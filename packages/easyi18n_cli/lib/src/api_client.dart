import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'apply/pending_code_change.dart';
import 'backoff.dart';
import 'exceptions.dart';
import 'fill_completeness.dart';
import 'http_capped.dart';
import 'iso_zone.dart';
import 'login_store.dart';

/// Keep 500: exhausted backend read retries can kill a paid fill poll (#591).
/// Shared with JSON retryability; this does not authorize POST replay.
const Set<int> kRetryableStatuses = {429, 500, 502, 503, 504};

class LanguageOutcome {
  LanguageOutcome({required this.code, required this.fillMode});

  /// The code as the server stored it, after its normalization.
  final String code;
  final String fillMode;
}

class OutputFormatOutcome {
  OutputFormatOutcome({required List<String> formats, required this.created})
    : formats = List.unmodifiable(formats);

  final List<String> formats;
  final bool created;
}

/// The rendered files for one pull: a map of relative path (as the backend
/// namespaces it, e.g. `arb/app_en.arb`) to file content.
/// How many of a version's keys carry a value in one language (#1052).
class LangCoverage {
  const LangCoverage({required this.translated, required this.total});

  final int translated;
  final int total;

  bool get complete => translated >= total;
}

class PulledTranslations {
  PulledTranslations({
    required this.project,
    required this.version,
    required this.baseCode,
    required this.formats,
    required this.files,
    this.snapshotAt,
    this.coverage,
    this.coverageBasis,
  });

  final String project;
  final String version;
  final String baseCode;
  final List<String> formats;
  final Map<String, String> files;

  /// Per-language completeness of the pulled version, keyed by language
  /// code: how many of the version's keys carry a value in that language
  /// (#1052). Null when the server did not report it (an older backend) —
  /// callers that need it must say so rather than read absence as complete.
  final Map<String, LangCoverage>? coverage;

  /// What an untranslated cell MEANT in the pulled version — the
  /// `incompleteMode` its publish ran under (#1052 review). Under `source`
  /// the base text was baked into every missing cell, so [coverage] counts
  /// the fallback as a value and reads complete for a half-translated
  /// project. Null when the server did not report it, which is the same
  /// answer as "unknown": a gate must refuse, never assume.
  final String? coverageBasis;

  /// The bases a client may grade a version's coverage on.
  ///
  /// ONE set, read by `pull --require-complete` and by `doctor` (#1248).
  /// They used to carry the predicate twice — and after #1182 narrowed the
  /// gate to `skip`, `doctor` still accepted `hold` under a comment saying
  /// the two were copied, so the same version could be refused by one
  /// command and graded by its sibling. A copied predicate is a claim, and
  /// this is the symbol that makes it checkable instead.
  ///
  /// `source` is excluded because it bakes the base text into every missing
  /// cell, so the count always reads complete (#1179); `hold` because a
  /// strings publish degrades it to `skip` before stamping, so no version can
  /// carry it and a client that judged it would be judging a state its
  /// server cannot produce. An absent or unrecognized basis is refused for
  /// the same reason a gate never assumes: it is unknown.
  ///
  /// The `hold` half of that is a fact about TODAY'S server
  /// (`kStampableIncompleteModes`, pinned on the backend side only) and
  /// nothing ties it to this set — deliberately, since the failure direction
  /// is safe: a basis this client does not know is refused, never graded.
  /// So do not read it as a guarantee, and do not widen the set on the
  /// strength of it; each consumer reports the unknown basis as unknown and
  /// names the CLI as the thing to upgrade.
  static const Set<String> judgeableCoverageBases = {'skip'};

  /// When the served snapshot was published (UTC), as the SERVER dates it —
  /// null on a backend that predates the field or a value that named no zone.
  ///
  /// This is what these bytes are not behind (#898). The pull renders the
  /// published version, never the live keys, so the response time answers a
  /// different question: `?version=` can serve content weeks old, and even
  /// `latest` is as old as the last publish.
  final DateTime? snapshotAt;
}

/// One source unit pushed to the translate endpoint. The CLI sends raw source
/// strings; the backend tokenizes them (the CLI never computes tokens).
class TranslateUnit {
  TranslateUnit({
    required this.source,
    this.ctx,
    this.previousSource,
    this.previousCtx,
  });

  final String source;
  final String? ctx;

  /// For a detected copy-edit (rename): the previous source + ctx, so the
  /// backend carries the existing key over (cheap `outdated` cascade) instead
  /// of orphaning it and minting a fresh key. The CLI doesn't tokenize, so it
  /// sends the raw previous value and the backend computes the token.
  final String? previousSource;
  final String? previousCtx;

  Map<String, Object?> toJson() => {
    'source': source,
    if (ctx != null && ctx!.isNotEmpty) 'ctx': ctx,
    if (previousSource != null && previousSource!.isNotEmpty)
      'previousSource': previousSource,
    if (previousCtx != null && previousCtx!.isNotEmpty)
      'previousCtx': previousCtx,
  };
}

/// The per-unit view the translate endpoint echoes back.
class TranslateUnitResult {
  TranslateUnitResult({
    required this.outcome,
    this.key,
    this.pending = const [],
    this.translated = const [],
    this.exhausted = const [],
    this.budgetExhausted = const [],
    this.gated = false,
    this.disabled = false,
  });

  final String outcome; // created | matched | carriedOver
  final String? key;
  final List<String> pending;
  final List<String> translated;

  /// Langs whose AI retry budget is spent (#752). Deliberately NOT part of
  /// [pending]: the engine will never fill them on its own, so a poll that
  /// waited on them would wait forever. They are also not in [translated] —
  /// ignoring this field reads them as complete, which is exactly the bug.
  final List<String> exhausted;

  /// Langs whose fill stopped because the operation's budget ran out
  /// (agent-native section 6.1). Also in [pending]: a new authorization
  /// re-queues them, which is why `fill_status` reports them apart.
  final List<String> budgetExhausted;

  /// True when the source-verify hard gate skipped this unit's fill because its
  /// source is not approved (`source-verify.md` §6). Its langs stay untranslated
  /// until the source is reviewed + approved.
  final bool gated;

  /// The key is switched off in the app, so it is excluded from published
  /// output and never translated (#563). Distinct from [gated]: a deliberate
  /// setting, not a pending review — and pushing does not re-enable it.
  final bool disabled;

  /// True when this push would (or did) queue at least one lang for fill.
  bool get needsTranslation => pending.isNotEmpty;
}

/// The result of one translate call (real or `dryRun`).
class TranslateResult {
  TranslateResult({
    required this.trackingToken,
    required this.estimatedCredits,
    required this.balance,
    required this.availableCredits,
    required this.accepted,
    required this.wouldExceedKeyCap,
    required this.units,
    this.skippedGated = 0,
    this.skippedDisabled = 0,
    this.batchSha256,
    this.targetLangs = const [],
  });

  /// The job id for a real push (null on a dry run or a no-op accept).
  final String? trackingToken;
  final int estimatedCredits;

  /// The workspace TOTAL. Overstates what a new job can spend whenever a fill
  /// is in flight — prefer [spendable].
  final int balance;

  /// The total minus every live reservation: what the next job can actually
  /// spend. Null against a server that predates the field.
  final int? availableCredits;

  /// The credit figure to show a human. Falls back to [balance] on an older
  /// server, which is exactly what such a server means by it.
  int get spendable => availableCredits ?? balance;

  /// Whether the balance covers the estimate (always true for an accepted real
  /// push; reported explicitly by a dry run).
  final bool accepted;

  /// Dry-run only: whether the push would be rejected because it exceeds the
  /// project's plan key cap (the real push enforces this with a 402). Lets the
  /// preview warn before an affordable-looking estimate that would still fail.
  final bool wouldExceedKeyCap;
  final List<TranslateUnitResult> units;

  /// Count of keys the source-verify hard gate skipped (source not approved).
  /// Their fill is deferred until the source is reviewed + approved.
  final int skippedGated;

  /// Count of keys skipped because they are switched off in the app. Their
  /// fill is not deferred — it will not happen until they are re-enabled.
  final int skippedDisabled;

  int get unitsNeedingTranslation =>
      units.where((u) => u.needsTranslation).length;

  /// Dry-run only: this body's `sha256` in an operation manifest, computed by
  /// the server so the client never re-implements the canonical form.
  final String? batchSha256;

  /// The languages the server resolved for this request.
  final List<String> targetLangs;
}

