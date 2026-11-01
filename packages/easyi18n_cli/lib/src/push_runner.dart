import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'config.dart';
import 'credits.dart';
import 'exceptions.dart';
import 'extract/source_unit.dart';
import 'extract/tr_extractor.dart';
import 'extract_runner.dart';
import 'fill_completeness.dart';
import 'lockfile.dart';

/// The most units one translate request accepts (matches the backend cap).
const int _maxUnitsPerBatch = 500;

class PushRunner {
  const PushRunner();

  /// The offline half of a push: scan the tree, diff it against the lockfile
  /// and shape the units a translate call would carry. Needs no credential,
  /// so a no-op push can stop here without one.
  PushScan scan(
    TrExtractor extractor,
    Easyi18nConfig config, {
    required String configPath,
    required String sourceDir,
  }) {
    final root = p.dirname(configPath);
    final extraction = extractor.extractFromDirectory(
      Directory(p.join(root, sourceDir)),
      relativeTo: root,
    );
    final lockFile = File(p.join(root, Lockfile.fileName));
    // Inert seed: the diff ignores it and `writeLock` writes the resolved id.
    final lock = Lockfile.loadOrEmpty(lockFile, project: config.ref.lockSeed);
    final diff = lock.diff(extraction.units);
    // Carry over unambiguous 1:1 copy-edits so the backend keeps the existing
    // key (cheap outdated cascade) instead of orphaning it and minting a new one.
    final renames = diff.renamePairs();
    return PushScan(
      extract: ExtractResult(
        extraction: extraction,
        diff: diff,
        projectDir: p.normalize(p.absolute(root)),
        baseUrl: config.baseUrl,
      ),
      lock: lock,
      lockFile: lockFile,
      units: [
        for (final u in extraction.units)
          TranslateUnit(
            source: u.source,
            ctx: u.ctx,
            previousSource: renames[u.identity]?.source,
            previousCtx: renames[u.identity]?.ctx,
          ),
      ],
    );
  }

  /// The free cost preview: one dry run over the whole scan. Registers and
  /// spends nothing.
  Future<PushPreview> preview(
    TranslationsApiClient client,
    String projectId,
    PushScan scan,
    List<String> langs,
  ) async => PushPreview(
    scan,
    await run(client, projectId, scan.units, langs, dryRun: true),
  );

  /// Sends [units] in batches and aggregates the per-batch results into one
  /// view (summed credits + units and the balance from the last batch).
  /// Tracks each batch's job token for a real push. [beforeSend] returns the
  /// identity fields of batch `index` and runs before it leaves; [afterSend]
  /// sees its answer. On a real push [onSent] gets the aggregate of the
  /// batches accepted so far, before the ceiling can stop the next one.
  Future<PushResult> run(
    TranslationsApiClient client,
    String projectId,
    List<TranslateUnit> units,
    List<String> langs, {
    required bool dryRun,
    int? maxCreditsMc,
    int startBatch = 0,
    Map<String, Object?> Function(int index)? beforeSend,
    void Function(int index, TranslateResult result)? afterSend,
    void Function(PushResult sent)? onSent,
  }) async {
    var estimated = 0;
    var balance = 0;
    int? available;
    var needing = 0;
    var wouldExceedKeyCap = false;
    var skippedGated = 0;
    var skippedDisabled = 0;
    final tokens = <String>[];
    var pendingPairs = 0;
    final exhaustedPairs = <ExhaustedPair>[];
    final budgetExhaustedPairs = <ExhaustedPair>[];
    final batches = <ManifestBatch>[];
    final targetLangs = <String>{};
    PushResult total() => PushResult(
      estimatedCredits: estimated,
      balance: balance,
      availableCredits: available,
      unitsNeedingTranslation: needing,
      trackingTokens: tokens,
      wouldExceedKeyCap: wouldExceedKeyCap,
      skippedGated: skippedGated,
      skippedDisabled: skippedDisabled,
      pendingPairs: pendingPairs,
      exhaustedPairs: exhaustedPairs,
      budgetExhaustedPairs: budgetExhaustedPairs,
      batches: batches,
      targetLangs: targetLangs.toList()..sort(),
    );
    for (var i = startBatch * _maxUnitsPerBatch;
        i < units.length; i += _maxUnitsPerBatch) {
      final batch = units.sublist(
        i,
        i + _maxUnitsPerBatch > units.length
            ? units.length
            : i + _maxUnitsPerBatch,
      );
      final index = i ~/ _maxUnitsPerBatch;
      final r = await client.translate(
        projectId: projectId,
        units: batch,
        langs: langs.isEmpty ? null : langs,
        dryRun: dryRun,
        identity: beforeSend?.call(index) ?? const {},
      );
      afterSend?.call(index, r);
      estimated += r.estimatedCredits;
      balance = r.balance;
      available = r.availableCredits;
      needing += r.unitsNeedingTranslation;
      if (r.wouldExceedKeyCap) wouldExceedKeyCap = true;
      skippedGated += r.skippedGated;
      skippedDisabled += r.skippedDisabled;
      for (final u in r.units) {
        pendingPairs += u.pending.length;
        for (final lang in u.exhausted) {
          exhaustedPairs.add(ExhaustedPair(u.key ?? '(unnamed key)', lang));
        }
        for (final lang in u.budgetExhausted) {
          budgetExhaustedPairs.add(
              ExhaustedPair(u.key ?? '(unnamed key)', lang));
        }
      }
      if (r.trackingToken != null) tokens.add(r.trackingToken!);
      batches.add(ManifestBatch(r.batchSha256, batch.length));
      targetLangs.addAll(r.targetLangs);
      onSent?.call(total());
      // Re-assert the ceiling against the running total on a real push: the
      // upfront check used the aggregate dry-run estimate, but stop before
      // spending further if the real per-batch charge has already exceeded it.
      if (!dryRun && maxCreditsMc != null && estimated > maxCreditsMc) {
        throw CliException(
          'Charged ~${formatCredits(estimated)} credit(s) across the '
          'completed batches, exceeding --max-credits '
          '${formatCredits(maxCreditsMc)}. Stopped before the remaining '
          'batches.',
        );
      }
    }
    return total();
  }

