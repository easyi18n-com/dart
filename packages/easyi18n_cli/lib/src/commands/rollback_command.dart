import 'dart:io';

import 'package:args/command_runner.dart';

import '../cli_output.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../rollback_runner.dart';
import '../session.dart';
import 'pull_command.dart' show ApiClientFactory;

/// `easyi18n rollback [version]` - restore a prior published version as a NEW
/// version (history is never rewritten) and point delivery at it. With no
/// argument it restores the version just before the current one - the "undo
/// the last publish" move after a bad `push --publish`.
class RollbackCommand extends Command<int> with JsonPresenter {
  RollbackCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _apiClientFactory = apiClientFactory,
       _environment = environment ?? Platform.environment {
    argParser.addOption(
      'token',
      help:
          'API key (eik_) with the publish scope. '
          'Defaults to \$EASYI18N_TOKEN, then your easyi18n login.',
    );
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final ApiClientFactory? _apiClientFactory;
  final Map<String, String> _environment;

  @override
  String get name => 'rollback';

  @override
  String get description =>
      'Restore a prior published version (default: the previous one) as a '
      'new version.';

  @override
  String get invocation => 'easyi18n rollback [version]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length > 1) {
      throw CliException(
        'At most one version id, got: ${rest.join(' ')}. '
        'Usage: easyi18n rollback [version]',
      );
    }
    final versionId = rest.isEmpty ? 'previous' : rest.single.trim();

    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);

    final token = requireToken(
      token: argResults!['token'] as String?, environment: _environment,
      scope: 'publish', baseUrl: config.baseUrl,
    );
    final outcome = await RollbackRunner().run(
      config: config, configPath: configPath, token: token, logger: _logger,
      versionId: versionId, apiClientFactory: _apiClientFactory,
    );
    // Restore's lists carry the OPPOSITE verdict to push's (#605): the
    // snapshot is copied verbatim, so the named cells are PRESENT in the
    // restored version — today's publish gates would refuse them. The
    // count rides the success line for the same reason as push's (#609):
    // a log that captured stdout alone must not read this as clean.
    final flagged = outcome.icuRejectedTotal + outcome.markupRejectedTotal;
    _logger.info(
      'Rolled back: ${outcome.restoredFrom} restored as '
      '${outcome.versionId} (${outcome.keyCount} key(s))'
      '${flagged == 0 ? '' : ' — $flagged cell(s) would be refused by '
          "today's publish gates, see the warnings"}.',
    );
    _warnRefusable(
      outcome.icuRejected,
      outcome.icuRejectedTotal,
      'fail ICU validation',
    );
    _warnRefusable(
      outcome.markupRejected,
      outcome.markupRejectedTotal,
      "break the source's markup structure",
    );
    if (output.json) output.emit(outcome.toJson());
    return 0;
  }

  /// One warning block for cells the restored version carries that today's
  /// gates would refuse. Unlike push's `_warnRejected`, nothing "fell back"
  /// — the cells shipped verbatim. [total] is the server's count, which
  /// exceeds [entries] once the response hit the 50-row cap.
  void _warnRefusable(List<String> entries, int total, String what) {
    if (entries.isEmpty) return;
    _logger.warn(
      '$total cell(s) in the restored version $what and are being served:',
    );
    for (final entry in entries) {
      _logger.warn('  $entry');
    }
    final hidden = total - entries.length;
    if (hidden > 0) {
      _logger.warn('  ...and $hidden more the server did not list.');
    }
  }
}
