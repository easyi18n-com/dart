import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'adapters/android_adapter.dart' show AndroidAdapter, kAndroidFormat;
import 'adapters/angular_adapter.dart' show kAngularFormat;
import 'api_client.dart';
import 'backoff.dart';
import 'catalog_layout.dart';
import 'config.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'pull_runner.dart';
import 'push_runner.dart' show creditsOf, exhaustedJson, refusedJson;
import 'state.dart';
import 'xcstrings_catalogs.dart';
import 'xcstrings_merge.dart'
    show xcstringsHasTranslatableEntry, xcstringsLocales;

/// The file-first half of a sync, decided before any credential or network
/// call: which catalog this run uploads and writes back to.
class SyncScan {
  const SyncScan({
    required this.file,
    required this.path,
    this.perLocale = false,
    this.catalogs = const [],
  });

  /// The catalog itself, at [path]; the first of [catalogs] when there are
  /// several.
  final File file;

  /// The files of a `catalogs:` config, uploaded as one catalog.
  final List<CatalogFile> catalogs;

  /// Normalized and relative to the process, like every other path the CLI
  /// prints — the config's `catalog:` resolved against the config's directory.
  final String path;

  /// True when [path] came from `source:`: the base-language file of a
  /// project that keeps one file per locale. Its write-back goes into
  /// `output:` and never onto [path].
  final bool perLocale;

  /// Every file this run writes back to.
  List<File> get files =>
      catalogs.isEmpty ? [file] : [for (final c in catalogs) File(c.path)];

  /// What the upload calls the file. The server keys its format sniffing on
  /// the name, never on the path it came from.
  String get fileName => p.basename(path);
}

/// The scan plus its dry run: the cost gate a real sync is judged on, and the
/// bytes and claim the real POSTs re-send unchanged.
class SyncPreview {
  const SyncPreview({
    required this.scan,
    required this.bytes,
    required this.pulledAt,
    required this.format,
    required this.onConflict,
    required this.configCatalog,
    this.configCatalogs = const [],
    required this.result,
    this.targets = const [],
    this.skippedTargets = const [],
  });

  final SyncScan scan;

  /// Read once, sent by the preview and by every re-POST after it: a catalog
  /// re-read mid-run would price one file and upload another.
  final Uint8List bytes;

  /// What [bytes] is not behind, or null when nothing local can claim it.
  /// Arms the server's base-language guard (#671).
  final DateTime? pulledAt;

  final String? format;
  final String onConflict;

  /// The config's `catalog:` as written, which `pull` finds the recorded
  /// key policy by (D16); [scan] holds it resolved.
  final String? configCatalog;
  final List<String> configCatalogs;

  final SyncResult result;

  /// The target-language files a real run uploads with their `lang` after
  /// the base (`android_xml`): before it, a first sync has no keys for them.
  final List<({String lang, String fileName, Uint8List bytes})> targets;

  /// The target files left out, each with why.
  final List<String> skippedTargets;

  /// The real POST of the body this dry run priced. An approved operation
  /// holds the hash of that body, so the two go through one [_postCatalog].
  Future<SyncResult> send(
    TranslationsApiClient client,
    String projectId, {
    Map<String, Object?> identity = const {},
  }) => _postCatalog(client, projectId, scan, bytes,
      format: format,
      onConflict: onConflict,
      pulledAt: pulledAt,
      identity: identity);

  /// After a real POST of this body that [mayHaveLanded]: whether the project
  /// holds it now, asked of a fresh dry run. With no key left to create and
  /// no source left to change, a target file imports as it would after the
  /// answer (#2319). A dry run that fails too answers no.
  Future<bool> landed(TranslationsApiClient client, String projectId) async {
    try {
      final r = await _postCatalog(client, projectId, scan, bytes,
          format: format,
          onConflict: onConflict,
          pulledAt: pulledAt,
          dryRun: true);
      return r.created == 0 && r.updatedSources == 0;
    } on CliException {
      return false;
    }
  }
}

/// A real POST that failed without proving nothing landed: no answer, a 5xx,
/// or another copy of the request still running on the server.
bool mayHaveLanded(CliException e) =>
    e is! ApiException ||
    e.statusCode >= 500 ||
    (e.statusCode == 409 && e.code == 'request_in_progress');

Future<SyncResult> _postCatalog(
  TranslationsApiClient client,
  String projectId,
  SyncScan scan,
  List<int> bytes, {
  required String? format,
  required String onConflict,
  required DateTime? pulledAt,
  bool dryRun = false,
  Map<String, Object?> identity = const {},
}) => client.sync(
  projectId: projectId,
  fileName: scan.fileName,
  bytes: bytes,
  format: format,
  dryRun: dryRun,
  onConflict: onConflict,
  pulledAt: pulledAt,
  identity: identity,
);

/// The logic half of `easyi18n sync` (`docs/specs/ci-sync.md` §4): what the
/// run decides and asks of the server, with none of the lines it prints. The
/// command owns the transcript; this owns the flow.
class SyncRunner {
  const SyncRunner();

