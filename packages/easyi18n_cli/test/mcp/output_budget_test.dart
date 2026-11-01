import 'dart:convert';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/mcp/output_budget.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show project, errorOf;

void expectBounded(CallToolResult result) {
  expect(
    utf8.encode(jsonEncode(result.structuredContent)).length,
    lessThanOrEqualTo(32768),
  );
}

void main() {
  test(
    'oversized scalar config refuses instead of returning partial identity',
    () async {
      final fixture = project(
        config:
            'projectId: proj_abc\n'
            'baseUrl: https://api.easyi18n.com/${'x' * 40000}\n',
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness.call('extract');
      expectBounded(result);
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'output_too_large');
    },
  );

  for (final schema in [false, true]) {
    test(
      'bounds ${schema ? 'schema' : 'CLI'} error and its text with its code intact',
      () async {
        final fixture = project();
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call(
          'extract',
          schema ? {'limit': '文😀' * 10000} : {'project_dir': '文😀' * 10000},
        );
        expectBounded(result);
        expect(result.isError, isTrue);
        expect(
          errorOf(result)['code'],
          schema ? 'invalid_arguments' : 'invalid_project_dir',
        );
        expect(errorOf(result)['statusCode'], isNull);
        expect(errorOf(result)['retryable'], isFalse);
        expect(result.structuredContent!['truncated'], isTrue);
        expect(
          (result.content.single as TextContent).text,
          errorOf(result)['message'],
        );
        expect((errorOf(result)['message'] as String), endsWith('…'));
      },
    );
  }

  test(
    'a singleton list can shrink to empty without mutating the original',
    () {
      final payload = {
        'items': [
          {'x' * 40000: 'value'},
        ],
      };
      final bounded = boundOutput(payload);
      expect(utf8.encode(jsonEncode(bounded)).length, lessThanOrEqualTo(32768));
      expect(bounded['items'], isEmpty);
      expect(bounded['truncated'], isTrue);
      expect(payload['items'], hasLength(1));
    },
  );

  test('an oversized API error keeps its HTTP status and code', () async {
    final fixture = project(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'scope_missing', 'message': '文😀' * 10000}),
          403,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    final result = await harness.call('status');
    expectBounded(result);
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'scope_missing');
    expect(errorOf(result)['statusCode'], 403);
    expect(errorOf(result)['retryable'], isFalse);
    expect(result.structuredContent!['truncated'], isTrue);
    expect(
      (result.content.single as TextContent).text,
      errorOf(result)['message'],
    );
  });

  test('the clip cap is exclusive: at the cap nothing is cut, so nothing is '
      'marked', () {
    // The marker is a claim about the message and the reader is a model that
    // cannot check it. At exactly the cap no rune is dropped, so marking would
    // be false; one rune over, the marker is true. Turning `>` into `>=` here
    // passes every other test in this file.
    final fat = {
      'rows': [
        for (var i = 0; i < 3000; i++) {'lang': 'l$i', 'n': i},
      ],
    };
    String messageOf(int runes) => ((boundOutput({
          'error': {'message': 'x' * runes, 'code': 'cli_error'},
          ...fat,
        })['error'] as Map)['message'] as String);

    expect(messageOf(kMcpListStringCap), isNot(endsWith('…')));
    expect(messageOf(kMcpListStringCap).runes.length, kMcpListStringCap);
    expect(messageOf(kMcpListStringCap + 1), endsWith('…'));
    expect(messageOf(kMcpListStringCap + 1).runes.length, kMcpListStringCap + 1);
  });
}
