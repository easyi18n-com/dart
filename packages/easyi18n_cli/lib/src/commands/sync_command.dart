import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../cli_output.dart';
import '../config.dart';
import '../credits.dart';
import '../exceptions.dart';
import '../fill_completeness.dart';
import '../logger.dart';
import '../output_format.dart';
import '../resolve.dart';
import '../security.dart';
import '../sync_runner.dart';

/// Builds the API client `sync` talks to (same seam as pull/push).
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// `easyi18n sync` — the file-first CI loop (`docs/specs/ci-sync.md` §4):
/// upload the local catalog (`catalog:` in `easyi18n.yaml`), let the server
/// diff/apply/fill, wait for the fill, publish with `skipIfIdentical`, and
/// write the translated catalog back onto the same path. With `source:` the
/// upload is the base-language file of a per-locale project, and the
/// write-back is every other locale's file in `output:`. Exit 0 on success;
/// whether anything changed is git's diff to judge (the Action opens a PR
/// only when the working tree moved).
///
/// Under `--json` a failure after the first answered POST carries the report
/// beside `error`: the catalog was applied, and possibly published, before
/// it (#1835).
class SyncCommand extends Command<int>
    with JsonPresenter
    implements SyncRunProgress {
  SyncCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
    bool Function(String prompt)? confirm,
    Future<void> Function(Duration)? wait,
    Duration? pollTimeout,
    Random? random,
  }) : _apiClientFactory = apiClientFactory ?? _defaultFactory,
       _environment = environment ?? Platform.environment,
       _confirm = confirm ?? ((prompt) => _stdinConfirm(prompt, output.logger)),
       _wait = wait ?? Future<void>.delayed,
       _pollTimeout = pollTimeout ?? _defaultPollTimeout,
       _random = random ?? Random() {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with the translate + publish + read scopes. '
            'Defaults to \$EASYI18N_TOKEN.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Classify and price the sync without writing anything.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip the confirmation prompt (CI).',
      )
      ..addOption(
        'max-credits',
        help: 'Abort if the estimated cost exceeds this many credits.',
      )
      ..addFlag(
        'no-publish',
        negatable: false,
        help: 'Upload and fill, but do not publish or pull the result back.',
      )
      ..addFlag(
        'require-complete',
        negatable: false,
        help: 'Fail when any (key, language) pair could not be translated '
            '(including exhausted pairs that need dashboard attention).',
      )
      ..addOption(
        'on-conflict',
        allowed: ['server', 'file'],
        defaultsTo: 'server',
        help: 'What to do when the catalog carries an older text than the '
            'project: a translation it edited, AI-filled or signed off, or '
            '(when the pull is dated) a SOURCE it corrected, after the '
            'catalog was pulled. "server" keeps the project\'s and reports '
            'the row; "file" imports the catalog\'s over it — including '
            'over a source correction.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace a locale file that changed since the pull that wrote '
            'it. Without it such a file stops the sync before it uploads.',
      );
  }

  static const SyncRunner _runner = SyncRunner();

  static const String tokenEnvVar = 'EASYI18N_TOKEN';
  static const Duration _defaultPollTimeout = Duration(minutes: 10);

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final ApiClientFactory _apiClientFactory;
  final Map<String, String> _environment;
  final bool Function(String prompt) _confirm;
  final Future<void> Function(Duration) _wait;

  /// Injectable so a test can pin the jitter; the retries themselves are
  /// asserted on the durations asked of [_wait].
  final Random _random;

  /// Injectable for the same reason [_wait] is: the give-up branch is
  /// reachable in a test only if the deadline can be brought forward.
  final Duration _pollTimeout;

  /// Every POST of this run the server answered: each applied the catalog.
  final _answered = <SyncResult>[];

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Sync the local translation catalog: upload, translate what changed, '
      'publish, and write the result back.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);
    final dryRun = results['dry-run'] as bool;
    final yes = results['yes'] as bool;
    final noPublish = _noPublish = results['no-publish'] as bool;
    final requireComplete = results['require-complete'] as bool;
    final onConflict = results['on-conflict'] as String;
    final maxCreditsMc = parseCreditsToMc(results['max-credits'] as String?);

    final force = results['force'] as bool;
    final scan = _runner.scan(config, configPath: configPath, force: force);
    // `catalog:` lands ONE served file on the scanned path, and `PullRunner`
    // refuses a per-locale format there — after the fill was charged and the
    // version published. Refused here, before any request.
    if (!dryRun &&
        !scan.perLocale &&
        !Easyi18nConfig.catalogFormats.contains(config.format)) {
      throw CliException(
        '`catalog:` names one file holding every language, but format '
        '"${config.format}" renders one file per locale, so `easyi18n sync` '
        'could not write it back. Name the base-language file with `source:` '
        'instead: the other locales are written into `output:`. Nothing was '
        'uploaded or charged.',
        code: 'format_not_writable',
      );
    }

    final token =
        (results['token'] as String?)?.trim() ??
        _environment[tokenEnvVar]?.trim();
    if (token == null || token.isEmpty) {
      throw CliException(
        'No API key. Pass --token or set $tokenEnvVar (an eik_ key with the '
        'translate, publish and read scopes).',
      );
    }
    warnOnUntrustedTarget(config.baseUrl, _logger);
    final client = _apiClientFactory(baseUrl: config.baseUrl, token: token);
    final adoption = noPublish ? null : OutputFormatAdoption(config.format);
    // Set when the run returns and again at the publish, so a failure after
    // either still reports what the run did.
    SyncReport? partial;
    try {
      final projectId = await resolveProjectId(config, client, logger: _logger);
      await adoption?.preflight(client, projectId);

      // ---- preview (always): the dry-run is the cost gate -----------------
      final previewed = await _runner.preview(
        client,
        projectId,
        scan,
        config: config,
        configPath: configPath,
        onConflict: onConflict,
      );
      final preview = previewed.result;
      for (final skipped in previewed.skippedTargets) {
        _logger.warn('Not uploading $skipped.');
      }
      // BEFORE the estimate, on purpose: `_report` is the line that carries
      // "~N credits to translate", and a set the operator only learns about
      // afterwards cannot be checked against what they intended to buy (#592).
      final namedUnconfigured =
          _reportLanguages(preview, perLocale: scan.perLocale);
      // After the language report (which records the rows it renders) and
      // BEFORE the estimate, for the same reason as `_reportLanguages`: a
      // catalog that lost a plural branch on the way in is something to see
      // while the credits are still a question.
      //
      // Reported off every response, exactly like `_warnConflicts` and for the
      // same reason (#550): the parse rows are a function of the bytes and do
      // repeat, but `PLURAL_BEHIND_PROJECT` is not — the server derives it
      // from the STORED plural, so a dashboard edit landing while the operator
      // answers the credit prompt produces a row the preview could not have.
      // Each row is announced once; the printer records what it prints.
      _warnParseDiagnostics(preview);
      _report(preview);
      // The preview classifies exactly what the real run will, and the
      // retries below re-POST the same catalog — so the per-pair report is
      // printed once, here, where `--dry-run` sees it too (#550).
      _warnConflicts(preview);
      if (preview.wouldExceedKeyCap) {
        throw CliException(
          "Creating ${preview.created} new key(s) would exceed the plan's "
          'key cap. Upgrade the workspace or trim the catalog.',
        );
      }
      // A `CliException`, not a bare `return 1`: the executable renders it
      // as the same `error:` line on stderr with the same exit code, and it
      // is the only shape `--json` can serve to a consumer (`push` refuses
      // the identical case the identical way).
      if (maxCreditsMc != null && preview.estimatedCredits > maxCreditsMc) {
        throw CliException(
          'Estimated cost ${formatCredits(preview.estimatedCredits)} credits '
          'exceeds --max-credits ${formatCredits(maxCreditsMc)}.',
          code: 'budget_exceeded',
        );
      }
      SyncReport report({
        SyncOutcome? outcome,
        List<SyncResult> answered = const [],
        SyncDelivery? delivery,
      }) => SyncReport(
            preview: previewed,
            dryRun: dryRun,
            outcome: outcome,
            answered: answered,
            delivery: delivery,
            outputFormat: adoption?.toJson(),
          );
      if (dryRun) {
        if (adoption?.state == OutputFormatState.wouldAdopt) {
          _logger.info('Dry run: output format "${config.format}" would be '
              'adopted conditionally after consent in a real run.');
        }
        // The preview carries the same completeness inputs the real run
        // refuses on (`exhausted` rows and `pendingSkipped`), so it reports
        // them the same way (#955): warn, or refuse under `--require-complete`.
        // A dry run used as a cheap CI gate must go red on the state the real
        // run refuses, not exit 0 over it. What the preview cannot see is
        // what only a fill decides (a job stopping short); that stays the
        // real run's call. Same order as the real run, and before the
        // affordability exit — both are non-zero, the pairs get named first.
        reportExhausted(_logger, preview.exhaustedPairs,
            requireComplete: requireComplete);
        // No job of ours has run yet, so the held pairs are never "maybe
        // ours".
        _reportPendingSkipped(preview.pendingSkipped,
            requireComplete: requireComplete, maybeOurs: false);
        return _finish(preview.accepted ? 0 : 1, report());
      }
      if (preview.estimatedCredits > 0 && !yes) {
        // JSON is a wire, not a person: nothing on it can answer a prompt,
        // and an injected `confirm` is not consent either. Refuse loudly
        // rather than exit 0 having spent nothing — an agent keys on the
        // exit code (same contract as `push`).
        if (output.json) {
          throw CliException(
            'Refusing to spend '
            '~${formatCredits(preview.estimatedCredits)} credit(s) without '
            '--yes under --json. Re-run with --yes to consent, or --dry-run '
            'to preview only.',
            code: 'confirmation_required',
          );
        }
        final ok = _confirm(
          'Translate for ~${formatCredits(preview.estimatedCredits)} credits '
          '(available ${formatCredits(preview.spendable)})? [y/N] ',
        );
        if (!ok) {
          _logger.info('Aborted.');
          return 1;
        }
      }

      await adoption?.apply(client, projectId, _logger);

      // ---- real sync, contended retries and the fill wait -----------------
      final SyncOutcome outcome;
      try {
        outcome = await _runner.run(
          client,
          projectId,
          previewed,
          config: config,
          onConflict: onConflict,
          progress: this,
          wait: _wait,
          random: _random,
          pollTimeout: _pollTimeout,
        );
      } on CliException {
        // The run never settled, but the POSTs it had answered applied the
        // catalog; before the first one there is nothing to report.
        if (_answered.isNotEmpty) partial = report(answered: [..._answered]);
        rethrow;
      }
      partial = report(outcome: outcome);
      final result = outcome.result;
      final stoppedShort = outcome.stoppedShort;

      // The decision (refuse vs warn, and the wording) is shared with `push`
      // (#752); only the decode is this route's own — `/v1/sync` reports
      // `[{key, lang}]` rows where `/v1/translate` reports per-unit langs.
      reportExhausted(_logger, result.exhaustedPairs,
          requireComplete: requireComplete);
      // Pairs whose marker says another fill already owns them. This run did
      // not queue them and was not charged for them, so it cannot say they
      // were translated — and if the job that owns the marker never existed,
      // nothing ever will (#591): the route reports them precisely because a
      // run with nothing left to queue answers `trackingToken: null` and the
      // wait loop above never even starts.
      //
      // "A fill this run does not own" stops being true once this run has
      // drained jobs of its own: the re-post that reported the count saw
      // THEIR markers as in-flight, and by now they have finished. Which
      // pairs those were is not in the response, so the count cannot be
      // corrected — only the sentence, which must not name a cause it can no
      // longer stand behind. The exit code is unchanged: refusing to publish
      // as complete when the count may be stale is the safe direction.
      _reportPendingSkipped(result.pendingSkipped,
          requireComplete: requireComplete,
          maybeOurs: outcome.drainedOwnJobs);
      // Before the publish and the pull, like the milder shortfall below:
      // under this flag the run must not mint a version and overwrite the
      // catalog with what it already knows is short.
      if (requireComplete && stoppedShort != null) {
        throw CliException(
          _stoppedShortMessage(stoppedShort, published: false),
        );
      }
      if (requireComplete && outcome.stillIncomplete) {
        throw CliException(
          'Some pairs are still untranslated (--require-complete).',
        );
      }

      if (noPublish) {
        // A kept value only reaches the catalog through the publish + pull
        // this flag skips, so the same conflicts will re-report on every run
        // until a full sync (or a pull of a fresh publish) closes the loop.
        final kept =
            result.conflicts.where((c) => c['resolution'] == 'kept').toList();
        // Counted apart for the same reason the rows above are worded apart
        // (#671): a base-language row is a SOURCE, and folding it into
        // "value(s)" sends the operator to the wrong column of the editor.
        final keptSources = result.baseCode.isEmpty
            ? 0
            : kept.where((c) => c['lang'] == result.baseCode).length;
        final what = switch ((kept.length - keptSources, keptSources)) {
          (0, _) => '$keptSources kept source(s)',
          (_, 0) => '${kept.length} kept value(s)',
          (final v, final s) => '$v kept value(s) and $s kept source(s)',
        };
        if (kept.isNotEmpty) {
          _logger.warn(
            '$what stay server-side only: --no-publish skips '
            'the publish and the pull that would bring them into the '
            'catalog, so the same conflict(s) will report again on the '
            'next run.',
          );
        }
        _logger.info('Skipping publish (--no-publish).');
        if (stoppedShort == null) return _finish(0, report(outcome: outcome));
        _logger.error(_stoppedShortMessage(stoppedShort, published: false));
        return _finish(1, report(outcome: outcome));
      }

      // ---- publish + pull, through the runner -----------------------------
      var delivery = await _runner.deliver(
        client,
        projectId,
        scan,
        config: config,
        configPath: configPath,
        logger: _logger,
        force: force,
        onPublished: (published) {
          _reportPublished(published);
          partial = report(
            outcome: outcome,
            delivery: SyncDelivery(published: published, pulledVersion: null),
          );
        },
      );
      // BEFORE the `stoppedShort` return, not after: a fill that ran out of
      // credits is the single most likely run to leave a configured language
      // out of the catalog, so putting this check behind that `return 1` would
      // kill it in exactly the case that motivates it (#592).
      //
      // A per-locale write-back leaves no catalog to read back, and
      // `languages` stays null rather than say it found no gap.
      if (!scan.perLocale) {
        final gaps = SyncRunner.verifyCatalogLanguages(
          scan.files,
          result,
          namedUnconfigured,
        );
        delivery = delivery.withLanguages(gaps);
        _reportLanguageGaps(gaps);
      }
      // Whatever DID translate is published and written — the run is not
      // discarded. But it exits non-zero: this catalog is not the translated
      // one, and a green job is what let the gap ship unnoticed for a whole
      // session (#602). Same condition the hold already refuses up front with
      // `insufficient_credits`, just reached mid-run.
      if (stoppedShort != null) {
        _logger.error(_stoppedShortMessage(stoppedShort, published: true));
        return _finish(1, report(outcome: outcome, delivery: delivery));
      }
      _logger.info('Sync complete (version ${delivery.pulledVersion}).');
      return _finish(0, report(outcome: outcome, delivery: delivery));
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

  /// Why a run that ended early is an error, in the words of the state that
  /// ended it. [published] is false under `--no-publish`, where nothing was
  /// written back at all.
  static String _stoppedShortMessage(JobSummary s, {required bool published}) {
    final left = s.pending + s.failed;
    final pairs = '$left pair(s)';
    final wrote = published
        ? 'the catalog written back does not contain them'
        : 'nothing was published or written back';
    return switch (s.status) {
      'aborted_no_credits' =>
        'The workspace ran out of credits while translating: $pairs were left '
            'untranslated and $wrote. Top up the balance and re-run this job.',
      'cancelled' =>
        'The translation job was cancelled with $pairs untranslated, and '
            '$wrote. Re-run this job.',
      'failed' =>
        'The translation job failed with $pairs untranslated, and $wrote. '
            'Re-run this job; the pairs it did translate are kept.',
      _ =>
        'The translation job ended as "${s.status}" with $pairs untranslated, '
            'and $wrote. Re-run this job.',
    };
  }

  /// The language set this run is about to work on, and both directions in
  /// which it disagrees with the catalog — printed BEFORE the credit estimate
  /// so the number can be checked against the intent (#592).
  ///
  /// One line per kind, never one per locale: a project whose file carries
  /// four extra locales would otherwise print four permanent lines on every CI
  /// run, and a warning that fires every time is one the operator stops
  /// reading. Each line names the remedy, because "these disagree" without
  /// "here is what to do" is a fact, not a report.
  /// Returns the locales it named as carried-but-unconfigured, folded, so the
  /// post-pull check can skip them: the written catalog still carries every
  /// one of them (the merge never deletes), so without this the same locale
  /// gets two warnings on every run — and the second would tell the operator
  /// something slightly different from the first.
  Set<String> _reportLanguages(SyncResult r, {required bool perLocale}) {
    // `baseCode` is the field that says the server told us what this project
    // is configured for. `targetLangs` cannot stand in for it: an EMPTY
    // `targetLangs` is a project whose only language is the base, not an old
    // server — and gating on it silenced, on exactly that project, the
    // `LANG_NOT_CONFIGURED` line naming #592's own `zh` and `pt-BR`.
    if (r.baseCode.isEmpty) return const {};
    if (r.targetLangs.isNotEmpty) {
      _logger.info(
        'Target languages (${r.targetLangs.length}): '
        '${r.targetLangs.join(', ')}',
      );
    }
    List<String> codes(String code) => [
      for (final d in r.diagnostics)
        if (d['code'] == code && d['field'] is String)
          _renderedRow(d),
    ];

    // The near-miss is the whole point: a project spelling a language one way
    // and a catalog spelling it another pays to re-translate text the file
    // already holds. Which spelling is right is not ours to decide (#681).
    //
    // Rendered ON the code it belongs to, never pooled across the line: the
    // backend answers `alsoSpelled` per row, and flattening two rows into one
    // set told an operator who configured `zh-hans` (near-miss `zh`) and
    // `es-ar` (no near-miss) that their catalog might spell `es-ar` as `zh`.
    final notInFile = [
      for (final d in r.diagnostics)
        if (d['code'] == 'LANG_NOT_IN_FILE' && d['field'] is String)
          (
            code: _renderedRow(d),
            also: <String>[
              for (final s in _rowList(d['alsoSpelled']))
                if (s is String) s,
            ],
            // What the plan holds for this language (#744). Only the number
            // zero means "nothing": a server that predates the field sends
            // none, and that row keeps the line it always had.
            planned: d['plannedPairs'] != 0,
          ),
    ];
    String rendered(Iterable<({String code, List<String> also, bool planned})>
            rows) =>
        [
          for (final e in rows)
            if (e.also.isEmpty)
              e.code
            else
              '${e.code} (your catalog spells it '
                  "${e.also.map((s) => "'$s'").join(', ')})",
        ].join(', ');
    const disagree = ' Where a spelling is named, the project and the file '
        'disagree about that one language, and re-spelling either side is '
        'your call';
    // Neither line is for a per-locale base file: it carries no other
    // language by design, so every target would be reported on every run.
    // The rows are still recorded above, or the generic printer names them.
    final planned = notInFile.where((e) => e.planned);
    if (!perLocale && planned.isNotEmpty) {
      _logger.warn(
        'Not in your catalog: ${rendered(planned)} — these will be '
        'translated from scratch and are part of the estimate below.'
        '${planned.every((e) => e.also.isEmpty) ? '' : '$disagree — fix it '
            'before paying to translate what the file already has.'}',
      );
    }
    // The project and the catalog still differ on these, which the operator
    // wants to know either way; what the line must not do is count them into
    // an estimate that prices them at zero. Not "the project already holds
    // them": zero planned pairs is also what pairs held by another fill,
    // exhausted ones and unverified sources look like, and each of those has
    // its own line.
    final held = notInFile.where((e) => !e.planned);
    if (!perLocale && held.isNotEmpty) {
      _logger.info(
        'Not in your catalog: ${rendered(held)} — this run has nothing to '
        'translate for these and they are not part of the estimate below.'
        '${held.every((e) => e.also.isEmpty) ? '' : '$disagree.'}',
      );
    }
    final notConfigured = codes('LANG_NOT_CONFIGURED');
    if (notConfigured.isNotEmpty) {
      _logger.warn(
        'Your catalog carries locales the project does not configure: '
        '${notConfigured.join(', ')} — this run ignores them and leaves them '
        'exactly as they are. Add the language to the project, or delete it '
        'from the catalog.',
      );
    }
    final manual = codes('LANG_NOT_FILLABLE');
    if (manual.isNotEmpty) {
      _logger.info(
        'Manual fill, not translated by this run: ${manual.join(', ')}.',
      );
    }
    return {for (final l in notConfigured) SyncRunner.foldLocale(l)};
  }

  /// The decision on pairs held by another fill, shared by the preview and
  /// the real run (#955): refuse under `--require-complete`, warn otherwise.
  /// [maybeOurs] is the real run's nuance — jobs this run finished may
  /// account for the count — and is never true on a preview.
  void _reportPendingSkipped(
    int n, {
    required bool requireComplete,
    required bool maybeOurs,
  }) {
    if (n <= 0) return;
    final pairs = 'pair${n == 1 ? '' : 's'}';
    if (requireComplete) {
      throw CliException(
        maybeOurs
            ? '$n $pairs were reported as held by another fill, and this '
                'run also finished jobs of its own that could account for '
                'them — it cannot confirm they were translated '
                '(--require-complete). Re-run to settle it.'
            : '$n $pairs are held by a fill this run does not own, so it '
                'cannot confirm they were translated (--require-complete). '
                'Re-run once that job has finished; if it never does, '
                're-translate them from the dashboard.',
      );
    }
    _logger.warn(
      maybeOurs
          ? '$n $pairs were reported as held by another fill; jobs this '
              'run finished may already cover them. The next run reports '
              'what is really left.'
          : '$n $pairs are already being filled by another run, so this '
              'sync skipped them and the published version leaves those '
              'cells out. A later sync picks them up once that job '
              'finishes.',
    );
  }

  void _report(SyncResult r) {
    _logger.info(
      '${r.dryRun ? 'Would sync' : 'Synced'}: ${r.created} new, '
      '${r.updatedSources} updated, ${r.matchedSources} unchanged source(s); '
      '${r.updatedTranslations} translation(s) imported'
      '${r.disabledOrphans > 0 ? '; ${r.disabledOrphans} orphan(s) disabled' : ''}'
      '${r.reenabled > 0 ? '; ${r.reenabled} re-enabled' : ''}'
      '${r.notInCode > 0 ? '; ${r.notInCode} no longer in your code' : ''}'
      '${r.skippedGated > 0 ? '; ${r.skippedGated} awaiting source review' : ''}'
      '${r.conflicts.isNotEmpty ? '; ${_conflictSummary(r)}' : ''}'
      '${r.estimatedCredits > 0 ? ' — ~${formatCredits(r.estimatedCredits)} credits to translate' : ''}',
    );
  }

  /// Counts each row's actual `resolution` — never the policy: a patch that
  /// fails mid-apply flips its row to `kept` even under `--on-conflict file`,
  /// and a policy-derived verb would report an overwrite that never landed.
  ///
  /// The breakdown is only spelled out while the rows are ALL of them. Past
  /// the server's cap the listed rows are a sample, and splitting a sample
  /// into "N overwritten, M kept" states two numbers that are simply wrong —
  /// so the total (which stays exact) is reported on its own.
  static String _conflictSummary(SyncResult r) {
    if (r.conflicts.length < r.conflictsTotal) {
      return '${r.conflictsTotal} conflict(s) — first ${r.conflicts.length} '
          'listed';
    }
    final overwritten =
        r.conflicts.where((c) => c['resolution'] == 'overwritten').length;
    final kept = r.conflicts.length - overwritten;
    final parts = [
      if (overwritten > 0) '$overwritten overwritten',
      if (kept > 0) '$kept kept on the server',
    ];
    return '${r.conflictsTotal} conflict(s): ${parts.join(', ')}';
  }

  /// What `--no-publish` makes true for this run, so the transcript this
  /// command renders for [SyncRunProgress] can name the right consequence.
  /// Set once, before the runner is handed the presenter.
  bool _noPublish = false;

  /// Rows already printed, keyed by (key, lang, resolution). The preview and
  /// every real POST are reported through the same door, and each row is
  /// announced once — printing off the preview ALONE dropped any conflict
  /// that first appeared in the real run (a dashboard edit landing while the
  /// operator answers the credit prompt, or during the retries, which run up
  /// to ~30 min after the preview). Under the default policy nothing else
  /// reads the real run's rows, so that pair was refused and never mentioned.
  final _reportedConflicts = <String>{};

  /// Diagnostic rows some other line already rendered, keyed by (code, field)
  /// — recorded by [_reportLanguages] as it prints, so
  /// [_warnParseDiagnostics] can print the REST without repeating it. Keyed by
  /// the row and not by the code because the language report groups on
  /// `field`: a row of the same family arriving without one is a row it drops,
  /// and skipping it here on its code alone would put it back where this
  /// found it — printed nowhere.
  final _renderedDiagnosticRows = <String>{};

  /// Marks a row as printed and returns its field, so a comprehension that
  /// renders a row records it in the same breath.
  String _renderedRow(Map<String, Object?> d) {
    _renderedDiagnosticRows.add(_diagnosticRowKey(
      d['code'] as String,
      d['field'],
      d['message'],
      d['lang'],
    ));
    return d['field']! as String;
  }

  /// A list-shaped field off a `/v1/sync` row, TESTED and never cast.
  ///
  /// `api_client` hands these rows over deliberately untyped (it filters only
  /// `is Map`), so every read here is on raw server data. The `as List?` this
  /// replaced was the last site in the CLI where a well-formed 200 still died
  /// with an uncaught `TypeError`: `alsoSpelled` answered as a string killed
  /// `sync` at exit 255, in the preview, before the credit prompt (#972).
  static List<Object?> _rowList(Object? value) =>
      value is List ? value : const [];

  /// A row's identity for the already-printed set: code, field, message AND
  /// language.
  ///
  /// The message is part of the identity even when there is a field, because
  /// one field is not one row. `PLURAL_BEHIND_PROJECT` — the code this report
  /// runs off every response FOR — is emitted per `(key, lang)` with the KEY
  /// as its field, so a key behind in `es` and later in `fr` produces two rows
  /// under one field. Keyed on the field alone, the `fr` row that only the
  /// real run can carry was discarded against the preview's `es` row and
  /// printed nowhere at all — not even counted, since the discard runs before
  /// the count. Zero times, where the spec promises once.
  ///
  /// `lang` is the same argument one level down (#726): a parse finding is
  /// raised per language pass and carries the pass that raised it, so two
  /// languages losing the same string produce two rows that agree on all
  /// three other components. Without it the second is discarded against the
  /// first — the fold the server stopped doing, done again here.
  static String _diagnosticRowKey(
    String code,
    Object? field,
    Object? message,
    Object? lang,
  ) => '$code\u0000$field\u0000$message\u0000$lang';

  /// Every `diagnostics[]` row no other line renders.
  ///
  /// The server forwards the parsers' diagnostics verbatim, and the CLI read
  /// exactly three codes out of that list ([_reportLanguages]) and dropped the
  /// rest: `SKIPPED_NON_STRING`, `EMPTY_PLURAL_FORM`, `DUPLICATE_PLURAL_FORM`,
  /// `PLURAL_SHAPE_MISMATCH` — every one of them names something the import
  /// LOST out of the operator's own file, and not one of them printed. The
  /// dashboard has shown them in its import report all along; `easyi18n sync`
  /// paid for them on the wire and threw them away (#731).
  ///
  /// One line per CODE, never per row: these are per-entry, so a catalog with
  /// 500 non-string leaves would otherwise bury the report it belongs to. The
  /// first row's message carries the explanation and the rest of the group is
  /// named by field, capped, because a name is what lets someone find the
  /// string.
  ///
  /// Grouped by (code, message SHAPE), not by code alone. "One wording per
  /// code" is false and the parsers make it false: `DUPLICATE_PLURAL_FORM`
  /// names its selector and `EMPTY_PLURAL_FORM` its category, so a group whose
  /// head speaks for every row would say `also on: b` under a message about
  /// `a`'s `one` when what `b` lost was `few`. The shape is the row's message
  /// with its own field blanked out, which is exactly the attribute `also on:`
  /// puts back — so a code whose message varies ONLY by field still prints the
  /// one line it printed before, and a code that varies by anything else
  /// prints one line per thing it varies by, up to the cap and then one
  /// message-less overflow line ([_overflowKey]).
  ///
  /// Warn, never fail: the entries that did parse were imported, and what to
  /// do about a lossy catalog is the operator's call. `--require-complete` is
  /// the flag for CI that wants red.
  void _warnParseDiagnostics(SyncResult r) {
    // Insertion-ordered, so the lines come out in the order the server sent
    // the first row of each group.
    final groups = <String, List<Map<String, Object?>>>{};
    final codeOf = <String, String>{};
    final shapesPerCode = <String, int>{};
    for (final d in r.diagnostics) {
      final code = d['code'];
      if (code is! String || code.isEmpty) continue;
      if (_renderedDiagnosticRows
          .contains(_diagnosticRowKey(
              code, d['field'], d['message'], d['lang']))) {
        continue;
      }
      var key = '$code\u0000${_messageShape(d['message'], d['field'])}';
      if (!groups.containsKey(key)) {
        // The shape space is not bounded by the CLDR categories: an `=N`
        // literal selector can take any value, so a catalog duplicating two
        // hundred of them would print two hundred lines. Past the cap the
        // rows fold into ONE overflow line per code — which borrows no
        // message. Folding them into another shape's line instead made that
        // line speak for a row it does not describe: since #878 one code
        // carries two CONSEQUENCES, so the sixth shape was told to an
        // operator as "kept the last and dropped the rest" while the value
        // was in fact stored intact
        // (`feedback_a_grouped_line_speaks_only_for_its_group_key`).
        final seen = shapesPerCode[code] ?? 0;
        if (seen >= _maxNamedDiagnosticFields) {
          key = _overflowKey(code);
        } else {
          shapesPerCode[code] = seen + 1;
        }
      }
      codeOf[key] = code;
      (groups[key] ??= []).add(d);
    }
    for (final entry in groups.entries) {
      final code = codeOf[entry.key]!;
      final rows = entry.value;
      // The overflow line describes no row, so it must not quote one. It names
      // keys off EVERY row in the bucket, the head's included — but the tail
      // is capped exactly like any other line's, so `also on:` is a sample
      // with a count, never the full set.
      //
      // For the same reason the head says only how many rows there are. "each
      // with its own message" was an assertion about rows this line declares
      // it does not describe, and a false one: every row of a shape past the
      // cap lands here, so the bucket can hold fifty rows carrying one wording
      // between them.
      final overflow = entry.key == _overflowKey(code);
      final message = overflow ? null : rows.first['message'];
      final headIsMessage = message is String && message.trim().isNotEmpty;
      final head = headIsMessage
          ? '${message.trim()} [$code]'
          : overflow
              ? '$code: ${rows.length} further row(s) under this code.'
              : '$code: the server reported ${rows.length} row(s).';
      // Each field once, and never the head's own: a code repeats on ONE key
      // whenever the value carries two faults of the same kind (a plural that
      // duplicates `one` AND `few`), and naming that key beside its own
      // message read as a second key carrying the first one's fault.
      final headField = overflow ? null : rows.first['field'];
      final others = <String>[];
      for (final d in (overflow ? rows : rows.skip(1))) {
        final f = d['field'];
        if (f is! String || f == headField || others.contains(f)) continue;
        others.add(f);
      }
      final named = others.take(_maxNamedDiagnosticFields).toList();
      final hidden = others.length - named.length;
      // Which language passes raised it (#726). The server names the pass on
      // every row a TARGET pass produced; the base parse's rows and the
      // membership rows carry no `lang` and print exactly the line they
      // always printed.
      //
      // It goes on the line rather than into the group key on purpose: the
      // wording is identical across languages, so keying by language would
      // print the same sentence once per column — the shape `also on:` exists
      // to avoid. Named EVERY row's language, the head's included, because
      // unlike a field a language is nowhere else on the line.
      final langs = <String>[];
      for (final d in rows) {
        final l = d['lang'];
        if (l is! String || l.isEmpty || langs.contains(l)) continue;
        langs.add(l);
      }
      final namedLangs = langs.take(_maxNamedDiagnosticFields).toList();
      final hiddenLangs = langs.length - namedLangs.length;
      final tail = StringBuffer();
      if (namedLangs.isNotEmpty) {
        tail.write(' — in: ${namedLangs.join(', ')}');
        if (hiddenLangs > 0) tail.write(' (+$hiddenLangs more)');
        tail.write('.');
      }
      if (named.isNotEmpty) {
        tail.write(' — also on: ${named.join(', ')}');
        if (hidden > 0) tail.write(' (+$hidden more)');
        tail.write('.');
      }
      // Each name accounts for one row; the count is what says there are more.
      // Without it, a key whose every row folds into the head prints a line
      // that names one fault and leaves the others unmentioned — the shape
      // this whole report exists to remove.
      //
      // It speaks for THIS LINE, not for the code: a code prints one line per
      // message shape, so `rows` is one shape's rows and "for this code in
      // total" undercounted every code that varies by more than its field.
      //
      // Only on a line whose head is a row's message. The other two heads open
      // with `rows.length` themselves, so the sentence would print the same
      // number twice on one line — which is the whole of what it added to the
      // overflow line, the one line that has no head field to account for.
      if (headIsMessage && rows.length > 1 + named.length + hidden) {
        tail.write(' This line covers ${rows.length} row(s).');
      }
      // Severity picks the sink, not the wording: `warning:` on stderr is what
      // a CI log greps for, and an informational classification (every entry
      // of a dev-only catalog opting out, #612) is not that.
      //
      // Taken off the LOUDEST row, not the first. No code carries two
      // severities today, so this is a bar on a group that cannot yet form —
      // but the failure it prevents is a warning routed to stdout because an
      // `info` row happened to sort ahead of it, which is the one direction a
      // CI log cannot recover from.
      final loud = rows.any(_isLoud);
      if (loud) {
        _logger.warn('$head$tail');
      } else {
        _logger.info('$head$tail');
      }
      for (final d in rows) {
        _renderedDiagnosticRows.add(
            _diagnosticRowKey(code, d['field'], d['message'], d['lang']));
      }
    }
    _warnOmittedDiagnostics(r);
  }

  static bool _isLoud(Map<String, Object?> d) =>
      d['severity'] == 'warning' || d['severity'] == 'error';

  /// Omitted groups already announced, keyed by (code, lang, count): the real
  /// run repeats the preview's bytes, but a different count is a new fact.
  final _announcedOmissions = <String>{};

  /// One line per code the server cut (#1247). The lines above speak only for
  /// the rows listed, and an omitted row has no message to be grouped under,
  /// so its count cannot join one of them without being attributed to it.
  void _warnOmittedDiagnostics(SyncResult r) {
    final counts = <String, int>{};
    final langs = <String, List<String>>{};
    for (final o in r.diagnosticsOmitted) {
      final code = o['code'];
      final count = o['count'];
      final lang = o['lang'];
      if (code is! String || count is! num) continue;
      if (!_announcedOmissions.add('$code\u0000$lang\u0000$count')) continue;
      counts[code] = (counts[code] ?? 0) + count.toInt();
      final seen = langs[code] ??= [];
      if (lang is String) seen.add(lang);
    }
    for (final MapEntry(key: code, value: count) in counts.entries) {
      final named = langs[code]!.take(_maxNamedDiagnosticFields).toList();
      final hidden = langs[code]!.length - named.length;
      final line = StringBuffer(
          '$code: $count more row(s) the server did not list');
      if (named.isNotEmpty) {
        line.write(' — in: ${named.join(', ')}');
        if (hidden > 0) line.write(' (+$hidden more)');
      }
      line.write('.');
      final loud = r.diagnostics.any((d) => d['code'] == code && _isLoud(d));
      if (loud) {
        _logger.warn('$line');
      } else {
        _logger.info('$line');
      }
    }
  }

  /// How many extra fields a grouped diagnostic line names before it counts
  /// the rest — and, for the same reason, how many distinct message shapes one
  /// code prints before the rest fold into its overflow line. Five is what
  /// fits on a terminal line next to the message.
  static const _maxNamedDiagnosticFields = 5;

  /// The group every shape past the cap folds into. Reserved by convention,
  /// not by construction: `_messageShape` hands the server's message back —
  /// verbatim when the row carries no usable `field` — so what rules out a
  /// collision is that no parser writes a message of exactly `\u0002`, not
  /// anything this function guarantees. A collision would cost one wording,
  /// never a row.
  ///
  /// It is per CODE and it borrows no row's message on purpose. The rows in it
  /// share nothing but their code — that is what put them past the cap — so
  /// any wording taken off one of them is an assertion about the others that
  /// the CLI has no ground for.
  static String _overflowKey(String code) => '$code\u0000\u0002';

  /// A diagnostic message with its OWN field blanked out — the identity two
  /// rows share when they differ only by which key they are about.
  ///
  /// Every parser writes the key into the message, so comparing messages raw
  /// would put each key in its own group and undo the grouping entirely.
  /// Blanking the field is what leaves behind the part `also on:` cannot
  /// stand in for: the selector in `DUPLICATE_PLURAL_FORM`, the category in
  /// `EMPTY_PLURAL_FORM`, nothing at all in `SKIPPED_NON_STRING`.
  static String _messageShape(Object? message, Object? field) {
    if (message is! String) return '';
    if (field is! String || field.isEmpty) return message;
    return message.replaceAll(field, '\u0001');
  }

  /// One line per (key, lang) the catalog would have reverted. The aggregate
  /// count read like work helpfully brought in; the pair is what lets a person
  /// find the string, and the provenance is what tells them whose work it was
  /// (#550).
  void _warnConflicts(SyncResult r) {
    for (final c in r.conflicts) {
      if (!_reportedConflicts
          .add('${c['key']}\u0000${c['lang']}\u0000${c['resolution']}')) {
        continue;
      }
      final pair = '${c['key']} [${c['lang']}]';
      // A row on the base language is about the key's SOURCE (#671): calling
      // it "the project's value" reads as a translation and sends the
      // operator to the wrong column of the editor. Decided ABOVE the failed
      // -overwrite branch, not below it: that branch is the line saying what
      // ACTUALLY stands in the datastore, so it is the one that can least
      // afford to name a source a value.
      final what = r.baseCode.isNotEmpty && c['lang'] == r.baseCode
          ? 'source text'
          : 'value';
      // A row the preview announced as `overwritten` coming back `kept` is
      // the one outcome a preview cannot predict: the patch failed its slot,
      // so the project's value stands after all.
      if (r.onConflict == 'file' && c['resolution'] == 'kept') {
        _logger.warn(
          'Conflict: $pair — the overwrite did not land (its entry failed; '
          'see the warnings above); the project\'s $what still stands.',
        );
        continue;
      }
      final who = switch (c['origin']) {
        'human' => 'edited by a person',
        'machine' => 'AI-translated',
        'memory' => 'from translation memory',
        _ => 'written',
      };
      final stage = switch (c['stage']) {
        'reviewed' => ', reviewed',
        'approved' => ', approved',
        _ => '',
      };
      final when = c['updatedAt'] is String ? ' on ${c['updatedAt']}' : '';
      final provenance = '$who$stage$when';
      if (c['resolution'] == 'overwritten') {
        _logger.warn(
          'Conflict: $pair — the catalog overwrites the project\'s $what '
          '($provenance) (--on-conflict file).',
        );
      } else {
        _logger.warn(
          'Conflict: $pair — kept the project\'s $what ($provenance); the '
          'catalog carries a different one. Pull first, or pass '
          '--on-conflict file to import the catalog\'s $what over it.',
        );
      }
    }
    final hidden = r.conflictsTotal - r.conflicts.length;
    if (hidden > 0 && _reportedConflicts.isNotEmpty) {
      _logger.warn(
        '...and $hidden more conflict(s) the server did not list. Your '
        'catalog is far behind the project — pull before syncing.',
      );
    }
  }

  /// One publish-rejection block. [total] is the server's own count: the
  /// arrays are capped at 50, so past the cap the listed rows are a sample
  /// and their length is not the damage.
  // ---- SyncRunProgress: the run loop's transcript ----------------------

  @override
  void onResponse(SyncResult result) {
    _answered.add(result);
    _warnFailures(result);
    _warnConflicts(result);
    _warnParseDiagnostics(result);
  }

  @override
  void onContendedRetry({
    required List<String> keys,
    required Duration delay,
    required int attempt,
    required int max,
  }) {
    _logger.info(
      'Retrying ${keys.length} entr${keys.length == 1 ? 'y' : 'ies'} '
      'in ${_describeDelay(delay)} '
      '($attempt/$max)...',
    );
  }

  @override
  void onJobTimedOut({required bool abandoned}) {
    _logger.warn(
      abandoned
          ? 'A translation job this run paid for is still running after '
              '${_pollTimeout.inMinutes} minutes; a later sync will pick up '
              'whatever it finishes.'
          : 'The translation job is still running after '
              '${_pollTimeout.inMinutes} minutes; a later sync will pick up '
              'whatever it finishes.',
    );
  }

  @override
  void onFillRetry({
    required int pairs,
    required int attempt,
    required int max,
  }) {
    _logger.info(
      'Retrying $pairs untranslated pair(s) '
      '($attempt/$max)...',
    );
  }

  @override
  void onShortfall({required int pairs, required int retries}) {
    _logger.warn(
      '$pairs pair(s) are still untranslated'
      '${retries == 0 ? '' : ' after $retries '
          'retr${retries == 1 ? 'y' : 'ies'}'}; '
      '${_noPublish ? 'nothing will be published or written back' : 'the '
          'catalog written back does not carry them'}.',
    );
  }

  static String _describeDelay(Duration d) => d.inSeconds >= 1
      ? '${d.inSeconds}s'
      : '${d.inMilliseconds}ms';

  /// Every successful exit goes through here so `--json` emits exactly one
  /// record, after the last text line and before the exit code.
  int _finish(int code, SyncReport report) {
    if (output.json) output.emit(report.toJson());
    return code;
  }

  /// The publish line, and the cells each gate refused.
  void _reportPublished(PublishOutcome published) {
    if (published.unchanged) {
      _logger.info(
        'Nothing changed since version ${published.versionId} — '
        'no new version.',
      );
      return;
    }
    // The refusal count rides ON the success line: the itemized rows
    // are warnings (stderr), and a log that captured stdout alone read
    // as a clean publish — the exact blindness this fixes (#609).
    final refused =
        published.icuRejectedTotal + published.markupRejectedTotal;
    // Same noun as push and rollback, for the same measured reason
    // (#1175): the total covers rows the 50-row cap kept off this side,
    // so it cannot be split into sources and values here.
    _logger.info(
      'Published version ${published.versionId} '
      '(${published.keyCount} keys)'
      '${refused == 0 ? '' : ' — $refused cell(s) refused by a '
          'gate, see the warnings'}.',
    );
    // Both gates, each named: the version shipped without these cells,
    // and under `incompleteMode: skip` (what sync publishes with) the
    // locale simply has no value for that key — quieter than push, not
    // milder. Warn, never fail: a partial publish is still a publish
    // (`ci-sync.md` §8) (#609).
    _warnRejected(
      published.icuRejected,
      published.icuRejectedTotal,
      'ICU gate',
    );
    _warnRejected(
      published.markupRejected,
      published.markupRejectedTotal,
      'Markup gate',
    );
  }

  /// Warn, never fail: `--require-complete` already exists for CI that wants
  /// red, and a catalog legitimately carrying an extra locale must not start
  /// failing every build.
  void _reportLanguageGaps(CatalogLanguageGaps gaps) {
    if (gaps.missing.isNotEmpty) {
      _logger.warn(
        'Configured but missing from the catalog just written: '
        '${gaps.missing.join(', ')} — this run did not deliver them. Re-run '
        'the sync, or remove the language from the project if it is not '
        'wanted.',
      );
    }
    if (gaps.extra.isNotEmpty) {
      _logger.warn(
        'In the catalog but configured nowhere: ${gaps.extra.join(', ')} — '
        'nothing here translated them and they were left exactly as your '
        'file had them. Add the language to the project, or delete it from '
        'the catalog.',
      );
    }
  }

  void _warnRejected(List<String> entries, int total, String label) {
    if (entries.isEmpty) return;
    for (final line in entries) {
      _logger.warn('$label: $line');
    }
    final hidden = total - entries.length;
    if (hidden > 0) {
      _logger.warn('$label: ...and $hidden more the server did not list.');
    }
  }

  void _warnFailures(SyncResult r) {
    for (final f in r.failedEntries) {
      final lang = f['lang'];
      _logger.warn(
        'Entry failed: ${f['key']}${lang == null ? '' : ' [$lang]'} — '
        '${f['reason'] ?? f['code']}',
      );
    }
  }

  /// Polls the job summary until terminal or [_pollTimeout]; null on timeout.
  /// Human-readable delay for the retry line — the operator reading a CI log
  /// needs to know the job is waiting on purpose, not hung.
  static bool _stdinConfirm(String prompt, CliLogger logger) {
    if (!stdin.hasTerminal) {
      logger.warn(
        'No terminal to confirm on; pass --yes to sync non-interactively.',
      );
      return false;
    }
    stdout.write(prompt);
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  static TranslationsApiClient _defaultFactory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(baseUrl: baseUrl, token: token);
}