  /// Resolves the configured catalog, refusing a run that has none to upload.
  ///
  /// A per-locale project ends in a pull that replaces its locale files, so
  /// one that changed since the last pull stops the run here, where nothing
  /// was uploaded or charged yet. [force] is the caller saying that pull may
  /// replace them.
  SyncScan scan(Easyi18nConfig config,
      {required String configPath, bool force = false}) {
    if (config.catalogs.isNotEmpty) {
      // Collisions and a missing file are caught here, before any credential.
      final files = CatalogFile.of(config, configPath);
      XcstringsCatalogs.read(files);
      return SyncScan(file: File(files.first.path), path: files.first.path,
          catalogs: files);
    }
    final configured = config.catalog;
    final perLocale = configured == null || configured.isEmpty;
    final catalogRel = perLocale ? config.source : configured;
    if (catalogRel == null || catalogRel.isEmpty) {
      throw CliException(
        'No `catalog:` in $configPath. Point it at your translation catalog '
        '(e.g. `catalog: MyApp/Localizable.xcstrings`) — sync uploads that '
        'file and writes the translated one back to the same path.',
      );
    }
    final root = p.dirname(configPath);
    final path = p.normalize(p.join(root, catalogRel));
    final file = File(path);
    if (!file.existsSync()) {
      throw CliException('Catalog not found: $path');
    }
    if (perLocale && !force) {
      final changed = PullRunner.changedTargets(
          CliState.load(CliState.fileFor(configPath)), root, config);
      if (changed.isNotEmpty) {
        throw editedTargets(changed,
            untouched: 'Nothing was uploaded or charged.');
      }
    }
    // Catch local collisions before credentials or network. Preview selects
    // again with the server's base language: an alias can have another name.
    if (perLocale && mergedLayouts.contains(config.sourceLayout)) {
      mergeCatalog(inputParts(path, root: root, config: config,
          baseCode: p.basenameWithoutExtension(path)));
    }
    return SyncScan(file: file, path: path, perLocale: perLocale);
  }

  /// How [inputParts] tells a one-file layout to take the other base files.
  /// `doctor` repeats it apart: MCP clips a finding's message at 200
  /// characters, and the refusal is longer.
  static const oneCatalogRemedy = 'To sync them as one catalog, set '
      '`sourceLayout: namespaces` (one file per namespace in sourceRoot) or '
      '`sourceLayout: scopes` (source: plus one directory per scope).';

