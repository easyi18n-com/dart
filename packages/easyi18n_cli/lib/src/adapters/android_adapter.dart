import 'dart:io';

import 'package:path/path.dart' as p;

import '../agents_md.dart' show agentsInline;
import '../config.dart';
import '../doctor_report.dart';
import '../init_report.dart';
import 'stack_adapter.dart';

/// The per-language resources format of an Android app.
const String kAndroidFormat = 'android_xml';

/// The Android file-first adapter (decision D0/D13, #2285): the base
/// `res/values/strings.xml` is the truth. `sync` uploads it plus each
/// `values-<qualifier>/strings.xml` under its language, and `pull` writes the
/// translated `values-<qualifier>/` files into the same `res/`, never onto the
/// base. No extractor: the strings already live in resources.
class AndroidAdapter implements StackAdapter {
  const AndroidAdapter();

  @override
  String get stack => 'android';
  @override
  String get family => 'file-first';

  /// A Gradle or manifest marker AND a base resources file. A `strings.xml`
  /// alone is a file any tool may have dropped; a Flutter app carries both
  /// halves under `android/`, and the order of the adapters keeps it Flutter.
  @override
  bool detect(String root) {
    final sources = sourcesIn(root);
    if (sources.isEmpty) return false;
    return _gradleScript(root) != null ||
        sources.any((s) => File(p.join(root, _manifestOf(s))).existsSync());
  }

  /// Mode B is the Dart runtime SDK, which an Android app cannot call.
  @override
  String resolveMode(String root, String? flagMode, void Function(InitStep) report) {
    if (flagMode != null && flagMode != 'a') {
      report(InitStep('skipped', 'mode',
          'file-first projects are Mode A (TMS) - ignoring --mode $flagMode'));
    }
    return 'a';
  }

