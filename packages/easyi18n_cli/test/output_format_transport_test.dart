import 'dart:async';
import 'dart:convert';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final operation in ['add', 'publish', 'restore']) {
    final successStatus = operation == 'add' ? 200 : 201;
    final successBody = operation == 'add'
      ? {'formats': ['strings', 'arb'], 'created': false}
      : {'versionId': 'v2', 'keyCount': 7, 'restoredFrom': 'v1',
          'icuRejected': ['a', 5], 'icuRejectedTotal': 9,
          'markupRejected': ['b'], 'markupRejectedTotal': 11};
    Future<Object> invoke(TranslationsApiClient client) => switch (operation) {
      'add' => client.addOutputFormat(projectId: 'p', format: 'arb'),
      'publish' => client.publish(projectId: 'p'),
      _ => client.restoreVersion(projectId: 'p', versionId: 'previous'),
    };
    late int calls;
    late int waits;
    TranslationsApiClient client(http.Client httpClient) {
      calls = 0;
      waits = 0;
      final result = TranslationsApiClient(baseUrl: 'https://example.test',
        token: 'eik_test', httpClient: httpClient,
        wait: (_) async { waits++; });
      addTearDown(result.close);
      return result;
    }
    test('$operation parses its success and rejects the other status', () async {
      final api = client(MockClient((req) async {
        calls++;
        return http.Response(jsonEncode(successBody),
          calls == 1 ? successStatus : (successStatus == 200 ? 201 : 200));
      }));
      final result = await invoke(api);
      if (result is OutputFormatOutcome) {
        expect(result.formats, ['strings', 'arb']);
        expect(result.created, false);
      } else {
        final value = result as PublishOutcome;
        expect(value.versionId, 'v2');
        expect(value.keyCount, 7);
        expect(value.restoredFrom, 'v1');
        expect(value.icuRejected, ['a']);
        expect(value.icuRejectedTotal, 9);
        expect(value.markupRejected, ['b']);
        expect(value.markupRejectedTotal, 11);
      }
      await expectLater(invoke(api), throwsA(isA<ApiException>()));
      expect(calls, 2);
    });
    for (final status in [400, 401, 402, 403, 409, 429, 500, 502, 503, 504]) {
      test('$operation does not replay $status unavailable', () async {
        final api = client(MockClient((req) async {
          calls++;
          return http.Response('{"error":"unavailable","message":"lost"}', status);
        }));
        await expectLater(invoke(api), throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', status)
          .having((e) => e.code, 'code', 'unavailable')
          .having((e) => e.message, 'hint', isNot(contains('formats add')))));
        expect(calls, 1);
        expect(waits, 0);
      });
    }
    for (final lost in ['connection', 'timeout', 'body']) {
      test('$operation does not replay lost $lost', () async {
        final api = client(MockClient.streaming((req, body) async {
          calls++;
          if (lost == 'timeout') throw TimeoutException('lost');
          if (lost == 'connection') throw http.ClientException('lost');
          return http.StreamedResponse(Stream.error(http.ClientException('lost body')), successStatus);
        }));
        await expectLater(invoke(api), throwsA(lost == 'timeout'
          ? isA<TimeoutException>() : isA<TransientCliException>()));
        expect(calls, 1);
        expect(waits, 0);
      });
    }
    for (final body in ['not json', '[]', operation == 'add'
      ? '{"formats":["arb"],"created":1}' : '{"keyCount":"wrong"}']) {
      test('$operation rejects body $body with its own hint', () async {
        final api = client(MockClient((req) async {
          calls++;
          return http.Response(body, successStatus);
        }));
        await expectLater(invoke(api), throwsA(isA<CliException>()
          .having((e) => e.message, 'hint', contains(operation == 'add'
            ? 'formats add <id>' : 'Check the project history'))
          .having((e) => e is FatalCliException, 'fatal shape', body != 'not json')));
        expect(calls, 1);
        expect(waits, 0);
      });
    }
    test('$operation replays only proven contended then succeeds', () async {
      final api = client(MockClient((req) async {
        calls++;
        return calls == 1
          ? http.Response('{"error":"contended"}', 503)
          : http.Response(jsonEncode(successBody), successStatus);
      }));
      await invoke(api);
      expect(calls, 2);
      expect(waits, 1);
    });
  }
  for (final body in [{}, {'formats': null, 'created': true},
    {'formats': 'arb', 'created': true}, {'formats': [1], 'created': true},
    {'formats': ['arb']}, {'formats': ['arb'], 'created': null}]) {
    test('add requires both correctly typed fields: $body', () async {
      final api = TranslationsApiClient(baseUrl: 'https://example.test', token: 'x',
        httpClient: MockClient((_) async => http.Response(jsonEncode(body), 200)));
      addTearDown(api.close);
      await expectLater(api.addOutputFormat(projectId: 'p', format: 'arb'),
        throwsA(isA<FatalCliException>()));
    });
  }
  test('publish unchanged 200 retains parser and request', () async {
    final api = TranslationsApiClient(baseUrl: 'https://example.test', token: 'x',
      httpClient: MockClient((req) async {
        expect(jsonDecode(req.body), {'skipIfIdentical': true});
        return http.Response('{"versionId":"v1","unchanged":true}', 200);
      }));
    addTearDown(api.close);
    final result = await api.publish(projectId: 'p', skipIfIdentical: true);
    expect(result.unchanged, true);
    expect(result.versionId, 'v1');
  });
}
