@TestOn('vm')
library;

import 'dart:convert';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/mcp/deps.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/stored_login.dart';
import 'harness.dart';
import 'server_test.dart' show errorOf, project;

const _pubspec = 'name: app\nflutter:\n  uses-material-design: true\n';

void main() {
  late List<http.Request> requests;
  late int estimateMc;
  late bool overCap;
  late Map<String, Object?> operation;
  // The state each GET of the operation answers, in order; the last one
  // repeats. Empty leaves `operation['state']` alone.
  late List<String> states;
  // What GET /v1/projects/{id}/credential says of a login (#2580 A3).
  late bool loginAsks;
  setUp(() {
    requests = [];
    states = [];
    loginAsks = false;
    estimateMc = 42000;
    overCap = false;
    operation = {
      'operation_id': 'op_1',
      'action': 'translate',
      'state': 'pending_approval',
      'scope': <String, Object?>{},
      'requested_mc': 50000,
      'authorized_mc': 0,
      'reserved_mc': 0,
      'charged_mc': 0,
      'absorbed_mc': 0,
      'approval_url': 'https://app.easyi18n.com/approve/op_1',
      'expires_at': '2026-09-22T16:00:00Z',
      'attempts': <Object?>[],
    };
  });

  Future<http.Response> backend(http.Request req) async {
    requests.add(req);
    if (req.url.path.endsWith('/translate')) {
      final units = (jsonDecode(req.body) as Map)['units'] as List;
      return http.Response(jsonEncode({
        'dryRun': true,
        'batchSha256': (units.length == 500 ? 'a' : 'b') * 64,
        'estimatedCredits': estimateMc,
        'balance': 900000,
        'availableCredits': 900000,
        'accepted': true,
        'wouldExceedKeyCap': overCap,
        'baseCode': 'en',
        'targetLangs': ['fr', 'de'],
        'units': [],
      }), 200);
    }
    if (req.url.path.endsWith('/credential')) {
      return http.Response(jsonEncode({'scopes': ['read', 'translate', 'publish'],
        'requires_operation_approval': loginAsks}), 200);
    }
    if (req.method == 'GET' && states.isNotEmpty) {
      operation['state'] = states.length > 1 ? states.removeAt(0) : states.first;
    }
    return http.Response(jsonEncode(operation), req.method == 'POST' ? 201 : 200);
  }

  Future<CallToolResult> call(Map<String, Object?> arguments, {
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
    int units = 1,
  }) async {
    final fixture = project(
      environment: environment,
      files: {
        'pubspec.yaml': _pubspec,
        'lib/main.dart': [
          for (var i = 0; i < units; i++) "final s$i = tr('String $i');",
        ].join('\n'),
      },
      httpClient: MockClient(backend),
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness.call('authorize', arguments);
  }

  List<http.Request> posts() =>
      [for (final r in requests) if (r.url.path == '/v1/operations') r];

  // Decision 1 of #2579: a login spends and publishes as its human, so
  // authorize mints nothing for it and sends the agent to the action. The
  // server says whether that login needs an approval after all: the flag
  // that turns a login back into a key under D17 (agent-native D3).
  group('with the stored login', () {
    for (final (action, next) in [
      ('translate', 'push'),
      ('publish', 'publish'),
      ('rollback', 'rollback'),
    ]) {
      test('$action mints no operation and sends the agent to $next',
          () async {
        final result = await call({
          'action': action,
          if (action == 'translate') 'max_credits': 51,
        }, environment: loggedInHome());
        expect(result.isError, isNot(true), reason: '${result.structuredContent}');
        expect(result.structuredContent!['next'], next);
        expect(result.structuredContent, isNot(contains('approval_url')));
        expect(posts(), isEmpty);
        expect((result.content.single as TextContent).text,
            contains('Call $next without an operation_id'));
      });
    }

    test('a login the server makes ask gets an operation, as a key does',
        () async {
      loginAsks = true;
      final result = await call({'action': 'publish'},
          environment: loggedInHome());
      expect(posts(), hasLength(1));
      expect(posts().single.headers['authorization'], 'Bearer eip_login');
      expect(result.structuredContent!['approval_url'],
          'https://app.easyi18n.com/approve/op_1');
    });

    test('a key in EASYI18N_TOKEN asks nothing about the login', () async {
      final result = await call({'action': 'publish'},
          environment: loggedInHome(also: {'EASYI18N_TOKEN': 'eik_test'}));
      expect(posts(), hasLength(1));
      expect(result.structuredContent!['approval_url'], isNotNull);
      expect(requests.where((r) => r.url.path.endsWith('/credential')), isEmpty);
    });
  });

  test('neither action nor operation_id is refused before any request',
      () async {
    final result = await call({'max_credits': 10});
    expect(errorOf(result)['code'], 'action_required');
    expect(requests, isEmpty);
  });

  test('translate without max_credits is refused before any request', () async {
    final result = await call({'action': 'translate'});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'max_credits_required');
    expect(requests, isEmpty);
  });

  group('the D7 ceiling', () {
    test('clamps M instead of refusing: ceil(42 x 1.2) = 51 is approved at '
        'the default 50', () async {
      final result = await call({'action': 'translate', 'max_credits': 51});
      expect(result.isError, isNot(true));
      expect(jsonDecode(posts().single.body)['max_credits'], 50);
      expect(result.structuredContent!['max_credits'], 50);
      expect(result.structuredContent!['ceiling'], {'env_max': 50});
    });

    test('a ceiling below the estimate aborts before the POST', () async {
      final result = await call({'action': 'translate', 'max_credits': 51},
          environment: const {
            'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_MCP_MAX_CREDITS': '40',
          });
      expect(errorOf(result)['code'], 'ceiling_below_estimate');
      expect(errorOf(result)['message'], contains('narrow the push with langs'));
      expect(errorOf(result)['env_max'], 40);
      expect(errorOf(result)['estimated_credits'], 42);
      expect(posts(), isEmpty);
    });

    test('a ceiling that covers the estimate exactly is not the one short',
        () async {
      estimateMc = 50000;
      final result = await call({'action': 'translate', 'max_credits': 41});
      expect(errorOf(result)['code'], 'below_estimate');
      expect(posts(), isEmpty);
    });

    test('max_credits at the default ceiling goes through', () async {
      estimateMc = 1000;
      final result = await call({'action': 'translate', 'max_credits': 50});
      expect(result.isError, isNot(true));
      expect(posts(), hasLength(1));
    });

    test('0 disables every paid authorization', () async {
      final result = await call({'action': 'translate', 'max_credits': 1},
          environment: const {
            'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_MCP_MAX_CREDITS': '0',
          });
      expect(errorOf(result)['code'], 'ceiling_below_estimate');
      expect(errorOf(result)['message'], contains('disables'));
      expect(posts(), isEmpty);
    });

    test('the env raises it', () async {
      estimateMc = 1000;
      final result = await call({'action': 'translate', 'max_credits': 80},
          environment: const {
            'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_MCP_MAX_CREDITS': '100',
          });
      expect(result.isError, isNot(true));
      expect(posts(), hasLength(1));
    });

    for (final raw in ['abc', '-5', '1.5']) {
      test('an unreadable value "$raw" fails closed, never the default',
          () async {
        final result = await call({'action': 'translate', 'max_credits': 10},
            environment: {
              'EASYI18N_TOKEN': 'eik_test',
              'EASYI18N_MCP_MAX_CREDITS': raw,
            });
        expect(errorOf(result)['code'], 'invalid_ceiling');
        expect(requests, isEmpty);
      });
    }
  });

  test('the preview it hashes is the push of the langs the agent named',
      () async {
    await call({'action': 'translate', 'max_credits': 50, 'langs': ['fr']});
    final dryRun = requests.firstWhere((r) => r.url.path.endsWith('/translate'));
    expect(jsonDecode(dryRun.body)['langs'], ['fr']);
  });

  for (final estimate in [42000, 0]) {
    test('a push past the plan key cap is plan_limit and mints nothing '
        '(estimate $estimate)', () async {
      overCap = true;
      estimateMc = estimate;
      final result = await call({'action': 'translate', 'max_credits': 50});
      expect(errorOf(result)['code'], 'plan_limit');
      expect(posts(), isEmpty);
    });
  }

  test('a free push has nothing to authorize and mints nothing', () async {
    estimateMc = 0;
    final result = await call({'action': 'translate', 'max_credits': 10});
    expect(errorOf(result)['code'], 'nothing_to_authorize');
    expect(posts(), isEmpty);
  });

  test('an estimate above max_credits is refused before the POST', () async {
    final result = await call({'action': 'translate', 'max_credits': 41});
    expect(errorOf(result)['code'], 'below_estimate');
    expect(errorOf(result)['estimated_credits'], 42);
    expect(posts(), isEmpty);
  });

  const raised = {'EASYI18N_TOKEN': 'eik_test', 'EASYI18N_MCP_MAX_CREDITS': '60'};

  test('an estimate equal to max_credits is authorized at max_credits',
      () async {
    estimateMc = 50000;
    final result = await call({'action': 'translate', 'max_credits': 50},
        environment: raised);
    expect(result.isError, isNot(true));
    expect(jsonDecode(posts().single.body)['max_credits'], 50);
  });

  test('one millicredit above max_credits is refused', () async {
    estimateMc = 50001;
    final result = await call({'action': 'translate', 'max_credits': 50},
        environment: raised);
    expect(errorOf(result)['code'], 'below_estimate');
    expect(posts(), isEmpty);
  });

  test('M is the estimate plus 20 %, rounded up, when max_credits allows it',
      () async {
    final result = await call({'action': 'translate', 'max_credits': 55},
        environment: const {
          'EASYI18N_TOKEN': 'eik_test',
          'EASYI18N_MCP_MAX_CREDITS': '60',
        });
    expect(result.isError, isNot(true));
    // ceil(42 x 1.2) = 51: the case D7 was rewritten for.
    expect(jsonDecode(posts().single.body)['max_credits'], 51);
    expect(result.structuredContent!['max_credits'], 51);
  });

  test('mints the operation over the manifest the dry run hashed', () async {
    // Priced per batch: two batches of 20 credits are C = 40, M = 48.
    estimateMc = 20000;
    final result = await call({'action': 'translate', 'max_credits': 50},
        units: 501);
    expect(result.isError, isNot(true));
    final dryRuns = [
      for (final r in requests)
        if (r.url.path.endsWith('/translate')) r,
    ];
    expect(dryRuns, hasLength(2));
    expect(dryRuns.every((r) => r.url.queryParameters['dryRun'] == 'true'),
        isTrue);
    final body = jsonDecode(posts().single.body) as Map<String, Object?>;
    expect(body, {
      'action': 'translate',
      'max_credits': 48,
      'scope': {
        'project_id': 'proj_abc',
        'langs': ['de', 'fr'],
        'unit_count': 501,
        'batches': [
          {'index': 0, 'sha256': 'a' * 64, 'unit_count': 500},
          {'index': 1, 'sha256': 'b' * 64, 'unit_count': 1},
        ],
        // The backend's ingestBatchSha256 over this manifest, computed with
        // backend/lib/routes/ingest_requests.dart at be2a0a86.
        'payload_sha256':
            'cd420240da59e86bbd2db728cca80b3697b15ad911f646f27f21063d2ad3ecdd',
      },
    });
    expect(result.structuredContent!['operation_id'], 'op_1');
    expect(result.structuredContent!['approval_url'],
        'https://app.easyi18n.com/approve/op_1');
    expect(result.structuredContent!['next'], 'wait');
    expect(result.structuredContent!['ceiling'], {'env_max': 50});
    // Codex ended its turn on the old «then call authorize … to see the
    // approval» (#2446): the result says now, in this turn.
    expect((result.content.single as TextContent).text, allOf(
      contains('Give them the approval_url'),
      contains('in this same turn'),
    ));
    expect([for (final r in requests) if (r.method == 'GET') r], isEmpty,
        reason: 'the creation hands over the link at once, it never waits');
  });

  test('a server without batch hashes cannot be asked for an approval',
      () async {
    final fixture = project(
      files: {'pubspec.yaml': _pubspec, 'lib/main.dart': "final s = tr('A');"},
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(jsonEncode({
          'dryRun': true,
          'estimatedCredits': 1000,
          'balance': 9000,
          'accepted': true,
          'units': [],
        }), 200);
      }),
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    final result = await harness
        .call('authorize', {'action': 'translate', 'max_credits': 10});
    expect(errorOf(result)['code'], 'operations_unsupported');
    expect(posts(), isEmpty);
  });

  group('with operation_id', () {
    test('only reads the operation: no dry run, no POST', () async {
      operation['state'] = 'approved';
      final result = await call({'action': 'translate', 'operation_id': 'op_1'});
      expect(result.isError, isNot(true));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/v1/operations/op_1');
      expect(result.structuredContent!['state'], 'approved');
      expect(result.structuredContent!['next'], 'push');
    });

    // The description and the translate prompt both say to wait for the
    // approval with authorize {operation_id}: the schema lets it through.
    test('reads it without action', () async {
      operation['state'] = 'approved';
      final result = await call({'operation_id': 'op_1'});
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(requests.single.url.path, '/v1/operations/op_1');
      expect(result.structuredContent!['next'], 'push');
    });

    test('a used operation sends the agent back to authorize', () async {
      operation['state'] = 'used';
      final result = await call({'action': 'translate', 'operation_id': 'op_1'});
      expect(result.structuredContent!['next'], 'authorize');
    });

    test('an unknown operation is the server error, not a new operation',
        () async {
      final fixture = project(httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(
            jsonEncode({'error': 'operation_not_found', 'message': 'unknown'}),
            404);
      }));
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness
          .call('authorize', {'action': 'translate', 'operation_id': 'op_x'});
      expect(errorOf(result)['code'], 'operation_not_found');
      expect(errorOf(result)['statusCode'], 404);
      expect(requests.single.method, 'GET');
    });
  });

  // #2446: no measured client turns a server notification into a new turn of
  // the agent, so the human's answer has to reach a call that is still open.
  group('a pending read waits for the human', () {
    final start = DateTime.utc(2026, 10, 28, 12);
    late DateTime now;
    late List<Duration> slept;
    late McpDeps deps;
    setUp(() {
      now = start;
      slept = [];
    });

    Future<McpHarness> server({
      Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
    }) async {
      final fixture = project(
        environment: environment,
        httpClient: MockClient(backend),
        clock: () => now,
        // A timer, not a microtask, so a wait that never ends fails the test
        // instead of hanging the suite.
        sleep: (d) async {
          slept.add(d);
          now = now.add(d);
          if (slept.length > 200) throw StateError('the wait never ends');
          await Future<void>.delayed(Duration.zero);
        },
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      deps = fixture.deps;
      final harness = await McpHarness.start(deps);
      addTearDown(harness.shutdown);
      return harness;
    }

    Future<CallToolResult> read(McpHarness harness) =>
        harness.call('authorize', {'operation_id': 'op_1'});
    String textOf(CallToolResult result) =>
        (result.content.single as TextContent).text;
    int reads() => [for (final r in requests) if (r.method == 'GET') r].length;
    Duration waited() => slept.fold(Duration.zero, (a, b) => a + b);

    test('a slow poll cannot extend the total wait deadline', () async {
      final fixture = project(
        environment: const {
          'EASYI18N_TOKEN': 'eik_test',
          'EASYI18N_MCP_APPROVAL_WAIT_SECONDS': '1',
        },
        httpClient: MockClient((request) async {
          if (requests.isNotEmpty) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          return backend(request);
        }),
        sleep: (_) async {},
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final watch = Stopwatch()..start();
      final result = await read(harness);
      expect(watch.elapsedMilliseconds, lessThan(1500));
      expect(result.structuredContent!['next'], 'ask_human');
    });

    test('a slow initial read returns a retryable error within T', () async {
      final fixture = project(
        environment: const {
          'EASYI18N_TOKEN': 'eik_test',
          'EASYI18N_MCP_APPROVAL_WAIT_SECONDS': '1',
        },
        httpClient: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return backend(request);
        }),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final watch = Stopwatch()..start();
      final result = await read(harness);
      expect(watch.elapsedMilliseconds, lessThan(1500));
      expect(errorOf(result)['code'], 'approval_read_timeout');
      expect(errorOf(result)['retryable'], isTrue);
      expect(result.structuredContent!.containsKey('state'), isFalse);
    });

    test('an operation read does not resolve an unused project handle', () async {
      operation['state'] = 'approved';
      final fixture = project(
        config: 'workspace: example\nproject: app\n',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/operations/op_1');
          return backend(request);
        }),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      expect((await read(harness)).structuredContent!['next'], 'push');
      expect(reads(), 1);
    });

    test('the approval reaches the open call, with no call in between',
        () async {
      states = ['pending_approval', 'pending_approval', 'approved'];
      final result = await read(await server());
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(result.structuredContent!['state'], 'approved');
      expect(result.structuredContent!['next'], 'push');
      expect(reads(), 3);
      expect(slept, [const Duration(seconds: 5), const Duration(seconds: 5)]);
    });

    test('a denial reaches it with its own next, and nothing to report as '
        'charged', () async {
      states = ['pending_approval', 'denied'];
      final result = await read(await server());
      expect(result.structuredContent!['next'], 'stop');
      expect(textOf(result), contains('denied'));
      expect(textOf(result), isNot(contains('Report what it charged')));
    });

    test('an expiry gets a next apart from a denial', () async {
      states = ['pending_approval', 'expired'];
      final result = await read(await server());
      expect(result.structuredContent!['next'], 'reauthorize');
      expect(textOf(result), contains('expired'));
      expect(textOf(result), isNot(contains('Report what it charged')));
    });

    test('a decided operation answers at once', () async {
      states = ['approved'];
      final result = await read(await server());
      expect(result.structuredContent!['next'], 'push');
      expect(reads(), 1);
      expect(slept, isEmpty);
    });

    test('still pending, the call comes back with wait after 45 s, never '
        'later', () async {
      final result = await read(await server());
      expect(result.structuredContent!['next'], 'wait');
      expect(waited(), const Duration(seconds: 45));
      expect(slept, everyElement(lessThanOrEqualTo(const Duration(seconds: 5))));
      expect(reads(), 9);
      expect(textOf(result), contains('again now, in this same turn'));
      expect(textOf(result), isNot(contains('Give them the approval_url')),
          reason: 'the human has the link already; the agent says it once');
    });

    test('ten minutes after this process first saw it, a read stops waiting '
        'at once and says so', () async {
      final harness = await server();
      await read(harness);
      now = start.add(const Duration(minutes: 10));
      slept.clear();
      requests.clear();
      final result = await read(harness);
      expect(result.structuredContent!['state'], 'pending_approval');
      expect(result.structuredContent!['next'], 'ask_human');
      expect(textOf(result), contains('Stop waiting'));
      expect(slept, isEmpty);
      expect(reads(), 1);
      expect(posts(), isEmpty);
    });

    test('a read close to the ten minutes waits only what is left', () async {
      final harness = await server();
      await read(harness);
      // 17 s left: not a multiple of the 5 s poll, so a last sleep that is
      // not cut short shows.
      now = start.add(const Duration(minutes: 9, seconds: 43));
      slept.clear();
      final result = await read(harness);
      expect(result.structuredContent!['next'], 'ask_human');
      expect(waited(), const Duration(seconds: 17));
    });

    test('the ten minutes count from the creation when this process made it',
        () async {
      final harness = await server();
      await harness.call('authorize', {'action': 'publish'});
      expect(posts(), hasLength(1));
      now = start.add(const Duration(minutes: 10));
      final result = await read(harness);
      expect(result.structuredContent!['next'], 'ask_human');
      expect(slept, isEmpty);
    });

    group('EASYI18N_MCP_APPROVAL_WAIT_SECONDS', () {
      Future<McpHarness> withWait(String value) => server(environment: {
            'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_MCP_APPROVAL_WAIT_SECONDS': value,
          });

      test('shortens the ten minutes', () async {
        final harness = await withWait('50');
        expect((await read(harness)).structuredContent!['next'], 'wait');
        slept.clear();
        final result = await read(harness);
        expect(result.structuredContent!['next'], 'ask_human');
        expect(waited(), const Duration(seconds: 5));
      });

      for (final value in ['9999', '', 'soon', '-5']) {
        test('"$value" leaves the ten minutes alone', () async {
          final harness = await withWait(value);
          await read(harness);
          now = start.add(const Duration(minutes: 9, seconds: 50));
          slept.clear();
          final result = await read(harness);
          expect(result.structuredContent!['next'], 'ask_human');
          expect(waited(), const Duration(seconds: 10));
        });
      }
    });

    test('progress reaches the client every 10 s with its token', () async {
      final harness = await server();
      final call = await harness
          .callWithProgress('authorize', {'operation_id': 'op_1'}, 'p1');
      expect(call.result.structuredContent!['next'], 'wait');
      expect([for (final n in call.progress) n.progressToken], List.filled(4, 'p1'));
      expect([for (final n in call.progress) n.progress], [1, 2, 3, 4]);
    });

    // A progress notification may only name a token the client sent.
    test('without a progressToken the wait sends none and still answers',
        () async {
      final harness = await server();
      final sent = <ProgressNotification>[];
      deps.notifyProgress = sent.add;
      final result = await read(harness);
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(result.structuredContent!['next'], 'wait');
      expect(sent, isEmpty);
    });

    // Measured on the binary: with stdin closed mid-wait the process lived
    // 32 s more, until the 45 s ran out.
    test('a closed channel ends the wait at the next poll', () async {
      final harness = await server();
      deps.connected = () => slept.length < 2;
      final result = await read(harness);
      expect(result.structuredContent!['next'], 'wait');
      expect(slept, hasLength(2));
      expect(reads(), 2);
    });

    test('an already closed channel does not sleep before returning', () async {
      final harness = await server();
      deps.connected = () => false;
      await read(harness);
      expect(slept, isEmpty);
    });

    test('the server ties connected to its channel', () async {
      final harness = await server();
      expect(deps.connected(), isTrue);
      await harness.shutdown();
      expect(deps.connected(), isFalse);
    });

    // Measured on the binary: left open, a keep-alive socket held the process
    // 15 s past a closed stdin.
    test('the read closes the client it opened', () async {
      final client = _CountingClose(MockClient(backend));
      final fixture = project(httpClient: client, clock: () => now,
          sleep: (d) async {
            now = now.add(d);
            await Future<void>.delayed(Duration.zero);
          });
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      expect((await read(harness)).structuredContent!['next'], 'wait');
      expect(client.closed, 1);
    });

    // The suite injects both; the server a client starts waits on the wall.
    test('the process defaults wait in real time', () async {
      final process = McpDeps(
        logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
        environment: const {},
      );
      expect(process.clock().difference(DateTime.now()).inSeconds.abs(),
          lessThan(2));
      final watch = Stopwatch()..start();
      await process.sleep(const Duration(milliseconds: 200));
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(190));
    });
  });

  test('an empty EASYI18N_MCP_MAX_CREDITS is the default, never invalid',
      () async {
    final result = await call({'action': 'translate', 'max_credits': 51},
        environment: const {
          'EASYI18N_TOKEN': 'eik_test',
          'EASYI18N_MCP_MAX_CREDITS': '',
        });
    expect(result.isError, isNot(true));
    expect(jsonDecode(posts().single.body)['max_credits'], 50);
  });

  test('an operation without operation_id or state is a wrong shape, '
      'never a result', () async {
    operation.remove('operation_id');
    final result = await call({'action': 'translate', 'operation_id': 'op_1'});
    expect(result.isError, isTrue);
    expect(errorOf(result)['message'], contains("'operation_id'"));
    expect(result.structuredContent, isNot(contains('next')));
  });

  group('D4 refuses a foreign host before the token is sent', () {
    const evil = 'projectId: proj_abc\nbaseUrl: https://evil.example\n';

    test('when reading an operation', () async {
      final fixture = project(config: evil, httpClient: MockClient(backend));
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness
          .call('authorize', {'action': 'translate', 'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });

    test('when creating one', () async {
      final fixture = project(
        config: evil,
        files: {'pubspec.yaml': _pubspec, 'lib/main.dart': "final s = tr('A');"},
        httpClient: MockClient(backend),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness
          .call('authorize', {'action': 'translate', 'max_credits': 10});
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });
  });

  group('push_preview', () {
    Future<CallToolResult> preview(Map<String, String> environment) async {
      final fixture = project(
        environment: environment,
        files: {'pubspec.yaml': _pubspec, 'lib/main.dart': "final s = tr('A');"},
        httpClient: MockClient(backend),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      return harness.call('push_preview', {'langs': ['fr']});
    }

    test('a push past the plan key cap says so instead of sending the agent '
        'to authorize', () async {
      overCap = true;
      final result = await preview(const {'EASYI18N_TOKEN': 'eik_test'});
      final text = (result.content.single as TextContent).text;
      expect(text, contains('next: plan_limit'));
      expect(text, isNot(contains('next: authorize')));
    });

    test('estimates for free and reports the ceiling', () async {
      final result = await preview(const {'EASYI18N_TOKEN': 'eik_test'});
      expect(result.isError, isNot(true));
      expect(requests.single.url.queryParameters['dryRun'], 'true');
      expect(jsonDecode(requests.single.body)['langs'], ['fr']);
      final content = result.structuredContent!;
      expect((content['estimate'] as Map)['estimated_credits'], 42);
      expect(content['ceiling'], {'env_max': 50});
      expect(
        (result.content.single as TextContent).text,
        allOf(contains('~42.0 credit(s)'), contains('next: authorize')),
      );
      expect(posts(), isEmpty);
    });

    // Flutter Mode A ends in the same `pull`, so it stops at the same place
    // on a project without an output format (#2133). Mode B never pulls.
    for (final mode in ['a', 'b']) {
      test('Mode ${mode.toUpperCase()} on a project with no output format '
          'and a key without write', () async {
        final fixture = project(
          config: 'projectId: proj_abc\nmode: $mode\n',
          files: {'pubspec.yaml': _pubspec, 'lib/main.dart': "final s = tr('A');"},
          httpClient: MockClient((req) async {
            final path = req.url.path;
            if (path.endsWith('/meta')) {
              return http.Response(jsonEncode({
                'baseCode': 'en', 'formats': [], 'outputFormatsApiVersion': 1,
              }), 200);
            }
            if (path.endsWith('/credential')) {
              return http.Response(jsonEncode({
                'scopes': ['read', 'translate', 'publish'],
                'requires_operation_approval': true,
              }), 200);
            }
            return backend(req);
          }),
        );
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call('push_preview', {'langs': ['fr']});
        final text = (result.content.single as TextContent).text;
        if (mode == 'b') {
          expect(text, contains('next: authorize'));
          expect(result.structuredContent!.containsKey('output_format'), isFalse);
          expect(requests, hasLength(1), reason: 'only the dry run');
          return;
        }
        expect(text, allOf(
          contains('next: output_format'),
          isNot(contains('next: authorize')),
          contains('Project > Settings > Output'),
          contains('`easyi18n formats add arb`'),
        ));
        final graded = result.structuredContent!['output_format'] as Map;
        expect(graded['state'], 'missing');
        expect(graded['remedy'], hasLength(2));
        // The plan key cap is named first, as in `sync_preview`.
        overCap = true;
        final capped = await harness.call('push_preview', {'langs': ['fr']});
        expect((capped.content.single as TextContent).text, allOf(
            contains('next: plan_limit'), contains('a plan upgrade'),
            isNot(contains('output_format')),
            isNot(contains('Project > Settings > Output'))));
      });
    }

    test('reports a raised ceiling', () async {
      final result = await preview(const {
        'EASYI18N_TOKEN': 'eik_test',
        'EASYI18N_MCP_MAX_CREDITS': '200',
      });
      expect(result.structuredContent!['ceiling'], {'env_max': 200});
    });
  });
}

class _CountingClose extends http.BaseClient {
  _CountingClose(this._inner);
  final http.Client _inner;
  int closed = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);
  @override
  void close() => closed++;
}
