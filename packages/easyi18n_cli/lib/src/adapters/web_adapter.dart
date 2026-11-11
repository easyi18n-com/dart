import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agents_md.dart' show agentsInline;
import '../catalog_layout.dart';
import '../config.dart';
import '../doctor_report.dart';
import '../exceptions.dart';
import '../init_report.dart';
import '../state.dart';
import '../sync_runner.dart' show SyncRunner;
import 'angular_adapter.dart' show angularMessages, kAngularFormat;
import 'stack_adapter.dart';

/// An i18n library the web adapter recognizes: the dependency that detects
/// it, the packages that make it read ICU (the plugin first, then its peers),
/// where its catalogs live when the project has none yet, the wiring `init`
/// prints, the name `doctor` gives that wiring and the pattern that finds it
/// in a source file.
typedef WebLibrary = ({
  String dependency,
  List<String> transpiler,
  String defaultDir,
  String wiring,
  String provider,
  String wired,
});

/// In detection order: an Angular app may carry i18next for a tool, so the
/// Angular libraries are asked first.
const List<WebLibrary> kWebLibraries = [
  (
    dependency: '@jsverse/transloco',
    transpiler: ['@jsverse/transloco-messageformat'],
    defaultDir: 'public/i18n',
    wiring: '''
// src/app/app.config.ts
import { provideTranslocoMessageformat } from '@jsverse/transloco-messageformat';

providers: [
  provideTransloco({ /* your config */ }),
  provideTranslocoMessageformat(),
]
''',
    provider: 'provideTranslocoMessageformat()',
    // The second arm is how an NgModule app provides the same transpiler.
    wired: r'provideTranslocoMessageformat\s*\(|'
        r'useClass\s*:\s*MessageFormatTranspiler\b',
  ),
  (
    dependency: '@ngx-translate/core',
    transpiler: ['ngx-translate-messageformat-compiler', '@messageformat/core'],
    defaultDir: 'public/i18n',
    wiring: '''
// src/app/app.config.ts
import { provideTranslateCompiler, provideTranslateService } from '@ngx-translate/core';
import { TranslateMessageFormatCompiler } from 'ngx-translate-messageformat-compiler';

providers: [
  provideTranslateService({
    compiler: provideTranslateCompiler(TranslateMessageFormatCompiler),
  }),
]
''',
    provider: 'provideTranslateCompiler(TranslateMessageFormatCompiler)',
    wired: r'(?:provideTranslateCompiler\s*\(|useClass\s*:)\s*'
        r'TranslateMessageFormat(?:Debug)?Compiler\b',
  ),
  (
    dependency: 'i18next',
    transpiler: ['i18next-icu', 'intl-messageformat'],
    defaultDir: 'locales',
    wiring: '''
import i18next from 'i18next';
import ICU from 'i18next-icu';

i18next.use(ICU).init({ /* your config */ });

// Every instance registers it, the ones the server creates too:
// createInstance().use(ICU).init(...), plugins: [ICU] or use: [ICU].
''',
    provider: 'i18next.use(ICU)',
    // `ICU` is whatever the file calls its import, so `.use()` or the plugin
    // list (remix-i18next, next-i18next) has to name what that file bound to
    // the package. The leading `\b` keeps the search linear: without it one
    // 60,000-character word (an inlined font) took 39 seconds.
    wired: r'''\b(\w+)(?:\s+from\s*|\s*=\s*require\(\s*)['"]i18next-icu['"]'''
        r'''[\s\S]*?(?:\.use\(\s*(?:new\s+)?\1\b|'''
        r'''\b(?:plugins|use)\s*:\s*\[[^\]]*?\b\1\b)''',
  ),
];

/// How the `detected` step describes each `sourceLayout` `init` can write.
const Map<String, String> _layoutReads = {
  'locale-files': 'one JSON file per locale',
  'namespaces': 'one JSON file per namespace and locale',
  'scopes': 'one JSON file per locale and scope',
};

/// The file-first adapter for JavaScript and TypeScript apps that keep JSON
/// files per locale. The base-language files are the truth: `init` points
/// `source:` at one, `sourceLayout` at how the others join it (i18next
/// namespaces, Transloco scopes) and `output:` at their directory, and names
/// the transpiler that makes the library read the ICU easyi18n writes.
class WebAdapter implements StackAdapter {
  const WebAdapter();

  static List<String> get dependencies =>
      [for (final library in kWebLibraries) library.dependency];

  @override
  String get stack => 'web';
  @override
  String get family => 'file-first';

  @override
  bool detect(String root) => libraryIn(root) != null;

