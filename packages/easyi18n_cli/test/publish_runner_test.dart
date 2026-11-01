import 'dart:convert';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/publish_runner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  const runner = PublishRunner();
  final units = [TranslateUnit(source: 'Hello', ctx: 'greeting')];
  late DateTime now;
  late List<Object> trace;
  late TranslationsApiClient client;
  var pending = true;
  var estimate = 0;

  setUp(() {
    now = DateTime.utc(2026);
    trace = [];
    pending = true;
    estimate = 0;
    client = TranslationsApiClient(
      baseUrl: 'http://localhost', token: 'eik_test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/projects/p/translate');
        expect(jsonDecode(request.body), {
          'units': [{'source': 'Hello', 'ctx': 'greeting'}], 'langs': ['fr'],
        });
        final dryRun = request.url.queryParameters['dryRun'] == 'true';
        trace.add(dryRun ? 'poll' : 'retry');
        return http.Response(jsonEncode({
          'estimatedCredits': estimate, 'balance': 100000,
          'trackingToken': dryRun ? null : 'ignored_job',
          'units': [{
            'key': 'hello', 'outcome': 'matched',
            'pending': pending ? ['fr'] : [], 'exhausted': ['de'],
          }],
        }), 200);
      }),
    );
  });
  tearDown(() => client.close());

  void progress(FillProgress event, int count, int retry) =>
      trace.add((event, count, retry));

  test('deadline is strict, cadence stays five seconds, final poll survives',
      () async {
    var waits = 0;
    final result = await runner.waitForFill(client, 'p', units, ['fr'],
      onProgress: progress, now: () => now, wait: (duration) async {
        expect(duration, const Duration(seconds: 5));
        now = now.add(waits++ == 0
            ? const Duration(minutes: 10) : const Duration(microseconds: 1));
      });
    expect(waits, 2);
    expect(trace, [
      'poll', (FillProgress.waiting, 1, 0), (FillProgress.pending, 1, 0),
      'poll', (FillProgress.pending, 1, 0),
      'poll', (FillProgress.timedOut, 1, 0),
    ]);
    expect(result.unitsNeedingTranslation, 1);
    expect(result.exhaustedPairs.single.toString(), 'hello [de]');
  });

  test('priced work times out without another retry or timeout announcement',
      () async {
    estimate = 100;
    await runner.waitForFill(client, 'p', units, ['fr'],
      onProgress: progress, now: () => now, wait: (_) async {
        now = now.add(const Duration(minutes: 11));
      });
    expect(trace, [
      'poll', (FillProgress.retrying, 1, 1), 'retry',
      (FillProgress.waiting, 1, 0), (FillProgress.pending, 1, 0), 'poll',
    ]);
  });

  test('failed work gets exactly two real retries before the final poll',
      () async {
    estimate = 100;
    await runner.waitForFill(client, 'p', units, ['fr'],
      onProgress: progress, now: () => now, wait: (_) async {});
    expect(trace, [
      'poll', (FillProgress.retrying, 1, 1), 'retry',
      (FillProgress.waiting, 1, 0), (FillProgress.pending, 1, 0),
      'poll', (FillProgress.retrying, 1, 2), 'retry',
      (FillProgress.pending, 1, 0), 'poll',
    ]);
  });

  test('completion wins over timeout and emits no further pending event',
      () async {
    final result = await runner.waitForFill(client, 'p', units, ['fr'],
      onProgress: progress, now: () => now, wait: (_) async {
        pending = false;
        now = now.add(const Duration(minutes: 11));
      });
    expect(result.unitsNeedingTranslation, 0);
    expect(trace, [
      'poll', (FillProgress.waiting, 1, 0), (FillProgress.pending, 1, 0),
      'poll', (FillProgress.complete, 0, 0),
    ]);
  });

  test('a completed first poll is silent and never waits', () async {
    pending = false;
    await runner.waitForFill(client, 'p', units, ['fr'],
      onProgress: progress, now: () => now, wait: (_) async => fail('unexpected wait'));
    expect(trace, ['poll']);
  });

  test('interrupted wait propagates unchanged and stops polling', () async {
    final interrupted = StateError('cancelled wait');
    await expectLater(runner.waitForFill(client, 'p', units, ['fr'],
      onProgress: progress, now: () => now, wait: (_) async => throw interrupted),
      throwsA(same(interrupted)));
    expect(trace, [
      'poll', (FillProgress.waiting, 1, 0), (FillProgress.pending, 1, 0),
    ]);
  });
}
