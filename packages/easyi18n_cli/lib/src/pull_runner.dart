import 'dart:convert';
import 'dart:io';

import 'package:intl/locale.dart';
import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'catalog_layout.dart';
import 'cli_output.dart';
import 'config.dart';
import 'delivery.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'offline_floor.dart';
import 'output_format.dart';
import 'state.dart';
import 'sync_runner.dart';
import 'xcstrings_catalogs.dart';
import 'xcstrings_merge.dart';

/// The pull machinery, extracted from `PullCommand` so `easyi18n sync` can
/// reuse it (ci-sync.md Fase 2): fetch → guard every path → prune → atomic
/// write → record state.
///
/// Two destinations, decided by the config: a `catalog:` names ONE file the
/// project already owns (`EscapeCall/Localizable.xcstrings`) and wins; an
/// `output:` names a directory of per-locale files this pull owns and
/// rewrites. `sync` passes [pullOnce]'s `syncCatalogTarget` for the file it
/// just uploaded, which also selects the merge policy — see
/// [XcstringsKeyPolicy]. A `source:` names the one file of that directory the
/// developer writes, and no pull ever writes it.
class PullRunner {
  PullRunner(this._logger, {DeliveryClientFactory? deliveryFactory})
      : _deliveryFactory = deliveryFactory ?? _defaultDelivery;

  final CliLogger _logger;
  final DeliveryClientFactory _deliveryFactory;

  static DeliveryClient _defaultDelivery({required String baseUrl}) =>
      DeliveryClient(baseUrl: baseUrl);


  /// Compatibility entry point for sync and the text watcher.
  Future<String> pullOnce({
    required TranslationsApiClient client,
    required Easyi18nConfig config,
    required String projectId,
    required String configPath,
    required String? version,
    required String? lang,
    required bool dryRun,
    String? syncCatalogTarget,
    OutputFormatAdoption? recovery,
    bool force = false,
  }) async => (await pullOnceDetailed(
    client: client, config: config, projectId: projectId,
    configPath: configPath, version: version, lang: lang, dryRun: dryRun,
    syncCatalogTarget: syncCatalogTarget, recovery: recovery, force: force,
  )).version;

  Future<PullOutcome> pullOnceDetailed({
    required TranslationsApiClient client,
    required Easyi18nConfig config,
    required String projectId,
    required String configPath,
    required String? version,
    required String? lang,
    required bool dryRun,
    String? syncCatalogTarget,
    XcstringsKeyPolicy? keyPolicy,
    OutputFormatAdoption? recovery,
    void Function(PullOutcome applied)? onApplied,
    bool force = false,
  }) async {
    final adoption = recovery ?? OutputFormatAdoption(config.format);
    try {
      return await _pullOnceDetailed(client: client, config: config,
          projectId: projectId, configPath: configPath, version: version,
          lang: lang, dryRun: dryRun, syncCatalogTarget: syncCatalogTarget,
          keyPolicy: keyPolicy, recovery: adoption, onApplied: onApplied,
          force: force);
    } on CliException catch (e) {
      throw adoption.annotate(e);
    } on FileSystemException catch (e) {
      if (!adoption.created) rethrow;
      throw FileSystemException('${e.message}\n${adoption.confirmedMessage}',
          e.path, e.osError);
    }
  }