  /// Rebuilds the lockfile from the scan, keeping previously-registered orphans
  /// unless [prune] is set (translations on the backend are never touched).
  void writeLock(
    File file,
    String project,
    Lockfile previous,
    ExtractionResult extraction,
    bool prune,
  ) {
    final units = <String, LockUnit>{};
    if (!prune) {
      for (final u in previous.units) {
        units[u.identity] = u;
      }
    }
    for (final u in extraction.units) {
      units[u.identity] = LockUnit(source: u.source, ctx: u.ctx);
    }
    Lockfile(project: project, units: units.values.toList()).write(file);
  }
}

/// Aggregated view across batched translate calls.
class PushResult {
  PushResult({
    required this.estimatedCredits,
    required this.balance,
    required this.availableCredits,
    required this.unitsNeedingTranslation,
    required this.trackingTokens,
    required this.wouldExceedKeyCap,
    this.skippedGated = 0,
    this.skippedDisabled = 0,
    this.pendingPairs = 0,
    this.exhaustedPairs = const [],
    this.budgetExhaustedPairs = const [],
    this.batches = const [],
    this.targetLangs = const [],
  });

  final int estimatedCredits;
  /// The workspace TOTAL. Never the affordability question's input: a live
  /// reservation is not spendable by this push.
  final int balance;

  /// The total minus every live reservation. Null on a server that predates
  /// the field, where [balance] is the only number available.
  final int? availableCredits;

  /// The credit figure a human reads, and the one affordability is judged on.
  int get spendable => availableCredits ?? balance;
  final int unitsNeedingTranslation;
  final List<String> trackingTokens;

  /// Dry-run only: any batch would push the project past its plan key cap.
  final bool wouldExceedKeyCap;

  /// Keys the source-verify hard gate skipped (source not verified) — their
  /// fill is deferred until the source is reviewed + approved.
  final int skippedGated;

  /// Keys skipped because they are switched off in the app. Unlike
  /// [skippedGated] this is not a deferral: nothing translates them until
  /// someone re-enables the key.
  final int skippedDisabled;

  /// (key, lang) pairs whose AI retry budget is spent (#752). Not counted in
  /// [unitsNeedingTranslation] and never priced — the engine has given up on
  /// them, so only `reportExhausted` gives them a voice.
  final List<ExhaustedPair> exhaustedPairs;

  /// (key, lang) pairs the server reports as `pending`: queued, in flight or
  /// waiting for a fill. The count `fill_status` polls down to zero.
  final int pendingPairs;

  /// (key, lang) pairs whose fill stopped on the operation's budget (section
  /// 6.1). A subset of [pendingPairs] that only a new authorization moves.
  final List<ExhaustedPair> budgetExhaustedPairs;

  /// Judged against what is SPENDABLE, not the total. A fill already in
  /// flight holds credits this push cannot touch, so measuring against the
  /// total previews a green dry run for a push the server will 402.
  bool get affordable => estimatedCredits <= spendable;

  /// One entry per request, in send order. A real push sends the same bodies
  /// in the same order, which is what the manifest's hashes vouch for.
  final List<ManifestBatch> batches;

  /// The languages the server resolved, across every batch.
  final List<String> targetLangs;

  /// The operation manifest (agent-native section 6.1), or null when a batch
  /// came back without its hash (a server that predates operations).
  OperationManifest? get manifest =>
      batches.isEmpty || batches.any((b) => b.sha256 == null)
          ? null
          : OperationManifest(batches);
}

