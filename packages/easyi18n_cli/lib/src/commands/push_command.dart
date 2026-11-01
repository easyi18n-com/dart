import 'dart:io';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../cli_output.dart';
import '../config.dart';
import '../credits.dart';
import '../exceptions.dart';
import '../extract/extraction_report.dart';
import '../extract/tr_extractor.dart';
import '../fill_completeness.dart';
import '../logger.dart';
import '../output_format.dart';
import '../publish_runner.dart';
import '../push_runner.dart';
import '../resolve.dart';
import '../security.dart';

/// Builds the API client `push` talks to. Injected so tests can swap in a
/// `MockClient`-backed instance.
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// Asks the user to confirm an action; returns true to proceed. Injected so
/// tests don't block on stdin.
typedef Confirm = bool Function(String prompt);

/// `easyi18n push` - statically extract `tr()` sources from the source tree,
/// diff them against the lockfile, then register and translate them via the
/// authenticated backend. Interactive by default with a cost preview; `--yes`
/// for CI, `--dry-run` to only estimate, `--max-credits` to cap the spend.
///
/// Under `--json` stdout is the wire: the prompt is never written, so `--yes`
/// is the only consent a priced push accepts. A failure after the lockfile
/// moved still carries the report beside `error`, because the push it
/// describes already happened.
class PushCommand extends Command<int> with JsonPresenter {
  PushCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
    Confirm? confirm,
    Future<void> Function(Duration)? wait,
  }) : _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _extractor = extractor ?? TrExtractor(),
       _environment = environment ?? Platform.environment,
       _confirm =
           confirm ?? ((prompt) => _stdinConfirm(prompt, output.logger)),
       _wait = wait ?? Future<void>.delayed {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with translate scope; --publish also needs publish. '
            'Mode A --publish needs read, plus write for format adoption. '
            'Defaults to \$EASYI18N_TOKEN.',
      )
      ..addOption(
        'source-dir',
        help: 'Directory to scan, relative to the config file.',
        defaultsTo: 'lib',
      )
      ..addMultiOption(
        'lang',
        help:
            'Restrict to these target languages (repeatable). '
            'Defaults to all of the project\'s languages.',
      )
      ..addOption(
        'max-credits',
        help:
            'Abort if the estimate exceeds this many credits '
            '(decimals allowed; CI guard).',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Estimate the cost without registering or translating anything.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip the confirmation prompt (for CI).',
      )
      ..addFlag(
        'prune',
        negatable: false,
        help:
            'Drop orphaned strings from the lockfile (never deletes '
            'translations).',
      )
      ..addFlag(
        'publish',
        negatable: false,
        help:
            'After pushing, wait for the AI fill to complete and publish a '
            'new version (needs the publish scope).',
      )
      ..addFlag(
        'approved-only',
        negatable: false,
        help:
            'With --publish: treat unapproved translations as missing when '
            'publishing.',
      )
      ..addFlag(
        'require-complete',
        negatable: false,
        help:
            'With --publish: fail before publishing when extracted strings '
            'remain untranslated after the fill retries, or when the scan '
            'finds no strings and completeness cannot be verified.',
      );
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final ApiClientFactory _apiClientFactory;
  final TrExtractor _extractor;
  final Map<String, String> _environment;
  final Confirm _confirm;
  final Future<void> Function(Duration) _wait;

  static const _runner = PushRunner();
  static const _publisher = PublishRunner();

  static const String tokenEnvVar = 'EASYI18N_TOKEN';

  @override
  String get name => 'push';

  @override
  String get description =>
      'Extract tr() strings, register them, and trigger translation.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);

    final dryRun = results['dry-run'] as bool;
    final prune = results['prune'] as bool;
    final assumeYes = results['yes'] as bool;
    final langs = results['lang'] as List<String>;
    final maxCreditsMc = _parseMaxCredits(results['max-credits'] as String?);
    final publish = results['publish'] as bool;
    final approvedOnly = results['approved-only'] as bool;
    final requireComplete = results['require-complete'] as bool;
    if (approvedOnly && !publish) {
      throw CliException('--approved-only only makes sense with --publish.');
    }
    if (requireComplete && !publish) {
      throw CliException('--require-complete only makes sense with --publish.');
    }
    if (publish && dryRun) {
      throw CliException('--publish cannot be combined with --dry-run.');
    }

    // ---- 1. scan + diff (offline) ----
    final scan = _runner.scan(
      _extractor,
      config,
      configPath: configPath,
      sourceDir: results['source-dir'] as String,
    );
    final extraction = scan.extraction;
    final lockFile = scan.lockFile;
    final lock = scan.lock;
    final units = scan.units;
    reportExtraction(_logger, extraction, scan.diff);

    // `requireComplete` is already rejected without `publish` above, so the
    // guard does not repeat an equivalent `publish` conjunct.
    if (extraction.units.isEmpty && requireComplete) {
      final isModeA = config.mode == 'a';
      final catalog = config.catalog;
      final source = config.source;
      // What `sync` can upload: a single-file catalog, or the base-language
      // file of a per-locale project.
      final modeAHasCatalogPath =
          isModeA &&
          (config.catalogs.isNotEmpty || (catalog != null && catalog.isNotEmpty)
              ? Easyi18nConfig.catalogFormats.contains(config.format)
              : source != null && source.isNotEmpty &&
                  !config.sourceIsArbTemplate);
      final remedy = !isModeA
          ? 'Check --source-dir and your tr() calls. To deliberately publish '
              'the current remote state, remove --require-complete.'
          : modeAHasCatalogPath
              ? 'Ensure the configured catalog file exists, then run '
                  '`easyi18n sync --require-complete` instead. To deliberately '
                  'publish the current remote state, remove --require-complete.'
              : 'This Mode A config has no push-side completeness path '
                  '(`sync` requires a non-empty `catalog:` in a supported '
                  'catalog format, or a `source:`). Gate on `easyi18n pull '
                  '--require-complete` '
                  'instead — it reads the published version\'s per-language '
                  'coverage — or remove --require-complete to deliberately '
                  'publish the current remote state.';
      throw CliException(
        '`push --publish --require-complete` found no extractable tr() '
        'strings, so it cannot verify completeness. Nothing was published.\n'
        '$remedy',
      );
    }

    if (extraction.units.isEmpty && !publish) {
      _logger.info('No extractable tr() strings found. Nothing to push.');
      return _finish(
        0,
        PushReport(preview: PushPreview.offline(scan), dryRun: dryRun),
      );
    }

    // ---- 2. resolve the credential ----
    final token =
        (results['token'] as String?)?.trim() ??
        _environment[tokenEnvVar]?.trim();
    if (token == null || token.isEmpty) {
      throw CliException(
        'No credential. Set $tokenEnvVar or pass --token.\n'
        'Create an API key in your project settings with translate scope. '
        '--publish also needs publish; in Mode A it needs read, '
        'plus write when adopting a format.',
      );
    }

    warnOnUntrustedTarget(config.baseUrl, _logger);

    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);

    final adoption = publish && config.mode == 'a'
        ? OutputFormatAdoption(config.format) : null;
    // Set once a real batch is accepted or the lockfile moves, so a failure
    // after that point still reports what the run did.
    PushReport? partial;
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      // File publication needs strict metadata; other pushes keep narrow scopes.
      ProjectMeta? meta;
      try {
        meta = adoption == null
            ? await client.fetchMeta(projectId: projectId)
            : await adoption.preflight(client, projectId);
      } catch (_) {
        if (adoption != null) rethrow;
        // Deliberately blanket. The call is best effort: a 200 whose body is
        // JSON of the wrong shape now fails as a FatalCliException (#972), and
        // that is precisely the failure this catch must swallow — narrowing it
        // would let a malformed `/meta` kill a push that never needed it.
        meta = null;
      }
      // Only when a translate call will actually happen: with nothing to
      // extract, `--lang` is inert (the publish path below ignores it), so
      // rejecting on it would block a publish that used to work.
      if (units.isNotEmpty) _checkRequestedLangs(langs, meta);
      if (publish) _warnOnModeDisagreement(config, meta);

      // Nothing to register: publish the state that's already on the server
      // (and never touch the lockfile - `--prune` would empty it).
      if (units.isEmpty) {
        _logger.info(
          'No extractable tr() strings found - publishing the current state.',
        );
        await adoption?.apply(client, projectId, _logger);
        final outcome = await _publish(client, projectId, approvedOnly,
            requiredOutputFormat: adoption?.format,
            incompleteMode: _incompleteModeFor(config));
        // Through `_finish` like every other successful exit: this path
        // publishes, and under `--json` a bare `return 0` would answer a run
        // that minted a version with no record at all.
        return _finish(
          0,
          PushReport(
            preview: PushPreview.offline(scan),
            dryRun: dryRun,
            published: outcome,
          ),
        );
      }

      // ---- 3. cost preview (dry run, batched) ----
      final previewed = await _runner.preview(client, projectId, scan, langs);
      final preview = previewed.result!;
      PushReport report({
        PushResult? pushed,
        PublishOutcome? published,
        bool lockfileWritten = false,
      }) => PushReport(
        preview: previewed,
        dryRun: dryRun,
        pushed: pushed,
        published: published,
        lockfileWritten: lockfileWritten,
      );
      _logger.info(
        '${preview.unitsNeedingTranslation} string(s) need translation · '
        '~${formatCredits(preview.estimatedCredits)} credit(s) '
        '(available ${formatCredits(preview.spendable)}).',
      );
      if (preview.skippedGated > 0) {
        _logger.warn(
          '${preview.skippedGated} source(s) skipped — pending source verification. '
          'Their translations wait until the source is verified '
          "in the app (this project's source verification gate is on).",
        );
      }
      // Not a deferral like the gate above: nothing will translate these until
      // someone switches the key back on, so the push must say so rather than
      // look clean while those strings stay untranslated.
      if (preview.skippedDisabled > 0) {
        _logger.warn(
          '${preview.skippedDisabled} string(s) skipped — their key is '
          'switched off in the app, so they are excluded from published '
          'output and are not translated. Re-enable the key to translate it.',
        );
      }

      if (maxCreditsMc != null && preview.estimatedCredits > maxCreditsMc) {
        throw CliException(
          'Estimate ~${formatCredits(preview.estimatedCredits)} credit(s) '
          'exceeds --max-credits ${formatCredits(maxCreditsMc)}. Aborted.',
        );
      }

      // The real push enforces the plan key cap (402 `plan_limit`); surface it
      // here so an affordable-looking estimate doesn't preview as a green push.
      if (preview.wouldExceedKeyCap) {
        if (dryRun) {
          _logger.warn(
            "This push would exceed your plan's key limit for this project.",
          );
          return _finish(1, report());
        }
        throw CliException(
          "This push would exceed your plan's key limit for this project. "
          'Upgrade your plan or remove unused keys, then retry.',
        );
      }

      if (dryRun) {
        // Warn-only here: the exit stays the affordability answer. A dry run
        // has no publish to refuse, so `--require-complete` (rejected with
        // --dry-run anyway) has nothing to govern on this path.
        reportExhausted(_logger, preview.exhaustedPairs,
            requireComplete: false);
        _logger.info('Dry run - nothing registered or translated.');
        return _finish(preview.affordable ? 0 : 1, report());
      }

      // A zero estimate means nothing NEW needs a fill - but langs left
      // in-flight by an earlier push are free and still untranslated, so
      // publishing here without waiting would bake base text (friction F2).
      if (preview.estimatedCredits == 0) {
        // "Everything is already translated." was the #752 lie: an exhausted
        // pair is neither pending nor priced, so this branch read it as
        // complete and said so while the catalog was short.
        if (preview.unitsNeedingTranslation > 0) {
          _logger.info(
            '${preview.unitsNeedingTranslation} string(s) are still being '
            'translated from an earlier push.',
          );
        } else if (preview.exhaustedPairs.isEmpty) {
          _logger.info('Everything is already translated.');
        }
        await adoption?.apply(client, projectId, _logger);
        _runner.writeLock(lockFile, projectId, lock, extraction, prune);
        partial = report(lockfileWritten: true);
        PublishOutcome? published;
        if (publish) {
          published = await _waitFillAndPublish(
            client,
            projectId,
            units,
            langs,
            approvedOnly: approvedOnly,
            requireComplete: requireComplete,
            maxCreditsMc: maxCreditsMc,
            incompleteMode: _incompleteModeFor(config),
            meta: meta,
            requiredOutputFormat: adoption?.format,
          );
        } else {
          // No poll on this path, so the preview's answer is the only one.
          reportExhausted(_logger, preview.exhaustedPairs,
              requireComplete: false);
          if (preview.unitsNeedingTranslation > 0) {
            _logger.info("Run 'easyi18n pull' once it completes.");
          }
        }
        return _finish(0, report(published: published, lockfileWritten: true));
      }

      if (!preview.affordable) {
        _logger.warn(
          'The estimate exceeds the credits available to it; the push may '
          'stop partway when they run out. Credits reserved by a fill already '
          'in flight are not spendable here.',
        );
      }

      // ---- 4. confirm ----
      // JSON is a wire, not a person: nothing on it can answer a prompt, and
      // an injected `confirm` is not consent either. Refuse loudly rather
      // than exit 0 having spent nothing — an agent keys on the exit code.
      if (!assumeYes && output.json) {
        throw CliException(
          'Refusing to spend ~${formatCredits(preview.estimatedCredits)} '
          'credit(s) without --yes under --json. Re-run with --yes to '
          'consent, or --dry-run to preview only.',
          code: 'confirmation_required',
        );
      }
      if (!assumeYes &&
          !_confirm(
            'Translate ${preview.unitsNeedingTranslation} string(s) '
            'for ~${formatCredits(preview.estimatedCredits)} credit(s)? '
            '[y/N] ',
          )) {
        _logger.info('Aborted.');
        return 0;
      }

      await adoption?.apply(client, projectId, _logger);

      // ---- 5. real push, batched ----
      final pushed = await _runner.run(
        client,
        projectId,
        units,
        langs,
        dryRun: false,
        maxCreditsMc: maxCreditsMc,
        onSent: (sent) => partial = report(pushed: sent),
      );
      _runner.writeLock(lockFile, projectId, lock, extraction, prune);
      partial = report(pushed: pushed, lockfileWritten: true);

      if (pushed.trackingTokens.isEmpty) {
        _logger.info('Registered. Nothing new to translate.');
      } else {
        _logger.info(
          'Pushed. Translating in the background '
          '(${pushed.trackingTokens.length} job(s)).'
          '${publish ? '' : " Run 'easyi18n pull' once it completes."}',
        );
      }
      // Without --publish there is no poll, so the real push's own response
      // is the last time these pairs are visible — pairs the background jobs
      // will NEVER deliver, so "run pull once it completes" must not stand
      // as the whole story (#752, review finding 1). With --publish the gate
      // below reports off the last poll instead, once, with the final list.
      if (!publish) {
        reportExhausted(_logger, pushed.exhaustedPairs,
            requireComplete: false);
      }
      PublishOutcome? published;
      if (publish) {
        published = await _waitFillAndPublish(
          client,
          projectId,
          units,
          langs,
          approvedOnly: approvedOnly,
          requireComplete: requireComplete,
          maxCreditsMc: maxCreditsMc,
          incompleteMode: _incompleteModeFor(config),
          meta: meta,
          requiredOutputFormat: adoption?.format,
        );
      }
      return _finish(
        0,
        report(pushed: pushed, published: published, lockfileWritten: true),
      );
    } on CliException catch (e) {
      final error = adoption?.annotate(e) ?? e;
      if (partial == null || !output.json) throw error;
      output.emitError(error, report: partial!.toJson());
      return error.exitCode;
    } on FileSystemException catch (e, stack) {
      final error = adoption?.created == true
          ? FileSystemException('${e.message}\n${adoption!.confirmedMessage}',
              e.path, e.osError)
          : e;
      if (partial == null || !output.json) {
        Error.throwWithStackTrace(error, stack);
      }
      final record = fileSystemError(error);
      output.emitError(record, report: partial!.toJson());
      return record.exitCode;
    } finally {
      client.close();
    }
  }

  /// Every successful exit goes through here so `--json` emits exactly one
  /// record, after the last text line and before the exit code.
  int _finish(int code, PushReport report) {
    if (output.json) output.emit(report.toJson());
    return code;
  }

  /// Says so when the local `mode:` and the dashboard's project mode
  /// disagree — they are set independently and never synced (#415), and until
  /// `/meta` carried the project mode this side could not see the other half.
  ///
  /// Only on `--publish`, because that is where the disagreement changes an
  /// outcome: an untranslated cell is either left out of the files (Mode A)
  /// or serves the source text. A null project mode is NOT a disagreement
  /// with a local `b` — undeclared already behaves as Mode B — but it IS one
  /// with a local `a`, because every other surface will publish source text
  /// into files the local config says are TMS-owned.
  void _warnOnModeDisagreement(Easyi18nConfig config, ProjectMeta? meta) {
    if (meta == null) return;
    final local = config.mode;
    final remote = meta.mode;
    if (local == 'a' && remote != 'a') {
      _logger.warn(
        'Mode mismatch: this checkout says Mode A (TMS) but the project is '
        "set to ${remote == null ? 'no mode' : 'Mode $remote'} in the "
        'dashboard. This push publishes with skip because the local config '
        'wins here, but a publish from the app — or any API call that omits '
        'incompleteMode — will bake source text into your files instead. Set '
        'the project to Mode A in Settings.',
      );
    } else if (local != 'a' && remote == 'a') {
      _logger.warn(
        'Mode mismatch: the project is set to Mode A (TMS) in the dashboard '
        'but this checkout does not say `mode: a`. Untranslated strings will '
        'be LEFT OUT of the published files rather than serving the source '
        'text. Add `mode: a` to easyi18n.yaml if that is what you want.',
      );
    }
  }

  /// Canonical locale form, mirroring the backend's `normalizeLocaleCode`
  /// (`easyi18n_core`, not a dependency here): trimmed, `_`→`-`, lowercase.
  /// Comparing without it rejects `pt_BR` for a project that has `pt-br` —
  /// a code the server would have accepted.
  static String _normalizeLocale(String raw) =>
      raw.trim().replaceAll('_', '-').toLowerCase();

  /// Catches a `--lang` that would translate nothing, BEFORE it costs a
  /// request.
  ///
  /// The server does NOT reject an unknown code: `_resolveTargetLangs`
  /// intersects the whitelist with the project's targets, so a typo is
  /// silently dropped and the run reports success having skipped it. That
  /// silence is the reason to check here. The two real server rejections are
  /// an intersection that comes out EMPTY (`400 no_target_langs` — including
  /// when only the base language was named, since the base is always
  /// dropped) and a manual language named explicitly (`400
  /// fill_mode_manual`).
  ///
  /// A null or empty catalogue means "unknown" — an older server, or a key
  /// without `read` — and validates nothing rather than inventing a
  /// rejection.
  void _checkRequestedLangs(List<String> langs, ProjectMeta? meta) {
    final catalogue = meta?.languages ?? const <ProjectLanguage>[];
    if (catalogue.isEmpty) return;

    final byCode = {for (final l in catalogue) _normalizeLocale(l.code): l};
    final targets = meta!.targets;
    final targetList =
        targets.isEmpty ? '(none)' : targets.map((l) => l.code).join(', ');

    if (langs.isNotEmpty) {
      final unknown = [
        for (final l in langs)
          if (!byCode.containsKey(_normalizeLocale(l))) l,
      ];
      if (unknown.isNotEmpty) {
        throw CliException(
          'Not a language on this project: ${unknown.join(', ')}.\n'
          'Configured targets: $targetList.\n'
          'The server would drop it silently and report success, so this '
          'would have translated nothing for it.',
        );
      }

      final named = [for (final l in langs) byCode[_normalizeLocale(l)]!];
      final namedTargets = [for (final l in named) if (!l.isBase) l];
      if (namedTargets.isEmpty) {
        throw CliException(
          'Only the base language was requested. The base is never a fill '
          'target, so the server has nothing to translate '
          '(400 no_target_langs).\n'
          'Configured targets: $targetList.',
        );
      }
      if (named.length != namedTargets.length) {
        _logger.warn(
          'Ignoring the base language — it is the source, never a fill '
          'target.',
        );
      }
      final manual = [for (final l in namedTargets) if (l.isManual) l.code];
      if (manual.isNotEmpty) {
        throw CliException(
          'Set to manual translation: ${manual.join(', ')}.\n'
          'The server refuses a run that names one explicitly '
          '(400 fill_mode_manual). Drop it from --lang, or switch it to AI '
          'fill in the dashboard.',
        );
      }
      return;
    }

    // Default set: a manual language is dropped rather than refused, so the
    // only failure a user would otherwise see is a translation that never
    // appears.
    final manual = [for (final l in targets) if (l.isManual) l.code];
    if (manual.isNotEmpty) {
      _logger.warn(
        'Skipping ${manual.join(', ')} — set to manual translation, so the '
        'fill leaves them to you.',
      );
    }
  }

  /// Waits for the fill, then publishes. A fill that leaves stragglers no
  /// longer blocks the publish: the missing cells resolve per the project's
  /// integration mode (Mode A skips them so the customer's files keep
  /// reporting what is untranslated; otherwise they serve the source text),
  /// so shipping the completed strings is strictly better than shipping
  /// nothing. `--require-complete` restores the old all-or-nothing behaviour.
  Future<PublishOutcome> _waitFillAndPublish(
    TranslationsApiClient client,
    String projectId,
    List<TranslateUnit> units,
    List<String> langs, {
    required bool approvedOnly,
    required bool requireComplete,
    int? maxCreditsMc,
    String? incompleteMode,
    ProjectMeta? meta,
    String? requiredOutputFormat,
  }) async {
    final lastPoll = await _publisher.waitForFill(
      client,
      projectId,
      units,
      langs,
      maxCreditsMc: maxCreditsMc,
      wait: _wait,
      onProgress: _presentFillProgress,
      now: DateTime.now,
    );
    final pending = lastPoll.unitsNeedingTranslation;
    if (pending > 0) {
      if (requireComplete) {
        throw CliException(
          '$pending string(s) did not translate after ${PublishRunner.maxFillRetries} '
          'retries. Nothing was published (--require-complete); re-run '
          "'easyi18n push --publish' to retry them.",
        );
      }
      // With the field omitted the SERVER resolves by the project's declared
      // mode. `/meta` now carries that mode, so say which way it goes; only
      // hedge when the mode is genuinely unknown (older server, or a key
      // without `read`).
      final skips = incompleteMode == 'skip' || meta?.publishSkipsIncomplete == true;
      final resolution = switch ((incompleteMode, meta)) {
        (_, _) when skips => 'they stay out of the published files so your '
            'tooling keeps reporting them',
        (_, final ProjectMeta _) => 'they serve the source text until filled',
        _ => "they resolve per the project's integration mode (source text "
            'for runtime-SDK projects, left out of the files for TMS)',
      };
      _logger.warn(
        '$pending string(s) are still untranslated - publishing anyway; '
        "$resolution. Re-run 'easyi18n push --publish' to retry them.",
      );
    }
    // Read off the LAST poll, not the preview: the run itself can burn a
    // pair's retry budget (#737), so the terminal state may only exist here.
    // Throws under --require-complete — it MUST come before the publish call,
    // or the refusal ships the very version it refuses (#752).
    reportExhausted(_logger, lastPoll.exhaustedPairs,
        requireComplete: requireComplete);
    return _publish(client, projectId, approvedOnly,
        incompleteMode: incompleteMode,
        requiredOutputFormat: requiredOutputFormat);
  }

  void _presentFillProgress(FillProgress progress, int pending, int retry) {
    switch (progress) {
      case FillProgress.complete:
        _logger.info('Fill complete.');
      case FillProgress.retrying:
        _logger.warn(
          '$pending string(s) failed to translate - '
          're-queueing them ($retry of '
          '${PublishRunner.maxFillRetries} retries)...',
        );
      case FillProgress.timedOut:
        _logger.warn(
          'The fill did not complete within '
          '${PublishRunner.pollTimeout.inMinutes} minutes.',
        );
      case FillProgress.waiting:
        _logger.info('Waiting for the AI fill to complete...');
      case FillProgress.pending:
        _logger.detail('$pending string(s) pending...');
    }
  }

  /// A Mode A yaml says `skip` explicitly: the local `mode:` is not synced
  /// with the dashboard's `Project.mode`, so trusting the server-side default
  /// would silently bake source text whenever only the yaml declares TMS.
  /// Anything else omits the field and lets the server resolve it from the
  /// project's declared mode (#415).
  static String? _incompleteModeFor(Easyi18nConfig config) =>
      config.mode == 'a' ? 'skip' : null;

  Future<PublishOutcome> _publish(
    TranslationsApiClient client,
    String projectId,
    bool approvedOnly, {
    String? incompleteMode,
    String? requiredOutputFormat,
  }) async {
    final outcome = await _publisher.publish(
      client,
      projectId,
      approvedOnly: approvedOnly,
      incompleteMode: incompleteMode,
      requiredOutputFormat: requiredOutputFormat,
    );
    // The itemized rows below are warnings (stderr). The count rides on the
    // success line so a log that captured stdout alone cannot read the
    // publish as clean — that blindness is the bug (#609).
    final refused = outcome.icuRejectedTotal + outcome.markupRejectedTotal;
    // `cell(s)`, not `translation(s)` or `value(s)` (#1175). The two
    // counters this sums are minted per CELL, and since #1000 a row can name
    // the BASE language — where the refused value is the stored source, not
    // a translation, and where the repair is a `strings/{hash}` document.
    //
    // #671's rule (count a base-language row apart and call it a `source`) is
    // not applied here, and the reason is measurable rather than aesthetic:
    // this number is the SERVER's total, which exceeds the listed entries
    // once the 50-row cap bites, so a client-side split would put a label on
    // rows it cannot see. `cell(s)` is the one noun true of both natures, and
    // it is the noun `rollback` already prints for the same two counters.
    _logger.info(
      'Published ${outcome.versionId} (${outcome.keyCount} key(s))'
      '${refused == 0 ? '' : ' — $refused cell(s) refused by a gate, '
          'see the warnings'}. '
      'Live via delivery within one poll interval.',
    );
    // A gate refused these cells — they shipped the incomplete-mode fallback
    // instead. Warn (not fail): the publish itself succeeded, and a version
    // that is missing some cells is still a version (`ci-sync.md` §8).
    // Two lists, two blocks: same consequence, different remedy (#609).
    _warnRejected(
      outcome.icuRejected,
      outcome.icuRejectedTotal,
      'failed ICU validation',
    );
    _warnRejected(
      outcome.markupRejected,
      outcome.markupRejectedTotal,
      "lost the source's markup structure",
    );
    return outcome;
  }

  /// One rejection block. [total] is the server's count, which exceeds
  /// [entries] once the response hit the 50-row cap — reporting `entries
  /// .length` there would under-report the damage on the worst publishes.
  ///
  /// The heading says "cell(s)" and stops at "did not reach the version" on
  /// purpose: since #1000 a row can name the BASE language, where the refused
  /// value is the stored source and not a translation, and where no fallback
  /// runs in either incomplete mode (the base cell is simply absent).
  ///
  /// `cell(s)` rather than `value(s)` since #1175: [total] is the server's
  /// count and exceeds [entries] under the 50-row cap, so the noun has to be
  /// true of rows this side cannot read. It is what `rollback` prints for the
  /// same two counters.
  void _warnRejected(List<String> entries, int total, String what) {
    if (entries.isEmpty) return;
    _logger.warn(
      '$total cell(s) $what and did not reach the published version:',
    );
    for (final entry in entries) {
      _logger.warn('  $entry');
    }
    final hidden = total - entries.length;
    if (hidden > 0) {
      _logger.warn('  ...and $hidden more the server did not list.');
    }
  }

  /// `--max-credits` is given in credits; the API speaks millicredits.
  int? _parseMaxCredits(String? raw) {
    try {
      return parseCreditsToMc(raw);
    } on FormatException {
      throw CliException(
        '--max-credits must be a non-negative number of credits.',
      );
    }
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);

  static bool _stdinConfirm(String prompt, CliLogger logger) {
    if (!stdin.hasTerminal) {
      logger.warn(
        'No terminal to confirm on; pass --yes to push non-interactively.',
      );
      return false;
    }
    stdout.write(prompt);
    final line = stdin.readLineSync()?.trim().toLowerCase();
    return line == 'y' || line == 'yes';
  }
}