  /// Fetch, write atomically and record state, returning paths and coverage.
  Future<PullOutcome> _pullOnceDetailed({
    required TranslationsApiClient client,
    required Easyi18nConfig config,
    required String projectId,
    required String configPath,
    required String? version,
    required String? lang,
    required bool dryRun,
    // Sync mode: the single served file (a multi-language catalog) lands on
    // this exact path — whatever name the server gave it — and the pull skips
    // prune/state/hints (the catalog file IS the state). Passing it also says
    // the caller UPLOADED that file, which is what makes the server's key set
    // authoritative for deletions.
    String? syncCatalogTarget,
    XcstringsKeyPolicy? keyPolicy,
    required OutputFormatAdoption recovery,
    void Function(PullOutcome applied)? onApplied,
    required bool force,
  }) async {
    final isSync = syncCatalogTarget != null;
    final policy = keyPolicy ?? (isSync
        ? XcstringsKeyPolicy.localOwnsKeySet : XcstringsKeyPolicy.union);
    // `catalog:` addresses one file, so it decides the destination whenever
    // it is set. `output` cannot express that: it is a directory, and it
    // always holds a value (the default is applied in the constructor), so an
    // untouched `output` is indistinguishable from a deliberate one — which
    // is how a configured catalog used to end up in `lib/l10n` (#552).
    final catalogTarget =
        syncCatalogTarget ?? _resolved(config.catalog, configPath);
    final source = _resolved(config.source, configPath);
    // `catalogs:` is read before the request: a missing file or a key two files
    // hold stops the pull with nothing fetched or written.
    final catalogs = config.catalogs.isEmpty
        ? null
        : XcstringsCatalogs.read(CatalogFile.of(config, configPath));

    // Honouring `catalog:` means writing ONE served file to a path the project
    // owns. Checking only that the backend served one file is not enough: a
    // per-locale format serves exactly one when the project has one language,
    // and that render would land inside the catalog reporting success — #552's
    // failure from the other side. The format has to be one that renders a
    // whole catalog, and that is knowable before the request.
    if ((catalogTarget != null || catalogs != null) &&
        !Easyi18nConfig.catalogFormats.contains(config.format)) {
      throw FatalCliException(
        '`catalog:` names one file holding every language, but format '
        '"${config.format}" renders one file per locale. Either remove '
        '`catalog:` (those files belong in `output:`) or set a catalog '
        'format: ${Easyi18nConfig.catalogFormats.join(', ')}.',
      );
    }

    Future<PulledTranslations> fetch() => client.fetchTranslations(
      projectId: projectId, format: config.format, version: version, lang: lang,
    );
    late PulledTranslations pulled;
    try {
      pulled = await fetch();
    } on ApiException catch (e) {
      if (isSync || e.statusCode != 400 ||
          (e.code != 'invalid_argument' && e.code != 'no_formats')) {
        rethrow;
      }
      await recovery.preflight(client, projectId, recoveryError: e);
      if (recovery.state == OutputFormatState.alreadyEnabled) rethrow;
      if (dryRun) {
        throw CliException('Dry run: output format "${config.format}" needs '
            'conditional adoption before files can be downloaded. No format '
            'was written and no files were downloaded.',
            code: 'output_format_pending');
      }
      await recovery.apply(client, projectId, _logger);
      pulled = await fetch();
    }

    if (pulled.files.isEmpty) {
      throw CliException(
        'The backend returned no files for format "${config.format}". '
        'Is that format configured for the project?',
      );
    }

    // A merged layout's base is every file it uploads; none is ever written.
    final parts = catalogTarget == null && source != null &&
            mergedLayouts.contains(config.sourceLayout)
        ? SyncRunner.inputParts(source, root: p.dirname(configPath),
            config: config, baseCode: pulled.baseCode)
        : null;
    final bases = [
      ?source,
      for (final part in parts ?? const <CatalogPart>[]) part.file,
    ];

    // What these bytes are NOT behind (#898). The server dates the snapshot
    // it rendered; the local clock only stands in when it did not report one
    // (an older backend, or a value naming no zone), which is the pre-#898
    // behavior — this run keeps arming the server's base-language guard
    // instead of falling out of it.
    //
    // It is not what protects a state file written BEFORE the upgrade: that
    // one has no `snapshotAt` at all, and `sync` covers it by falling back to
    // `pulledAt` (`sync_command.dart`). Both stamps are written here on every
    // pull, so the two fallbacks land on the same instant — writing null here
    // would read as the same claim, one hop later.
    final snapshotAt = pulled.snapshotAt ?? DateTime.now().toUtc();
    if (pulled.snapshotAt == null) {
      _logger.detail(
        'The server did not report when this version was published; dating '
        'this pull by the local clock.',
      );
    }

    if (catalogs != null) {
      final paths = [for (final f in catalogs.files) f.path];
      _refuseSourceWrites([
        for (final path in paths) ...[path, '$path.tmp'],
      ], bases);
      if (pulled.files.length != 1) {
        throw FatalCliException(
          'Expected one catalog file for format "${config.format}" but the '
          'backend served ${pulled.files.length}.',
        );
      }
      final split = catalogs.split(pulled.files.values.single);
      // Every file's content is settled before the first one is written, so a
      // merge that refuses cannot leave the catalogs on two versions.
      final merged = [
        for (final (i, path) in paths.indexed)
          _contentFor(File(path), split.parts[i], config, keyPolicy: policy),
      ];
      for (final m in merged) {
        _warnBaseReplacements(m.baseReplacements, isSync: isSync, dryRun: dryRun);
      }
      if (split.unplaced.isNotEmpty) {
        _logger.warn(
          '${split.unplaced.length} key(s) of version ${pulled.version} are in '
          'none of the catalogs and were not written: ${split.unplaced.join(', ')}',
        );
      }
      _logger.info(
        '${dryRun ? 'Would write' : 'Wrote'} the translated catalogs '
        '(version ${pulled.version}) to ${paths.join(', ')}',
      );
      if (!dryRun) {
        for (final (i, path) in paths.indexed) {
          File('$path.tmp').writeAsStringSync(merged[i].content);
        }
        for (final path in paths) {
          File('$path.tmp').renameSync(path);
        }
        if (!isSync) {
          _recordCatalogPull(configPath, config, pulled.version, snapshotAt);
        }
      }
      return PullOutcome(pulled, destination: 'catalog', keyPolicy: policy,
        files: paths, pruned: const [], dryRun: dryRun,
        configPath: configPath, baseUrl: config.baseUrl,
        unplaced: split.unplaced);
    }

    if (catalogTarget != null) {
      _refuseSourceWrites([catalogTarget, '$catalogTarget.tmp',
        if (!isSync) CliState.fileFor(configPath).path], bases);
      if (pulled.files.length != 1) {
        // Fatal: the count is a property of the format and the project, so
        // the next cycle serves the same thing.
        throw FatalCliException(
          'Expected one catalog file for format "${config.format}" but the '
          'backend served ${pulled.files.length}.',
        );
      }
      final file = File(catalogTarget);
      // Computed under --dry-run too (the merge writes nothing): it is the
      // one moment the replacement warning can precede the destruction.
      final merged = _contentFor(
        file,
        pulled.files.values.single,
        config,
        keyPolicy: policy,
      );
      _warnBaseReplacements(merged.baseReplacements, isSync: isSync, dryRun: dryRun);
      _logger.info(
        '${dryRun ? 'Would write' : 'Wrote'} the translated catalog '
        '(version ${pulled.version}) to $catalogTarget',
      );
      if (!dryRun) {
        file.parent.createSync(recursive: true);
        final tmp = File('$catalogTarget.tmp');
        tmp.writeAsStringSync(merged.content);
        tmp.renameSync(catalogTarget);
        // `sync` records nothing: it runs in CI on every push, and a fresh
        // `pulledAt` in a repo whose config predates `init`'s .gitignore
        // patch is a diff — which is the signal the action opens a PR on.
        if (!isSync) {
          _recordCatalogPull(configPath, config, pulled.version, snapshotAt);
        }
      }
      return PullOutcome(pulled, destination: 'catalog', keyPolicy: policy,
        files: [catalogTarget], pruned: const [], dryRun: dryRun,
        configPath: configPath, baseUrl: config.baseUrl);
    }

    final outputDir = p.normalize(p.join(p.dirname(configPath), config.output));
    final fullPull = lang == null;
    final files = parts == null ? pulled.files : <String, String>{};
    if (parts != null) {
      for (final e in pulled.files.entries) {
        final code = p.posix.basenameWithoutExtension(e.key);
        final split = splitCatalog(e.value, code, config.sourceLayout!, parts);
        if (split.unplaced.isNotEmpty) {
          _logger.warn('$code: ${split.unplaced.length} key(s) belong to no '
              'file of the ${config.sourceLayout} layout and were not '
              'written: ${split.unplaced.join(', ')}');
        }
        files.addAll(split.files);
      }
    }

    // Resolve and guard every path up front, so a bad key aborts the pull
    // before anything is pruned or written.
    final entries = <({String relPath, String stripped, String target})>[];
    final served = <String>{};
    final kept = <String>[];
    final named = _templateNames(config.source, pulled.baseCode, outputDir);
    for (final relPath in files.keys.toList()..sort()) {
      final stripped = named(_stripFormatPrefix(relPath, config.format));
      // The file keys come from the backend; a traversing or absolute key
      // (`../`, `/etc/...`) must never write outside the output directory.
      final target = _resolveWithin(outputDir, stripped);
      if (target == null) {
        throw CliException(
          'Refusing to write "$relPath": resolves outside $outputDir.',
        );
      }
      served.add(stripped);
      if (_isSource(target, bases)) {
        kept.add(stripped);
        continue;
      }
      entries.add((relPath: relPath, stripped: stripped, target: target));
    }
    final stateFile = CliState.fileFor(configPath);
    final previous = CliState.load(stateFile);
    // Recorded paths only mean something under the format + output dir they
    // were written into — after a switch they must never be pruned.
    final sameTarget =
        previous.format == config.format &&
        previous.output != null &&
        p.normalize(previous.output!) == p.normalize(config.output);
    // Before the line that announces the files, the prune and the first
    // write, dry run included: a refusal half way would leave some locales on
    // the new version and one on the old.
    if (!force) {
      final changed = previous.changedSincePull(
        p.dirname(configPath),
        config.output,
        among: [
          for (final e in entries) e.stripped,
          if (fullPull && sameTarget)
            for (final rel in previous.files ?? const <String>[])
              if (!served.contains(rel) &&
                  !_isSource(p.join(outputDir, rel), bases)) rel,
        ],
        incoming: {for (final e in entries) e.stripped: files[e.relPath]!},
      );
      if (changed.isNotEmpty) {
        throw editedTargets(changed, untouched: 'Nothing was written.');
      }
    }
    _logger.info(
      '${dryRun ? 'Would pull' : 'Pulled'} ${entries.length} file(s) '
      'for ${config.describeRef} (version ${pulled.version}) into $outputDir',
    );
    for (final name in kept) {
      _logger.detail('$name left as it is: it is a base-language file');
    }
    final written = {for (final e in entries) e.stripped};
    final floor = await _fetchFloor(config, configPath, projectId,
        version: version, lang: lang);

    _refuseSourceWrites([
      for (final e in entries) '${e.target}.tmp',
      for (final target in floor.keys) ...[target, '$target.tmp'],
      stateFile.path,
    ], bases);
    final pruned = fullPull && sameTarget
        ? _prune(previous.files ?? const [], served, outputDir,
            bases: bases, dryRun: dryRun)
        : <String>[];
    // What is already on disk, for a caller whose record has to outlive a
    // write that fails half way (#1835).
    final done = <String>[];
    final digests = <String, String>{};
    void applied() => onApplied?.call(PullOutcome(pulled,
        destination: 'directory', keyPolicy: policy, files: done,
        pruned: pruned, dryRun: dryRun, configPath: configPath,
        baseUrl: config.baseUrl));
    if (pruned.isNotEmpty && !dryRun) applied();

    for (final e in entries) {
      final file = File(e.target);
      final merged = _contentFor(
        file,
        files[e.relPath]!,
        config,
        keyPolicy: policy,
      );
      _warnBaseReplacements(merged.baseReplacements, isSync: isSync, dryRun: dryRun);
      if (dryRun) {
        _logger.detail(e.stripped);
        continue;
      }
      file.parent.createSync(recursive: true);
      // Write to a sibling temp file then atomically rename, so a mid-write
      // failure can't leave a half-written (un-`gen-l10n`-able) .arb in place.
      final tmp = File('${e.target}.tmp');
      tmp.writeAsStringSync(merged.content);
      tmp.renameSync(e.target);
      done.add(e.target);
      // A String Catalog is merged with the local file, never replaced.
      if (config.format != 'xcstrings') {
        digests[e.stripped] = contentDigest(merged.content);
      }
      applied();
      _logger.detail(e.stripped);
    }
    if (floor.isNotEmpty) {
      _logger.info('${dryRun ? 'Would bake' : 'Baked'} the offline floor '
          '(${floor.length} locale(s)) into '
          '${p.dirname(floor.keys.first)}');
    }
    if (!dryRun) {
      for (final e in floor.entries) {
        File(e.key).parent.createSync(recursive: true);
        File('${e.key}.tmp')
          ..writeAsStringSync(e.value)
          ..renameSync(e.key);
        done.add(e.key);
        applied();
      }
    }

    if (!dryRun) {
      if (fullPull && previous.files == null) {
        _hintLeftovers(outputDir, served, bases: bases);
      } else if (fullPull && !sameTarget && previous.files != null) {
        _hintSwitchedTarget(configPath, previous, bases: bases);
      }
      // Record what now sits on disk for `status` and the next pull's prune.
      // Best-effort: a cache write must never fail a successful pull.
      final recorded = fullPull || !sameTarget
          ? written
          : {...?previous.files, ...written};
      try {
        CliState(
          version: pulled.version,
          pulledAt: DateTime.now().toUtc(),
          snapshotAt: snapshotAt,
          format: config.format,
          output: config.output,
          files: recorded.toList()..sort(),
          digests: {
            for (final e in (previous.digests ?? const {}).entries)
              if (recorded.contains(e.key)) e.key: e.value,
            ...digests,
          },
        ).save(stateFile);
      } on FileSystemException {
        _logger.detail(
          'Could not write ${CliState.dirName}/${CliState.fileName}.',
        );
      }
      if (config.format == 'arb' && floor.isEmpty) {
        _logger.info(
          "Run 'flutter gen-l10n' to regenerate your localizations.",
        );
      }
    }
    return PullOutcome(pulled, destination: 'directory', keyPolicy: policy,
      files: [...entries.map((e) => e.target), ...floor.keys], pruned: pruned,
      dryRun: dryRun, configPath: configPath, baseUrl: config.baseUrl);
  }

