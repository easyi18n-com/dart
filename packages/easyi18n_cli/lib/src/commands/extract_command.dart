import 'package:args/command_runner.dart';

import '../cli_output.dart';
import '../config.dart';
import '../extract/extraction_report.dart';
import '../extract/tr_extractor.dart';
import '../extract_runner.dart';
import '../logger.dart';

/// `easyi18n extract` - statically scan the source tree for `tr()` calls and
/// print what would be registered, what's new, and what's orphaned versus the
/// lockfile. Read-only and offline: it never writes the lockfile or contacts the
/// backend (that's `push`). Useful as a CI drift check or before a push.
class ExtractCommand extends Command<int> with JsonPresenter {
  ExtractCommand({required this.output, TrExtractor? extractor})
    : _runner = ExtractRunner(extractor: extractor) {
    argParser
      ..addOption(
        'source-dir',
        help: 'Directory to scan, relative to the config file.',
        defaultsTo: 'lib',
      )
      ..addFlag(
        'fail-on-orphans',
        negatable: false,
        help: 'Exit non-zero if the lockfile has strings no longer in code.',
      );
  }

  final CliOutput output;
  final ExtractRunner _runner;
  CliLogger get _logger => output.logger;

  @override
  String get name => 'extract';

  @override
  String get description =>
      'Scan the source tree for tr() strings and report against the lockfile.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final result = _runner.run(
      configPath: configPath,
      sourceDir: results['source-dir'] as String,
      logger: _logger,
    );
    // JSON uses outputQuiet to suppress info/detail; shared warnings/errors
    // still reach stderr, including any added to this report later.
    reportExtraction(_logger, result.extraction, result.diff);
    if (output.json) {
      output.emit(result.toJson());
    }

    if ((results['fail-on-orphans'] as bool) && result.orphans > 0) {
      _logger.error('${result.orphans} orphan(s) found.');
      return 1;
    }
    return 0;
  }
}
