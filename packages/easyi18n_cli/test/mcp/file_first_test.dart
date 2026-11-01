@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/mcp/request_log.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show errorOf, project;

const _config =
    'projectId: proj_abc\nformat: xcstrings\ncatalog: Localizable.xcstrings\n';

const _catalog =
    '{"sourceLanguage":"en","version":"1.0","strings":{'
    '"hello":{"localizations":{"en":{"stringUnit":'
    '{"state":"translated","value":"Hello"}}}},'
    '"bye":{"localizations":{"en":{"stringUnit":'
    '{"state":"translated","value":"Bye"}}}}}}';

// The backend's ingestBatchSha256({'batches': [{index: 0, sha256: 'd' x 64,
// unit_count: 2}]}): the one-batch manifest of the two-entry catalog above.
const _payloadCatalog =
    '1506b29d72f4747256aec5f5934a83216d5365b05d70d6244d8ff98d4ca08f45';

void main() {
  late List<http.Request> requests;
  late Map<String, Object?> dryRun;
  late Directory dir;
  late String operationState;
  late Map<String, Object?> operation;
  // What the write-ahead log held for the real sync when the server got it.
  late Map<String, Object?>? logAtSend;
  late http.Response? realReply;
  late Duration latency;
  late String requestState;
  // What `/meta` and `/credential` answer; null leaves the 404 of a backend
  // that serves neither.
  late List<String>? formats;
  // Null answers a credential without `requires_operation_approval`.
  late List<String>? scopes;

  setUp(() {
    requests = [];
    formats = null;
    scopes = ['read', 'translate', 'publish'];
    operationState = 'pending_approval';
    logAtSend = null;
    realReply = null;
    latency = Duration.zero;
    requestState = 'done';
    operation = {
      'operation_id': 'op_1',
      'action': 'translate',
      'state': 'approved',
      'scope': <String, Object?>{'payload_sha256': _payloadCatalog},
      'authorized_mc': 50000,
      'reserved_mc': 0,
      'charged_mc': 0,
      'approval_url': 'https://app.easyi18n.com/approve/op_1',
    };
    dryRun = {
      'dryRun': true,
      'batchSha256': 'd' * 64,
      'format': 'xcstrings',
      'baseCode': 'en',
      'targetLangs': ['fr', 'de'],
      'fillableLangs': ['fr', 'de'],
      'created': 2,
      'updatedSources': 0,
      'matchedSources': 0,
      'updatedTranslations': 0,
      'unchangedTranslations': 0,
      'disabledOrphans': 0,
      'reenabled': 0,
      'failedEntries': [],
      'exhausted': [],
      'budgetExhausted': [],
      'onConflict': 'server',
      'conflicts': [
        {'key': 'hello', 'lang': 'fr', 'origin': 'human', 'resolution': 'kept'},
      ],
      'conflictsTotal': 1,
      'diagnostics': [
        {'code': 'LANG_NOT_FILLABLE', 'lang': 'it'},
      ],
      'trackingToken': null,
      'estimatedCredits': 42000,
      'balance': 900000,
      'availableCredits': 900000,
      'accepted': true,
    };
  });

  Future<http.Response> backend(http.Request req) async {
    requests.add(req);
    await Future<void>.delayed(latency);
    final path = req.url.path;
    if (path.endsWith('/sync')) {
      if (req.url.queryParameters['dryRun'] == 'true') {
        return http.Response(jsonEncode(dryRun), 200);
      }
      final body = jsonDecode(req.body) as Map;
      final log = File(p.join(
        dir.path,
        '.easyi18n',
        'operations',
        body['operationId'] == null
            ? p.join('free', '${body['attemptId']}.json')
            : 'op_1.json',
      ));
      logAtSend = log.existsSync()
          ? (jsonDecode(log.readAsStringSync()) as Map).cast()
          : null;
      return realReply ??
          http.Response(
            jsonEncode({
              ...dryRun,
              'dryRun': false,
              'trackingToken': 'job_0',
            }),
            200,
          );
    }
    if (path == '/v1/operations') {
      return http.Response(
        jsonEncode({
          'operation_id': 'op_1',
          'action': 'translate',
          'state': operationState,
          'approval_url': 'https://app.easyi18n.com/approve/op_1',
        }),
        201,
      );
    }
    final requestId = RegExp(r'/requests/([^/]+)$').firstMatch(path)?.group(1);
    if (requestId != null) {
      return http.Response(
        jsonEncode({
          'requestId': requestId,
          'state': requestState,
          if (requestState == 'failed') 'error': {'code': 'orphaned'},
          if (requestState == 'done') 'response': {'trackingToken': 'job_0', 'estimatedCredits': 42000},
        }),
        200,
      );
    }
    if (path.startsWith('/v1/operations/')) {
      return http.Response(jsonEncode(operation), 200);
    }
    if (formats != null && path.endsWith('/meta')) {
      return http.Response(jsonEncode({
        'baseCode': 'en', 'formats': formats, 'outputFormatsApiVersion': 1,
      }), 200);
    }
    if (formats != null && path.endsWith('/credential')) {
      return http.Response(jsonEncode({
        'scopes': scopes ?? const <String>[],
        if (scopes != null) 'requires_operation_approval': true,
      }), 200);
    }
    return http.Response('{"error":"not_found"}', 404);
  }

  Future<McpHarness> start({
    String config = _config,
    Map<String, String> files = const {'Localizable.xcstrings': _catalog},
  }) async {
    final fixture = project(
      config: config,
      files: files,
      httpClient: MockClient(backend),
    );
    dir = fixture.dir;
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness;
  }

  List<http.Request> syncs() => [
    for (final r in requests)
      if (r.url.path == '/v1/projects/proj_abc/sync') r,
  ];

  for (final free in [false, true]) {
    test('failed sync retries under the same attempt free=$free', () async {
      if (free) dryRun['estimatedCredits'] = 0;
      final harness = await start();
      final args = <String, Object?>{if (!free) 'operation_id': 'op_1'};
      realReply = http.Response('lost', 503);
      requestState = 'failed';
      expect(errorOf(await harness.call('sync', args))['code'], 'request_unresolved');
      expect(errorOf(await harness.call('sync', args))['code'], 'request_unresolved');
      final poll = await harness.call('fill_status');
      expect((poll.structuredContent!['reconciled'] as List).single,
          containsPair('server_state', 'failed'));
      realReply = null;
      final result = await harness.call('sync', args);
      expect(result.isError, isNot(true));
      final sent = [for (final r in syncs())
        if (r.url.queryParameters['dryRun'] != 'true') jsonDecode(r.body) as Map];
      expect(sent, hasLength(2));
      expect(sent.map((r) => r['attemptId']).toSet(), hasLength(1),
          reason: 'a failed sync must not consume a new attempt');
      expect(sent.map((r) => r['requestId']).toSet(), hasLength(2));
      expect(sent.map((r) => r['batchIndex']), [0, 0]);
      expect(RequestLog.all(dir.path).single.requests.map((r) => r['state']),
          ['refused', 'accepted']);
    });

    test('sync late original still processing keeps the resend unresolved free=$free',
        () async {
      if (free) dryRun['estimatedCredits'] = 0;
      final harness = await start();
      final args = <String, Object?>{if (!free) 'operation_id': 'op_1'};
      requestState = 'unknown';
      realReply = http.Response('never arrived', 503);
      expect(errorOf(await harness.call('sync', args))['code'], 'request_unresolved');
      await harness.call('fill_status');
      realReply = http.Response(jsonEncode({
        'error': 'request_in_progress', 'message': 'original still processing',
      }), 409);
      expect(errorOf(await harness.call('sync', args))['code'], 'request_unresolved');
      requestState = 'processing';
      expect((await harness.call('fill_status')).structuredContent!['unresolved'], hasLength(1));
      requestState = 'done';
      await harness.call('fill_status');
      expect(RequestLog.all(dir.path).single.requests.map((r) => r['state']),
          ['lost', 'accepted']);
    });

    test('sync the server never saw goes again with its request id in the same attempt free=$free',
        () async {
      if (free) dryRun['estimatedCredits'] = 0;
      final harness = await start();
      final args = <String, Object?>{if (!free) 'operation_id': 'op_1'};
      realReply = http.Response('never arrived', 503);
      requestState = 'unknown';
      expect(errorOf(await harness.call('sync', args))['code'], 'request_unresolved');
      final poll = await harness.call('fill_status');
      expect((poll.structuredContent!['reconciled'] as List).single,
          containsPair('state', 'lost'));
      realReply = null;
      final result = await harness.call('sync', args);
      expect(result.isError, isNot(true));
      final sent = [for (final r in syncs())
        if (r.url.queryParameters['dryRun'] != 'true') jsonDecode(r.body) as Map];
      expect(sent, hasLength(2));
      expect(sent.map((r) => r['attemptId']).toSet(), hasLength(1),
          reason: 'a sync the server never saw must not consume an attempt');
      expect(sent.map((r) => r['requestId']).toSet(), hasLength(1));
      expect(RequestLog.all(dir.path).single.requests.map((r) => r['state']),
          ['lost', 'accepted']);
    });
  }

  test('sync of a catalogs project records the list, and pull finds the policy by it (#590)',
      () async {
    dryRun['estimatedCredits'] = 0;
    final harness = await start(
      config: 'projectId: proj_abc\nformat: xcstrings\ncatalogs:\n'
          '  - Localizable.xcstrings\n  - Shortcuts.xcstrings\n',
      files: {
        'Localizable.xcstrings': _catalog,
        'Shortcuts.xcstrings':
            '{"sourceLanguage":"en","version":"1.0","strings":{"third":{}}}',
      },
    );
    final result = await harness.call('sync');
    expect(result.isError, isNot(true));
    expect(result.structuredContent!['catalogs'],
        ['Localizable.xcstrings', 'Shortcuts.xcstrings']);
    expect(result.structuredContent!.keys, isNot(contains('catalog')));
    final log = RequestLog.all(dir.path).single.data!;
    expect(log['catalogs'], ['Localizable.xcstrings', 'Shortcuts.xcstrings']);
    expect(
      RequestLog.recordedKeyPolicy(
          dir.path, null, ['Localizable.xcstrings', 'Shortcuts.xcstrings']),
      'local_owns',
    );
  });

  group('sync_preview', () {
    test('prices the catalog with the dry run and registers nothing', () async {
      final harness = await start();
      final result = await harness.call('sync_preview', {
        'on_conflict': 'file',
      });
      expect(result.isError, isNot(true));
      final sent = syncs().single;
      expect(sent.url.queryParameters['dryRun'], 'true');
      final body = jsonDecode(sent.body) as Map;
      expect(body['onConflict'], 'file');
      expect(body['fileName'], 'Localizable.xcstrings');
      expect(
        base64Decode(body['contentBase64'] as String),
        utf8.encode(_catalog),
      );
      expect(body.keys, isNot(contains('requestId')));
      expect(body.keys, isNot(contains('operationId')));
      final out = result.structuredContent!;
      expect(out['estimated_credits'], 42);
      expect(out['conflicts'], dryRun['conflicts']);
      expect(out['conflicts_total'], 1);
      expect(out['diagnostics'], dryRun['diagnostics']);
      expect(out['catalog'], 'Localizable.xcstrings');
      expect(out['ceiling'], {'env_max': 50});
      expect(out['next'], 'authorize');
      // Only an android_xml project has values-<lang> files to report.
      expect(out.keys, isNot(contains('language_files')));
      expect(out.keys, isNot(contains('skipped_language_files')));
    });

    test('lists every catalog and prices the union of their entries (#590)',
        () async {
      final harness = await start(
        config: 'projectId: proj_abc\nformat: xcstrings\ncatalogs:\n'
            '  - Localizable.xcstrings\n  - Shortcuts.xcstrings\n',
        files: {
          'Localizable.xcstrings': _catalog,
          'Shortcuts.xcstrings':
              '{"sourceLanguage":"en","version":"1.0","strings":{"third":{}}}',
        },
      );
      final result = await harness.call('sync_preview');
      expect(result.isError, isNot(true));
      final out = result.structuredContent!;
      expect(out['catalogs'], ['Localizable.xcstrings', 'Shortcuts.xcstrings']);
      expect(out.keys, isNot(contains('catalog')));
      final sent = jsonDecode(utf8.decode(base64Decode(
          (jsonDecode(syncs().single.body) as Map)['contentBase64'] as String)))
          as Map;
      expect((sent['strings'] as Map).keys, unorderedEquals(['hello', 'bye', 'third']));
    });

    // `file` overwrites the project's newer values: it is never the default.
    test('without on_conflict the dry run keeps the project value', () async {
      final harness = await start();
      await harness.call('sync_preview');
      expect(jsonDecode(syncs().single.body)['onConflict'], 'server');
    });

    test('a foreign host is refused before the token is sent', () async {
      final harness = await start(
        config: '${_config}baseUrl: https://evil.example\n',
      );
      final result = await harness.call('sync_preview');
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });

    test('a sync past the plan key cap is next: plan_limit', () async {
      dryRun['wouldExceedKeyCap'] = true;
      final harness = await start();
      final result = await harness.call('sync_preview');
      expect(result.structuredContent!['next'], 'plan_limit');
      expect((result.content.single as TextContent).text,
          contains('next: plan_limit'));
    });

    test('a sync that costs 0 goes straight to sync', () async {
      dryRun['estimatedCredits'] = 0;
      final harness = await start();
      final result = await harness.call('sync_preview');
      expect(result.structuredContent!['next'], 'sync');
    });

    group('grades the output format before the spend (#2133)', () {
      // `pull` enables the format of a project that has none, which takes the
      // `write` scope the setup prompt's Agent key does not carry.
      String textOf(CallToolResult result) =>
          (result.content.single as TextContent).text;

      test('no format and a key that cannot enable one is next: '
          'output_format, with both remedies', () async {
        formats = [];
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['next'], 'output_format');
        final graded = result.structuredContent!['output_format'] as Map;
        expect(graded['format'], 'xcstrings');
        expect(graded['state'], 'missing');
        expect(graded['enabled'], isEmpty);
        expect(graded['remedy'], hasLength(2));
        expect(textOf(result), allOf(
          contains('next: output_format'),
          isNot(contains('next: authorize')),
          contains('"xcstrings"'),
          contains('Project > Settings > Output'),
          contains('`easyi18n formats add xcstrings`'),
        ));
        expect(result.structuredContent!['estimated_credits'], 42,
            reason: 'the estimate is still what the human would approve');
      });

      // The server clips every string inside a list to 200 characters, and
      // `findings` is a list: a remedy at the end of one long message never
      // reached the agent.
      test('doctor carries both remedies whole through the output budget',
          () async {
        formats = [];
        final harness = await start();
        final result = await harness.call('doctor');
        final finding = (result.structuredContent!['findings'] as List)
            .cast<Map>()
            .singleWhere((f) => f['check'] == 'output_format');
        expect(finding['level'], 'fail');
        expect(finding['message'], allOf(
            contains('scopes: read, translate, publish'), isNot(contains('…'))));
        expect(finding['details'], [
          'A human enables "xcstrings" under Project > Settings > Output in '
              'the dashboard.',
          'Or a human runs `easyi18n formats add xcstrings` with a key that '
              'has the write scope.',
        ]);
        expect(textOf(result), contains('fail: output_format'));
      });

      test('a key with write keeps next: authorize, because pull enables '
          'the format', () async {
        formats = [];
        scopes = ['read', 'write', 'translate', 'publish'];
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.structuredContent!['next'], 'authorize');
        expect((result.structuredContent!['output_format'] as Map)['state'],
            'adoptable');
      });

      test('an enabled format keeps next: authorize and never reads the '
          'credential', () async {
        formats = ['xcstrings'];
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.structuredContent!['next'], 'authorize');
        expect((result.structuredContent!['output_format'] as Map)['state'],
            'enabled');
        expect(requests.where((r) => r.url.path.endsWith('/credential')),
            isEmpty);
      });

      test('another format enabled is next: output_format for a key with '
          'write too', () async {
        formats = ['json'];
        scopes = ['read', 'write', 'translate', 'publish'];
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.structuredContent!['next'], 'output_format');
        final graded = result.structuredContent!['output_format'] as Map;
        expect(graded['state'], 'conflict');
        expect(graded['enabled'], ['json']);
        expect(graded['remedy'], hasLength(3));
        expect(textOf(result), allOf(contains('enabled: json'),
            contains('Set `format:` in easyi18n.yaml')));
      });

      test('a /meta that fails does not hide the estimate', () async {
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.structuredContent!['next'], 'authorize');
        expect((result.structuredContent!['output_format'] as Map)['state'],
            'unknown');
      });

      test('a /credential the client cannot read does not hide it either',
          () async {
        formats = [];
        scopes = null;
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['estimated_credits'], 42);
        expect(result.structuredContent!['next'], 'authorize');
        expect((result.structuredContent!['output_format'] as Map)['state'],
            'unknown');
      });

      test('the plan key cap is named first', () async {
        formats = [];
        dryRun['wouldExceedKeyCap'] = true;
        final harness = await start();
        final result = await harness.call('sync_preview');
        expect(result.structuredContent!['next'], 'plan_limit');
        expect(textOf(result), allOf(contains('a plan upgrade'),
            isNot(contains('Project > Settings > Output'))));
      });
    });

    test(
      'a code-first project is wrong_family and names push_preview',
      () async {
        final harness = await start(
          config: 'projectId: proj_abc\n',
          files: {
            'pubspec.yaml':
                'name: app\nflutter:\n  uses-material-design: '
                'true\n',
            'lib/main.dart': "final s = tr('Hi');",
          },
        );
        final result = await harness.call('sync_preview');
        expect(errorOf(result)['code'], 'wrong_family');
        expect(errorOf(result)['use_instead'], 'push_preview');
        expect(result.content.single, isA<TextContent>());
        expect(
          (result.content.single as TextContent).text,
          isNot(contains('is for code-first')),
        );
        expect(requests, isEmpty);
      },
    );
  });

  group('authorize {action: translate} on a file-first project', () {
    test('submits the one-batch manifest the sync dry run hashed', () async {
      final harness = await start();
      final result = await harness.call('authorize', {
        'action': 'translate',
        'max_credits': 51,
        'on_conflict': 'file',
      });
      expect(result.isError, isNot(true));
      expect(jsonDecode(syncs().single.body)['onConflict'], 'file');
      final post = requests.singleWhere((r) => r.url.path == '/v1/operations');
      final body = jsonDecode(post.body) as Map;
      expect(body['max_credits'], 50);
      expect(body['scope'], {
        'project_id': 'proj_abc',
        'langs': ['fr', 'de'],
        'unit_count': 2,
        'batches': [
          {'index': 0, 'sha256': 'd' * 64, 'unit_count': 2},
        ],
        'payload_sha256': _payloadCatalog,
      });
      expect(result.structuredContent!['next'], 'wait');
    });

    // The server decodes the catalog with allowMalformed, so a stray byte it
    // priced must not make the entry count throw.
    test('a catalog with a malformed UTF-8 byte is still counted', () async {
      final harness = await start();
      final bytes = utf8.encode(_catalog);
      bytes[_catalog.indexOf('Bye') + 2] = 0xFF;
      File(p.join(dir.path, 'Localizable.xcstrings')).writeAsBytesSync(bytes);
      final result = await harness.call('authorize', {
        'action': 'translate',
        'max_credits': 51,
      });
      expect(result.isError, isNot(true));
      final post = requests.singleWhere((r) => r.url.path == '/v1/operations');
      expect((jsonDecode(post.body) as Map)['scope']['unit_count'], 2);
    });

    test('langs is refused before any request: the catalog carries every '
        'language', () async {
      final harness = await start();
      final result = await harness.call('authorize', {
        'action': 'translate',
        'max_credits': 51,
        'langs': ['fr'],
      });
      expect(errorOf(result)['code'], 'langs_unsupported');
      expect(requests, isEmpty);
    });

    test(
      'a sync that costs 0 has nothing to authorize, and says sync',
      () async {
        dryRun['estimatedCredits'] = 0;
        final harness = await start();
        final result = await harness.call('authorize', {
          'action': 'translate',
          'max_credits': 10,
        });
        expect(errorOf(result)['code'], 'nothing_to_authorize');
        expect(errorOf(result)['message'], contains('Call sync'));
        expect(requests.where((r) => r.url.path == '/v1/operations'), isEmpty);
      },
    );

    test('a sync past the plan key cap is plan_limit and mints nothing',
        () async {
      dryRun['wouldExceedKeyCap'] = true;
      final harness = await start();
      final result = await harness.call(
          'authorize', {'action': 'translate', 'max_credits': 50});
      expect(errorOf(result)['code'], 'plan_limit');
      expect(errorOf(result)['message'], contains('This sync'));
      expect(requests.where((r) => r.method == 'POST' &&
          r.url.path == '/v1/operations'), isEmpty);
    });

    test('an approved operation sends the agent to sync, not push', () async {
      final harness = await start();
      final result = await harness.call('authorize', {
        'action': 'translate',
        'operation_id': 'op_1',
      });
      expect(result.structuredContent!['next'], 'sync');
      expect(
        (result.content.single as TextContent).text,
        contains('Call sync'),
      );
      expect(syncs(), isEmpty);
    });

    test('re-authorizing an approved scope sends the agent to sync',
        () async {
      operationState = 'approved';
      final harness = await start();
      final result = await harness
          .call('authorize', {'action': 'translate', 'max_credits': 51});
      expect(result.structuredContent!['next'], 'sync');
    });

    test('a ceiling below the estimate does not suggest langs', () async {
      final fixture = project(
        config: _config,
        files: {'Localizable.xcstrings': _catalog},
        environment: const {
          'EASYI18N_TOKEN': 'eik_test',
          'EASYI18N_MCP_MAX_CREDITS': '40',
        },
        httpClient: MockClient(backend),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness.call('authorize', {
        'action': 'translate',
        'max_credits': 51,
      });
      expect(errorOf(result)['code'], 'ceiling_below_estimate');
      expect(errorOf(result)['message'], startsWith('The sync is estimated'));
      expect(errorOf(result)['message'], isNot(contains('langs')));
    });

    test('a server without batchSha256 cannot approve a sync', () async {
      dryRun.remove('batchSha256');
      final harness = await start();
      final result = await harness.call('authorize', {
        'action': 'translate',
        'max_credits': 51,
      });
      expect(errorOf(result)['code'], 'operations_unsupported');
      expect(requests.where((r) => r.url.path == '/v1/operations'), isEmpty);
    });
  });

  group('fill_status on a file-first project', () {
    test(
      'polls with the sync dry run and is complete only at 0 credits',
      () async {
        dryRun['estimatedCredits'] = 0;
        final harness = await start();
        final result = await harness.call('fill_status');
        expect(result.isError, isNot(true));
        expect(syncs().single.url.queryParameters['dryRun'], 'true');
        final out = result.structuredContent!;
        expect(out['complete'], isTrue);
        expect(out['pending'], 0);
        expect(out['next'], 'publish');
      },
    );

    test('credits still to spend are not complete, even with nothing in '
        'flight', () async {
      final harness = await start();
      final out = (await harness.call('fill_status')).structuredContent!;
      expect(out['complete'], isFalse);
      expect(out['failed_needs_requeue'], isTrue);
      expect(out['estimated_credits'], 42);
      expect(out['next'], 'ingest_again');
    });

    test('the ingest_again summary says sync, not push', () async {
      final harness = await start();
      final result = await harness.call('fill_status');
      final text = (result.content.single as TextContent).text;
      expect(text, contains('Sync again'));
      expect(text, isNot(contains('Push')));
    });

    test('pairs held by a fill in flight are pending: poll', () async {
      dryRun['estimatedCredits'] = 0;
      dryRun['pendingSkipped'] = 3;
      final harness = await start();
      final out = (await harness.call('fill_status')).structuredContent!;
      expect(out['complete'], isFalse);
      expect(out['pending'], 3);
      expect(out['next'], 'poll');
    });

    test('budget-exhausted pairs ask for a new authorization', () async {
      dryRun['budgetExhausted'] = [
        {'key': 'hello', 'lang': 'fr'},
      ];
      dryRun['exhausted'] = [
        {'key': 'bye', 'lang': 'de'},
      ];
      final harness = await start();
      final out = (await harness.call('fill_status')).structuredContent!;
      expect(out['budget_exhausted'], [
        {'key': 'hello', 'lang': 'fr'},
      ]);
      expect(out['budget_exhausted_total'], 1);
      expect(out['exhausted'], [
        {'key': 'bye', 'lang': 'de'},
      ]);
      expect(out['next'], 'reauthorize');
    });

    test('an operation that ran its attempts asks for a new authorization '
        'that names sync', () async {
      operation['attempts'] = [
        for (var i = 1; i <= 3; i++)
          {
            'id': 'a_$i',
            'requests': [
              {'id': 'r_$i', 'batch_index': 0, 'state': 'done'},
            ],
          },
      ];
      final harness = await start(
        files: {
          'Localizable.xcstrings': _catalog,
          '.easyi18n/operations/op_1.json': jsonEncode({
            'family': 'file-first',
            'requests': [
              for (var i = 1; i <= 3; i++)
                {
                  'request_id': 'r_$i',
                  'attempt_id': 'a_$i',
                  'batch_index': 0,
                  'action': 'translate',
                  'batch_sha256': 'd' * 64,
                  'sent_at': DateTime.now().toUtc().toIso8601String(),
                  'state': 'accepted',
                },
            ],
          }),
        },
      );
      final result = await harness.call('fill_status');
      expect(result.structuredContent!['next'], 'reauthorize');
      expect(
        (result.content.single as TextContent).text,
        contains('another sync under it is refused'),
      );
    });

    test('a sync that continues its last attempt says so', () async {
      final harness = await start(
        files: {
          'Localizable.xcstrings': _catalog,
          '.easyi18n/operations/op_1.json': jsonEncode({
            'family': 'file-first',
            'requests': [
              {
                'request_id': 'r_1',
                'attempt_id': 'a_1',
                'batch_index': 0,
                'action': 'translate',
                'batch_sha256': 'd' * 64,
                'sent_at': DateTime.now().toUtc().toIso8601String(),
                'state': 'lost',
                'response': {'server_state': 'unknown'},
              },
            ],
          }),
        },
      );
      final result = await harness.call('fill_status');
      expect(result.structuredContent!['next'], 'ingest_again');
      final text = (result.content.single as TextContent).text;
      expect(text, contains('Sync again'));
      expect(text, contains('continues the last attempt'));
      expect(text, isNot(contains('at most twice')));
    });

    test('settles a sent intent of a sync like one of a push', () async {
      dryRun['estimatedCredits'] = 0;
      final harness = await start();
      final log = File(p.join(dir.path, '.easyi18n', 'operations', 'op_1.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'family': 'file-first',
            'catalog': 'Localizable.xcstrings',
            'key_policy': 'local_owns',
            'requests': [
              {
                'request_id': 'r_1',
                'attempt_id': 'a_1',
                'batch_index': 0,
                'action': 'translate',
                'sent_at': DateTime.now().toUtc().toIso8601String(),
                'state': 'sent',
              },
            ],
          }),
        );
      final out = (await harness.call('fill_status')).structuredContent!;
      expect(out['reconciled'], [
        {
          'request_id': 'r_1',
          'was': 'sent',
          'state': 'accepted',
          'server_state': 'done',
        },
      ]);
      final written = jsonDecode(log.readAsStringSync()) as Map;
      expect(
        ((written['requests'] as List).single as Map)['state'],
        'accepted',
      );
      expect(written['key_policy'], 'local_owns');
    });

    test('langs is refused before any request', () async {
      final harness = await start();
      final result = await harness.call('fill_status', {
        'langs': ['fr'],
      });
      expect(errorOf(result)['code'], 'langs_unsupported');
      expect(requests, isEmpty);
    });
  });

  group('sync', () {
    // The body fields that name the request, not the batch the server hashes.
    const identity = [
      'operationId',
      'attemptId',
      'requestId',
      'batchIndex',
      'batchSha256',
    ];

    Map<String, Object?> bodyOf(http.Request r) =>
        (jsonDecode(r.body) as Map).cast<String, Object?>();

    List<http.Request> realSyncs() => [
      for (final r in syncs())
        if (r.url.queryParameters['dryRun'] != 'true') r,
    ];

    Map<String, Object?>? logged(String relative) {
      final file = File(p.join(dir.path, '.easyi18n', 'operations', relative));
      if (!file.existsSync()) return null;
      return (jsonDecode(file.readAsStringSync()) as Map).cast();
    }

    Future<CallToolResult> sync(
      Map<String, Object?> arguments, {
      Map<String, String> extraFiles = const {},
      String config = _config,
    }) async {
      final harness = await start(
        config: config,
        files: {'Localizable.xcstrings': _catalog, ...extraFiles},
      );
      return harness.call('sync', arguments);
    }

    test('sends the body the dry run priced, with its identity, after its '
        'intent is on disk', () async {
      final result = await sync(
        {'operation_id': 'op_1', 'on_conflict': 'file'},
        extraFiles: {
          '.easyi18n/state.json': jsonEncode({
            'catalog': 'Localizable.xcstrings',
            'format': 'xcstrings',
            'snapshotAt': '2026-09-20T10:00:00Z',
          }),
        },
      );
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');

      final priced = bodyOf(syncs().first);
      expect(syncs().first.url.queryParameters['dryRun'], 'true');
      expect(priced['pulledAt'], '2026-09-20T10:00:00.000Z');
      expect(priced['onConflict'], 'file');
      final sent = bodyOf(realSyncs().single);
      expect(
        {
          for (final e in sent.entries)
            if (!identity.contains(e.key)) e.key: e.value,
        },
        priced,
        reason: 'the approved hash is the hash of the priced body',
      );
      expect(sent['operationId'], 'op_1');
      expect(sent['batchIndex'], 0);
      expect(sent['batchSha256'], 'd' * 64);
      expect(sent['attemptId'], isA<String>());
      expect(sent['requestId'], isA<String>());

      final atSend = logAtSend!;
      expect(atSend['family'], 'file-first');
      expect(atSend['payload_sha256'], _payloadCatalog);
      expect(atSend['target'], 'https://api.easyi18n.com/proj_abc');
      expect(atSend['catalog'], 'Localizable.xcstrings');
      expect(atSend['key_policy'], 'local_owns');
      expect(atSend['authorized_mc'], 50000);
      expect((atSend['requests'] as List).single, {
        'request_id': sent['requestId'],
        'attempt_id': sent['attemptId'],
        'batch_index': 0,
        'action': 'translate',
        'batch_sha256': 'd' * 64,
        'sent_at': isA<String>(),
        'state': 'sent',
      });

      final after = logged('op_1.json')!;
      final request = (after['requests'] as List).single as Map;
      expect(request['state'], 'accepted');
      expect((request['response'] as Map)['tracking_token'], 'job_0');
      expect(
        RequestLog.recordedKeyPolicy(dir.path, 'Localizable.xcstrings'),
        'local_owns',
        reason: 'pull reads the policy by the config catalog string (D16)',
      );

      final out = result.structuredContent!;
      expect(out['next'], 'fill_status');
      expect(out['catalog'], 'Localizable.xcstrings');
      expect(out['tracking_tokens'], ['job_0']);
      expect(out['conflicts'], dryRun['conflicts']);
      expect(out['diagnostics'], dryRun['diagnostics']);
      expect(out.keys, isNot(contains('language_files')));
      expect((result.content.single as TextContent).text,
          isNot(contains('language file')));
      expect(syncs().where((r) => r.url.queryParameters['dryRun'] != 'true'),
          hasLength(1), reason: 'a catalog with every language is one request');
      expect(out['attempt'], {
        'id': sent['attemptId'],
        'requests': [
          {'id': sent['requestId'], 'state': 'accepted'},
        ],
      });
      expect((out['operation'] as Map)['authorized_mc'], 50000);
    });

    // fill_status cannot see an entry a create race left unwritten: with
    // nothing left to price it would send the agent on to publish.
    test('entries a create race left unwritten send the agent back to sync',
        () async {
      realReply = http.Response(
        jsonEncode({
          ...dryRun,
          'dryRun': false,
          'trackingToken': 'job_0',
          'failedEntries': [
            {'key': 'hello', 'code': 'contended', 'reason': 'peer sync'},
          ],
        }),
        200,
      );
      final result = await sync({'operation_id': 'op_1'});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['next'], 'sync');
      expect(
        (result.content.single as TextContent).text,
        contains('call sync again with the same operation_id'),
      );
      expect(realSyncs(), hasLength(1), reason: 'the tool never re-sends');
    });

    test('conflicts past the output budget are cut and marked truncated',
        () async {
      final rows = [
        for (var i = 0; i < 2000; i++)
          {'key': 'key_$i', 'lang': 'en', 'origin': 'human', 'value': 'x' * 300},
      ];
      realReply = http.Response(
        jsonEncode({
          ...dryRun,
          'dryRun': false,
          'trackingToken': 'job_0',
          'conflicts': rows,
          'conflictsTotal': 2000,
        }),
        200,
      );
      final result = await sync({'operation_id': 'op_1'});
      final out = result.structuredContent!;
      expect(out['truncated'], isTrue);
      expect(out['conflicts_total'], 2000);
      expect((out['conflicts'] as List), isNotEmpty);
      expect((out['conflicts'] as List).length, lessThan(2000));
      expect(utf8.encode(jsonEncode(out)).length, lessThanOrEqualTo(32 * 1024));
      expect(out['next'], 'fill_status');
    });

    test('a billable sync without operation_id is authorization_required',
        () async {
      final result = await sync({});
      expect(errorOf(result)['code'], 'authorization_required');
      expect(errorOf(result)['estimated_credits'], 42);
      expect(realSyncs(), isEmpty);
      expect(
        requests.where((r) => r.url.path.startsWith('/v1/operations')),
        isEmpty,
      );
    });

    test('a 403 authorization_required on the real sync hands the estimate '
        'over, in credits', () async {
      dryRun['estimatedCredits'] = 0;
      realReply = http.Response(
        jsonEncode({
          'error': 'authorization_required',
          'message': 'an Agent key needs an approved translate operation: '
              'request one with POST /v1/operations and send its operationId',
          'estimatedCredits': 156,
        }),
        403,
      );
      final result = await sync({});
      expect(errorOf(result)['code'], 'authorization_required');
      expect(errorOf(result)['estimated_credits'], 0.156);
      expect(errorOf(result)['message'], isNot(contains('scope')));
      expect(errorOf(result)['message'],
          contains('authorize {action: translate}'));
      expect(errorOf(result)['message'], isNot(contains('/v1/operations')));
      expect(errorOf(result)['attempt'], isA<Map<Object?, Object?>>());
    });

    for (final (label, arguments) in [
      ('under an approved operation', {'operation_id': 'op_1'}),
      ('without an operation', <String, Object?>{}),
    ]) {
      test('a sync past the plan key cap, $label, is plan_limit before the '
          'real sync', () async {
        dryRun['wouldExceedKeyCap'] = true;
        final result = await sync(arguments);
        expect(errorOf(result)['code'], 'plan_limit');
        expect(realSyncs(), isEmpty);
        expect(
          requests.where((r) => r.url.path.startsWith('/v1/operations')),
          isEmpty,
        );
      });
    }

    test('a free sync needs no operation and logs under free/', () async {
      dryRun['estimatedCredits'] = 0;
      final result = await sync({});
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      final sent = bodyOf(realSyncs().single);
      expect(sent.containsKey('operationId'), isFalse);
      expect(sent['requestId'], isA<String>());
      expect(
        (logAtSend!['requests'] as List).single,
        containsPair('state', 'sent'),
      );
      expect(logged('free/${sent['attemptId']}.json'), isNotNull);
      expect(result.structuredContent!['operation'], isNull);
    });

    for (final (state, code) in [
      ('pending_approval', 'authorization_required'),
      ('denied', 'authorization_required'),
      ('expired', 'expired'),
      ('exhausted', 'budget_exhausted'),
    ]) {
      test('a $state operation is $code, before the real sync', () async {
        operation['state'] = state;
        final result = await sync({'operation_id': 'op_1'});
        expect(errorOf(result)['code'], code);
        expect(realSyncs(), isEmpty);
        expect(logged('op_1.json'), isNull);
      });
    }

    test('an approved publish operation is action_mismatch, before the real '
        'sync', () async {
      operation['action'] = 'publish';
      operation['scope'] = <String, Object?>{'project_id': 'proj_abc'};
      final result = await sync({'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'action_mismatch');
      expect(realSyncs(), isEmpty);
    });

    test('a catalog that changed since the approval is scope_changed',
        () async {
      operation['scope'] = <String, Object?>{'payload_sha256': '0' * 64};
      final result = await sync({'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'scope_changed');
      expect(realSyncs(), isEmpty);
    });

    test('an operation authorized above the local ceiling is refused',
        () async {
      operation['authorized_mc'] = 50001;
      final result = await sync({'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'above_ceiling');
      expect(realSyncs(), isEmpty);
    });

    test('a non-409 response with request_in_progress stays refused', () async {
      realReply = http.Response(jsonEncode({'error': 'request_in_progress'}), 400);
      final result = await (await start()).call('sync', {'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'request_in_progress');
      expect(RequestLog.all(dir.path).single.requests.single['state'], 'refused');
    });

    test('a refused sync keeps the answer in the log', () async {
      realReply = http.Response(
        jsonEncode({'error': 'batch_replayed', 'message': 'replayed'}),
        409,
      );
      final result = await sync({'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'batch_replayed');
      final request = (logged('op_1.json')!['requests'] as List).single as Map;
      expect(request['state'], 'refused');
      expect(errorOf(result)['attempt'], {
        'id': request['attempt_id'],
        'requests': [
          {'id': request['request_id'], 'state': 'refused'},
        ],
      });
      expect((request['response'] as Map)['code'], 'batch_replayed');
    });

    for (final (label, reply) in [
      ('a 5xx', http.Response('upstream', 503)),
      ('a bare 500', http.Response('boom', 500)),
      ('a 200 it cannot read', http.Response('[7]', 200)),
    ]) {
      test('$label leaves the intent sent: the server may have acted',
          () async {
        realReply = reply;
        final result = await sync({'operation_id': 'op_1'});
        expect(errorOf(result)['code'], 'request_unresolved');
        final request =
            (logged('op_1.json')!['requests'] as List).single as Map;
        expect(request['state'], 'sent');
        expect(realSyncs(), hasLength(1));
        // No language file to send, so no dry run asks whether it landed.
        expect(requests.last.url.queryParameters['dryRun'], isNull);
      });
    }

    test('an intent still sent refuses before any request', () async {
      final result = await sync({'operation_id': 'op_1'}, extraFiles: {
        '.easyi18n/operations/free/a_1.json': jsonEncode({
          'requests': [
            {'request_id': 'r_1', 'attempt_id': 'a_1', 'batch_index': 0,
              'state': 'sent'},
          ],
        }),
      });
      expect(errorOf(result)['code'], 'request_unresolved');
      expect(requests, isEmpty);
    });

    test('EASYI18N_MCP_MAX_CREDITS=0 disables real syncs, free ones too',
        () async {
      dryRun['estimatedCredits'] = 0;
      final fixture = project(
        config: _config,
        files: {'Localizable.xcstrings': _catalog},
        environment: const {
          'EASYI18N_TOKEN': 'eik_test',
          'EASYI18N_MCP_MAX_CREDITS': '0',
        },
        httpClient: MockClient(backend),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness.call('sync');
      expect(errorOf(result)['code'], 'ingests_disabled');
      expect(requests, isEmpty);
    });

    test('a foreign host is refused before the token is sent', () async {
      final result = await sync(
        {'operation_id': 'op_1'},
        config: '${_config}baseUrl: https://evil.example\n',
      );
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });

    test('operation_id "../escape" never names a file or reaches the server',
        () async {
      final result = await sync({'operation_id': '../escape'});
      expect(errorOf(result)['code'], 'invalid_operation_id');
      expect(requests, isEmpty);
    });

    test('a code-first project is wrong_family and names push', () async {
      final harness = await start(
        config: 'projectId: proj_abc\n',
        files: {
          'pubspec.yaml': 'name: app\nflutter:\n  uses-material-design: true\n',
          'lib/main.dart': "final s = tr('Hi');",
        },
      );
      final result = await harness.call('sync', {'operation_id': 'op_1'});
      expect(errorOf(result)['code'], 'wrong_family');
      expect(errorOf(result)['use_instead'], 'push');
      expect(requests, isEmpty);
    });

    test('two syncs racing in one session run one after the other, and the '
        'log holds both requests', () async {
      latency = const Duration(milliseconds: 20);
      final harness = await start();
      final results = await Future.wait([
        harness.call('sync', {'operation_id': 'op_1'}),
        harness.call('sync', {'operation_id': 'op_1'}),
      ]);
      expect(results.map((r) => r.isError), [isNot(true), isNot(true)]);
      expect(
        syncs().map((r) => r.url.queryParameters['dryRun']),
        ['true', null, 'true', null],
        reason: 'the second sync started before the first one answered',
      );
      final sent = realSyncs().map(bodyOf).toList();
      final after = logged('op_1.json')!['requests'] as List;
      expect(
        after.map((r) => (r as Map)['request_id']),
        unorderedEquals(sent.map((b) => b['requestId'])),
        reason: 'a request the server received has no intent on disk',
      );
      expect(after.map((r) => (r as Map)['state']), everyElement('accepted'));
    });
  });
}
