import 'dart:io';

import 'package:path/path.dart' as p;

import '../agents_md.dart' show agentsInline;
import '../config.dart';
import '../doctor_report.dart';
import '../exceptions.dart';
import '../init_report.dart';
import '../xcstrings_catalogs.dart';
import '../xcstrings_merge.dart' show xcstringsCatalogSummary;
import 'stack_adapter.dart';

/// The canonical Xcode catalog name. The server serves the merged file under
/// this name whatever the project calls it, so it is also the pick a project
/// with several catalogs gets by default (`ci-sync.md` section 4).
const String kXcstringsCatalogName = 'Localizable.xcstrings';

/// The catalog v1 never syncs: `InfoPlist.xcstrings` holds the usage
/// descriptions Xcode generates, most of them opted out of translation
/// (#612), and every modern Xcode project ships one next to the real catalog
/// (`ci-sync.md` section 9).
const String kXcstringsPlistCatalog = 'InfoPlist.xcstrings';

/// The single-file format a catalog is rendered in.
const String kXcstringsFormat = 'xcstrings';

/// The file-first adapter (decision D0/D13): the translation catalog the
/// project already owns is the truth, not the calls in the source. `init`
/// writes a config pointing at it, `sync` uploads it and writes the translated
/// one back, and `doctor` grades the file rather than a runtime wiring the
/// stack has no way to use.
class XcstringsAdapter implements StackAdapter {
  const XcstringsAdapter();

  @override
  String get stack => 'xcode';
  @override
  String get family => 'file-first';

  /// An Xcode project AND a catalog to sync. Both halves are load-bearing: a
  /// `.xcodeproj` alone is every Flutter app (`ios/Runner.xcodeproj`), and a
  /// lone `.xcstrings` is a file any tool may have dropped.
  @override
  bool detect(String root) =>
      xcodeProjectIn(root) != null && catalogsIn(root).isNotEmpty;

  /// File-first is Mode A by construction: Mode B is the Dart runtime SDK
  /// (`context.tr()`, `Easyi18nScope`, OTA bundles), which an Xcode target
  /// cannot call. Honouring `--mode b` here would write a config whose only
  /// effect is to turn off the coverage grading `doctor` does for Mode A.
  @override
  String resolveMode(String root, String? flagMode, void Function(InitStep) report) {
    if (flagMode != null && flagMode != 'a') {
      report(InitStep('skipped', 'mode',
          'file-first projects are Mode A (TMS) - ignoring --mode $flagMode'));
    }
    return 'a';
  }

