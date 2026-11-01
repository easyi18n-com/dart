import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../agents_md.dart' show agentsInline;
import '../config.dart';
import '../contract.dart';
import '../delivery.dart';
import '../doctor_report.dart';
import '../extract/extraction_report.dart' show ellipsize;
import '../extract/source_unit.dart';
import '../extract/tr_extractor.dart';
import '../icu_lint.dart';
import '../init_report.dart';
import '../project_ref.dart';
import '../pull_runner.dart';
import '../scaffold.dart';
import '../state.dart';
import 'stack_adapter.dart';

class DartFlutterAdapter implements StackAdapter {
  DartFlutterAdapter({TrExtractor? extractor, DeliveryClientFactory? deliveryFactory})
      : _extractor = extractor ?? TrExtractor(),
        _deliveryFactory = deliveryFactory ?? _defaultDelivery;
  final TrExtractor _extractor;
  final DeliveryClientFactory _deliveryFactory;
  @override
  String get stack => 'flutter';
  @override
  String get family => 'code-first';

  /// Detection runs over a tree nobody promised is readable — `doctor` calls
  /// it before it knows what the project is — so a pubspec this process cannot
  /// read or parse is "not Flutter", never a crash. It used to throw on a
  /// non-UTF8 file, which only stayed invisible while doctor named its stack.
  @override
  bool detect(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return false;
    final dynamic doc;
    try {
      doc = loadYaml(pubspec.readAsStringSync());
    } on YamlException {
      return false;
    } on FileSystemException {
      return false;
    }
    return doc is Map && doc.containsKey('flutter');
  }

  @override
  String resolveMode(String root, String? flagMode, void Function(InitStep) report) {
    if (flagMode != null) return flagMode;
    if (File(p.join(root, 'l10n.yaml')).existsSync()) {
      report(InitStep('detected', p.join(root, 'l10n.yaml'),
          'gen_l10n project - assuming Mode A (override with --mode b)'));
      return 'a';
    }
    return 'b';
  }

  /// Mode B pulls a directory of per-locale files, which is what the core
  /// defaults already describe. Mode A writes into the `arb-dir` of
  /// `l10n.yaml`, and its template is `source:`, the file pull leaves alone:
  /// a first pull used to replace it with the server's keys (#2343).
  @override
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report) {
    final l10n = mode == 'a' ? _l10nYaml(root) : null;
    if (l10n == null) {
      return (format: null, catalog: null, output: null, source: null,
          sourceLayout: null);
    }
    final template = p.posix.join(l10n.arbDir, l10n.template);
    final exists = File(p.join(root, template)).existsSync();
    if (exists) {
      report(InitStep('detected', p.join(root, template),
          'gen_l10n template - set as `source:`, pull never writes it. '
          'Before the first pull, import the .arb files in the dashboard '
          '(Keys, Import a file) and publish'));
    }
    return (format: null, catalog: null, output: l10n.arbDir,
        source: exists ? template : null, sourceLayout: null);
  }

  /// The two settings of `l10n.yaml` init reads, with gen_l10n's defaults
  /// for a key it leaves out. Null when the file does not parse: the tree
  /// is not ours to trust, so init keeps the core defaults instead.
  static ({String arbDir, String template})? _l10nYaml(String root) {
    final Object? doc;
    try {
      doc = loadYaml(File(p.join(root, 'l10n.yaml')).readAsStringSync());
    } on YamlException {
      return null;
    } on FileSystemException {
      return null;
    }
    final settings = doc is Map ? doc : const {};
    String read(String key, String fallback) => switch (settings[key]) {
          final String value when value.trim().isNotEmpty =>
            p.posix.normalize(value.trim()),
          _ => fallback,
        };
    return (arbDir: read('arb-dir', 'lib/l10n'),
        template: read('template-arb-file', 'app_en.arb'));
  }

  @override
  String nextCommand(Easyi18nConfig config) => config.mode == 'a' ? 'pull' : 'push';

  @override
  String agentsMdSection(Easyi18nConfig config) {
    final output = agentsInline(config.output);
    final template = config.source;
    final strings = config.mode == 'a' && template != null && template.isNotEmpty
        ? '''- Mode A: the app keeps gen_l10n. `${agentsInline(template)}` is the truth:
  add keys there as usual; `easyi18n pull` never writes it.
- Before the first pull, import the .arb files in the dashboard (Keys →
  Import a file, the template first) and publish: pull writes every other
  .arb in `$output` and the next pull overwrites them, so never hand-edit
  those.'''
        : config.mode == 'a'
        ? '''- Mode A: the app keeps gen_l10n and its .arb files. `easyi18n pull`
  writes every .arb file into `$output`, the template too. Never hand-edit a
  pulled .arb: the next pull overwrites it.'''
        : '''- User-facing text goes through `context.tr('Natural English')` from
  `package:easyi18n/easyi18n.dart`: the literal IS the key. Placeholders
  `{name}`, plurals in ICU `{count, plural, one{...} other{...}}`, `ctx:` to
  tell homonyms apart. Never interpolate: `tr('Hi \$name')` cannot be
  extracted. Leave logs, ids, URLs and keys alone.
- macOS needs `com.apple.security.network.client` in both entitlements files;
  web needs the delivery CDN to allow the app's origin (CORS). doctor checks
  both.''';
    return '''### Flutter

$strings
- Never edit easyi18n.lock, .easyi18n/ or assets/easyi18n/: they are generated.
''';
  }

  @override
  void initSteps(InitContext context, Easyi18nConfig config) =>
      _FlutterInit(context).run(config);

  @override
  Future<void> doctorChecks({required String root, required String sourcePath,
    required Easyi18nConfig config, required DoctorFindings findings}) =>
      _FlutterDoctor(_extractor, _deliveryFactory, findings).run(root: root,
          sourcePath: sourcePath, config: config);

  static DeliveryClient _defaultDelivery({required String baseUrl}) =>
      DeliveryClient(baseUrl: baseUrl);
}