/// The result of a publish or rollback (`201 {versionId, keyCount}`).
class PublishOutcome {
  PublishOutcome({
    required this.versionId,
    required this.keyCount,
    this.restoredFrom,
    this.icuRejected = const [],
    int? icuRejectedTotal,
    this.markupRejected = const [],
    int? markupRejectedTotal,
    this.unchanged = false,
  })  : icuRejectedTotal = icuRejectedTotal ?? icuRejected.length,
        markupRejectedTotal = markupRejectedTotal ?? markupRejected.length;

  final String versionId;
  final int keyCount;

  /// `skipIfIdentical` matched the current version's snapshot digest: nothing
  /// was minted and [versionId] is the CURRENT version (200, not 201).
  final bool unchanged;

  /// Rollback only: the version id whose snapshot was restored.
  final String? restoredFrom;

  /// `key [lang]: problem` per cell the backend's ICU gate refused to bake.
  /// A refused TARGET cell fell to the incomplete-mode axis instead; a row on
  /// the BASE language names the stored source itself (#1000), where nothing
  /// falls back and the key simply ships without its base cell. Surfaced so a
  /// CI log names the offending cells.
  final List<String> icuRejected;

  /// `key [lang]: problem` per target cell the markup parity gate refused: a
  /// markdown/html translation that lost or mangled the source's structure
  /// (`markup-key-types.md` "Gate de salida"). Same consequence as
  /// [icuRejected], different remedy — hence its own list, and its own line
  /// of output (#609).
  final List<String> markupRejected;

  /// The real rejection counts. The server caps each array (50) and sends the
  /// totals alongside, so a count taken off `list.length` under-reports the
  /// damage exactly on the publishes that carry the most of it. Pre-cap
  /// servers omit them; the list is then complete by definition and its
  /// length IS the total.
  final int icuRejectedTotal;
  final int markupRejectedTotal;
}

/// Wire mirror of the `/v1/.../sync` response (`ci-sync.md` §2).
class SyncResult {
  SyncResult({
    required this.dryRun,
    required this.created,
    required this.updatedSources,
    required this.matchedSources,
    required this.updatedTranslations,
    required this.unchangedTranslations,
    required this.disabledOrphans,
    required this.reenabled,
    required this.failedEntries,
    required this.exhausted,
    required this.conflicts,
    required this.conflictsTotal,
    required this.onConflict,
    required this.trackingToken,
    required this.estimatedCredits,
    required this.balance,
    required this.availableCredits,
    required this.accepted,
    required this.skippedGated,
    required this.notInCode,
    required this.wouldExceedKeyCap,
    this.pendingSkipped = 0,
    this.baseCode = '',
    this.targetLangs = const [],
    this.fillableLangs = const [],
    this.diagnostics = const [],
    this.diagnosticsOmitted = const [],
    this.budgetExhausted = const [],
    this.batchSha256,
  });

  final bool dryRun;
  final int created;
  final int updatedSources;
  final int matchedSources;
  final int updatedTranslations;
  final int unchangedTranslations;
  final int disabledOrphans;
  final int reenabled;
  final List<Map<String, Object?>> failedEntries;

  /// (key, lang) pairs whose retry budget is spent — terminal until a human
  /// (or a source/model change) moves them. Never retried by the CLI.
  final List<Map<String, Object?>> exhausted;

  /// [exhausted] decoded once for `reportExhausted`, so the dry-run and the
  /// real-run sites of `sync` cannot drift apart on how a row is named
  /// (the `push` response has the same getter for its own wire shape).
  List<ExhaustedPair> get exhaustedPairs => [
        for (final e in exhausted)
          ExhaustedPair('${e['key']}', '${e['lang']}'),
      ];

  /// (key, lang) pairs whose fill stopped on an operation's budget
  /// (agent-native section 6.1): only a new authorization moves them.
  final List<Map<String, Object?>> budgetExhausted;

  List<ExhaustedPair> get budgetExhaustedPairs => [
        for (final e in budgetExhausted)
          ExhaustedPair('${e['key']}', '${e['lang']}'),
      ];

  /// The server's hash of this request's body, on a dry run: the one batch
  /// of the manifest an `authorize` for this sync submits. Null from a
  /// server without operations.
  final String? batchSha256;

  /// (key, lang) pairs whose stored value the catalog would revert: the
  /// server produced it (a person's edit, an AI fill, a memory hit) or a
  /// person signed it, and the catalog carries something older (#550). Each
  /// row names `origin`, `stage`, `updatedAt` and the `resolution` the server
  /// applied — `kept` (the default) or `overwritten` (`--on-conflict file`).
  final List<Map<String, Object?>> conflicts;

  /// How many pairs conflicted in total. [conflicts] is capped by the server,
  /// so above the cap this is the only honest count — a summary built off
  /// `conflicts.length` would under-report exactly when it matters most.
  final int conflictsTotal;

  /// The policy the server applied to [conflicts]: `server` or `file`.
  final String onConflict;
  final String? trackingToken;
  final int estimatedCredits;

  /// The workspace TOTAL — see [TranslateResult.balance].
  final int balance;

  /// The total minus every live reservation. Null on an older server.
  final int? availableCredits;

  /// The credit figure to show a human.
  int get spendable => availableCredits ?? balance;

  final bool accepted;
  final int skippedGated;

  /// Keys the catalog still carries that its extraction pass no longer finds
  /// in the sources (`extractionState: "stale"`, #558). Informative: the
  /// server records it as a code-scan signal and never disables them, because
  /// the marker is the compiler's conjecture — a phrase reached through a
  /// computed key is marked stale while still on screen.
  final int notInCode;
  final bool wouldExceedKeyCap;

  /// (key, lang) pairs the server left alone because their marker says a fill
  /// is already in flight. This run neither queued nor priced them, so it
  /// cannot vouch for them — and the version it publishes leaves those cells
  /// out. Zero from a pre-#591 server, which is the honest default: it had no
  /// way to tell us.
  final int pendingSkipped;

  /// The project's base language.
  final String baseCode;

  /// Every configured target language, in the project's stored spelling. This
  /// is the SET the run is about to work on, and it is what the credit
  /// estimate below is priced over — so it is printed before that estimate,
  /// never after (#592).
  final List<String> targetLangs;

  /// The subset of [targetLangs] this run can deliver: everything except the
  /// `manual` (user-owned) languages. Empty from a pre-#592 server, which is
  /// why the post-run check treats an empty list as "unknown" and stays quiet
  /// rather than accusing every language at once.
  final List<String> fillableLangs;

  /// Server-side notes about this run. Only the `LANG_*` family is rendered
  /// today; the rest ride along for forward compatibility.
  final List<Map<String, Object?>> diagnostics;

  /// The (code, language) groups [diagnostics] was cut in: `code`, `count`
  /// (rows not listed) and, for a target pass, `lang`. The server lists 10
  /// rows per group (#1247); empty from an older server, whose list is whole.
  final List<Map<String, Object?>> diagnosticsOmitted;

  /// Whether the sync changed anything server-side (the publish decision is
  /// the backend's `skipIfIdentical` — this is only for messaging).
  bool get changedAnything =>
      created > 0 ||
      updatedSources > 0 ||
      updatedTranslations > 0 ||
      disabledOrphans > 0 ||
      reenabled > 0;
}

/// The fill-job summary behind `?trackingToken=`.
class JobSummary {
  JobSummary({
    required this.status,
    required this.total,
    required this.translated,
    required this.pending,
    required this.failed,
  });

  final String status;
  final int total;
  final int translated;
  final int pending;
  final int failed;

  /// Wire values from the core `JobStatus` `@JsonValue`s (job.dart) — the
  /// summary's `status` field serves them verbatim.
  bool get terminal =>
      status == 'done' ||
      status == 'failed' ||
      status == 'aborted_no_credits' ||
      status == 'cancelled';

  /// The job ran to the end of its own plan. NOT the same question as
  /// [terminal]: a run stopped by a cancel or by an exhausted balance is
  /// terminal too, and it stopped with work outstanding (#602).
  bool get ranToCompletion => status == 'done';

  /// Pairs this run left untranslated — the axis `failed` cannot answer. The
  /// server reports a no-credits abort's pairs as `pending` on purpose (they
  /// are recoverable, not a terminal failure), so a caller that only reads
  /// `failed` sees a clean summary for a run that translated nothing.
  bool get coveredEverything => pending == 0 && failed == 0;
}