  /// The offline floor a Mode B app ships, fetched before anything is written
  /// so a bad bundle leaves the disk as it was. Empty when the app bundles no
  /// floor, or when a pinned [version] asks for bytes the live manifest does
  /// not serve.
  Future<Map<String, String>> _fetchFloor(Easyi18nConfig config,
      String configPath, String projectId,
      {required String? version, required String? lang}) async {
    if (config.mode == 'a') return const {};
    final floor = OfflineFloor.of(p.dirname(configPath));
    if (floor == null) return const {};
    if (version != null) {
      _logger.info('The offline floor comes from the live version; '
          '--version $version leaves ${floor.dir.path} as it is.');
      return const {};
    }
    final client = _deliveryFactory(baseUrl: config.baseUrl);
    try {
      return await floor.fetch(client, projectId, lang: lang);
    } finally {
      client.close();
    }
  }

  /// The Mode A completeness gate (#1052): the translations live on the
  /// server, so "are we complete?" is answered by the pulled version's
  /// per-language coverage, not by anything in the code. A backend that
  /// does not report it cannot be read as complete — the gate refuses, and
  /// says why, rather than turn silence into a green.
  void gateComplete(PullOutcome pulled, {required String? lang}) {
    final coverage = pulled.coverage;
    if (coverage == null) {
      throw CliException(
          'The server did not report per-language coverage, so '
          '--require-complete cannot verify this version. Upgrade the '
          'backend, or drop the flag.');
    }
    // What the count MEANS, before reading it. A version published with the
    // source fallback baked its base text into every missing cell, so its
    // coverage reads complete for a half-translated project — the local
    // `mode: a` in the yaml says who publishes, never how THIS version was
    // published, and only the version can answer that. Unknown (a snapshot
    // minted before the field) is refused for the same reason: the gate's
    // whole job is to fail rather than green over a state it cannot see.
    // `skip` is the only judgeable basis, and the only one the export can
    // send: a strings publish degrades `hold` to `skip` before stamping the
    // version, so accepting it here was a branch reachable only by a server
    // that does not exist (#1179).
    final basis = pulled.coverageBasis;
    if (!PulledTranslations.judgeableCoverageBases.contains(basis)) {
      throw CliException(switch (basis) {
        'source' => 'Version ${pulled.version} was published with '
            'incompleteMode: source, which bakes the base text into every '
            'untranslated cell — its coverage always reads complete, so '
            '--require-complete cannot verify it. Publish with '
            'incompleteMode: skip (the Mode A default) to gate on it.',
        // Absent: a snapshot minted before the field. Republishing is the
        // remedy because it is the stamp that is missing.
        null => 'Version ${pulled.version} does not say how it treated '
            'untranslated cells, so --require-complete cannot verify it. '
            'Publish again to stamp the version, or drop the flag.',
        // Present and unrecognized. The version DID say how it treated the
        // cells, so neither of the two messages above is true of it and
        // republishing would return the same basis: the gap is on this side.
        _ => 'Version ${pulled.version} says it treated untranslated cells '
            'as `$basis`, which this easyi18n_cli does not know how to judge '
            'for completeness. Upgrade easyi18n_cli, or drop the flag.',
      });
    }
    // `--lang` naming the base leaves nothing to verify, and it has to be
    // asked before `isEmpty`: under `--lang` the route reports the requested
    // language alone and never the base, so `--lang <base>` gets `{}` from a
    // version that does carry target languages (#1261). A locale the version
    // does not carry never gets here: the route answers it `lang_not_found`.
    if (lang != null && !coverage.containsKey(lang)) {
      throw CliException(
          '--lang $lang is the base language of this version, so '
          '--require-complete has nothing to verify.');
    }
    // A version with no target language at all reports `{}`, and an empty map
    // has nothing to be complete about: "every target language carries all 0
    // keys" is a green over a question nobody answered.
    if (coverage.isEmpty) {
      throw CliException(
          'Version ${pulled.version} reports no target language, so '
          '--require-complete has nothing to verify.');
    }
    final incomplete = [
      for (final e in coverage.entries)
        if ((lang == null || e.key == lang) && !e.value.complete) e,
    ];
    if (incomplete.isEmpty) {
      // "entries", not "keys": the count includes the alias shims a publish
      // bakes for renamed keys, which the version's own `keyCount` excludes
      // — so calling them keys prints a number the dashboard contradicts
      // for the same version.
      _logger.info(
          'Complete: every target language carries all ${_total(coverage)} '
          'entries of this version, aliases included '
          '(--require-complete).');
      return;
    }
    for (final e in incomplete) {
      final missing = e.value.total - e.value.translated;
      _logger.error(
          '${e.key}: $missing of ${e.value.total} key(s) untranslated');
    }
    throw CliException(
        '${incomplete.length} language(s) are incomplete in version '
        '${pulled.version} (--require-complete). Translate them in the '
        'dashboard and publish again.',
        // Which language, and how many keys: printed above for the operator,
        // and carried in the error for a caller that has no stderr. Without
        // this the refusal reaches an agent as a count it cannot act on.
        details: {
          'incomplete': [
            for (final e in incomplete)
              {
                'lang': e.key,
                'untranslated': e.value.total - e.value.translated,
                'total': e.value.total,
              },
          ],
        });
  }

