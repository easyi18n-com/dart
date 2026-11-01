import 'dart:convert';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/output_format.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('preflight is read-only; adoption is conditional and confirmed', () async {
    final calls = <http.Request>[];
    final client = TranslationsApiClient(baseUrl: 'https://example.test', token: 'eik_x',
      httpClient: MockClient((r) async {
        calls.add(r);
        return http.Response(jsonEncode(r.method == 'GET'
            ? {'formats': [], 'outputFormatsApiVersion': 1}
            : {'formats': ['arb'], 'created': true}), 200);
      }));
    final plan = OutputFormatAdoption('arb');
    await plan.preflight(client, 'p');
    expect(plan.state, OutputFormatState.wouldAdopt);
    expect(calls.map((r) => r.method), ['GET']);
    await plan.apply(client, 'p', CliLogger(out: StringBuffer(), err: StringBuffer()));
    expect(jsonDecode(calls.last.body), {'format': 'arb', 'mode': 'adopt'});
    expect(plan.created, isTrue);
  });
  for (final meta in <Map<String, Object?>>[
    {}, {'formats': []}, {'formats': [], 'outputFormatsApiVersion': 2},
    {'formats': [], 'outputFormatsApiVersion': '1'},
    {'outputFormatsApiVersion': 1},
    {'formats': [null], 'outputFormatsApiVersion': 1},
    {'formats': [''], 'outputFormatsApiVersion': 1},
  ]) {
    test('invalid metadata refuses: $meta', () async {
      final client = TranslationsApiClient(baseUrl: 'https://example.test', token: 'eik_x',
        httpClient: MockClient((r) async {
          expect(r.method, 'GET');
          return http.Response(jsonEncode(meta), 200);
        }));
      await expectLater(OutputFormatAdoption('arb').preflight(client, 'p'),
          throwsA(isA<CliException>()));
    });
  }
  for (final changed in [false, true]) {
    test('annotation preserves exception classes and only confirmed changes ($changed)', () async {
      final plan = OutputFormatAdoption('arb');
      final client = TranslationsApiClient(baseUrl: 'https://example.test', token: 'eik_x',
        httpClient: MockClient((r) async => http.Response(jsonEncode(r.method == 'GET'
            ? {'formats': [], 'outputFormatsApiVersion': 1}
            : {'formats': ['arb'], 'created': changed}), 200)));
      await plan.preflight(client, 'p');
      await plan.apply(client, 'p', CliLogger(out: StringBuffer(), err: StringBuffer()));
      for (final error in <CliException>[
        ApiException('original',
            statusCode: 503, code: 'unavailable', details: {'pending': 4}),
        FatalCliException('original', exitCode: 4),
        TransientCliException('original', exitCode: 5),
        CliException('original',
            exitCode: 6, code: 'custom', details: {'pending': 4}),
      ]) {
        final annotated = plan.annotate(error);
        expect(annotated.runtimeType, error.runtimeType);
        expect(annotated.code, error.code);
        expect(annotated.exitCode, error.exitCode);
        // Rewrapping is where a refusal loses the fields the MCP error
        // contract carries; the message is not the whole exception.
        expect(annotated.details, error.details);
        if (error is ApiException) {
          expect((annotated as ApiException).statusCode, error.statusCode);
        }
        expect(annotated.message.contains('configuration was updated'), changed);
        expect(plan.annotate(annotated), same(annotated));
      }
    });
  }
  test('a 403 rewrapped with the write-scope remedy keeps the refusal fields',
      () async {
    final client = TranslationsApiClient(baseUrl: 'https://example.test',
      token: 'eik_x', httpClient: MockClient((r) async => http.Response(
        jsonEncode(r.method == 'GET'
            ? {'formats': [], 'outputFormatsApiVersion': 1}
            : {'error': 'forbidden', 'message': 'no write scope',
               'requiredScope': 'write'}),
        r.method == 'GET' ? 200 : 403)));
    final plan = OutputFormatAdoption('arb');
    await plan.preflight(client, 'p');
    await expectLater(
      plan.apply(client, 'p', CliLogger(out: StringBuffer(), err: StringBuffer())),
      throwsA(isA<ApiException>()
          .having((e) => e.details['requiredScope'], 'details', 'write')
          .having((e) => e.message, 'message', contains('write scope must run'))),
    );
  });
  for (final status in [500, 503]) {
    test('adoption does not replay unavailable $status', () async {
      var writes = 0;
      final client = TranslationsApiClient(baseUrl: 'https://example.test', token: 'eik_x',
        wait: (_) async {}, httpClient: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response('{"formats":[],"outputFormatsApiVersion":1}', 200);
          }
          writes++;
          return http.Response('{"error":"unavailable","message":"lost"}', status);
        }));
      final plan = OutputFormatAdoption('arb');
      await plan.preflight(client, 'p');
      await expectLater(plan.apply(client, 'p', CliLogger(out: StringBuffer())),
          throwsA(isA<ApiException>()));
      expect(writes, 1);
      expect(plan.created, isFalse);
    });
  }

  group('OutputFormatCheck: can pull write this format with this key? (#2133)', () {
    Future<OutputFormatCheck> check(Object? formats, List<String> scopes,
        {String format = 'nested_json', int version = 1}) {
      final client = TranslationsApiClient(baseUrl: 'https://example.test',
        token: 'eik_x', httpClient: MockClient((r) async => http.Response(
          jsonEncode(r.url.path.endsWith('/credential')
              ? {'scopes': scopes, 'requires_operation_approval': true}
              : {'formats': formats, 'outputFormatsApiVersion': version}), 200)));
      return OutputFormatCheck.of(client, 'p', format);
    }

    // The backend's own rule (`grantsScope`): admin grants every scope.
    for (final scopes in [['read', 'write'], ['admin']]) {
      test('a project with no format is adoptable with $scopes', () async {
        final graded = await check([], scopes);
        expect(graded.readiness, OutputFormatReadiness.adoptable);
        expect(graded.readiness.blocksPull, isFalse);
        expect(graded.remedy, isEmpty);
      });
    }

    // Each half of the guard alone: without it, a key without write grades
    // `missing` over metadata this CLI cannot read.
    test('a version this CLI does not read, or formats it cannot trust, is '
        'unknown', () async {
      expect((await check([], ['read'], version: 2)).readiness,
          OutputFormatReadiness.unknown);
      expect((await check([1], ['read'])).readiness,
          OutputFormatReadiness.unknown);
    });

    test('every string fits the 200 characters an MCP list keeps, at the '
        'longest scopes and formats the backend allows', () async {
      const longest = 'angular_json';
      final missing = await check([], ['read', 'capture', 'translate',
          'publish', 'members:read', 'members:write'], format: longest);
      final conflict = await check(['json', 'nested_json', 'ios_strings',
          'xcstrings', 'android_xml', 'arb', 'po'], ['admin'], format: longest);
      expect(missing.readiness, OutputFormatReadiness.missing);
      expect(conflict.readiness, OutputFormatReadiness.conflict);
      for (final line in [missing.message, ...missing.remedy,
          conflict.message, ...conflict.remedy]) {
        expect(line.length, lessThanOrEqualTo(200), reason: line);
      }
    });
  });
}