/// One translate request of a push: the server's hash of its body and how
/// many units it carries.
class ManifestBatch {
  const ManifestBatch(this.sha256, this.unitCount);

  final String? sha256;
  final int unitCount;
}

/// The batch manifest an `authorize {action: translate}` submits.
class OperationManifest {
  OperationManifest(this.batches);

  final List<ManifestBatch> batches;

  int get unitCount => batches.fold(0, (n, b) => n + b.unitCount);

  List<Map<String, Object?>> toJson() => [
    for (final (i, b) in batches.indexed)
      {'index': i, 'sha256': b.sha256, 'unit_count': b.unitCount},
  ];

  /// The server's `ingestBatchSha256({'batches': ...})`: keys sorted, as
  /// `jsonEncode` writes them. The maps above are built in sorted order.
  String get payloadSha256 =>
      sha256.convert(utf8.encode(jsonEncode({'batches': toJson()}))).toString();
}

/// What a push knows before it talks to the server.
class PushScan {
  PushScan({
    required this.extract,
    required this.lock,
    required this.lockFile,
    required this.units,
  });

  final ExtractResult extract;
  final Lockfile lock;
  final File lockFile;

  /// The translate payload, renames folded in. Empty means nothing to push.
  final List<TranslateUnit> units;

  ExtractionResult get extraction => extract.extraction;
  LockfileDiff get diff => extract.diff;

  Map<String, Object?> toJson() => extract.toJson();
}

/// The scan plus its dry run. [result] is null when the scan was empty and no
/// request was made; the shape stays the same so a consumer reads one contract.
class PushPreview {
  PushPreview(this.scan, this.result);

  PushPreview.offline(this.scan) : result = null;

  final PushScan scan;
  final PushResult? result;

  Map<String, Object?> toJson() {
    final r = result;
    return {
      'scan': scan.toJson(),
      'estimate': r == null
          ? null
          : {
              'units_needing_translation': r.unitsNeedingTranslation,
              'estimated_credits': creditsOf(r.estimatedCredits),
              'available_credits': creditsOf(r.spendable),
              'affordable': r.affordable,
              'would_exceed_key_cap': r.wouldExceedKeyCap,
              'skipped_gated': r.skippedGated,
              'skipped_disabled': r.skippedDisabled,
            },
      'exhausted': exhaustedJson(r?.exhaustedPairs ?? const []),
    };
  }
}

/// The whole push as one record: the preview it was judged on, what the real
/// push did (null when nothing was sent), what `--publish` minted and whether
/// the lockfile moved.
class PushReport {
  PushReport({
    required this.preview,
    required this.dryRun,
    this.pushed,
    this.published,
    this.lockfileWritten = false,
  });

  final PushPreview preview;
  final bool dryRun;
  final PushResult? pushed;

  /// Null without `--publish`, and on the `--require-complete` refusal that
  /// throws before the publish call.
  final PublishOutcome? published;

  final bool lockfileWritten;

  Map<String, Object?> toJson() {
    final sent = pushed;
    return {
      'preview': preview.toJson(),
      'pushed': sent == null
          ? null
          : {
              'estimated_credits': creditsOf(sent.estimatedCredits),
              'tracking_tokens': sent.trackingTokens,
              'exhausted': exhaustedJson(sent.exhaustedPairs),
            },
      'published': publishedJson(published),
      'lockfile_written': lockfileWritten,
      'dry_run': dryRun,
    };
  }
}

/// The publish half of a `--json` record, in the shape the `publish` MCP tool
/// already answers with.
Map<String, Object?>? publishedJson(PublishOutcome? outcome) => outcome == null
    ? null
    : {
        'version_id': outcome.versionId,
        'key_count': outcome.keyCount,
        'unchanged': outcome.unchanged,
        'refused': refusedJson(outcome),
      };

/// What the ICU and markup gates kept out of the version: both lists AND both
/// totals. The text run prints the refused cells one per line, so a block
/// carrying only the totals tells an agent less than the humans reading
/// stderr — the blindness #609 fixed, in the other channel. And the server
/// caps each array at 50, so a block carrying only the lists under-reports
/// exactly the publishes that refused the most.
Map<String, Object?> refusedJson(PublishOutcome outcome) => {
  'icu': outcome.icuRejected,
  'icu_total': outcome.icuRejectedTotal,
  'markup': outcome.markupRejected,
  'markup_total': outcome.markupRejectedTotal,
};

/// Credits, not millicredits: the number `--max-credits` is written in.
double creditsOf(int mc) => mc / kMillicreditsPerCredit;

List<Map<String, Object?>> exhaustedJson(List<ExhaustedPair> pairs) => [
  for (final pair in pairs) {'key': pair.key, 'lang': pair.lang},
];
