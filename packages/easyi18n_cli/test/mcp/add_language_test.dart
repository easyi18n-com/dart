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
  late int status;
  late Object response;
  setUp(() {
    requests = [];
    status = 201;
    response = {'code': 'fr', 'isBase': false, 'fillMode': 'ai'};
  });

  Future<CallToolResult> call(Map<String, Object?> arguments,
      {Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
      String config = 'projectId: proj_abc\n'}) async {
    final fixture = project(
      config: config,
      environment: environment,
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(jsonEncode(response), status);
      }),
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    return harness.call('add_language', arguments);
  }

  test('adds the language through the /v1 route and reports it', () async {
    final result = await call({'code': 'fr'});
    expect(result.isError, isNot(true));
    expect(requests.single.url.path, '/v1/projects/proj_abc/languages');
    expect(jsonDecode(requests.single.body), {'code': 'fr'});
    expect(result.structuredContent, {
      'code': 'fr',
      'fill_mode': 'ai',
      'next': 'status',
    });
    expect((result.content.single as TextContent).text, contains('fr'));
  });

  test('fill_mode manual travels as fillMode', () async {
    response = {'code': 'de', 'isBase': false, 'fillMode': 'manual'};
    final result = await call({'code': 'de', 'fill_mode': 'manual'});
    expect(result.isError, isNot(true));
    expect(jsonDecode(requests.single.body),
        {'code': 'de', 'fillMode': 'manual'});
    expect(result.structuredContent!['fill_mode'], 'manual');
  });

  test('a missing code is refused before any request', () async {
    final result = await call({});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'invalid_arguments');
    expect(requests, isEmpty);
  });

  test('a token argument is refused by the closed schema', () async {
    final result = await call({'code': 'fr', 'token': 'eik_x'});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'invalid_arguments');
    expect(requests, isEmpty);
  });

  test('no credential is no_credential naming the write scope', () async {
    final result = await call({'code': 'fr'}, environment: const {});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'no_credential');
    expect(errorOf(result)['message'], contains('write'));
    expect(requests, isEmpty);
  });

  test('an untrusted base_url is refused before any request', () async {
    final result = await call({'code': 'fr'},
        config: 'projectId: proj_abc\nbaseUrl: https://evil.example\n');
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'untrusted_base_url');
    expect(requests, isEmpty);
  });

  test('a server refusal keeps its code', () async {
    status = 403;
    response = {'error': 'forbidden', 'message': 'key lacks write scope'};
    final result = await call({'code': 'fr'});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'forbidden');
  });
}