  static int _total(Map<String, LangCoverage> coverage) =>
      coverage.values.isEmpty ? 0 : coverage.values.first.total;

  /// A configured `catalog:` or `source:` resolved against the config's
  /// directory, or null when the config does not set it.
  static String? _resolved(String? rel, String configPath) {
    if (rel == null || rel.isEmpty) return null;
    return p.normalize(p.join(p.dirname(configPath), rel));
  }

  /// What actually gets written for one served file.
  ///
  /// A String Catalog is never simply overwritten, wherever it lands: it is a
  /// file two tools write. Xcode owns its structure, key order (a localized
  /// collation), per-key metadata (`extractionState`,
  /// `isCommentAutoGenerated`) and — the part that loses work — the keys added
  /// since the last publish (#554). The server owns translated values, and
  /// nothing else. So the served values are injected into the local document
  /// and the whole thing is re-printed in Xcode's style; only a destination
  /// with no file yet takes the served rendering, normalized so the next pull
  /// is a byte-exact no-op instead of a whole-file reformat.
  XcstringsMergeResult _contentFor(
    File target,
    String served,
    Easyi18nConfig config, {
    required XcstringsKeyPolicy keyPolicy,
  }) {
    if (config.format != 'xcstrings') {
      return (content: served, baseReplacements: const []);
    }
    if (!target.existsSync()) {
      return (
        content: normalizeXcstringsCatalog(served),
        baseReplacements: const [],
      );
    }
    return mergeXcstringsCatalog(
      local: target.readAsStringSync(),
      served: served,
      keyPolicy: keyPolicy,
    );
  }

