@TestOn('vm')
library;

import 'dart:convert';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show errorOf, project;

const _config = 'projectId: proj_abc\nmode: a\nformat: android_xml\n'
    'output: app/src/main/res\nsource: app/src/main/res/values/strings.xml\n';

/// The fixture of the acceptance of #2286: four keys the server imports, one
/// `translatable="false"`, and a base-only `checkout` for the fill.
const _base = '''
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
    <!-- <string name="commented">not a resource</string> -->
    <string name="app_name" translatable="false">Demo Shop</string>
    <string name="greeting">Hello, %1\$s! Don\\'t miss today\\'s deals.</string>
    <string name="cart_status">You have <xliff:g id="count">%1\$d</xliff:g> items</string>
    <plurals name="item_count">
        <item quantity="one">%1\$d item</item>
        <item quantity="other">%1\$d items</item>
    </plurals>
    <string-array name="sizes"><item>S</item></string-array>
    <string name="checkout">Pay %1\$s now</string>
</resources>
''';

const _es = '''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="greeting">¡Hola, %1\$s!</string>
</resources>
''';

final _tree = {
  'settings.gradle': "include ':app'\n",
  'app/src/main/res/values/strings.xml': _base,
  'app/src/main/res/values-es/strings.xml': _es,
  'app/src/main/res/values-fr/strings.xml': '<resources/>\n',
};