class _FlutterInit {
  _FlutterInit(this.context);
  final InitContext context;
  void run(Easyi18nConfig config) {
    final root = context.root;
    if (config.mode == 'a') {
      // Mode A is "we're your TMS": the customer keeps gen_l10n and their
      // own runtime. Only the config and the derived-state ignore make
      // sense — the runtime dependency, offline floor, macOS network
      // entitlement and Easyi18nScope are all Mode B, and wiring them
      // (especially editing main.dart) adds a runtime the customer will
      // never use.
      context.ignoreDerivedState();
    } else {
      _patchPubspec(File(p.join(root, 'pubspec.yaml')));
      _ensureFloorDir(Directory(p.join(root, 'assets', 'easyi18n')));
      context.ignoreDerivedState();
      for (final name in const [
        'DebugProfile.entitlements',
        'Release.entitlements',
      ]) {
        _patchEntitlements(File(p.join(root, 'macos', 'Runner', name)));
      }
      _wireMain(File(p.join(root, 'lib', 'main.dart')), config);
    }

  }

  void _patchPubspec(File pubspec) {
    if (!pubspec.existsSync()) {
      context.report('skipped', pubspec.path, 'not found - not a package root?');
      return;
    }
    var content = pubspec.readAsStringSync();
    var changed = false;

    final stale = staleRuntimeConstraint(content);
    final withDep = addRuntimeDependency(content);
    if (withDep != null) {
      content = withDep;
      changed = true;
      context.report('patched', pubspec.path, stale == null
          ? 'added easyi18n dependency'
          : 'raised easyi18n $stale to $kRuntimeDependency');
    } else {
      context.report('ok', pubspec.path, 'easyi18n already a dependency');
    }

    final withAssets = addAssetsFloor(content);
    if (withAssets != null) {
      content = withAssets;
      changed = true;
      context.report('patched', pubspec.path, 'registered $kAssetsFloorDir assets');
    } else {
      context.report('ok', pubspec.path, 'assets floor already registered');
    }

    final withLocalizations = addLocalizationsDependency(content);
    if (withLocalizations != null) {
      content = withLocalizations;
      changed = true;
      context.report('patched', pubspec.path,
          'added flutter_localizations dependency');
    } else {
      context.report('ok', pubspec.path,
          'flutter_localizations already a dependency');
    }

    if (changed) context.write(pubspec, content);
  }

