@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show project;

const _pubspec = 'name: app\nflutter:\n  uses-material-design: true\n';

void main() {
  late List<http.Request> requests;
  late Directory dir;
  // What `GET /requests/{id}` answers, by request id; absent reads `unknown`.
  late Map<String, Map<String, Object?>> requestViews;
  late Map<String, http.Response> requestReplies;
  late Map<String, Object?> operation;
  late Map<String, Object?> dryRun;
  late Duration latency;

  setUp(() {
    requests = [];
    requestViews = {};
    requestReplies = {};
    latency = Duration.zero;
    operation = {
      'operation_id': 'op_1',
      'action': 'translate',
      'state': 'approved',
      'scope': <String, Object?>{'payload_sha256': 'x'},
      'requested_mc': 50000,
      'authorized_mc': 50000,
      'reserved_mc': 1000,
      'charged_mc': 2000,
      'absorbed_mc': 0,
      'approval_url': 'https://app.easyi18n.com/approve/op_1',
      'expires_at': '2026-09-22T16:00:00Z',
      'attempts': [
        {
          'id': 'a_1',
          'requests': [
            {'id': 'r_1', 'batch_index': 0, 'state': 'done'},
          ],
        },
      ],
    };
    dryRun = {
      'dryRun': true,
      'batchSha256': 'c' * 64,
      'estimatedCredits': 0,
      'balance': 900000,
      'availableCredits': 900000,
      'accepted': true,
      'wouldExceedKeyCap': false,
      'targetLangs': ['fr', 'de'],
      'units': [
        {
          'key': 'hi',
          'outcome': 'matched',
          'translated': ['fr'],
          'pending': ['de'],
        },
      ],
    };
  });

  Future<http.Response> backend(http.Request req) async {
    requests.add(req);
    await Future<void>.delayed(latency);
    final path = req.url.path;
    if (path.endsWith('/translate')) {
      if (req.url.queryParameters['dryRun'] == 'true') {
        return http.Response(jsonEncode(dryRun), 200);
      }
      final body = jsonDecode(req.body) as Map;
      return http.Response(
        jsonEncode({
          'trackingToken': 'job_${body['batchIndex']}',
          'estimatedCredits': 0,
          'balance': 900000,
          'accepted': true,
          'units': [],
        }),
        200,
      );
    }
    final requestId = RegExp(r'/requests/([^/]+)$').firstMatch(path)?.group(1);
    if (requestId != null) {
      final reply = requestReplies[requestId];
      if (reply != null) return reply;
      return http.Response(
        jsonEncode(
          requestViews[requestId] ??
              {'requestId': requestId, 'state': 'unknown'},
        ),
        200,
      );
    }
    if (path.endsWith('/translations')) {
      return http.Response(
        jsonEncode({
          'status': 'processing',
          'summary': {'total': 2, 'translated': 1, 'pending': 1, 'failed': 0},
        }),
        200,
      );
    }
    if (path.startsWith('/v1/operations/')) {
      return http.Response(jsonEncode(operation), 200);
    }
    return http.Response('{"error":"not_found"}', 404);
  }

  String sentAt([Duration ago = const Duration(minutes: 5)]) =>
      DateTime.now().toUtc().subtract(ago).toIso8601String();

  Map<String, Object?> intent(
    String id, {
    String state = 'sent',
    String? at,
    String attempt = 'a_1',
    int index = 0,
  }) => {
    'request_id': id,
    'attempt_id': attempt,
    'batch_index': index,
    'action': 'translate',
    'batch_sha256': 'c' * 64,
    'sent_at': at ?? sentAt(),
    'state': state,
  };

  String log(List<Map<String, Object?>> entries, {String? operationId}) =>
      jsonEncode({
        'operation_id': ?operationId,
        'family': 'code-first',
        'requests': entries,
      });

  Future<McpHarness> start({
    Map<String, String> extraFiles = const {},
    String config = 'projectId: proj_abc\n',
  }) async {
    final fixture = project(
      config: config,
      files: {
        'pubspec.yaml': _pubspec,
        'lib/main.dart': "final s = tr('hi');",
        ...extraFiles,
      },
      httpClient: MockClient(backend),
    );
    dir = fixture.dir;
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness;
  }

  Future<CallToolResult> call(
    Map<String, Object?> arguments, {
    Map<String, String> extraFiles = const {},
  }) async {
    final harness = await start(extraFiles: extraFiles);
    return harness.call('fill_status', arguments);
  }

  List<Map<String, Object?>> logged(String relative) {
    final file = File(p.join(dir.path, '.easyi18n', 'operations', relative));
    final data = jsonDecode(file.readAsStringSync()) as Map;
    return [
      for (final r in data['requests'] as List)
        (r as Map).cast<String, Object?>(),
    ];
  }

  List<http.Request> requestGets() => [
    for (final r in requests)
      if (r.method == 'GET' && r.url.path.contains('/requests/')) r,
  ];

  List<http.Request> realIngests() => [
    for (final r in requests)
      if (r.url.path.endsWith('/translate') &&
          r.url.queryParameters['dryRun'] != 'true')
        r,
  ];

  Map<String, Object?> ok(CallToolResult result) {
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    return result.structuredContent!;
  }

  group('reconciliation of a sent intent', () {
    test('one the server finished is adopted with the recorded answer, and '
        'push is unblocked', () async {
      requestViews['r_1'] = {
        'requestId': 'r_1',
        'state': 'done',
        'response': {'trackingToken': 'job_9', 'estimatedCredits': 5000},
      };
      final harness = await start(
        extraFiles: {
          '.easyi18n/operations/op_1.json': log([
            intent('r_1'),
          ], operationId: 'op_1'),
        },
      );
      final content = ok(await harness.call('fill_status'));
      final after = logged('op_1.json').single;
      expect(after['state'], 'accepted');
      expect((after['response'] as Map)['tracking_token'], 'job_9');
      expect(content['reconciled'], [
        {
          'request_id': 'r_1',
          'was': 'sent',
          'state': 'accepted',
          'server_state': 'done',
        },
      ]);
      expect(content['unresolved'], isEmpty);
      expect(
        requestGets().single.url.path,
        '/v1/projects/proj_abc/requests/r_1',
      );

      final pushed = await harness.call('push');
      expect(
        pushed.isError,
        isNot(true),
        reason: '${pushed.structuredContent}',
      );
      expect(realIngests(), hasLength(1));
    });

    for (final (server, local, extra) in [
      (
        'failed',
        'refused',
        {
          'error': {
            'status': 402,
            'body': {'error': 'x'},
          },
        },
      ),
      ('unknown', 'lost', <String, Object?>{}),
      ('expired', 'expired', {'stateWas': 'done', 'trackingToken': 'job_3'}),
    ]) {
      test('$server on the server closes the intent as $local', () async {
        requestViews['r_1'] = {'requestId': 'r_1', 'state': server, ...extra};
        final content = ok(
          await call(
            {},
            extraFiles: {
              '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
            },
          ),
        );
        final after = logged(p.join('free', 'a_1.json')).single;
        expect(after['state'], local);
        expect(after['response'], isNotNull);
        expect(content['unresolved'], isEmpty);
        expect(
          (content['reconciled'] as List).single,
          containsPair('server_state', server),
        );
      });
    }

    // Spec section 4.4: an expired intent is never re-sent and is reported,
    // so the summary the agent relays says so whatever `next` is.
    for (final (label, at, view) in [
      (
        'on the server',
        null,
        <String, Object?>{
          'requestId': 'r_1',
          'state': 'expired',
          'stateWas': 'done',
        },
      ),
      ('locally, after 24 h', sentAt(const Duration(hours: 25)), null),
    ]) {
      test('a request closed as expired $label reaches the summary', () async {
        dryRun['units'] = [
          {
            'key': 'hi',
            'outcome': 'matched',
            'translated': ['fr', 'de'],
            'pending': [],
          },
        ];
        if (view != null) requestViews['r_1'] = view;
        final result = await call(
          {},
          extraFiles: {
            '.easyi18n/operations/free/a_1.json': log([intent('r_1', at: at)]),
          },
        );
        expect(ok(result)['next'], 'publish');
        final text = (result.content.single as TextContent).text;
        expect(text, contains('complete. Authorize and publish.'));
        expect(text, contains('1 request(s) closed as expired'));
      });
    }

    test('a request the server finished leaves the summary alone', () async {
      requestViews['r_1'] = {
        'requestId': 'r_1',
        'state': 'done',
        'response': {'trackingToken': 'job_9'},
      };
      final result = await call(
        {},
        extraFiles: {
          '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
        },
      );
      expect(ok(result)['reconciled'], hasLength(1));
      expect(
        (result.content.single as TextContent).text,
        isNot(contains('expired')),
      );
    });

    test('expired keeps what the server says it was', () async {
      requestViews['r_1'] = {
        'requestId': 'r_1',
        'state': 'expired',
        'stateWas': 'failed',
      };
      await call(
        {},
        extraFiles: {
          '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
        },
      );
      final after = logged(p.join('free', 'a_1.json')).single;
      expect((after['response'] as Map)['state_was'], 'failed');
    });

    test(
      'processing stays sent, reports the lease, and asks for a poll',
      () async {
        requestViews['r_1'] = {
          'requestId': 'r_1',
          'state': 'processing',
          'leaseUntil': '2026-09-22T16:00:00Z',
        };
        final content = ok(
          await call(
            {},
            extraFiles: {
              '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
            },
          ),
        );
        expect(logged(p.join('free', 'a_1.json')).single['state'], 'sent');
        expect(content['unresolved'], [
          {
            'request_id': 'r_1',
            'server_state': 'processing',
            'lease_until': '2026-09-22T16:00:00Z',
          },
        ]);
        expect(content['next'], 'poll');
      },
    );

    test('a state this client does not know leaves the intent sent', () async {
      requestViews['r_1'] = {'requestId': 'r_1', 'state': 'archived'};
      final content = ok(
        await call(
          {},
          extraFiles: {
            '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
          },
        ),
      );
      expect(logged(p.join('free', 'a_1.json')).single['state'], 'sent');
      expect(
        (content['unresolved'] as List).single,
        containsPair('server_state', 'archived'),
      );
      expect(content['next'], 'poll');
    });

    test('an intent older than 24 h expires locally, without asking the '
        'server, and is never re-sent', () async {
      final content = ok(
        await call(
          {},
          extraFiles: {
            '.easyi18n/operations/free/a_1.json': log([
              intent('r_1', at: sentAt(const Duration(hours: 25))),
            ]),
          },
        ),
      );
      expect(requestGets(), isEmpty);
      final after = logged(p.join('free', 'a_1.json')).single;
      expect(after['state'], 'expired');
      expect((after['response'] as Map)['reason'], 'stale_intent');
      expect(
        (content['reconciled'] as List).single,
        containsPair('server_state', 'stale_intent'),
      );
    });

    test('an intent whose sent_at cannot be read counts as stale', () async {
      await call(
        {},
        extraFiles: {
          '.easyi18n/operations/free/a_1.json': log([
            intent('r_1', at: 'never'),
          ]),
        },
      );
      expect(requestGets(), isEmpty);
      expect(logged(p.join('free', 'a_1.json')).single['state'], 'expired');
    });

    test(
      'a GET that fails leaves the intent sent and asks for a poll',
      () async {
        requestReplies['r_1'] = http.Response('upstream', 503);
        final content = ok(
          await call(
            {},
            extraFiles: {
              '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
            },
          ),
        );
        expect(logged(p.join('free', 'a_1.json')).single['state'], 'sent');
        expect(
          (content['unresolved'] as List).single,
          containsPair('server_state', 'unreachable'),
        );
        expect(content['next'], 'poll');
      },
    );

    test('only sent intents are asked about, across every log', () async {
      requestViews['r_2'] = {
        'requestId': 'r_2',
        'state': 'done',
        'response': {},
      };
      requestViews['r_4'] = {
        'requestId': 'r_4',
        'state': 'done',
        'response': {},
      };
      await call(
        {},
        extraFiles: {
          '.easyi18n/operations/op_1.json': log([
            intent('r_1', state: 'accepted'),
            intent('r_2', index: 1),
          ], operationId: 'op_1'),
          '.easyi18n/operations/free/a_2.json': log([
            intent('r_3', state: 'refused', attempt: 'a_2'),
            intent('r_4', attempt: 'a_2', index: 1),
          ]),
        },
      );
      expect(
        requestGets().map((r) => p.basename(r.url.path)),
        unorderedEquals(['r_2', 'r_4']),
      );
      expect(logged('op_1.json').map((r) => r['state']), [
        'accepted',
        'accepted',
      ]);
      expect(logged(p.join('free', 'a_2.json')).map((r) => r['state']), [
        'refused',
        'accepted',
      ]);
    });

    test('a log it cannot read is reported, never rewritten, and holds next '
        'at poll even when the fill is complete', () async {
      // Complete on the server: without the unreadable log `next` would be
      // `publish`, so this pins the guard and not the pending pair.
      dryRun['units'] = [
        {
          'key': 'hi',
          'outcome': 'matched',
          'translated': ['fr', 'de'],
          'pending': [],
        },
      ];
      final harness = await start(
        extraFiles: {'.easyi18n/operations/op_1.json': '{"requests": ['},
      );
      final result = await harness.call('fill_status');
      final content = ok(result);
      expect(
        File(
          p.join(dir.path, '.easyi18n/operations/op_1.json'),
        ).readAsStringSync(),
        '{"requests": [',
      );
      expect(content['unreadable_logs'], [
        p.join('.easyi18n', 'operations', 'op_1.json'),
      ]);
      expect(content['pending'], 0);
      expect(content['next'], 'poll');
      final text = (result.content.single as TextContent).text;
      expect(text, contains('cannot be read'));
      expect(text, isNot(contains('Poll again')));
    });

    test('an intent whose request_id is not a string is reported as an '
        'unreadable log, not skipped', () async {
      dryRun['units'] = [
        {
          'key': 'hi',
          'outcome': 'matched',
          'translated': ['fr', 'de'],
          'pending': [],
        },
      ];
      final content = ok(
        await call(
          {},
          extraFiles: {
            '.easyi18n/operations/free/a_1.json': log([
              {...intent('r_1'), 'request_id': 7},
            ]),
          },
        ),
      );
      expect(requestGets(), isEmpty);
      expect(content['unreadable_logs'], [
        p.join('.easyi18n', 'operations', 'free', 'a_1.json'),
      ]);
      expect(content['next'], 'poll');
    });
  });

  group('the poll', () {
    test('never ingests', () async {
      dryRun['estimatedCredits'] = 42000;
      final result = await call({
        'langs': ['de'],
      });
      final content = ok(result);
      expect(realIngests(), isEmpty);
      expect(content['failed_needs_requeue'], isTrue);
      expect(content['next'], 'ingest_again');
      // No operation in the log: nothing to count attempts against.
      expect(
        (result.content.single as TextContent).text,
        contains('Push again under the same operation_id, at most twice.'),
      );
      final dry = requests.singleWhere(
        (r) => r.url.queryParameters['dryRun'] == 'true',
      );
      expect((jsonDecode(dry.body) as Map)['langs'], ['de']);
      expect(File(p.join(dir.path, 'easyi18n.lock')).existsSync(), isFalse);
    });

    test('work the plan key cap refuses is plan_limit, never ingest_again',
        () async {
      dryRun['estimatedCredits'] = 42000;
      dryRun['wouldExceedKeyCap'] = true;
      final result = await call({});
      expect(ok(result)['next'], 'plan_limit');
      final text = (result.content.single as TextContent).text;
      expect(text, contains('plan'));
      expect(text, isNot(contains('Push again')));
    });

    for (final state in ['expired', 'exhausted', 'denied', 'approved']) {
      test('plan_limit precedes reauthorization for $state', () async {
        operation['state'] = state;
        dryRun['wouldExceedKeyCap'] = true;
        dryRun['estimatedCredits'] = 1000;
        if (state == 'approved') {
          dryRun['units'] = [
            {'key': 'hi', 'outcome': 'matched', 'budgetExhausted': ['de']},
          ];
        }
        final result = await call({}, extraFiles: {
          '.easyi18n/operations/op_1.json': log([
            intent('r_1', state: 'accepted'),
          ], operationId: 'op_1'),
        });
        expect(ok(result)['next'], 'plan_limit');
        expect((result.content.single as TextContent).text,
            contains('authorizing or pushing again does not'));
      });
    }

    test('plan_limit still reconciles a processing request before a remedy',
        () async {
      dryRun['wouldExceedKeyCap'] = true;
      requestViews['r_1'] = {'requestId': 'r_1', 'state': 'processing'};
      final result = await call({}, extraFiles: {
        '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
      });
      expect(ok(result)['next'], 'poll');
      expect(ok(result)['unresolved'], hasLength(1));
      expect(logged(p.join('free', 'a_1.json')).single['state'], 'sent');
    });

    test('pending pairs with nothing to requeue are a poll', () async {
      final content = ok(await call({}));
      expect(content['complete'], isFalse);
      expect(content['pending'], 1);
      expect(content['failed_needs_requeue'], isFalse);
      expect(content['next'], 'poll');
    });

    test('everything translated is complete: publish', () async {
      dryRun['units'] = [
        {
          'key': 'hi',
          'outcome': 'matched',
          'translated': ['fr', 'de'],
          'pending': [],
        },
      ];
      final content = ok(await call({}));
      expect(content['complete'], isTrue);
      expect(content['pending'], 0);
      expect(content['next'], 'publish');
    });

    test('an exhausted pair is reported and does not block publish', () async {
      dryRun['units'] = [
        {
          'key': 'hi',
          'outcome': 'matched',
          'translated': ['fr'],
          'pending': [],
          'exhausted': ['de'],
        },
      ];
      final content = ok(await call({}));
      expect(content['complete'], isTrue);
      expect(content['exhausted'], [
        {'key': 'hi', 'lang': 'de'},
      ]);
      expect(content['next'], 'publish');
    });

    test('a budget_exhausted pair asks for a new authorization', () async {
      dryRun['estimatedCredits'] = 1000;
      dryRun['units'] = [
        {
          'key': 'hi',
          'outcome': 'matched',
          'translated': ['fr'],
          'pending': ['de'],
          'budgetExhausted': ['de'],
        },
      ];
      final result = await call({});
      final content = ok(result);
      expect(content['budget_exhausted'], [
        {'key': 'hi', 'lang': 'de'},
      ]);
      expect(content['next'], 'reauthorize');
      final text = (result.content.single as TextContent).text;
      expect(text, contains('cannot spend further'));
      expect(text, isNot(contains('attempts')));
    });

    test('exhausted lists are capped at 50 with their totals', () async {
      dryRun['units'] = [
        for (var i = 0; i < 60; i++)
          <String, Object?>{
            'key': 'k$i',
            'outcome': 'matched',
            'translated': <String>[],
            'pending': ['de'],
            'exhausted': ['fr'],
            'budgetExhausted': ['de'],
          },
      ];
      final content = ok(await call({}));
      expect(content['exhausted'], hasLength(50));
      expect(content['exhausted_total'], 60);
      expect(content['budget_exhausted'], hasLength(50));
      expect(content['budget_exhausted_total'], 60);
    });

    test(
      'an unresolved intent wins over a requeue: poll, not ingest',
      () async {
        dryRun['estimatedCredits'] = 42000;
        requestViews['r_1'] = {'requestId': 'r_1', 'state': 'processing'};
        final content = ok(
          await call(
            {},
            extraFiles: {
              '.easyi18n/operations/free/a_1.json': log([intent('r_1')]),
            },
          ),
        );
        expect(content['failed_needs_requeue'], isTrue);
        expect(content['next'], 'poll');
      },
    );

    test('an empty scan is complete without a request', () async {
      final harness = await start(extraFiles: {'lib/main.dart': ''});
      final content = ok(await harness.call('fill_status'));
      expect(requests, isEmpty);
      expect(content['complete'], isTrue);
      expect(content['next'], 'publish');
    });

    test('tracking_tokens add a job summary each', () async {
      final content = ok(
        await call({
          'tracking_tokens': ['job_1', 'job_2'],
        }),
      );
      expect(content['jobs'], [
        {
          'tracking_token': 'job_1',
          'status': 'processing',
          'total': 2,
          'translated': 1,
          'pending': 1,
          'failed': 0,
        },
        {
          'tracking_token': 'job_2',
          'status': 'processing',
          'total': 2,
          'translated': 1,
          'pending': 1,
          'failed': 0,
        },
      ]);
    });
  });

  group('the operation ledger', () {
    test('is read from the newest log that names one', () async {
      final content = ok(
        await call(
          {},
          extraFiles: {
            '.easyi18n/operations/op_1.json': log([
              intent('r_1', state: 'accepted'),
            ], operationId: 'op_1'),
          },
        ),
      );
      expect(content['operation'], {
        'id': 'op_1',
        'state': 'approved',
        'authorized_mc': 50000,
        'reserved_mc': 1000,
        'charged_mc': 2000,
        'absorbed_mc': 0,
        'attempts': [
          {
            'id': 'a_1',
            'requests': [
              {'id': 'r_1', 'batch_index': 0, 'state': 'done'},
            ],
          },
        ],
      });
      expect(
        requests.where((r) => r.url.path == '/v1/operations/op_1'),
        hasLength(1),
      );
    });

    test(
      'two logs with operations: the newest by mtime is the one read',
      () async {
        final harness = await start(
          extraFiles: {
            '.easyi18n/operations/op_1.json': log([
              intent('r_1', state: 'accepted'),
            ], operationId: 'op_1'),
            '.easyi18n/operations/op_2.json': log([
              intent('r_2', state: 'accepted'),
            ], operationId: 'op_2'),
          },
        );
        final ops = p.join(dir.path, '.easyi18n', 'operations');
        final old = DateTime.now().subtract(const Duration(hours: 1));
        File(p.join(ops, 'op_2.json')).setLastModifiedSync(old);
        File(p.join(ops, 'op_1.json')).setLastModifiedSync(DateTime.now());
        final content = ok(await harness.call('fill_status'));
        expect((content['operation'] as Map)['id'], 'op_1');
        expect(
          requests
              .where((r) => r.url.path.startsWith('/v1/operations/'))
              .map((r) => r.url.path),
          ['/v1/operations/op_1'],
        );
      },
    );

    test('is absent without a log', () async {
      final content = ok(await call({}));
      expect(content.containsKey('operation'), isTrue);
      expect(content['operation'], isNull);
      expect(
        requests.where((r) => r.url.path.startsWith('/v1/operations')),
        isEmpty,
      );
    });

    for (final state in ['expired', 'exhausted', 'denied']) {
      test('a $state operation asks for a new authorization', () async {
        operation['state'] = state;
        final content = ok(
          await call(
            {},
            extraFiles: {
              '.easyi18n/operations/op_1.json': log([
                intent('r_1', state: 'accepted'),
              ], operationId: 'op_1'),
            },
          ),
        );
        expect(content['next'], 'reauthorize');
      });
    }

    // The server refuses a fourth attempt (`attempts_exhausted`) but accepts
    // a continuation of the last one, so only the ingest_again branch reads
    // the attempts: three of them never stop a poll or a publish.
    group('with every attempt registered', () {
      List<Map<String, Object?>> attempts(int n) => [
        for (var i = 1; i <= n; i++)
          {
            'id': 'a_$i',
            'requests': [
              {'id': 'r_$i', 'batch_index': 0, 'state': 'done'},
            ],
          },
      ];

      // The local log of [n] attempts of one batch each; [last] replaces the
      // record of the last one.
      Future<CallToolResult> poll(int n, {Map<String, Object?>? last}) async {
        operation['attempts'] = attempts(n);
        final harness = await start(
          extraFiles: {
            '.easyi18n/operations/op_1.json': log([
              for (var i = 1; i < n; i++)
                intent('r_$i', state: 'accepted', attempt: 'a_$i'),
              last ?? intent('r_$n', state: 'accepted', attempt: 'a_$n'),
            ], operationId: 'op_1'),
          },
        );
        return harness.call('fill_status');
      }

      test('a new ingest with no continuation left asks for a new '
          'authorization, without promising one', () async {
        dryRun['estimatedCredits'] = 42000;
        final result = await poll(3);
        expect(ok(result)['next'], 'reauthorize');
        final text = (result.content.single as TextContent).text;
        expect(text, contains('already ran its 3 attempts'));
        expect(text, contains('may return this same operation'));
        expect(text, isNot(contains('Push again')));
      });

      String textOf(CallToolResult result) =>
          (result.content.single as TextContent).text;

      test('two attempts leave one: ingest_again, and the text counts it',
          () async {
        dryRun['estimatedCredits'] = 42000;
        final result = await poll(2);
        expect(ok(result)['next'], 'ingest_again');
        expect(textOf(result), contains('opens a new attempt'));
        expect(textOf(result), contains('1 of 3 left'));
        expect(textOf(result), isNot(contains('at most twice')));
      });

      test('one attempt leaves two', () async {
        dryRun['estimatedCredits'] = 42000;
        final result = await poll(1);
        expect(ok(result)['next'], 'ingest_again');
        expect(textOf(result), contains('2 of 3 left'));
      });

      test('a last attempt that can continue is still ingest_again, and the '
          'text says it opens no attempt', () async {
        dryRun['estimatedCredits'] = 42000;
        final result = await poll(3, last: {
          ...intent('r_3', state: 'refused', attempt: 'a_3'),
          'response': {'server_state': 'failed'},
        });
        expect(ok(result)['next'], 'ingest_again');
        expect(textOf(result), contains('Push again'));
        expect(textOf(result), contains('continues the last attempt'));
        expect(textOf(result), isNot(contains('new ingest')));
        expect(textOf(result), isNot(contains('left')));
        expect(textOf(result), isNot(contains('at most twice')));
      });

      test('a last attempt the server never saw is still ingest_again',
          () async {
        dryRun['estimatedCredits'] = 42000;
        final result = await poll(3, last: {
          ...intent('r_3', state: 'lost', attempt: 'a_3'),
          'response': {'server_state': 'unknown'},
        });
        expect(ok(result)['next'], 'ingest_again');
        expect(textOf(result), contains('continues the last attempt'));
      });

      // Section 13 (iv): the poll that closes a request as lost is the one
      // that says what the next push does with it.
      test('a request this poll closes as lost continues its attempt',
          () async {
        dryRun['estimatedCredits'] = 42000;
        final result = await poll(1, last: intent('r_1'));
        final content = ok(result);
        expect((content['reconciled'] as List).single['state'], 'lost');
        expect(content['next'], 'ingest_again');
        expect(textOf(result), contains('continues the last attempt'));
        expect(textOf(result), isNot(contains('at most twice')));
      });

      test('pending pairs are still a poll', () async {
        final result = await poll(3);
        expect(ok(result)['next'], 'poll');
      });

      test('a complete fill is still a publish', () async {
        dryRun['units'] = [
          {
            'key': 'hi',
            'outcome': 'matched',
            'translated': ['fr', 'de'],
            'pending': [],
          },
        ];
        final result = await poll(3);
        expect(ok(result)['next'], 'publish');
      });
    });

    test(
      'the operation id comes from the file name, never the header',
      () async {
        final content = ok(
          await call(
            {},
            extraFiles: {
              '.easyi18n/operations/op_1.json': jsonEncode({
                'operation_id': '../../escaped',
                'family': 'code-first',
                'requests': [intent('r_1', state: 'accepted')],
              }),
            },
          ),
        );
        expect(
          requests.where((r) => r.url.path == '/v1/operations/op_1'),
          hasLength(1),
        );
        expect((content['operation'] as Map)['id'], 'op_1');
      },
    );
  });

  test('fill_status racing a push in one session keeps every request in the '
      'log', () async {
    latency = const Duration(milliseconds: 20);
    requestViews['r_0'] = {'requestId': 'r_0', 'state': 'done', 'response': {}};
    final harness = await start(
      extraFiles: {
        '.easyi18n/operations/free/a_0.json': log([
          intent('r_0', attempt: 'a_0'),
        ]),
      },
    );
    final results = await Future.wait([
      harness.call('fill_status'),
      harness.call('push'),
      harness.call('fill_status'),
    ]);
    expect(
      results.map((r) => r.isError),
      everyElement(isNot(true)),
      reason: '${results.map((r) => r.structuredContent)}',
    );
    expect(realIngests(), hasLength(1));
    final sent = (jsonDecode(realIngests().single.body) as Map);
    final free = Directory(
      p.join(dir.path, '.easyi18n', 'operations', 'free'),
    ).listSync().whereType<File>().map((f) => p.basename(f.path)).toSet();
    expect(free, {'a_0.json', '${sent['attemptId']}.json'});
    expect(logged(p.join('free', 'a_0.json')).single['state'], 'accepted');
    expect(
      logged(p.join('free', '${sent['attemptId']}.json')).single['state'],
      'accepted',
    );
  });
}