  /// What [detect] looks for, worded to follow "web needs" in the CLI's
  /// refusal.
  String get detectionNeeds =>
      'one of ${dependencies.join(', ')} in package.json';

  /// File-first is Mode A by construction: Mode B is the Dart runtime SDK.
  @override
  String resolveMode(String root, String? flagMode, void Function(InitStep) report) {
    if (flagMode != null && flagMode != 'a') {
      report(InitStep('skipped', 'mode',
          'file-first projects are Mode A (TMS) - ignoring --mode $flagMode'));
    }
    return 'a';
  }

  /// Each merged layout only for the library whose default it is: anywhere
  /// else a second base file stays a refusal at sync time, which names the
  /// layout, rather than an upload nobody chose.
  @override
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report) {
    final library = libraryIn(root);
    final dir = catalogDirIn(root, library);
    final namespaces =
        library?.dependency == 'i18next' ? _namespaceRootIn(root, dir) : null;
    final source = namespaces == null
        ? p.posix.join(dir, _baseFileIn(root, dir))
        : p.posix.join(namespaces, _defaultNamespaceIn(root, namespaces));
    final layout = namespaces != null
        ? 'namespaces'
        : library?.dependency == '@jsverse/transloco' &&
                _scopesIn(root, dir, p.posix.basename(source)).isNotEmpty
            ? 'scopes'
            : 'locale-files';
    if (library != null) {
      report(InitStep('detected', p.join(root, 'package.json'),
          '${library.dependency} (${_layoutReads[layout]})'));
    }
    return (
      // A merged upload declares its own format and `pull` flattens what it
      // downloads, so `format:` only picks the export, and a flat one never
      // drops the children of a key that is also a leaf.
      format: layout == 'locale-files' && _nests(File(p.join(root, source)))
          ? 'nested_json' : 'json',
      catalog: null,
      output: dir,
      source: source,
      sourceLayout: layout,
    );
  }

  @override
  String nextCommand(Easyi18nConfig config) => 'sync';

  @override
  String agentsMdSection(Easyi18nConfig config) {
    final source = config.source;
    final named = switch (config.sourceLayout) {
      _ when source == null || source.isEmpty =>
        'The base-language file (`source:` in easyi18n.yaml) is',
      'namespaces' => 'The base-language files in '
          '`${agentsInline(p.posix.dirname(source))}/`, '
          'one per namespace, are',
      'scopes' => 'The base-language file `${agentsInline(source)}` and the '
          '`${agentsInline(p.posix.basename(source))}` of each scope directory '
          'beside it are',
      _ => 'The base-language file `${agentsInline(source)}` is',
    };
    return '''### Web

- $named the truth: add and edit user-facing strings there as ICU
  (`{name}`, `{count, plural, one {...} other {...}}`) and read them through
  your i18n library.
- The other locale files in `${agentsInline(config.output)}/` are written by
  easyi18n: do not hand-edit them.
- Never edit .easyi18n/: it is generated.
''';
  }

  @override
  void initSteps(InitContext context, Easyi18nConfig config) {
    final source = config.source;
    if (source == null || source.isEmpty) {
      context.report('skipped', 'source',
          'no `source:` in ${Easyi18nConfig.fileName} - set it to your '
          'base-language JSON file');
    } else {
      final file = File(p.normalize(p.join(context.root, source)));
      final sourceRoot = p.posix.dirname(source);
      if (file.existsSync() && config.sourceLayout == 'namespaces') {
        final namespaces = _jsonFilesIn(context.root, sourceRoot);
        context.report('ok', p.normalize(p.join(context.root, sourceRoot)),
            '${namespaces.length} i18next namespace file(s): '
            '${namespaces.join(', ')} - sync uploads them as one catalog '
            '(edit `sourceRoot:` and `source:` if another language is the base)');
      } else if (file.existsSync() && config.sourceLayout == 'scopes') {
        final scopes =
            _scopesIn(context.root, sourceRoot, p.posix.basename(source));
        context.report('ok', file.path, 'base catalog to sync, with '
            '${scopes.isEmpty ? 'no Transloco scope yet' : '${scopes.length} '
                'Transloco scope(s): ${scopes.join(', ')}'} '
            '(edit `source:` if another file is the base)');
      } else if (file.existsSync()) {
        // Named, not silent: the pick is a guess when the directory holds
        // several languages, and the fix is one line of the config.
        context.report('ok', file.path,
            'base catalog to sync (edit `source:` if another file is the base)');
      } else {
        context.write(file, '{}\n');
        context.report('created', file.path,
            'empty base catalog - move user-facing strings here as ICU');
      }
    }
    _reportTranspiler(context);
    context.ignoreDerivedState();
  }

  /// Names the transpiler instead of editing `package.json`: the project's
  /// own package manager resolves the version against the library's peers and
  /// keeps the lockfile in step, which a patched manifest would not.
  void _reportTranspiler(InitContext context) {
    final manifest = p.join(context.root, 'package.json');
    final library = libraryIn(context.root);
    if (library == null) {
      context.report('skipped', manifest,
          'no ${dependencies.join(', ')} dependency - install one and its ICU '
          'transpiler before translating');
      return;
    }
    final installed = _dependenciesIn(context.root);
    final missing = [
      for (final name in library.transpiler)
        if (!installed.contains(name)) name,
    ];
    if (missing.isEmpty) {
      context.report('ok', manifest,
          '${library.transpiler.join(', ')} present - it reads ICU once wired:',
          scopeSnippet: library.wiring);
    } else {
      context.report('skipped', manifest,
          'install ${missing.join(' ')} with your package manager so '
          '${library.dependency} reads ICU, then wire it:',
          scopeSnippet: library.wiring);
    }
  }

  /// Read-only, offline and free (the [StackAdapter] contract).
  @override
  Future<void> doctorChecks({required String root, required String sourcePath,
      required Easyi18nConfig config, required DoctorFindings findings}) async {
    checkLocaleFiles(root, config, findings);
    final manifest = p.join(root, 'package.json');
    final library = libraryIn(root);
    if (library == null) {
      findings.skip('transpiler', manifest,
          'no ${dependencies.join(', ')} dependency - cannot tell how this '
          'app reads ICU');
      return;
    }
    _checkTranspiler(root, manifest, library, findings);
    _checkWiring(root, library, findings);
  }

  /// The `source` and `targets` checks, which read only the files.
  void checkLocaleFiles(
      String root, Easyi18nConfig config, DoctorFindings findings) {
    final parts = _checkSource(root, config, findings);
    _checkTargets(root, config, parts, findings);
  }

  /// The base files of a merged layout once they all pass, else null.
  List<CatalogPart>? _checkSource(
      String root, Easyi18nConfig config, DoctorFindings findings) {
    final relative = config.source;
    if (relative == null || relative.isEmpty) {
      // Not a failure: a project that only pulls its locale files has no
      // base file to upload, and was a valid config before this adapter.
      findings.skip('source', 'source',
          'no `source:` in ${Easyi18nConfig.fileName} - this project only '
          'pulls; set it to your base-language file to sync it');
      return null;
    }
    final path = p.normalize(p.join(root, relative));
    final decoded = _readJson(File(path));
    if (decoded == _missing) {
      findings.fail('source', path,
          'base file not found - `source:` points at a file that is not there, '
          'so every sync fails before it uploads anything');
      return null;
    }
    if (mergedLayouts.contains(config.sourceLayout)) {
      return _checkParts(root, path, config, findings);
    }
    // Sync selects its input before the server reads a byte (#2456).
    try {
      SyncRunner.inputParts(path, root: root, config: config,
          baseCode: p.basenameWithoutExtension(path));
    } on CliException catch (e) {
      findings.fail('source', path, e.message, details: [
        if (e.code == 'several_files_per_locale') SyncRunner.oneCatalogRemedy,
      ]);
      return null;
    }
    if (decoded is! Map) {
      findings.fail('source', path,
          'not a JSON object of keys - sync would upload it and the server '
          'would refuse it');
      return null;
    }
    // The server names the format from the bytes and refuses a sync that
    // declares another one (`format_mismatch`), in every direction.
    final angular = angularMessages(decoded);
    final nesting = _nestingKey(decoded);
    final shape = angular != null
        ? kAngularFormat
        : nesting == null ? 'json' : 'nested_json';
    if (_jsonFormats.contains(config.format) && config.format != shape) {
      final found = angular != null
          ? 'the file is Angular\'s (`locale` and `translations`)'
          : nesting == null
              ? 'the file is flat'
              : 'the file nests (`$nesting` holds an object)';
      findings.fail('source', path,
          '$found, which is $shape, and ${Easyi18nConfig.fileName} says '
          '${config.format} - the server refuses that sync; set '
          '`format: $shape`');
      return null;
    }
    findings.ok('source', path, '${angular?.length ?? _leaves(decoded)} key(s)');
    return null;
  }

  /// The files the sync selects, read as it reads them. The merged upload
  /// declares the format of its own bytes, so `format:` only names the
  /// export here, and what sync refuses offline is what can fail.
  List<CatalogPart>? _checkParts(String root, String source,
      Easyi18nConfig config, DoctorFindings findings) {
    final List<CatalogPart> parts;
    try {
      parts = SyncRunner.inputParts(source, root: root, config: config,
          baseCode: p.basenameWithoutExtension(source));
    } on CliException catch (e) {
      findings.fail('source', source, e.message);
      return null;
    }
    final counts = <String>[];
    var total = 0;
    var readable = true;
    for (final part in parts) {
      try {
        final keys = _leaves(readCatalogPart(part));
        total += keys;
        counts.add('${part.name}: $keys key(s)');
      } on CliException catch (e) {
        findings.fail('source', p.normalize(p.join(root, part.name)), e.message);
        readable = false;
      }
    }
    if (!readable) return null;
    try {
      mergeCatalog(parts);
    } on CliException catch (e) {
      final files = e.details['files'];
      findings.fail('source', files is List && files.isNotEmpty
          ? p.normalize(p.join(root, '${files.first}')) : source, e.message);
      return null;
    }
    findings.ok('source', p.normalize(p.join(root, config.sourceRoot!)),
        '$total key(s) in ${parts.length} file(s), uploaded as one catalog',
        details: counts);
    return parts;
  }

  /// Names the locale files no pull of this checkout wrote. The record is
  /// `.easyi18n/state.json`, which is not committed: a fresh clone has none,
  /// and then nothing here can tell a pulled file from a hand-made one.
  void _checkTargets(String root, Easyi18nConfig config,
      List<CatalogPart>? parts, DoctorFindings findings) {
    final dir = p.normalize(p.join(root, config.output));
    final List<String> targets;
    if (mergedLayouts.contains(config.sourceLayout)) {
      if (parts == null) {
        findings.skip('targets', dir,
            'the base files are not known until `source` passes, so no locale '
            'file can be told from one');
        return;
      }
      targets = _mergedTargetsIn(root, config.output, parts);
    } else {
      final source = config.source;
      final base = source == null ? null : p.normalize(p.join(root, source));
      targets = [
        for (final name in _jsonFilesIn(root, config.output))
          if (p.join(dir, name) != base) name,
      ];
    }
    if (targets.isEmpty) {
      findings.skip('targets', dir,
          'no locale file besides the base yet - `pull` writes them');
      return;
    }
    final state =
        CliState.load(File(p.join(root, CliState.dirName, CliState.fileName)));
    final recorded = state.files;
    final output = state.output;
    // A record vouches only for the format and directory it was written
    // under, the same scope `pull` prunes by.
    if (recorded == null || output == null || state.format != config.format ||
        p.normalize(output) != p.normalize(config.output)) {
      findings.skip('targets', dir,
          '${targets.join(', ')}: no pull is recorded in this checkout '
          '(${CliState.dirName}/ is not committed), so a hand-made file '
          'cannot be told from a pulled one');
      return;
    }
    // Without case: on APFS a pulled file keeps the casing of an older one.
    final pulled = {for (final path in recorded) path.toLowerCase()};
    final unrecorded = [
      for (final name in targets)
        if (!pulled.contains(name.toLowerCase())) name,
    ];
    final digests = {
      for (final e in (state.digests ?? const <String, String>{}).entries)
        e.key.toLowerCase(): e.value,
    };
    final changed = [
      for (final name in targets)
        if (digests[name.toLowerCase()] case final digest?
            when contentDigest(utf8.decode(
                    File(p.join(dir, name)).readAsBytesSync(),
                    allowMalformed: true)) !=
                digest)
          name,
    ];
    if (unrecorded.isEmpty && changed.isEmpty) {
      findings.ok('targets', dir,
          '${targets.length} locale file(s), each written by `pull`');
      return;
    }
    findings.warn('targets', dir, [
      if (unrecorded.isNotEmpty)
        '${unrecorded.join(', ')}: not written by a `pull` - a pull '
            'overwrites the file of a project language and never updates any '
            'other',
      if (changed.isNotEmpty)
        '${changed.join(', ')}: $changedSincePullFinding',
    ].join('; '));
  }

  void _checkTranspiler(String root, String manifest, WebLibrary library,
      DoctorFindings findings) {
    final installed = _dependenciesIn(root);
    final plugin = library.transpiler.first;
    if (!installed.contains(plugin)) {
      findings.fail('transpiler', manifest,
          '$plugin is not in package.json - ${library.dependency} shows ICU '
          'plurals as raw text without it; install it with your package '
          'manager');
      return;
    }
    // npm 7 and later install a peer without listing it, so the manifest
    // alone would fail an install that works.
    final absent = [
      for (final peer in library.transpiler.skip(1))
        if (!installed.contains(peer) &&
            !File(p.join(root, 'node_modules', peer, 'package.json'))
                .existsSync())
          peer,
    ];
    if (absent.isEmpty) {
      findings.ok('transpiler', manifest,
          '${library.transpiler.join(', ')} present');
    } else {
      findings.warn('transpiler', manifest,
          '${absent.join(', ')}: a peer of $plugin that is neither in '
          'package.json nor in node_modules - install it with your package '
          'manager');
    }
  }

  /// Looks for the plugin's wiring in every source file of the app rather
  /// than in one conventional file: an NgModule app, an Nx workspace and
  /// i18next each keep it somewhere else, and a `fail` for a wiring that
  /// exists stops the setup that reads this report. i18next is graded per
  /// instance: each formats with the plugins it registered, so a server that
  /// creates its own renders raw ICU beside a wired client (#2574).
  void _checkWiring(String root, WebLibrary library, DoctorFindings findings) {
    final wired = RegExp(library.wired);
    final perInstance = library.dependency == 'i18next';
    final wiredIn = <String>[];
    final unwired = <String>[];
    var read = 0;
    for (final file in _sourcesIn(Directory(root))) {
      final String source;
      try {
        source = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      read++;
      // An empty literal in place of the others keeps an import from
      // reading on into the next one.
      final code = source.replaceAllMapped(_nonCode, (match) {
        final literal = match[1];
        if (!perInstance || literal == null) return ' ';
        return _i18nextPackage.hasMatch(literal) ? literal : '""';
      });
      if (wired.hasMatch(code)) {
        if (!perInstance) {
          findings.ok('wiring', file.path, '${library.provider} wired');
          return;
        }
        wiredIn.add(file.path);
      } else if (perInstance && _registersPlugins(code)) {
        unwired.add(file.path);
      }
    }
    if (wiredIn.isEmpty) {
      findings.fail('wiring', root,
          '${library.provider} not found in $read source file(s) - '
          '${library.dependency} shows ICU as raw text until '
          '${library.transpiler.first} is wired',
          details: const LineSplitter().convert(library.wiring));
      return;
    }
    // A warning: an instance is read from one file's text, and a test setup
    // without the plugin reads the same as a server.
    for (final path in unwired) {
      findings.warn('wiring', path,
          'registers i18next plugins without ${library.transpiler.first} - '
          'this instance shows ICU as raw text until it registers it too, '
          'with .use(ICU) or in its plugins: list');
    }
    if (unwired.isNotEmpty) return;
    if (wiredIn.length == 1) {
      findings.ok('wiring', wiredIn.single, '${library.provider} wired');
    } else {
      findings.ok('wiring', root,
          '${library.provider} wired in ${wiredIn.length} files',
          details: [for (final path in wiredIn) p.relative(path, from: root)]);
    }
  }

  static final RegExp _i18nextPackage =
      RegExp(r'''^(['"])(?:react-)?i18next(?:-[\w.-]+)?\1$''');
  // A clause ends before the next `import`: read on to the end of the words
  // after each one, JSX text made the search quadratic.
  static final RegExp _importsI18next = RegExp(
      r'''\bimport\s+((?:(?!\bimport\b)[\w$,{}\s*])+?)\s*from\s*['"]i18next['"]|'''
      r'''(?<![\w$])(\{[^}]+\}|[\w$]+)\s*=\s*require\(\s*['"]i18next['"]''');
  static final RegExp _i18nextImport = RegExp(
      r'''\bimport\s+((?:(?!\bimport\b)[\w$,{}\s*])+?)\s*from\s*['"](?:react-)?i18next(?:-[\w.-]+)?['"]|'''
      r'''\b([\w$]+)\s*=\s*require\(\s*['"](?:react-)?i18next(?:-[\w.-]+)?['"]''');
  static final RegExp _pluginList =
      RegExp(r'\b(?:plugins|use)\s*:\s*\[([^\]]*)\]');
  static final RegExp _name = RegExp(r'[\w$]+');

  /// Whether [code] registers plugins on an i18next instance of its own: it
  /// imports i18next and chains `.use()` into `.init(`, or its `plugins:` or
  /// `use:` list holds what an i18next package exports. Imports are not
  /// followed, so a chain on an instance from another module is not one.
  static bool _registersPlugins(String code) {
    if (_importsI18next.hasMatch(code) && _chainsToInit(code)) return true;
    final plugins = {
      for (final clause in _i18nextImport.allMatches(code))
        for (final name in _name.allMatches(clause[1] ?? clause[2]!)) name[0],
    };
    return _pluginList.allMatches(code).any((list) =>
        _name.allMatches(list[1]!).any((name) => plugins.contains(name[0])));
  }

  // Start at a local i18next binding, not every suffix of its use chain:
  // revisiting those suffixes makes a long chain without init quadratic.
  static Iterable<Match> _instanceUses(String code, Map<int, int> closing) sync* {
    final instances = <String>{};
    final factories = <String>{};
    for (final imported in _importsI18next.allMatches(code)) {
      final clause = imported[1] ?? imported[2]!;
      final binding = RegExp(r'^\s*(?:\*\s+as\s+)?([\w$]+)|'
          r'\bdefault\s*(?:as\s+|:\s*)([\w$]+)').firstMatch(clause);
      final instance = binding?[1] ?? binding?[2];
      if (instance != null) instances.add(instance);
      final factory = RegExp(r'\bcreateInstance\b(?:\s*(?:as\s+|:\s*)([\w$]+))?')
          .firstMatch(clause);
      if (factory != null) factories.add(factory[1] ?? 'createInstance');
    }
    final calls = [
      ...factories.map(RegExp.escape),
      for (final name in instances)
        '${RegExp.escape(name)}\\s*\\.\\s*createInstance',
    ].join('|');
    if (calls.isNotEmpty) {
      // A TypeScript annotation, kept to its line: `const server: i18n = ...`.
      final assigned = RegExp('(?<![\\w\$])([\\w\$]+)\\s*'
          '(?::[\\w\$.<>\\[\\]|& \\t]*)?=\\s*(?:$calls)\\s*\\(');
      instances.addAll(assigned.allMatches(code).map((match) => match[1]!));
    }
    final receivers = [
      if (calls.isNotEmpty) '(?:$calls)\\s*(\\()',
      ...instances.map(RegExp.escape),
    ];
    if (receivers.isEmpty) return;
    final start = RegExp('(?<![\\w\$\\.])(?:${receivers.join('|')})');
    for (final match in start.allMatches(code)) {
      final at = calls.isNotEmpty && match[1] != null
          ? closing[match.end - 1] : match.end;
      if (at == null) continue;
      final link = _link.matchAsPrefix(code, at);
      if (link != null && link[1] == 'use') yield link;
    }
  }

  static final RegExp _link = RegExp(r'\s*\.\s*(use|init)\s*\(');

  /// Whether a `.use()` chain in [code] reaches `.init(`, past the arguments
  /// of each link: a backend's loader nests parentheses of its own.
  static bool _chainsToInit(String code) {
    final closing = _closingParens(code);
    for (final use in _instanceUses(code, closing)) {
      var at = use.start;
      for (var link = _link.matchAsPrefix(code, at);
          link != null;
          link = _link.matchAsPrefix(code, at)) {
        if (link[1] == 'init') return true;
        final end = closing[link.end - 1];
        if (end == null) break;
        at = end;
      }
    }
    return false;
  }

  /// The index after the `)` that closes each `(`, keyed by the `(`. One
  /// pass: a `(` no `)` closes, as in a regex literal, made a scan from each
  /// `.use(` read to the end of the file.
  static Map<int, int> _closingParens(String code) {
    final open = <int>[];
    final closing = <int, int>{};
    for (var i = 0; i < code.length; i++) {
      final unit = code.codeUnitAt(i);
      if (unit == 0x28) {
        open.add(i);
      } else if (unit == 0x29 && open.isNotEmpty) {
        closing[open.removeLast()] = i + 1;
      }
    }
    return closing;
  }

  /// The one check that needs the project, so `DoctorRunner` runs it with the
  /// languages it fetched. [codes] come as the server stores them (`pt-br`)
  /// and it serves each as `pt-BR.json`: names compare without case.
  void checkLanguages({required String root, required Easyi18nConfig config,
      required List<String> codes, required DoctorFindings findings}) {
    final dir = p.normalize(p.join(root, config.output));
    final source = config.source;
    final sourceRoot = config.sourceRoot;
    // Under namespaces a language is a directory and its files namespaces.
    final namespaces = config.sourceLayout == 'namespaces';
    final files = {
      if (namespaces)
        for (final name in [
          for (final sub in _subdirsIn(root, config.output))
            if (!sub.startsWith('.') &&
                _jsonFilesIn(root, p.posix.join(config.output, sub)).isNotEmpty)
              sub,
          if (sourceRoot != null &&
              Directory(p.join(root, sourceRoot)).existsSync())
            p.basename(sourceRoot),
        ])
          name.toLowerCase(): '$name/'
      else
        for (final name in [
          ..._jsonFilesIn(root, config.output),
          // The base file is its language's file wherever it lives.
          if (source != null && source.isNotEmpty &&
              File(p.join(root, source)).existsSync()) p.basename(source),
        ])
          p.basenameWithoutExtension(name).toLowerCase(): name,
    };
    final project = {for (final code in codes) code.toLowerCase()};
    final noFile = [
      for (final code in codes)
        if (!files.containsKey(code.toLowerCase())) code,
    ];
    final noLanguage = [
      for (final entry in files.entries)
        if (!project.contains(entry.key)) entry.value,
    ];
    if (noFile.isEmpty && noLanguage.isEmpty) {
      findings.ok('languages', dir,
          '${codes.length} project language(s), each with its locale file: '
          '${codes.join(', ')}');
    }
    if (noFile.isNotEmpty) {
      findings.warn('languages', dir,
          '${noFile.join(', ')}: on the project with no locale file here - '
          'a `pull` writes one per language');
    }
    if (noLanguage.isNotEmpty) {
      findings.warn('languages', dir,
          '${noLanguage.join(', ')}: the project has no such language - add '
          'it to the project or delete the ${namespaces ? 'directory' : 'file'}');
    }
  }

  // ----- discovery -----------------------------------------------------------

  /// The first recognized library `package.json` depends on, or null.
  static WebLibrary? libraryIn(String root) {
    final installed = _dependenciesIn(root);
    for (final library in kWebLibraries) {
      if (installed.contains(library.dependency)) return library;
    }
    return null;
  }

  /// Where the per-locale files live, relative to [root] with forward
  /// slashes: what Transloco declares, then a conventional directory that
  /// already holds a JSON file, then one that holds i18next's language
  /// directories, then the library's default.
  static String catalogDirIn(String root, WebLibrary? library) {
    final declared = _translocoSetting(root, _rootPath);
    // Repository content, not a setting of ours: a path that leaves the
    // project is not followed, since `init` creates the base file under it.
    if (declared != null && p.isWithin(root, p.join(root, declared))) {
      return p.posix.normalize(declared);
    }
    for (final dir in _conventionalDirs) {
      if (_jsonFilesIn(root, dir).isNotEmpty) return dir;
    }
    if (library?.dependency == 'i18next') {
      for (final dir in _namespaceDirs) {
        if (_languageDirsIn(root, dir).isNotEmpty) return dir;
      }
    }
    return library?.defaultDir ?? _conventionalDirs.first;
  }

  static const List<String> _conventionalDirs = [
    'public/i18n', 'src/assets/i18n', 'locales',
  ];

  /// Where i18next's default `loadPath`, `/locales/{{lng}}/{{ns}}.json`,
  /// lands on disk: read by `i18next-fs-backend`, or served from `public/`.
  static const List<String> _namespaceDirs = ['locales', 'public/locales'];

  static final RegExp _languageTag =
      RegExp(r'^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8})*$');

  /// The base-language directory of i18next namespaces under [dir]: `en`,
  /// else the first language by name. Null when [dir] holds JSON files of
  /// its own, which makes it one file per locale.
  static String? _namespaceRootIn(String root, String dir) {
    if (_jsonFilesIn(root, dir).isNotEmpty) return null;
    final languages = _languageDirsIn(root, dir);
    if (languages.isEmpty) return null;
    return p.posix.join(dir, languages.contains('en') ? 'en' : languages.first);
  }

  /// The subdirectories of [dir] named like a language that hold JSON files.
  static List<String> _languageDirsIn(String root, String dir) => [
    for (final name in _subdirsIn(root, dir))
      if (_languageTag.hasMatch(name) &&
          _jsonFilesIn(root, p.posix.join(dir, name)).isNotEmpty)
        name,
  ];

  /// i18next's `defaultNS`, else the first namespace by name.
  static String _defaultNamespaceIn(String root, String dir) {
    final files = _jsonFilesIn(root, dir);
    return files.contains('translation.json') ? 'translation.json' : files.first;
  }

  /// The Transloco scopes beside the root file [base] in [dir]: each
  /// directory one level down that holds a file of the same name. Hidden
  /// ones are left out, as `sync` leaves them out.
  static List<String> _scopesIn(String root, String dir, String base) => [
    for (final name in _subdirsIn(root, dir))
      if (!name.startsWith('.') &&
          File(p.join(root, dir, name, base)).existsSync())
        name,
  ];

  /// What a merged layout's pull writes into [dir], one directory down
  /// included (`es/common.json`, `admin/es.json`), apart from its base files.
  static List<String> _mergedTargetsIn(
      String root, String dir, List<CatalogPart> parts) {
    final bases = {
      for (final part in parts) p.normalize(p.join(root, part.name)),
    };
    return [
      for (final name in [
        ..._jsonFilesIn(root, dir),
        for (final sub in _subdirsIn(root, dir))
          if (!sub.startsWith('.'))
            for (final file in _jsonFilesIn(root, p.posix.join(dir, sub)))
              '$sub/$file',
      ])
        if (!bases.contains(p.normalize(p.join(root, dir, name)))) name,
    ]..sort();
  }

  static List<String> _subdirsIn(String root, String dir) {
    try {
      return [
        for (final entry in Directory(p.join(root, dir)).listSync())
          if (entry is Directory) p.basename(entry.path),
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  static final RegExp _rootPath =
      RegExp('''rootTranslationsPath\\s*:\\s*['"]([^'"]+)['"]''');
  static final RegExp _firstLang =
      RegExp('''langs\\s*:\\s*\\[\\s*['"]([A-Za-z0-9_-]+)['"]''');

  /// The base-language file name: the first language Transloco lists, then
  /// `en.json`, unless the directory holds files and none is English.
  static String _baseFileIn(String root, String dir) {
    final declared = _translocoSetting(root, _firstLang);
    if (declared != null) return '$declared.json';
    final files = _jsonFilesIn(root, dir);
    return files.isEmpty || files.contains('en.json') ? 'en.json' : files.first;
  }

  static String? _translocoSetting(String root, RegExp setting) {
    for (final name in const ['transloco.config.ts', 'transloco.config.js']) {
      final file = File(p.join(root, name));
      try {
        final match = setting.firstMatch(file.readAsStringSync());
        if (match != null) return match.group(1);
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// Sorted, so the pick never depends on the filesystem's listing order.
  static List<String> _jsonFilesIn(String root, String dir) {
    try {
      return [
        for (final entry in Directory(p.join(root, dir)).listSync())
          if (entry is File && entry.path.endsWith('.json'))
            p.basename(entry.path),
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  static Set<String> _dependenciesIn(String root) {
    final manifest = _readJson(File(p.join(root, 'package.json')));
    if (manifest is! Map) return const {};
    return {
      for (final section in const ['dependencies', 'devDependencies'])
        if (manifest[section] case final Map deps) ...deps.keys.cast<String>(),
    };
  }

  static const Object _missing = Object();

  /// The decoded file, [_missing] when it cannot be read, null when it is not
  /// JSON.
  static Object? _readJson(File file) {
    try {
      return jsonDecode(file.readAsStringSync());
    } on FileSystemException {
      return _missing;
    } on FormatException {
      return null;
    }
  }

  static bool _nests(File file) {
    final decoded = _readJson(file);
    return decoded is Map && _nestingKey(decoded) != null;
  }

  static const Set<String> _jsonFormats = {'json', 'nested_json', kAngularFormat};

  /// The first key that makes [catalog] `nested_json` for the server, or
  /// null for a flat file. Its rule, not ours (`parser_registry.dart`): an
  /// object under an `@key` is metadata and nests nothing.
  static String? _nestingKey(Map<Object?, Object?> catalog) {
    for (final entry in catalog.entries) {
      final key = '${entry.key}';
      if (entry.value is Map && !key.startsWith('@')) return key;
    }
    return null;
  }

  static const Set<String> _sourceExtensions = {
    '.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs', '.vue',
    '.svelte',
  };

  /// Installed and built code: a provider in there wires some other app.
  static const Set<String> _notSourceDirs = {
    'node_modules', 'dist', 'build', 'out', 'coverage',
  };

  /// Quoted examples are not wiring. Keep only the package specifier that
  /// the i18next import pattern needs; comment markers inside strings are data.
  static final RegExp _nonCode = RegExp(
      r'''("(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`)|/\*[\s\S]*?\*/|//[^\r\n]*''');

  /// The app's source files in path order, so the file a finding names never
  /// depends on the filesystem's listing order. Links are not followed: a
  /// workspace links its packages into each other.
  static Iterable<File> _sourcesIn(Directory dir) sync* {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        if (!name.startsWith('.') && !_notSourceDirs.contains(name)) {
          yield* _sourcesIn(entry);
        }
      } else if (entry is File &&
          _sourceExtensions.contains(p.extension(name))) {
        yield entry;
      }
    }
  }

  static int _leaves(Map<Object?, Object?> node) => node.values.fold(
      0, (count, value) => count + (value is Map ? _leaves(value) : 1));
}