  /// The base-language files of the declared input tree, which is independent
  /// of download destinations: [source] alone, or every file a merged layout
  /// has a place for.
  static List<CatalogPart> inputParts(String source, {
    required String root,
    required Easyi18nConfig config,
    required String baseCode,
  }) {
    final physicalRoot = Directory(root).resolveSymbolicLinksSync();
    String relative(String path) =>
        p.split(p.relative(path, from: physicalRoot)).join('/');
    final sourceName = p.split(p.relative(source, from: root)).join('/');
    final observed = <String>{};
    final selected = <String>{};
    final declaredRoot = config.sourceRoot != null && config.sourceRoot!.isNotEmpty;
    final layout = config.sourceLayout;
    final invalid = [
      if (!declaredRoot) 'sourceRoot',
      if (!{'locale-files', 'base-tree', ...mergedLayouts}.contains(layout)) 'sourceLayout',
    ];
    void unknown() => throw CliException(
        'Declare sourceRoot and sourceLayout (locale-files, base-tree, '
        'namespaces or scopes), and '
        'check source/sourceExclude. The input catalog is unknown; nothing was uploaded.',
        code: 'catalog_scope_unknown', details: {'source': sourceName,
          'fields': invalid, 'files': (observed.toList()..sort()).map(relative).toList()});
    final sourceFile = File(source).resolveSymbolicLinksSync();
    // Angular's base file is `messages.json` and its translations
    // `messages.<locale>.json`: the base name carries no language.
    final baseName = config.format == kAngularFormat
        ? foldLocale(p.basename(source)) : '${foldLocale(baseCode)}.json';
    final others = <String>{};
    var inputRoot = '';
    try {
      // No root is inferred for a missing one: the refusal lists the folder
      // of `source:` and walks nothing else.
      inputRoot = Directory(declaredRoot
          ? p.join(root, config.sourceRoot!) : p.dirname(source)).resolveSymbolicLinksSync();
      final excluded = [for (final path in config.sourceExclude)
        Directory(p.join(root, path)).resolveSymbolicLinksSync()];
      if (excluded.any((path) => !Directory(path).existsSync())) unknown();
      bool excludes(String path) =>
          excluded.any((e) => p.equals(e, path) || p.isWithin(e, path));
      final visited = <String>{};
      void visit(Directory folder) {
        final physicalDir = folder.resolveSymbolicLinksSync();
        if (excludes(physicalDir) || !visited.add(physicalDir)) return;
        for (final entry in folder.listSync()) {
          if (entry is File) {
            final physical = entry.resolveSymbolicLinksSync();
            final names = [entry.path, physical].map((f) => foldLocale(p.basename(f)));
            if (!excludes(physical) && names.any((n) => n.endsWith('.json'))) {
              observed.add(physical);
              if (layout == 'base-tree' || layout == 'namespaces' ||
                  names.contains(baseName)) {
                selected.add(physical);
              }
            }
          } else if (entry is Directory && declaredRoot &&
              (!p.basename(entry.path).startsWith('.') ||
                  p.isWithin(entry.resolveSymbolicLinksSync(), sourceFile))) {
            visit(entry);
          } else if (entry is Link) {
            unknown();
          }
        }
      }
      visit(Directory(inputRoot));
      if (invalid.isNotEmpty || !p.isWithin(inputRoot, sourceFile) ||
          excludes(sourceFile) ||
          !selected.any((f) => FileSystemEntity.identicalSync(f, sourceFile))) {
        unknown();
      }
      for (final file in selected.toList()..sort()) {
        if (!FileSystemEntity.identicalSync(file, sourceFile) &&
            !others.any((other) => FileSystemEntity.identicalSync(other, file))) {
          others.add(file);
        }
      }
    } on FileSystemException {
      unknown();
    }
    if (!mergedLayouts.contains(layout)) {
      if (others.isEmpty) return [CatalogPart('', sourceName, sourceFile)];
      final files = (others.toList()..sort()).map(relative).toList();
      throw CliException(
        '`source:` names $sourceName, and its language has '
        '${files.length} more file(s): ${files.join(', ')}. A sync uploads one '
        'file as the whole catalog of the project, so the keys of the others '
        'would be disabled. $oneCatalogRemedy Nothing was uploaded.',
        code: 'several_files_per_locale',
        details: {'source': sourceName, 'files': files},
      );
    }
    final parts = <CatalogPart>[];
    final unplaced = <String>[];
    for (final file in [sourceFile, ...others]) {
      final prefix = partPrefix(layout!,
          p.split(p.relative(file, from: inputRoot)).join('/'),
          isSource: file == sourceFile);
      if (prefix == null) {
        unplaced.add(relative(file));
      } else {
        parts.add(CatalogPart(prefix, relative(file), file));
      }
    }
    if (layout == 'scopes' && !parts.any((part) => part.prefix.isEmpty)) unknown();
    if (unplaced.isNotEmpty) {
      throw CliException(
        '`sourceLayout: $layout` has no place for ${unplaced.join(', ')}: '
        'namespaces are the JSON files directly in sourceRoot, and scopes '
        'are source: plus the directories one level below it. Move the '
        'file or exclude its directory with sourceExclude. Nothing was '
        'uploaded.',
        code: 'several_files_per_locale',
        details: {'source': sourceName, 'files': unplaced},
      );
    }
    return parts..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The free cost preview: one dry run over the whole catalog. Registers and
  /// spends nothing, and classifies exactly what the real run will.
  Future<SyncPreview> preview(
    TranslationsApiClient client,
    String projectId,
    SyncScan scan, {
    required Easyi18nConfig config,
    required String configPath,
    required String onConflict,
  }) async {
    ({Uint8List bytes, String format})? merged;
    final targets = <({String lang, String fileName, Uint8List bytes})>[];
    final skippedTargets = <String>[];
    if (scan.perLocale) {
      final meta = await client.fetchMeta(projectId: projectId);
      if (meta.baseCode.trim().isEmpty) {
        throw CliException('The project did not return its base language. '
            'The catalog scope is unknown; nothing was uploaded.',
            code: 'catalog_scope_unknown');
      }
      if (config.format == kAndroidFormat) {
        // Each language has its own `values-*` directory, so the base file
        // has no siblings to merge or refuse; its targets go up by `lang`.
        final langs = {for (final l in meta.targets) l.code.toLowerCase(): l.code};
        final res = p.join(p.dirname(configPath), config.output);
        for (final t in AndroidAdapter.targetsIn(res)) {
          final name = '${p.basename(t.file.parent.path)}/strings.xml';
          final code = langs[t.lang.toLowerCase()];
          if (code == null) {
            skippedTargets.add('$name (${t.lang} is not a target language of '
                'the project)');
          } else {
            targets.add((lang: code, fileName: name,
                bytes: t.file.readAsBytesSync()));
          }
        }
      } else {
        final parts = inputParts(scan.path, root: p.dirname(configPath),
            config: config, baseCode: meta.baseCode);
        if (mergedLayouts.contains(config.sourceLayout)) merged = mergeCatalog(parts);
      }
    }
    final bytes = merged?.bytes ??
        (scan.catalogs.isEmpty
            ? scan.file.readAsBytesSync()
            : XcstringsCatalogs.read(scan.catalogs).upload);
    final format = merged?.format ?? config.format;
    final pulledAt = _pulledAt(config, configPath);
    return SyncPreview(
      scan: scan,
      bytes: bytes,
      pulledAt: pulledAt,
      format: format,
      onConflict: onConflict,
      configCatalog: config.catalog,
      configCatalogs: config.catalogs,
      targets: targets,
      skippedTargets: skippedTargets,
      result: await _postCatalog(client, projectId, scan, bytes,
          format: format,
          onConflict: onConflict,
          pulledAt: pulledAt,
          dryRun: true),
    );
  }

  /// Jobs above this many keys poll at [_pollIntervalLarge]: the summary
  /// endpoint reads one doc per PLANNED key per poll. `summary.total` is not
  /// that number — it drops keys deleted or disabled after planning (#593)
  /// while the per-poll cost does not — so the loop throttles on the largest
  /// total it has seen (#614). Keys retired before the first poll are still
  /// invisible to it; only the server exposing the planned count closes that.
  static const int _largeJobKeys = 500;
  static const Duration _pollInterval = Duration(seconds: 5);
  static const Duration _pollIntervalLarge = Duration(seconds: 10);
  static const int maxFillRetries = 2;
  static const int maxContendedRetries = 2;

  /// The whole spending half of a sync: the real POST, the re-POSTs a lost
  /// create race earns, and the wait for every job this run paid for.
  ///
  /// [wait], [random] and [pollTimeout] are injected for the same reason they
  /// always were: the retries are asserted on the durations asked of [wait],
  /// and the give-up branch is reachable only if the deadline can be brought
  /// forward. The clock itself is NOT injected — a fake `wait` that resolves
  /// by microtask plus an injected `now` starves the timer queue, so a
  /// termination regression hangs the suite instead of going red (#1600).
  Future<SyncOutcome> run(
    TranslationsApiClient client,
    String projectId,
    SyncPreview preview, {
    required Easyi18nConfig config,
    required String onConflict,
    required SyncRunProgress progress,
    required Future<void> Function(Duration) wait,
    required Random random,
    required Duration pollTimeout,
  }) async {
    Future<void> sendTargets() async {
      for (final target in preview.targets) {
        progress.onResponse(await client.sync(
          projectId: projectId,
          fileName: target.fileName,
          bytes: target.bytes,
          format: preview.format,
          onConflict: onConflict,
          lang: target.lang,
        ));
      }
    }

    Future<SyncResult> runSync() async {
      try {
        return await client.sync(
          projectId: projectId,
          fileName: preview.scan.fileName,
          bytes: preview.bytes,
          format: preview.format,
          onConflict: onConflict,
          pulledAt: preview.pulledAt,
        );
      } on CliException catch (e) {
        // A lost answer can hide an applied base whose fill is queued: the
        // targets go before its tick, then the run fails as before (#2319).
        if (preview.targets.isNotEmpty &&
            mayHaveLanded(e) &&
            await preview.landed(client, projectId)) {
          try {
            await sendTargets();
          } on CliException {
            // The base may have queued a fill; its unresolved error takes
            // precedence over a failed attempt to recover a language file.
          }
        }
        rethrow;
      }
    }
    // Every response is a report of something that HAPPENED, and the rows are
    // not cumulative on the server's side: a conflict the first POST resolved
    // is simply absent from the re-POST that follows it. The text presenter
    // sees each response as it lands; anything built off the last one alone
    // would drop the rows a superseded attempt was the sole carrier of.
    //
    // Kept WHOLE, one entry per attempt, rather than folded into a union:
    // each response's rows and its own `conflictsTotal` are one statement by
    // one server at one moment. Merging the rows while keeping some other
    // response's total would publish a record that contradicts itself, and
    // neither repair is available — the lists are capped, so the union's
    // length is not a total, and rows repeat across attempts, so the totals
    // do not add.
    final attempts = <SyncResult>[];
    void observe(SyncResult r) {
      attempts.add(r);
      progress.onResponse(r);
    }
    var result = await runSync();
    observe(result);

    // ---- lost create races: re-POST, then fail the run ------------------
    // `contended` is the one `failedEntries` row a retry moves (`ci-sync.md`
    // §Response): a concurrent sync won the create, so the key exists now and
    // this pass applies our catalog on top of it instead of racing for it.
    //
    // What is left contended after the retries is content THIS run never
    // wrote. The server can only report it — 200 with a per-entry slot is its
    // contract — so refusing to exit 0 is the CLI's half, and it is not
    // optional: the two runs may carry different catalogs (two branches
    // building at once), in which case the peer's write is not ours and a
    // green job would drop this branch's strings until someone pushes again.
    var contendedRetries = 0;
    // Jobs queued by an earlier pass of the loop below, which its own
    // re-post then superseded. Each was charged.
    final abandonedTokens = <String>[];
    while (contendedKeys(result).isNotEmpty) {
      final keys = contendedKeys(result);
      if (contendedRetries >= maxContendedRetries) {
        // The reason comes from the row, not from this sentence: the same
        // code now covers a peer sync AND a database-wide write throttle
        // (#591), and telling someone to wait for "the other sync" when
        // there is none sends them looking for a job that does not exist.
        final why = contendedReasons(result);
        throw CliException(
          '${keys.length} entr${keys.length == 1 ? 'y' : 'ies'} went '
          'unwritten after $maxContendedRetries retries: '
          '${keys.join(', ')}. Reported as: ${why.join('; ')}. Re-run the '
          'job.',
        );
      }
      contendedRetries++;
      // Wait first. Both things that produce this row — a peer sync mid-run,
      // and a database-wide write throttle (#591) — are made worse by an
      // instant re-POST, which is what this loop used to do: the retry that
      // exists to recover from saturation was itself part of the load.
      final delay = backoffDelay(contendedRetries, random: random);
      progress.onContendedRetry(
        keys: keys,
        delay: delay,
        attempt: contendedRetries,
        max: maxContendedRetries,
      );
      await wait(delay);
      // A response can carry BOTH a contended row and a tracking token: the
      // entries that DID apply were charged and queued, and only some other
      // entry lost its write. Overwriting `result` drops that token on the
      // floor, and every re-post can leave another one — so they are kept
      // and waited for below. Without that, the run publishes without pairs
      // it has already paid for, and only `pendingSkipped` hints at it.
      if (result.trackingToken case final token?) abandonedTokens.add(token);
      result = await runSync();
      observe(result);
    }

    // ---- target-language files: every key the base names exists now -----
    // Before the wait: an import over a cell the fill has not reached clears
    // its marker, and the fill never writes a cell it does not own.
    await sendTargets();

    // ---- wait for the fill; retry only what is retryable ----------------
    var retries = 0;
    var stillIncomplete = false;
    JobSummary? stoppedShort;
    JobSummary? lastShort;
    // Drained before the loop proper: these jobs are paid for and running,
    // and nothing below would ever ask about them — `result` only carries
    // the last token. No retry pass for them, deliberately: what they could
    // not finish is re-classified by the next run, and re-posting here would
    // ask for a hold on work this run has already shown it cannot place.
    for (final token in abandonedTokens) {
      final summary = await _waitForJob(
        client,
        projectId,
        token,
        wait: wait,
        pollTimeout: pollTimeout,
      );
      // The same three answers the loop below gives, not just one of them:
      // reading only `coveredEverything` into `stillIncomplete` made a
      // timeout and an abandoned job silent, and `stillIncomplete` is
      // consulted only under `--require-complete` — so a job that ran out of
      // credits mid-way exited 0 saying nothing, while the identical state
      // on the LAST job prints an error and exits 1 (#602).
      if (summary == null) {
        stillIncomplete = true;
        progress.onJobTimedOut(abandoned: true);
      } else if (!summary.ranToCompletion) {
        stoppedShort = summary;
      } else if (!summary.coveredEverything) {
        stillIncomplete = true;
      }
    }
    while (result.trackingToken != null) {
      final summary = await _waitForJob(
        client,
        projectId,
        result.trackingToken!,
        wait: wait,
        pollTimeout: pollTimeout,
      );
      if (summary == null) {
        stillIncomplete = true;
        // The job still running IS the outstanding one; keeping an earlier
        // iteration's summary would report its counts against a run that
        // has already superseded them.
        lastShort = null;
        progress.onJobTimedOut(abandoned: false);
        break;
      }
      // Asked before the status, so that whatever ended the job, a run that
      // covered its ask is a clean run: a cancel landing after the last pair
      // was written must not fail a complete catalog.
      if (summary.coveredEverything) {
        lastShort = null;
        break;
      }
      // Terminal is not the same question as done (#602): a cancel and an
      // exhausted balance both END the job, and the pairs they left behind
      // are reported as `pending` — deliberately, since they are
      // recoverable. Reading only `failed` therefore saw a clean summary for
      // a run that translated nothing, published anyway, and wrote the
      // uploaded catalog back as "the translated catalog". No retry here:
      // the plan was not exhausted, it was abandoned, and re-POSTing would
      // ask for a hold the run has already shown it cannot cover.
      if (!summary.ranToCompletion) {
        stoppedShort = summary;
        lastShort = null; // its own message carries the count
        break;
      }
      lastShort = summary;
      if (retries >= maxFillRetries) break;
      retries++;
      progress.onFillRetry(
        pairs: summary.pending + summary.failed,
        attempt: retries,
        max: maxFillRetries,
      );
      // Re-POSTing the same catalog re-classifies and re-queues only what is
      // retryable (exhausted pairs are excluded by the server, and a pair
      // already marked in-flight is never queued twice).
      result = await runSync();
      observe(result);
    }
    if (lastShort case final short?) {
      stillIncomplete = true;
      progress.onShortfall(
        pairs: short.pending + short.failed,
        retries: retries,
      );
    }

    // Asked AGAIN, after the fill loop: that loop also re-posts the catalog
    // (`runSync` at the bottom of it), and nothing looked at its rows. A
    // create race could not realistically produce one there — by then every
    // key exists — but a datastore failure can, and it used to be a 500 that
    // failed the run. Leaving it warn-only would exit 0 on content this run
    // never wrote, which is the one thing the loop above refuses to do.
    if (contendedKeys(result).isNotEmpty) {
      final keys = contendedKeys(result);
      throw CliException(
        '${keys.length} entr${keys.length == 1 ? 'y' : 'ies'} went unwritten '
        'while waiting for the fill: ${keys.join(', ')}. Reported as: '
        '${contendedReasons(result).join('; ')}. Re-run the job.',
      );
    }
    return SyncOutcome(
      result: result,
      attempts: attempts,
      stillIncomplete: stillIncomplete,
      stoppedShort: stoppedShort,
      drainedOwnJobs: abandonedTokens.isNotEmpty,
    );
  }

  /// Publishes what the fill produced and pulls the merged catalog back onto
  /// the configured path — the half of a sync that writes to disk. A
  /// per-locale project has no file to land on: its pull is the directory
  /// one, which writes into `output:` and leaves `source:` as it is.
  ///
  /// `skipIfIdentical` is the server's no-op door: an unchanged project mints
  /// no version and the pull still runs, because the catalog on disk may be
  /// behind a version someone else published.
  Future<SyncDelivery> deliver(
    TranslationsApiClient client,
    String projectId,
    SyncScan scan, {
    required Easyi18nConfig config,
    required String configPath,
    required CliLogger logger,
    required void Function(PublishOutcome) onPublished,
    bool force = false,
  }) async {
    final published = await client.publish(
      projectId: projectId,
      incompleteMode: 'skip',
      skipIfIdentical: true,
      requiredOutputFormat: config.format,
    );
    onPublished(published);
    final version = await PullRunner(logger).pullOnce(
      client: client,
      config: config,
      projectId: projectId,
      configPath: configPath,
      version: null,
      lang: null,
      dryRun: false,
      syncCatalogTarget: scan.perLocale ? null : scan.path,
      force: force,
    );
    return SyncDelivery(published: published, pulledVersion: version);
  }

  /// Reads the catalog that was just WRITTEN back and names both ways it
  /// disagrees with what the server said it would deliver (#592).
  ///
  /// This is the check that cannot be fooled by *why* a language went missing:
  /// the exporter emits no entry at all for a language with no values, and the
  /// merge is a pure upsert, so "never planned", "manual", and "every pair
  /// failed" all produce the same file. Reading the file back is the only
  /// statement about the outcome that is not a restatement of the plan.
  ///
  /// [alreadyNamed] are the folded locales the pre-estimate line already
  /// reported as carried-but-unconfigured. They are still in the file — the
  /// merge never deletes — so repeating them would give the same locale two
  /// warnings on every run.
  static CatalogLanguageGaps verifyCatalogLanguages(
    List<File> catalogFiles,
    SyncResult r,
    Set<String> alreadyNamed,
  ) {
    final gaps = [
      for (final f in catalogFiles) _verifyCatalogFile(f, r, alreadyNamed),
    ];
    return CatalogLanguageGaps(
      missing: {for (final g in gaps) ...g.missing}.toList(),
      extra: {for (final g in gaps) ...g.extra}.toList()..sort(),
    );
  }

  static CatalogLanguageGaps _verifyCatalogFile(
    File catalogFile,
    SyncResult r,
    Set<String> alreadyNamed,
  ) {
    // The two halves have different inputs and therefore different guards, and
    // collapsing them into one cost the more valuable half:
    //
    //  - "configured but missing" iterates `fillableLangs`, which a pre-#592
    //    server does not send. Empty there is "unknown", not "none" — and it
    //    is ALSO what a project whose every language is `manual` looks like,
    //    which JSON cannot tell apart. Either way saying nothing is right, and
    //    iterating the empty list is already exactly that: no extra guard.
    //  - "in the catalog, configured nowhere" reads only `targetLangs` and
    //    `baseCode`, which every server that ever answered `/sync` sends. That
    //    is the half that names #592's own `zh` and `pt-BR`, so gating it on a
    //    field the server may not send would have muted the headline symptom
    //    against exactly the deployments that still have it — and gating it on
    //    `targetLangs` being non-empty did exactly that for a project whose
    //    only configured language is its base.
    if (r.baseCode.isEmpty) return const CatalogLanguageGaps();
    final String content;
    try {
      content = catalogFile.readAsStringSync();
    } on FileSystemException {
      return const CatalogLanguageGaps(); // The pull already reported it.
    }
    // Null is "cannot read", not "carries nothing": announcing that every
    // configured language went missing because the file is unparseable would
    // be a fabrication on top of whatever really went wrong.
    final locales = xcstringsLocales(content);
    if (locales == null) return const CatalogLanguageGaps();
    final present = {for (final l in locales) foldLocale(l)};
    // A catalog with nothing to translate cannot be missing a language. Every
    // entry opting out is an ordinary state for a dev-only catalog (#612), no
    // fill will ever write a locale into one, and "re-run the sync" there is
    // advice that can never work — printed on every CI run, forever.
    final missing = xcstringsHasTranslatableEntry(content) == false
        ? const <String>[]
        : [
            for (final code in r.fillableLangs)
              if (!present.contains(foldLocale(code))) code,
          ];
    final known = {
      foldLocale(r.baseCode),
      for (final l in r.targetLangs) foldLocale(l),
    };
    // What survives the subtraction is the case the server could not have told
    // us about: an older backend whose diagnostics the CLI cannot group.
    final extra = [
      for (final l in locales)
        if (!known.contains(foldLocale(l)) &&
            !alreadyNamed.contains(foldLocale(l)))
          l,
    ]..sort();
    return CatalogLanguageGaps(missing: missing, extra: extra);
  }

  /// The CLI's own copy of the server's stored-code fold (trim, `_`→`-`,
  /// lowercase). Duplicated rather than imported because this package ships
  /// standalone and does not depend on `easyi18n_core`; it only ever compares
  /// codes, never stores or renders one, so it cannot drift into a spelling
  /// decision.
  static String foldLocale(String code) =>
      code.trim().replaceAll('_', '-').toLowerCase();

  /// The `failedEntries` rows a re-POST can converge: the key is already
  /// created by the peer, so the next pass patches it instead of racing.
  static List<String> contendedKeys(SyncResult r) => [
    for (final f in r.failedEntries)
      if (f['code'] == 'contended') '${f['key']}',
  ];

  /// The distinct `reason` strings those rows carried. Distinct, because one
  /// row per key would repeat the same sentence hundreds of times on a run
  /// the datastore throttled wholesale.
  static List<String> contendedReasons(SyncResult r) => {
    for (final f in r.failedEntries)
      if (f['code'] == 'contended' && f['reason'] is String)
        f['reason'] as String,
  }.toList();

  /// Polls one job to a terminal state, or null when the deadline passes
  /// first. The interval throttles on the largest total seen (#614).
  Future<JobSummary?> _waitForJob(
    TranslationsApiClient client,
    String projectId,
    String trackingToken, {
    required Future<void> Function(Duration) wait,
    required Duration pollTimeout,
  }) async {
    final deadline = DateTime.now().add(pollTimeout);
    JobSummary summary;
    var largestTotal = 0;
    while (true) {
      summary = await client.fetchJobSummary(
        projectId: projectId,
        trackingToken: trackingToken,
      );
      if (summary.terminal) return summary;
      if (DateTime.now().isAfter(deadline)) return null;
      if (summary.total > largestTotal) largestTotal = summary.total;
      await wait(
        largestTotal > _largeJobKeys ? _pollIntervalLarge : _pollInterval,
      );
    }
  }

  /// What THIS catalog's content is not behind — the claim that arms the
  /// server's base-language guard (#671). Only when the recorded pull
  /// describes this same file: the state belongs to whatever target the
  /// last explicit `pull` wrote, and after a config switch its timestamp
  /// is a claim about another file — arming the guard with it would date
  /// this catalog by that one's pull. Absent state (the CI flow, where
  /// `sync`'s own final pull deliberately records nothing) sends nothing,
  /// which is the server's signal to behave as before.
  ///
  /// `snapshotAt` FIRST, and the order is the fix (#898): it is the
  /// server's stamp for the published snapshot these bytes came from,
  /// while `pulledAt` is the local clock at fetch time. Under `--version`
  /// those are days apart, and even a plain `pull` serves content as old
  /// as the last publish — claiming the pull moment says the file already
  /// carried a dashboard edit it never saw, and the guard stays mute while
  /// the correction is reverted. `pulledAt` is only the fallback for state
  /// an older CLI wrote.
  ///
  /// A `source:` project never has a claim: no pull writes its base file,
  /// so the stamp of one dates the other locales and nothing this uploads.
  static DateTime? _pulledAt(Easyi18nConfig config, String configPath) {
    final state = CliState.load(CliState.fileFor(configPath));
    return state.catalog == config.catalog &&
            jsonEncode(state.catalogs) == jsonEncode(config.catalogs) &&
            state.format == config.format &&
            (state.catalog != null || state.catalogs.isNotEmpty)
        ? state.snapshotAt ?? state.pulledAt
        : null;
  }
}

/// When the run loop produces a line, never what it says. Every word stays in
/// the command, which owns the transcript; this is the order.
abstract interface class SyncRunProgress {
  /// Every response of the real run, in the order the server answered — the
  /// first POST and every re-POST the retries make. The preview is reported
  /// by the caller, not through here.
  void onResponse(SyncResult result);

