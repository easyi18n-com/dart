import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/doctor_report.dart' show DoctorFindings;
import 'package:test/test.dart';

/// The file-first adapter (#1409): what `init --stack xcode` writes, what
/// `doctor` reads back, and which of the two adapters claims a tree.
void main() {
  late Directory dir;
  late CliLogger logger;
  late StringBuffer err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xcstrings_adapter');
    err = StringBuffer();
    logger = CliLogger(out: StringBuffer(), err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String at(String relative) => '${dir.path}/$relative';
  String configPath() => at('easyi18n.yaml');

  void writeFile(String relative, String content) =>
      File(at(relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  /// The smallest thing Xcode would call a catalog.
  String catalog({String? base = 'es', Map<String, Object?>? strings}) =>
      jsonEncode({
        'sourceLanguage': ?base,
        'strings': strings ?? const {'Hello': <String, Object?>{}},
        'version': '1.0',
      });

  void xcodeTree({String catalogPath = 'EscapeCall/Localizable.xcstrings',
      String? content}) {
    Directory(at('EscapeCall.xcodeproj')).createSync(recursive: true);
    writeFile(catalogPath, content ?? catalog());
  }

  InitReport init(List<String> _, {String stack = 'xcode', String? catalogFlag,
          String? format, String? mode, bool dryRun = false,
          List<InitStep>? steps}) =>
      InitRunner().run(configPath: configPath(), logger: logger,
          projectId: 'p1', stack: stack, catalog: catalogFlag, format: format,
          mode: mode, dryRun: dryRun, onStep: steps?.add);

  Easyi18nConfig loadConfig() => Easyi18nConfig.load(File(configPath()));

  Future<List<DoctorFinding>> checksOn(Easyi18nConfig config) async {
    final findings = <DoctorFinding>[];
    await const XcstringsAdapter().doctorChecks(root: dir.path,
        sourcePath: 'lib', config: config, findings: DoctorFindings(findings.add));
    return findings;
  }

  Future<List<DoctorFinding>> doctorOver(String yaml) {
    File(configPath()).writeAsStringSync(yaml);
    return checksOn(loadConfig());
  }

  DoctorFinding only(List<DoctorFinding> findings, String check) =>
      findings.singleWhere((f) => f.check == check);

  // ----- detection -----------------------------------------------------------

  group('detection', () {
    test('needs an Xcode project AND a catalog, never one of the two', () {
      const adapter = XcstringsAdapter();
      expect(adapter.detect(dir.path), isFalse, reason: 'empty tree');

      Directory(at('EscapeCall.xcodeproj')).createSync();
      expect(adapter.detect(dir.path), isFalse, reason: 'project, no catalog');

      Directory(at('EscapeCall.xcodeproj')).deleteSync();
      writeFile('EscapeCall/Localizable.xcstrings', catalog());
      expect(adapter.detect(dir.path), isFalse, reason: 'catalog, no project');

      Directory(at('EscapeCall.xcodeproj')).createSync();
      expect(adapter.detect(dir.path), isTrue);
    });

    test('a workspace counts as the project bundle', () {
      Directory(at('EscapeCall.xcworkspace')).createSync();
      writeFile('EscapeCall/Localizable.xcstrings', catalog());
      expect(const XcstringsAdapter().detect(dir.path), isTrue);
    });

    test('InfoPlist.xcstrings alone is not a project to sync', () {
      // Every modern Xcode project ships one; v1 never syncs it (#612).
      Directory(at('EscapeCall.xcodeproj')).createSync();
      writeFile('EscapeCall/InfoPlist.xcstrings', catalog());
      expect(const XcstringsAdapter().detect(dir.path), isFalse);
      expect(XcstringsAdapter.catalogsIn(dir.path), isEmpty);
    });

    test('a Flutter app is never claimed by the Xcode adapter under auto', () {
      // Every Flutter app ships ios/Runner.xcodeproj, and one that syncs a
      // catalog would be claimed by whichever adapter ran first.
      writeFile('pubspec.yaml', 'name: demo\nflutter:\n');
      Directory(at('ios/Runner.xcodeproj')).createSync(recursive: true);
      writeFile('ios/Runner/Localizable.xcstrings', catalog());
      expect(const XcstringsAdapter().detect(dir.path), isFalse,
          reason: 'ios/Runner.xcodeproj is not a root project bundle');
      final report = init([], stack: 'auto');
      expect(report.stack, 'flutter');
      expect(loadConfig().catalog, isNull);
    });

    test('the pick is total and never the filesystem order', () {
      Directory(at('EscapeCall.xcodeproj')).createSync();
      // Written worst-first: a walk that returned `listSync` order would keep
      // this order on one runner and change it on the next.
      writeFile('Watch/Deep/Other.xcstrings', catalog());
      writeFile('Zzz.xcstrings', catalog());
      writeFile('Widget/Localizable.xcstrings', catalog());
      writeFile('Localizable.xcstrings', catalog());
      writeFile('Aaa.xcstrings', catalog());
      expect(XcstringsAdapter.catalogsIn(dir.path), [
        'Localizable.xcstrings',        // canonical name first
        'Widget/Localizable.xcstrings', // canonical, deeper
        'Aaa.xcstrings',                // then shallowest, alphabetical
        'Zzz.xcstrings',
        'Watch/Deep/Other.xcstrings',
      ]);
    });

    test('build products, bundles, hidden dirs and depth 4 are out of scope', () {
      Directory(at('EscapeCall.xcodeproj')).createSync();
      for (final path in [
        'build/Localizable.xcstrings',
        'Pods/Lib/Localizable.xcstrings',
        'DerivedData/Localizable.xcstrings',
        'Carthage/Localizable.xcstrings',
        'node_modules/Localizable.xcstrings',
        '.build/Localizable.xcstrings',
        'EscapeCall.xcodeproj/Localizable.xcstrings',
        'a/b/c/Localizable.xcstrings',
      ]) {
        writeFile(path, catalog());
      }
      expect(XcstringsAdapter.catalogsIn(dir.path), isEmpty);
      writeFile('a/b/Localizable.xcstrings', catalog());
      expect(XcstringsAdapter.catalogsIn(dir.path), ['a/b/Localizable.xcstrings']);
    });
  });

  // ----- init ----------------------------------------------------------------

  group('init', () {
    test('writes catalog + format + Mode A and points at sync', () {
      xcodeTree();
      final steps = <InitStep>[];
      final report = init([], steps: steps);

      expect(report.stack, 'xcode');
      expect(report.family, 'file-first');
      expect(report.next, 'sync');
      final config = loadConfig();
      expect(config.catalog, 'EscapeCall/Localizable.xcstrings');
      expect(config.format, 'xcstrings');
      expect(config.mode, 'a');
      // The written file must survive its own reader: `catalog:` is a comment
      // block away from the keys around it.
      expect(File(configPath()).readAsStringSync(),
          contains('catalog: EscapeCall/Localizable.xcstrings'));
      expect(steps.map((s) => '${s.verb} ${s.target}'), [
        'detected ${at('EscapeCall/Localizable.xcstrings')}',
        'created ${configPath()}',
        'ok ${at('EscapeCall/Localizable.xcstrings')}',
        'patched ${at('.gitignore')}',
        'created ${at('AGENTS.md')}',
      ]);
      expect(File(at('.gitignore')).readAsStringSync(), contains('.easyi18n/'));
      // Nothing code-first: no runtime dependency, no floor, no scope.
      expect(Directory(at('assets')).existsSync(), isFalse);
      expect(File(at('pubspec.yaml')).existsSync(), isFalse);
      expect(report.toJson()['family'], 'file-first');
    });

    test('--catalog outranks detection and is written as given', () {
      xcodeTree();
      writeFile('Widget/Strings.xcstrings', catalog());
      final steps = <InitStep>[];
      init([], catalogFlag: 'Widget/Strings.xcstrings', steps: steps);
      expect(loadConfig().catalog, 'Widget/Strings.xcstrings');
      expect(steps.where((s) => s.verb == 'detected'), hasLength(1),
          reason: 'the detected line still reports what the tree holds');
      expect(only2(steps, 'ok').target, at('Widget/Strings.xcstrings'));
    });

    test('several catalogs name the alternatives instead of choosing silently', () {
      xcodeTree();
      writeFile('Widget/Localizable.xcstrings', catalog());
      final steps = <InitStep>[];
      init([], steps: steps);
      expect(loadConfig().catalog, 'EscapeCall/Localizable.xcstrings');
      expect(steps.first.detail, contains('1 other(s) found'));
    });

    test('no catalog still writes a usable config and says what is missing', () async {
      Directory(at('EscapeCall.xcodeproj')).createSync();
      final steps = <InitStep>[];
      final report = init([], steps: steps);
      expect(loadConfig().catalog, isNull);
      expect(loadConfig().format, 'xcstrings');
      expect(File(configPath()).readAsStringSync(), isNot(contains('catalog:')));
      expect(steps.first.verb, 'skipped');
      expect(steps.first.detail, contains('--catalog'));
      expect(report.next, 'sync');
      // and doctor is the one that turns that into a failure
      expect(only(await checksOn(loadConfig()), 'catalog').level, 'fail');
    });

    test('--mode b is refused in place, not written', () {
      xcodeTree();
      final steps = <InitStep>[];
      init([], mode: 'b', steps: steps);
      expect(loadConfig().mode, 'a');
      expect(steps.first.detail, contains('ignoring --mode b'));
    });

    test('an explicit --format still wins over the stack default', () async {
      xcodeTree();
      init([], format: 'arb');
      expect(loadConfig().format, 'arb');
      // Which doctor then reports, because `catalog:` cannot hold an arb render.
      expect(only(await checksOn(loadConfig()), 'format').level, 'fail');
    });

    test('a second run keeps the config and re-detects nothing', () {
      xcodeTree();
      init([]);
      final before = File(configPath()).readAsBytesSync();
      final steps = <InitStep>[];
      final report = init([], steps: steps);
      expect(File(configPath()).readAsBytesSync(), before);
      expect(steps.map((s) => s.verb), ['ok', 'ok', 'ok', 'ok']);
      expect(steps.first.detail, 'kept existing config');
      expect(report.next, 'sync');
    });

    test('a configured catalog that is gone is reported on the re-run', () {
      xcodeTree();
      init([]);
      File(at('EscapeCall/Localizable.xcstrings')).deleteSync();
      final steps = <InitStep>[];
      init([], steps: steps);
      expect(steps[1].verb, 'skipped');
      expect(steps[1].detail, contains('.xcstrings'));
    });

    test('dry run writes neither the config nor the ignore', () {
      xcodeTree();
      final steps = <InitStep>[];
      init([], dryRun: true, steps: steps);
      expect(File(configPath()).existsSync(), isFalse);
      expect(File(at('.gitignore')).existsSync(), isFalse);
      expect(steps.map((s) => s.verb),
          ['detected', 'created', 'ok', 'patched', 'created']);
      expect(File(at('AGENTS.md')).existsSync(), isFalse);
    });

    test('through the real command, the stack format reaches the file', () async {
      // The runner tests above pass `format: null` directly, which is not what
      // the CLI does: `--format` carries `defaultsTo: 'arb'`, so only
      // `wasParsed` tells "the user chose arb" from "nobody said anything".
      // Without this scenario that distinction is untested — the transcript
      // golden cannot see it either, because the written config is not printed.
      xcodeTree();
      final out = StringBuffer();
      final cli = Easyi18nCommandRunner(
          output: CliOutput(out: out, err: StringBuffer()));
      Future<int?> init(List<String> flags) =>
          cli.run(['--json', '--config', configPath(), 'init', '--stack',
                   'xcode', '--project-id', 'p1', ...flags]);

      expect(await init([]), 0);
      expect(loadConfig().format, 'xcstrings');
      expect(loadConfig().catalog, 'EscapeCall/Localizable.xcstrings');
      expect(jsonDecode(out.toString())['next'], 'sync');

      expect(await init(['--force', '--format', 'arb']), 0);
      expect(loadConfig().format, 'arb');
    });

    test('through the real command, no Flutter directory reaches the file',
        () async {
      // Same reason as above: `--output` carries `defaultsTo: 'lib/l10n'`, so
      // the command always hands the runner a value. The file-first config
      // came out naming a directory an Xcode project does not have (#1858).
      xcodeTree();
      Future<int?> init(List<String> flags) => Easyi18nCommandRunner(
              output: CliOutput(out: StringBuffer(), err: StringBuffer()))
          .run(['--json', '--config', configPath(), 'init', '--stack', 'xcode',
                '--project-id', 'p1', ...flags]);
      String written() => File(configPath()).readAsStringSync();

      expect(await init([]), 0);
      expect(written(), isNot(contains('output:')));
      expect(written(), isNot(contains('l10n')));
      expect(loadConfig().catalog, 'EscapeCall/Localizable.xcstrings');

      expect(await init(['--force', '--output', 'Resources']), 0);
      expect(written(), contains('\noutput: Resources\n'));
      expect(written(), isNot(contains('l10n')));
    });

    test('a path only the filesystem approves survives the round trip', () async {
      // Through the real command, because the value the serializer receives is
      // one `init` DISCOVERED. The special name goes INSIDE the config root on
      // purpose: above it, the serialized path is a plain `Sources/…` and the
      // scenario proves nothing. `App #1/…` used to reload as `App` (a path
      // that does not exist) with init reporting success, `App: Demo/…` made
      // the config unreadable, and a real line feed folded into a space.
      var caseIndex = 0;
      for (final name in const [
        'App #1', 'App: Demo', "Bob's App", 'App\nDemo', 'App "Demo"',
      ]) {
        final root = Directory('${dir.path}/case${caseIndex++}')..createSync();
        Directory('${root.path}/App.xcodeproj').createSync();
        File('${root.path}/$name/Localizable.xcstrings')
          ..createSync(recursive: true)
          ..writeAsStringSync(catalog());
        final config = '${root.path}/easyi18n.yaml';
        Future<int?> run(List<String> flags) => Easyi18nCommandRunner(
                output: CliOutput(out: StringBuffer(), err: StringBuffer()))
            .run(['--json', '--config', config, 'init', '--stack', 'xcode',
                  '--project-id', 'p1', ...flags]);

        expect(await run([]), 0, reason: name);
        var loaded = Easyi18nConfig.load(File(config));
        expect(loaded.catalog, '$name/Localizable.xcstrings', reason: name);
        expect(File('${root.path}/${loaded.catalog}').existsSync(), isTrue,
            reason: 'the reloaded path must still name the file init found');

        final other = '$name/Other #2.xcstrings';
        File('${root.path}/$other').createSync(recursive: true);
        expect(await run(['--force', '--catalog', other]), 0, reason: name);
        loaded = Easyi18nConfig.load(File(config));
        expect(loaded.catalog, other, reason: name);
        expect(File('${root.path}/${loaded.catalog}').existsSync(), isTrue);
      }
    });

    test('the Flutter init is untouched by the new default', () {
      writeFile('pubspec.yaml', 'name: demo\nflutter:\n');
      final report = init([], stack: 'flutter');
      final config = loadConfig();
      expect(report.stack, 'flutter');
      expect(config.catalog, isNull);
      expect(config.format, 'arb');
      expect(config.mode, 'b');
      expect(report.next, 'push');
    });
  });

  // ----- doctor --------------------------------------------------------------

  group('doctor checks', () {
    test('a healthy catalog reports its shape, format, mode and project', () async {
      Directory(at('EscapeCall.xcodeproj')).createSync();
      File(at('EscapeCall/Localizable.xcstrings'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
            File('test/fixtures/xcode_canonical.xcstrings').readAsStringSync());
      final findings = await doctorOver('projectId: p1\nmode: a\nformat: xcstrings\n'
          'catalog: EscapeCall/Localizable.xcstrings\n');

      expect(findings.map((f) => f.check), ['catalog', 'format', 'mode', 'xcode']);
      expect(findings.every((f) => f.level == 'ok'), isTrue,
          reason: findings.map((f) => '${f.level} ${f.message}').join('\n'));
      expect(only(findings, 'catalog').message, contains('1 locale(s): en'));
      expect(only(findings, 'catalog').message, matches(RegExp(r'^\d+ entry')));
      expect(only(findings, 'xcode').subject, at('EscapeCall.xcodeproj'));
    });

    test('no catalog configured fails and lists what the tree holds', () async {
      xcodeTree();
      final finding = only(await doctorOver('projectId: p1\nformat: xcstrings\n'), 'catalog');
      expect(finding.level, 'fail');
      expect(finding.message, contains('no `catalog:`'));
      expect(finding.details, ['found EscapeCall/Localizable.xcstrings']);
    });

    test('a catalog path that resolves to nothing fails', () async {
      final finding = only(
          await doctorOver('projectId: p1\nformat: xcstrings\ncatalog: gone.xcstrings\n'),
          'catalog');
      expect(finding.level, 'fail');
      expect(finding.subject, at('gone.xcstrings'));
      expect(finding.message, contains('not there'));
    });

    test('unreadable bytes are never reported as an empty catalog', () async {
      File(at('Localizable.xcstrings')).writeAsBytesSync([0xff, 0xfe]);
      final finding = only(
          await doctorOver('projectId: p1\nformat: xcstrings\n'
              'catalog: Localizable.xcstrings\n'),
          'catalog');
      expect(finding.level, 'unverified');
      expect(finding.message, startsWith('Cannot read '));
    });

    test('a file that is not a catalog fails, and does so distinctly', () async {
      writeFile('Localizable.xcstrings', '{"strings": "nope"}');
      final finding = only(
          await doctorOver('projectId: p1\nformat: xcstrings\n'
              'catalog: Localizable.xcstrings\n'),
          'catalog');
      expect(finding.level, 'fail');
      expect(finding.message, contains('not a readable .xcstrings catalog'));
    });

    test('an empty catalog warns; one that opts every entry out does not', () async {
      writeFile('Localizable.xcstrings', catalog(strings: const {}));
      var findings = await doctorOver('projectId: p1\nformat: xcstrings\n'
          'catalog: Localizable.xcstrings\n');
      expect(findings.where((f) => f.check == 'catalog').map((f) => f.level),
          ['ok', 'warn']);
      expect(findings[1].message, contains('no entries'));

      writeFile('Localizable.xcstrings', catalog(strings: const {
        'NSCameraUsageDescription': {'shouldTranslate': false},
      }));
      findings = await doctorOver('projectId: p1\nformat: xcstrings\n'
          'catalog: Localizable.xcstrings\n');
      // `skip`, not `warn`: a dev-only catalog is an ordinary file (#612) and
      // this must not be the line that fails a CI doctor.
      expect(findings.where((f) => f.check == 'catalog').map((f) => f.level),
          ['ok', 'skip']);
      expect(findings.any((f) => f.level == 'fail'), isFalse);
    });

    for (final base in [null, '']) {
      test('a catalog whose sourceLanguage is ${base ?? 'absent'} warns without '
          'failing', () async {
        writeFile('Localizable.xcstrings', catalog(base: base));
        final findings = await doctorOver('projectId: p1\nformat: xcstrings\n'
            'catalog: Localizable.xcstrings\n');
        expect(findings.where((f) => f.check == 'catalog').map((f) => f.level),
            ['ok', 'warn']);
        expect(findings[1].message, contains('sourceLanguage'));
      });
    }

    test('a per-locale format under a catalog is a failure, not a warning', () async {
      writeFile('Localizable.xcstrings', catalog());
      final finding = only(
          await doctorOver('projectId: p1\nformat: arb\ncatalog: Localizable.xcstrings\n'),
          'format');
      expect(finding.level, 'fail');
      expect(finding.message, contains('one file per locale'));
    });

    test('Mode B on a file-first project warns that grading goes dark', () async {
      writeFile('Localizable.xcstrings', catalog());
      final finding = only(
          await doctorOver('projectId: p1\nformat: xcstrings\nmode: b\n'
              'catalog: Localizable.xcstrings\n'),
          'mode');
      expect(finding.level, 'warn');
      expect(finding.message, contains('not graded'));
    });

    test('a checkout without the project bundle is a skip, not a failure', () async {
      writeFile('Localizable.xcstrings', catalog());
      final finding = only(
          await doctorOver('projectId: p1\nformat: xcstrings\n'
              'catalog: Localizable.xcstrings\n'),
          'xcode');
      expect(finding.level, 'skip');
      expect(finding.subject, dir.path);
    });
  });

  // ----- which adapter grades ------------------------------------------------

  group('doctor picks the adapter', () {
    Future<DoctorReport> doctor() => DoctorRunner().run(
        configPath: configPath(), logger: logger, environment: const {});

    test('an Xcode tree is graded by the file-first adapter', () async {
      xcodeTree();
      File(configPath()).writeAsStringSync('projectId: p1\nmode: b\n'
          'format: xcstrings\ncatalog: EscapeCall/Localizable.xcstrings\n');
      final report = await doctor();
      expect(report.stack, 'xcode');
      expect(report.family, 'file-first');
      expect(report.findings.map((f) => f.check),
          ['config', 'credential', 'agents_md', 'catalog', 'format', 'mode',
           'xcode']);
    });

    test('a catalog config with no project bundle still grades file-first',
        () async {
      // The CI checkout, and the one nothing on disk can detect.
      writeFile('Localizable.xcstrings', catalog());
      File(configPath()).writeAsStringSync(
          'projectId: p1\nmode: a\nformat: xcstrings\ncatalog: Localizable.xcstrings\n');
      final report = await doctor();
      expect(report.stack, 'xcode');
      expect(report.findings.map((f) => f.check),
          ['config', 'credential', 'agents_md', 'catalog', 'format', 'mode',
           'xcode', 'completeness']);
    });

    test('init without a catalog still gets its catalog checks', () async {
      // The composition, not the pieces: `init --stack xcode` over a tree with
      // no catalog writes `format: xcstrings` and NO `catalog:`, and that is
      // exactly the project that needs the diagnosis. Detection fails (no
      // catalog on disk) and a fallback keyed on `catalog:` failed too, so
      // doctor graded it as Flutter and said nothing about the missing setting.
      Directory(at('EscapeCall.xcodeproj')).createSync();
      expect(
          await Easyi18nCommandRunner(
                  output: CliOutput(out: StringBuffer(), err: StringBuffer()))
              .run(['--json', '--config', configPath(), 'init', '--stack',
                    'xcode', '--project-id', 'p1']),
          0);
      expect(loadConfig().catalog, isNull);

      final report = await doctor();
      expect(report.stack, 'xcode');
      expect(report.findings.map((f) => f.check),
          containsAll(['catalog', 'format', 'xcode']));
      final catalogFinding =
          report.findings.firstWhere((f) => f.check == 'catalog');
      expect(catalogFinding.level, 'fail');
      expect(report.exitCode, 1);
    });

    test('a Flutter project that also syncs a catalog stays code-first',
        () async {
      writeFile('pubspec.yaml', 'name: demo\nflutter:\n');
      writeFile('Localizable.xcstrings', catalog());
      File(configPath()).writeAsStringSync(
          'projectId: p1\nmode: b\nformat: xcstrings\ncatalog: Localizable.xcstrings\n');
      final report = await doctor();
      expect(report.stack, 'flutter');
      expect(report.findings.map((f) => f.check), contains('pubspec'));
    });

    test('a tree no adapter claims keeps the historical checks', () async {
      writeFile('pubspec.yaml', 'name: plain_dart\n');
      File(configPath()).writeAsStringSync('projectId: p1\n');
      final report = await doctor();
      expect(report.stack, 'flutter');
      expect(report.findings.map((f) => f.check), contains('pubspec'));
      expect(err.toString(), isEmpty);
    });
  });

  test('a re-run reports every catalog of a `catalogs:` config (#590)', () {
    xcodeTree();
    writeFile('EscapeCall/Shortcuts.xcstrings', catalog());
    File(configPath()).writeAsStringSync('projectId: p1\nmode: a\nformat: xcstrings\n'
        'catalogs:\n  - EscapeCall/Localizable.xcstrings\n  - EscapeCall/Shortcuts.xcstrings\n'
        '  - EscapeCall/Gone.xcstrings\n');
    final steps = <InitStep>[];
    init(const [], steps: steps);
    expect([for (final s in steps) if (s.detail == 'catalog to sync') s.target], [
      at('EscapeCall/Localizable.xcstrings'),
      at('EscapeCall/Shortcuts.xcstrings'),
    ]);
    expect([for (final s in steps) if (s.verb == 'skipped' && s.detail.startsWith('catalog not found')) s.target],
        [at('EscapeCall/Gone.xcstrings')]);
  });

  group('doctor checks on `catalogs:` (#590)', () {
    const config = 'projectId: p1\nformat: xcstrings\ncatalogs:\n'
        '  - App/Localizable.xcstrings\n  - App/Shortcuts.xcstrings\n';

    Map<String, Object?> entries(List<String> keys) =>
        {for (final k in keys) k: <String, Object?>{}};

    test('grades every file of the list', () async {
      writeFile('App/Localizable.xcstrings', catalog(strings: entries(['a'])));
      writeFile('App/Shortcuts.xcstrings', catalog(strings: entries(['b'])));
      final findings = await doctorOver(config);
      expect(findings.where((f) => f.check == 'catalog').map((f) => f.subject),
          [at('App/Localizable.xcstrings'), at('App/Shortcuts.xcstrings')]);
      expect(findings.any((f) => f.level == 'fail'), isFalse);
    });

    test('a missing file of the list fails by its path', () async {
      writeFile('App/Localizable.xcstrings', catalog(strings: entries(['a'])));
      final fails = (await doctorOver(config)).where((f) => f.level == 'fail');
      expect(fails.map((f) => f.subject), [at('App/Shortcuts.xcstrings')]);
    });

    test('a key two files hold fails, naming the key and both files', () async {
      writeFile('App/Localizable.xcstrings', catalog(strings: entries(['a', 'dup'])));
      writeFile('App/Shortcuts.xcstrings', catalog(strings: entries(['dup'])));
      final fail = (await doctorOver(config)).singleWhere((f) => f.level == 'fail');
      expect(fail.message, allOf(contains('`dup`'),
          contains('Localizable.xcstrings'), contains('Shortcuts.xcstrings')));
    });

    test('files with different base languages fail', () async {
      writeFile('App/Localizable.xcstrings', catalog(base: 'en', strings: entries(['a'])));
      writeFile('App/Shortcuts.xcstrings', catalog(base: 'es', strings: entries(['b'])));
      final fail = (await doctorOver(config)).singleWhere((f) => f.level == 'fail');
      expect(fail.message, contains('Shortcuts.xcstrings'));
    });
  });
}

InitStep only2(List<InitStep> steps, String verb) =>
    steps.singleWhere((s) => s.verb == verb);
