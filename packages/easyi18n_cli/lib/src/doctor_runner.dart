import 'dart:io';

import 'package:path/path.dart' as p;

import 'adapters/stack_adapter.dart';
import 'adapters/stack_adapters.dart';
import 'adapters/web_adapter.dart';
import 'agents_md.dart';
import 'api_client.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'delivery.dart' show DeliveryClientFactory;
import 'doctor_report.dart';
import 'exceptions.dart';
import 'extract/tr_extractor.dart';
import 'logger.dart';
import 'output_format.dart';
import 'resolve.dart';
import 'security.dart';
import 'session.dart';

export 'delivery.dart' show DeliveryClientFactory;
export 'doctor_report.dart';

/// Shared config, credential and published-coverage checks plus the stack adapter.
class DoctorRunner {
  Future<DoctorReport> run({
    required String configPath,
    required CliLogger logger,
    StackAdapter? adapter,
    String sourceDir = 'lib',
    String? token,
    DeliveryClientFactory? deliveryFactory,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
    // Replay completed findings before later diagnostics or network requests.
    void Function(DoctorFinding)? onFinding,
    // An agent holds the key: doctor asks whether it is an Agent key.
    bool agentSession = false,
  }) => _DoctorRun(logger: logger, deliveryFactory: deliveryFactory,
      apiClientFactory: apiClientFactory, extractor: extractor,
      environment: environment, onFinding: onFinding, adapter: adapter)
      .run(configPath: configPath, sourcePath: sourceDir, token: token,
          agentSession: agentSession);
}

class _DoctorRun {
  _DoctorRun({
    required CliLogger logger,
    StackAdapter? adapter,
    DeliveryClientFactory? deliveryFactory,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
    void Function(DoctorFinding)? onFinding,
  }) : _logger = logger,
       _deliveryFactory = deliveryFactory,
       _adapter = adapter,
       _apiClientFactory = apiClientFactory ?? _defaultApiFactory,
       _extractor = extractor,
       _environment = environment ?? Platform.environment,
       _onFinding = onFinding;

  final CliLogger _logger;
  final DeliveryClientFactory? _deliveryFactory;
  final StackAdapter? _adapter;
  final ApiClientFactory _apiClientFactory;
  final TrExtractor? _extractor;
  final Map<String, String> _environment;
  final void Function(DoctorFinding)? _onFinding;
  final _findings = <DoctorFinding>[];
  late final _checks = DoctorFindings(_addFinding);

  Future<DoctorReport> run({required String configPath,
      required String sourcePath, String? token,
      bool agentSession = false}) async {
    // Same root idiom as push/extract, so every command scans the same tree.
    final root = p.dirname(configPath);

    // ---- local wiring -------------------------------------------------------
    // An agent calls doctor to orient itself, often before init: a missing
    // config is its first finding, not an error (#2445). The CLI keeps failing.
    if (agentSession && !File(configPath).existsSync()) {
      _checks.fail('config', configPath,
          'no ${Easyi18nConfig.fileName} - call init to create it');
      _checkCredential(token);
      final adapter = _adapter ?? adapterFor(root, null,
          extractor: _extractor, deliveryFactory: _deliveryFactory);
      return DoctorReport(_findings,
          projectDir: p.normalize(p.absolute(root)),
          baseUrl: Easyi18nConfig.originFrom(_environment),
          stack: adapter.stack, family: adapter.family);
    }
    final Easyi18nConfig config;
    try {
      config = Easyi18nConfig.load(File(configPath), logger: _logger);
    } on FileSystemException catch (e) {
      throw CliException('Cannot read $configPath: ${e.message}');
    }
    final modeA = config.mode == 'a';
    _checks.ok('config', configPath,
        'project ${config.describeRef}${modeA ? ' (Mode A: TMS)' : ''}');

    _checkCredential(token);
    if (agentSession) await _checkAgentKey(config, token);
    final adapter = _adapter ?? adapterFor(root, config,
        extractor: _extractor, deliveryFactory: _deliveryFactory);
    if (agentSession &&
        OutputFormatCheck.pulls(config, family: adapter.family)) {
      await _checkOutputFormat(config, token);
    }
    checkAgentsMd(root, config, adapter, _checks);
    await adapter.doctorChecks(root: root, sourcePath: sourcePath, config: config,
      findings: _checks);
    if (adapter is WebAdapter) await _checkLanguages(adapter, root, config, token);
    if (modeA) await _gradeModeACompleteness(config, token);

    return DoctorReport(_findings,
        projectDir: p.normalize(p.absolute(root)), baseUrl: config.baseUrl,
        stack: adapter.stack, family: adapter.family);
  }

