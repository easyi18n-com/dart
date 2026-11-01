import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:easyi18n_cli/src/scaffold.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_init');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CommandRunner<int> runner({String? Function(String)? prompt}) {
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    r.addCommand(InitCommand(output: CliOutput(logger: logger), prompt: prompt ?? (_) => null));
    return r;
  }

  String configPath() => '${dir.path}/easyi18n.yaml';
  File fileAt(String relative) => File('${dir.path}/$relative');

  /// A minimal Flutter app fixture: pubspec, trivial main, both macOS
  /// entitlements (sandbox only — the state `flutter create` leaves them in).
  void writeFlutterFixture() {
    fileAt('pubspec.yaml').writeAsStringSync('''
name: demo_app

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter

flutter:
  uses-material-design: true
''');
    fileAt('lib/main.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp();
}
''');
    for (final name in ['DebugProfile.entitlements', 'Release.entitlements']) {
      fileAt('macos/Runner/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''');
    }
  }

  Future<int?> runInit(List<String> extra) =>
      runner().run(['--config', configPath(), 'init', ...extra]);

  group('full scaffold', () {
    test('sets up a clean Flutter fixture end to end', () async {
      writeFlutterFixture();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);

      // Config.
      expect(
        Easyi18nConfig.load(File(configPath())).ref,
        const IdRef('proj_abc'),
      );

      // Pubspec: dependency + assets floor, still valid YAML.
      final pubspec = fileAt('pubspec.yaml').readAsStringSync();
      final doc = loadYaml(pubspec) as Map;
      expect((doc['dependencies'] as Map).containsKey('easyi18n'), isTrue);
      expect((doc['flutter'] as Map)['assets'], contains(kAssetsFloorDir));

      // Floor dir.
      expect(fileAt('assets/easyi18n/.gitkeep').existsSync(), isTrue);

      // Gitignore.
      expect(
        fileAt('.gitignore').readAsStringSync(),
        contains(kStateIgnoreEntry),
      );

      // Both entitlements.
      for (final name in [
        'DebugProfile.entitlements',
        'Release.entitlements',
      ]) {
        expect(
          fileAt('macos/Runner/$name').readAsStringSync(),
          contains('<key>$kNetworkClientKey</key>'),
          reason: name,
        );
      }

      // Scope wiring.
      final main = fileAt('lib/main.dart').readAsStringSync();
      expect(main, contains('Easyi18nScope('));
      expect(main, contains("projectId: 'proj_abc'"));
      expect(main, contains("import 'package:easyi18n/easyi18n.dart';"));
    });

    test('wires the app so the published locales can show', () async {
      writeFlutterFixture();
      final code = await runInit([
        '--project-id', 'proj_abc', '--base-url', 'http://localhost:8080',
      ]);
      expect(code, 0);

      final main = fileAt('lib/main.dart').readAsStringSync();
      // The scope reads the backend easyi18n.yaml names, and polls it so a
      // publish lands in the running app.
      expect(main, contains("baseUrl: Uri.parse('http://localhost:8080')"));
      expect(main, contains('refreshInterval: const Duration(seconds: 10)'));
      // Both are development values, and the generated file says so on the
      // line above each.
      expect(main, matches(RegExp(r'// Development value:[^\n]*\n +baseUrl:')));
      expect(main,
          matches(RegExp(r'// Development value:[^\n]*\n +refreshInterval:')));
      // MaterialApp resolves the device locale against what the project
      // publishes; without these two lines it resolves en_US forever.
      expect(main, contains(
          'localizationsDelegates: GlobalMaterialLocalizations.delegates'));
      expect(main, contains(
          'supportedLocales: Easyi18nScope.localesOf(context)'));
      expect(main, isNot(contains('const MaterialApp(')));
      expect(main, contains(
          "import 'package:flutter_localizations/flutter_localizations.dart';"));
      final doc = loadYaml(fileAt('pubspec.yaml').readAsStringSync()) as Map;
      expect((doc['dependencies'] as Map)['flutter_localizations'],
          {'sdk': 'flutter'});
      expect(out.toString(), contains('wired MaterialApp locales'));
    });

    test('raises the ^0.1.x pin an rc.2 init left, and says so', () async {
      writeFlutterFixture();
      final pubspec = fileAt('pubspec.yaml').readAsStringSync();
      fileAt('pubspec.yaml').writeAsStringSync(
          pubspec.replaceFirst('dependencies:', 'dependencies:\n  easyi18n: ^0.1.0'));
      expect(await runInit(['--project-id', 'proj_abc']), 0);
      expect(out.toString(), contains('raised easyi18n ^0.1.0 to ^0.2.0'));
      final doc = loadYaml(fileAt('pubspec.yaml').readAsStringSync()) as Map;
      expect((doc['dependencies'] as Map)['easyi18n'], '^0.2.0');
    });

    test('a main.dart whose runApp bails still gets its locales wired',
        () async {
      writeFlutterFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';

void main() {
  if (const bool.fromEnvironment('X')) runApp(const Other());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(home: const Text('x'));
}
''');
      expect(await runInit(['--project-id', 'proj_abc']), 0);
      expect(out.toString(), contains('no single runApp(...) call site'));
      expect(out.toString(), contains('wired MaterialApp locales'));
      expect(out.toString(), matches(
          RegExp(r'// Development value:[^\n]*\n +refreshInterval:')));
      final main = fileAt('lib/main.dart').readAsStringSync();
      expect(main, isNot(contains('Easyi18nScope(')));
      expect(main, contains('supportedLocales: Easyi18nScope.localesOf(context)'));
    });

    test('a production baseUrl writes no origin into main.dart', () async {
      writeFlutterFixture();
      expect(await runInit(['--project-id', 'proj_abc']), 0);
      final main = fileAt('lib/main.dart').readAsStringSync();
      expect(main, isNot(contains('baseUrl:')));
      expect(main, contains('refreshInterval:'));
      expect('// Development value:'.allMatches(main), hasLength(1));
      expect(main,
          matches(RegExp(r'// Development value:[^\n]*\n +refreshInterval:')));
    });

    test('is idempotent: a second run changes nothing', () async {
      writeFlutterFixture();
      await runInit(['--project-id', 'proj_abc']);

      String snapshot() => [
        for (final f in [
          'easyi18n.yaml',
          'pubspec.yaml',
          '.gitignore',
          'lib/main.dart',
          'macos/Runner/DebugProfile.entitlements',
          'macos/Runner/Release.entitlements',
        ])
          File('${dir.path}/$f').readAsStringSync(),
      ].join('\n===\n');

      final before = snapshot();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(snapshot(), before);
    });

    test('--dry-run writes nothing', () async {
      writeFlutterFixture();
      final mainBefore = fileAt('lib/main.dart').readAsStringSync();
      final code = await runInit(['--project-id', 'proj_abc', '--dry-run']);
      expect(code, 0);

      expect(File(configPath()).existsSync(), isFalse);
      expect(fileAt('.gitignore').existsSync(), isFalse);
      expect(fileAt('assets/easyi18n').existsSync(), isFalse);
      expect(fileAt('lib/main.dart').readAsStringSync(), mainBefore);
      expect(out.toString(), contains('would'));
    });

    test('prints the snippet for a non-trivial main', () async {
      writeFlutterFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
void main() { runApp(A()); }
void alt() { runApp(B()); }
''');
      final mainBefore = fileAt('lib/main.dart').readAsStringSync();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(fileAt('lib/main.dart').readAsStringSync(), mainBefore);
      expect(out.toString(), contains('Easyi18nScope('));
      expect(out.toString(), contains('wire the scope manually'));
    });

    test('skips macOS entitlements when there is no macos target', () async {
      writeFlutterFixture();
      Directory('${dir.path}/macos').deleteSync(recursive: true);
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(out.toString(), contains('no macOS target'));
    });
  });

  group('Mode A (#415)', () {
    /// Everything the Mode B scaffold would have touched, snapshotted so a
    /// Mode A run can be proven to leave ALL of it alone.
    String runtimeSnapshot() => [
          for (final f in [
            'pubspec.yaml',
            'lib/main.dart',
            'macos/Runner/DebugProfile.entitlements',
            'macos/Runner/Release.entitlements',
          ])
            fileAt(f).readAsStringSync(),
        ].join('\n===\n');

    test('--mode a writes only config + gitignore; the customer tree is '
        'untouched', () async {
      writeFlutterFixture();
      final before = runtimeSnapshot();
      final code = await runInit(['--project-id', 'proj_abc', '--mode', 'a']);
      expect(code, 0);

      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.mode, 'a');
      expect(
        fileAt('.gitignore').readAsStringSync(),
        contains(kStateIgnoreEntry),
      );

      expect(runtimeSnapshot(), before,
          reason: 'pubspec, main.dart and entitlements must not change');
      expect(fileAt('assets/easyi18n').existsSync(), isFalse,
          reason: 'no offline floor for a project with no runtime');
      // Mode A's verb is pull; pointing at push here sent TMS users down the
      // wrong flow.
      expect(out.toString(), contains("run 'easyi18n pull'"));
      expect(out.toString(), isNot(contains("run 'easyi18n push'")));
    });

    test('l10n.yaml at the root is detected as Mode A without the flag',
        () async {
      writeFlutterFixture();
      fileAt('l10n.yaml').writeAsStringSync(
          'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n');
      final mainBefore = fileAt('lib/main.dart').readAsStringSync();

      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(Easyi18nConfig.load(File(configPath())).mode, 'a');
      expect(fileAt('lib/main.dart').readAsStringSync(), mainBefore);
      expect(out.toString(), contains('assuming Mode A'));
    });

    group('the gen_l10n template is the source pull never writes (#2343)', () {
      void writeArb(String relative) => fileAt(relative)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"@@locale":"en","welcome":"Welcome"}\n');

      test('arb-dir is output: and template-arb-file is source:', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync(
            'arb-dir: lib/i18n\ntemplate-arb-file: strings_en.arb\n');
        writeArb('lib/i18n/strings_en.arb');
        expect(await runInit(['--project-id', 'proj_abc']), 0);
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, 'lib/i18n');
        expect(config.source, 'lib/i18n/strings_en.arb');
        expect(out.toString(), contains('strings_en.arb - gen_l10n template'));
        expect(out.toString(), contains('pull never writes it'));
        expect(out.toString(), contains('import the .arb files'));
        expect(out.toString(), contains("run 'easyi18n pull'"));
      });

      test("keys l10n.yaml leaves out take gen_l10n's defaults", () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('synthetic-package: false\n');
        writeArb('lib/l10n/app_en.arb');
        expect(await runInit(['--project-id', 'proj_abc']), 0);
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, 'lib/l10n');
        expect(config.source, 'lib/l10n/app_en.arb');
      });

      test('an empty l10n.yaml takes them all', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('');
        writeArb('lib/l10n/app_en.arb');
        await expectLater(runInit(['--project-id', 'proj_abc']), completion(0));
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, 'lib/l10n');
        expect(config.source, 'lib/l10n/app_en.arb');
      });

      test('a template that does not exist yet is no source:', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('arb-dir: lib/i18n\n');
        expect(await runInit(['--project-id', 'proj_abc']), 0);
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, 'lib/i18n');
        expect(config.source, isNull);
        expect(out.toString(), isNot(contains('gen_l10n template')));
      });

      test('an l10n.yaml that does not parse keeps the defaults', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('arb-dir: [lib/i18n\n');
        writeArb('lib/i18n/app_en.arb');
        await expectLater(runInit(['--project-id', 'proj_abc']), completion(0));
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.mode, 'a');
        expect(config.output, Easyi18nConfig.defaultOutput);
        expect(config.source, isNull);
      });

      test('an l10n.yaml that is not UTF-8 keeps the defaults', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsBytesSync([0x61, 0x3a, 0x20, 0xff, 0xfe]);
        writeArb('lib/l10n/app_en.arb');
        await expectLater(runInit(['--project-id', 'proj_abc']), completion(0));
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.mode, 'a');
        expect(config.source, isNull);
      });

      test('an empty arb-dir is no directory', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('arb-dir: ""\n');
        writeArb('lib/l10n/app_en.arb');
        expect(await runInit(['--project-id', 'proj_abc']), 0);
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, 'lib/l10n');
        expect(config.source, 'lib/l10n/app_en.arb');
      });

      test('the paths l10n.yaml names are written normalized', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('arb-dir: ./lib/i18n/\n');
        writeArb('lib/i18n/app_en.arb');
        expect(await runInit(['--project-id', 'proj_abc']), 0);
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, 'lib/i18n');
        expect(config.source, 'lib/i18n/app_en.arb');
      });

      test('Mode B reads no template', () async {
        writeFlutterFixture();
        fileAt('l10n.yaml').writeAsStringSync('arb-dir: lib/i18n\n');
        writeArb('lib/i18n/app_en.arb');
        expect(await runInit(['--project-id', 'proj_abc', '--mode', 'b']), 0);
        final config = Easyi18nConfig.load(File(configPath()));
        expect(config.output, Easyi18nConfig.defaultOutput);
        expect(config.source, isNull);
      });
    });

    test('--mode b overrides the l10n.yaml detection', () async {
      writeFlutterFixture();
      fileAt('l10n.yaml').writeAsStringSync('arb-dir: lib/l10n\n');
      final code = await runInit(['--project-id', 'proj_abc', '--mode', 'b']);
      expect(code, 0);
      expect(Easyi18nConfig.load(File(configPath())).mode, 'b');
      // Full scaffold ran: the scope got wired.
      expect(
          fileAt('lib/main.dart').readAsStringSync(),
          contains('Easyi18nScope('));
    });

    test('no l10n.yaml and no flag stays Mode B (regression guard)', () async {
      writeFlutterFixture();
      final code = await runInit(['--project-id', 'proj_abc']);
      expect(code, 0);
      expect(Easyi18nConfig.load(File(configPath())).mode, 'b');
      expect(
          fileAt('lib/main.dart').readAsStringSync(),
          contains('Easyi18nScope('));
      expect(out.toString(), contains("run 'easyi18n push'"));
    });

    test('an existing config keeps its mode; a differing --mode is named',
        () async {
      writeFlutterFixture();
      await runInit(['--project-id', 'proj_abc', '--mode', 'a']);
      final code = await runInit(['--project-id', 'proj_abc', '--mode', 'b']);
      expect(code, 0);
      expect(Easyi18nConfig.load(File(configPath())).mode, 'a');
      expect(out.toString(),
          contains('keeps mode: a, not b (use --force to rewrite)'));
    });

    test('a Mode A re-run is idempotent', () async {
      writeFlutterFixture();
      await runInit(['--project-id', 'proj_abc', '--mode', 'a']);
      final before = [
        File(configPath()).readAsStringSync(),
        fileAt('.gitignore').readAsStringSync(),
        runtimeSnapshot(),
      ].join('\n===\n');
      final code = await runInit(['--project-id', 'proj_abc', '--mode', 'a']);
      expect(code, 0);
      expect(
        [
          File(configPath()).readAsStringSync(),
          fileAt('.gitignore').readAsStringSync(),
          runtimeSnapshot(),
        ].join('\n===\n'),
        before,
      );
    });
  });

  group('config handling', () {
    // Whoever types --stack knows the repository; only the MCP tool holds a
    // named stack to detection (#2444).
    test('--stack is taken as typed on a tree that does not show it', () async {
      fileAt('package.json').writeAsStringSync('{"name": "node_app"}\n');
      final code = await runInit(['--stack', 'web', '--project-id', 'proj_abc']);
      expect(code, 0);
      expect(Easyi18nConfig.load(File(configPath())).format, 'json');
    });

    test('writes a config from flags', () async {
      final code = await runInit([
        '--project-id',
        'proj_abc',
        '--base-url',
        'http://localhost:8080',
        '--format',
        'json',
      ]);

      expect(code, 0);
      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.ref, const IdRef('proj_abc'));
      expect(config.baseUrl, 'http://localhost:8080');
      expect(config.format, 'json');
      expect(config.output, Easyi18nConfig.defaultOutput);
    });

    test(
      'keeps an existing config without --force (idempotent re-run)',
      () async {
        File(configPath()).writeAsStringSync('projectId: old');
        final code = await runInit(['--project-id', 'new']);
        expect(code, 0);
        expect(Easyi18nConfig.load(File(configPath())).ref, const IdRef('old'));
        expect(out.toString(), contains('kept existing config'));
      },
    );

    test('a re-run names only the flags it was given', () async {
      // --base-url has a default, and a default is not an argument: read as
      // one, every re-run over an emulator config would name it.
      File(configPath()).writeAsStringSync(
          'projectId: proj_abc\nbaseUrl: http://localhost:8080\n');
      expect(await runInit(['--project-id', 'proj_abc']), 0);
      expect(out.toString(), contains('kept existing config'));
      expect(out.toString(), isNot(contains('keeps ')));

      expect(await runInit(
          ['--project-id', 'proj_abc', '--base-url', 'http://localhost:9090']), 0);
      expect(out.toString(), contains('keeps baseUrl: http://localhost:8080, '
          'not http://localhost:9090 (use --force to rewrite)'));
    });

    test(
      'keeps an existing config when the ref flags are degenerate',
      () async {
        // A lone '@' strips to an absent workspace inside ProjectRef.parse;
        // on the keep-existing path that must warn, not abort the re-run.
        File(configPath()).writeAsStringSync('projectId: old');
        final code = await runInit([
          '--workspace',
          '@',
          '--project',
          'dogfood',
        ]);
        expect(code, 0);
        expect(Easyi18nConfig.load(File(configPath())).ref, const IdRef('old'));
        expect(out.toString(), contains('kept existing config'));
      },
    );

    test('rewrites with --force', () async {
      File(configPath()).writeAsStringSync('projectId: old');
      await runInit(['--project-id', 'new', '--force']);
      expect(Easyi18nConfig.load(File(configPath())).ref, const IdRef('new'));
    });

    test('fails without a project id when non-interactive', () async {
      expect(() => runInit([]), throwsA(isA<CliException>()));
    });

    test('prompts for the workspace handle + project slug', () async {
      final r = runner(
        prompt: (label) => label.contains('Workspace') ? 'acme' : 'dogfood',
      );
      await r.run(['--config', configPath(), 'init']);
      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.ref, const HandleRef('acme', 'dogfood'));
    });

    test(
      'falls back to the project id prompt when no handle is given',
      () async {
        final r = runner(
          prompt: (label) => label.contains('Workspace') ? '' : 'proj_prompted',
        );
        await r.run(['--config', configPath(), 'init']);
        expect(
          Easyi18nConfig.load(File(configPath())).ref,
          const IdRef('proj_prompted'),
        );
      },
    );

    test('a prompted lone @ fails without blaming flags', () async {
      final r = runner(
        prompt: (label) => label.contains('Workspace') ? '@' : 'dogfood',
      );
      expect(
        () => r.run(['--config', configPath(), 'init']),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains("easyi18n init sets 'project' without 'workspace'"),
          ),
        ),
      );
    });

    test('accepts the @handle/slug flags', () async {
      await runInit(['--workspace', 'acme', '--project', 'dogfood']);
      final config = Easyi18nConfig.load(File(configPath()));
      expect(config.ref, const HandleRef('acme', 'dogfood'));
    });

    test('rejects --project-id combined with --workspace', () async {
      expect(
        () => runInit(['--project-id', 'p', '--workspace', 'acme']),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects --workspace without --project', () async {
      expect(
        () => runInit(['--workspace', 'acme']),
        throwsA(isA<CliException>()),
      );
    });
  });
}