  void _ensureFloorDir(Directory dir) {
    final keep = File(p.join(dir.path, '.gitkeep'));
    if (dir.existsSync() && (keep.existsSync() || dir.listSync().isNotEmpty)) {
      context.report('ok', '${dir.path}/', 'floor dir present');
      return;
    }
    if (!context.dryRun) {
      dir.createSync(recursive: true);
      keep.writeAsStringSync('');
    }
    context.report('created', '${dir.path}/', 'offline floor dir');
  }

  void _patchEntitlements(File plist) {
    if (!plist.existsSync()) {
      context.report('skipped', plist.path, 'no macOS target');
      return;
    }
    final patched = patchEntitlements(plist.readAsStringSync());
    if (patched == null) {
      context.report('ok', plist.path, '$kNetworkClientKey already set');
      return;
    }
    context.write(plist, patched);
    context.report('patched', plist.path, 'granted $kNetworkClientKey');
  }

  /// Both edits to `main.dart` from one read, so a dry run and a partial
  /// bail see the same source: the scope around `runApp`, then the locale
  /// arguments of `MaterialApp`. A bail prints the full snippet.
  void _wireMain(File main, Easyi18nConfig config) {
    final baseUrl = config.baseUrl == Easyi18nConfig.defaultBaseUrl
        ? null
        : config.baseUrl;
    final snippet = scopeSnippet(config.ref, baseUrl: baseUrl);
    if (!main.existsSync()) {
      context.report('skipped', main.path, 'not found - wire the scope manually:',
          scopeSnippet: snippet);
      return;
    }
    var source = main.readAsStringSync();
    var changed = false;
    try {
      final wrapped = wrapRunApp(source, config.ref, baseUrl: baseUrl);
      if (wrapped == null) {
        context.report('ok', main.path, 'Easyi18nScope already mounted');
      } else {
        source = wrapped;
        changed = true;
        context.report('patched', main.path, 'wrapped runApp in Easyi18nScope');
      }
    } on ScaffoldUnpatchable catch (e) {
      context.report('skipped', main.path, '${e.reason} - wire the scope manually:',
          scopeSnippet: snippet);
    }
    try {
      final localized = localizeApp(source);
      if (localized == null) {
        context.report('ok', main.path, 'MaterialApp already declares its locales');
      } else {
        source = localized;
        changed = true;
        context.report('patched', main.path, 'wired MaterialApp locales');
      }
    } on ScaffoldUnpatchable catch (e) {
      context.report('skipped', main.path,
          '${e.reason} - wire the MaterialApp locales manually:',
          scopeSnippet: snippet);
    }
    if (changed) context.write(main, source);
  }

}

class _FlutterDoctor {
  _FlutterDoctor(this._extractor, this._deliveryFactory, this._checks);
  final TrExtractor _extractor;
  final DeliveryClientFactory _deliveryFactory;
  final DoctorFindings _checks;

  /// The locales the live manifest serves; null until one was read.
  Set<String>? _published;
  String _floorPubspec = '';