  /// A re-POST for entries a peer won the create race for, about to wait
  /// [delay] (#591).
  void onContendedRetry({
    required List<String> keys,
    required Duration delay,
    required int attempt,
    required int max,
  });

  /// A job this run paid for was still running when the poll deadline passed.
  /// [abandoned] is a job an earlier re-POST superseded, whose pairs no later
  /// pass will ask about — a different sentence from the run's last job.
  void onJobTimedOut({required bool abandoned});

  /// A re-POST of the catalog to re-queue [pairs] the fill left behind.
  void onFillRetry({
    required int pairs,
    required int attempt,
    required int max,
  });

  /// The fill ended with [pairs] still untranslated after [retries] re-POSTs.
  ///
  /// Emitted from inside the run, not derived from its result, because the run
  /// can still refuse afterwards: a re-POST that answers a `contended` row
  /// throws before any outcome exists, and an operator told only that the run
  /// failed never learns what it left untranslated.
  void onShortfall({required int pairs, required int retries});
}

/// What the run loop settled, once every job it paid for is accounted for.
class SyncOutcome {
  const SyncOutcome({
    required this.result,
    required this.attempts,
    required this.stillIncomplete,
    required this.stoppedShort,
    required this.drainedOwnJobs,
  });

  /// The last response, which is what the publish and the pull are judged on.
  final SyncResult result;

