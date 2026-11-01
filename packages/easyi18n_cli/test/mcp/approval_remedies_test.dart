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
  for (final action in ['publish', 'rollback']) {
    for (final state in ['pending_approval', 'denied', 'unknown']) {
      test('$action approval remedy for $state', () async {
        final requests = <http.Request>[];
        final fixture = project(
          httpClient: MockClient((request) async {
            requests.add(request);
            if (request.method == 'POST') {
              return http.Response(jsonEncode({
                'error': 'operation_not_approved',
                'message': 'operation is not approved',
              }), 409);
            }
            if (state == 'unknown') {
              return http.Response('{"error":"operation_not_found"}', 404);
            }
            return http.Response(jsonEncode({
              'operation_id': 'op_1',
              'action': action,
              'state': state,
              'approval_url': 'https://app.easyi18n.com/approve/op_1',
            }), 200);
          }),
        );
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call(action, {'operation_id': 'op_1'});
        expect(errorOf(result)['code'], 'authorization_required');
        expect(requests.map((r) => r.method), ['POST', 'GET']);
        final text = (result.content.single as TextContent).text;
        if (state == 'pending_approval') {
          expect(text, contains('wait with authorize {operation_id}'));
          expect(text, isNot(contains('authorize the $action again')));
        } else {
          expect(text, isNot(contains('wait with authorize')));
          expect(text, contains('Ask the human whether to authorize the '
              '$action again'));
        }
      });
    }
  }
}