  /// One warning block per key whose base-language text the merge replaced
  /// (#646). Deliberately the same family of line as `sync`'s
  /// `_warnConflicts` (`commands/sync_command.dart`, #887):
  /// `Conflict: `key` [lang] — … source text …`. The wording is copied, not
  /// shared — the two
  /// answer opposite questions (sync: the upload the server refused to take;
  /// this: the download that replaced the file's own text) and a helper
  /// would cross files for one line. Silent under sync: the server already
  /// reported that pair on the conflicts channel (#671), through
  /// `_warnConflicts`.
  void _warnBaseReplacements(
    List<XcstringsBaseReplacement> replacements, {
    required bool isSync,
    required bool dryRun,
  }) {
    if (isSync) return;
    for (final r in replacements) {
      _logger.warn(
        [
          'Conflict: ${r.key} [${r.lang}] — the server\'s source text '
              '${dryRun ? 'would replace' : 'replaced'} your catalog\'s:',
          // Every discarded form, each with its text: this line is the only
          // place the developer's edit survives.
          for (final f in r.forms.entries) '    ${f.key}: "${f.value}"',
          '  Re-apply the edit in the dashboard, or edit this file and run '
              '`easyi18n sync`.',
        ].join('\n'),
      );
    }
  }

  /// Records a catalog-mode pull for `status`, and surfaces once whatever a
  /// previous output-dir pull left behind — the stray `lib/l10n/` tree a
  /// pre-#552 CLI wrote into repos that have no `lib/` at all.
  ///
  /// [CliState.output] and [CliState.files] are deliberately dropped: they
  /// scope pruning to a directory this pull did not write into. Dropping them
  /// is also what makes the hint one-shot — the next pull finds no records to
  /// report.
  void _recordCatalogPull(
    String configPath,
    Easyi18nConfig config,
    String version,
    DateTime snapshotAt,
  ) {
    final stateFile = CliState.fileFor(configPath);
    // Best-effort, READ included: the catalog is already on disk by now, so
    // an unreadable state file (a `sudo` run left it root-owned) must not
    // turn a pull that did its job into a failure.
    try {
      _hintSwitchedTarget(configPath, CliState.load(stateFile),
          bases: [?_resolved(config.source, configPath)]);
      CliState(
        version: version,
        pulledAt: DateTime.now().toUtc(),
        snapshotAt: snapshotAt,
        format: config.format,
        catalog: config.catalog,
        catalogs: config.catalogs,
      ).save(stateFile);
    } on FileSystemException {
      _logger.detail(
        'Could not update ${CliState.dirName}/${CliState.fileName}.',
      );
    }
  }