/// One language of a project's live catalogue, from `GET /v1/…/meta`.
class ProjectLanguage {
  ProjectLanguage({
    required this.code,
    required this.name,
    required this.isBase,
    required this.fillMode,
  });

  final String code;

  /// English display name (CLDR). Falls back to [code] on an older server
  /// that does not send one.
  final String name;
  final bool isBase;

  /// `ai` or `manual`. A run targeting a `manual` language is refused with
  /// `400 fill_mode_manual`, so this is worth checking before spending a
  /// round trip.
  final String fillMode;

  bool get isManual => fillMode == 'manual';
}

/// `GET /v1/projects/{id}/meta` — the project's live configuration.
class ProjectMeta {
  ProjectMeta({
    required this.currentVersionId,
    required this.baseCode,
    this.mode,
    this.languages = const [],
    this.formats = const [],
    this.formatsKnown = true,
    this.outputFormatsApiVersion,
  });

  final String currentVersionId;
  final String baseCode;

  /// The project's integration mode: `'a'` (TMS), `'b'` (runtime SDK), or
  /// null when the project never declared one — which is NOT the same as
  /// `'b'` for messaging, even though the publish default treats it that
  /// way. Independent of the CLI's own local `mode:`; the two can disagree.
  final String? mode;

  /// The languages configured on the project TODAY (not the last publish).
  /// Empty from a server that predates the field — callers must treat an
  /// empty catalogue as "unknown", never as "the project has no languages".
  final List<ProjectLanguage> languages;

  /// Live configuration, not the formats of a pinned published version.
  /// Missing or malformed metadata cannot authorize automatic adoption.
  final List<String> formats;
  final bool formatsKnown;
  final int? outputFormatsApiVersion;

  /// Target languages, i.e. everything but the base.
  List<ProjectLanguage> get targets =>
      [for (final l in languages) if (!l.isBase) l];

  /// What an omitted `incompleteMode` resolves to server-side for this
  /// project (`publish.dart`): Mode A skips untranslated cells, everything
  /// else — including an undeclared mode — serves the source text.
  bool get publishSkipsIncomplete => mode == 'a';
}

/// The opaque ids a `workspace` + `project` handle ref resolves to, via
/// `GET /v1/projects/resolve`.
class ResolvedProjectRef {
  ResolvedProjectRef({required this.projectId, required this.workspaceId});

  final String projectId;
  final String workspaceId;
}

/// The key in use, as `GET /v1/projects/{id}/credential` describes it.
class KeyCredential {
  KeyCredential({required this.scopes, required this.requiresOperationApproval});

  final List<String> scopes;

  /// The backend's rule (`grantsScope`): `admin` grants every scope.
  bool grants(String scope) =>
      scopes.contains('admin') || scopes.contains(scope);

  /// An Agent key: it spends, publishes and rolls back only under an
  /// operation a human approved (agent-native §6.2).
  final bool requiresOperationApproval;
}

/// The project the key in use belongs to, as `GET /v1/credential` names it.
class KeyProject {
  KeyProject({required this.id, this.workspace, this.slug});

  final String id;

  /// The workspace handle, null until it is claimed.
  final String? workspace;
  final String? slug;

  /// A ref is the `@handle/slug` pair once both exist, the opaque id before.
  bool get hasHandle => workspace != null && slug != null;
  String get describe => hasHandle ? '@$workspace/$slug' : id;
}

/// A project as the management routes name it (`GET /v1/me/workspaces`).
class AccountProject extends KeyProject {
  AccountProject({required super.id, super.workspace, super.slug,
      required this.workspaceId, this.name, this.baseCode, this.role});

  final String workspaceId;
  final String? name, baseCode, role;

  /// The route's own shape: `workspace` is absent until the handle is claimed.
  Map<String, Object?> toJson() => {'id': id, 'workspace_id': workspaceId,
      'workspace': ?workspace, 'slug': slug, 'name': name, 'base_code': baseCode,
      'role': role};
}

/// A workspace of the login's person, with their role and their projects in it.
class AccountWorkspace {
  AccountWorkspace({required this.id, this.handle, this.name, required this.plan,
      required this.role, required this.projects});

  final String id;

  /// The claimed `@handle`, null until it is claimed.
  final String? handle;
  final String? name;
  final String plan, role;
  final List<AccountProject> projects;

  String get describe => handle == null ? id : '@$handle';

  Map<String, Object?> toJson() => {'id': id, 'workspace': ?handle, 'name': name,
      'plan': plan, 'role': role,
      'projects': [for (final project in projects) project.toJson()]};
}

final _versionSegment = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');

/// Whether [raw] is a version the restore path can carry: the backend's own
/// `_versionShape` (`public_operations_api.dart`), minus the two relative
/// segments it also refuses.
bool isVersionSegment(String raw) =>
    _versionSegment.hasMatch(raw) && raw != '.' && raw != '..';

