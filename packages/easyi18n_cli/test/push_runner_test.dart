import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/push_runner.dart';
import 'package:test/test.dart';

void main() {
  const runner = PushRunner();
  final units = List.generate(1001, (i) => TranslateUnit(
    source: 'source $i', ctx: 'context $i', previousSource: 'old $i',
    previousCtx: 'previous $i',
  ));

  test('continuation skips accepted units and keeps manifest indices', () async {
    final client = _Client((_) => _result());
    addTearDown(client.close);
    final before = <int>[];
    final after = <int>[];
    await runner.run(client, 'project', units, ['fr'], dryRun: false,
      startBatch: 1,
      beforeSend: (index) { before.add(index); return {}; },
      afterSend: (index, _) => after.add(index));
    expect(client.batches.map((b) => b.length), [500, 1]);
    expect(client.batches.expand((b) => b), orderedEquals(units.skip(500)),
      reason: 'accepted units must not leave again');
    expect(before, [1, 2], reason: 'identity uses the absolute manifest index');
    expect(after, [1, 2], reason: 'response uses the absolute manifest index');
  });

  test('batches preserve payloads and aggregate mixed server results', () async {
    final client = _Client((index) => TranslateResult(
      trackingToken: index == 1 ? null : 'job_$index',
      estimatedCredits: (index + 1) * 10, balance: 1000 - index,
      availableCredits: 40 - index, accepted: true,
      wouldExceedKeyCap: index == 1, skippedGated: index + 1,
      skippedDisabled: 2 * index,
      units: [TranslateUnitResult(outcome: 'matched', key: 'key_$index',
        pending: index == 1 ? [] : ['fr', 'de'], exhausted: ['de'],
        budgetExhausted: index == 2 ? ['de'] : [])],
    ));
    addTearDown(client.close);
    final result = await runner.run(client, 'project', units, ['fr', 'de'],
      dryRun: true, maxCreditsMc: 1);
    expect(client.batches.map((b) => b.length), [500, 500, 1]);
    expect(client.batches.expand((b) => b), orderedEquals(units));
    expect(client.languages, everyElement(['fr', 'de']));
    expect(client.projects, everyElement('project'));
    expect(client.dryRuns, [true, true, true]);
    expect(result.estimatedCredits, 60);
    expect(result.balance, 998);
    expect(result.spendable, 38);
    expect(result.affordable, isFalse);
    expect(result.unitsNeedingTranslation, 2);
    expect(result.trackingTokens, ['job_0', 'job_2']);
    expect(result.wouldExceedKeyCap, isTrue);
    expect(result.skippedGated, 6);
    expect(result.skippedDisabled, 6);
    expect(result.exhaustedPairs.map((p) => p.toString()),
      ['key_0 [de]', 'key_1 [de]', 'key_2 [de]']);
    // Pairs, not units: key_0 and key_2 each hold two pending langs (#1823).
    expect(result.pendingPairs, 4);
    expect(result.budgetExhaustedPairs.map((p) => p.toString()),
      ['key_2 [de]']);
  });

  for (final budget in [19, 20]) {
    test('real push budget $budget checks cumulative cost after each batch', () async {
      final client = _Client((_) => _result());
      addTearDown(client.close);
      final future = runner.run(client, 'project', units, [],
        dryRun: false, maxCreditsMc: budget);
      await expectLater(future, throwsA(isA<CliException>().having(
        (e) => e.message, 'message', contains('completed batches, exceeding'))));
      expect(client.batches.map((b) => b.length),
        budget == 19 ? [500, 500] : [500, 500, 1]);
      expect(client.dryRuns, everyElement(false));
      expect(client.languages, everyElement(isNull));
    });
  }

  test('last batch can restore legacy balance fallback; equality is affordable', () async {
    final client = _Client((i) => _result(available: i == 0 ? 1 : null));
    addTearDown(client.close);
    final result = await runner.run(client, 'project', units.take(501).toList(),
      [], dryRun: false, maxCreditsMc: 20);
    expect(result.availableCredits, isNull);
    expect(result.spendable, 20);
    expect(result.estimatedCredits, 20);
    expect(result.affordable, isTrue);
    expect(client.batches.map((b) => b.length), [500, 1]);
  });

  test('a failed batch stops the remaining requests and preserves the error', () async {
    final error = StateError('failed second batch');
    final client = _Client((i) => i == 1 ? throw error : _result());
    addTearDown(client.close);
    await expectLater(runner.run(client, 'project', units, [], dryRun: false),
      throwsA(same(error)));
    expect(client.batches.map((b) => b.length), [500, 500]);
  });
}

TranslateResult _result({int? available}) => TranslateResult(
  trackingToken: null, estimatedCredits: 10, balance: 20,
  availableCredits: available, accepted: true, wouldExceedKeyCap: false,
  units: [],
);

class _Client extends TranslationsApiClient {
  _Client(this.response) : super(baseUrl: 'http://localhost', token: 'test');
  final TranslateResult Function(int) response;
  final batches = <List<TranslateUnit>>[];
  final languages = <List<String>?>[];
  final projects = <String>[];
  final dryRuns = <bool>[];

  @override
  Future<TranslateResult> translate({required String projectId,
    required List<TranslateUnit> units, List<String>? langs,
    bool dryRun = false, Map<String, Object?> identity = const {}}) async {
    batches.add(units);
    languages.add(langs);
    projects.add(projectId);
    dryRuns.add(dryRun);
    return response(batches.length - 1);
  }
}