  /// Every real POST's response, in order; [result] is the last of them.
  ///
  /// The channels only `/v1/sync` reports are per-response: a conflict the
  /// first POST resolved is absent from the re-POST a contended entry forces
  /// (#671 base-language sources among them), and `PLURAL_BEHIND_PROJECT` is
  /// derived from the STORED plural, so it too is per-attempt rather than a
  /// function of the bytes (#727). Reading only [result] loses whatever an
  /// attempt was the sole carrier of.
  final List<SyncResult> attempts;

  /// A pair this run paid for that it cannot say was translated. Only
  /// `--require-complete` acts on it; everything else warns.
  final bool stillIncomplete;

  /// A job that ended before finishing its own plan (#602) — cancelled, out
  /// of credits, failed. Not the same as failing pairs: what it did not
  /// translate is queued nowhere.
  final JobSummary? stoppedShort;

  /// This run drained jobs of its own, so a "held by another fill" count may
  /// already be covered by them and the sentence must not name a cause it can
  /// no longer stand behind.
  final bool drainedOwnJobs;
}

/// The gaps between the catalog just written and what the project configures
/// (#592). Both are warn-only: `--require-complete` is the flag for CI that
/// wants red, and a catalog legitimately carrying an extra locale must not
/// start failing every build.
class CatalogLanguageGaps {
  const CatalogLanguageGaps({
    this.missing = const [],
    this.extra = const [],
  });

