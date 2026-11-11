import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agents_md.dart' show agentsInline;
import '../config.dart';
import '../doctor_report.dart';
import '../init_report.dart';
import 'stack_adapter.dart';
import 'web_adapter.dart';

/// The format `ng extract-i18n --format=json` writes and `@angular/localize`
/// loads: `{"locale": …, "translations": {id: message}}`, one file per locale.
const String kAngularFormat = 'angular_json';

/// Where `init` points an Angular app that has not chosen another directory:
/// the `--output-path` the Angular docs use for `ng extract-i18n`.
const String _localeDir = 'src/locale';

/// The ids and texts of an Angular translation file, or null for any other
/// JSON. The server's rule (`isAngularJsonRoot`): exactly a string `locale`
/// and an object `translations`, so a catalog that merely has a `locale` key
/// is not one.
Map<String, String>? angularMessages(Object? decoded) {
  if (decoded is! Map || decoded.length != 2 || decoded['locale'] is! String) {
    return null;
  }
  final translations = decoded['translations'];
  if (translations is! Map) return null;
  return {
    for (final e in translations.entries)
      if (e.value case final String text) '${e.key}': text,
  };
}

/// The id Angular derives when a message has no `@@id`: a 63-bit hash of
/// the source text, in decimal.
final RegExp _digest = RegExp(r'^\d{12,19}$');

/// How the extractor writes a plural or select it lifts out of a message:
/// the whole text is the ICU, its variable named `VAR_PLURAL`, `VAR_SELECT`…
final RegExp _wholeIcu = RegExp(r'^\{VAR_\w+,');

/// The Angular file-first adapter (#2100): the `messages.json` that
/// `ng extract-i18n` writes is the truth, and `pull` writes each translation
/// beside it as `messages.<locale>.json`, the names the server serves.
class AngularAdapter implements StackAdapter {
  const AngularAdapter();

  static const String dependency = '@angular/localize';

  @override
  String get stack => 'angular';
  @override
  String get family => 'file-first';

  /// `@angular/localize` and an `angular.json`. Neither an `i18n` section nor
  /// an `extract-i18n` target: `ng add @angular/localize` on Angular 22 writes
  /// neither.
  @override
  bool detect(String root) =>
      _section(root) != null && File(p.join(root, 'angular.json')).existsSync();

  /// What [detect] looks for, worded to follow "angular needs" in the CLI's
  /// refusal.
  String get detectionNeeds => '$dependency in package.json and an angular.json';

  /// File-first is Mode A by construction: Mode B is the Dart runtime SDK.
  @override
  String resolveMode(String root, String? flagMode, void Function(InitStep) report) {
    if (flagMode != null && flagMode != 'a') {
      report(InitStep('skipped', 'mode',
          'file-first projects are Mode A (TMS) - ignoring --mode $flagMode'));
    }
    return 'a';
  }

