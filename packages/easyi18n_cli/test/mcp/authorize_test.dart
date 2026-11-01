@TestOn('vm')
library;

import 'dart:convert';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show errorOf, project;

const _pubspec = 'name: app\nflutter:\n  uses-material-design: true\n';

void main() {
  late List<http.Request> requests;
  late int estimateMc;
  late bool overCap;
  late Map<String, Object?> operation;
  setUp(() {
    requests = [];
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

    test('a denied operation sends the agent back to authorize', () async {
      operation['state'] = 'denied';
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
