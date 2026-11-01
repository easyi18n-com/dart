import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/doctor_command.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/contract.dart';
import 'package:easyi18n_cli/src/delivery.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/agents_md.dart';

/// The default for tests that are not about the completeness arm: every
/// request fails, so the arm reports "could not verify" and nothing else in
/// the run changes.
MockClient _unreachableApi() =>
    MockClient((_) async => http.Response('down', 503));

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_doctor');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String configPath() => '${dir.path}/easyi18n.yaml';
  File fileAt(String relative) =>
      File('${dir.path}/$relative')..createSync(recursive: true);

  // ----- fixture -------------------------------------------------------------

  /// A fully-initialized Flutter app fixture: what `init` leaves behind, plus
  /// the offline floor a `pull` bakes for [floor].
  void writeHealthyFixture({
    List<String> sources = const ['Hello'],
    List<String> floor = const ['en', 'es'],
  }) {
    fileAt('easyi18n.yaml').writeAsStringSync('''
projectId: proj_abc
baseUrl: http://localhost:9
''');
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
    fileAt('assets/easyi18n/.gitkeep');
    for (final locale in floor) {
      fileAt('assets/easyi18n/$locale.json').writeAsStringSync('{}');
    }
    final trCalls = [
      for (final s in sources)
        "      Text(context.tr('${s.replaceAll("'", r"\'")}')),",
    ].join('\n');
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
    home: Column(children: [
$trCalls
    ]),
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
    writeAgentsBlock(configPath());
  }

  // ----- fake delivery -------------------------------------------------------

  /// Serves a manifest + bundles for `proj_abc`. Published state:
  /// - `Hello`   → slug `hello`, translated in es
  /// - `Pending` → slug `pending`, NOT translated in es
  /// - `Ghost string` → slug `ghost`, translated, never called from code
  MockClient fakeDelivery({
    bool cors = true,
    bool published = true,
    String corsValue = '*',
    bool corruptEs = false,
    bool emptyManifest = false,
  }) {
    final tHello = messageTokenForText('Hello');
    final tPending = messageTokenForText('Pending');
    final tGhost = messageTokenForText('Ghost string');
    final tokenIndex = {tHello: 'hello', tPending: 'pending', tGhost: 'ghost'};
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
      'en': bundle('en', {
        'hello': 'Hello',
        'pending': 'Pending',
        'ghost': 'Ghost string',
      }),
      'es': bundle('es', {'hello': 'Hola', 'ghost': 'Fantasma'}),
    };
    if (corruptEs) {
      // Content no longer matches the advertised address (stale CDN object).
      (bundles['es']!['messages'] as Map<String, String>)['hello'] = 'HolaX';
    }

    return MockClient((request) async {
      final headers = {
        'content-type': 'application/json',
        if (cors) 'access-control-allow-origin': corsValue,
      };
      final path = request.url.path;
      if (path == '/v1/projects/proj_abc/manifest') {
        if (!published) {
          return http.Response(
            jsonEncode({
              'error': 'not_published',
              'message': 'project has no published version',
            }),
            404,
            headers: headers,
          );
        }
        return http.Response(
          jsonEncode({
            'project': 'proj_abc',
            'channel': 'production',
            'revision': '2026.07.09.1',
            'tokenAlgoVersions': ['m1'],
            'locales': {
              for (final e in bundles.entries)
                if (!emptyManifest) e.key: {
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
      final bundleMatch = RegExp(
        r'^/v1/projects/proj_abc/bundles/(\w+)/',
      ).firstMatch(path);
      if (bundleMatch != null) {
        final bundle = bundles[bundleMatch.group(1)];
        if (bundle != null) {
          return http.Response(jsonEncode(bundle), 200, headers: headers);
        }
      }
      return http.Response('not found', 404);
    });
  }

  Future<int?> runDoctor({
    MockClient? client,
    MockClient? apiClient,
    bool json = false,
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
    String? sourceDir,
  }) {
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      DoctorCommand(
        output: CliOutput(logger: CliLogger(out: out, err: err))..json = json,
        environment: environment,
        deliveryFactory: ({required String baseUrl}) => DeliveryClient(
          baseUrl: baseUrl,
          httpClient: client ?? fakeDelivery(),
        ),
        apiClientFactory: ({required String baseUrl, required String token}) =>
            TranslationsApiClient(
              baseUrl: baseUrl,
              token: token,
              httpClient: apiClient ?? _unreachableApi(),
            ),
      ),
    );
    return runner.run([
      '--config', configPath(), 'doctor',
      if (sourceDir != null) ...['--source-dir', sourceDir],
    ]);
  }

  // ----- tests ---------------------------------------------------------------

  // #2445 answers a missing config with a finding only to an agent (MCP); the
  // command a human types still stops before grading a tree it cannot place.
  test('without easyi18n.yaml the terminal doctor still fails', () async {
    await expectLater(runDoctor(), throwsA(isA<CliException>().having(
        (e) => e.message, 'message', contains('No easyi18n.yaml found'))));
  });

  test('Mode B JSON retains delivery and drift findings with details', () async {
    writeHealthyFixture(sources: ['Hello', 'Pending', 'New string']);
    final code = await runDoctor(json: true);
    final report = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(code, 0);
    expect(report['verdict'], 'warnings');
    expect(report['counts'], {'failures': 0, 'warnings': 2, 'unchecked': 0});
    final findings = report['findings'] as List;
    expect(findings.map((f) => f['check']), [
      'config', 'credential', 'agents_md', 'pubspec', 'pubspec',
      'entitlements',
      'entitlements', 'scope', 'scope', 'app', 'scan', 'icu', 'delivery',
      'delivery', 'assets', 'scan', 'scan', 'scan',
    ]);
    expect(findings.where((f) => f['check'] == 'delivery').map((f) => f['level']),
        ['ok', 'ok']);
    final missing = findings.singleWhere((f) =>
        (f['message'] as String).contains('not in the published version'));
    expect(missing['level'], 'warn');
    expect(missing['details'], hasLength(1));
    expect(missing['details'].single, contains('New string'));
    expect(findings.last['level'], 'skip');
    expect(err.toString(), isEmpty);
  });

  group('healthy project', () {
    test('all checks pass, exit 0', () async {
      writeHealthyFixture();
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('All checks passed.'));
      expect(o, contains('ok    credential'));
      expect(o, contains('easyi18n is a dependency'));
      expect(o, contains('offline floor for 2 published locale(s)'));
      expect(o, contains('Easyi18nScope mounted'));
      expect(o, contains('revision 2026.07.09.1'));
      expect(o, contains('CORS allows browser fetches'));
      expect(o, contains('every tr() string is published'));
      // Ghost string is published but never called - informational only.
      expect(o, contains('info  scan - 2 published key(s) not referenced'));
      expect(o, isNot(contains('FAIL')));
    });
  });

  // `init` leaves assets/easyi18n/ holding only .gitkeep. The SDK asks for
  // assets/easyi18n/<locale>.json at start, and Flutter web logs a 404 for
  // each one missing (acceptance run 5 of #1422, #1835).
  group('offline floor', () {
    Future<Map<String, dynamic>> floorFinding({bool published = true, bool emptyManifest = false}) async {
      final code = await runDoctor(
          json: true, client: fakeDelivery(published: published, emptyManifest: emptyManifest));
      final report = jsonDecode(out.toString()) as Map<String, dynamic>;
      final findings = (report['findings'] as List)
          .cast<Map<String, dynamic>>()
          .where((f) => f['check'] == 'assets').toList();
      expect(findings, hasLength(1), reason: 'doctor must report the assets check');
      return {...findings.single, 'exit': code};
    }

    test('a published project whose floor holds only .gitkeep fails', () async {
      writeHealthyFixture(floor: []);
      final floor = await floorFinding();
      expect(floor['level'], 'fail');
      expect(floor['message'], contains('en, es'));
      expect(floor['message'], contains("run 'easyi18n pull'"));
      expect(floor['exit'], 1);
    });

    test('a floor missing one published locale fails naming only that one',
        () async {
      writeHealthyFixture(floor: ['en']);
      final floor = await floorFinding();
      expect(floor['level'], 'fail');
      expect(floor['message'], contains('no offline floor for es '));
    });

    test('files on disk but omitted from itemized assets fail', () async {
      writeHealthyFixture();
      final pubspec = fileAt('pubspec.yaml');
      pubspec.writeAsStringSync(pubspec.readAsStringSync()
          .replaceFirst('- assets/easyi18n/', '- assets/easyi18n/en.json'));
      final floor = await floorFinding();
      expect(floor['level'], 'fail');
      expect(floor['message'], contains('es'));
      expect(floor['exit'], 1);
    });

    test('a floor for every published locale passes', () async {
      writeHealthyFixture();
      final floor = await floorFinding();
      expect(floor['level'], 'ok');
      expect(floor['exit'], 0);
    });

    test('an empty floor with an empty manifest is a warning', () async {
      writeHealthyFixture(floor: []);
      final floor = await floorFinding(emptyManifest: true);
      expect(floor['level'], 'warn');
    });

    test('an existing floor before publish is reported without a locale claim', () async {
      writeHealthyFixture(floor: ['en']);
      final floor = await floorFinding(published: false);
      expect(floor['level'], 'ok');
      expect(floor['message'], 'offline floor for 1 locale(s)');
    });

    // Setup tells the agent to fix every fail, and before a publish there
    // is nothing for pull to bake.
    test('an empty floor before the first publish is a warning', () async {
      writeHealthyFixture(floor: []);
      final floor = await floorFinding(published: false);
      expect(floor['level'], 'warn');
      expect(floor['exit'], 0);
    });
  });

  // `doctor` catches `on Exception`, and a `TypeError` is an `Error` — so the
  // `as List?` this replaced escaped the command entirely: stack trace, exit
  // 255, on a 200 the probe is built to grade (SPA catch-all, captive portal,
  // WAF page). Tolerant like every other field of the manifest (#972).
  group('a manifest field of the wrong type (#972)', () {
    for (final bad in <Object?>[5, 'm1', true, <String, Object?>{}]) {
      test('tokenAlgoVersions=$bad degrades to a warning, not a crash',
          () async {
        writeHealthyFixture();
        final code = await runDoctor(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/manifest')) {
              return http.Response(
                jsonEncode({
                  'project': 'proj_abc',
                  'revision': '2026.07.09.1',
                  'tokenAlgoVersions': bad,
                  'locales': const <String, Object?>{},
                }),
                200,
                headers: const {
                  'content-type': 'application/json',
                  'access-control-allow-origin': '*',
                },
              );
            }
            return http.Response('not found', 404);
          }),
        );
        final o = out.toString();
        // The manifest still parses — `revision` is what grades it — and the
        // unreadable algo list is reported as "cannot judge", which is the
        // same verdict a genuinely newer manifest would get.
        expect(o, contains('revision 2026.07.09.1'), reason: o);
        expect(o, contains('scan skipped'), reason: o);
        expect(code, isNotNull, reason: o);
      });
    }
  });

  group('Mode A (#415)', () {
    /// What a real Mode A project looks like: config with `mode: a`, a
    /// gen_l10n tree, and NONE of the runtime wiring — no easyi18n
    /// dependency, no assets floor, no entitlements grant, no scope.
    void writeModeAFixture() {
      fileAt('easyi18n.yaml').writeAsStringSync('''
projectId: proj_abc
baseUrl: http://localhost:9
mode: a
''');
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
      writeAgentsBlock(configPath());
    }

    test('the runtime-wiring checks read as not-applicable, exit 0', () async {
      // Before #415 this exact project failed doctor on 4+ counts (missing
      // dependency, floor, entitlements, scope) — all of which are what
      // CORRECT looks like for a TMS integration.
      writeModeAFixture();
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('(Mode A: TMS)'));
      expect(o, contains('runtime wiring checks not applicable'));
      expect(o, contains('not applicable (Mode A pulls files'));
      expect(o, isNot(contains('FAIL')));
      expect(o, isNot(contains("missing the 'easyi18n' dependency")));
      expect(o, isNot(contains('Easyi18nScope not mounted')));
    });

    group('a pulled .arb against its recorded digest (#2095)', () {
      // SHA-256 of the UTF-8 bytes of `{"hello":"Hola"}`.
      const hola = 'sha256:'
          '4a59a5bb7785af3f6d9aa3856fb3cfcb1d0ad69f1701a57a35b4a64b2ef02eb9';

      Future<String> doctorOver(String arb) async {
        writeModeAFixture();
        fileAt('lib/l10n/app_es.arb')
          ..createSync(recursive: true)
          ..writeAsStringSync(arb);
        fileAt('.easyi18n/state.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({
            'format': 'arb', 'output': 'lib/l10n',
            'files': ['app_es.arb'], 'digests': {'app_es.arb': hola},
          }));
        expect(await runDoctor(), 0, reason: out.toString());
        return out.toString();
      }

      test('a file changed by hand is a warning that names it', () async {
        final o = await doctorOver('{"hello": "Buenas"}');
        expect(
            o,
            contains('lib/l10n/app_es.arb: changed since the `pull` that '
                'wrote it'));
        expect(o, contains('easyi18n pull --force'));
      });

      test('a file that says what the pull wrote adds no line', () async {
        final o = await doctorOver('{\n  "hello": "Hola"\n}\n');
        expect(o, isNot(contains('changed since')));
        expect(o, isNot(contains('app_es.arb')));
      });

      test('the file `source:` names is not one a pull replaces', () async {
        writeModeAFixture();
        fileAt('pubspec.yaml')
            .writeAsStringSync('name: demo_app\n\nflutter:\n  generate: true\n');
        fileAt('easyi18n.yaml').writeAsStringSync(
            'source: lib/l10n/app_en.arb\n',
            mode: FileMode.append);
        fileAt('lib/l10n/app_en.arb')
          ..createSync(recursive: true)
          ..writeAsStringSync('{"hello": "Hello there"}');
        fileAt('.easyi18n/state.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({
            'format': 'arb', 'output': 'lib/l10n',
            'files': ['app_en.arb'], 'digests': {'app_en.arb': hola},
          }));
        expect(await runDoctor(), 0, reason: out.toString());
        expect(out.toString(), contains('(Mode A: TMS)'));
        expect(out.toString(), isNot(contains('changed since')));
      });
    });

    /// The export answer a Mode A `doctor` grades on.
    MockClient exportAnswering(Map<String, Object?> body) => MockClient(
          (request) async => http.Response(
            jsonEncode(body),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        );

    Map<String, Object?> exportBody({
      Object? coverage,
      String? basis = 'skip',
    }) => {
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb'],
          'files': {'app_en.arb': '{}'},
          'coverageBasis': ?basis,
          'coverage': ?coverage,
        };

    test('a complete Mode A project grades, and only then passes', () async {
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(coverage: {
          'es': {'translated': 5, 'total': 5},
        })),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('ok    completeness'));
      expect(o, contains('All checks passed.'));
    });

    test('an incomplete language is a FAIL, named, exit 1', () async {
      // The state #1052 exists for: the files are shorter and nothing local
      // can tell. Before #1176 this printed `All checks passed.` (#1176).
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(coverage: {
          'es': {'translated': 3, 'total': 5},
          'fr': {'translated': 5, 'total': 5},
        })),
      );
      final o = out.toString();
      expect(code, 1, reason: o);
      expect(o, contains('FAIL  completeness'));
      expect(o, contains('es: 2 of 5'));
      expect(o, isNot(contains('fr:')));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('no credential cannot pass as a clean bill of health', () async {
      // The verdict this issue is about: an arm that could not look must not
      // let the run read as verified.
      writeModeAFixture();
      final code = await runDoctor(environment: const {});
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, contains('check(s) could not run'));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('a key without the read scope says so', () async {
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: MockClient((_) async => http.Response(
              jsonEncode({'error': 'forbidden', 'message': 'no scope'}),
              403,
              headers: const {'content-type': 'application/json'},
            )),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, contains('read scope'));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('a source-fallback version is not graded as complete', () async {
      // Its coverage counts the baked base text as a value, so it always
      // reads complete (#1179) — grading it would be the false green one
      // layer down.
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(
          basis: 'source',
          coverage: {
            'es': {'translated': 5, 'total': 5},
          },
        )),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, contains('incompleteMode: source'));
      expect(o, isNot(contains('ok    completeness')));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('a hold-basis version is NOT graded, like the gate refuses it',
        () async {
      // The name and the assertions used to say the opposite, and both were
      // green: this test was defending a divergence #1182 had already
      // created. The gate narrowed to `skip` alone, `doctor` kept accepting
      // `hold`, and the two commands answered differently about one version
      // (#1248).
      //
      // `hold` is not judgeable because a strings publish degrades it to
      // `skip` before stamping, so no version can carry it — grading it
      // would be grading a state this server cannot produce.
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(
          basis: 'hold',
          coverage: {
            'es': {'translated': 3, 'total': 5},
          },
        )),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, isNot(contains('FAIL  completeness')),
          reason: 'a basis this client cannot judge is not a verdict');
      expect(o, isNot(contains('All checks passed.')),
          reason: 'and it is not a pass either — the check could not look');
      // The MESSAGE, not just the label. Narrowing the set moved `hold` into
      // the arm that says the version "does not say how it treated" its
      // cells — false about a version that says `hold`, and a remedy
      // (republish) that stamps the same basis again. Pinned per arm because
      // the arm the set picks is not the arm the message came from (#1248).
      expect(o, contains('says it treated untranslated cells as `hold`'));
      expect(o, contains('upgrade easyi18n_cli'));
      expect(o, isNot(contains('does not say how it treated')),
          reason: 'the version DID say - it said `hold`');
    });

    test('an unstamped version is the OTHER arm, with the other remedy',
        () async {
      // The state the `hold` arm used to be collapsed into, and the only one
      // republishing fixes: a snapshot minted before the field existed says
      // nothing at all. Without this test the two arms share one fixture and
      // nothing distinguishes them — which is how they came to share one
      // message. Mirrors `pull_command_test`'s pair for the sibling gate.
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(
          basis: null,
          coverage: {
            'es': {'translated': 3, 'total': 5},
          },
        )),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, contains('does not say how it treated untranslated cells'));
      expect(o, contains('publish again to stamp it'));
      expect(o, isNot(contains('upgrade easyi18n_cli')),
          reason: 'a missing stamp is not a client that is behind');
      expect(o, isNot(contains('FAIL  completeness')));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('a project with no target language is not an unverified check',
        () async {
      // `{}` is the CORRECT answer for a base-only project (the base is
      // omitted from coverage by construction). Reading it as "could not
      // verify" blamed the server and left a healthy project permanently
      // unable to print `All checks passed.`.
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(coverage: const {})),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('no target language'));
      expect(o, isNot(contains('could not verify')));
      expect(o, isNot(contains('check(s) could not run')));
      expect(o, contains('All checks passed.'));
    });

    test('the base-only version doctor passes is the one '
        '`pull --require-complete` refuses, and doctor says so', () async {
      // The two commands answer the SAME wire body in opposite directions,
      // on purpose (health check vs gate). The divergence is defensible; a
      // dev running doctor to find out why CI is red discovering it on his
      // own is not. Both halves are driven here so the claim doctor prints
      // about its sibling cannot go stale in silence: no mutation of
      // `doctor_command.dart` can reach a sentence about `pull`.
      writeModeAFixture();
      final body = exportBody(coverage: const {});

      final code = await runDoctor(apiClient: exportAnswering(body));
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('pull --require-complete'), reason: o);

      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: CliLogger(out: out, err: err)),
          environment: const {'EASYI18N_TOKEN': 'eik_test'},
          apiClientFactory:
              ({required String baseUrl, required String token}) =>
                  TranslationsApiClient(
                    baseUrl: baseUrl,
                    token: token,
                    httpClient: exportAnswering(body),
                  ),
        ),
      );
      await expectLater(
        runner.run(['--config', configPath(), 'pull', '--require-complete']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('no target language'))),
      );
    });

    test('a backend that reports no coverage at all cannot be read as '
        'complete', () async {
      // A backend older than `1e69bfdf` sends neither `coverage` nor
      // `coverageBasis`: both keys shipped in that commit, so no server
      // sends a basis without coverage (#1263). Republishing against it
      // stamps nothing it can report, so the remedy is the gate's.
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: exportAnswering(exportBody(basis: null, coverage: null)),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, contains('no per-language coverage'));
      expect(o, contains('upgrade the backend'));
      expect(o, isNot(contains('publish again')));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('a transport failure that is not an ApiException still reports '
        'could not verify', () async {
      // The generic `catch (e)` arm: a socket that never answers is not an
      // HTTP status, and it must not fall through as a pass either.
      writeModeAFixture();
      final code = await runDoctor(
        apiClient: MockClient(
            (_) async => throw const SocketException('connection refused')),
      );
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('could not verify'));
      expect(o, contains('check(s) could not run'));
      expect(o, isNot(contains('All checks passed.')));
    });

    test('the token is not sent to a planted baseUrl without warning',
        () async {
      // doctor is the FIRST command run on a freshly cloned repo, and this
      // arm is the only one that puts the bearer token on the wire. The six
      // commands that send it all warn first; this one did not.
      writeModeAFixture();
      fileAt('easyi18n.yaml').writeAsStringSync('''
projectId: proj_abc
baseUrl: http://evil.example.com
mode: a
''');
      await runDoctor(
        environment: const {'EASYI18N_TOKEN': 'eik_secret'},
        apiClient: exportAnswering(exportBody(coverage: {
          'es': {'translated': 5, 'total': 5},
        })),
      );
      final e = err.toString();
      expect(e, contains('baseUrl points at evil.example.com'));
      expect(e, contains('plaintext HTTP'));
    });

    test('the loopback emulator is not warned about (negative control)',
        () async {
      // Positive control for the test above: the same code path over the
      // default fixture (http://localhost:9) must stay silent, or the
      // warning is noise on every dev run.
      writeModeAFixture();
      await runDoctor(
        environment: const {'EASYI18N_TOKEN': 'eik_secret'},
        apiClient: exportAnswering(exportBody(coverage: {
          'es': {'translated': 5, 'total': 5},
        })),
      );
      expect(err.toString(), isNot(contains('baseUrl points at')));
    });

    test('no token means nothing is sent, so nothing is warned about',
        () async {
      writeModeAFixture();
      fileAt('easyi18n.yaml').writeAsStringSync('''
projectId: proj_abc
baseUrl: http://evil.example.com
mode: a
''');
      await runDoctor(environment: const {});
      expect(err.toString(), isNot(contains('baseUrl points at')));
    });

    test('a second run does not inherit the first run\'s unchecked count',
        () async {
      // `_failures` and `_warnings` are reset at the top of `run()` because
      // someone contemplated re-running the command; `_unchecked` was not,
      // so a reused instance would block `All checks passed.` forever with
      // no finding to point at.
      writeModeAFixture();
      var call = 0;
      final command = DoctorCommand(
        output: CliOutput(logger: CliLogger(out: out, err: err)),
        environment: const {'EASYI18N_TOKEN': 'eik_test'},
        deliveryFactory: ({required String baseUrl}) =>
            DeliveryClient(baseUrl: baseUrl, httpClient: fakeDelivery()),
        apiClientFactory: ({required String baseUrl, required String token}) =>
            TranslationsApiClient(
              baseUrl: baseUrl,
              token: token,
              // First run cannot look; second run sees a complete version.
              httpClient: call++ == 0
                  ? _unreachableApi()
                  : exportAnswering(exportBody(coverage: {
                      'es': {'translated': 5, 'total': 5},
                    })),
            ),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
        ..addCommand(command);
      await runner.run(['--config', configPath(), 'doctor']);
      expect(out.toString(), contains('could not run'));
      out.clear();
      final code = await runner.run(['--config', configPath(), 'doctor']);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('All checks passed.'));
      expect(o, isNot(contains('could not run')));
    });

    test('points at the dashboard mode setting once', () async {
      // The CLI mode and the dashboard's project mode are set independently
      // and CAN disagree; the hint is the lightweight bridge between them.
      writeModeAFixture();
      await runDoctor();
      expect(out.toString(), contains('dashboard Settings'));
    });

    test('a Mode B config still runs the full runtime checks (regression '
        'guard)', () async {
      writeHealthyFixture();
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('Easyi18nScope mounted'));
      expect(o, isNot(contains('not applicable')));
    });
  });

  group('handle-ref config', () {
    test('probes the @handle/slug manifest with no auth header', () async {
      // Same fixture, but addressed by the legible ref.
      writeHealthyFixture();
      fileAt('easyi18n.yaml').writeAsStringSync('''
workspace: acme
project: dogfood
baseUrl: http://localhost:9
''');
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
import 'package:flutter/material.dart';

void main() => runApp(
  Easyi18nScope(
    workspace: 'acme',
    slug: 'dogfood',
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

      String? manifestPath;
      String? manifestAuth;
      final base = fakeDelivery();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/manifest')) {
          manifestPath = request.url.path;
          manifestAuth = request.headers['authorization'];
          // Rewrite the alias path to the id path the base fake serves; its
          // manifest advertises canonical (id-path) bundle URLs, so bundle
          // fetches below hit the id path the base already handles.
          final rewritten = request.url.replace(
            path: '/v1/projects/proj_abc/manifest',
          );
          return base.get(rewritten, headers: request.headers);
        }
        return base.get(request.url, headers: request.headers);
      });

      final code = await runDoctor(client: client);
      expect(manifestPath, '/v1/@acme/dogfood/manifest');
      expect(manifestAuth, isNull);
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('project @acme/dogfood'));
    });
  });

  group('platform wiring', () {
    test(
      'flags an entitlements file missing network.client (spec §12 gate)',
      () async {
        writeHealthyFixture();
        fileAt('macos/Runner/Release.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''');
        final code = await runDoctor();
        final o = out.toString();
        expect(code, 1, reason: o);
        expect(
          o,
          contains(
            'FAIL  ${dir.path}/macos/Runner/Release.entitlements - '
            'com.apple.security.network.client missing',
          ),
        );
        // The debug one is still fine.
        expect(
          o,
          contains('ok    ${dir.path}/macos/Runner/DebugProfile.entitlements'),
        );
      },
    );

    test('flags an entitlement explicitly set to false, distinctly', () async {
      writeHealthyFixture();
      fileAt('macos/Runner/Release.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.network.client</key>
\t<false/>
</dict>
</plist>
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('explicitly <false/>'));
    });

    test(
      'a commented-out entitlement pair does not count as granted',
      () async {
        writeHealthyFixture();
        fileAt('macos/Runner/Release.entitlements').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<!-- <key>com.apple.security.network.client</key>
\t<true/> -->
</dict>
</plist>
''');
        final code = await runDoctor();
        expect(code, 1);
        expect(
          out.toString(),
          contains('com.apple.security.network.client missing'),
        );
      },
    );

    test('a scope mention in a comment does not count as mounted', () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
// TODO: re-add Easyi18nScope when ready
void main() => runApp(const MyApp());
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('Easyi18nScope not mounted'));
    });

    test('accepts itemized entries for every published locale', () async {
      writeHealthyFixture();
      final pubspec = fileAt('pubspec.yaml').readAsStringSync();
      fileAt('pubspec.yaml').writeAsStringSync(
        pubspec.replaceFirst(
          '- assets/easyi18n/',
          '- assets/easyi18n/en.json\n    - assets/easyi18n/es.json',
        ),
      );
      final code = await runDoctor();
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('assets/easyi18n/ assets registered'));
    });

    test('skips entitlements when there is no macOS target', () async {
      writeHealthyFixture();
      Directory('${dir.path}/macos').deleteSync(recursive: true);
      final code = await runDoctor();
      expect(code, 0);
      expect(out.toString(), contains('info  macos/ - no macOS target'));
    });

    test('a scope on the SDK default fails when the config is not production',
        () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
void main() => runApp(Easyi18nScope(projectId: 'proj_abc', child: const MyApp()));
Widget build(BuildContext context) => MaterialApp(
  localizationsDelegates: const [], supportedLocales: const [Locale('en')]);
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('Easyi18nScope has no baseUrl'));
      expect(out.toString(),
          contains("add baseUrl: Uri.parse('http://localhost:9')"));
    });

    test('a scope on the SDK default is fine when the config is production',
        () async {
      writeHealthyFixture();
      fileAt('easyi18n.yaml').writeAsStringSync('projectId: proj_abc\n');
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
void main() => runApp(Easyi18nScope(projectId: 'proj_abc', child: const MyApp()));
Widget build(BuildContext context) => MaterialApp(
  localizationsDelegates: const [], supportedLocales: const [Locale('en')]);
''');
      await runDoctor();
      expect(out.toString(), isNot(contains('baseUrl')));
    });

    test('a MaterialApp without the locale arguments fails', () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
void main() => runApp(Easyi18nScope(
  projectId: 'proj_abc', baseUrl: Uri.parse('http://localhost:9'),
  child: const MyApp()));
Widget build(BuildContext context) => const MaterialApp(home: Text('x'));
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(),
          contains('MaterialApp has no supportedLocales / localizationsDelegates'));
    });

    test('no MaterialApp in the tree is reported, not failed', () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
void main() => runApp(Easyi18nScope(
  projectId: 'proj_abc', baseUrl: Uri.parse('http://localhost:9'),
  child: const MyApp()));
''');
      final code = await runDoctor();
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('no MaterialApp found'));
    });

    test('a narrowed --source-dir keeps the scope it found outside lib/',
        () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('void main() {}\n');
      fileAt('src/boot.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:easyi18n/easyi18n.dart';
void main() => runApp(Easyi18nScope(
  projectId: 'proj_abc', baseUrl: Uri.parse('http://localhost:9'),
  child: const MyApp()));
''');
      final code = await runDoctor(sourceDir: 'src');
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('src/boot.dart - Easyi18nScope mounted'));
      expect(out.toString(), contains('no MaterialApp found'));
    });

    test('a narrowed --source-dir still finds the wiring under lib/',
        () async {
      writeHealthyFixture();
      fileAt('lib/features/a.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync("Widget w(BuildContext c) => Text(c.tr('Hello'));\n");
      final code = await runDoctor(sourceDir: 'lib/features');
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('lib/main.dart - Easyi18nScope mounted'));
      expect(out.toString(), contains('MaterialApp declares'));
    });

    test('a ^0.1.x easyi18n constraint fails with the raise remedy', () async {
      writeHealthyFixture();
      final pubspec = fileAt('pubspec.yaml').readAsStringSync();
      fileAt('pubspec.yaml').writeAsStringSync(
          pubspec.replaceFirst('easyi18n: ^0.2.0', 'easyi18n: ^0.1.0'));
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('easyi18n ^0.1.0 excludes the SDK'));
    });

    test('fails when the scope is not mounted anywhere', () async {
      writeHealthyFixture();
      fileAt('lib/main.dart').writeAsStringSync('''
void main() => runApp(const MyApp());
''');
      final code = await runDoctor();
      expect(code, 1);
      expect(out.toString(), contains('Easyi18nScope not mounted'));
    });

    test('fails on missing pubspec dependency and floor', () async {
      writeHealthyFixture();
      fileAt('pubspec.yaml').writeAsStringSync('name: demo_app\n');
      Directory('${dir.path}/assets/easyi18n').deleteSync(recursive: true);
      int? code;
      await expectLater(runDoctor().then((value) => code = value), completes);
      final o = out.toString();
      expect(code, 1);
      expect(o, contains("missing the 'easyi18n' dependency"));
      expect(o, contains('not under flutter: assets:'));
      expect(o, contains('offline floor dir missing'));
    });
  });

  group('credential', () {
    test('warns when EASYI18N_TOKEN is not set', () async {
      writeHealthyFixture();
      final code = await runDoctor(environment: const {});
      expect(code, 0);
      expect(
        out.toString(),
        contains('warn  credential - EASYI18N_TOKEN not set'),
      );
    });
  });

  group('delivery', () {
    test('warns (does not fail) when nothing is published yet', () async {
      writeHealthyFixture();
      final code = await runDoctor(client: fakeDelivery(published: false));
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('warn  delivery - nothing published yet'));
      expect(o, isNot(contains('every tr() string is published')));
    });

    test('fails when CORS is not served', () async {
      writeHealthyFixture();
      final code = await runDoctor(client: fakeDelivery(cors: false));
      expect(code, 1);
      expect(out.toString(), contains('no access-control-allow-origin'));
    });

    test('warns when CORS is locked to one origin', () async {
      writeHealthyFixture();
      final code = await runDoctor(
        client: fakeDelivery(corsValue: 'https://app.easyi18n.com'),
      );
      expect(code, 0);
      expect(
        out.toString(),
        contains('warn  delivery - CORS is locked to https://app.easyi18n.com'),
      );
    });

    test('fails on a 200 that is not a manifest (SPA catch-all)', () async {
      writeHealthyFixture();
      final code = await runDoctor(
        client: MockClient(
          (_) async => http.Response(
            '<!doctype html><html>app</html>',
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
      );
      expect(code, 1);
      expect(out.toString(), contains('not a delivery manifest'));
    });

    test('skips a bundle whose content does not match its address', () async {
      writeHealthyFixture(sources: ['Hello', 'Pending']);
      final code = await runDoctor(client: fakeDelivery(corruptEs: true));
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('warn  delivery - bundle es:'));
      expect(o, contains('stale CDN object'));
      // en still grades; es untranslated report is skipped with the locale.
      expect(o, contains('every tr() string is published'));
    });

    test('fails when the origin is unreachable', () async {
      writeHealthyFixture();
      final code = await runDoctor(
        client: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      expect(code, 1);
      expect(out.toString(), contains('FAIL  delivery - Could not reach'));
    });
  });

  group('scan vs published keys', () {
    test('classifies missing, untranslated and unused', () async {
      writeHealthyFixture(sources: ['Hello', 'Pending', 'Brand new string']);
      final code = await runDoctor();
      final o = out.toString();
      // Warnings only: nothing here blocks, it just needs a push/translation.
      expect(code, 0, reason: o);
      expect(
        o,
        contains('warn  scan - 1 tr() string(s) not in the published version'),
      );
      expect(o, contains('"Brand new string"'));
      expect(
        o,
        contains('warn  scan - 1 of your tr() string(s) untranslated in es'),
      );
      expect(o, contains('info  scan - 1 published key(s) not referenced'));
      expect(o, contains('No blocking problems'));
    });
  });

  group('icu lint', () {
    test('a malformed source string fails the run', () async {
      writeHealthyFixture(sources: ['Hello', 'Unclosed {brace']);
      final code = await runDoctor();
      final o = out.toString();
      expect(code, 1, reason: o);
      expect(o, contains('FAIL  icu - 1 ICU problem(s)'));
      expect(o, contains('"Unclosed {brace"'));
      expect(o, contains('never closed'));
    });
  });
}
