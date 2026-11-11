import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapters.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/doctor_report.dart' show DoctorFindings;
import 'package:test/test.dart';

/// The Android file-first adapter (#2285): which trees it claims, what `init`
/// writes and what `doctor` reads back.
void main() {
  late Directory dir;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('android_adapter');
    logger = CliLogger(out: StringBuffer(), err: StringBuffer());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String at(String relative) => '${dir.path}/$relative';
  String configPath() => at('easyi18n.yaml');

  void writeFile(String relative, String content) =>
      File(at(relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  const base = '''
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
    <string name="app_name" translatable="false">Demo Shop</string>
    <string name="greeting">Hello, %1\$s! Don\\'t miss today\\'s deals.</string>
    <!-- <string name="commented_out">Never counted</string> -->
    <string name="cart_status">You have <xliff:g id="count" example="3">%1\$d</xliff:g> items in your cart</string>
    <string-array name="sizes"><item>S</item></string-array>
    <plurals name="item_count">
        <item quantity="one">%1\$d item</item>
        <item quantity="other">%1\$d items</item>
    </plurals>
</resources>
''';

  void androidTree() {
    writeFile('settings.gradle', "include ':app'\n");
    writeFile('app/src/main/AndroidManifest.xml', '<manifest/>\n');
    writeFile('app/src/main/res/values/strings.xml', base);
    writeFile('app/src/main/res/values-es/strings.xml',
        '<resources><string name="greeting">Hola</string></resources>\n');
  }

  InitReport init({String stack = 'auto', bool dryRun = false,
          String? mode}) =>
      InitRunner().run(configPath: configPath(), logger: logger,
          projectId: 'p1', stack: stack, dryRun: dryRun, mode: mode);

  Easyi18nConfig loadConfig() => Easyi18nConfig.load(File(configPath()));

  Future<List<DoctorFinding>> checksOn(Easyi18nConfig config) async {
    final findings = <DoctorFinding>[];
    await const AndroidAdapter().doctorChecks(root: dir.path,
        sourcePath: 'lib', config: config, findings: DoctorFindings(findings.add));
    return findings;
  }

  DoctorFinding only(List<DoctorFinding> findings, String check) =>
      findings.singleWhere((f) => f.check == check);

  group('detection', () {
    test('auto picks android over a Gradle tree with values/strings.xml', () {
      androidTree();
      expect(selectStackAdapter(dir.path, stack: 'auto').stack, 'android');
      expect(selectStackAdapter(dir.path, stack: 'android').family, 'file-first');
    });

    test('needs a Gradle or manifest marker AND a values/strings.xml', () {
      const adapter = AndroidAdapter();
      expect(adapter.detect(dir.path), isFalse, reason: 'empty tree');
      writeFile('settings.gradle', "include ':app'\n");
      expect(adapter.detect(dir.path), isFalse, reason: 'Gradle, no resources');
      File(at('settings.gradle')).deleteSync();
      writeFile('app/src/main/res/values/strings.xml', base);
      expect(adapter.detect(dir.path), isFalse, reason: 'resources, no marker');
      writeFile('app/src/main/AndroidManifest.xml', '<manifest/>\n');
      expect(adapter.detect(dir.path), isTrue, reason: 'manifest beside res/');
      File(at('app/src/main/AndroidManifest.xml')).deleteSync();
      writeFile('build.gradle.kts', '\n');
      expect(adapter.detect(dir.path), isTrue, reason: 'root Gradle script');
    });

    test('a Flutter app with android/ inside still answers flutter', () {
      writeFile('pubspec.yaml', 'name: demo\nflutter:\n');
      writeFile('android/settings.gradle', "include ':app'\n");
      writeFile('android/app/src/main/AndroidManifest.xml', '<manifest/>\n');
      writeFile('android/app/src/main/res/values/strings.xml', base);
      expect(const AndroidAdapter().detect(dir.path), isTrue,
          reason: 'the tree is Android too; the order of the adapters decides');
      expect(selectStackAdapter(dir.path, stack: 'auto').stack, 'flutter');
    });

    test('build outputs and hidden dirs hold copies, never the source', () {
      writeFile('settings.gradle', "include ':app'\n");
      writeFile('app/build/intermediates/res/values/strings.xml', base);
      writeFile('.gradle/res/values/strings.xml', base);
      writeFile('node_modules/x/res/values/strings.xml', base);
      expect(AndroidAdapter.sourcesIn(dir.path), isEmpty);
    });

    test('the main source set comes first, then shallowest, then by path', () {
      writeFile('settings.gradle', "include ':app', ':lib'\n");
      // Written worst-first: a walk in listSync order would keep this order.
      writeFile('lib/src/main/res/values/strings.xml', base);
      writeFile('app/src/debug/res/values/strings.xml', base);
      writeFile('res/values/strings.xml', base);
      writeFile('app/src/main/res/values/strings.xml', base);
      expect(AndroidAdapter.sourcesIn(dir.path), [
        'app/src/main/res/values/strings.xml',
        'lib/src/main/res/values/strings.xml',
        'res/values/strings.xml',
        'app/src/debug/res/values/strings.xml',
      ]);
    });

    test('a tree with no stack is refused naming android as supported', () {
      expect(() => selectStackAdapter(dir.path, stack: 'auto'),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'unsupported_stack')
              .having((e) => e.message, 'message',
                  allOf(contains('Supported: flutter, xcode, web, android, angular;'),
                      isNot(contains('Android'))))));
    });
  });

  /// The `android/` a React Native or Capacitor app commits: Gradle, the
  /// manifest and the template `strings.xml`.
  void committedAndroidProject() {
    writeFile('android/settings.gradle', "include ':app'\n");
    writeFile('android/app/build.gradle', "apply plugin: 'com.android.application'\n");
    writeFile('android/app/src/main/AndroidManifest.xml', '<manifest/>\n');
    writeFile('android/app/src/main/res/values/strings.xml',
        '<resources><string name="app_name">Demo Shop</string></resources>\n');
  }

  Future<DoctorReport> doctor() => DoctorRunner()
      .run(configPath: configPath(), logger: logger, environment: {});

  group('a web app that commits its android/ project (#2311)', () {
    final hybrids = {
      'React Native with i18next': (
        dependencies: {'react-native': '^0.80.0', 'i18next': '^25.0.0',
            'react-i18next': '^15.0.0'},
        library: 'i18next',
        source: 'locales/en.json',
      ),
      'Capacitor with ngx-translate': (
        dependencies: {'@capacitor/android': '^7.0.0',
            '@ngx-translate/core': '^17.0.0'},
        library: '@ngx-translate/core',
        source: 'src/assets/i18n/en.json',
      ),
    };

    for (final MapEntry(key: name, value: app) in hybrids.entries) {
      void hybridTree() {
        writeFile('package.json', jsonEncode({'dependencies': app.dependencies}));
        writeFile(app.source, '{"title": "Demo Shop"}\n');
        committedAndroidProject();
      }

      test('$name: auto detects web by its package.json', () {
        hybridTree();
        final report = init();
        expect(report.stack, 'web');
        final detected = report.steps.first;
        expect((detected.verb, detected.target), ('detected', at('package.json')));
        expect(detected.detail, contains(app.library));
        expect(loadConfig().format, 'json');
        expect(loadConfig().source, app.source);
      });

      test('$name: doctor grades the web config with the web checks', () async {
        hybridTree();
        init(stack: 'web');
        final report = await doctor();
        expect(report.stack, 'web');
        expect(only(report.findings, 'source').message, '1 key(s)');
        expect(report.findings.map((f) => f.message),
            everyElement(isNot(contains('android_xml'))));
      });

      test('$name: a config that chose android_xml still grades as android',
          () async {
        hybridTree();
        init(stack: 'android');
        expect(loadConfig().format, 'android_xml');
        final report = await doctor();
        expect(report.stack, 'android');
        expect(only(report.findings, 'source').message,
            startsWith('android_xml, 1 translatable key(s)'));
      });
    }

    test('the android_xml exception is for web: Flutter keeps detection first',
        () {
      writeFile('pubspec.yaml', 'name: demo\nflutter:\n');
      committedAndroidProject();
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: android_xml\nmode: a\n'
          'source: android/app/src/main/res/values/strings.xml\n'
          'output: android/app/src/main/res\n');
      expect(adapterFor(dir.path, loadConfig()).stack, 'flutter');
    });

    // A gen_l10n template under `source:` (#2343) is no web base file.
    test('an undetected tree with an ARB source: grades as Flutter', () {
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: arb\nmode: a\n'
          'source: lib/l10n/app_en.arb\noutput: lib/l10n\n');
      expect(adapterFor(dir.path, loadConfig()).stack, 'flutter');
    });

    test('a tooling package.json leaves a native Android tree android', () {
      writeFile('package.json',
          jsonEncode({'devDependencies': {'prettier': '^3.0.0'}}));
      committedAndroidProject();
      expect(selectStackAdapter(dir.path, stack: 'auto').stack, 'android');
    });
  });

  group('init', () {
    test('writes android_xml, the base file and its res/ in Mode A', () {
      androidTree();
      final report = init(mode: 'b');
      expect(report.stack, 'android');
      expect(report.family, 'file-first');
      expect(report.next, 'sync');
      final config = loadConfig();
      expect(config.format, 'android_xml');
      expect(config.source, 'app/src/main/res/values/strings.xml');
      expect(config.output, 'app/src/main/res');
      expect(config.catalog, isNull);
      expect(config.mode, 'a');
      expect(File(at('AGENTS.md')).readAsStringSync(),
          contains('`app/src/main/res/values/strings.xml` is the truth'));
    });

    test('several modules: the pick is named with the count of the others', () {
      androidTree();
      writeFile('lib/src/main/res/values/strings.xml', base);
      final steps = <InitStep>[];
      InitRunner().run(configPath: configPath(), logger: logger,
          projectId: 'p1', stack: 'android', onStep: steps.add);
      expect(steps.where((s) => s.verb == 'detected').single.detail,
          contains('1 other(s) found'));
    });

    test('a dry run plans the same config and writes nothing', () {
      androidTree();
      final report = init(stack: 'android', dryRun: true);
      expect(report.stack, 'android');
      expect(report.steps.map((s) => (s.verb, s.target)), contains(
          ('detected', at('app/src/main/res/values/strings.xml'))));
      expect(File(configPath()).existsSync(), isFalse);
    });

    test('with no base file found, init says what to set', () {
      writeFile('settings.gradle', "include ':app'\n");
      final steps = <InitStep>[];
      InitRunner().run(configPath: configPath(), logger: logger,
          projectId: 'p1', stack: 'android', onStep: steps.add);
      expect(loadConfig().format, 'android_xml');
      expect(loadConfig().source, isNull);
      expect(steps.any((s) => s.verb == 'skipped' && s.target == 'source'),
          isTrue);
    });
  });

  group('doctor', () {
    test('counts the translatable keys of the source and the locales', () async {
      androidTree();
      writeFile('app/src/main/res/values-night/strings.xml', '<resources/>\n');
      writeFile('app/src/main/res/values-b+zh+Hant/strings.xml', '<resources/>\n');
      init();
      final findings = await checksOn(loadConfig());
      final source = only(findings, 'source');
      expect(source.level, 'ok');
      expect(source.message,
          'android_xml, 3 translatable key(s); 2 locale file(s): es, zh-Hant');
      expect(only(findings, 'format').level, 'ok');
      expect(only(findings, 'mode').level, 'ok');
      expect(only(findings, 'gradle').level, 'ok');
    });

    test('a missing source, the wrong format and Mode B are named', () async {
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: arb\nmode: b\n'
          'source: app/src/main/res/values/strings.xml\n'
          'output: app/src/main/res\n');
      final findings = await checksOn(loadConfig());
      expect(only(findings, 'source').level, 'fail');
      expect(only(findings, 'format').level, 'fail');
      expect(only(findings, 'mode').level, 'warn');
      expect(only(findings, 'gradle').level, 'skip');
    });

    test('a file with no <resources> root is not an Android resources file',
        () async {
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: android_xml\nmode: a\n'
          'source: res/values/strings.xml\noutput: res\n');
      writeFile('res/values/strings.xml', '{"greeting": "Hello"}\n');
      final findings = await checksOn(loadConfig());
      expect(only(findings, 'source').level, 'fail');
    });

    test('a resources file whose every string is opted out is a warning',
        () async {
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: android_xml\nmode: a\n'
          'source: res/values/strings.xml\noutput: res\n');
      writeFile('res/values/strings.xml', '<resources>\n'
          '<string name="app_name" translatable="false">Demo</string>\n'
          '</resources>\n');
      final findings = await checksOn(loadConfig());
      expect(only(findings, 'source').level, 'warn');
    });

    test('no source: in the config fails naming init', () async {
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: android_xml\nmode: a\n');
      final findings = await checksOn(loadConfig());
      expect(only(findings, 'source').level, 'fail');
      expect(only(findings, 'source').message, contains('init --stack android'));
    });

    test('doctor grades a config-only checkout as android by its format', () {
      writeFile('easyi18n.yaml', 'projectId: p1\nformat: android_xml\nmode: a\n'
          'source: res/values/strings.xml\noutput: res\n');
      expect(adapterFor(dir.path, loadConfig()).stack, 'android');
    });
  });

  test('a values-* directory names the locale the server renders into it', () {
    for (final (name, locale) in [
      ('values-pt-rBR', 'pt-BR'),
      ('values-mcc310-mnc004-fr-rCA', 'fr-CA'),
      ('values-b+es+', null),
    ]) {
      expect(AndroidAdapter.localeOfValuesDir(name), locale, reason: name);
    }
  });
}