void main() {
  late List<http.Request> requests;
  late Map<String, Object?>? approvedScope;
  late http.Response Function(Map<String, Object?> body)? targetReply;
  late int estimate;
  // The real base POST whose answer never reaches the client, and whether
  // the server applied it first (#2319).
  late ({bool applied, Future<http.Response> Function() answer})? lostBase;
  late bool baseApplied;

  setUp(() {
    requests = [];
    approvedScope = null;
    targetReply = null;
    estimate = 600;
    lostBase = null;
    baseApplied = false;
  });

  Map<String, Object?> syncReply({required bool dryRun, String? lang}) => {
    'dryRun': dryRun, 'batchSha256': 'd' * 64, 'format': 'android_xml',
    'baseCode': 'en', 'targetLangs': ['es'], 'fillableLangs': ['es'],
    'created': lang == null && !(dryRun && baseApplied) ? 4 : 0,
    'updatedSources': 0, 'matchedSources': 0,
    'updatedTranslations': lang == null ? 0 : 1, 'unchangedTranslations': 0,
    'disabledOrphans': 0, 'reenabled': 0, 'failedEntries': [],
    'exhausted': [], 'budgetExhausted': [], 'onConflict': 'server',
    'conflicts': [], 'conflictsTotal': 0, 'diagnostics': [],
    'trackingToken': dryRun || lang != null ? null : 'job_0',
    'estimatedCredits': lang == null ? estimate : 0, 'balance': 900000,
    'availableCredits': 900000, 'accepted': true,
  };

  Future<http.Response> backend(http.Request req) async {
    requests.add(req);
    final path = req.url.path;
    if (path.endsWith('/meta')) {
      return http.Response(jsonEncode({
        'baseCode': 'en', 'formats': ['android_xml'],
        'outputFormatsApiVersion': 1,
        'languages': [
          {'code': 'en', 'isBase': true}, {'code': 'es', 'isBase': false},
        ],
      }), 200);
    }
    if (path.endsWith('/sync')) {
      final body = (jsonDecode(req.body) as Map).cast<String, Object?>();
      final lang = body['lang'] as String?;
      final dryRun = req.url.queryParameters['dryRun'] == 'true';
      if (lang != null && targetReply != null) return targetReply!(body);
      if (!dryRun && lang == null) {
        if (lostBase case final lost?) {
          baseApplied = lost.applied;
          return lost.answer();
        }
        baseApplied = true;
      }
      return http.Response(
          jsonEncode(syncReply(dryRun: dryRun, lang: lang)), 200);
    }
    if (path == '/v1/operations') {
      approvedScope =
          ((jsonDecode(req.body) as Map)['scope'] as Map).cast();
      return http.Response(jsonEncode({
        'operation_id': 'op_1', 'action': 'translate',
        'state': 'pending_approval',
        'approval_url': 'https://app.easyi18n.com/approve/op_1',
      }), 201);
    }
    if (path == '/v1/operations/op_1') {
      return http.Response(jsonEncode({
        'operation_id': 'op_1', 'action': 'translate', 'state': 'approved',
        'scope': approvedScope, 'authorized_mc': 1000, 'reserved_mc': 0,
        'charged_mc': 0,
      }), 200);
    }
    return http.Response('{"error":"not_found"}', 404);
  }

  Future<McpHarness> start() async {
    final fixture =
        project(config: _config, files: _tree, httpClient: MockClient(backend));
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness;
  }

  List<Map<String, Object?>> realSyncs() => [
    for (final r in requests)
      if (r.url.path.endsWith('/sync') &&
          r.url.queryParameters['dryRun'] != 'true')
        (jsonDecode(r.body) as Map).cast<String, Object?>(),
  ];

  // The human approves the count the manifest carries, and the server refuses
  // an operation that counts none. It is the resources the server imports:
  // not app_name, not the string-array, not the commented-out string.
  test('authorize counts the strings.xml resources the server imports',
      () async {
    final harness = await start();
    final result = await harness
        .call('authorize', {'action': 'translate', 'max_credits': 1});
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
    expect(result.structuredContent!['operation_id'], 'op_1');
    expect(approvedScope!['unit_count'], 4);
    expect(approvedScope!['batches'], [
      {'index': 0, 'sha256': 'd' * 64, 'unit_count': 4},
    ]);
  });

  test('fill_status reads an Android project', () async {
    final harness = await start();
    final result = await harness.call('fill_status');
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
  });

  // The CLI's order (`SyncRunner.run`): the base creates the keys, then each
  // values-<lang> file imports its cells before the fill's tick reaches them.
  // Without it the fill writes the languages the project already translated
  // by hand and the next pull overwrites them.
  test('sync uploads each values-<lang> file with its lang after the base',
      () async {
    final harness = await start();
    await harness.call('authorize', {'action': 'translate', 'max_credits': 1});
    final result = await harness.call('sync', {'operation_id': 'op_1'});
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
    final sent = realSyncs();
    expect(sent.map((b) => (b['fileName'], b['lang'])), [
      ('strings.xml', null),
      ('values-es/strings.xml', 'es'),
    ]);
    expect(sent.first['operationId'], 'op_1');
    // A file with a lang never queues a fill, so it spends no operation.
    for (final field in ['operationId', 'attemptId', 'requestId']) {
      expect(sent.last.containsKey(field), isFalse, reason: field);
    }
    expect(utf8.decode(base64Decode(sent.last['contentBase64'] as String)),
        _es);
    final out = result.structuredContent!;
    expect(out['tracking_tokens'], ['job_0']);
    expect(out['language_files'], [
      {'file': 'values-es/strings.xml', 'lang': 'es',
        'updated_translations': 1, 'unchanged_translations': 0,
        'conflicts_total': 0, 'failed_entries': []},
    ]);
    expect(out['skipped_language_files'],
        ['values-fr/strings.xml (fr is not a target language of the project)']);
  });

  // The base is applied and its fill paid for by then: an error result would
  // hide the tracking token and invite a second ingest of the same operation.
  test('a refused language file is data in a sync that went through',
      () async {
    final harness = await start();
    targetReply = (_) => http.Response(jsonEncode({
      'error': 'invalid_argument', 'message': 'add the language first',
    }), 400);
    await harness.call('authorize', {'action': 'translate', 'max_credits': 1});
    final result = await harness.call('sync', {'operation_id': 'op_1'});
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
    expect(result.structuredContent!['tracking_tokens'], ['job_0']);
    expect(result.structuredContent!['language_files'], [
      {'file': 'values-es/strings.xml', 'lang': 'es',
        'error': {'code': 'invalid_argument',
          'message': 'Sync failed: add the language first'}},
    ]);
    expect(result.structuredContent!['next'], 'fill_status');
    expect((result.content.single as TextContent).text,
        contains('1 language file(s) uploaded, 1 refused (see language_files).'));
  });

  test('sync_preview names the language files a sync would upload', () async {
    final harness = await start();
    final result = await harness.call('sync_preview');
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
    expect(result.structuredContent!['language_files'], [
      {'file': 'values-es/strings.xml', 'lang': 'es'},
    ]);
    expect(result.structuredContent!['skipped_language_files'],
        ['values-fr/strings.xml (fr is not a target language of the project)']);
    expect(realSyncs(), isEmpty);
  });

  test('a free sync uploads the language files too', () async {
    estimate = 0;
    final harness = await start();
    final result = await harness.call('sync');
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
    expect(realSyncs().map((b) => (b['fileName'], b['lang'])), [
      ('strings.xml', null),
      ('values-es/strings.xml', 'es'),
    ]);
  });

  // on_conflict is part of what the human approves; a language file that
  // dropped it would keep the project's values the human chose to overwrite.
  test('the language files carry the on_conflict of the sync', () async {
    estimate = 0;
    final harness = await start();
    final result = await harness.call('sync', {'on_conflict': 'file'});
    expect(result.isError, isNot(true),
        reason: '${result.structuredContent}');
    expect(realSyncs().map((b) => (b['lang'], b['onConflict'])), [
      (null, 'file'),
      ('es', 'file'),
    ]);
  });

  test('a sync that needs an operation uploads nothing', () async {
    final harness = await start();
    expect(errorOf(await harness.call('sync'))['code'],
        'authorization_required');
    expect(realSyncs(), isEmpty);
  });

  // The server applied the base and queued its fill; only the answer was
  // lost. fill_status will reconcile the request as done, so the files go
  // now, before that fill's tick, or the fill writes the cells the project
  // translated by hand and charges for them (#2319).
  for (final (lost, answer) in [
    ('a 503', () async => http.Response('{"error":"unavailable"}', 503)),
    ('a 409 request_in_progress',
        () async => http.Response('{"error":"request_in_progress"}', 409)),
    ('a dropped socket',
        () async => throw http.ClientException('Connection reset by peer')),
  ]) {
    test('a base answer lost to $lost still uploads the language files',
        () async {
      lostBase = (applied: true, answer: answer);
      final harness = await start();
      await harness.call('authorize', {'action': 'translate', 'max_credits': 1});
      final error = errorOf(await harness.call('sync', {'operation_id': 'op_1'}));
      expect(error['code'], 'request_unresolved');
      expect(realSyncs().map((b) => (b['fileName'], b['lang'])), [
        ('strings.xml', null),
        ('values-es/strings.xml', 'es'),
      ]);
      expect(error['language_files'], [
        {'file': 'values-es/strings.xml', 'lang': 'es',
          'updated_translations': 1, 'unchanged_translations': 0,
          'conflicts_total': 0, 'failed_entries': []},
      ]);
      // Still sent: fill_status reconciles it from the server's record.
      expect((error['attempt'] as Map)['requests'], [
        {'id': isA<String>(), 'state': 'sent'},
      ]);
    });
  }

  // Nothing landed, so fill_status answers ingest_again and the next sync
  // uploads the base and then the files, as after any answer.
  test('a base request that never reached the server uploads no language '
      'file', () async {
    lostBase = (applied: false,
        answer: () async => throw http.ClientException('Connection reset'));
    final harness = await start();
    await harness.call('authorize', {'action': 'translate', 'max_credits': 1});
    final error = errorOf(await harness.call('sync', {'operation_id': 'op_1'}));
    expect(error['code'], 'request_unresolved');
    expect(realSyncs().map((b) => b['lang']), [null]);
    expect(error.containsKey('language_files'), isFalse);
  });
}
