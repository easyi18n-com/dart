import 'dart:io';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../cli_output.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../output_format.dart';
import '../pull_runner.dart';
import '../resolve.dart';
import '../security.dart';
import '../session.dart';

/// Builds the API client `pull` talks to. Injected so tests can swap in a
/// `MockClient`-backed instance.
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// `easyi18n pull` - downloads the translated files for the configured project
/// from the authenticated backend and writes them to the output directory, so
/// the dev can run `flutter gen-l10n` (Mode A - native .arb).
///
/// `--watch` keeps running: it polls the project's `meta` (cheap - one small
/// GET per cycle, no file bodies) and re-pulls whenever `currentVersionId`
/// changes, so a publish from the dashboard or CI lands on disk by itself.
class PullCommand extends Command<int> with JsonPresenter {
  PullCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
    Future<void> Function(Duration)? sleeper,
    int? watchCyclesForTest,
  }) : _runner = PullRunner(output.logger),
       _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _environment = environment ?? Platform.environment,
       _sleep = sleeper ?? Future<void>.delayed,
       _watchCyclesForTest = watchCyclesForTest {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with read scope; adopting a missing format also needs write. '
            'Defaults to \$EASYI18N_TOKEN, then your easyi18n login.',
      )
      ..addOption(
        'version',
        help: 'Published version to pull (YYYY.MM.DD.N). Defaults to latest.',
      )
      ..addOption('lang', help: 'Only pull one locale (e.g. es).')
      ..addFlag(
        'require-complete',
        negatable: false,
        help:
            'Fail (exit 1) when any target language of the pulled version is '
            'missing translations — the CI gate for a Mode A project, whose '
            'translations live on the server, not in the code. Needs '
            '`mode: a` in the config, and refuses to judge a version whose '
            'publish baked the source into untranslated cells, or that does '
            'not say which it did: the version decides, not the config.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'List the files that would be written without writing them.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Replace a file that changed since the pull that wrote it. '
            'Without it such a file stops the pull before anything is written.',
      )
      ..addFlag(
        'watch',
        negatable: false,
        help:
            'Keep running: re-pull whenever a new version is published. '
            'Ctrl-C to stop.',
      )
      ..addOption(
        'interval',
        defaultsTo: '30',
        help: 'Seconds between version checks in --watch mode (min 5).',
      );
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final PullRunner _runner;
  final ApiClientFactory _apiClientFactory;
  final Map<String, String> _environment;
  final Future<void> Function(Duration) _sleep;

  /// Tests only: stop the watch loop after N checks instead of running
  /// forever. Null (production) never stops.
  final int? _watchCyclesForTest;

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Download translated files from easyi18n and write them to disk.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);

    final token = requireCredential(
      token: results['token'] as String?, environment: _environment,
      baseUrl: config.baseUrl,
      need: 'Create an API key in your project settings with read scope. '
          'Adopting a missing format also requires write scope.',
    );

    warnOnUntrustedTarget(config.baseUrl, _logger);

    final watch = results['watch'] as bool;
    if (watch && output.json) {
      throw CliException('--json cannot be combined with --watch. Run a one-shot pull instead.');
    }
    final dryRun = results['dry-run'] as bool;
    final force = results['force'] as bool;
    final version = results['version'] as String?;
    // Read as the route reads `?lang=`: trimmed, and empty is no filter. A
    // blank value renders every file, and the pull has to prune and gate like
    // the full one it is; a padded one renders the trimmed locale.
    final lang = switch ((results['lang'] as String?)?.trim()) {
      '' => null,
      final l => l,
    };
    final requireComplete = results['require-complete'] as bool;
    if (watch && requireComplete) {
      throw CliException(
          '--require-complete is a one-shot gate; it cannot be combined '
          'with --watch.');
    }
    // Mode A only: a Mode B project publishes under `incompleteMode: source`,
    // which bakes the SOURCE into every untranslated cell — the server then
    // counts it as a value and this gate could never fail. Refusing beats a
    // green that measures nothing (#1052).
    if (requireComplete && config.mode != 'a') {
      // The first remedy is the config line, not another command: for a
      // gen_l10n project the two commands this used to name are the ones
      // #1052 documents as structurally unusable, and `push`'s own remedy
      // points back here — a circle with the real fix outside it.
      throw CliException(
          '--require-complete on `pull` is the Mode A gate (the project '
          'publishes untranslated cells as absent), and this config reads '
          '`mode: ${config.mode}`. If this project keeps its gen_l10n files '
          'and the dashboard translates them, add `mode: a` to '
          'easyi18n.yaml. If it really is a runtime-SDK project, gate with '
          '`push --publish --require-complete` instead.');
    }
    if (watch && version != null) {
      throw CliException(
        '--watch follows the latest published version; it cannot be '
        'combined with --version.',
      );
    }
    if (watch && dryRun) {
      throw CliException('--watch cannot be combined with --dry-run.');
    }
    if (config.format == 'xcstrings' && lang != null) {
      throw CliException(
        '--lang cannot be combined with format: xcstrings. A String Catalog '
        'holds every language in one file, and a single-locale render drops '
        'the base values its keys are addressed by, so it has nothing to '
        'merge back into. Pull the whole catalog instead.',
      );
    }

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    final recovery = OutputFormatAdoption(config.format);
    // Set once a file is pruned or written, so a later failure still reports
    // them.
    PullOutcome? partial;
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      if (!watch) {
        final pulled = partial = await _runner.pullOnceDetailed(
          client: client,
          config: config,
          projectId: projectId,
          configPath: configPath,
          version: version,
          lang: lang,
          dryRun: dryRun,
          recovery: recovery,
          onApplied: (applied) => partial = applied,
          force: force,
        );
        if (requireComplete) _runner.gateComplete(pulled, lang: lang);
        if (output.json) output.emit(pulled.toJson());
        return 0;
      }
      return await _watch(
        client: client,
        config: config,
        projectId: projectId,
        configPath: configPath,
        lang: lang,
        interval: _parseInterval(results['interval'] as String),
        recovery: recovery,
        force: force,
      );
    } on CliException catch (e) {
      final error = recovery.annotate(e);
      if (partial == null || !output.json) throw error;
      output.emitError(error, report: partial!.toJson());
      return error.exitCode;
    } on FileSystemException catch (e) {
      if (partial == null || !output.json) rethrow;
      final record = fileSystemError(e);
      output.emitError(record, report: partial!.toJson());
      return record.exitCode;
    } finally {
      client.close();
    }
  }

  Duration _parseInterval(String raw) {
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 5) {
      throw CliException('--interval must be an integer >= 5 (seconds).');
    }
    return Duration(seconds: seconds);
  }

  /// Poll `meta` and re-pull on every new `currentVersionId`. Transient
  /// errors — backend/network (CliException) AND local file I/O
  /// (FileSystemException from the atomic write) — are warnings: a watcher
  /// that dies overnight on one hiccup is worse than one that retries next
  /// cycle. Same for the bootstrap pull: a watch started before the FIRST
  /// publish must idle until a version appears, not exit with an error.
  ///
  /// A [FatalCliException] is the exception to that: retrying cannot fix it,
  /// so warning once per cycle forever would leave the watcher alive, silent
  /// about being useless, and exiting 0.
  Future<int> _watch({
    required TranslationsApiClient client,
    required Easyi18nConfig config,
    required String projectId,
    required String configPath,
    required String? lang,
    required Duration interval,
    required OutputFormatAdoption recovery,
    required bool force,
  }) async {
    Future<String> pullLatest() => _runner.pullOnce(
      client: client,
      config: config,
      projectId: projectId,
      configPath: configPath,
      version: null,
      lang: lang,
      dryRun: false,
      recovery: recovery,
      force: force,
    );

    var lastVersion = '';
    try {
      lastVersion = await pullLatest();
    } on FatalCliException {
      rethrow;
    } on CliException catch (e) {
      _logger.warn('${recovery.annotate(e).message} (watching for the first publish)');
    } on FileSystemException catch (e) {
      _logger.warn('${e.message} (retrying next cycle)');
    }
    _logger.info(
      'Watching for new published versions every ${interval.inSeconds}s '
      '- Ctrl-C to stop.',
    );
    var cycles = 0;
    while (_watchCyclesForTest == null || cycles < _watchCyclesForTest) {
      cycles++;
      await _sleep(interval);
      try {
        final meta = await client.fetchMeta(projectId: projectId);
        if (meta.currentVersionId.isEmpty ||
            meta.currentVersionId == lastVersion) {
          continue;
        }
        _logger.info('New version ${meta.currentVersionId} - pulling.');
        lastVersion = await pullLatest();
      } on FatalCliException {
        rethrow;
      } on CliException catch (e) {
        _logger.warn('${e.message} (retrying next cycle)');
      } on FileSystemException catch (e) {
        _logger.warn('${e.message} (retrying next cycle)');
      }
    }
    return 0;
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);
}