  Future<void> run({required String root, required String sourcePath,
    required Easyi18nConfig config}) async {
    final modeA = config.mode == 'a';
    if (modeA) {
      // Mode A keeps gen_l10n and its own runtime (#415): the pubspec
      // dependency, offline floor, macOS entitlements and Easyi18nScope are
      // all runtime-SDK wiring — on a Mode A project their absence is
      // CORRECT, not a failure.
      _checks.skip('mode', 'mode', 'runtime wiring checks not applicable (Mode A: pubspec '
          'dependency, assets floor, entitlements, Easyi18nScope)');
      _checks.skip('mode', 'mode', "if this project's dashboard Settings has not been set "
          'to Mode A yet, do that too - it picks the right publish defaults');
    } else {
      _checkPubspec(File(p.join(root, 'pubspec.yaml')));
      _checkEntitlements(Directory(p.join(root, 'macos')));
    }
    final changed = PullRunner.changedTargets(
        CliState.load(File(p.join(root, CliState.dirName, CliState.fileName))),
        root, config);
    if (changed.isNotEmpty) {
      _checks.warn('targets', p.normalize(p.join(root, config.output)),
          '${changed.join(', ')}: $changedSincePullFinding');
    }

    // ---- source scan (tr() + scope) + ICU lint -------------------------------
    final sourceDir = Directory(p.join(root, sourcePath));
    final extraction = _extractor.extractFromDirectory(
      sourceDir,
      relativeTo: root,
    );
    if (!modeA) _checkWiring(extraction, root, sourceDir, config);
    _reportScan(extraction);
    _lintSources(extraction);

    // ---- delivery probe + published-vs-code grading -------------------------
    // Runtime-SDK infrastructure: the manifest/bundles are what Easyi18nScope
    // fetches OTA. Mode A consumes the export API through `pull` instead, so
    // "nothing published to delivery" is not a finding there.
    if (modeA) {
      _checks.skip('delivery', 'delivery',
          'not applicable (Mode A pulls files, no OTA runtime)');
    } else {
      final client = _deliveryFactory(baseUrl: config.baseUrl);
      try {
        final probe = await _probeDelivery(client, config);
        _checkFloor(Directory(p.join(root, 'assets', 'easyi18n')));
        if (probe != null && extraction.units.isNotEmpty) {
          await _gradeAgainstBundles(client, probe, extraction.units);
        }
      } finally {
        client.close();
      }
    }

  }

  void _checkPubspec(File pubspec) {
    if (!pubspec.existsSync()) {
      _checks.fail('pubspec', pubspec.path, 'not found - not a package root?');
      return;
    }
    final content = _readText(pubspec, 'pubspec');
    if (content == null) return;
    _floorPubspec = content;
    // addRuntimeDependency returns null exactly when the dependency already
    // exists (any form) and resolves, which makes it a free read-only check.
    final stale = staleRuntimeConstraint(content);
    if (addRuntimeDependency(content) == null) {
      _checks.ok('pubspec', pubspec.path, 'easyi18n is a dependency');
    } else if (stale != null) {
      _checks.fail('pubspec', pubspec.path,
          'easyi18n $stale excludes the SDK Easyi18nScope.localesOf needs '
          "($kRuntimeDependency); run 'easyi18n init'");
    } else {
      _checks.fail('pubspec', pubspec.path, "missing the 'easyi18n' dependency");
    }
    if (floorRegistered(content)) {
      _checks.ok('pubspec', pubspec.path, '$kAssetsFloorDir assets registered');
    } else {
      _checks.fail('pubspec', pubspec.path, '$kAssetsFloorDir not under flutter: assets:');
    }
  }

  /// The SDK asks for `assets/easyi18n/<locale>.json` at start and for each
  /// locale the app switches to; Flutter web logs a 404 for every one that
  /// was not baked (#1835). Graded against what the manifest serves.
  void _checkFloor(Directory dir) {
    final path = '${dir.path}/';
    if (!dir.existsSync()) {
      _checks.fail('assets', path, 'offline floor dir missing');
      return;
    }
    final baked = {
      for (final f in dir.listSync().whereType<File>())
        if (p.extension(f.path) == '.json') p.basenameWithoutExtension(f.path),
    };
    final published = _published;
    if (published == null || published.isEmpty) {
      if (baked.isEmpty) {
        _checks.warn('assets', path, "offline floor empty - 'easyi18n pull' "
            'fills it once a version is published');
      } else {
        _checks.ok('assets', path, 'offline floor for ${baked.length} locale(s)');
      }
      return;
    }
    final missing = published.where((l) => !baked.contains(l) ||
        !floorRegistered(_floorPubspec, locale: l)).toList()..sort();
    if (missing.isEmpty) {
      _checks.ok('assets', path,
          'offline floor for ${published.length} published locale(s)');
    } else {
      _checks.fail('assets', path, 'no offline floor for ${missing.join(', ')} '
          '- the file must exist and be registered in pubspec.yaml; '
          "run 'easyi18n pull' (after 'easyi18n init' if assets are unregistered)");
    }
  }

