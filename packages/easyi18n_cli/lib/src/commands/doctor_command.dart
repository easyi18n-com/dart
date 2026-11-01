import 'package:args/command_runner.dart';

import '../cli_output.dart';
import '../config.dart';
import '../doctor_runner.dart';
import '../extract/tr_extractor.dart';
import '../logger.dart';
import 'pull_command.dart' show ApiClientFactory;

/// Cap on itemized details so a large drift does not scroll away the summary.
const int _maxListed = 10;

class DoctorCommand extends Command<int> with JsonPresenter {
  DoctorCommand({
    required this.output,
    DeliveryClientFactory? deliveryFactory,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
  }) : _deliveryFactory = deliveryFactory,
       _apiClientFactory = apiClientFactory,
       _extractor = extractor,
       _environment = environment {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with the read scope. Reads published coverage '
            'for Mode A and project languages for web projects. '
            'Defaults to \$EASYI18N_TOKEN.',
      )
      ..addOption(
        'source-dir',
        help: 'Directory to scan for tr() calls, relative to the config file.',
        defaultsTo: 'lib',
      );
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final DeliveryClientFactory? _deliveryFactory;
  final ApiClientFactory? _apiClientFactory;
  final TrExtractor? _extractor;
  final Map<String, String>? _environment;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check the easyi18n integration: config, platform wiring, ICU health '
      'and the published translations vs your tr() calls.';

  @override
  Future<int> run() async {
    final report = await DoctorRunner().run(
      configPath: globalResults?['config'] as String? ?? Easyi18nConfig.fileName,
      sourceDir: argResults!['source-dir'] as String,
      token: argResults!['token'] as String?, logger: _logger,
      deliveryFactory: _deliveryFactory, apiClientFactory: _apiClientFactory,
      extractor: _extractor, environment: _environment,
      onFinding: output.json ? null : _replay,
    );
    if (output.json) {
      output.emit(report.toJson());
    } else {
      _verdict(report);
    }
    return report.exitCode;
  }

  void _replay(DoctorFinding finding) {
    // ICU historically lists locations before its headline; other checks after.
    if (finding.check == 'icu') _details(finding.details);
    final prefix = switch (finding.level) {
      'ok' => 'ok   ', 'warn' => 'warn ', 'fail' => 'FAIL ', _ => 'info ',
    };
    final unverified = finding.level == 'unverified' ? 'could not verify: ' : '';
    _logger.info('$prefix ${finding.subject} - $unverified${finding.message}');
    if (finding.check != 'icu') _details(finding.details);
  }

  void _details(List<String> details) {
    for (final detail in details.take(_maxListed)) {
      _logger.detail(detail);
    }
    if (details.length > _maxListed) {
      _logger.detail('... and ${details.length - _maxListed} more');
    }
  }

  void _verdict(DoctorReport report) {
    final unchecked = report.unchecked == 0
        ? '' : ' ${report.unchecked} check(s) could not run - see `info` above.';
    _logger.info(switch (report.verdict) {
      'failed' => '${report.failures} problem(s), ${report.warnings} warning(s).'
          "$unchecked Most local issues are fixed by 'easyi18n init'.",
      'passed' => 'All checks passed.',
      _ => 'No blocking problems, ${report.warnings} warning(s).$unchecked',
    });
  }
}