  /// Configured and fillable, but absent from the file this run wrote.
  final List<String> missing;

  /// In the file, configured nowhere — left exactly as it was.
  final List<String> extra;

  bool get isEmpty => missing.isEmpty && extra.isEmpty;

  Map<String, Object?> toJson() => {'missing': missing, 'extra': extra};
}

/// The publish and the pull that close a sync.
class SyncDelivery {
  const SyncDelivery({
    required this.published,
    required this.pulledVersion,
    this.languages,
  });

  final PublishOutcome published;

  /// The version the pull rendered from, which is what the catalog on disk
  /// now carries. Null when the pull failed after the publish.
  final String? pulledVersion;

  /// Null until the catalog written back has been read: an empty value would
  /// say it has no gaps.
  final CatalogLanguageGaps? languages;

  SyncDelivery withLanguages(CatalogLanguageGaps gaps) => SyncDelivery(
    published: published,
    pulledVersion: pulledVersion,
    languages: gaps,
  );

  Map<String, Object?> toJson() => {
    'version_id': published.versionId,
    'unchanged': published.unchanged,
    'key_count': published.keyCount,
    'refused': refusedJson(published),
    'pulled_version': pulledVersion,
    'languages': languages?.toJson(),
  };
}

/// The whole sync as one record: what it was priced on, what the run settled,
/// and what reached the disk.
class SyncReport {
  const SyncReport({
    required this.preview,
    required this.dryRun,
    this.outcome,
    this.answered = const [],
    this.delivery,
    this.outputFormat,
  });

