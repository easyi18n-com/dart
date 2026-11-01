import 'dart:convert';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/transcript.dart';

void main() {
  const key = 'eik_abcdefghijklmnopqrstuvwxyz0123456789';
  const pat = 'eip_abcdefghijklmnopqrstuvwxyz0123456789';

  test('quiet follows the shared mode but preserves warnings and errors', () {
    final t = Transcript();
    final output = CliOutput(out: t.out, err: t.err);
    final logger = output.logger;
    logger.info('before');
    output.json = true;
    logger.info('hidden');
    logger.detail('hidden detail');
    logger.warn('careful');
    logger.error('failure');
    output.json = false;
    logger.detail('after');
    expect(t.records, [
      (channel: 'out', line: 'before'),
      (channel: 'err', line: 'warning: careful'),
      (channel: 'err', line: 'error: failure'),
      (channel: 'out', line: '  after'),
    ]);
  });

  test('redacts credentials without swallowing help literals', () {
    expect(CliLogger.sanitize('$key $pat'), '[REDACTED] [REDACTED]');
    const prose = 'eik_ eik_) eip_ eik_x eik_secret eik_flag';
    expect(CliLogger.sanitize(prose), prose);
  });

  test('every logger channel redacts credentials', () {
    final t = Transcript();
    final logger = CliLogger(out: t.out, err: t.err);
    logger.info(key);
    logger.detail(pat);
    logger.warn(key);
    logger.error(pat);
    expect(t.records.map((r) => r.line), [
      '[REDACTED]', '  [REDACTED]', 'warning: [REDACTED]',
      'error: [REDACTED]',
    ]);
  });

  test('emit sanitizes nested keys and values before JSON encoding', () {
    final t = Transcript();
    CliOutput(out: t.out, err: t.err).emit({
      'bad\x9b$key': [
        {'nested\x7f': '$pat\r\x1b\x9b\x7f\n\tvalue'},
        null, true, 3,
      ],
    });
    expect(t.records, hasLength(1));
    expect(t.records.single.channel, 'out');
    expect(jsonDecode(t.records.single.line), {
      'bad[REDACTED]': [
        {'nested': '[REDACTED]\n\tvalue'},
        null, true, 3,
      ],
    });
  });

  for (final row in <(CliException, bool)>[
    (CliException('no config'), false),
    (TransientCliException('Could not reach server'), true),
    (FatalCliException('bad config'), false),
    for (final status in [429, 500, 502, 503, 504])
      (ApiException('temporary', statusCode: status), true),
    for (final status in [400, 401, 402, 403, 404, 409, 422, 501])
      (ApiException('permanent', statusCode: status), false),
  ]) {
    test('retryability ${row.$1.runtimeType} ${row.$1 is ApiException ? (row.$1 as ApiException).statusCode : row.$1.message}', () {
      final t = Transcript();
      final output = CliOutput(out: t.out, err: t.err)..json = true;
      output.emitError(row.$1);
      final payload = jsonDecode(t.records.single.line) as Map;
      expect(payload['error']['retryable'], row.$2);
      expect(payload['error']['message'], row.$1.message);
      expect(payload['error']['statusCode'],
          row.$1 is ApiException ? (row.$1 as ApiException).statusCode : null);
    });
  }

  test('a refusal that names files carries them beside the four error fields',
      () {
    final t = Transcript();
    CliOutput(out: t.out, err: t.err)
      ..json = true
      ..emitError(
        CliException('es.json changed', code: 'edited_targets', details: const {
          'edited': [
            {'file': 'public/i18n/es.json'},
          ],
          'other': 'stays out of the record',
        }),
        report: const {'files_written': <String>[]},
      );
    expect(jsonDecode(t.records.single.line), {
      'files_written': <String>[],
      'edited': [
        {'file': 'public/i18n/es.json'},
      ],
      'error': {
        'message': 'es.json changed', 'code': 'edited_targets',
        'statusCode': null, 'retryable': false,
      },
    });
  });

  test('a server error whose body has an `edited` field stays four fields',
      () {
    final t = Transcript();
    CliOutput(out: t.out, err: t.err)
      ..json = true
      ..emitError(ApiException('conflict', statusCode: 409, code: 'conflict',
          details: const {'edited': 3}));
    expect((jsonDecode(t.records.single.line) as Map).keys, ['error']);
  });

  test('error envelope preserves backend code and redacts its message', () {
    final t = Transcript();
    final output = CliOutput(out: t.out, err: t.err)..json = true;
    output.emitError(ApiException('$key denied', statusCode: 403, code: 'scope'));
    expect(jsonDecode(t.records.single.line), {
      'error': {
        'message': '[REDACTED] denied', 'code': 'scope',
        'statusCode': 403, 'retryable': false,
      },
    });
    output.json = false;
    output.emitError(CliException('$pat denied'));
    expect(t.records.last, (channel: 'err', line: 'error: [REDACTED] denied'));
  });

  test('transport exhaustion reaches the JSON retryable contract', () async {
    var calls = 0;
    final client = TranslationsApiClient(
      baseUrl: 'https://api.easyi18n.com', token: 'eik_secret',
      httpClient: MockClient((_) async {
        calls++;
        throw http.ClientException('offline');
      }),
      wait: (_) async {},
    );
    try {
      await client.fetchMeta(projectId: 'p1');
      fail('transport failure must reach the caller');
    } on CliException catch (error) {
      expect(calls, greaterThan(1));
      expect(error, isA<TransientCliException>());
      final t = Transcript();
      final output = CliOutput(out: t.out, err: t.err)..json = true;
      output.emitError(error);
      expect(jsonDecode(t.records.single.line)['error']['retryable'], true);
    }
  });

  test('JSON golden rejects empty objects and additional stdout', () {
    for (final records in <List<TranscriptRecord>>[
      [],
      [(channel: 'out', line: '{}')],
      [(channel: 'out', line: '[]')],
      [(channel: 'out', line: '{"version":"0.13.0-rc.4"}'),
       (channel: 'out', line: 'noise')],
    ]) {
      expect(() => expectJsonGolden('version_json', 0, records,
          check: (_) {}), throwsA(isA<TestFailure>()));
    }
  });
}