  void _checkEntitlements(Directory macosDir) {
    if (!macosDir.existsSync()) {
      _checks.skip('entitlements', 'macos/', 'no macOS target');
      return;
    }
    for (final name in const [
      'DebugProfile.entitlements',
      'Release.entitlements',
    ]) {
      final file = File(p.join(macosDir.path, 'Runner', name));
      if (!file.existsSync()) {
        _checks.fail('entitlements', file.path, 'not found - macOS target without entitlements?');
        continue;
      }
      final content = _readText(file, 'entitlements');
      if (content == null) continue;
      switch (_entitlementState(content)) {
        case _Entitlement.granted:
          _checks.ok('entitlements', file.path, '$kNetworkClientKey granted');
        case _Entitlement.denied:
          _checks.fail('entitlements', file.path,
            '$kNetworkClientKey is explicitly <false/> - delivery fetches '
            'fail SILENTLY in the macOS sandbox',
          );
        case _Entitlement.missing:
          _checks.fail('entitlements', file.path,
            '$kNetworkClientKey missing - delivery fetches fail SILENTLY in '
            'the macOS sandbox',
          );
        case _Entitlement.unverifiable:
          _checks.warn('entitlements', file.path,
            'could not verify $kNetworkClientKey (unrecognized plist shape)',
          );
      }
    }
  }

  /// Structural read of the entitlement pair. Checked directly (not via the
  /// init patcher, whose null conflates "already true" with "malformed").
  static _Entitlement _entitlementState(String rawPlist) {
    // A commented-out pair must not count as granted.
    final plist = rawPlist.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    final pair = RegExp(
      '<key>${RegExp.escape(kNetworkClientKey)}</key>'
      r'\s*<(true|false)\s*/>',
    ).firstMatch(plist);
    if (pair != null) {
      return pair.group(1) == 'true'
          ? _Entitlement.granted
          : _Entitlement.denied;
    }
    if (plist.contains(kNetworkClientKey)) return _Entitlement.unverifiable;
    if (!plist.contains('</dict>')) return _Entitlement.unverifiable;
    return _Entitlement.missing;
  }

  void _checkWiring(
    ExtractionResult extraction,
    String root,
    Directory sourceDir,
    Easyi18nConfig config,
  ) {
    // A narrowed --source-dir must not false-FAIL wiring that lives elsewhere
    // under lib/ (usually main.dart / a bootstrap file); what the narrowed
    // scan did find is kept.
    final lib = Directory(p.join(root, 'lib'));
    ExtractionResult? fallback;
    ExtractionResult found(bool Function(ExtractionResult) has) {
      if (has(extraction) ||
          !lib.existsSync() ||
          p.equals(sourceDir.path, lib.path)) {
        return extraction;
      }
      return fallback ??= _extractor.extractFromDirectory(lib, relativeTo: root);
    }
    final scope = found((r) => r.scopeFile != null);
    final app = found((r) => r.appFile != null);
    final scopeFile = scope.scopeFile;
    if (scopeFile == null) {
      _checks.fail('scope', p.join(root, 'lib', 'main.dart'),
        'Easyi18nScope not mounted - tr() will never resolve; run '
        "'easyi18n init'",
      );
    } else {
      final path = p.join(root, scopeFile);
      _checks.ok('scope', path, 'Easyi18nScope mounted');
      // The SDK default is production: a scope without baseUrl never sees
      // what the CLI publishes to the emulator or a staging backend.
      if (config.baseUrl != Easyi18nConfig.defaultBaseUrl) {
        if (scope.scopeNamesBaseUrl) {
          _checks.ok('scope', path, 'Easyi18nScope sets its baseUrl');
        } else {
          _checks.fail('scope', path,
            'Easyi18nScope has no baseUrl - the app reads '
            '${Easyi18nConfig.defaultBaseUrl} while easyi18n.yaml says '
            "${config.baseUrl}; add baseUrl: Uri.parse('${config.baseUrl}')",
          );
        }
      }
    }
    final appFile = app.appFile;
    if (appFile == null) {
      _checks.skip('app', p.join(root, 'lib'),
          'no MaterialApp found - locale wiring not checked');
    } else if (app.appLocalized) {
      _checks.ok('app', p.join(root, appFile),
          'MaterialApp declares localizationsDelegates and supportedLocales');
    } else {
      _checks.fail('app', p.join(root, appFile),
        'MaterialApp has no supportedLocales / localizationsDelegates - tr() '
        "resolves en only, whatever the device says; run 'easyi18n init'",
      );
    }
  }