  final SyncPreview preview;
  final bool dryRun;

  /// Null on `--dry-run`, where nothing was posted for real, and when the run
  /// failed before it settled.
  final SyncOutcome? outcome;

  /// The answered POSTs of a run that failed before it settled. They applied
  /// the catalog, so they are reported, and what only [outcome] decides
  /// (`still_incomplete`, `stopped_short`) stays null (#1835).
  final List<SyncResult> answered;

  /// Null on `--dry-run` and `--no-publish`, where nothing was published or
  /// written back.
  final SyncDelivery? delivery;
  final Map<String, Object?>? outputFormat;

  List<SyncResult> get _attempts => outcome?.attempts ?? answered;

  Map<String, Object?> toJson() => {
    'preview': syncResultJson(preview.result),
    // The state the publish and the pull were judged on: the last response,
    // with ITS rows and ITS totals. Self-consistent, because a consumer that
    // summarises off `conflicts_total` must never read a total that belongs
    // to a different set of rows.
    'synced': _attempts.isEmpty
        ? null
        : syncResultJson(outcome?.result ?? _attempts.last),
    // Where nothing is lost: one entry per real POST, each carrying the rows
    // that attempt reported and the total the server sent with them. A row
    // only a superseded attempt saw lives here and nowhere else.
    'attempts': _attempts.isEmpty
        ? null
        : [
            for (final attempt in _attempts)
              {
                'conflicts': attempt.conflicts,
                'conflicts_total': attempt.conflictsTotal,
                'diagnostics': attempt.diagnostics,
                'diagnostics_omitted': attempt.diagnosticsOmitted,
              },
          ],
    'still_incomplete': outcome?.stillIncomplete,
    'stopped_short': outcome?.stoppedShort == null
        ? null
        : {
            'status': outcome!.stoppedShort!.status,
            'pending': outcome!.stoppedShort!.pending,
            'failed': outcome!.stoppedShort!.failed,
          },
    'delivery': delivery?.toJson(),
    if (outputFormat != null) 'output_format': outputFormat,
    'dry_run': dryRun,
  };
}

/// One `/v1/sync` response, verbatim where the server's own vocabulary is the
/// contract. `conflicts` and `diagnostics` pass through untouched on purpose:
/// a code this serialization drops is a code the agent never sees, and both
/// carry rows (#671 base-language sources, #727 per-language parse findings)
/// that no other channel reports.
Map<String, Object?> syncResultJson(SyncResult r) => {
  'dry_run': r.dryRun,
  'created': r.created,
  'updated_sources': r.updatedSources,
  'matched_sources': r.matchedSources,
  'updated_translations': r.updatedTranslations,
  'unchanged_translations': r.unchangedTranslations,
  'disabled_orphans': r.disabledOrphans,
  'reenabled': r.reenabled,
  'not_in_code': r.notInCode,
  'skipped_gated': r.skippedGated,
  'accepted': r.accepted,
  'would_exceed_key_cap': r.wouldExceedKeyCap,
  'estimated_credits': creditsOf(r.estimatedCredits),
  'available_credits': creditsOf(r.spendable),
  'pending_skipped': r.pendingSkipped,
  'base_code': r.baseCode,
  'target_langs': r.targetLangs,
  'fillable_langs': r.fillableLangs,
  'conflicts': r.conflicts,
  'conflicts_total': r.conflictsTotal,
  'on_conflict': r.onConflict,
  'diagnostics': r.diagnostics,
  'diagnostics_omitted': r.diagnosticsOmitted,
  'exhausted': exhaustedJson(r.exhaustedPairs),
  'failed_entries': r.failedEntries,
  'tracking_token': r.trackingToken,
};