  /// The two settings that make a config file-first, reported as a step so the
  /// pick is in the transcript rather than only in the written file.
  @override
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report) {
    final catalogs = catalogsIn(root);
    if (catalogs.isEmpty) {
      report(InitStep('skipped', 'catalog',
          'no $kXcstringsCatalogName found - pass --catalog, or set '
          '`catalog:` before running sync'));
      return (format: kXcstringsFormat, catalog: null, output: null,
          source: null, sourceLayout: null);
    }
    // Named, not silent: with a Widget or Watch target in the tree the pick is
    // a guess, and the fix is one line of the file init just wrote.
    final others = catalogs.length - 1;
    report(InitStep('detected', p.join(root, catalogs.first),
        others == 0
            ? 'translation catalog'
            : 'translation catalog ($others other(s) found - edit `catalog:` '
                'to sync a different one, or list them under `catalogs:` to '
                'sync them as one project)'));
    return (format: kXcstringsFormat, catalog: catalogs.first, output: null,
        source: null, sourceLayout: null);
  }

  @override
  String nextCommand(Easyi18nConfig config) => 'sync';

  @override
  String agentsMdSection(Easyi18nConfig config) {
    final catalog = config.catalog;
    final many = config.catalogs.isNotEmpty;
    final named = many
        ? 'The catalogs ${config.catalogs.map((c) => '`${agentsInline(c)}`').join(', ')} '
              '(one project; a key lives in exactly one of them)'
        : catalog == null || catalog.isEmpty
        ? 'The catalog (`catalog:` in easyi18n.yaml)'
        : 'The catalog `${agentsInline(catalog)}`';
    return '''### Xcode

- $named ${many ? 'are' : 'is'} the truth: add strings in Xcode as usual.
  `easyi18n sync` uploads ${many ? 'them' : 'it'}, publishes, and writes the translations back
  into the same file${many ? 's' : ''}.
- Review the git diff after every sync or pull: that diff is the review.
- Do not hand-edit translations in the catalog before a sync: sync reports
  them as conflicts and keeps the project's value unless told otherwise.
- Never edit .easyi18n/: it is generated.
''';
  }

  /// Nothing to scaffold: the catalog is the project's own file and the only
  /// derived state is the core's `.easyi18n/` cache. Reporting the catalog is
  /// the whole step list — a re-run of `init` says whether the configured
  /// path still resolves, which is what an idempotent second run is for.
  @override
  void initSteps(InitContext context, Easyi18nConfig config) {
    final catalog = config.catalog;
    for (final relative in config.catalogs.isEmpty
        ? [if (catalog != null && catalog.isNotEmpty) catalog]
        : config.catalogs) {
      final path = p.normalize(p.join(context.root, relative));
      if (File(path).existsSync()) {
        context.report('ok', path, 'catalog to sync');
      } else {
        context.report('skipped', path,
            'catalog not found - `catalog:` must point at your .xcstrings file');
      }
    }
    context.ignoreDerivedState();
  }

  /// Read-only, offline and free (the [StackAdapter] contract): every answer
  /// comes from the config and the catalog on disk.
  @override
  Future<void> doctorChecks({required String root, required String sourcePath,
      required Easyi18nConfig config, required DoctorFindings findings}) async {
    _checkCatalog(root, config, findings);
    _checkFormat(config, findings);
    _checkMode(config, findings);
    _checkProject(root, findings);
  }

  void _checkCatalog(String root, Easyi18nConfig config, DoctorFindings checks) {
    final single = config.catalog;
    if (config.catalogs.isEmpty && (single == null || single.isEmpty)) {
      final found = catalogsIn(root);
      checks.fail('catalog', 'catalog',
          'no `catalog:` or `catalogs:` in ${Easyi18nConfig.fileName} - sync '
          "has nothing to upload; run 'easyi18n init --stack xcode'",
          details: [for (final c in found) 'found $c']);
      return;
    }
    for (final relative in config.catalogs.isEmpty ? [single!] : config.catalogs) {
      _checkCatalogFile(root, relative, checks);
    }
    if (config.catalogs.isEmpty) return;
    // The files read one by one above; what only the union shows is a key two
    // of them hold or a base language they do not share.
    try {
      XcstringsCatalogs.read(CatalogFile.of(config, p.join(root, Easyi18nConfig.fileName)));
    } on CliException catch (e) {
      if (e.code == 'catalog_key_collision' ||
          e.code == 'catalog_base_language_mismatch') {
        checks.fail('catalog', 'catalogs', e.message);
      }
    }
  }

  void _checkCatalogFile(String root, String relative, DoctorFindings checks) {
    final path = p.normalize(p.join(root, relative));
    final file = File(path);
    if (!file.existsSync()) {
      checks.fail('catalog', path,
          'catalog not found - `catalog:` points at a file that is not there, '
          'so every sync fails before it uploads anything');
      return;
    }
    final String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException catch (e) {
      checks.unverified('catalog', path, 'Cannot read $path: ${e.message}');
      return;
    }
    // Null is "cannot read this as a catalog", never "carries nothing": the
    // counts below would otherwise report a truncated or half-written file as
    // an empty one (`xcstrings_merge.dart`).
    final summary = xcstringsCatalogSummary(content);
    if (summary == null) {
      checks.fail('catalog', path,
          'not a readable .xcstrings catalog (a JSON object with a `strings` '
          'map) - sync would upload it and the server would refuse it');
      return;
    }
    final locales = summary.locales.toList()..sort();
    checks.ok('catalog', path,
        '${summary.entries} entry(ies), ${locales.length} locale(s)'
        '${locales.isEmpty ? '' : ': ${locales.join(', ')}'}');
    if (summary.sourceLanguage == null) {
      checks.warn('catalog', path,
          'no `sourceLanguage` - Xcode stamps it; the base language of the '
          "sync comes from the project's own setting instead");
    }
    if (summary.entries == 0) {
      checks.warn('catalog', path,
          'the catalog carries no entries - a sync would upload nothing');
    } else if (summary.translatable == 0) {
      // An ordinary state, not a failure: a dev-only catalog opts every entry
      // out and no fill will ever write a locale into it (#612).
      checks.skip('catalog', path,
          'every entry is `"shouldTranslate": false` - nothing here will ever '
          'be translated');
    }
  }

  void _checkFormat(Easyi18nConfig config, DoctorFindings checks) {
    if (Easyi18nConfig.catalogFormats.contains(config.format)) {
      checks.ok('format', 'format',
          'format: ${config.format} renders every language into one file');
      return;
    }
    checks.fail('format', 'format',
        'format: ${config.format} renders one file per locale, so the write-back '
        "would funnel a single locale's render into your catalog and call it a "
        'success - set `format: $kXcstringsFormat`');
  }

  void _checkMode(Easyi18nConfig config, DoctorFindings checks) {
    if (config.mode == 'a') {
      checks.ok('mode', 'mode',
          'Mode A (TMS) - easyi18n translates the catalog this project owns');
      return;
    }
    // Not a failure: nothing in `sync` reads `mode`. What it costs is the
    // published-coverage grading, which `doctor` only runs for Mode A — a
    // check that goes dark, which is worse to leave unsaid than to fail.
    checks.warn('mode', 'mode',
        'mode: ${config.mode} is the Dart runtime SDK, which an Xcode target '
        'cannot call - the published coverage is not graded; set `mode: a`');
  }

  void _checkProject(String root, DoctorFindings checks) {
    final project = xcodeProjectIn(root);
    if (project != null) {
      checks.ok('xcode', project, 'Xcode project');
      return;
    }
    checks.skip('xcode', root,
        'no .xcodeproj here - a checkout without it (CI) or a catalog owned by '
        'another tool; the catalog checks above are the ones that matter');
  }

  // ----- discovery -----------------------------------------------------------

  /// The `.xcodeproj` / `.xcworkspace` bundle at the root of [root], or null.
  /// Only the top level: the copies inside a Flutter app live under `ios/` and
  /// `macos/`, and finding one of those would claim every Flutter project.
  static String? xcodeProjectIn(String root) {
    for (final entry in _sortedEntries(Directory(root))) {
      final name = p.basename(entry.path);
      if (entry is Directory &&
          (name.endsWith('.xcodeproj') || name.endsWith('.xcworkspace'))) {
        return entry.path;
      }
    }
    return null;
  }

  /// Every catalog under [root] a sync could own, relative to it, best pick
  /// first: [kXcstringsCatalogName] before any other name, then the shallowest,
  /// then alphabetical.
  ///
  /// The order is total and derived from the paths, never from
  /// `listSync`, whose order is the filesystem's: a pick that depends on it
  /// changes between the three CI runners without a line of the diff moving.
  static List<String> catalogsIn(String root) {
    final found = <String>[];
    void walk(Directory dir, int depth) {
      for (final entry in _sortedEntries(dir)) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        if (entry is Directory) {
          if (depth + 1 >= _maxDepth ||
              _skippedDirs.contains(name) ||
              name.endsWith('.xcodeproj') ||
              name.endsWith('.xcworkspace')) {
            continue;
          }
          walk(entry, depth + 1);
        } else if (entry is File &&
            name.endsWith('.xcstrings') &&
            name != kXcstringsPlistCatalog) {
          found.add(p.relative(entry.path, from: root));
        }
      }
    }

    walk(Directory(root), 0);
    found.sort(_byCatalogPreference);
    return found;
  }

  /// How deep the walk goes below the project root. Three levels reach
  /// `MyApp/Resources/Localizable.xcstrings`; going further turns `init` into
  /// a full-tree scan of a checkout it does not own.
  static const int _maxDepth = 3;

  /// Directories that hold build products or vendored sources — a catalog in
  /// one of them is a copy, never the project's own.
  static const Set<String> _skippedDirs = {
    'build', 'Build', 'DerivedData', 'Pods', 'Carthage', 'node_modules',
  };

  static int _byCatalogPreference(String a, String b) {
    final canonical = _canonicalRank(a).compareTo(_canonicalRank(b));
    if (canonical != 0) return canonical;
    final depth = p.split(a).length.compareTo(p.split(b).length);
    return depth != 0 ? depth : a.compareTo(b);
  }

  static int _canonicalRank(String path) =>
      p.basename(path) == kXcstringsCatalogName ? 0 : 1;

  /// An unreadable directory is not the caller's problem: `init` and `doctor`
  /// both run over trees with directories the process cannot enter.
  static List<FileSystemEntity> _sortedEntries(Directory dir) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync();
    } on FileSystemException {
      return const [];
    }
    return entries..sort((a, b) => a.path.compareTo(b.path));
  }
}
