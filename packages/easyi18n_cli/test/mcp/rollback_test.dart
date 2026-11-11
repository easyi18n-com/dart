@TestOn('vm')
library;

import 'dart:convert';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/stored_login.dart';
import 'harness.dart';
import 'server_test.dart' show errorOf, project;

void main() {
  late List<http.Request> requests;
  late Map<String, Object?> restored;
  late int restoreStatus;
  late Map<String, Object?> operation;

  setUp(() {
    requests = [];
    restoreStatus = 201;
    restored = {
      'versionId': '2026.09.22.4',
      'keyCount': 7,
      'restoredFrom': '2026.09.22.2',
    };
    operation = {
      'operation_id': 'op_r1',
      'action': 'rollback',
      'state': 'pending_approval',
      'scope': <String, Object?>{},
      'authorized_mc': 0,
      'approval_url': 'https://app.easyi18n.com/approve/op_r1',
      'expires_at': '2026-09-22T16:00:00Z',
    };
  });

  Future<http.Response> backend(http.Request req) async {
    requests.add(req);
    if (req.url.path.endsWith('/restore')) {
      return http.Response(jsonEncode(restored), restoreStatus);
    }
    return http.Response(
        jsonEncode(operation), req.method == 'POST' ? 201 : 200);
  }

  Future<CallToolResult> call(
    String tool,
    Map<String, Object?> arguments, {
    String config = 'projectId: proj_abc\n',
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
  }) async {
    final fixture = project(config: config, environment: environment,
        httpClient: MockClient(backend));
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness.call(tool, arguments);
  }

  http.Request restoreRequest() =>
      requests.singleWhere((r) => r.url.path.endsWith('/restore'));

  Map<String, Object?> bodyOf(http.Request request) =>
      (jsonDecode(request.body) as Map).cast<String, Object?>();

  // Decision 1 of #2579: the MCP that inherits the login rolls back as its
  // human. A key in EASYI18N_TOKEN keeps D17, and a server that makes the
  // login ask after all answers 403, which reads as today's remedy.
  group('with the stored login', () {
    test('rollback goes without operation_id, as the login', () async {
      final result = await call('rollback', {'version': '2026.09.22.2'}, environment: loggedInHome());
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(restoreRequest().headers['authorization'], 'Bearer eip_login');
      expect(bodyOf(restoreRequest()), isNot(contains('operationId')));
      expect(requests.where((r) => r.url.path.contains('/operations')), isEmpty);
    });

    test('a key in EASYI18N_TOKEN still needs the operation', () async {
      final result = await call('rollback', {'version': '2026.09.22.2'},
          environment: loggedInHome(also: {'EASYI18N_TOKEN': 'eik_test'}));
      expect(errorOf(result)['code'], 'authorization_required');
      expect(requests, isEmpty);
    });

    test('a 403 authorization_required is the remedy without an operation',
        () async {
      restoreStatus = 403;
      restored = {'error': 'authorization_required',
        'message': 'this credential needs an approved operation'};
      final result = await call('rollback', {'version': '2026.09.22.2'}, environment: loggedInHome());
      expect(errorOf(result)['code'], 'authorization_required');
      expect(errorOf(result)['message'], contains('authorize {action: rollback}'));
      expect(errorOf(result)['statusCode'], 403);
      expect(requests.where((r) => r.url.path.contains('/operations')), isEmpty);
    });
  });

  group('the approval is mandatory', () {
    test('rollback without operation_id refuses before any request', () async {
      final result = await call('rollback', {});
      expect(result.isError, isTrue,
          reason: '${result.content.map((c) => (c as TextContent).text)}');
      expect(errorOf(result)['code'], 'authorization_required');
      expect(requests, isEmpty);
    });

    test('a blank operation_id is not an operation', () async {
      final result = await call('rollback', {'operation_id': '  '});
      expect(errorOf(result)['code'], 'authorization_required');
      expect(requests, isEmpty);
    });
  });

  // D4: the token never reaches a host the config points at unless it is ours.
  group('an untrusted base_url is refused before any request', () {
    const evil = 'projectId: proj_abc\nbaseUrl: https://evil.example\n';

    test('by rollback', () async {
      final result =
          await call('rollback', {'operation_id': 'op_r1'}, config: evil);
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });

    test('by authorize {action: rollback}', () async {
      final result = await call('authorize', {'action': 'rollback'}, config: evil);
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
    });
  });

  group('the version the agent names reaches the door as a path segment', () {
    test('the default target is the previous version', () async {
      final result = await call('rollback', {'operation_id': 'op_r1'});
      expect(result.isError, isNot(true),
          reason: '${result.content.map((c) => (c as TextContent).text)}');
      expect(restoreRequest().url.path,
          endsWith('/projects/proj_abc/versions/previous/restore'));
      expect((jsonDecode(restoreRequest().body) as Map).cast<String, Object?>(),
          {'operationId': 'op_r1'});
      expect(result.structuredContent, {
        'restored_from': '2026.09.22.2',
        'version_id': '2026.09.22.4',
        'key_count': 7,
        'flagged': {
          'icu': <String>[], 'icu_total': 0,
          'markup': <String>[], 'markup_total': 0,
        },
        'next': 'pull',
      });
    });

    test('an explicit version travels instead of the alias', () async {
      await call('rollback',
          {'operation_id': 'op_r1', 'version': ' 2026.09.20.3 '});
      expect(restoreRequest().url.path,
          endsWith('/versions/2026.09.20.3/restore'));
    });

    test('a version that is not one cannot walk out of the path', () async {
      // The last one is the door's own length cap, one over.
      for (final bad in [
        '../../projects/other/publish', '..', '.', 'a/b', 'v' * 129,
      ]) {
        requests.clear();
        final result = await call(
            'rollback', {'operation_id': 'op_r1', 'version': bad});
        expect(result.isError, isTrue, reason: 'version $bad');
        expect(errorOf(result)['code'], 'invalid_argument', reason: bad);
        expect(requests.where((r) => r.url.path.endsWith('/restore')), isEmpty,
            reason: 'version $bad reached the door');
      }
    });

    test('the flagged cells carry the total the server counted', () async {
      restored = {
        'versionId': '2026.09.22.4',
        'keyCount': 7,
        'restoredFrom': '2026.09.22.2',
        'icuRejected': ['Hi {n} [fr]: bad plural'],
        'icuRejectedTotal': 63,
        'markupRejected': <String>[],
        'markupRejectedTotal': 0,
      };
      final result = await call('rollback', {'operation_id': 'op_r1'});
      expect((result.structuredContent!['flagged']! as Map)['icu_total'], 63);
      // The opposite verdict to publish's: these cells ARE being served.
      expect((result.content.single as TextContent).text,
          contains('63 cell(s) in it would be refused'));
    });
  });

  group('what the door refuses', () {
    test('scope_changed names the target this call asked for', () async {
      restoreStatus = 409;
      restored = {'error': 'scope_changed', 'message': 'not the one approved'};
      final result = await call('rollback', {'operation_id': 'op_r1'});
      final error = errorOf(result);
      expect(error['code'], 'scope_changed');
      expect(error['message'], contains('"previous"'));
      expect(error['message'], contains('published again'));
      // A used approval has its own branch; the sentence must not send the
      // agent there.
      expect(error['message'], isNot(contains('already used')));
      expect(requests, hasLength(1));
    });

    test('an expired approval is expired, with the url the human needs',
        () async {
      restoreStatus = 409;
      restored = {'error': 'operation_not_approved', 'message': 'expired'};
      operation = {...operation, 'state': 'expired'};
      final result = await call('rollback', {'operation_id': 'op_r1'});
      final error = errorOf(result);
      expect(error['code'], 'expired');
      expect(error['state'], 'expired');
      expect(error['approval_url'], operation['approval_url']);
      expect(error['message'], contains('authorize the rollback again'));
    });

    test('a used approval is not a second rollback', () async {
      restoreStatus = 409;
      restored = {'error': 'operation_not_approved', 'message': 'used'};
      operation = {...operation, 'state': 'exhausted'};
      final result = await call('rollback', {'operation_id': 'op_r1'});
      final error = errorOf(result);
      expect(error['code'], 'authorization_required');
      expect(error['message'], contains('already used'));
      expect(error['message'], contains('one rollback'));
    });

    test('an unknown operation is not approved, without a state it invented',
        () async {
      restoreStatus = 404;
      restored = {'error': 'operation_not_found', 'message': 'unknown operation'};
      operation = {'error': 'operation_not_found'};
      final result = await call('rollback', {'operation_id': 'op_r1'});
      final error = errorOf(result);
      expect(error['code'], 'authorization_required');
      expect(error['state'], isNull);
      expect(error['message'], contains('not approved'));
      expect(requests, hasLength(2));
    });

    test('a refusal this tool does not name keeps its own code', () async {
      restoreStatus = 404;
      restored = {
        'error': 'version_not_found',
        'message': 'no version older than 2026.09.22.2 to restore',
      };
      final result = await call('rollback', {'operation_id': 'op_r1'});
      expect(errorOf(result)['code'], 'version_not_found');
      // No second call: only the approval branches read the operation.
      expect(requests, hasLength(1));
    });
  });

  group('authorize {action: rollback}', () {
    test('mints the scope the rollback will send, with no max_credits',
        () async {
      final result = await call('authorize', {'action': 'rollback'});
      expect(result.isError, isNot(true),
          reason: '${result.content.map((c) => (c as TextContent).text)}');
      final request = requests.single;
      expect(request.url.path, '/v1/operations');
      expect(bodyOf(request), {
        'action': 'rollback',
        'scope': {
          'project_id': 'proj_abc',
          'from_version': 'current',
          'to_version': 'previous',
        },
      });
      expect(result.structuredContent!['next'], 'wait');
    });

    // The agent never picks which version it is leaving: the mint resolves
    // `current` against the project, so the pair the human approves comes
    // from one read.
    test('an explicit version is the target, and the source stays the alias',
        () async {
      await call('authorize', {'action': 'rollback', 'version': '2026.09.20.3'});
      expect(bodyOf(requests.single)['scope'], {
        'project_id': 'proj_abc',
        'from_version': 'current',
        'to_version': '2026.09.20.3',
      });
    });

    test('max_credits is refused before any request: a rollback spends '
        'nothing', () async {
      final result =
          await call('authorize', {'action': 'rollback', 'max_credits': 5});
      expect(errorOf(result)['code'], 'max_credits_not_applicable');
      expect(errorOf(result)['message'], contains('rollback approval'));
      expect(requests, isEmpty);
    });

    test('an approved rollback operation sends the agent to rollback',
        () async {
      operation = {...operation, 'state': 'approved'};
      final result = await call(
          'authorize', {'operation_id': 'op_r1', 'action': 'rollback'});
      expect(result.structuredContent!['next'], 'rollback');
      expect((result.content.single as TextContent).text,
          contains('Call rollback'));
      expect(requests.single.method, 'GET');
    });
  });
}