  /// Removes what the previous pull wrote (the caller checks it targeted the
  /// same format + output dir) and this one no longer serves — typically a
  /// locale renamed to its platform-canonical filename. Runs BEFORE writing:
  /// on a case-insensitive filesystem (APFS) deleting the old `zh-hant.json`
  /// after writing `zh-Hant.json` would hit the same directory entry and
  /// destroy the fresh file.
  List<String> _prune(
    List<String> recorded,
    Set<String> written,
    String outputDir, {
    required List<String> bases,
    required bool dryRun,
  }) {
    var pruned = 0;
    final paths = <String>[];
    for (final rel in recorded) {
      if (written.contains(rel)) continue;
      // Recorded by us, but never trust a state file to escape the dir.
      final target = _resolveWithin(outputDir, rel);
      if (target == null || _isSource(target, bases) ||
          _isSource('$target.tmp', bases)) {
        continue;
      }
      final file = File(target);
      // A pull that crashed mid-write strands `<file>.tmp`; sweep it along.
      final tmp = File('$target.tmp');
      if (!file.existsSync() && !tmp.existsSync()) continue;
      pruned++;
      if (file.existsSync()) paths.add(target);
      if (tmp.existsSync()) paths.add(tmp.path);
      if (dryRun) {
        _logger.detail('Would remove stale $rel');
        continue;
      }
      if (tmp.existsSync()) tmp.deleteSync();
      if (file.existsSync()) file.deleteSync();
      _logger.detail('Removed stale $rel');
      _dropEmptiedDirs(file.parent, outputDir, bases: bases);
    }
    if (pruned > 0) {
      _logger.info(
        '${dryRun ? 'Would remove' : 'Removed'} $pruned stale file(s) '
        'from the previous pull.',
      );
    }
    return paths;
  }

  /// Deletes the dirs a pruned file leaves behind (`zh-hant.lproj/`), walking
  /// up to [outputDir]. Finder droppings (`.DS_Store`) don't keep a dir alive.
  void _dropEmptiedDirs(Directory dir, String outputDir, {required List<String> bases}) {
    while (p.isWithin(outputDir, dir.path)) {
      final entries = dir.listSync();
      final droppings = entries
          .where((e) => p.basename(e.path) == '.DS_Store' && !_isSource(e.path, bases))
          .toList();
      if (droppings.length != entries.length) return;
      for (final dropping in droppings) {
        dropping.deleteSync();
      }
      dir.deleteSync();
      dir = dir.parent;
    }
  }

  /// The recorded files a pull would replace that changed since the pull
  /// that wrote them. The file `source:` names is not one of them, by the
  /// rule that keeps every pull off it: a pull that ran before `source:`
  /// named the file left a digest of it, and editing it is how a sync starts.
  static List<String> changedTargets(
      CliState state, String root, Easyi18nConfig config) {
    final named = config.source;
    final source = named == null ? null : p.join(root, named);
    return state.changedSincePull(root, config.output, among: [
      for (final rel in state.digests?.keys ?? const <String>[])
        if (!_isSource(p.join(root, config.output, rel), [?source])) rel,
    ]);
  }

