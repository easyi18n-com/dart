import 'dart:io';

import 'package:args/command_runner.dart';

import '../cli_output.dart';
import '../config.dart';
import '../logger.dart';
import '../session.dart';
import '../status_runner.dart';
import 'pull_command.dart' show ApiClientFactory;

/// `easyi18n status` compares the last pulled version
/// (`.easyi18n/state.json`) against the server's current published version, so
/// a dev can tell at a glance whether the files on disk are up to date.
class StatusCommand extends Command<int> with JsonPresenter {
  StatusCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _apiClientFactory = apiClientFactory,
       _environment = environment ?? Platform.environment {
    argParser.addOption(
      'token',
      help:
          'API key (eik_) with the read scope. '
          'Defaults to \$EASYI18N_TOKEN, then your easyi18n login.',
    );
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final ApiClientFactory? _apiClientFactory;
  final Map<String, String> _environment;

  @override
  String get name => 'status';

  @override
  String get description =>
      'Show whether the local translations are up to date with the server.';

  @override
  Future<int> run() async {
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);

    final token = requireToken(
      token: argResults!['token'] as String?, environment: _environment,
      baseUrl: config.baseUrl,
    );
    final result = await StatusRunner().run(
      config: config, configPath: configPath, token: token, logger: _logger,
      apiClientFactory: _apiClientFactory,
    );
    if (output.json) {
      output.emit(result.toJson());
      return result.exitCode;
    }
    if (!result.published) {
      _logger.info('remote: (never published)');
      _logger.info(
        "The project has no published version yet - run 'easyi18n push "
        "--publish' or publish from the dashboard.",
      );
      return result.exitCode;
    }
    _logger.info('remote: ${result.remoteVersion}');
    if (result.localVersion == null) {
      _logger.info('local:  (never pulled)');
      _logger.info("Run 'easyi18n pull' to download the current version.");
      return result.exitCode;
    }
    final pulledAgo = result.pulledAt == null
        ? ''
        : ' (pulled ${_ago(result.pulledAt!)})';
    _logger.info('local:  ${result.localVersion}$pulledAgo');
    final catalog = result.catalog;
    if (catalog != null) _logger.detail('catalog: $catalog');
    if (result.catalogs.isNotEmpty) {
      _logger.detail('catalogs: ${result.catalogs.join(', ')}');
    }
    if (result.state == 'up_to_date') {
      _logger.info('Up to date.');
    } else {
      final n = result.behind;
      final behind = n == null ? '' : ' - $n publish${n == 1 ? '' : 'es'} behind';
      _logger.info("Out of date$behind - run 'easyi18n pull'.");
    }
    return result.exitCode;
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