  /// `ng add @angular/localize --use-at-runtime` puts the package under
  /// `dependencies`; without the flag it goes to `devDependencies`.
  @override
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report) {
    final section = _section(root);
    if (section != null) {
      report(InitStep('detected', p.join(root, 'package.json'),
          '$dependency in $section (${section == 'dependencies'
              ? 'translations loaded at runtime' : 'translated at build time'})'));
    }
    return (format: kAngularFormat, catalog: null, output: _localeDir,
        source: '$_localeDir/messages.json', sourceLayout: 'locale-files');
  }

  @override
  String nextCommand(Easyi18nConfig config) => 'sync';

  @override
  String agentsMdSection(Easyi18nConfig config) {
    final source = config.source;
    final named = source == null || source.isEmpty
        ? 'The extracted file (`source:` in easyi18n.yaml) is'
        : '`${agentsInline(source)}` is';
    return '''### Angular

- Mark user-facing text with `i18n` and `\$localize`. $named
  written by `${agentsInline(_extraction(config))}`: run it after
  changing templates and before `easyi18n sync`, and never hand-edit it.
- Give each message its own id (`i18n="@@cart.title"`): without one the id
  is a digest of the text, and editing the text starts its translation
  over. Keep every `{\$…}` token as it is.
- The `messages.<locale>.json` files in `${agentsInline(config.output)}/` are
  written by easyi18n: do not hand-edit them.
- Never edit .easyi18n/: it is generated.
''';
  }

  @override
  void initSteps(InitContext context, Easyi18nConfig config) {
    final source = config.source;
    if (source == null || source.isEmpty) {
      context.report('skipped', 'source',
          'no `source:` in ${Easyi18nConfig.fileName} - set it to the file '
          '`ng extract-i18n --format=json` writes');
    } else {
      // Not created: an empty file has no `locale` and the server would not
      // read it as Angular's format.
      final file = File(p.normalize(p.join(context.root, source)));
      if (file.existsSync()) {
        context.report('ok', file.path, 'base catalog to sync - run '
            '`${_extraction(config)}` again after changing templates, before '
            'each sync');
      } else {
        context.report('skipped', file.path, 'not extracted yet - run '
            '`${_extraction(config)}` before `easyi18n sync`');
      }
    }
    final runtime = _section(context.root) == 'dependencies';
    context.report('ok', p.join(context.root, runtime ? 'src/main.ts' : 'angular.json'),
        runtime
            ? 'load the pulled file of the language before the app starts:'
            : 'build one app per language from the pulled files:',
        scopeSnippet:
            runtime ? _runtimeWiring(config.output) : _buildTimeWiring(context.root, config));
    context.ignoreDerivedState();
  }

  /// The checks of a file per locale, which Angular shares with web, then
  /// the ids of the messages.
  @override
  Future<void> doctorChecks({required String root, required String sourcePath,
      required Easyi18nConfig config, required DoctorFindings findings}) async {
    const WebAdapter().checkLocaleFiles(root, config, findings);
    _checkIds(root, config, findings);
  }

  /// Warns at the first digest: each one starts its translation over the next
  /// time its text changes, and a share would hide the strays of a project
  /// that otherwise names its ids. Unreadable or non-Angular sources are skipped.
  static void _checkIds(String root, Easyi18nConfig config, DoctorFindings findings) {
    final source = config.source;
    if (source == null || source.isEmpty) return;
    final path = p.normalize(p.join(root, source));
    final Map<String, String>? messages;
    try {
      messages = angularMessages(jsonDecode(File(path).readAsStringSync()));
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
    if (messages == null) return;
    // A plural or select nested in a message is a message of its own, whose
    // id Angular derives from its text and takes no @@id.
    final icu = [
      for (final e in messages.entries)
        if (_digest.hasMatch(e.key) && _wholeIcu.hasMatch(e.value)) e.key,
    ];
    final digests = [
      for (final id in messages.keys)
        if (_digest.hasMatch(id) && !icu.contains(id)) id,
    ];
    if (digests.isEmpty) {
      findings.ok('ids', path,
          '${messages.length - icu.length} custom id(s), no digest'
          '${icu.isEmpty ? '' : '; ${icu.length} plural or select message(s) '
              'keep the id Angular derives from their text'}');
      return;
    }
    // The remedy leads: MCP clips a finding's message at 200 characters.
    findings.warn('ids', path,
        '${digests.length} of ${messages.length} id(s) are digests of their '
        'text: edit it and the id changes, so its translation starts over - '
        r'name each with i18n="@@cart.title" or $localize`:@@cart.title:…`',
        details: [
          ...digests.take(10),
          if (digests.length > 10) 'and ${digests.length - 10} more',
        ]);
  }

  static String _extraction(Easyi18nConfig config) {
    final source = config.source;
    final dir = source == null || source.isEmpty
        ? _localeDir : p.posix.dirname(source);
    return 'ng extract-i18n --format=json --output-path=$dir';
  }

  /// Runtime translation has to be loaded before any `$localize` runs, so the
  /// app is imported after it.
  static String _runtimeWiring(String output) => r'''
// src/main.ts
import { loadTranslations } from '@angular/localize';

const locale = 'es'; // the language to show
fetch(`/locale/messages.${locale}.json`)
  .then((response) => response.json())
  .then(({ translations }) => loadTranslations(translations))
  .catch(() => {}) // no file for that language: the source text shows
  .then(() => import('./bootstrap'));

// src/bootstrap.ts holds the bootstrapApplication(...) call main.ts had, and
// angular.json serves the files: "assets": [{"glob": "messages.*.json",
// "input": $OUTPUT, "output": "locale"}]
'''.replaceFirst(r'$OUTPUT', jsonEncode(output));

  /// `sourceLocale` is the `locale` the extractor wrote, which is Angular's
  /// own default (`en-US`) until the project sets another.
  static String _buildTimeWiring(String root, Easyi18nConfig config) {
    final source = config.source ?? '$_localeDir/messages.json';
    final dir = config.output;
    var locale = 'en-US';
    try {
      final decoded = jsonDecode(File(p.join(root, source)).readAsStringSync());
      if (decoded case {'locale': final String declared}) locale = declared;
    } on FileSystemException {
      // Not extracted yet.
    } on FormatException {
      // `doctor` names a source that is not JSON.
    }
    return '''
// angular.json, in your project (one locale per target language)
"i18n": {
  "sourceLocale": "$locale",
  "locales": { "es": "$dir/messages.es.json" }
},
"architect": { "build": { "options": { "localize": true } } }
''';
  }

  /// The `package.json` section that lists `@angular/localize`, or null.
  static String? _section(String root) {
    final Object? manifest;
    try {
      manifest = jsonDecode(File(p.join(root, 'package.json')).readAsStringSync());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
    if (manifest is! Map) return null;
    for (final section in const ['dependencies', 'devDependencies']) {
      if (manifest[section] case final Map deps when deps.containsKey(dependency)) {
        return section;
      }
    }
    return null;
  }
}