  // ----- source checks -------------------------------------------------------

  void _reportScan(ExtractionResult extraction) {
    _checks.ok('scan', 'scan',
      '${extraction.filesScanned} file(s), ${extraction.units.length} '
          'extractable tr() string(s)',
    );
    if (extraction.dynamics.isNotEmpty) {
      _checks.warn('scan', 'scan',
        '${extraction.dynamics.length} tr() call(s) with a non-literal '
            'source rely on runtime auto-capture',
        details: [for (final d in extraction.dynamics)
          '${d.file}:${d.line}  ${d.snippet}'],
      );
    }
  }

  void _lintSources(ExtractionResult extraction) {
    final details = <String>[];
    for (final unit in extraction.units) {
      final found = lintIcuMessage(unit.source);
      try {
        canonicalizeCtx(unit.ctx);
      } on ArgumentError {
        found.add('ctx contains control characters');
      }
      for (final problem in found) {
        details.add('${unit.file}:${unit.line}  "${ellipsize(unit.source)}"'
            ' - $problem');
      }
    }
    if (details.isEmpty) {
      _checks.ok('icu', 'icu', '${extraction.units.length} source string(s) lint clean');
    } else {
      _checks.fail('icu', 'icu',
        '${details.length} ICU problem(s) - a malformed string renders RAW to users',
        details: details,
      );
    }
  }

  // ----- delivery checks -----------------------------------------------------

  /// Probes the manifest. Returns it when the scan can proceed, null when
  /// delivery is absent/broken (already reported).
  Future<ManifestProbe?> _probeDelivery(
    DeliveryClient client,
    Easyi18nConfig config,
  ) async {
    final ManifestProbe probe;
    try {
      probe = switch (config.ref) {
        IdRef(:final id) => await client.fetchManifest(id),
        HandleRef(:final workspace, :final slug) =>
          await client.fetchManifestByRef(workspace, slug),
      };
    } on Exception catch (e) {
      _checks.fail('delivery', 'delivery', '$e');
      return null;
    }

    if (probe.statusCode == 404 && probe.errorCode == 'not_published') {
      _checks.warn('delivery', 'delivery',
        "nothing published yet - run 'easyi18n push', then publish",
      );
      return null;
    }
    if (probe.statusCode != 200) {
      _checks.fail('delivery', 'delivery',
        'GET ${probe.uri} -> HTTP ${probe.statusCode}'
            '${probe.errorMessage == null ? '' : ' (${probe.errorMessage})'}',
      );
      return null;
    }
    // A 200 that isn't a manifest (SPA catch-all, captive portal, WAF page)
    // is a broken delivery path, not a version-skew warning.
    if (probe.revision == null) {
      _checks.fail('delivery', 'delivery',
        'GET ${probe.uri} returned 200 but not a delivery manifest - '
            'check baseUrl',
      );
      return null;
    }

    _published = probe.locales.keys.toSet();
    _checks.ok('delivery', 'delivery',
      'manifest reachable - revision ${probe.revision}, '
          '${probe.locales.length} locale(s)',
    );

    // The Flutter WEB build can only fetch this cross-origin with CORS; a
    // missing header is invisible on macOS and fatal in every browser. A
    // locked-down value is graded, not just presence: only `*` provably
    // admits the customer's own app origin.
    final cors = probe.headers['access-control-allow-origin'];
    if (cors == '*') {
      _checks.ok('delivery', 'delivery', 'CORS allows browser fetches');
    } else if (cors != null) {
      _checks.warn('delivery', 'delivery',
        'CORS is locked to $cors - your web app must be served from that '
            'origin or browser fetches will be blocked',
      );
    } else {
      _checks.fail('delivery', 'delivery',
        'no access-control-allow-origin header - the web app cannot fetch '
            'translations',
      );
    }

    if (!probe.tokenAlgoVersions.contains(kMessageTokenAlgoVersion)) {
      _checks.warn('delivery', 'delivery',
        'manifest serves token algo ${probe.tokenAlgoVersions} but this CLI '
            'speaks $kMessageTokenAlgoVersion - scan skipped, update the CLI',
      );
      return null;
    }
    return probe;
  }