  /// The Mode A half of "is this project actually translated?".
  ///
  /// Mode A publishes untranslated cells as ABSENT, so an incomplete locale
  /// renders as a shorter file and nothing local can tell it from a complete
  /// one — which is why `doctor` used to answer `All checks passed.` over a
  /// half-translated project (#1176). The verdict comes from the published
  /// version's own per-language coverage, the same pair `pull
  /// --require-complete` reads, and there are THREE answers, never two: it
  /// graded, it found something, or it could not look.
  Future<void> _gradeModeACompleteness(
    Easyi18nConfig config,
    String? flagToken,
  ) async {
    const tokenEnv = 'EASYI18N_TOKEN';
    final token = readToken(token: flagToken, environment: _environment) ?? '';
    if (token.isEmpty) {
      _checks.unverified('completeness', 'completeness',
          '$tokenEnv not set (a key with the read scope grades it)');
      return;
    }
    // This arm puts the bearer token on the wire,
    // and `baseUrl` comes from the checked-in yaml — the same reason the six
    // commands that send it warn first. Doctor is the one a dev runs on a
    // repo they just cloned, so it warns before the request, not after.
    // Setup and close stay outside grading catches: injected failures propagate.
    warnOnUntrustedTarget(config.baseUrl, _logger);
    final client =
        _apiClientFactory(baseUrl: config.baseUrl, token: token);
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      final pulled = await client.fetchTranslations(
        projectId: projectId,
        format: config.format,
      );
      final coverage = pulled.coverage;
      // Before the basis, in the gate's order: `coverage` and `coverageBasis`
      // shipped in one commit (`1e69bfdf`), so a backend without the count
      // has no basis either, and the basis arm told it to republish, which
      // stamps nothing that backend reports (#1263).
      if (coverage == null) {
        _checks.unverified('completeness', 'completeness',
            'the server reported no per-language coverage for version '
            '${pulled.version} - upgrade the backend');
        return;
      }
      // What the count MEANS travels with it: a version published with the
      // source fallback carries the base text in every untranslated cell, so
      // its coverage always reads complete (#1179).
      // The SAME set the gate reads, not a copy of its predicate. It used to
      // be a copy, and after #1182 narrowed the gate to `skip` this one still
      // accepted `hold` — under a comment promising they were copied — so
      // one version could be refused by `pull --require-complete` and graded
      // here (#1248).
      final basis = pulled.coverageBasis;
      if (!PulledTranslations.judgeableCoverageBases.contains(basis)) {
        // Three arms, the same three the gate refuses on: this is the command
        // a dev runs to find out why the sibling turned CI red, so it must
        // not answer a different question than the sibling asked. A ternary
        // here collapsed the unknown basis into the message for the ABSENT
        // one — "does not say how it treated untranslated cells" over a
        // version that does say — and sent the dev to republish, which
        // stamps the same basis again (#1248).
        _checks.unverified('completeness', 'completeness', switch (basis) {
          'source' => 'version ${pulled.version} was published with '
              'incompleteMode: source, whose coverage always reads complete',
          null => 'version ${pulled.version} does not say how it treated '
              'untranslated cells - publish again to stamp it',
          _ => 'version ${pulled.version} says it treated untranslated cells '
              'as `$basis`, which this easyi18n_cli does not know how to '
              'judge - upgrade easyi18n_cli',
        });
        return;
      }
      // `null` above is a check that could not look; `{}` is a backend that
      // reported coverage correctly for a version with no target language
      // (the base is omitted by construction, `public_api.dart`
      // `_coverageOf`). Reading `{}` as unverified blamed the server for a
      // healthy project and left it unable to print `All checks passed.`.
      if (coverage.isEmpty) {
        // Doctor and `pull --require-complete` answer THIS body in opposite
        // directions, deliberately: a base-only project is a healthy state
        // for a health check and nothing to gate on for a gate, which
        // refuses rather than green over a question nobody answered. Doctor
        // is the command a dev runs to find out why that gate turned CI
        // red, so the divergence is named here instead of left to be
        // discovered (#1176).
        _checks.skip('completeness', 'completeness',
            'version ${pulled.version} carries no target language, so there '
            'is nothing to grade (`pull --require-complete` refuses this '
            'same version - it has nothing to verify either)');
        return;
      }
      final incomplete = [
        for (final e in coverage.entries)
          if (!e.value.complete) e,
      ];
      if (incomplete.isEmpty) {
        _checks.ok('completeness', 'completeness',
            'every target language of version ${pulled.version} carries all '
            '${coverage.values.first.total} entries');
        return;
      }
      for (final e in incomplete) {
        _checks.fail('completeness', 'completeness',
            '${e.key}: ${e.value.total - e.value.translated} of '
            '${e.value.total} entry(ies) untranslated in version '
            '${pulled.version}');
      }
    } on ApiException catch (e) {
      // A key without the read scope is the expected miss, and it is the one
      // that must not read as a pass — it is exactly the state the arm exists
      // to grade, seen through a credential that cannot see it.
      final scopeHint =
          e.statusCode == 403 ? ' (does this key carry the read scope?)' : '';
      _checks.unverified(
          'completeness', 'completeness', 'the API answered ${e.statusCode}$scopeHint');
    } catch (e) {
      _checks.unverified('completeness', 'completeness', '$e');
    } finally {
      client.close();
    }
  }

  /// The web check that has to ask: which languages the project has today.
  /// A per-locale project shows one file per language, and nothing on disk
  /// says whether those are the languages easyi18n translates.
  Future<void> _checkLanguages(WebAdapter adapter, String root,
      Easyi18nConfig config, String? flagToken) async {
    final token = readToken(token: flagToken, environment: _environment) ?? '';
    if (token.isEmpty) {
      _checks.unverified('languages', 'languages', 'EASYI18N_TOKEN not set '
          '(a key with the read scope compares the project languages with '
          'the locale files)');
      return;
    }
    warnOnUntrustedTarget(config.baseUrl, _logger);
    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      final meta = await client.fetchMeta(projectId: projectId);
      if (meta.languages.isEmpty) {
        // "Unknown", never "the project has no languages" (`ProjectMeta`).
        _checks.unverified('languages', 'languages', 'the server reported no '
            'languages for this project - upgrade the backend');
        return;
      }
      adapter.checkLanguages(root: root, config: config, findings: _checks,
          codes: [for (final language in meta.languages) language.code]);
    } on ApiException catch (e) {
      _checks.unverified('languages', 'languages',
          'the API answered ${e.statusCode}');
    } catch (e) {
      _checks.unverified('languages', 'languages', '$e');
    } finally {
      client.close();
    }
  }

  /// Only an Agent key makes every spend and publish wait for a human
  /// approval (agent-native §6.2), and the agent is who holds the key. The CLI
  /// doctor does not ask: a CI key is the other valid kind, and on Mode B that
  /// doctor sends the token nowhere.
  Future<void> _checkAgentKey(Easyi18nConfig config, String? flagToken) async {
    final token = readToken(token: flagToken, environment: _environment) ?? '';
    if (token.isEmpty) return;
    warnOnUntrustedTarget(config.baseUrl, _logger);
    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      final key = await client.fetchCredential(projectId: projectId);
      final scopes = 'scopes: ${key.scopes.join(', ')}';
      if (key.requiresOperationApproval) {
        _checks.ok('agent_key', 'credential', 'Agent key ($scopes): every '
            'spend and publish waits for a human approval');
      } else {
        _checks.warn('agent_key', 'credential', 'not an Agent key: spends and '
            'publishes without a human approval ($scopes) - create one under '
            'API keys > New API key, Used by: AI agent');
      }
    } on ApiException catch (e) {
      _checks.unverified('agent_key', 'credential',
          'the API answered ${e.statusCode}');
    } catch (e) {
      _checks.unverified('agent_key', 'credential', '$e');
    } finally {
      client.close();
    }
  }

  /// Asked where the loop ends in `pull`, and only of an agent: its key is
  /// the one that spends and publishes without being able to enable a format.
  Future<void> _checkOutputFormat(Easyi18nConfig config, String? flagToken) async {
    final token = readToken(token: flagToken, environment: _environment) ?? '';
    if (token.isEmpty) return;
    warnOnUntrustedTarget(config.baseUrl, _logger);
    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      final check =
          await OutputFormatCheck.of(client, projectId, config.format);
      final report = check.readiness.blocksPull ? _checks.fail
          : check.readiness == OutputFormatReadiness.unknown
              ? _checks.unverified : _checks.ok;
      report('output_format', 'output format', check.message,
          details: check.remedy);
    } on ApiException catch (e) {
      _checks.unverified('output_format', 'output format',
          'the API answered ${e.statusCode}');
    } catch (e) {
      _checks.unverified('output_format', 'output format', '$e');
    } finally {
      client.close();
    }
  }

  // ----- local checks --------------------------------------------------------

  void _checkCredential(String? flagToken) {
    final token = readToken(token: flagToken, environment: _environment);
    if (token != null && token.isNotEmpty) {
      _checks.ok('credential', 'credential', 'EASYI18N_TOKEN set');
    } else {
      _checks.warn('credential', 'credential',
        "EASYI18N_TOKEN not set - 'easyi18n push/pull' will need it",
      );
    }
  }

  void _addFinding(DoctorFinding finding) {
    _findings.add(finding);
    _onFinding?.call(finding);
  }

  static TranslationsApiClient _defaultApiFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);
}