  static void _refuseSourceWrites(Iterable<String> targets, List<String> bases) {
    for (final target in targets) {
      if (_isSource(target, bases)) {
        throw CliException('Refusing to write "$target": it reaches `source:`.',
            code: 'source_collision');
      }
    }
  }

  static bool _isSource(String target, List<String> bases) => bases.any((source) =>
      _physicalPath(target).toLowerCase() == _physicalPath(source).toLowerCase() ||
      File(target).existsSync() && File(source).existsSync() &&
          FileSystemEntity.identicalSync(target, source));

  // Resolve existing ancestors too: new targets can live under directory aliases.
  static String _physicalPath(String path) {
    var ancestor = p.normalize(p.absolute(path));
    final missing = <String>[];
    while (FileSystemEntity.typeSync(ancestor, followLinks: false) ==
        FileSystemEntityType.notFound) {
      missing.insert(0, p.basename(ancestor));
      ancestor = p.dirname(ancestor);
    }
    return p.joinAll([File(ancestor).resolveSymbolicLinksSync(), ...missing]);
  }

  /// Resolves [rel] under [outputDir], or null when it escapes it — the
  /// single containment rule for both the write and the delete paths.
  static String? _resolveWithin(String outputDir, String rel) {
    final target = p.normalize(p.join(outputDir, rel));
    return p.isWithin(outputDir, target) ? target : null;
  }

  /// A format or output-dir switch strands the previous pull's outputs (their
  /// records no longer match this pull's target, so they can never be
  /// pruned). Surface the ones still on disk instead of leaving them behind
  /// silently — this is the last pull that still has their record.
  void _hintSwitchedTarget(String configPath, CliState previous,
      {required List<String> bases}) {
    final prevOutput = previous.output;
    if (prevOutput == null) return;
    final prevDir = p.normalize(p.join(p.dirname(configPath), prevOutput));
    final stranded = <String>[];
    for (final rel in previous.files ?? const <String>[]) {
      final target = _resolveWithin(prevDir, rel);
      if (target != null && !_isSource(target, bases) &&
          File(target).existsSync()) {
        stranded.add(rel);
      }
    }
    if (stranded.isEmpty) return;
    stranded.sort();
    _logger.info(
      'The previous ${previous.format ?? 'unknown'}-format pull left '
      '${stranded.length} file(s) in $prevDir that this pull no longer '
      'manages: ${stranded.join(', ')}. Remove them if stale.',
    );
  }