  /// Grades the extracted tr() units against the published bundles:
  /// missing (not resolvable at all), untranslated (resolvable but absent in
  /// a target locale), unused (published but never called).
  Future<void> _gradeAgainstBundles(
    DeliveryClient client,
    ManifestProbe probe,
    List<ExtractedUnit> units,
  ) async {
    // Fetched concurrently (they're independent), integrity-checked against
    // their content address like the runtime SDK does.
    final bundles = <String, DeliveryBundle>{};
    final entries = probe.locales.entries.toList();
    final fetched = await Future.wait([
      for (final entry in entries)
        client
            .fetchBundle(entry.value.url, expectedHash: entry.value.bundleHash)
            .then<Object>((b) => b, onError: (Object e) => e),
    ]);
    for (var i = 0; i < entries.length; i++) {
      final result = fetched[i];
      if (result is DeliveryBundle) {
        bundles[entries[i].key] = result;
      } else {
        _checks.warn('delivery', 'delivery', 'bundle ${entries[i].key}: $result - locale skipped');
      }
    }
    if (bundles.isEmpty) {
      _checks.fail('delivery', 'delivery', 'no bundle could be fetched');
      return;
    }
    // The tokenIndex is locale-independent (identity, not translation) - any
    // one bundle carries the full map.
    final tokenIndex = bundles.values.first.tokenIndex;

    final tokenByUnit = <ExtractedUnit, String>{
      for (final u in units)
        if (_tokenOrNull(u) case final String token) u: token,
    };

    // missing: the runtime would fall back to the source string forever.
    final missing = [
      for (final e in tokenByUnit.entries)
        if (!tokenIndex.containsKey(e.value)) e.key,
    ];
    if (missing.isEmpty) {
      _checks.ok('scan', 'scan', 'every tr() string is published');
    } else {
      _checks.warn('scan', 'scan',
        '${missing.length} tr() string(s) not in the published version - '
            "run 'easyi18n push', then publish",
        details: [for (final u in missing)
          '${u.file}:${u.line}  "${ellipsize(u.source)}"'],
      );
    }

    // untranslated: resolvable, but a locale still falls back to the source.
    final usedSlugs = {
      for (final token in tokenByUnit.values)
        if (tokenIndex[token] case final String slug) slug,
    };
    for (final bundle in bundles.values) {
      final absent = usedSlugs.difference(bundle.messages.keys.toSet());
      // The base locale always carries every live key, so it reports zero;
      // only genuine target-locale gaps surface here.
      if (absent.isNotEmpty) {
        _checks.warn('scan', 'scan',
          '${absent.length} of your tr() string(s) untranslated in '
              '${bundle.locale}',
        );
      }
    }

    // unused: published and addressable, but no tr() call references it. Only
    // informational - it may be live on another platform or a dynamic call.
    // Since #1547 the index also carries keys no door minted a token for, so
    // a file-first project reports every catalog entry its code does not call
    // by phrase. That is the honest count for Mode B and the reason this stays
    // a skip: it never moves doctor's exit code.
    final extractedTokens = tokenByUnit.values.toSet();
    final unused = [
      for (final e in tokenIndex.entries)
        if (!extractedTokens.contains(e.key)) e.value,
    ];
    if (unused.isNotEmpty) {
      _checks.skip('scan', 'scan',
        '${unused.length} published key(s) not referenced by any extracted '
            'tr() call (dynamic calls / other platforms?)',
      );
    }
  }

  String? _tokenOrNull(ExtractedUnit unit) {
    try {
      return messageTokenForText(unit.source, ctx: unit.ctx);
    } on ArgumentError {
      return null; // already reported by the ICU/ctx lint
    }
  }

  String? _readText(File file, String check) {
    try {
      return file.readAsStringSync();
    } on FileSystemException catch (e) {
      _checks.unverified(check, file.path, 'Cannot read ${file.path}: ${e.message}');
      return null;
    }
  }

}

enum _Entitlement { granted, denied, missing, unverifiable }