  @override
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report) {
    final sources = sourcesIn(root);
    if (sources.isEmpty) {
      report(InitStep('skipped', 'source',
          'no res/values/strings.xml found - set `source:` to your base '
          'strings.xml and `output:` to its res/ before running sync'));
      return (format: kAndroidFormat, catalog: null, output: null,
          source: null, sourceLayout: null);
    }
    final source = sources.first;
    final others = sources.length - 1;
    // Named, not silent: with several modules the pick is a guess, and the
    // fix is two lines of the file init just wrote.
    report(InitStep('detected', p.join(root, source),
        others == 0
            ? 'base strings'
            : 'base strings ($others other(s) found - edit `source:` and '
                '`output:` to sync a different module)'));
    return (format: kAndroidFormat, catalog: null,
        output: p.posix.dirname(p.posix.dirname(source)), source: source,
        sourceLayout: null);
  }

  @override
  String nextCommand(Easyi18nConfig config) => 'sync';

  @override
  String agentsMdSection(Easyi18nConfig config) {
    final source = config.source;
    final named = source == null || source.isEmpty
        ? 'The base strings file (`source:` in easyi18n.yaml) is'
        : '`${agentsInline(source)}` is';
    return '''### Android

- $named the truth: add strings there as usual, with Android
  escapes and `%1\$s` placeholders.
- `easyi18n sync` uploads it and the `values-*/strings.xml` beside it, and
  writes the translations back into `${agentsInline(config.output)}/values-*/`.
- Review the git diff after every sync or pull: that diff is the review.
- Never edit .easyi18n/: it is generated.
''';
  }

  @override
  void initSteps(InitContext context, Easyi18nConfig config) {
    final source = config.source;
    if (source != null && source.isNotEmpty) {
      final path = p.normalize(p.join(context.root, source));
      if (File(path).existsSync()) {
        context.report('ok', path, 'base strings to sync');
      } else {
        context.report('skipped', path,
            'not found - `source:` must point at your res/values/strings.xml');
      }
    }
    context.ignoreDerivedState();
  }

  /// Read-only, offline and free (the [StackAdapter] contract).
  @override
  Future<void> doctorChecks({required String root, required String sourcePath,
      required Easyi18nConfig config, required DoctorFindings findings}) async {
    _checkSource(root, config, findings);
    if (config.format == kAndroidFormat) {
      findings.ok('format', 'format', 'format: $kAndroidFormat');
    } else {
      findings.fail('format', 'format',
          'format: ${config.format} is not Android resources - pull would '
          'write other files into res/; set `format: $kAndroidFormat`');
    }
    if (config.mode == 'a') {
      findings.ok('mode', 'mode',
          'Mode A (TMS) - easyi18n translates the resources this project owns');
    } else {
      findings.warn('mode', 'mode',
          'mode: ${config.mode} is the Dart runtime SDK, which an Android app '
          'cannot call - the published coverage is not graded; set `mode: a`');
    }
    final gradle = _gradleScript(root);
    if (gradle != null) {
      findings.ok('gradle', gradle, 'Gradle build');
    } else {
      findings.skip('gradle', root,
          'no Gradle script here - the resources checks above are the ones '
          'that matter');
    }
  }

  void _checkSource(String root, Easyi18nConfig config, DoctorFindings checks) {
    final relative = config.source;
    if (relative == null || relative.isEmpty) {
      checks.fail('source', 'source',
          'no `source:` in ${Easyi18nConfig.fileName} - sync has nothing to '
          "upload; run 'easyi18n init --stack android'",
          details: [for (final s in sourcesIn(root)) 'found $s']);
      return;
    }
    final path = p.normalize(p.join(root, relative));
    final String content;
    try {
      content = File(path).readAsStringSync();
    } on PathNotFoundException {
      checks.fail('source', path,
          'not found - `source:` points at a file that is not there, so every '
          'sync fails before it uploads anything');
      return;
    } on FileSystemException catch (e) {
      checks.unverified('source', path, 'Cannot read $path: ${e.message}');
      return;
    }
    final keys = translatableKeys(content);
    if (keys == null) {
      checks.fail('source', path,
          'not an Android resources file (no <resources> root) - the server '
          'would refuse the sync');
      return;
    }
    final locales = [
      for (final t in targetsIn(p.join(root, config.output))) t.lang,
    ];
    final summary = '$kAndroidFormat, $keys translatable key(s); '
        '${locales.length} locale file(s)'
        '${locales.isEmpty ? '' : ': ${locales.join(', ')}'}';
    if (keys == 0) {
      checks.warn('source', path,
          '$summary - every string is missing or translatable="false", so a '
          'sync would upload nothing');
    } else {
      checks.ok('source', path, summary);
    }
  }

  // ----- discovery -----------------------------------------------------------

  /// The `<string>` and `<plurals>` resources of [content] a sync imports
  /// (not `translatable="false"`), or null without a `<resources>` root.
  static int? translatableKeys(String content) {
    final text = content.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    if (!RegExp(r'<resources[\s>/]').hasMatch(text)) return null;
    return RegExp(r'<(?:string|plurals)(\s[^>]*)?>')
        .allMatches(text)
        .where((m) => !RegExp(r'''translatable\s*=\s*["']false["']''')
            .hasMatch(m[1] ?? ''))
        .length;
  }

  /// The locale a `values-<qualifiers>` directory name holds (`values-zh-rTW`
  /// is `zh-TW`, `values-b+zh+Hant` is `zh-Hant`), or null when it names none
  /// (`values`, `values-night`). The server reads the same rule from the
  /// file name it is sent.
  static String? localeOfValuesDir(String name) {
    if (!name.startsWith('values-')) return null;
    final parts = name.substring('values-'.length).split('-');
    var i = 0;
    while (i < parts.length && RegExp(r'^(mcc|mnc)\d+$').hasMatch(parts[i])) {
      i++;
    }
    if (i == parts.length) return null;
    if (parts[i].startsWith('b+')) {
      final tags = parts[i].substring(2).split('+');
      return tags.any((t) => t.isEmpty) ? null : tags.join('-');
    }
    if (!RegExp(r'^[a-z]{2}$').hasMatch(parts[i])) return null;
    final region = i + 1 < parts.length ? parts[i + 1] : '';
    return RegExp(r'^r[A-Z]{2}$').hasMatch(region)
        ? '${parts[i]}-${region.substring(1)}'
        : parts[i];
  }

  /// Every `values-<locale>/strings.xml` in [resDir], by language.
  static List<({String lang, File file})> targetsIn(String resDir) {
    final found = <({String lang, File file})>[];
    for (final entry in _sortedEntries(Directory(resDir))) {
      final lang = localeOfValuesDir(p.basename(entry.path));
      final file = File(p.join(entry.path, 'strings.xml'));
      if (entry is Directory && lang != null && file.existsSync()) {
        found.add((lang: lang, file: file));
      }
    }
    return found..sort((a, b) => a.lang.compareTo(b.lang));
  }

  /// Every `res/values/strings.xml` under [root], relative with forward
  /// slashes, best pick first: a `main` source set, then the shallowest,
  /// then by path. The order never comes from `listSync`.
  static List<String> sourcesIn(String root) {
    final found = <String>[];
    void walk(Directory dir, int depth) {
      for (final entry in _sortedEntries(dir)) {
        final name = p.basename(entry.path);
        if (entry is! Directory || name.startsWith('.') ||
            _skippedDirs.contains(name)) {
          continue;
        }
        final strings = File(p.join(entry.path, 'values', 'strings.xml'));
        if (name == 'res' && strings.existsSync()) {
          found.add(p.split(p.relative(strings.path, from: root)).join('/'));
        } else if (depth + 1 < _maxDepth) {
          walk(entry, depth + 1);
        }
      }
    }

    walk(Directory(root), 0);
    int rank(String path) => path.contains('/src/main/res/') ? 0 : 1;
    return found
      ..sort((a, b) {
        final main = rank(a).compareTo(rank(b));
        if (main != 0) return main;
        final depth = p.posix.split(a).length.compareTo(p.posix.split(b).length);
        return depth != 0 ? depth : a.compareTo(b);
      });
  }

  /// `app/src/main/res` is four directories down; one more reaches a module
  /// nested in a folder without turning `init` into a full-tree scan.
  static const int _maxDepth = 5;

  /// Build outputs hold merged copies of the resources, never the source.
  static const Set<String> _skippedDirs = {'build', 'node_modules'};

  static String _manifestOf(String source) =>
      p.join(p.dirname(p.dirname(p.dirname(source))), 'AndroidManifest.xml');

  static String? _gradleScript(String root) {
    for (final name in const ['settings.gradle', 'settings.gradle.kts',
        'build.gradle', 'build.gradle.kts']) {
      final file = File(p.join(root, name));
      if (file.existsSync()) return file.path;
    }
    return null;
  }

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