  /// First pull that records its file list (older CLIs kept none): surface
  /// files in the output dir it cannot attribute — e.g. a pre-canonical
  /// `app_zh-hant.arb` — since without a recorded list nothing can be pruned
  /// safely. One-shot by construction: after this pull the list exists.
  void _hintLeftovers(String outputDir, Set<String> written,
      {required List<String> bases}) {
    final root = Directory(outputDir);
    if (!root.existsSync()) return;
    final extensions = written
        .map(p.extension)
        .where((e) => e.isNotEmpty)
        .toSet();
    // Case-insensitive: on APFS the fresh file can surface under a previous
    // pull's directory-entry casing.
    final writtenLower = written.map((w) => w.toLowerCase()).toSet();
    final leftovers =
        root
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.split(p.relative(f.path, from: outputDir)).join('/'))
            .where(
              (rel) =>
                  extensions.contains(p.extension(rel)) &&
                  !writtenLower.contains(rel.toLowerCase()) &&
                  !_isSource(p.join(outputDir, rel), bases),
            )
            .toList()
          ..sort();
    if (leftovers.isEmpty) return;
    _logger.info(
      'Not written by this pull: ${leftovers.join(', ')}. '
      'Remove them if stale; from now on pull tracks and cleans its own files.',
    );
  }

  /// The backend namespaces files under the format id (`arb/app_en.arb`); strip
  /// it so files land directly in the output dir (gen-l10n's `arb-dir`).
  String _stripFormatPrefix(String relPath, String format) {
    final prefix = '$format/';
    return relPath.startsWith(prefix)
        ? relPath.substring(prefix.length)
        : relPath;
  }

  /// The server names ARB files `app_<locale>.arb`, and gen_l10n reads every
  /// .arb of its `arb-dir`, refusing two files of one locale. A served locale
  /// the directory already has a file of goes to that file (#2436). Else,
  /// beside a template named `strings_en.arb` the served `app_en.arb` is a
  /// second `en` file (#2343): under such a template the files take its
  /// prefix, so the base one lands on it and is kept. The prefix is what
  /// precedes the base language (its stored lowercase-dash code) in the
  /// template's name; `--lang` serves no base file to read it from. No other
  /// format is served under `app_`.
  static String Function(String) _templateNames(
      String? source, String baseCode, String outputDir) {
    if (source == null) return (name) => name;
    final own = _arbLocales(outputDir);
    String? ownFile(String name) {
      final locale = RegExp(r'^app_(\w+)\.arb$').firstMatch(name)?[1];
      return locale == null ? null : own[locale.toLowerCase()];
    }
    final stem = p.basenameWithoutExtension(source);
    for (var i = stem.indexOf('_'); i >= 0; i = stem.indexOf('_', i + 1)) {
      final locale = stem.substring(i + 1).toLowerCase().replaceAll('_', '-');
      if (locale != baseCode) continue;
      final prefix = stem.substring(0, i + 1);
      return (name) => ownFile(name) ??
          (name.startsWith('app_') ? '$prefix${name.substring(4)}' : name);
    }
    // gen_l10n also accepts templates such as messages.arb via @@locale.
    // Keep the served base on that file even without a locale suffix.
    return (name) => ownFile(name) ??
        (name.toLowerCase().replaceAll('_', '-') == 'app-$baseCode.arb'
            ? p.basename(source)
            : name);
  }

  /// The .arb files gen_l10n reads in [dir], by the locale it reads each as
  /// (lowercased): its `@@locale`, else its name (`AppResourceBundle`,
  /// Flutter 3.44). A locale two files claim maps to null and a file that is
  /// not a JSON object maps nothing: gen_l10n refuses both directories.
  static Map<String, String?> _arbLocales(String dir) {
    final found = <String, String?>{};
    if (!Directory(dir).existsSync()) return found;
    for (final file in Directory(dir).listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (!RegExp(r'\w\.arb$').hasMatch(name)) continue;
      final Object? doc;
      try {
        final text = file.readAsStringSync().trim();
        doc = text.isEmpty ? const {} : jsonDecode(text);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
      if (doc is! Map) continue;
      final declared = doc['@@locale'];
      final locale = declared is String
          ? declared.toLowerCase()
          : _nameLocale(p.basenameWithoutExtension(name));
      if (locale == null) continue;
      found[locale] = found.containsKey(locale) ? null : name;
    }
    return found;
  }

  /// gen_l10n's reading of a file name: the whole name, else what follows
  /// each `_`, the first that parses as a locale of one of its languages.
  static String? _nameLocale(String stem) {
    for (var start = 0; start >= 0;) {
      final locale = Locale.tryParse(stem.substring(start));
      if (locale != null && _languages.contains(locale.languageCode)) {
        return locale.toString().replaceAll('-', '_').toLowerCase();
      }
      final next = stem.indexOf('_', start);
      start = next < 0 ? -1 : next + 1;
    }
    return null;
  }

  // flutter_tools' `_iso639Languages`: in `ui_es.arb`, `ui` is none of them.
  static final _languages = ('aa ab ae af ak am an ar as av ay az ba be bg '
          'bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz ee el '
          'en eo es et eu fa ff fi fil fj fo fr fy ga gd gl gn gsw gu gv ha '
          'he hi ho hr ht hu hy hz ia id ie ig ii ik io is it iu ja jv ka kg '
          'ki kj kk kl km kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv '
          'mg mh mi mk ml mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc '
          'oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd se sg si sk '
          'sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts '
          'tt tw ty ug uk ur uz ve vi vo wa wo xh yi yo za zh zu')
      .split(' ')
      .toSet();
}

/// Paths and coverage only; served file contents stay inside the pull.
class PullOutcome {
  PullOutcome(PulledTranslations pulled, {
    required this.destination, required this.keyPolicy,
    required List<String> files, required List<String> pruned,
    required this.dryRun, required String configPath, required this.baseUrl,
    this.unplaced = const [],
  }) : version = pulled.version,
       coverage = pulled.coverage == null ? null : Map.unmodifiable(pulled.coverage!),
       coverageBasis = pulled.coverageBasis,
       files = List.unmodifiable(files.map((path) => p.normalize(p.absolute(path)))),
       pruned = List.unmodifiable(pruned.map((path) => p.normalize(p.absolute(path)))),
       projectDir = p.normalize(p.absolute(p.dirname(configPath)));

  final String version;
  final String destination;
  final XcstringsKeyPolicy keyPolicy;
  final List<String> files;
  final List<String> pruned;

  /// Served keys that no file of `catalogs:` holds, so none was written.
  final List<String> unplaced;
  final bool dryRun;
  final Map<String, LangCoverage>? coverage;
  final String? coverageBasis;
  final String projectDir;
  final String baseUrl;

  Map<String, Object?> toJson() => sanitizeJson({
    'version': version, 'destination': destination,
    'key_policy': keyPolicy == XcstringsKeyPolicy.localOwnsKeySet ? 'local_owns' : 'union',
    'dry_run': dryRun,
    'files_written': dryRun ? <String>[] : files,
    'pruned': dryRun ? <String>[] : pruned,
    if (dryRun) 'files_planned': files,
    if (dryRun) 'prune_planned': pruned,
    if (unplaced.isNotEmpty) 'unplaced_keys': unplaced,
    'coverage': coverage == null ? null : {
      for (final e in coverage!.entries)
        e.key: {'translated': e.value.translated, 'total': e.value.total},
    },
    'coverage_basis': coverageBasis,
    'project_dir': projectDir, 'base_url': baseUrl,
  }) as Map<String, Object?>;
}
