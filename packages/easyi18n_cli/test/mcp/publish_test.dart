@TestOn('vm')
library;

import 'dart:convert';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show errorOf, project;

void main() {
  late List<http.Request> requests;
  late Map<String, Object?> published;
  late int publishStatus;
  late Map<String, Object?> operation;

  setUp(() {
    requests = [];
    publishStatus = 201;
    published = {'versionId': '2026.09.22.1', 'keyCount': 7};
    operation = {
      'operation_id': 'op_p1',
      'action': 'publish',
      'state': 'pending_approval',
      'scope': <String, Object?>{},
      'authorized_mc': 0,
      'approval_url': 'https://app.easyi18n.com/approve/op_p1',
      'expires_at': '2026-09-22T16:00:00Z',
    };
  });

  Future<http.Response> backend(http.Request req) async {
    requests.add(req);
    if (req.url.path.endsWith('/publish')) {
      return http.Response(jsonEncode(published), publishStatus);
    }
    return http.Response(
        jsonEncode(operation), req.method == 'POST' ? 201 : 200);
  }

  Future<CallToolResult> call(
    String tool,
    Map<String, Object?> arguments, {
    String config = 'projectId: proj_abc\n',
  }) async {
    final fixture = project(config: config, httpClient: MockClient(backend));
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness.call(tool, arguments);
  }

  Map<String, Object?> bodyOf(http.Request request) =>
      (jsonDecode(request.body) as Map).cast<String, Object?>();

  http.Request publishRequest() =>
      requests.singleWhere((r) => r.url.path.endsWith('/publish'));

  group('the approval is mandatory', () {
    test('publish without operation_id refuses before any request', () async {
      final result = await call('publish', {});
      expect(result.isError, isTrue,
          reason: '${result.content.map((c) => (c as TextContent).text)}');
      expect(errorOf(result)['code'], 'authorization_required');
      expect(requests, isEmpty);
    });

    test('a blank operation_id is not an operation', () async {
      final result = await call('publish', {'operation_id': '  '});
      expect(errorOf(result)['code'], 'authorization_required');
      expect(requests, isEmpty);
    });

    // D4: the token never reaches a host the config points at unless it is ours.
    test('an untrusted base_url is refused before any request', () async {
      final result = await call('publish', {'operation_id': 'op_p1'},
          config: 'projectId: proj_abc\nbaseUrl: https://evil.example\n');
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });
  });

  group('the filters the human approved are the filters that travel', () {
    test('a publish sends the operation and the resolved filters', () async {
      final result = await call('publish', {'operation_id': 'op_p1'});
      expect(result.isError, isNot(true));
      expect(bodyOf(publishRequest()), {
        'incompleteMode': 'source',
        'skipIfIdentical': true,
        'require_complete': true,
        'operationId': 'op_p1',
      });
      expect(result.structuredContent, {
        'version_id': '2026.09.22.1',
        'key_count': 7,
        'unchanged': false,
        'refused': {'icu': [], 'icu_total': 0, 'markup': [], 'markup_total': 0},
        'pending_at_publish': 0,
        'incomplete_mode': 'source',
        'next': 'pull',
      });
    });

    test('Mode A leaves an untranslated cell out instead of shipping the '
        'source', () async {
      await call('publish', {'operation_id': 'op_p1'},
          config: 'projectId: proj_abc\nmode: a\n');
      expect(bodyOf(publishRequest())['incompleteMode'], 'skip');
    });

    test('an explicit incomplete_mode wins over the config', () async {
      await call('publish',
          {'operation_id': 'op_p1', 'incomplete_mode': 'skip'});
      expect(bodyOf(publishRequest())['incompleteMode'], 'skip');
    });

    test('approved_only travels and defaults to false', () async {
      await call('publish', {'operation_id': 'op_p1', 'approved_only': true});
      expect(bodyOf(publishRequest())['approvedOnly'], true);
    });

    test('require_complete:false leaves the gate off, and nothing counted '
        'the pending', () async {
      final result = await call(
          'publish', {'operation_id': 'op_p1', 'require_complete': false});
      // Absent, not `false`: the door reads the two the same way, and the
      // shipped CLI publishes without the field.
      expect(bodyOf(publishRequest()).containsKey('require_complete'), isFalse);
      expect(result.structuredContent!['pending_at_publish'], isNull);
    });

    test('skip_if_identical:false asks for a new version either way',
        () async {
      await call(
          'publish', {'operation_id': 'op_p1', 'skip_if_identical': false});
      expect(bodyOf(publishRequest()).containsKey('skipIfIdentical'), isFalse);
    });

    test('an unchanged publish says so instead of claiming a new version',
        () async {
      publishStatus = 200;
      published = {
        'versionId': '2026.09.21.3',
        'keyCount': 7,
        'unchanged': true,
      };
      final result = await call('publish', {'operation_id': 'op_p1'});
      expect(result.structuredContent!['unchanged'], isTrue);
      expect((result.content.single as TextContent).text,
          contains('nothing changed'));
    });

    test('refused cells reach the agent with their totals, not their length',
        () async {
      published = {
        'versionId': '2026.09.22.1',
        'keyCount': 7,
        'icuRejected': ['Hi {n} [fr]: bad plural'],
        'icuRejectedTotal': 63,
        'markupRejected': <String>[],
        'markupRejectedTotal': 0,
      };
      final result = await call('publish', {'operation_id': 'op_p1'});
      expect(result.structuredContent!['refused'], {
        'icu': ['Hi {n} [fr]: bad plural'],
        'icu_total': 63,
        'markup': <String>[],
        'markup_total': 0,
      });
      expect((result.content.single as TextContent).text,
          contains('63 cell(s) refused'));
    });
  });

  group('what the door refuses', () {
    test('fill_incomplete carries the counts the agent has to act on',
        () async {
      publishStatus = 409;
      published = {
        'error': 'fill_incomplete',
        'message': 'the publication snapshot is incomplete',
        'pending': 4,
        'exhausted': [
          {'key': 'Hello', 'lang': 'fr'},
        ],
        'exhausted_total': 12,
        'refused': {
          'icu': <String>[],
          'icu_total': 0,
          'markup': <String>[],
          'markup_total': 0,
        },
      };
      final result = await call('publish', {'operation_id': 'op_p1'});
      expect(result.isError, isTrue);
      final error = errorOf(result);
      expect(error['code'], 'fill_incomplete');
      expect(error['pending'], 4);
      expect(error['exhausted'], [
        {'key': 'Hello', 'lang': 'fr'},
      ]);
      expect(error['exhausted_total'], 12);
      expect(error['refused'], isA<Map<Object?, Object?>>());
      // The whole point of naming this refusal: the server's own sentence
      // says the snapshot is incomplete and stops there, which leaves the
      // agent with nothing to do next.
      expect(error['message'], contains('require_complete: false'));
      // The refusal is the answer; it never costs a second call.
      expect(requests, hasLength(1));
    });

    // The 409 of `approved_only` with everything translated and nothing
    // approved (#1835): fill_status already says complete, so a text that
    // sends the agent to poll until it is complete never ends.
    test('pending cells send the agent to fill_status and its next, never '
        'to a poll, and bound the retry', () async {
      publishStatus = 409;
      published = {
        'error': 'fill_incomplete',
        'message': 'the publication snapshot is incomplete',
        'pending': 8,
        'exhausted': <Object?>[],
        'exhausted_total': 0,
        'refused': {
          'icu': <String>[],
          'icu_total': 0,
          'markup': <String>[],
          'markup_total': 0,
        },
      };
      final result = await call(
          'publish', {'operation_id': 'op_p1', 'approved_only': true});
      final text = (result.content.single as TextContent).text;
      expect(text, contains('Call fill_status and follow its next'));
      expect(text, isNot(matches(RegExp(r'\bpoll', caseSensitive: false))));
      expect(text, contains('this refusal comes back, do not publish again'));
      expect(text, contains('Under approved_only a cell also needs'));
      expect(text, isNot(contains('gates')));
      expect(text, isNot(contains('fill attempts')));
      expect(text, contains('require_complete: false'));
    });

    test('refused and exhausted cells are counted from their totals and '
        'handed to the human', () async {
      publishStatus = 409;
      published = {
        'error': 'fill_incomplete',
        'message': 'the publication snapshot is incomplete',
        'pending': 4,
        'exhausted': [
          {'key': 'Hello', 'lang': 'fr'},
        ],
        'exhausted_total': 12,
        'refused': {
          'icu': ['Hi {n} [fr]: bad plural'],
          'icu_total': 3,
          'markup': ['<b>Hi [de]: unclosed'],
          'markup_total': 2,
        },
      };
      final result = await call('publish', {'operation_id': 'op_p1'});
      final text = (result.content.single as TextContent).text;
      expect(text, contains('5 cell(s) were refused by the ICU or markup '
          'gates'));
      expect(text, contains('12 pair(s) used up their fill attempts'));
      expect(text, contains('Call fill_status'));
      expect(text, isNot(contains('approved_only')));
    });

    test('exhausted pairs with nothing pending do not send the agent to '
        'fill_status', () async {
      publishStatus = 409;
      published = {
        'error': 'fill_incomplete',
        'message': 'the publication snapshot is incomplete',
        'pending': 0,
        'exhausted': [
          {'key': 'Hello', 'lang': 'fr'},
        ],
        'exhausted_total': 3,
        'refused': {
          'icu': <String>[],
          'icu_total': 0,
          'markup': <String>[],
          'markup_total': 0,
        },
      };
      final result = await call('publish', {'operation_id': 'op_p1'});
      final text = (result.content.single as TextContent).text;
      expect(text, contains('3 pair(s) used up their fill attempts'));
      expect(text, isNot(contains('fill_status')));
    });

    test('a fill_incomplete without its counts still refuses and leaves the '
        'choice to the human', () async {
      publishStatus = 409;
      published = {
        'error': 'fill_incomplete',
        'message': 'the publication snapshot is incomplete',
        'pending': '8',
        'refused': 'none',
      };
      final result = await call('publish', {'operation_id': 'op_p1'});
      final error = errorOf(result);
      expect(error['code'], 'fill_incomplete');
      expect(error['message'], contains('is incomplete'));
      expect(error['message'], contains('require_complete: false'));
      expect(error['message'], isNot(contains('fill_status')));
    });

    test('scope_changed names the filters this call sent', () async {
      publishStatus = 409;
      published = {'error': 'scope_changed', 'message': 'not the one approved'};
      final result = await call(
          'publish', {'operation_id': 'op_p1', 'approved_only': true});
      final error = errorOf(result);
      expect(error['code'], 'scope_changed');
      expect(error['message'], contains('approved_only true'));
      // A used approval is `operation_not_approved`, named by its own
      // branch; what else reaches this code is an operation of another
      // action, and the sentence must not send the agent to the wrong one.
      expect(error['message'], isNot(contains('already used')));
      expect(error['message'], contains('a different action'));
      expect(requests, hasLength(1));
    });

    test('an expired approval is expired, with the url the human needs',
        () async {
      publishStatus = 409;
      published = {'error': 'operation_not_approved', 'message': 'expired'};
      operation = {...operation, 'state': 'expired'};
      final result = await call('publish', {'operation_id': 'op_p1'});
      final error = errorOf(result);
      expect(error['code'], 'expired');
      expect(error['state'], 'expired');
      expect(error['approval_url'], operation['approval_url']);
    });

    test('a used approval is not a second publish', () async {
      publishStatus = 409;
      published = {'error': 'operation_not_approved', 'message': 'used'};
      operation = {...operation, 'state': 'exhausted'};
      final result = await call('publish', {'operation_id': 'op_p1'});
      final error = errorOf(result);
      expect(error['code'], 'authorization_required');
      expect(error['state'], 'exhausted');
      expect(error['message'], contains('already used'));
    });

    test('an unreadable operation still refuses, without a state it invented',
        () async {
      publishStatus = 403;
      published = {'error': 'authorization_required', 'message': 'no op'};
      operation = {'error': 'operation_not_found'};
      final result = await call('publish', {'operation_id': 'op_p1'});
      final error = errorOf(result);
      expect(error['code'], 'authorization_required');
      expect(error['state'], isNull);
    });

    test('an unknown operation is not approved, without a state it invented',
        () async {
      publishStatus = 404;
      published = {'error': 'operation_not_found', 'message': 'unknown operation'};
      operation = {'error': 'operation_not_found'};
      final result = await call('publish', {'operation_id': 'op_p1'});
      final error = errorOf(result);
      expect(error['code'], 'authorization_required');
      expect(error['state'], isNull);
      expect(error['message'], contains('not approved'));
      expect(requests, hasLength(2));
    });

    test('a refusal this tool does not name keeps its own code', () async {
      publishStatus = 402;
      published = {'error': 'plan_limit', 'message': 'upgrade'};
      final result = await call('publish', {'operation_id': 'op_p1'});
      final error = errorOf(result);
      expect(error['code'], 'plan_limit');
      expect(error['message'], contains('upgrade'));
      expect(requests, hasLength(1));
    });
  });

  group('authorize {action: publish}', () {
    test('mints the scope the publish will send, with no max_credits',
        () async {
      final result = await call('authorize', {'action': 'publish'});
      expect(result.isError, isNot(true));
      final request = requests.single;
      expect(request.url.path, '/v1/operations');
      expect(bodyOf(request), {
        'action': 'publish',
        'scope': {
          'project_id': 'proj_abc',
          'approved_only': false,
          'require_complete': true,
          'incomplete_mode': 'source',
          'expected_pending': 0,
        },
      });
      expect(result.structuredContent!['next'], 'wait');
    });

    test('the scope carries the same filters publish resolves', () async {
      await call('authorize', {'action': 'publish', 'approved_only': true},
          config: 'projectId: proj_abc\nmode: a\n');
      expect((bodyOf(requests.single)['scope']! as Map)['incomplete_mode'],
          'skip');
      expect(
          (bodyOf(requests.single)['scope']! as Map)['approved_only'], isTrue);
    });

    test('max_credits is refused before any request: a publish spends nothing',
        () async {
      final result =
          await call('authorize', {'action': 'publish', 'max_credits': 5});
      expect(errorOf(result)['code'], 'max_credits_not_applicable');
      expect(requests, isEmpty);
    });

    test('an approved publish operation sends the agent to publish, not push',
        () async {
      operation = {...operation, 'state': 'approved'};
      final result =
          await call('authorize', {'operation_id': 'op_p1', 'action': 'publish'});
      expect(result.structuredContent!['next'], 'publish');
      expect((result.content.single as TextContent).text,
          contains('Call publish'));
      expect(requests.single.method, 'GET');
    });
  });
}
