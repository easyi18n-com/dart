import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/lockfile.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;
  late List<http.Request> requests;

  /// The `/translate` calls only. `push` also reads `/meta` (and may resolve a
  /// handle ref), and counting those here would make every spend assertion
  /// depend on plumbing rather than on what was actually translated.
  List<http.Request> translateCalls() =>
      [for (final r in requests) if (r.url.path.endsWith('/translate')) r];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_push');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig({
    String? mode,
    String? format,
    String? catalog,
    List<String> catalogs = const [],
    String? source,
  }) {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync(
      'projectId: proj_abc\n'
      '${mode == null ? '' : 'mode: $mode\n'}'
      '${format == null ? '' : 'format: $format\n'}'
      '${catalog == null ? '' : 'catalog: "$catalog"\n'}'
      '${catalogs.isEmpty ? '' : 'catalogs:\n${catalogs.map((c) => '  - "$c"\n').join()}'}'
      '${source == null ? '' : 'source: "$source"\n'}',
    );
    return path;
  }

  void writeSource(String relPath, String content) {
    final f = File(p.join(dir.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  File lockFile() => File(p.join(dir.path, Lockfile.fileName));

  /// A runner whose push command talks to a MockClient that prices each unit at
  /// 10 credits and reports one pending lang. [balance] is the workspace TOTAL;
  /// [availableCredits] is what a new job may spend (omit to mean an older
  /// server that does not send the field). [confirm] answers the prompt.
  CommandRunner<int> runnerWith({
    int balance = 1000,
    int? availableCredits,
    bool confirm = true,
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_x'},
    String? projectMode,
    List<Map<String, Object?>>? languages,
    int metaStatus = 200,
    String? metaBody,
  }) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        requests.add(req);
        // `push` reads /meta for the language catalogue and the project mode.
        // Best effort by contract: `metaStatus` lets a test prove the push
        // still works when a translate-only key cannot read it.
        if (req.url.path.endsWith('/publish')) {
          return http.Response(
            jsonEncode({'versionId': '2026.07.09.9', 'keyCount': 0}),
            201,
          );
        }
        if (req.url.path.endsWith('/meta')) {
          if (metaBody != null) return http.Response(metaBody, 200);
          if (metaStatus != 200) {
            return http.Response(
              jsonEncode({'error': 'forbidden', 'message': 'no read scope'}),
              metaStatus,
            );
          }
          return http.Response(
            jsonEncode({
              'baseCode': 'en',
              'mode': projectMode,
              'outputFormatsApiVersion': 1, 'currentVersionId': '2026.01.01',
              'formats': ['arb'],
              'languages': languages ??
                  const [
                    {
                      'code': 'en',
                      'name': 'English',
                      'isBase': true,
                      'fillMode': 'ai',
                    },
                    {
                      'code': 'fr',
                      'name': 'French',
                      'isBase': false,
                      'fillMode': 'ai',
                    },
                  ],
            }),
            200,
          );
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final units = (body['units'] as List).cast<Map<String, dynamic>>();
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        final estimated = units.length * 10;
        return http.Response(
          jsonEncode({
            'dryRun': dryRun,
            'trackingToken': dryRun ? null : 'job_1',
            'estimatedCredits': estimated,
            'balance': balance,
            'availableCredits': ?availableCredits,
            'accepted': estimated <= (availableCredits ?? balance),
            'baseCode': 'en',
            'targetLangs': ['fr'],
            'units': [
              for (final u in units)
                {
                  'key': 'k_${u['source']}',
                  'token': 't',
                  'outcome': 'created',
                  'translated': <String>[],
                  'pending': ['fr'],
                },
            ],
          }),
          200,
        );
      }),
    );

    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PushCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factory,
        environment: environment,
        confirm: (_) => confirm,
      ),
    );
    return runner;
  }

  test(
    'pushes new strings, writes the lockfile, prints a job message',
    () async {
      writeSource('lib/main.dart', '''
void build(c) {
  c.tr('Hello');
  c.tr('World');
}
''');
      final code = await runnerWith().run([
        '--config',
        writeConfig(),
        'push',
        '--yes',
      ]);

      expect(code, 0);
      // One /meta read + one dry-run call + one real call.
      expect(requests.length, 3);
      expect(requests.first.url.path, endsWith('/meta'));
      final translates =
          requests.where((r) => r.url.path.endsWith('/translate')).toList();
      expect(translates.first.url.queryParameters['dryRun'], 'true');
      expect(
          translates.last.url.queryParameters.containsKey('dryRun'), isFalse);
      expect(out.toString(), contains('Translating in the background'));

      final lock = Lockfile.loadOrEmpty(lockFile(), project: 'x');
      expect(lock.units.map((u) => u.source).toSet(), {'Hello', 'World'});
    },
  );

  group('--lang validation against the live catalogue', () {
    setUp(() => writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n"));

    test('an unknown code fails locally, before any translate call', () async {
      await expectLater(
        runnerWith().run(
            ['--config', writeConfig(), 'push', '--yes', '--lang', 'de']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            allOf(contains('Not a language on this project: de'),
                contains('Configured targets: fr'),
                // The server DROPS it silently — the message must not claim
                // a rejection that does not exist on this route.
                contains('drop it silently')))),
      );
      expect(translateCalls(), isEmpty);
    });

    test('an underscore locale matches its stored dashed form', () async {
      // The backend normalizes `_`->`-` before intersecting, so pt_BR is a
      // language the project HAS. Rejecting it would break a working call.
      final code = await runnerWith(languages: const [
        {'code': 'en', 'name': 'English', 'isBase': true, 'fillMode': 'ai'},
        {'code': 'pt-br', 'name': 'Portuguese (Brazil)', 'isBase': false,
          'fillMode': 'ai'},
      ]).run(['--config', writeConfig(), 'push', '--yes', '--lang', 'pt_BR']);
      expect(code, 0, reason: out.toString());
      expect(translateCalls(), isNotEmpty);
    });

    test('naming only the base language fails locally', () async {
      // The base is never a fill target: the server intersects it away and
      // answers 400 no_target_langs. That is the rejection worth pre-empting.
      await expectLater(
        runnerWith().run(
            ['--config', writeConfig(), 'push', '--yes', '--lang', 'en']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('no_target_langs'))),
      );
      expect(translateCalls(), isEmpty);
    });

    test('the base alongside a real target only warns', () async {
      final code = await runnerWith().run([
        '--config', writeConfig(), 'push', '--yes',
        '--lang', 'en', '--lang', 'fr',
      ]);
      expect(code, 0, reason: out.toString());
      expect(err.toString(), contains('Ignoring the base language'));
      expect(translateCalls(), isNotEmpty);
    });

    test('a malformed 200 from /meta does not break the push', () async {
      // A body that parses as JSON but not as a meta fails as a
      // FatalCliException (#972) — the best-effort promise has to cover it.
      // (Green before and after that fix: the catch is blanket either way, so
      // this test anchors the promise, not the parsing change.)
      final code = await runnerWith(metaBody: '[]')
          .run(['--config', writeConfig(), 'push', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(translateCalls(), isNotEmpty);
    });

    test('--publish with nothing to extract ignores --lang', () async {
      // The empty-units path never translates, so `--lang` is inert there;
      // validating it would block a publish that used to work.
      writeSource('lib/a.dart', 'void f() {}\n');
      final code = await runnerWith()
          .run(['--config', writeConfig(), 'push', '--publish', '--yes',
                '--lang', 'de']);
      expect(code, 0, reason: out.toString());
    });

    test('a manual language named explicitly is refused locally', () async {
      await expectLater(
        runnerWith(languages: const [
          {'code': 'en', 'name': 'English', 'isBase': true, 'fillMode': 'ai'},
          {'code': 'fr', 'name': 'French', 'isBase': false,
            'fillMode': 'manual'},
        ]).run(['--config', writeConfig(), 'push', '--yes', '--lang', 'fr']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('Set to manual translation: fr'))),
      );
      expect(translateCalls(), isEmpty);
    });

    test('a manual language in the DEFAULT set only warns', () async {
      final code = await runnerWith(languages: const [
        {'code': 'en', 'name': 'English', 'isBase': true, 'fillMode': 'ai'},
        {'code': 'fr', 'name': 'French', 'isBase': false,
          'fillMode': 'manual'},
      ]).run(['--config', writeConfig(), 'push', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(err.toString(), contains('Skipping fr'));
      // Not naming it is not asking for it: the push still runs.
      expect(translateCalls(), isNotEmpty);
    });

    test('a key that cannot read /meta still pushes', () async {
      // `push` needs `translate`; `/meta` needs `read`. A narrower key must
      // degrade to the old behaviour, not break the command.
      final code = await runnerWith(metaStatus: 403)
          .run(['--config', writeConfig(), 'push', '--yes', '--lang', 'de']);
      expect(code, 0, reason: out.toString());
      expect(translateCalls(), isNotEmpty);
    });

    test('an empty catalogue validates nothing', () async {
      // An older server sends no `languages`; treating that as "the project
      // has none" would reject every --lang.
      final code = await runnerWith(languages: const [])
          .run(['--config', writeConfig(), 'push', '--yes', '--lang', 'de']);
      expect(code, 0, reason: out.toString());
      expect(translateCalls(), isNotEmpty);
    });
  });

  test(
    'a @handle/slug config resolves, then keys the lockfile by the id',
    () async {
      final configFile = p.join(dir.path, 'easyi18n.yaml');
      File(configFile).writeAsStringSync('workspace: acme\nproject: dogfood\n');
      writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/v1/projects/resolve') {
            return http.Response(
              jsonEncode({'projectId': 'proj_abc', 'workspaceId': 'ws_1'}),
              200,
            );
          }
          if (req.url.path.endsWith('/meta')) {
            return http.Response(
              jsonEncode({'baseCode': 'en', 'outputFormatsApiVersion': 1, 'currentVersionId': 'v1', 'formats': ['arb']}),
              200,
            );
          }
          final units = (jsonDecode(req.body)['units'] as List)
              .cast<Map<String, dynamic>>();
          final dryRun = req.url.queryParameters['dryRun'] == 'true';
          return http.Response(
            jsonEncode({
              'dryRun': dryRun,
              'trackingToken': dryRun ? null : 'job_1',
              'estimatedCredits': 0,
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
                    'translated': ['fr'],
                    'pending': <String>[],
                  },
              ],
            }),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PushCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
        ),
      );

      final code = await runner.run(['--config', configFile, 'push', '--yes']);
      expect(code, 0);
      expect(requests.first.url.path, '/v1/projects/resolve');
      // The lockfile carries the RESOLVED opaque id, not the handle ref.
      final lockJson =
          jsonDecode(lockFile().readAsStringSync()) as Map<String, dynamic>;
      expect(lockJson['project'], 'proj_abc');
    },
  );

  for (final stop in ['success', 'poll', 'retry', 'wait', 'publish']) {
    test('publish lifecycle closes the client after $stop', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final failure = StateError('interrupted $stop');
      var translateCount = 0;
      var publishCount = 0;
      late _CloseTrackingClient httpClient;
      httpClient = _CloseTrackingClient((request) async {
        expect(httpClient.closes, 0);
        if (request.url.path.endsWith('/meta')) {
          return http.Response('{}', 403);
        }
        if (request.url.path.endsWith('/publish')) {
          publishCount++;
          if (stop == 'publish') throw failure;
          return http.Response(jsonEncode({
            'versionId': 'published-final', 'keyCount': 1,
          }), 201);
        }
        translateCount++;
        if ((stop == 'poll' && translateCount == 2) ||
            (stop == 'retry' && translateCount == 3)) {
          throw failure;
        }
        return http.Response(jsonEncode({
          'estimatedCredits': stop == 'retry' && translateCount == 2 ? 10 : 0,
          'balance': 1000,
          'units': [{
            'key': 'hello', 'outcome': 'matched',
            'pending': translateCount == 1 || stop == 'wait' || stop == 'retry'
                ? ['fr'] : [],
          }],
        }), 200);
      });
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config')
        ..addCommand(PushCommand(
          output: CliOutput(logger: logger),
          environment: const {'EASYI18N_TOKEN': 'eik_test'},
          apiClientFactory: ({required baseUrl, required token}) =>
              TranslationsApiClient(baseUrl: baseUrl, token: token,
                  httpClient: httpClient),
          wait: (_) async => throw failure,
        ));
      final run = runner.run(['--config', config, 'push', '--publish', '--yes']);
      if (stop == 'success') {
        expect(await run, 0);
        expect(out.toString(), contains('Published published-final (1 key(s))'));
      } else {
        await expectLater(run, throwsA(same(failure)));
        expect(out.toString(), isNot(contains('Published ')));
      }
      expect(httpClient.closes, 1);
      expect(translateCount, stop == 'retry' ? 3 : 2);
      expect(publishCount, stop == 'success' || stop == 'publish' ? 1 : 0);
    });
  }

  test('dry-run estimates without a real push or a lockfile write', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    final code = await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--dry-run',
    ]);

    expect(code, 0);
    expect(translateCalls().length, 1);
    expect(translateCalls().single.url.queryParameters['dryRun'], 'true');
    expect(lockFile().existsSync(), isFalse);
    expect(out.toString(), contains('need translation'));
  });

  test('--max-credits below the estimate aborts before pushing', () async {
    // The flag is read in CREDITS while the API estimate is millicredits:
    // the mock prices this push at 10 mc (0.01 cr), so 0.005 cr must abort.
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    await expectLater(
      runnerWith().run([
        '--config',
        writeConfig(),
        'push',
        '--yes',
        '--max-credits',
        '0.005',
      ]),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('max-credits'),
        ),
      ),
    );
    // Only the dry-run happened; no real push.
    expect(translateCalls().length, 1);
  });

  test('--max-credits above the estimate lets the push through', () async {
    // 5 credits = 5000 mc ceiling vs a 10 mc estimate. Before the units fix
    // this compared 5 against 10 raw mc and aborted a run 500× under budget.
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    final code = await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--yes',
      '--max-credits',
      '5',
    ]);
    expect(code, 0);
    expect(translateCalls().length, 2); // dry-run + real push
  });

  test('the cost preview prints credits, not raw millicredits', () async {
    writeSource('lib/main.dart', '''
void build(c) {
  c.tr('Hello');
  c.tr('World');
}
''');
    final code = await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--dry-run',
    ]);
    expect(code, 0);
    // 2 units × 10 mc = 20 mc → "<0.1"; balance 1000 mc → "1".
    expect(out.toString(), contains('~<0.1 credit(s) (available 1).'));
  });

  // #653 — affordability is a question about what this push can SPEND. A fill
  // already in flight holds credits it cannot touch, so judging against the
  // workspace total previews a green dry run for a push the server will 402.
  group('affordability judges availability, not the total', () {
    test('a dry run fails when a live hold puts the estimate out of reach',
        () async {
      writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
      // 1 unit x 10 mc = 10 mc estimated. The total covers it; what is left
      // after the in-flight reservation does not.
      final code = await runnerWith(balance: 1000, availableCredits: 5)
          .run(['--config', writeConfig(), 'push', '--dry-run']);
      expect(code, 1);
      expect(out.toString(), contains('available <0.1'));
    });

    test('the same estimate passes once nothing is reserved', () async {
      writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
      final code = await runnerWith(balance: 1000, availableCredits: 1000)
          .run(['--config', writeConfig(), 'push', '--dry-run']);
      expect(code, 0);
    });

    test('an older server that omits the field still judges on its balance',
        () async {
      writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
      final code = await runnerWith(balance: 1000)
          .run(['--config', writeConfig(), 'push', '--dry-run']);
      expect(code, 0);
      expect(out.toString(), contains('available 1'));
    });
  });

  test('a declined confirmation aborts without a real push', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    final code = await runnerWith(
      confirm: false,
    ).run(['--config', writeConfig(), 'push']);

    expect(code, 0);
    expect(translateCalls().length, 1); // dry-run only
    expect(out.toString(), contains('Aborted'));
    expect(lockFile().existsSync(), isFalse);
  });

  test('a 1:1 copy-edit carries the previous source on every request', () async {
    File(lockFile().path).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'project': 'proj_abc',
        'units': [{'source': 'Hello'}],
      }),
    );
    writeSource('lib/main.dart', "void f(c) => c.tr('Hello!');\n");

    expect(await runnerWith().run(['--config', writeConfig(), 'push', '--yes']), 0);
    // The preview and the real push alike: the backend keeps the key only if
    // BOTH see the rename, and the preview prices the cheap cascade.
    final calls = translateCalls();
    expect(calls, hasLength(2));
    for (final call in calls) {
      final unit = (jsonDecode(call.body)['units'] as List).single;
      expect(unit['source'], 'Hello!');
      expect(unit['previousSource'], 'Hello');
    }
  });

  test('reports orphans and --prune drops them from the lockfile', () async {
    Lockfile.fromExtraction('proj_abc', []).write(lockFile());
    // Seed a lockfile with a string that is NOT in the source.
    File(lockFile().path).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'project': 'proj_abc',
        'units': [
          {'source': 'Gone'},
          {'source': 'Hi'},
        ],
      }),
    );
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

    await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--yes',
      '--prune',
    ]);

    expect(out.toString(), contains('orphan'));
    final lock = Lockfile.loadOrEmpty(lockFile(), project: 'x');
    expect(lock.units.map((u) => u.source), ['Hi']);
  });

  test('without --prune, orphans stay in the lockfile', () async {
    File(lockFile().path).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'project': 'proj_abc',
        'units': [
          {'source': 'Gone'},
        ],
      }),
    );
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

    await runnerWith().run(['--config', writeConfig(), 'push', '--yes']);

    final lock = Lockfile.loadOrEmpty(lockFile(), project: 'x');
    expect(lock.units.map((u) => u.source).toSet(), {'Gone', 'Hi'});
  });

  test('warns about non-literal tr() calls', () async {
    writeSource('lib/main.dart', '''
void f(c, name) {
  c.tr('Hi');
  c.tr(name);
}
''');
    await runnerWith().run(['--config', writeConfig(), 'push', '--yes']);
    expect(err.toString(), contains('non-literal source'));
  });

  test('no extractable strings → nothing to push, no network', () async {
    writeSource('lib/main.dart', 'void f() {}\n');
    final code = await runnerWith().run([
      '--config',
      writeConfig(),
      'push',
      '--yes',
    ]);
    expect(code, 0);
    expect(requests, isEmpty);
    expect(out.toString(), contains('Nothing to push'));
  });

  test('a numeric lock project keeps its units in an offline push', () async {
    final config = p.join(dir.path, 'easyi18n.yaml');
    File(config).writeAsStringSync('workspace: acme\nproject: demo\n');
    lockFile().writeAsStringSync(jsonEncode({
      'version': 1,
      'project': 123,
      'units': [
        {'source': 'Gone'},
      ],
    }));
    writeSource('lib/a.dart', 'void main() {}\n');

    final code = await runnerWith(environment: const {})
        .run(['--config', config, 'push']);

    expect(code, 0);
    expect(out.toString(), contains('1 orphan(s)'));
    expect(out.toString(), contains('Nothing to push'));
    expect(requests, isEmpty);
  });

  test('missing token throws before any network', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");
    await expectLater(
      runnerWith(
        environment: const {},
      ).run(['--config', writeConfig(), 'push']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('EASYI18N_TOKEN'),
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  group('--publish', () {
    /// Stateful fake mirroring the backend's dry-run semantics:
    /// - a lang left IN FLIGHT by an earlier push counts in `pending` but is
    ///   free to re-estimate (estimatedCredits == 0);
    /// - a FAILED lang is re-queued, so it is both pending AND priced.
    ///
    /// [startPending] seeds in-flight langs before this run's push;
    /// [pollsUntilDone] is how many polls the fill takes; [failAfterPush]
    /// makes the fill settle as failed instead of translated;
    /// [recoverOnRetry] lets the SECOND real push (the CLI's re-queue of the
    /// failed strings) land, so the fill completes after one retry.
    CommandRunner<int> publishRunner({
      int pollsUntilDone = 1,
      bool startPending = false,
      bool failAfterPush = false,
      bool recoverOnRetry = false,
      String? projectMode,
      Map<String, Object?>? publishBody,
      required List<String> publishBodies,
    }) {
      var pushed = startPending;
      var realPushes = 0;
      var polls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path.endsWith('/publish')) {
            publishBodies.add(req.body);
            return http.Response(
              jsonEncode(
                publishBody ??
                    const {'versionId': '2026.07.09.9', 'keyCount': 3},
              ),
              201,
            );
          }
          if (req.url.path.endsWith('/meta')) {
            return http.Response(
              jsonEncode({
                'baseCode': 'en',
                'mode': projectMode,
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
          var priced = !pushed; // an unregistered lang needs a paid fill
          if (dryRun && pushed) {
            polls++;
            if (polls >= pollsUntilDone) {
              if (failAfterPush && !(recoverOnRetry && realPushes >= 2)) {
                priced = true; // failed → re-queued, so it costs again
              } else {
                pending = [];
              }
            }
          }
          if (!dryRun) realPushes++;
          if (!dryRun) pushed = true;
          return http.Response(
            jsonEncode({
              'dryRun': dryRun,
              'trackingToken': dryRun ? null : 'job_1',
              'estimatedCredits': priced ? units.length * 10 : 0,
              'balance': 1000,
              'accepted': true,
              'units': [
                for (final u in units)
                  {
                    'key': 'k_${u['source']}',
                    'outcome': 'created',
                    'translated': <String>[],
                    'pending': pending,
                  },
              ],
            }),
            200,
          );
        }),
      );

      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PushCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
          wait: (_) async {},
        ),
      );
      return runner;
    }

    Future<CliException> emptyRequireCompleteError(
      String config, {
      String sourceDir = 'lib',
    }) async {
      final publishBodies = <String>[];
      try {
        await publishRunner(publishBodies: publishBodies).run([
          '--config',
          config,
          'push',
          '--source-dir',
          sourceDir,
          '--publish',
          '--require-complete',
          '--yes',
        ]);
      } on CliException catch (error) {
        expect(error.exitCode, 1);
        expect(requests, isEmpty);
        expect(publishBodies, isEmpty);
        return error;
      }
      fail('The empty --require-complete push should fail.');
    }

    test('pushes, waits for the fill, then publishes', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(
        pollsUntilDone: 2,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('Waiting for the AI fill'));
      expect(o, contains('Fill complete.'));
      expect(o, contains('Published 2026.07.09.9 (3 key(s))'));
      expect(publishBodies, hasLength(1));
      expect(jsonDecode(publishBodies.single), isEmpty);
    });

    test('a Mode A config publishes with an explicit incompleteMode skip '
        '(#415)', () async {
      // The yaml's mode is not synced with the dashboard's Project.mode, so
      // the CLI says skip explicitly instead of trusting the server-side
      // default to agree with the local declaration.
      final config = writeConfig(mode: 'a');
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(publishBodies: publishBodies)
          .run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(
        jsonDecode(publishBodies.single),
        equals({'incompleteMode': 'skip', 'requiredOutputFormat': 'arb'}),
      );
    });

    test('warns when the local mode and the project mode disagree (#415)',
        () async {
      // Local A + remote B: the local config wins for THIS push (explicit
      // skip), so the warning is about every other surface baking source
      // text into files the yaml says are TMS-owned.
      final config = writeConfig(mode: 'a');
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final code = await publishRunner(
        publishBodies: <String>[],
        projectMode: 'b',
      ).run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(err.toString(), contains('Mode mismatch'));
      expect(err.toString(), contains('bake source text'));
    });

    test('warns the other way when only the dashboard says Mode A (#415)',
        () async {
      // The dangerous direction: nothing local declares TMS, so push omits
      // incompleteMode and the server resolves it to skip — strings vanish
      // from the files instead of serving source text.
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final code = await publishRunner(
        publishBodies: <String>[],
        projectMode: 'a',
      ).run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(err.toString(), contains('Mode mismatch'));
      expect(err.toString(), contains('LEFT OUT'));
    });

    test('an undeclared project mode is no mismatch for a local Mode B',
        () async {
      // Undeclared already behaves as Mode B server-side, so warning here
      // would fire on every project created before the field existed.
      final config = writeConfig(mode: 'b');
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final code = await publishRunner(publishBodies: <String>[])
          .run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(err.toString(), isNot(contains('Mode mismatch')));
    });

    test('a Mode B config keeps omitting incompleteMode (#415)', () async {
      // Omitted lets the server resolve by the project's declared mode — if
      // the dashboard says Mode A while the yaml says b, the safe default
      // still wins server-side.
      final config = writeConfig(mode: 'b');
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(publishBodies: publishBodies)
          .run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(jsonDecode(publishBodies.single), isEmpty);
    });

    test('--approved-only is forwarded to the publish call', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(publishBodies: publishBodies).run([
        '--config',
        config,
        'push',
        '--publish',
        '--approved-only',
        '--yes',
      ]);
      expect(code, 0, reason: out.toString());
      expect(jsonDecode(publishBodies.single), equals({'approvedOnly': true}));
    });

    test('already-translated push publishes without waiting', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      // First run pushes + publishes; the second preview then sees 0 pending
      // and must publish directly, without the fill wait.
      final runner = publishRunner(publishBodies: publishBodies);
      var code = await runner.run([
        '--config',
        config,
        'push',
        '--publish',
        '--yes',
      ]);
      expect(code, 0, reason: out.toString());
      out.clear();
      publishBodies.clear();
      code = await runner.run([
        '--config',
        config,
        'push',
        '--publish',
        '--yes',
      ]);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('Everything is already translated.'));
      expect(o, isNot(contains('Waiting for the AI fill')));
      expect(publishBodies, hasLength(1));
    });

    test('waits for a fill left in flight by an EARLIER push', () async {
      // The regression: those langs are pending but free, so the estimate is
      // 0 - publishing on that signal would bake base text (friction F2).
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      // The preview itself consumes one poll; the fill lands on the third.
      final code = await publishRunner(
        startPending: true,
        pollsUntilDone: 3,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      final o = out.toString();
      expect(code, 0, reason: o);
      expect(o, contains('still being translated from an earlier push'));
      expect(o, contains('Waiting for the AI fill'));
      expect(o, contains('Fill complete.'));
      expect(publishBodies, hasLength(1));
    });

    test('a failed fill is re-queued, and stragglers no longer block the '
        'publish (the B2/B3 postmortem)', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(
        failAfterPush: true,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      final o = out.toString();
      final e = err.toString();
      expect(code, 0, reason: '$o\n$e');
      // Initial push + 2 re-queues of the failed string.
      expect(
        requests
            .where((r) =>
                r.url.path.endsWith('/translate') &&
                r.url.queryParameters['dryRun'] != 'true')
            .length,
        3,
      );
      expect(e, contains('re-queueing'));
      expect(e, contains('publishing anyway'));
      expect(publishBodies, hasLength(1));
    });

    test('a failed fill that recovers on the re-queue publishes complete',
        () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(
        failAfterPush: true,
        recoverOnRetry: true,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      final o = out.toString();
      final e = err.toString();
      expect(code, 0, reason: '$o\n$e');
      expect(e, contains('re-queueing'));
      expect(e, isNot(contains('publishing anyway')));
      expect(o, contains('Fill complete.'));
      expect(publishBodies, hasLength(1));
    });

    test('--require-complete restores the all-or-nothing behaviour', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      await expectLater(
        publishRunner(
          failAfterPush: true,
          publishBodies: publishBodies,
        ).run([
          '--config',
          config,
          'push',
          '--publish',
          '--require-complete',
          '--yes',
        ]),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains('Nothing was published'),
          ),
        ),
      );
      expect(publishBodies, isEmpty);
    });

    test('--require-complete without --publish is rejected', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      await expectLater(
        publishRunner(
          publishBodies: [],
        ).run(['--config', config, 'push', '--require-complete', '--yes']),
        throwsA(isA<CliException>()),
      );
    });

    test(
      'push --publish --require-complete refuses a mispointed source-dir '
      'before any request',
      () async {
        final config = writeConfig();
        writeSource('lib/main.dart', "void f(c) => c.tr('Real source');\n");
        final error = await emptyRequireCompleteError(
          config,
          sourceDir: 'mispointed',
        );
        expect(error.message, contains('no extractable tr() strings'));
        expect(error.message, contains('--require-complete'));
        expect(error.message, contains('cannot verify'));
        expect(error.message, contains('Nothing was published'));
        expect(error.message, contains('--source-dir'));
        expect(error.message, isNot(contains('sync --require-complete')));
        expect(error.message, isNot(contains('Mode A')));
      },
    );

    test('empty canonical Mode A has no CLI completeness path', () async {
      final error = await emptyRequireCompleteError(writeConfig(mode: 'a'));
      expect(error.message, contains('Mode A'));
      expect(error.message, contains('pull --require-complete'));
      expect(error.message, isNot(contains('dashboard')),
          reason: 'the gate exists now (#1052); the remedy names it');
      expect(error.message, isNot(contains('sync --require-complete')));
      expect(error.message, isNot(contains('--source-dir')));
    });

    test('missing Mode A catalog is not a CLI completeness path', () async {
      final error = await emptyRequireCompleteError(
        writeConfig(mode: 'a', format: 'xcstrings'),
      );
      expect(error.message, contains('pull --require-complete'));
      expect(error.message, isNot(contains('sync --require-complete')));
    });

    test('empty Mode A catalog is not a CLI completeness path', () async {
      final error = await emptyRequireCompleteError(
        writeConfig(mode: 'a', format: 'xcstrings', catalog: ''),
      );
      expect(error.message, contains('pull --require-complete'));
      expect(error.message, isNot(contains('sync --require-complete')));
    });

    test('per-locale Mode A catalog is not a CLI completeness path',
        () async {
      writeSource('translations.arb', '{}\n');
      final error = await emptyRequireCompleteError(
        writeConfig(
          mode: 'a',
          format: 'arb',
          catalog: 'translations.arb',
        ),
      );
      expect(error.message, contains('pull --require-complete'));
      expect(error.message, isNot(contains('sync --require-complete')));
    });

    // `sync` uploads the base file of a per-locale project, so it is the
    // push-side gate of one; `catalog:` on that format still is not.
    test('a Mode A project with source: is recommended sync completeness',
        () async {
      writeSource('public/i18n/en.json', '{}\n');
      final error = await emptyRequireCompleteError(
        writeConfig(mode: 'a', format: 'json', source: 'public/i18n/en.json'),
      );
      expect(error.message, contains('sync --require-complete'));
      expect(error.message, isNot(contains('pull --require-complete')));
    });

    // `/v1/sync` takes no ARB: a gen_l10n template under `source:` only keeps
    // pull off the file (#2343).
    test('a Mode A ARB template under source: is not a sync path', () async {
      writeSource('lib/l10n/app_en.arb', '{}\n');
      final error = await emptyRequireCompleteError(
        writeConfig(mode: 'a', format: 'arb', source: 'lib/l10n/app_en.arb'),
      );
      expect(error.message, contains('pull --require-complete'));
      expect(error.message, isNot(contains('sync --require-complete')));
    });

    test('catalog-backed Mode A recommends sync completeness', () async {
      writeSource('Localizable.xcstrings', '{}\n');
      final error = await emptyRequireCompleteError(
        writeConfig(
          mode: 'a',
          format: 'xcstrings',
          catalog: 'Localizable.xcstrings',
        ),
      );
      expect(error.message, contains('sync --require-complete'));
      expect(error.message, isNot(contains('pull --require-complete')));
      expect(error.message, isNot(contains('--source-dir')));
      expect(error.message, contains('Nothing was published'));
    },
    );

    test('catalogs-backed Mode A recommends sync completeness (#590)', () async {
      final error = await emptyRequireCompleteError(
        writeConfig(
          mode: 'a',
          format: 'xcstrings',
          catalogs: ['Localizable.xcstrings', 'AppShortcuts.xcstrings'],
        ),
      );
      expect(error.message, contains('sync --require-complete'));
      expect(error.message, isNot(contains('pull --require-complete')));
    });

    test('catalogs on a per-locale format are not a completeness path (#590)',
        () async {
      final error = await emptyRequireCompleteError(
        writeConfig(mode: 'a', format: 'arb', catalogs: ['a.arb', 'b.arb']),
      );
      expect(error.message, contains('pull --require-complete'));
      expect(error.message, isNot(contains('sync --require-complete')));
    });

    test(
      '--publish --prune with no strings never touches the lockfile',
      () async {
        final config = writeConfig();
        lockFile().writeAsStringSync(
          jsonEncode({
            'project': 'proj_abc',
            'units': [
              {'source': 'Hello', 'ctx': null},
            ],
          }),
        );
        final before = lockFile().readAsStringSync();
        final publishBodies = <String>[];
        final code = await publishRunner(
          publishBodies: publishBodies,
        ).run(['--config', config, 'push', '--publish', '--prune', '--yes']);
        expect(code, 0, reason: out.toString());
        expect(out.toString(), contains('publishing the current state'));
        expect(lockFile().readAsStringSync(), before);
        expect(publishBodies, hasLength(1));
      },
    );

    test('an in-flight fill from an earlier push still publishes skip on a '
        'Mode A config (#415)', () async {
      // Three run() paths reach client.publish; this is the estimate-zero one
      // (nothing new to charge, langs left pending by an earlier push). It
      // shipped without the mode wiring while the other two had it.
      final config = writeConfig(mode: 'a');
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await publishRunner(
        startPending: true,
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(
        jsonDecode(publishBodies.single),
        equals({'incompleteMode': 'skip', 'requiredOutputFormat': 'arb'}),
      );
    });

    test('the no-strings publish path also says skip on a Mode A config '
        '(#415)', () async {
      // Three run() paths reach client.publish; a Mode A repo with zero tr()
      // strings takes this one (push_command's empty-units early exit).
      final config = writeConfig(mode: 'a');
      final publishBodies = <String>[];
      final code = await publishRunner(publishBodies: publishBodies)
          .run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: out.toString());
      expect(out.toString(), contains('publishing the current state'));
      expect(
        jsonDecode(publishBodies.single),
        equals({'incompleteMode': 'skip', 'requiredOutputFormat': 'arb'}),
      );
    });

    test('--approved-only without --publish is rejected', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      await expectLater(
        publishRunner(
          publishBodies: [],
        ).run(['--config', config, 'push', '--approved-only', '--yes']),
        throwsA(isA<CliException>()),
      );
    });

    test('--publish with --dry-run is rejected', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      await expectLater(
        publishRunner(
          publishBodies: [],
        ).run(['--config', config, 'push', '--publish', '--dry-run']),
        throwsA(isA<CliException>()),
      );
    });

    // #609: the response carries TWO rejection lists and the CLI read one, so
    // a markdown/html translation the parity gate refused shipped as the
    // incomplete-mode fallback with nothing in the log naming the key.
    group('rejection lists (#609)', () {
      /// stdout ALONE — the itemized rows are warnings, so this is what a
      /// CI log that captured only stdout sees.
      Future<String> publishStdout(Map<String, Object?> body) async {
        final config = writeConfig();
        writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
        final code = await publishRunner(publishBody: body, publishBodies: [])
            .run(['--config', config, 'push', '--publish', '--yes']);
        expect(code, 0, reason: out.toString());
        return out.toString();
      }

      Future<String> publishWith(Map<String, Object?> body) async {
        final config = writeConfig();
        writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
        final code = await publishRunner(publishBody: body, publishBodies: [])
            .run(['--config', config, 'push', '--publish', '--yes']);
        expect(code, 0, reason: out.toString());
        return out.toString() + err.toString();
      }

      test('a markupRejected entry is printed and names the key', () async {
        final o = await publishWith({
          'versionId': '2026.07.09.9',
          'keyCount': 3,
          'markupRejected': ['welcome.title [fr]: bold span dropped'],
        });
        expect(o, contains('welcome.title [fr]: bold span dropped'));
        expect(o, contains('markup'));
      });

      test('both lists are printed under their own heading', () async {
        final o = await publishWith({
          'versionId': '2026.07.09.9',
          'keyCount': 3,
          'icuRejected': ['cart.count [fr]: plural without other'],
          'markupRejected': ['welcome.title [fr]: bold span dropped'],
        });
        expect(o, contains('cart.count [fr]: plural without other'));
        expect(o, contains('welcome.title [fr]: bold span dropped'));
        expect(o, contains('failed ICU validation'));
        expect(o, contains("lost the source's markup"));
      });

      // The arrays are capped at 50 server-side and the real count rides
      // alongside; counting the lines received under-reports the damage
      // exactly on the publishes that have the most of it.
      test('the printed count is the server total, not the capped list',
          () async {
        final o = await publishWith({
          'versionId': '2026.07.09.9',
          'keyCount': 3,
          'markupRejected': ['a [fr]: x', 'b [fr]: y'],
          'markupRejectedTotal': 120,
          'icuRejected': ['c [fr]: z'],
          'icuRejectedTotal': 7,
        });
        // The whole heading, not its head: the clause that was false — and
        // that #1000 replaced — is the TAIL, so an assertion stopping at
        // "markup" lets a revert back to "fell back to the incomplete mode"
        // stay green.
        expect(
          o,
          contains("120 cell(s) lost the source's markup structure and did "
              'not reach the published version:'),
        );
        expect(o, contains('118 more'));
        expect(
          o,
          contains('7 cell(s) failed ICU validation and did not reach the '
              'published version:'),
        );
        expect(o, contains('6 more'));
      });

      // A pre-cap server sends the list without its total: its length IS the
      // total, and inventing a "...and N more" line off a missing field would
      // be a lie in the other direction.
      test('a response without the totals reports the list length', () async {
        final o = await publishWith({
          'versionId': '2026.07.09.9',
          'keyCount': 3,
          'markupRejected': ['a [fr]: x', 'b [fr]: y'],
        });
        expect(
          o,
          contains("2 cell(s) lost the source's markup structure and did "
              'not reach the published version:'),
        );
        expect(o, isNot(contains('more')));
      });

      // The rows are warnings; a run whose stdout is captured alone used to
      // read as a clean publish. The count rides on the success line.
      test('the success line on stdout carries the refusal count', () async {
        final o = await publishStdout({
          'versionId': '2026.07.09.9',
          'keyCount': 3,
          'markupRejected': ['a [fr]: x'],
          'markupRejectedTotal': 120,
          'icuRejected': ['c [fr]: z'],
          'icuRejectedTotal': 7,
        });
        // `cell(s)` (#1175): the count mixes refused target cells with
        // refused base SOURCES, and it is the server's total — rows the
        // 50-row cap kept off this side included — so the noun has to be
        // true of what this side cannot read.
        expect(o, contains('Published 2026.07.09.9 (3 key(s)) — 127 '
            'cell(s) refused by a gate, see the warnings.'));
        expect(o, isNot(contains('translation(s) refused')));
      });

      test('a clean publish says nothing about either gate', () async {
        final o = await publishWith({
          'versionId': '2026.07.09.9',
          'keyCount': 3,
        });
        expect(o, isNot(contains('markup')));
        expect(o, isNot(contains('ICU')));
        expect(o, isNot(contains('refused')));
        expect(o, contains('Published 2026.07.09.9 (3 key(s)). Live via'));
      });
    });
  });

  // #752 — the server keeps an exhausted pair OUT of `pending` (the engine
  // will never fill it), so a client that only reads `pending` saw a complete
  // catalog, printed "Everything is already translated.", and published the
  // pair as source text — under the very flag whose job is to refuse that.
  group('exhausted pairs (#752)', () {
    /// A push runner whose /translate mock is fully scripted per call.
    /// [translate] receives (dryRun, units, nth translate call) and returns
    /// the response body; unit rows should copy the backend's unitView shape
    /// (`public_api.dart` — `exhausted` omitted when empty).
    CommandRunner<int> scriptedRunner({
      required Map<String, Object?> Function(
        bool dryRun,
        List<Map<String, dynamic>> units,
        int call,
      ) translate,
      required List<String> publishBodies,
    }) {
      var calls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path.endsWith('/publish')) {
            publishBodies.add(req.body);
            return http.Response(
              jsonEncode(const {'versionId': '2026.07.09.9', 'keyCount': 3}),
              201,
            );
          }
          if (req.url.path.endsWith('/meta')) {
            return http.Response(
              jsonEncode({
                'baseCode': 'en',
                'outputFormatsApiVersion': 1, 'currentVersionId': '2026.01.01',
                'formats': ['arb'],
                'languages': const [
                  {'code': 'en', 'name': 'English', 'isBase': true,
                    'fillMode': 'ai'},
                  {'code': 'fr', 'name': 'French', 'isBase': false,
                    'fillMode': 'ai'},
                  {'code': 'de', 'name': 'German', 'isBase': false,
                    'fillMode': 'ai'},
                ],
              }),
              200,
            );
          }
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final units = (body['units'] as List).cast<Map<String, dynamic>>();
          final dryRun = req.url.queryParameters['dryRun'] == 'true';
          calls++;
          return http.Response(
            jsonEncode(translate(dryRun, units, calls)),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PushCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
          wait: (_) async {},
        ),
      );
      return runner;
    }

    /// Backend-shaped response where every unit's fr+de are exhausted:
    /// nothing pending, nothing to charge — the state that used to read as
    /// "complete".
    Map<String, Object?> exhaustedOnly(
      bool dryRun,
      List<Map<String, dynamic>> units,
    ) => {
      'dryRun': dryRun,
      'trackingToken': null,
      'estimatedCredits': 0,
      'balance': 1000,
      'accepted': true,
      'baseCode': 'en',
      'targetLangs': ['fr', 'de'],
      'units': [
        for (final u in units)
          {
            'key': 'k_${u['source']}',
            'token': 't',
            'outcome': 'matched',
            'translated': <String>[],
            'pending': <String>[],
            'exhausted': ['fr', 'de'],
          },
      ],
    };

    test('retry keeps max-credits and stops before remaining batches', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', 'void f(c) {\n${List.generate(1001,
        (i) => "c.tr('Source $i');").join('\n')}\n}');
      final publishBodies = <String>[];
      final realBatchSizes = <int>[];
      var calls = 0;
      await expectLater(scriptedRunner(
        translate: (dryRun, units, call) {
          calls = call;
          if (!dryRun) realBatchSizes.add(units.length);
          return {
            'dryRun': dryRun,
            'trackingToken': dryRun ? null : 'job_$call',
            'estimatedCredits': call >= 10 ? 20000 : 1000,
            'balance': 100000,
            'accepted': true,
            'units': [for (final u in units) {
              'key': 'k_${u['source']}', 'outcome': 'created',
              'translated': <String>[], 'pending': ['fr'],
            }],
          };
        },
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes',
        '--max-credits', '30']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
          contains('completed batches, exceeding --max-credits 30'))));
      expect(calls, 11);
      expect(realBatchSizes, [500, 500, 1, 500, 500]);
      expect(publishBodies, isEmpty);
    });

    test('push --require-complete fails on exhausted pairs', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      await expectLater(
        scriptedRunner(
          translate: (d, u, _) => exhaustedOnly(d, u),
          publishBodies: publishBodies,
        ).run([
          '--config', config, 'push', '--publish', '--require-complete',
          '--yes',
        ]),
        throwsA(isA<CliException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('retry budget is spent'),
            // The ABSOLUTE list, not just the reason: both pairs, in the
            // server's order, and nothing else after them.
            endsWith(': k_Hello [fr], k_Hello [de]'),
          ),
        )),
      );
      // The branch that costs: nothing may be published on the refusal.
      expect(publishBodies, isEmpty);
      expect(
        requests.where((r) => r.url.path.endsWith('/publish')), isEmpty,
      );
    });

    test(
      'push without the flag reports exhausted pairs and does not claim '
      'completion',
      () async {
        final config = writeConfig();
        writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
        final publishBodies = <String>[];
        final code = await scriptedRunner(
          translate: (d, u, _) => exhaustedOnly(d, u),
          publishBodies: publishBodies,
        ).run(['--config', config, 'push', '--publish', '--yes']);
        expect(code, 0, reason: '$out\n$err');
        expect(publishBodies, hasLength(1));
        expect(
          err.toString(),
          contains('Skipped exhausted pair(s) — retry them from the '
              'dashboard: k_Hello [fr], k_Hello [de]'),
        );
        expect(
          out.toString(),
          isNot(contains('Everything is already translated.')),
        );
      },
    );

    test('a zero-estimate push without --publish still names the pairs',
        () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final code = await scriptedRunner(
        translate: (d, u, _) => exhaustedOnly(d, u),
        publishBodies: [],
      ).run(['--config', config, 'push', '--yes']);
      expect(code, 0, reason: '$out\n$err');
      expect(
        err.toString(),
        contains('Skipped exhausted pair(s) — retry them from the '
            'dashboard: k_Hello [fr], k_Hello [de]'),
      );
      expect(
        out.toString(),
        isNot(contains('Everything is already translated.')),
      );
    });

    test('--dry-run with exhausted pairs warns and keeps its exit', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final code = await scriptedRunner(
        translate: (d, u, _) => exhaustedOnly(d, u),
        publishBodies: [],
      ).run(['--config', config, 'push', '--dry-run']);
      // Affordability exit (estimate 0 is affordable), unchanged by #752.
      expect(code, 0, reason: '$out\n$err');
      expect(
        err.toString(),
        contains('Skipped exhausted pair(s) — retry them from the '
            'dashboard: k_Hello [fr], k_Hello [de]'),
      );
    });

    test('exhausted appearing only in the final poll still gates', () async {
      // The #737 case: the run itself burns the pair's retry budget, so the
      // preview was clean and only the poll sees the terminal state. The gate
      // must read the LAST poll, not the preview.
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      var pushed = false;
      await expectLater(
        scriptedRunner(
          translate: (dryRun, units, _) {
            if (!dryRun) pushed = true;
            final done = dryRun && pushed;
            return {
              'dryRun': dryRun,
              'trackingToken': dryRun ? null : 'job_1',
              'estimatedCredits': pushed ? 0 : units.length * 10,
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
                    'pending': done ? <String>[] : ['fr'],
                    if (done) 'exhausted': ['fr'],
                  },
              ],
            };
          },
          publishBodies: publishBodies,
        ).run([
          '--config', config, 'push', '--publish', '--require-complete',
          '--yes',
        ]),
        throwsA(isA<CliException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('retry budget is spent'),
            endsWith(': k_Hello [fr]'),
          ),
        )),
      );
      expect(publishBodies, isEmpty);
    });

    test(
      'a real push without --publish names the exhausted pairs it cannot '
      'deliver',
      () async {
        // Estimate > 0 and no --publish: there is no poll, so the report has
        // to ride on the real push's own response or it happens nowhere.
        final config = writeConfig();
        writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
        final code = await scriptedRunner(
          translate: (dryRun, units, _) => {
            'dryRun': dryRun,
            'trackingToken': dryRun ? null : 'job_1',
            'estimatedCredits': units.length * 10,
            'balance': 1000,
            'accepted': true,
            'baseCode': 'en',
            'targetLangs': ['fr', 'de'],
            'units': [
              for (final u in units)
                {
                  'key': 'k_${u['source']}',
                  'token': 't',
                  'outcome': 'created',
                  'translated': <String>[],
                  'pending': ['fr'],
                  'exhausted': ['de'],
                },
            ],
          },
          publishBodies: [],
        ).run(['--config', config, 'push', '--yes']);
        expect(code, 0, reason: '$out\n$err');
        expect(out.toString(), contains('Translating in the background'));
        expect(
          err.toString(),
          contains('Skipped exhausted pair(s) — retry them from the '
              'dashboard: k_Hello [de]'),
        );
      },
    );

    // Mixed state: fr keeps failing (pending, priced on every poll) while de
    // is exhausted. The MIXTURE is the composition that discriminates — an
    // all-exhausted or all-pending fixture exercises only one gate.
    Map<String, Object?> mixedPendingExhausted(
      bool dryRun,
      List<Map<String, dynamic>> units,
    ) => {
      'dryRun': dryRun,
      'trackingToken': dryRun ? null : 'job_1',
      'estimatedCredits': units.length * 10,
      'balance': 1000,
      'accepted': true,
      'baseCode': 'en',
      'targetLangs': ['fr', 'de'],
      'units': [
        for (final u in units)
          {
            'key': 'k_${u['source']}',
            'token': 't',
            'outcome': 'created',
            'translated': <String>[],
            'pending': ['fr'],
            'exhausted': ['de'],
          },
      ],
    };

    test('with pending AND exhausted, the pending refusal wins and nothing '
        'publishes', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      await expectLater(
        scriptedRunner(
          translate: (d, u, _) => mixedPendingExhausted(d, u),
          publishBodies: publishBodies,
        ).run([
          '--config', config, 'push', '--publish', '--require-complete',
          '--yes',
        ]),
        // The decided precedence: the pending message speaks (same exit
        // either way); the exhausted list is not in this message.
        throwsA(isA<CliException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('1 string(s) did not translate'),
            contains('Nothing was published'),
          ),
        )),
      );
      expect(publishBodies, isEmpty);
    });

    test('with pending AND exhausted and no flag, both warnings surface and '
        'the publish happens once', () async {
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await scriptedRunner(
        translate: (d, u, _) => mixedPendingExhausted(d, u),
        publishBodies: publishBodies,
      ).run(['--config', config, 'push', '--publish', '--yes']);
      expect(code, 0, reason: '$out\n$err');
      expect(publishBodies, hasLength(1));
      final e = err.toString();
      expect(e, contains('publishing anyway'));
      expect(
        e,
        contains('Skipped exhausted pair(s) — retry them from the '
            'dashboard: k_Hello [de]'),
      );
    });

    test('a unit row without the exhausted field neither warns nor gates',
        () async {
      // Negative control, pinning that the server omits the empty field: a
      // complete catalog under --require-complete publishes with no warning.
      final config = writeConfig();
      writeSource('lib/a.dart', "void f(c) => c.tr('Hello');\n");
      final publishBodies = <String>[];
      final code = await scriptedRunner(
        translate: (dryRun, units, _) => {
          'dryRun': dryRun,
          'trackingToken': null,
          'estimatedCredits': 0,
          'balance': 1000,
          'accepted': true,
          'baseCode': 'en',
          'targetLangs': ['fr'],
          'units': [
            for (final u in units)
              {
                'key': 'k_${u['source']}',
                'token': 't',
                'outcome': 'matched',
                'translated': ['fr'],
                'pending': <String>[],
              },
          ],
        },
        publishBodies: publishBodies,
      ).run([
        '--config', config, 'push', '--publish', '--require-complete',
        '--yes',
      ]);
      expect(code, 0, reason: '$out\n$err');
      expect(publishBodies, hasLength(1));
      expect(err.toString(), isNot(contains('exhausted')));
      expect(out.toString(), contains('Everything is already translated.'));
    });
  });
}

class _CloseTrackingClient extends MockClient {
  _CloseTrackingClient(super.handler);
  int closes = 0;

  @override
  void close() {
    closes++;
    super.close();
  }
}
