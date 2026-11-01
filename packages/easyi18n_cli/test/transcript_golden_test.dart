@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart' show CliOutput, Easyi18nCommandRunner;
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/commands/apply_command.dart';
import 'package:easyi18n_cli/src/commands/doctor_command.dart';
import 'package:easyi18n_cli/src/commands/extract_command.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/commands/rollback_command.dart';
import 'package:easyi18n_cli/src/commands/status_command.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:easyi18n_cli/src/contract.dart';
import 'package:easyi18n_cli/src/delivery.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/agents_md.dart';
import 'support/transcript.dart';

/// Byte-for-byte transcript goldens of every command, recorded BEFORE the
/// runner/presenter refactor (spec `docs/specs/agent-native.md` section 11,
/// phase 1) moves a printed line.
///
/// "The existing tests stay green" does not prove a behaviour-preserving
/// refactor of this CLI. Measured 2026-09-06 over the nine
/// `test/*_command_test.dart` suites, one per command:
///
/// ```
/// find packages/easyi18n_cli/test -name '*_command_test.dart' -print0 |
///   xargs -0 perl -0777 -ne \
///     '$n += () = /\b(?:expect|expectLater)\(\s*(?:out|err|errOut)\b/g;
///      END{print "$n\n"}'
/// ```
///
/// **179** of their 901 `expect(` / `expectLater(` calls have a command's
/// output sink as the *actual* (101 stdout, 78 stderr; `sync` names its
/// stderr sink `errOut`, which is why a grep for `err` undercounts). Extend
/// the same pattern with `[^,]*,\s*` and a quote to grade the expected
/// side: **zero** of the 179 compare against a string literal, so none pins
/// a full transcript. Three mutations (two line reorders, one stdout to
/// stderr flip) accordingly left all 606 tests green. These goldens are
/// what those mutations have to get past.
///
/// One canonical scenario per command - not an error matrix. What a golden
/// cannot see is documented on [Transcript].
void main() {
  late Directory dir;
  late Transcript transcript;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_golden');
    transcript = Transcript();
    logger = CliLogger(out: transcript.out, err: transcript.err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  // ----- fixture plumbing ----------------------------------------------------

  File fileAt(String relative) =>
      File(p.join(dir.path, relative))..createSync(recursive: true);

  String configPath() => p.join(dir.path, 'easyi18n.yaml');

  String writeConfig(String body) {
    fileAt('easyi18n.yaml').writeAsStringSync(body);
    return configPath();
  }

  CommandRunner<int> runnerFor(Command<int> command) =>
      CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
        ..addCommand(command);

  /// Runs [args] and returns the exit code the CLI would leave the shell,
  /// including the one carried by a thrown [CliException] - a command that
  /// signals through an exception must still land in its golden.
  Future<int> exitCodeOf(CommandRunner<int> runner, List<String> args) async {
    try {
      return await runner.run(args) ?? 0;
    } on CliException catch (e) {
      return e.exitCode;
    }
  }

  /// The one scrub every scenario needs: the temp directory is different on
  /// every run, and `init` / `doctor` print absolute paths.
  (Pattern, String) scrubTmp() => (dir.path, '<tmp>');

  TranslationsApiClient Function({required String baseUrl, required String
      token})
  clientOn(MockClient mock) =>
      ({required String baseUrl, required String token}) =>
          TranslationsApiClient(
            baseUrl: baseUrl,
            token: token,
            httpClient: mock,
          );

  const env = {'EASYI18N_TOKEN': 'eik_x'};

  // ----- init ----------------------------------------------------------------

  test('init', () async {
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
    fileAt('lib/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp();
}
''');
    fileAt('macos/Runner/DebugProfile.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''');

    final code = await exitCodeOf(
      runnerFor(InitCommand(output: CliOutput(logger: logger), prompt: (_) => null)),
      ['--config', configPath(), 'init', '--project-id', 'proj_abc'],
    );

    expectGolden('init', code, transcript.records, scrub: [scrubTmp()]);
  });

  // ----- init (Xcode) --------------------------------------------------------

  // The first scenario of a second family: `init` writes a config whose
  // `catalog:`/`format:` it chose itself, and NOTHING else — a transcript that
  // grew a pubspec patch or an assets floor here would mean the file-first
  // path had picked up code-first scaffolding.
  test('init (Xcode)', () async {
    Directory(p.join(dir.path, 'EscapeCall.xcodeproj')).createSync();
    fileAt('EscapeCall/Localizable.xcstrings').writeAsStringSync(
        '{"sourceLanguage":"es","strings":{"Hola":{}},"version":"1.0"}');

    final code = await exitCodeOf(
      runnerFor(InitCommand(output: CliOutput(logger: logger), prompt: (_) => null)),
      ['--config', configPath(), 'init', '--stack', 'xcode',
       '--project-id', 'proj_abc'],
    );

    expectGolden('init_xcode', code, transcript.records, scrub: [scrubTmp()]);
  });

  // ----- doctor --------------------------------------------------------------

  test('doctor', () async {
    writeConfig('projectId: proj_abc\nbaseUrl: http://localhost:9\n');
    fileAt('pubspec.yaml').writeAsStringSync('''
name: demo_app

dependencies:
  flutter:
    sdk: flutter
  easyi18n: ^0.2.0

flutter:
  assets:
    - assets/easyi18n/
''');
    for (final locale in ['en', 'es']) {
      fileAt('assets/easyi18n/$locale.json').writeAsStringSync('{}');
    }
    fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
import 'package:flutter/material.dart';

void main() => runApp(
  Easyi18nScope(
    projectId: 'proj_abc',
    baseUrl: Uri.parse('http://localhost:9'),
    child: const MyApp(),
  ),
);

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: Easyi18nScope.localesOf(context),
    home: Text(context.tr('Hello')),
  );
}
''');
    for (final name in ['DebugProfile.entitlements', 'Release.entitlements']) {
      fileAt('macos/Runner/$name').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
\t<key>com.apple.security.network.client</key>
\t<true/>
</dict>
</plist>
''');
    }

    final tokenIndex = {
      messageTokenForText('Hello'): 'hello',
      messageTokenForText('Pending'): 'pending',
    };
    Map<String, Object?> bundle(String locale, Map<String, String> messages) =>
        {
          'schemaVersion': 1,
          'locale': locale,
          'bundleHash': computeBundleHash(
            schemaVersion: 1,
            locale: locale,
            messages: messages,
            tokenIndex: tokenIndex,
          ),
          'messages': messages,
          'tokenIndex': tokenIndex,
        };
    final bundles = {
      'en': bundle('en', {'hello': 'Hello', 'pending': 'Pending'}),
      'es': bundle('es', {'hello': 'Hola'}),
    };
    final delivery = MockClient((request) async {
      const headers = {
        'content-type': 'application/json',
        'access-control-allow-origin': '*',
      };
      final path = request.url.path;
      if (path == '/v1/projects/proj_abc/manifest') {
        return http.Response(
          jsonEncode({
            'project': 'proj_abc',
            'channel': 'production',
            'revision': '2026.07.09.1',
            'tokenAlgoVersions': ['m1'],
            'locales': {
              for (final e in bundles.entries)
                e.key: {
                  'version': '2026.07.09.1',
                  'bundleHash': e.value['bundleHash'],
                  'url':
                      '/v1/projects/proj_abc/bundles/${e.key}/'
                      '${e.value['bundleHash']}.json',
                },
            },
          }),
          200,
          headers: headers,
        );
      }
      final match = RegExp(
        r'^/v1/projects/proj_abc/bundles/(\w+)/',
      ).firstMatch(path);
      final bundle = match == null ? null : bundles[match.group(1)];
      if (bundle != null) {
        return http.Response(jsonEncode(bundle), 200, headers: headers);
      }
      return http.Response('not found', 404);
    });
    writeAgentsBlock(configPath());

    final code = await exitCodeOf(
      runnerFor(
        DoctorCommand(
          output: CliOutput(logger: logger),
          environment: env,
          deliveryFactory: ({required String baseUrl}) =>
              DeliveryClient(baseUrl: baseUrl, httpClient: delivery),
          apiClientFactory: clientOn(
            // Mode B never reaches `_gradeModeACompleteness`, so this factory
            // is never called and nothing it returns appears in the golden.
            // The completeness presenter is recorded by the `doctor (Mode A)`
            // scenario below, which is the only one that arms it.
            MockClient((_) async => http.Response('down', 503)),
          ),
        ),
      ),
      ['--config', configPath(), 'doctor'],
    );

    expectGolden('doctor', code, transcript.records, scrub: [scrubTmp()]);
  });

  // ----- doctor (Mode A) -----------------------------------------------------

  // The second `doctor` scenario earns its place: Mode A is the ONLY config
  // that reaches `_gradeModeACompleteness` (`doctor_command.dart`), i.e. the
  // `ok/FAIL/could-not-verify completeness` presenter that #1176/#1179/#1248
  // rewrote three times. The Mode B scenario above never calls its injected
  // `apiClientFactory` at all, so without this the whole arm is unrecorded.
  test('doctor (Mode A)', () async {
    writeConfig('projectId: proj_abc\nbaseUrl: http://localhost:9\nmode: a\n');
    fileAt('pubspec.yaml').writeAsStringSync('''
name: demo_app

dependencies:
  flutter:
    sdk: flutter
''');
    fileAt('lib/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp());
''');

    final export = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb'],
          'files': {'app_en.arb': '{}'},
          'coverageBasis': 'skip',
          'coverage': {
            'es': {'translated': 5, 'total': 5},
            'fr': {'translated': 3, 'total': 5},
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );

    final code = await exitCodeOf(
      runnerFor(
        DoctorCommand(
          output: CliOutput(logger: logger),
          environment: env,
          deliveryFactory: ({required String baseUrl}) => DeliveryClient(
            baseUrl: baseUrl,
            // Mode A skips the delivery probe; an exploding client proves it
            // rather than asserting the skip from the transcript alone.
            httpClient: MockClient(
              (_) async => throw StateError('delivery probed in Mode A'),
            ),
          ),
          apiClientFactory: clientOn(export),
        ),
      ),
      ['--config', configPath(), 'doctor'],
    );

    expectGolden('doctor_mode_a', code, transcript.records,
        scrub: [scrubTmp()]);
  });

  // ----- doctor (Xcode) ------------------------------------------------------

  // The file-first half of `doctor`: the catalog checks plus the Mode A
  // completeness grading, over a tree with no pubspec at all. It is the
  // scenario that would go silent if `doctor` ever went back to naming its
  // stack instead of detecting it.
  test('doctor (Xcode)', () async {
    writeConfig('projectId: proj_abc\nbaseUrl: http://localhost:9\nmode: a\n'
        'format: xcstrings\ncatalog: EscapeCall/Localizable.xcstrings\n');
    Directory(p.join(dir.path, 'EscapeCall.xcodeproj')).createSync();
    fileAt('EscapeCall/Localizable.xcstrings').writeAsStringSync(
        '{"sourceLanguage":"es","strings":{"Hola":{"localizations":'
        '{"en":{"stringUnit":{"state":"translated","value":"Hi"}}}}},'
        '"version":"1.0"}');
    writeAgentsBlock(configPath());

    final export = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'es',
          'formats': ['xcstrings'],
          'files': {'Localizable.xcstrings': '{}'},
          'coverageBasis': 'skip',
          'coverage': {
            'en': {'translated': 1, 'total': 1},
          },
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );

    final code = await exitCodeOf(
      runnerFor(
        DoctorCommand(
          output: CliOutput(logger: logger),
          environment: env,
          deliveryFactory: ({required String baseUrl}) => DeliveryClient(
            baseUrl: baseUrl,
            // A file-first project never probes delivery: an exploding client
            // proves it instead of reading the absence off the transcript.
            httpClient: MockClient(
              (_) async => throw StateError('delivery probed on a catalog project'),
            ),
          ),
          apiClientFactory: clientOn(export),
        ),
      ),
      ['--config', configPath(), 'doctor'],
    );

    expectGolden('doctor_xcode', code, transcript.records, scrub: [scrubTmp()]);
  });

  // ----- extract -------------------------------------------------------------

  test('extract', () async {
    fileAt('lib/app.dart').writeAsStringSync('''
void build(c, name) {
  c.tr('Hello');
  c.tr('Goodbye');
  c.tr(name);
}
''');
    fileAt('easyi18n.lock').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'project': 'proj_abc',
        'units': [
          {'source': 'Hello'},
          {'source': 'Retired copy'},
        ],
      }),
    );
    final config = writeConfig('projectId: proj_abc\n');

    final code = await exitCodeOf(runnerFor(ExtractCommand(output: CliOutput(logger: logger))), [
      '--config',
      config,
      'extract',
    ]);

    expectGolden('extract', code, transcript.records);
  });

  for (final failOnOrphans in [false, true]) {
    final name = failOnOrphans ? 'extract_json_orphans' : 'extract_json';
    test(name, () async {
      fileAt('lib/app.dart').writeAsStringSync('''
void build(c, name) {
  c.tr('Hello');
  c.tr('Goodbye');
  c.tr(name);
}
''');
      fileAt('easyi18n.lock').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'project': 'proj_abc',
          'units': [
            {'source': 'Hello'},
            {'source': 'Retired copy'},
          ],
        }),
      );
      final config = writeConfig('projectId: proj_abc\n');

      final code = await exitCodeOf(Easyi18nCommandRunner(logger: logger), [
        if (!failOnOrphans) '--json',
        '--config',
        config,
        'extract',
        if (failOnOrphans) ...['--json', '--fail-on-orphans'],
      ]);

      final records = transcript.records.map((r) => (
        channel: r.channel,
        line: r.line.replaceAll(dir.path, '<project>'),
      )).toList();
      expectJsonGolden(name, code, records, check: (json) {
        expect(json['dynamics'][0], {
          'file': 'lib/app.dart', 'line': 4, 'snippet': 'c.tr(name)',
        });
      });
    });
  }

  for (final filesScanned in [0, 1]) {
    final name = filesScanned == 0 ? 'extract_json_missing' : 'extract_json_empty';
    test(name, () async {
      final config = writeConfig('projectId: proj_abc\n');
      if (filesScanned == 1) {
        fileAt('lib/app.dart').writeAsStringSync('void build() {}\n');
      }
      final code = await exitCodeOf(Easyi18nCommandRunner(logger: logger), [
        '--config', config, 'extract', '--json', '--fail-on-orphans',
      ]);
      expect(code, 0);
      expect(transcript.records.where((r) => r.channel == 'err'), isEmpty);
      final records = transcript.records.map((r) => (
        channel: r.channel,
        line: r.line.replaceAll(dir.path, '<project>'),
      )).toList();
      expectJsonGolden(name, code, records, check: (json) {
        expect(json['files_scanned'], filesScanned);
        expect(json['total'], 0);
        expect(json['dynamics'], isEmpty);
      });
    });
  }

  // ----- push ----------------------------------------------------------------

  test('push', () async {
    fileAt('lib/app.dart').writeAsStringSync("void f(c) => c.tr('Hello');\n");
    final config = writeConfig('projectId: proj_abc\n');

    var pushed = false;
    var polls = 0;
    final mock = MockClient((req) async {
      if (req.url.path.endsWith('/publish')) {
        return http.Response(
          jsonEncode({'versionId': '2026.07.09.9', 'keyCount': 3}),
          201,
        );
      }
      if (req.url.path.endsWith('/meta')) {
        return http.Response(
          jsonEncode({
            'baseCode': 'en',
            'mode': null,
            'outputFormatsApiVersion': 1, 'currentVersionId': '2026.01.01',
            'formats': ['arb'],
            'languages': const [
              {'code': 'en', 'name': 'English', 'isBase': true,
                'fillMode': 'ai'},
              {'code': 'fr', 'name': 'French', 'isBase': false,
                'fillMode': 'ai'},
            ],
          }),
          200,
        );
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final units = (body['units'] as List).cast<Map<String, dynamic>>();
      final dryRun = req.url.queryParameters['dryRun'] == 'true';
      var pending = <String>['fr'];
      final priced = !pushed;
      if (dryRun && pushed) {
        polls++;
        if (polls >= 2) pending = [];
      }
      if (!dryRun) pushed = true;
      return http.Response(
        jsonEncode({
          'dryRun': dryRun,
          'trackingToken': dryRun ? null : 'job_1',
          'estimatedCredits': priced ? units.length * 10 : 0,
          'balance': 1000,
          'accepted': true,
          'baseCode': 'en',
          'targetLangs': ['fr'],
          'units': [
            for (final u in units)
              {
                'key': 'k_${u['source']}',
                'token': 't',
                'outcome': 'created',
                'translated': <String>[],
                'pending': pending,
              },
          ],
        }),
        200,
      );
    });

    final code = await exitCodeOf(
      runnerFor(
        PushCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: clientOn(mock),
          environment: env,
          confirm: (_) => true,
          wait: (_) async {},
        ),
      ),
      ['--config', config, 'push', '--publish', '--yes'],
    );

    expectGolden('push', code, transcript.records);
  });

  for (final dryRun in [true, false]) {
    final name = dryRun ? 'push_json_dry_run' : 'push_json';
    test(name, () async {
      fileAt('lib/app.dart').writeAsStringSync("void f(c) => c.tr('Hello');\n");
      final config = writeConfig('projectId: proj_abc\n');
      final mock = MockClient((req) async {
        if (req.url.path.endsWith('/meta')) return http.Response('{}', 403);
        final dry = req.url.queryParameters['dryRun'] == 'true';
        return http.Response(jsonEncode({
          'dryRun': dry, 'trackingToken': dry ? null : 'job_1',
          'estimatedCredits': 10000, 'balance': 1000000,
          'availableCredits': 500000, 'accepted': true,
          'baseCode': 'en', 'targetLangs': ['fr'],
          'units': [{'key': 'k_Hello', 'token': 't', 'outcome': 'created',
            'translated': <String>[], 'pending': ['fr']}],
        }), 200);
      });
      final code = await exitCodeOf(
        Easyi18nCommandRunner(logger: logger, environment: env,
            apiClientFactory: clientOn(mock)),
        ['--config', config, '--json', 'push', if (dryRun) '--dry-run' else '--yes'],
      );
      final records = transcript.records.map((r) => (
        channel: r.channel,
        line: r.line.replaceAll(dir.path, '<project>'),
      )).toList();
      expectJsonGolden(name, code, records, check: (json) {
        expect(json['preview']['estimate']['estimated_credits'], 10.0);
        expect(json['preview']['estimate']['available_credits'], 500.0);
        expect(json['dry_run'], dryRun);
        expect(json['lockfile_written'], !dryRun);
        expect(json['pushed'], dryRun ? isNull : isNotNull);
      });
    });
  }

  // ----- pull ----------------------------------------------------------------

  test('pull', () async {
    final config = writeConfig(
      'projectId: proj_abc\nformat: arb\noutput: lib/l10n\n',
    );
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb'],
          'files': {
            'arb/app_en.arb': '{"hi":"Hi"}',
            'arb/app_es.arb': '{"hi":"Hola"}',
          },
        }),
        200,
      ),
    );

    final code = await exitCodeOf(
      runnerFor(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: clientOn(mock),
          environment: env,
        ),
      ),
      ['--config', config, 'pull'],
    );

    expectGolden('pull', code, transcript.records, scrub: [scrubTmp()]);
  });

  // ----- sync ----------------------------------------------------------------

  test('sync', () async {
    final config = writeConfig(
      'projectId: p1\nformat: xcstrings\ncatalog: App/Localizable.xcstrings\n',
    );
    fileAt('App/Localizable.xcstrings').writeAsStringSync(
      '{\n'
      '  "sourceLanguage" : "es",\n'
      '  "strings" : {\n'
      '    "Hola" : {\n'
      '\n'
      '    }\n'
      '  },\n'
      '  "version" : "1.0"\n'
      '}',
    );

    Map<String, Object?> syncBody(http.Request req) {
      final dryRun = req.url.queryParameters['dryRun'] == 'true';
      return {
        'dryRun': dryRun,
        'format': 'xcstrings',
        'baseCode': 'es',
        'targetLangs': ['en'],
        'fillableLangs': ['en'],
        'created': 2,
        'updatedSources': 0,
        'matchedSources': 0,
        'updatedTranslations': 1,
        'unchangedTranslations': 0,
        'disabledOrphans': 0,
        'reenabled': 0,
        'failedEntries': const [],
        'exhausted': const [],
        'conflicts': [
          {'key': 'Hola', 'lang': 'en', 'local': 'Hi', 'server': 'Hello'},
        ],
        'conflictsTotal': 1,
        'onConflict': 'server',
        'diagnostics': const [],
        'trackingToken': dryRun ? null : 'job1',
        'estimatedCredits': 12000,
        'balance': 500000,
        'accepted': true,
      };
    }

    final mock = MockClient((req) async {
      const headers = {'content-type': 'application/json'};
      final path = req.url.path;
      if (path.endsWith('/meta')) {
        return http.Response(
          jsonEncode({
            'baseCode': 'es',
            'mode': null,
            'outputFormatsApiVersion': 1, 'currentVersionId': '2026.08.11.1',
            'languages': const [],
            'formats': ['xcstrings'],
          }),
          200,
          headers: headers,
        );
      }
      if (path.endsWith('/sync')) {
        return http.Response(jsonEncode(syncBody(req)), 200, headers: headers);
      }
      if (path.endsWith('/translations') &&
          req.url.queryParameters.containsKey('trackingToken')) {
        return http.Response(
          jsonEncode({
            'status': 'done',
            'summary': {
              'total': 1,
              'translated': 1,
              'pending': 0,
              'failed': 0,
            },
          }),
          200,
          headers: headers,
        );
      }
      if (path.endsWith('/publish')) {
        return http.Response(
          jsonEncode({'versionId': '2026.08.11.1', 'keyCount': 2}),
          201,
          headers: headers,
        );
      }
      if (path.endsWith('/translations')) {
        return http.Response(
          jsonEncode({
            'project': 'p1',
            'version': '2026.08.11.1',
            'baseCode': 'es',
            'formats': ['xcstrings'],
            'files': {
              'xcstrings/Localizable.xcstrings':
                  '{"sourceLanguage":"es","strings":{"Hola":{"localizations":'
                  '{"en":{"stringUnit":{"state":"translated","value":"Hello"'
                  '}}}}}}',
            },
          }),
          200,
          headers: headers,
        );
      }
      return http.Response('{"error":"not_found"}', 404);
    });

    final code = await exitCodeOf(
      runnerFor(
        SyncCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: clientOn(mock),
          environment: env,
          confirm: (_) => true,
          wait: (_) async {},
          // `_describeDelay` prints the backoff, so the seed is pinned.
          random: Random(7),
        ),
      ),
      ['--config', config, 'sync', '--yes'],
    );

    expectGolden('sync', code, transcript.records, scrub: [scrubTmp()]);
  });

  // The `sync --json` record, on the same wire the text golden uses: one
  // object, and both channels the route is the only reporter for — the #671
  // base-language conflict row and the #727 per-language parse diagnostics.
  test('sync_json', () async {
    final config = writeConfig(
      'projectId: p1\nformat: xcstrings\ncatalog: App/Localizable.xcstrings\n',
    );
    fileAt('App/Localizable.xcstrings').writeAsStringSync(
      '{"sourceLanguage":"es","strings":{"Hola":{}},"version":"1.0"}',
    );
    final mock = MockClient((req) async {
      const headers = {'content-type': 'application/json'};
      final path = req.url.path;
      if (path.endsWith('/meta')) {
        return http.Response(
          jsonEncode({
            'baseCode': 'es', 'mode': null,
            'outputFormatsApiVersion': 1, 'currentVersionId': '2026.08.11.1',
            'languages': const [], 'formats': ['xcstrings'],
          }),
          200, headers: headers,
        );
      }
      if (path.endsWith('/sync')) {
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        return http.Response(jsonEncode({
          'dryRun': dryRun, 'format': 'xcstrings', 'baseCode': 'es',
          'targetLangs': ['en'], 'fillableLangs': ['en'],
          'created': 1, 'updatedSources': 0, 'matchedSources': 0,
          'updatedTranslations': 1, 'unchangedTranslations': 0,
          'disabledOrphans': 0, 'reenabled': 0,
          'failedEntries': const [], 'exhausted': const [],
          'conflicts': [
            {'key': 'Hola', 'lang': 'es', 'origin': 'human',
              'stage': 'reviewed', 'resolution': 'kept'},
          ],
          'conflictsTotal': 1, 'onConflict': 'server',
          'diagnostics': const [
            {'code': 'DUPLICATE_PLURAL_FORM', 'field': 'Hola',
              'lang': 'en', 'message': 'selector "one" repeated'},
          ],
          'trackingToken': null,
          'estimatedCredits': 12000, 'balance': 500000,
          'availableCredits': 400000, 'accepted': true,
        }), 200, headers: headers);
      }
      if (path.endsWith('/publish')) {
        return http.Response(
          jsonEncode({'versionId': '2026.08.11.1', 'keyCount': 2}),
          201, headers: headers,
        );
      }
      if (path.endsWith('/translations')) {
        return http.Response(jsonEncode({
          'project': 'p1', 'version': '2026.08.11.1', 'baseCode': 'es',
          'formats': ['xcstrings'],
          'files': {
            'xcstrings/Localizable.xcstrings':
                '{"sourceLanguage":"es","strings":{"Hola":{"localizations":'
                '{"en":{"stringUnit":{"state":"translated","value":"Hello"'
                '}}}}}}',
          },
        }), 200, headers: headers);
      }
      return http.Response('{"error":"not_found"}', 404);
    });
    final code = await exitCodeOf(
      Easyi18nCommandRunner(logger: logger, environment: env,
          apiClientFactory: clientOn(mock)),
      ['--config', config, '--json', 'sync', '--yes'],
    );
    final records = transcript.records.map((r) => (
      channel: r.channel,
      line: r.line.replaceAll(dir.path, '<project>'),
    )).toList();
    expectJsonGolden('sync_json', code, records, check: (json) {
      // The row a `sync` is the only reporter of (#671): a base-language
      // conflict is a SOURCE the catalog would have reverted.
      expect(json['synced']['conflicts'].single['lang'], 'es');
      expect(json['synced']['conflicts'].single['resolution'], 'kept');
      // And the parse finding the CLI used to pay for and throw away (#727).
      expect(json['synced']['diagnostics'].single['code'],
          'DUPLICATE_PLURAL_FORM');
      expect(json['delivery']['version_id'], '2026.08.11.1');
      expect(json['dry_run'], false);
    });
  });

  // ----- apply ---------------------------------------------------------------

  test('apply', () async {
    fileAt('lib/app.dart').writeAsStringSync("void f(c) => c.tr('Helo');\n");
    final config = writeConfig('projectId: proj_abc\n');
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'changes': [
            {
              'key': 'greeting',
              'ctx': null,
              'oldSource': 'Helo',
              'newSource': 'Hello',
            },
            {
              'key': 'farewell',
              'ctx': 'button',
              'oldSource': 'Bye',
              'newSource': 'Goodbye',
            },
          ],
        }),
        200,
      ),
    );

    final code = await exitCodeOf(
      runnerFor(
        ApplyCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: clientOn(mock),
          environment: env,
        ),
      ),
      ['--config', config, 'apply'],
    );

    expectGolden('apply', code, transcript.records);
  });

  // ----- status --------------------------------------------------------------

  test('status', () async {
    final config = writeConfig('projectId: proj_abc\n');
    CliState(
      version: '2026.07.04.1',
      pulledAt: DateTime.now().toUtc(),
      format: 'xcstrings',
      catalog: 'App/Localizable.xcstrings',
    ).save(CliState.fileFor(config));

    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({'outputFormatsApiVersion': 1, 'currentVersionId': '2026.07.04.3', 'baseCode': 'en', 'formats': ['arb']}),
        200,
      ),
    );

    final code = await exitCodeOf(
      runnerFor(
        StatusCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: clientOn(mock),
          environment: env,
        ),
      ),
      ['--config', config, 'status'],
    );

    expectGolden(
      'status',
      code,
      transcript.records,
      // `_ago` reads DateTime.now(); the elapsed form is the only part of
      // this transcript that is not a function of the fixture.
      scrub: [(RegExp(r'\(pulled [^)]+\)'), '(pulled <ago>)')],
    );
  });

  for (final remote in <String?>[null, '2026.07.04.3']) {
    final name = remote == null ? 'status_json' : 'status_json_outdated';
    test(name, () async {
      final config = writeConfig('projectId: proj_abc\n');
      CliState(
        version: '2026.07.04.1',
        pulledAt: DateTime.utc(2026, 7, 4, 12),
        catalog: 'App/Localizable.xcstrings',
      ).save(CliState.fileFor(config));
      var requests = 0;
      final mock = MockClient((req) async {
        requests++;
        expect(req.url.path, '/v1/projects/proj_abc/meta');
        return http.Response(jsonEncode({
          'outputFormatsApiVersion': 1, 'currentVersionId': remote, 'baseCode': 'en',
          'formats': ['arb'],
          'languages': [
            {'code': 'en', 'isBase': true, 'fillMode': 'manual'},
            {'code': 'es', 'isBase': false, 'fillMode': 'ai'},
          ],
        }), 200);
      });
      final code = await Easyi18nCommandRunner(
        logger: logger, apiClientFactory: clientOn(mock), environment: env,
      ).run(['--json', '--config', config, 'status']);
      expect(code, 1);
      expect(requests, 1);
      expectJsonGolden(name, code!, transcript.records.map((r) => (
        channel: r.channel, line: r.line.replaceAll(dir.path, '<project>'),
      )).toList(), check: (json) {
        expect(json['state'], remote == null ? 'never_published' : 'out_of_date');
        expect(json['published'], remote != null);
        expect(json['languages'], [
          {'code': 'en', 'is_base': true, 'fill_mode': 'manual'},
          {'code': 'es', 'is_base': false, 'fill_mode': 'ai'},
        ]);
      });
    });
  }

  test('status_json_error', () async {
    final config = writeConfig('projectId: proj_abc\n');
    final code = await Easyi18nCommandRunner(
      logger: logger, environment: const {},
      apiClientFactory: ({required baseUrl, required token}) =>
          throw StateError('Missing credentials must not create a client'),
    ).run(['--config', config, 'status', '--json']);
    expect(code, 1);
    expectJsonGolden('status_json_error', code!, transcript.records, check: (json) {
      expect(json['error']['retryable'], false);
      expect(json['error']['code'], 'cli_error');
    });
  });

  // ----- rollback ------------------------------------------------------------

  test('rollback', () async {
    final config = writeConfig('projectId: proj_abc\n');
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'versionId': '2026.07.09.4',
          'keyCount': 3,
          'restoredFrom': '2026.07.08.2',
          'icuRejected': [
            "apples [es]: plural value is missing the mandatory 'other' form",
          ],
          'icuRejectedTotal': 2,
        }),
        201,
      ),
    );

    final code = await exitCodeOf(
      runnerFor(
        RollbackCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: clientOn(mock),
          environment: env,
        ),
      ),
      ['--config', config, 'rollback'],
    );

    expectGolden('rollback', code, transcript.records);
  });

  test('rollback_json', () async {
    final config = writeConfig('projectId: proj_abc\n');
    final mock = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path,
          '/v1/projects/proj_abc/versions/previous/restore');
      return http.Response(jsonEncode({
        'versionId': '2026.07.09.4', 'keyCount': 3,
        'restoredFrom': '2026.07.08.2',
        'icuRejected': [
          "apples [es]: plural value is missing the mandatory 'other' form",
        ],
        'icuRejectedTotal': 2,
      }), 201);
    });
    final code = await Easyi18nCommandRunner(
      logger: logger, apiClientFactory: clientOn(mock), environment: env,
    ).run(['--json', '--config', config, 'rollback']);
    expect(code, 0);
    final warnings = transcript.records.where((r) => r.channel == 'err').toList();
    expect(warnings, hasLength(3));
    expect(warnings.map((r) => 'err|${r.line}').join('\n'),
        File('test/goldens/rollback.txt').readAsLinesSync()
            .where((line) => line.startsWith('err|')).join('\n'));
    expectJsonGolden('rollback_json', code!, transcript.records.map((r) => (
      channel: r.channel, line: r.line.replaceAll(dir.path, '<project>'),
    )).toList(), check: (json) {
      expect(json['flagged']['icu_total'], 2);
      expect(json['project_dir'], '<project>');
    });
  });

  test('rollback_json_error', () async {
    final config = writeConfig('projectId: proj_abc\n');
    final code = await Easyi18nCommandRunner(
      logger: logger, environment: const {},
      apiClientFactory: ({required baseUrl, required token}) =>
          throw StateError('Missing credentials must not create a client'),
    ).run(['--config', config, 'rollback', '--json']);
    expect(code, 1);
    expectJsonGolden('rollback_json_error', code!, transcript.records, check: (json) {
      expect(json['error']['message'],
          'No credential. Set EASYI18N_TOKEN or pass --token.\n'
          'Create an API key in your project settings (needs the publish scope).');
      expect(json['error']['retryable'], false);
    });
  });

}