/// Thin client over the authenticated public read endpoint
/// `GET /v1/projects/{id}/translations`, which renders files per format/locale
/// from the project's currently published version.
class TranslationsApiClient {
  TranslationsApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
    Future<void> Function(Duration)? wait,
    Random? random,
  }) : _client = httpClient ?? http.Client(),
       _wait = wait ?? Future<void>.delayed,
       _random = random ?? Random();

  final String baseUrl;
  final String token;
  final http.Client _client;
  final Future<void> Function(Duration) _wait;
  final Random _random;

  /// A POST is replayed only when the answer PROVES the failed attempt left
  /// nothing behind — never merely because the route is idempotent.
  ///
  /// `503 contended` is that proof: it comes from a lost CAS on the credits
  /// document, which returns without writing, so no reservation exists. A
  /// `503 unavailable` is not, and what it leaves behind is the route's
  /// (#1028): a translate or sync releases its credit hold on the way out,
  /// that release is itself a write against the database that is
  /// throttling, and when it fails the reservation outlives the request — a
  /// replay then reports `402 insufficient_credits` on a workspace that has
  /// the credits, and leaks one more hold per attempt; a publish holds
  /// nothing, and a refused publish minted nothing either (the version rides
  /// one commit) — it is still not replayed here because this predicate sees
  /// a status, not a route, and the user's own re-run is the recovery the
  /// server names.
  ///
  /// And never without an answer at all: a write whose response was lost may
  /// have landed, which is the TOCTOU #564/#567 exist about.
  static bool _postProvedNothingLanded(http.Response r) =>
      r.statusCode == 503 && _errorCodeOf(r) == 'contended';

  /// Fetches the rendered files for [projectId] in [format]. [version] defaults
  /// to the published `latest`; [lang] optionally narrows to one locale.
  Future<PulledTranslations> fetchTranslations({
    required String projectId,
    required String format,
    String? version,
    String? lang,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/projects/$projectId/translations')
        .replace(
          queryParameters: {
            'format': format,
            if (version != null && version.isNotEmpty) 'version': version,
            if (lang != null && lang.isNotEmpty) 'lang': lang,
          },
        );

    final response = await _get(uri);

    if (response.statusCode != 200) {
      throw _apiError(response);
    }

    final body = _envelope(response);

    return PulledTranslations(
      project: _str(body, 'project') ?? projectId,
      version: _str(body, 'version') ?? '',
      baseCode: _str(body, 'baseCode') ?? '',
      // Lenient on purpose: nothing in this package reads `formats` off a pull
      // (the command reads `.files`), so a mixed list writes the files and
      // exits 0 today. Refusing it here would be a new refusal (#972).
      formats: _strListLenient(body, 'formats'),
      files: _strMap(body, 'files'),
      // Lenient for the same reason as `formats`, and it matters more here:
      // `_str` THROWS on a non-String, so reading this field strictly would
      // turn a 200 of an odd shape into a FAILED pull — a new refusal in a
      // purely additive change (#972). Unusable (absent, wrong type, or no
      // zone) degrades to null, and the caller dates the pull by its own
      // clock, which is exactly the pre-#898 behavior.
      snapshotAt: parseZonedInstant(body['snapshotAt']),
      // Lenient like the two above: absent or odd-shaped degrades to null,
      // and both consumers (`pull --require-complete` and the `doctor` Mode A
      // completeness arm, #1176) refuse on null rather than reading it as
      // complete.
      coverage: _coverage(body['coverage']),
      coverageBasis: body['coverageBasis'] is String
          ? body['coverageBasis'] as String
          : null,
    );
  }

  static Map<String, LangCoverage>? _coverage(Object? raw) {
    if (raw is! Map) return null;
    final out = <String, LangCoverage>{};
    for (final e in raw.entries) {
      final v = e.value;
      if (e.key is! String || v is! Map) return null;
      final translated = v['translated'];
      final total = v['total'];
      if (translated is! num || total is! num) return null;
      out[e.key as String] =
          LangCoverage(translated: translated.toInt(), total: total.toInt());
    }
    return out;
  }

  /// `GET /v1/projects/{id}/meta` - the project's currently published version
  /// (what `easyi18n status` compares the local state against).
  Future<ProjectMeta> fetchMeta({required String projectId}) async {
    final uri = Uri.parse('$baseUrl/v1/projects/$projectId/meta');
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Status');
    }
    final body = _envelope(response);
    return ProjectMeta(
      currentVersionId: _str(body, 'currentVersionId') ?? '',
      baseCode: _str(body, 'baseCode') ?? '',
      mode: _str(body, 'mode'),
      languages: [
        for (final raw in _list(body, 'languages') ?? const [])
          if (raw is Map<String, dynamic>)
            if (raw['code'] case final String code when code.isNotEmpty)
              ProjectLanguage(
                code: code,
                name: _str(raw, 'name') ?? code,
                isBase: raw['isBase'] == true,
                fillMode: _str(raw, 'fillMode') ?? 'ai',
              ),
      ],
      outputFormatsApiVersion: body['outputFormatsApiVersion'] is int
          ? body['outputFormatsApiVersion'] as int : null,
      formatsKnown: body['formats'] is List &&
          (body['formats'] as List).every((v) => v is String && v.isNotEmpty),
      formats: [
        for (final raw in _list(body, 'formats') ?? const [])
          if (raw is String && raw.isNotEmpty) raw,
      ],
    );
  }

  /// `GET /v1/projects/{id}/pending-code-changes` - the open "update your code"
  /// list from source review (`source-verify.md` §5): each entry retires an old
  /// `tr()` literal for a corrected one. Needs the `read` scope.
  Future<List<PendingCodeChange>> fetchPendingCodeChanges({
    required String projectId,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/projects/$projectId/pending-code-changes',
    );
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Apply');
    }
    final body = _envelope(response);
    return [
      for (final raw in _list(body, 'changes') ?? const [])
        if (raw is Map)
          PendingCodeChange(
            key: _str(raw, 'key') ?? '',
            ctx: _str(raw, 'ctx'),
            oldSource: _str(raw, 'oldSource') ?? '',
            newSource: _str(raw, 'newSource') ?? '',
          ),
    ];
  }

  /// `GET /v1/projects/{id}/credential` - the scopes of the key in use and
  /// whether it is an Agent key. Any valid key for the project may read it.
  Future<KeyCredential> fetchCredential({required String projectId}) async {
    final uri = Uri.parse('$baseUrl/v1/projects/$projectId/credential');
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Doctor');
    }
    final body = _envelope(response);
    final agent = body['requires_operation_approval'];
    if (agent is! bool) {
      throw _wrongShape("'requires_operation_approval'", 'a boolean', agent);
    }
    return KeyCredential(
      scopes: [
        for (final raw in _list(body, 'scopes') ?? const [])
          if (raw is String) raw,
      ],
      requiresOperationApproval: agent,
    );
  }

  /// `GET /v1/credential` - the project of the key in use. Null from a backend
  /// that predates the route: its 404 carries no `/v1` envelope, while a
  /// trashed project's does.
  Future<KeyProject?> fetchKeyProject() async {
    final response = await _get(Uri.parse('$baseUrl/v1/credential'));
    if (response.statusCode == 404 && _errorCodeOf(response) == null) {
      return null;
    }
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Credential');
    }
    final project = _envelope(response)['project'];
    final id = project is Map ? _str(project, 'id') ?? '' : '';
    if (id.isEmpty) {
      throw CliException('Unexpected response from $baseUrl (no project id).');
    }
    return KeyProject(id: id, workspace: _str(project as Map, 'workspace'),
        slug: _str(project, 'slug'));
  }

  /// `GET /v1/me` - the account of this login and when the login expires.
  Future<({String? email, DateTime? expiresAt})> fetchMe() async {
    final response = await _get(Uri.parse('$baseUrl/v1/me'));
    if (response.statusCode != 200) throw _apiError(response, action: 'Whoami');
    final body = _envelope(response);
    return (email: _str(body, 'email'),
        expiresAt: DateTime.tryParse(_str(body, 'expires_at') ?? '')?.toUtc());
  }

  /// `GET /v1/me/workspaces` - where this login works.
  Future<List<AccountWorkspace>> fetchWorkspaces() async {
    final response = await _get(Uri.parse('$baseUrl/v1/me/workspaces'));
    if (response.statusCode != 200) throw _apiError(response, action: 'Workspaces');
    final rows = _list(_envelope(response), 'workspaces') ??
        (throw _wrongShape("'workspaces'", 'an array', null));
    return [
      for (final w in rows.whereType<Map<Object?, Object?>>())
        AccountWorkspace(id: _need(w, 'id'), handle: _str(w, 'workspace'),
          name: _str(w, 'name'), plan: _str(w, 'plan') ?? 'free',
          role: _str(w, 'role') ?? '', projects: [
            for (final p in (_list(w, 'projects') ?? const []).whereType<Map<Object?, Object?>>())
              _accountProject(p),
          ]),
    ];
  }

  /// `POST /v1/workspaces/{wid}/projects` - creates as the login's person; a
  /// repeat without [slug] within a minute answers 200 with the same project.
  Future<AccountProject> createProject({required String workspaceId,
      required String name, String? slug, required String baseCode,
      List<String> targetLanguages = const [], String? stack}) => _post(
    'workspaces/$workspaceId/projects',
    action: 'Create project',
    okStatuses: const {200, 201},
    body: {'name': name, 'slug': ?slug, 'base_code': baseCode,
      if (targetLanguages.isNotEmpty) 'target_languages': targetLanguages,
      'stack': ?stack},
    parser: _accountProject,
    successBodyHint: 'The server answered success, so the project may exist: '
        "run 'easyi18n init' again to link it.",
  );

  /// `POST /v1/projects/{id}/api-keys` - a key for CI, minted by a login. The
  /// answer is the only time the secret is shown.
  Future<({String id, String prefix, String rawKey})> mintApiKey({
      required String projectId, required String label,
      required List<String> scopes}) => _post(
    'projects/$projectId/api-keys',
    action: 'Mint API key',
    body: {'label': label, 'scopes': scopes},
    parser: (b) => (id: _need(b, 'id'), prefix: _need(b, 'prefix'),
        rawKey: _need(b, 'raw_key')),
    successBodyHint: 'The server answered success, so a key may exist that '
        'this run never showed: revoke it under Settings > API keys.',
  );

  AccountProject _accountProject(Map<Object?, Object?> p) => AccountProject(
      id: _need(p, 'id'), workspaceId: _need(p, 'workspace_id'),
      workspace: _str(p, 'workspace'), slug: _str(p, 'slug'), name: _str(p, 'name'),
      baseCode: _str(p, 'base_code'), role: _str(p, 'role'));

  String _need(Map<Object?, Object?> m, String key) =>
      _str(m, key) ?? (throw _wrongShape("'$key'", 'a string', null));

  /// `GET /v1/projects/resolve?workspace=&project=` - maps the config's
  /// `@handle/slug` ref to the opaque ids the id-bound write routes need. Any
  /// valid key for the project is accepted (resolve underlies read, translate
  /// and publish alike); a key bound to another project 401s, which surfaces
  /// config<->key drift early.
  Future<ResolvedProjectRef> resolveProjectRef({
    required String workspace,
    required String project,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/projects/resolve',
    ).replace(queryParameters: {'workspace': workspace, 'project': project});
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Resolve');
    }
    final body = _envelope(response);
    final projectId = _str(body, 'projectId') ?? '';
    if (projectId.isEmpty) {
      throw CliException('Unexpected response from $baseUrl (no projectId).');
    }
    return ResolvedProjectRef(
      projectId: projectId,
      workspaceId: _str(body, 'workspaceId') ?? '',
    );
  }

  /// `POST /v1/projects/{id}/translate` - register source units and (unless
  /// [dryRun]) trigger their translation. [dryRun] runs an estimate-only pass:
  /// no key is written, no job enqueued, nothing charged. [langs] optionally
  /// narrows to a subset of the project's target languages. [identity] names
  /// the request (operation, attempt, request id, batch) without changing the
  /// batch the server hashes.
  Future<TranslateResult> translate({
    required String projectId,
    required List<TranslateUnit> units,
    List<String>? langs,
    bool dryRun = false,
    Map<String, Object?> identity = const {},
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/projects/$projectId/translate',
    ).replace(queryParameters: {if (dryRun) 'dryRun': 'true'});

    final http.Response response;
    try {
      response = await _sendCapped(
        http.Request('POST', uri)
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          })
          ..body = jsonEncode({
            'units': [for (final u in units) u.toJson()],
            if (langs != null && langs.isNotEmpty) 'langs': langs,
            ...identity,
          }),
      );
    } on http.ClientException catch (e) {
      throw TransientCliException('Could not reach $baseUrl: ${e.message}');
    }

    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Push');
    }

    // On a REAL push the 200 is the LAST thing the route does: the credit hold
    // and the job enqueue already happened inside the request. A body this CLI
    // cannot read therefore kills a run the server has already acted on — so
    // the failure has to carry the remedy, not just the diagnosis (#972).
    // A dry run acted on nothing, and says so in the catch below.
    try {
      final body = _envelope(response);
      return TranslateResult(
        trackingToken: _str(body, 'trackingToken'),
        estimatedCredits: _num(body, 'estimatedCredits')?.toInt() ?? 0,
        balance: _num(body, 'balance')?.toInt() ?? 0,
        availableCredits: _num(body, 'availableCredits')?.toInt(),
        // A real push that returns 200 was accepted; a dry run says so
        // explicitly.
        accepted: _flag(body, 'accepted') ?? true,
        wouldExceedKeyCap: _flag(body, 'wouldExceedKeyCap') ?? false,
        skippedGated: _num(body, 'skippedGated')?.toInt() ?? 0,
        skippedDisabled: _num(body, 'skippedDisabled')?.toInt() ?? 0,
        batchSha256: _str(body, 'batchSha256'),
        targetLangs: _strListLenient(body, 'targetLangs'),
        units: [
          for (final raw in _list(body, 'units') ?? const [])
            if (raw is Map<String, dynamic>)
              TranslateUnitResult(
                outcome: _str(raw, 'outcome') ?? 'matched',
                key: _str(raw, 'key'),
                // `pending` and `translated` are lenient: their only consumers
                // ask `isNotEmpty`/`length`, which a lazy cast never forced, so
                // a mixed list completes the push today (#972).
                pending: _strListLenient(raw, 'pending'),
                translated: _strListLenient(raw, 'translated'),
                // The server omits the field when empty (`public_api.dart`
                // emits it under `isNotEmpty`), so absent means none.
                //
                // Strict, unlike its two neighbours: `push_command` iterates
                // it on every batch, so a non-string already crashes the run —
                // and silently dropping one would under-report pairs the fill
                // will never retry, which is the bug #752 fixed.
                exhausted: _strListStrict(raw, 'exhausted'),
                budgetExhausted: _strListStrict(raw, 'budgetExhausted'),
                gated: _flag(raw, 'gated') ?? false,
                disabled: _flag(raw, 'disabled') ?? false,
              ),
        ],
      );
    } on CliException catch (e) {
      // Not on a dry run: `?dryRun=true` is answered by `_translateDryRun`,
      // which prices the units off a read-only `credits.precheck` and returns
      // `trackingToken: null` — no key, no marker, no job. The note would be
      // false there, and `_waitForFill` polls the preview in a loop (#972).
      throw dryRun ? e : _afterTheServerActed(e, _chargedRunNote('push'));
    }
  }

  /// `POST /v1/projects/{id}/publish` - freeze the live state into a new
  /// immutable version (needs the `publish` scope). With [skipIfIdentical]
  /// the backend answers 200 `unchanged` (no mint) when nothing changed.
  ///
  /// [requireComplete] is the server-side completeness gate (agent-native
  /// D15): the handler measures the snapshot it is about to freeze, under
  /// these same filters, and refuses with 409 `fill_incomplete` before
  /// writing. A client-side poll measures the local ingest instead, which is
  /// a different question.
  Future<PublishOutcome> publish({
    required String projectId,
    String? label,
    bool approvedOnly = false,
    String? incompleteMode,
    bool skipIfIdentical = false,
    bool requireComplete = false,
    String? operationId,
    String? requiredOutputFormat,
  }) => _post(
    'projects/$projectId/publish',
    action: 'Publish',
    parser: _parsePublish,
    successBodyHint: _versionBodyHint('Publish'),
    okStatuses: skipIfIdentical ? const {200, 201} : const {201},
    body: {
      if (label != null && label.isNotEmpty) 'label': label,
      if (approvedOnly) 'approvedOnly': true,
      'incompleteMode': ?incompleteMode,
      'requiredOutputFormat': ?requiredOutputFormat,
      if (skipIfIdentical) 'skipIfIdentical': true,
      // Omitted when false, because the door reads an absent field as false
      // (`public_api.dart`) and every shipped caller publishes without it:
      // sending it always would change the request of `push --publish` for a
      // value that means what its absence already meant.
      if (requireComplete) 'require_complete': true,
      'operationId': ?operationId,
    },
  );

  /// `POST /v1/projects/{id}/versions/{vid}/restore` - roll back by restoring
  /// [versionId] (or the literal `previous`) as a new version.
  ///
  /// [versionId] reaches the server as a path segment, and with the MCP tool
  /// the caller picking it is an agent rather than a human at a shell. It is
  /// checked against the shape the door accepts (`public_operations_api.dart`)
  /// rather than a stricter one of our own: a second definition of "a version"
  /// would refuse ids the backend mints.
  Future<PublishOutcome> restoreVersion({
    required String projectId,
    required String versionId,
    String? operationId,
  }) {
    if (!isVersionSegment(versionId)) {
      throw CliException('Invalid version "$versionId".', code: 'invalid_argument');
    }
    return _post(
      'projects/$projectId/versions/$versionId/restore',
      action: 'Rollback',
      parser: _parsePublish,
      successBodyHint: _versionBodyHint('Rollback'),
      body: {'operationId': ?operationId},
    );
  }

  Future<OutputFormatOutcome> addOutputFormat({
    required String projectId,
    required String format,
  }) => _outputFormat(projectId, format, 'add');

  Future<OutputFormatOutcome> adoptOutputFormat({
    required String projectId, required String format,
  }) => _outputFormat(projectId, format, 'adopt');

  Future<OutputFormatOutcome> _outputFormat(
    String projectId, String format, String mode,
  ) => _post(
    'projects/$projectId/output-formats',
    action: mode == 'add' ? 'Add output format' : 'Adopt output format',
    okStatuses: const {200},
    body: {'format': format, 'mode': mode},
    parser: (decoded) {
      if (decoded['formats'] == null) {
        throw _wrongShape("'formats'", 'an array of strings', null);
      }
      final formats = _strListStrict(decoded, 'formats');
      final created = _flag(decoded, 'created');
      if (created == null) {
        throw _wrongShape("'created'", 'a boolean', null);
      }
      if (!formats.contains(format)) {
        throw FatalCliException(
          'Unexpected response from $baseUrl: the persisted formats '
          'do not include the requested format "$format".',
        );
      }
      return OutputFormatOutcome(formats: formats, created: created);
    },
    successBodyHint: 'The server answered success, so the output format '
        'configuration may already be updated. Re-running '
        '`easyi18n formats add <id>` is safe.',
  );

  Future<LanguageOutcome> addLanguage({
    required String projectId,
    required String code,
    String? fillMode,
  }) => _post(
    'projects/$projectId/languages',
    action: 'Add language',
    body: {'code': code, 'fillMode': ?fillMode},
    parser: (decoded) {
      final stored = _str(decoded, 'code');
      if (stored == null || stored.isEmpty) {
        throw _wrongShape("'code'", 'a non-empty string', stored);
      }
      final mode = _str(decoded, 'fillMode');
      if (mode != 'ai' && mode != 'manual') {
        throw _wrongShape("'fillMode'", 'ai or manual', mode);
      }
      if (fillMode != null && mode != fillMode) {
        throw FatalCliException(
          'Unexpected response from $baseUrl: the stored fill mode "$mode" '
          'is not the requested "$fillMode".',
        );
      }
      return LanguageOutcome(code: stored, fillMode: mode!);
    },
    successBodyHint: 'The server answered success, so the language may '
        'already be added. Re-running `easyi18n languages add <code>` is safe.',
  );

  /// `POST /v1/operations` - ask for a human approval of [action] over
  /// [scope] (agent-native D14). Idempotent by scope: the server returns the
  /// pending or approved operation it already holds for the same request.
  Future<Map<String, Object?>> createOperation({
    required String action,
    required Map<String, Object?> scope,
    int? maxCredits,
  }) => _post(
    'operations',
    action: 'Authorize',
    body: {'action': action, 'scope': scope, 'max_credits': ?maxCredits},
    parser: _parseOperation,
    successBodyHint: 'The server answered success, so the operation may '
        'already exist. Calling authorize again with the same scope returns it.',
  );

  /// `GET /v1/operations/{id}` - the operation's state and ledger. Waiting
  /// for the approval is this read, never a second create.
  Future<Map<String, Object?>> getOperation(String operationId) async {
    final response = await _get(Uri.parse(
      '$baseUrl/v1/operations/${Uri.encodeComponent(operationId)}',
    ));
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Authorize');
    }
    return _parseOperation(_envelope(response));
  }

  /// `GET /v1/projects/{id}/requests/{requestId}` - what became of an ingest
  /// request this key sent: `unknown | processing | done | failed | expired`
  /// (agent-native section 4.4). The reconciliation after a lost answer reads
  /// this; nothing is ever re-sent on a guess.
  Future<Map<String, Object?>> getRequest({
    required String projectId,
    required String requestId,
  }) async {
    final response = await _get(Uri.parse(
      '$baseUrl/v1/projects/$projectId/requests/'
      '${Uri.encodeComponent(requestId)}',
    ));
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Push');
    }
    final decoded = _envelope(response);
    final state = decoded['state'];
    if (state is! String || state.isEmpty) {
      throw _wrongShape("'state'", 'a non-empty string', state);
    }
    return decoded;
  }

  Map<String, Object?> _parseOperation(Map<String, Object?> decoded) {
    for (final field in ['operation_id', 'state']) {
      final value = decoded[field];
      if (value is! String || value.isEmpty) {
        throw _wrongShape("'$field'", 'a non-empty string', value);
      }
    }
    return decoded;
  }

  String _versionBodyHint(String action) =>
      'The server answered success before this body was read, so the '
      'version may already exist. Check the project history before '
      'running $action again.';

  PublishOutcome _parsePublish(Map<String, Object?> decoded) => PublishOutcome(
    versionId: _str(decoded, 'versionId') ?? '',
    keyCount: _num(decoded, 'keyCount')?.toInt() ?? 0,
    restoredFrom: _str(decoded, 'restoredFrom'),
    unchanged: decoded['unchanged'] == true,
    icuRejected: _strListLenient(decoded, 'icuRejected'),
    icuRejectedTotal: _num(decoded, 'icuRejectedTotal')?.toInt(),
    markupRejected: _strListLenient(decoded, 'markupRejected'),
    markupRejectedTotal: _num(decoded, 'markupRejectedTotal')?.toInt(),
  );

  Future<T> _post<T>(
    String path, {
    required String action,
    required T Function(Map<String, Object?>) parser,
    required String successBodyHint,
    Map<String, Object?>? body,
    Set<int> okStatuses = const {201},
  }) async {
    // All writes use the same no-replay policy unless nothing landed is
    // proven. Explicit add is safe to repeat; publish/restore may mint again.
    final response = await _send(
      () => http.Request('POST', Uri.parse('$baseUrl/v1/$path'))
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        })
        ..body = jsonEncode(body ?? const {}),
      shouldRetry: _postProvedNothingLanded,
      retryTransport: false,
    );
    if (!okStatuses.contains(response.statusCode)) {
      throw _apiError(response, action: action);
    }
    try {
      return parser(_envelope(response));
    } on CliException catch (e) {
      throw _afterTheServerActed(e, successBodyHint);
    }
  }

  /// `POST /v1/projects/{id}/sync` - upload the whole catalog file; the
  /// backend parses, diffs, applies and queues the fill (`ci-sync.md` §2).
  /// [identity] names the request like `translate`'s, outside the hashed
  /// batch.
  Future<SyncResult> sync({
    required String projectId,
    required String fileName,
    required List<int> bytes,
    String? format,
    bool dryRun = false,
    String? onConflict,
    DateTime? pulledAt,
    String? lang,
    Map<String, Object?> identity = const {},
  }) async {
    // What may be replayed here is narrower than "the route is idempotent",
    // which it is. See [_postProvedNothingLanded]: a `503 unavailable` from
    // the real run can be hiding a credit hold that outlived the failure, and
    // replaying into it reports a balance problem the workspace does not have.
    //
    // The DRY RUN is the exception, and it is the first call the command
    // makes: it returns before the apply and before the hold, so nothing it
    // failed at can have been left behind — any `503` there is safe. Losing
    // the whole run to a throttle in the preview, before a single write was
    // attempted, was the cheapest failure to avoid.
    //
    // The failure #591 actually measured needs none of this: a datastore
    // failure inside the apply loop is now a per-entry `contended` row on a
    // 200, and that retry lives in `SyncCommand`, backed off, on a response
    // that proves no hold was left behind.
    final response = await _send(
      () => http.Request(
        'POST',
        Uri.parse('$baseUrl/v1/projects/$projectId/sync'
            '${dryRun ? '?dryRun=true' : ''}'),
      )
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        })
        ..body = jsonEncode({
          'format': ?format,
          'fileName': fileName,
          'contentBase64': base64Encode(bytes),
          'onConflict': ?onConflict,
          // Arms the server's base-language guard (#671): a source the
          // project edited after this instant comes back as a `conflicts`
          // row instead of being silently reverted.
          'pulledAt': ?pulledAt?.toUtc().toIso8601String(),
          // The language of a one-language file (`android_xml`, #2297).
          'lang': ?lang,
          ...identity,
        }),
      shouldRetry: (r) =>
          dryRun ? r.statusCode == 503 : _postProvedNothingLanded(r),
      retryTransport: false,
    );
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Sync');
    }
    // On a real sync the apply, the credit hold and the enqueue all ran before
    // this 200. A body we cannot read kills everything the command does next —
    // the `contended` retries, the abandoned-token drain, the wait and the
    // publish — so the failure names what is safe to do about it (#972). The
    // dry run is the exception the comment above already carves out.
    try {
      final decoded = _envelope(response);
      // The `.cast` here is inert: `jsonDecode` only ever produces String keys
      // for a JSON object, and `Object?` accepts every value, so it can never
      // throw. Kept because [SyncResult] is typed on the narrower map.
      List<Map<String, Object?>> mapList(String key) => [
        for (final e in _list(decoded, key) ?? const [])
          if (e is Map) e.cast<String, Object?>(),
      ];
      return SyncResult(
        dryRun: decoded['dryRun'] == true,
        created: _num(decoded, 'created')?.toInt() ?? 0,
        updatedSources: _num(decoded, 'updatedSources')?.toInt() ?? 0,
        matchedSources: _num(decoded, 'matchedSources')?.toInt() ?? 0,
        updatedTranslations:
            _num(decoded, 'updatedTranslations')?.toInt() ?? 0,
        unchangedTranslations:
            _num(decoded, 'unchangedTranslations')?.toInt() ?? 0,
        disabledOrphans: _num(decoded, 'disabledOrphans')?.toInt() ?? 0,
        reenabled: _num(decoded, 'reenabled')?.toInt() ?? 0,
        failedEntries: mapList('failedEntries'),
        exhausted: mapList('exhausted'),
        conflicts: mapList('conflicts'),
        // Pre-cap servers do not send it; the list is then complete by
        // definition, so its length IS the total.
        conflictsTotal: _num(decoded, 'conflictsTotal')?.toInt() ??
            mapList('conflicts').length,
        onConflict: _str(decoded, 'onConflict') ?? 'server',
        trackingToken: _str(decoded, 'trackingToken'),
        estimatedCredits: _num(decoded, 'estimatedCredits')?.toInt() ?? 0,
        balance: _num(decoded, 'balance')?.toInt() ?? 0,
        availableCredits: _num(decoded, 'availableCredits')?.toInt(),
        accepted: decoded['accepted'] == true,
        skippedGated: _num(decoded, 'skippedGated')?.toInt() ?? 0,
        notInCode: _num(decoded, 'notInCode')?.toInt() ?? 0,
        wouldExceedKeyCap: decoded['wouldExceedKeyCap'] == true,
        pendingSkipped: _num(decoded, 'pendingSkipped')?.toInt() ?? 0,
        baseCode: _str(decoded, 'baseCode') ?? '',
        targetLangs: _strListLenient(decoded, 'targetLangs'),
        fillableLangs: _strListLenient(decoded, 'fillableLangs'),
        diagnostics: mapList('diagnostics'),
        diagnosticsOmitted: mapList('diagnosticsOmitted'),
        budgetExhausted: mapList('budgetExhausted'),
        batchSha256: _str(decoded, 'batchSha256'),
      );
    } on CliException catch (e) {
      // Not on a dry run, for the reason this method already states 80 lines
      // up: `public_sync_api` returns on `dryRun` BEFORE the apply loop and
      // before the hold, off a read-only precheck. The preview is the first
      // call `SyncCommand` makes, so this is the likelier of the two (#972).
      throw dryRun ? e : _afterTheServerActed(e, _chargedRunNote('sync'));
    }
  }

  /// `GET /v1/projects/{id}/translations?trackingToken=` - fill-job summary
  /// recomputed from the keys' live markers.
  // wired-ignore: R8 false positive — called by SyncCommand._waitForJob.
  Future<JobSummary> fetchJobSummary({
    required String projectId,
    required String trackingToken,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/v1/projects/$projectId/translations',
    ).replace(queryParameters: {'trackingToken': trackingToken});
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw _apiError(response, action: 'Sync');
    }
    final decoded = _envelope(response);
    // The `.cast<String, Object?>` this replaced was inert for the same reason
    // as `sync`'s: a decoded JSON object never has a non-String key.
    final summary = _obj(decoded, 'summary') ?? const {};
    return JobSummary(
      status: _str(decoded, 'status') ?? 'unknown',
      total: _num(summary, 'total')?.toInt() ?? 0,
      translated: _num(summary, 'translated')?.toInt() ?? 0,
      pending: _num(summary, 'pending')?.toInt() ?? 0,
      failed: _num(summary, 'failed')?.toInt() ?? 0,
    );
  }

  /// `POST /v1/auth/device` (ci-sync §6): a login request for this machine,
  /// asked with no credential.
  Future<({String deviceCode, String userCode, String uri, String complete,
      int interval, int expiresIn})> startDeviceLogin(String deviceName) async {
    final response =
        await _auth('device', {'client': 'cli', 'device_name': deviceName});
    if (response.statusCode != 200) throw _apiError(response, action: 'Login');
    final b = _envelope(response);
    String need(String key) =>
        _str(b, key) ?? (throw _wrongShape("'$key'", 'a string', null));
    return (deviceCode: need('device_code'), userCode: need('user_code'),
        uri: need('verification_uri'), complete: need('verification_uri_complete'),
        interval: _num(b, 'interval')?.toInt() ?? 5,
        expiresIn: _num(b, 'expires_in')?.toInt() ?? 900);
  }

  /// One poll of `POST /v1/auth/device/token`: the login once approved, else
  /// the code of a `428` or `429` and its `Retry-After`. A final answer
  /// (`denied`, `expired`, `login_limit_reached`) throws.
  Future<({StoredLogin? login, String? code, int? retryAfter})> pollDeviceLogin(
      String deviceCode) async {
    final response = await _auth('device/token', {'device_code': deviceCode});
    if (response.statusCode == 200) {
      final b = _envelope(response);
      final token = _str(b, 'access_token');
      if (token == null || token.isEmpty) {
        throw _wrongShape("'access_token'", 'a non-empty string', token);
      }
      return (login: StoredLogin(token: token, email: _str(b, 'email'),
          expiresAt: DateTime.tryParse(_str(b, 'expires_at') ?? '')?.toUtc()),
          code: null, retryAfter: null);
    }
    if (response.statusCode != 428 && response.statusCode != 429) {
      throw _apiError(response, action: 'Login');
    }
    return (login: null, code: _errorCodeOf(response),
        retryAfter: int.tryParse(response.headers['retry-after'] ?? ''));
  }

  /// `POST /v1/auth/logout` with this login: true once revoked, false when
  /// the server no longer knew it.
  Future<bool> logout() async {
    final response = await _auth('logout', const {});
    if (response.statusCode == 401) return false;
    if (response.statusCode != 204) throw _apiError(response, action: 'Logout');
    return true;
  }

  /// The device routes take no credential, so an empty [token] sends none.
  Future<http.Response> _auth(String path, Map<String, Object?> body) => _send(
        () => http.Request('POST', Uri.parse('$baseUrl/v1/auth/$path'))
          ..headers.addAll({'content-type': 'application/json',
            if (token.isNotEmpty) 'authorization': 'Bearer $token'})
          ..body = jsonEncode(body),
        shouldRetry: (_) => false,
        retryTransport: false,
      );

  void close() => _client.close();

  Future<http.Response> _sendCapped(http.BaseRequest request) =>
      sendCapped(_client, request);

  /// Sends [build]'s request, replaying it with jittered backoff while
  /// [shouldRetry] accepts the answer. [retryTransport] additionally replays a
  /// connection-level failure — true only for GETs, which are idempotent.
  ///
  /// The predicate takes the whole response, not a status set, because for a
  /// POST the status alone does not settle it: two `503`s can mean opposite
  /// things about what the failed attempt left behind, and only the `error`
  /// code tells them apart.
  Future<http.Response> _send(
    http.BaseRequest Function() build, {
    required bool Function(http.Response) shouldRetry,
    required bool retryTransport,
  }) async {
    for (var attempt = 1; ; attempt++) {
      final http.Response response;
      try {
        response = await _sendCapped(build());
      } on http.ClientException catch (e) {
        if (!retryTransport || attempt >= kMaxApiAttempts) {
          throw TransientCliException('Could not reach $baseUrl: ${e.message}');
        }
        await _wait(backoffDelay(attempt, random: _random));
        continue;
      }
      if (attempt >= kMaxApiAttempts || !shouldRetry(response)) return response;
      await _wait(backoffDelay(attempt, random: _random));
    }
  }

  /// The `error` field of a `/v1` failure envelope, or null when the body is
  /// not one.
  static String? _errorCodeOf(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is String) {
        return body['error'] as String;
      }
    } on FormatException {
      // Not our envelope; the status is all there is.
    }
    return null;
  }

  /// A GET with the standard headers, replayed on a transient failure.
  Future<http.Response> _get(Uri uri) => _send(
        () => http.Request('GET', uri)
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'accept': 'application/json',
          }),
        shouldRetry: (r) => kRetryableStatuses.contains(r.statusCode),
        retryTransport: true,
      );

  /// The `/v1` envelope as a typed failure, so callers can branch on the
  /// status instead of the sentence.
  ApiException _apiError(http.Response response, {String action = 'Pull'}) {
    String? code;
    var details = const <String, Object?>{};
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is String) code = body['error'] as String;
      // The envelope's own fields are already the message, the code and the
      // trace id; everything else is the structured half of the refusal
      // (`fill_incomplete`'s pending/exhausted/refused, above all), and the
      // MCP error contract is the only channel an agent reads.
      if (body is Map) {
        details = {
          for (final entry in body.entries)
            if (!const {'error', 'message', 'correlationId'}
                .contains(entry.key))
              '${entry.key}': entry.value,
        };
      }
    } on FormatException {
      // Non-JSON error body; the message falls back to the status line.
    }
    return ApiException(
      _describeError(response, action: action),
      statusCode: response.statusCode,
      code: code,
      details: details,
    );
  }

  String _describeError(http.Response response, {String action = 'Pull'}) {
    String? message;
    String? code;
    Object? id = response.headers['x-correlation-id'];
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        if (body['message'] is String) message = body['message'] as String;
        if (body['error'] is String) code = body['error'] as String;
        id = body['correlationId'] ?? id;
      }
    } on FormatException {
      // Non-JSON error body; fall back to the status line.
    }

    final hint = switch (response.statusCode) {
      // A login's own refusal already names `easyi18n login` (#2580).
      401 when code == 'login_expired' || code == 'login_revoked' => '',
      401 when token.startsWith('eip_') =>
        "\nThis login is no longer valid. Run 'easyi18n login' to sign in again.",
      401 => '\nCheck your token (EASYI18N_TOKEN) - it needs the right scope.',
      // 402 covers out-of-credits, plan caps (e.g. the free-tier key limit)
      // and the monthly spending cap. Only the credits case warrants the
      // top-up hint; for a plan limit the server message already says what to
      // do, and topping up cannot clear a spending cap — offering it there
      // contradicts the reason the server just gave.
      429 when action == 'Login' =>
        '\nTry again in ${response.headers['retry-after'] ?? 60} seconds.',
      402 when code == 'spend_cap_exceeded' =>
        '\nThe monthly spending cap refused this run, not the balance. Raise '
            'the cap in billing settings, or narrow the push '
            '(--max-credits / fewer langs).',
      402 when code != 'plan_limit' =>
        '\nNot enough credits to translate. Top up, or narrow the push '
            '(--max-credits / fewer langs).',
      // An Agent key's missing approval: the token has the scope.
      403 when code != 'authorization_required' =>
        '\nThe token is valid but lacks the required scope for this '
            'project.',
      404 when action == 'Resolve' =>
        '\nCheck the workspace/project in easyi18n.yaml - is the handle '
            'claimed and the slug correct?',
      // The version_not_found message already says exactly what's missing
      // (e.g. rollback with nothing older) - don't muddy it.
      404 when code != 'version_not_found' =>
        '\nThe project may not exist or have no published version yet.',
      // Quota-wide: every client of that database shares the throttle, so
      // there is nothing to fix locally. Deliberately says nothing about how
      // far THIS command got — the same envelope is rendered for pull,
      // publish, rollback and resolve, and only some of them retried first.
      503 =>
        '\nThe service was busy. Nothing is wrong with the request; run the '
            'command again in a few minutes.',
      500 =>
        '\nThe server hit an unexpected error; this is not a problem with '
            'your token or config.',
      409 when code == 'export_collision' =>
        '\nTwo keys collapse to the same name in a lossy format. Rename one '
            'and re-publish, or pull a path-preserving format (e.g. json).',
      _ => '',
    };
    // Only a 5xx is ours to trace, and only a short token is printed: the
    // backend mints 16 hex chars but echoes a caller-sent header, and a
    // proxy's 5xx can carry anything, ANSI escapes included (#1235).
    final ref = response.statusCode >= 500 &&
            id is String &&
            _quotableId.hasMatch(id)
        ? '\nIf it keeps happening, contact support and quote this id: $id'
        : '';
    final detail = message ?? 'HTTP ${response.statusCode}';
    return '$action failed: $detail$hint$ref';
  }

  static final _quotableId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  // ---------------------------------------------------------------------
  // Reading a success body (#972)
  //
  // Every `as T` below used to run straight off `jsonDecode`, so a body that
  // was valid JSON of the wrong SHAPE — a proxy's own envelope, a `baseUrl`
  // aimed at another service, a serialization regression — escaped as an
  // uncaught `TypeError` with a stack trace and exit 255.
  //
  // Each reader accepts exactly the set its cast accepted: `{null} ∪ {T}`, so
  // an absent or explicitly-null field still returns null and the call site's
  // `?? default` still governs. Nothing that parses today stops parsing; only
  // the class of the failure changes on a body that already blew up.
  // ---------------------------------------------------------------------

  /// The body of a 2xx as a JSON object.
  ///
  /// Every `/v1` success envelope is an object. Not being one is permanent for
  /// this run, never a hiccup worth retrying — hence [FatalCliException],
  /// which is what an uncaught `TypeError` already amounted to inside
  /// `pull --watch` (`pull_command.dart` rethrows it and warns-and-retries a
  /// plain [CliException]).
  Map<String, Object?> _envelope(http.Response response) {
    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      // Unchanged, deliberately: HTML from a captive portal or a proxy is a
      // genuinely transient signal, and the watcher should keep watching.
      throw CliException('Unexpected response from $baseUrl (not JSON).');
    }
    if (body is! Map<String, Object?>) {
      throw _wrongShape('the body', 'a JSON object', body);
    }
    return body;
  }

  /// Names the field and the type that came back, so one printed line is
  /// enough to diagnose a schema regression.
  FatalCliException _wrongShape(String what, String expected, Object? got) =>
      FatalCliException(
        'Unexpected response from $baseUrl: $what should be $expected, got '
        '${got == null ? 'null' : got.runtimeType}.',
      );

  String? _str(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is String?) return v;
    throw _wrongShape("'$key'", 'a string', v);
  }

  num? _num(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is num?) return v;
    throw _wrongShape("'$key'", 'a number', v);
  }

  bool? _flag(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is bool?) return v;
    throw _wrongShape("'$key'", 'a boolean', v);
  }

  List<Object?>? _list(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is List?) return v;
    throw _wrongShape("'$key'", 'an array', v);
  }

  Map<Object?, Object?>? _obj(Map<Object?, Object?> m, String key) {
    final v = m[key];
    if (v is Map?) return v;
    throw _wrongShape("'$key'", 'an object', v);
  }

  /// A JSON object whose every key and value is a string (`files`). Eager, as
  /// the `Map.map` it replaces was — the same inputs already threw here.
  /// Mirrors `delivery.dart`'s `stringMap`, which is the pattern this file
  /// should have followed from the start.
  Map<String, String> _strMap(Map<Object?, Object?> m, String key) {
    final raw = _obj(m, key);
    if (raw == null) return const {};
    final out = <String, String>{};
    for (final e in raw.entries) {
      final k = e.key;
      final v = e.value;
      // The message names `v` on both arms, so a non-String KEY would report
      // the type of its value. Unreachable, for the same reason the `.cast`
      // above is inert: `jsonDecode` never produces a non-String key for a
      // JSON object. Left alone rather than given a branch no input can take.
      if (k is! String || v is! String) {
        throw _wrongShape("'$key'", 'a map of strings to strings', v);
      }
      out[k] = v;
    }
    return out;
  }

  /// A list of strings, refusing a non-string element.
  ///
  /// Only for a field the product actually ITERATES, where a bad element is
  /// already a crash today — just three frames further up, in the consumer,
  /// because `List.cast` is lazy and throws on access rather than on the cast.
  /// Using it on a field nobody reads would refuse a response that succeeds
  /// today, which in a published CLI is a new refusal (#972).
  List<String> _strListStrict(Map<Object?, Object?> m, String key) {
    final raw = _list(m, key);
    if (raw == null) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is! String) throw _wrongShape("'$key'", 'a list of strings', e);
      out.add(e);
    }
    return out;
  }

  /// A list of strings, dropping a non-string element — the same tolerance the
  /// `if (e is String)` filters in this file already apply. For a field whose
  /// consumers never touch the elements, so a mixed list completes the run
  /// today and has to keep completing it.
  List<String> _strListLenient(Map<Object?, Object?> m, String key) => [
    for (final e in _list(m, key) ?? const [])
      if (e is String) e,
  ];

  /// What to tell a user whose run died after the server had already priced
  /// it.
  ///
  /// Modal on purpose. A run with nothing to do is charged 0 and answers the
  /// same 200, so from a body the CLI cannot read it is unknowable whether
  /// THIS run spent anything — "may have" is the strongest true claim.
  ///
  /// It promises only what is measured in the backend: that a re-run does not
  /// pay twice. Both halves of that have to keep holding, and neither is
  /// reachable from any test in this package —
  /// `backend/lib/ai/fill_eligibility.dart` (under `FillOverwrite.none` a pair
  /// that already carries a value with a live anchor is not fillable again)
  /// and `backend/lib/routes/public_sync_api.dart` (`LangState.pending` —
  /// "in flight, never re-queued"). It deliberately does NOT promise that one
  /// re-run finishes the job: pairs the abandoned fill still holds come back
  /// as `pendingSkipped`, and `sync` already reports those on its own.
  String _chargedRunNote(String command) =>
      'The server had already accepted this $command when the body arrived, '
      'so it may have reserved credits and queued a fill for it. Re-running '
      '`easyi18n $command` is safe: work that already landed is not paid for '
      'twice.';

  /// Re-throws [cause] with what the caller can still do about it, for a parse
  /// that fails AFTER the server already acted on the request. Preserves the
  /// class, so the `pull --watch` verdict and every existing handler behave
  /// exactly as they did.
  CliException _afterTheServerActed(CliException cause, String note) {
    final message = '${cause.message}\n$note';
    return cause is FatalCliException
        ? FatalCliException(message)
        : CliException(message);
  }
}
