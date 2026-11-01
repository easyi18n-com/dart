import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/command_runner.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/transcript.dart';

/// The `push --json` contract: the payload an agent budgets against, so every
/// field of the estimate is asserted by value, and `--json` never becomes
/// consent to spend.
void main() {
  late Directory dir;
  late Transcript transcript;
  late List<http.Request> requests;
  late String config;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('push_json');
    transcript = Transcript();
    requests = [];
    config = p.join(dir.path, 'easyi18n.yaml');
    File(config).writeAsStringSync('projectId: proj_abc\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void writeSource(String body) => File(p.join(dir.path, 'lib', 'app.dart'))
    ..parent.createSync()
    ..writeAsStringSync(body);
  File lockFile() => File(p.join(dir.path, 'easyi18n.lock'));
  List<http.Request> translateCalls() =>
      requests.where((r) => r.url.path.endsWith('/translate')).toList();
  List<bool> dryRuns() => [
    for (final r in translateCalls()) r.url.queryParameters['dryRun'] == 'true',
  ];

  /// Prices each unit at 10 credits; the rest is per-test.
  TranslationsApiClient Function({required String baseUrl, required String token})
  clientWith({
    int perUnitMc = 10000,
    int balance = 1000000,
    int? available,
    bool wouldExceedKeyCap = false,
    int skippedGated = 0,
    int skippedDisabled = 0,
    List<String> exhausted = const [],
  }) => ({required baseUrl, required token}) => TranslationsApiClient(
    baseUrl: baseUrl, token: token,
    httpClient: MockClient((req) async {
      requests.add(req);
      if (req.url.path.endsWith('/meta')) return http.Response('{}', 403);
      final units = (jsonDecode(req.body)['units'] as List).length;
      final dryRun = req.url.queryParameters['dryRun'] == 'true';
      return http.Response(jsonEncode({
        'dryRun': dryRun,
        'trackingToken': dryRun ? null : 'job_1',
        'estimatedCredits': units * perUnitMc,
        'balance': balance,
        'availableCredits': ?available,
        'accepted': true,
        'wouldExceedKeyCap': wouldExceedKeyCap,
        'skippedGated': skippedGated,
        'skippedDisabled': skippedDisabled,
        'baseCode': 'en', 'targetLangs': ['fr'],
        'units': [
          for (var i = 0; i < units; i++)
            {'key': 'key_$i', 'token': 't', 'outcome': 'created',
              'translated': <String>[], 'pending': ['fr'],
              'exhausted': exhausted},
        ],
      }), 200);
    }),
  );

  /// A fill that settles on the first poll, so `--publish` runs without the
  /// real 5-second wait, plus a `/publish` the test can shape.
  TranslationsApiClient Function({required String baseUrl, required String token})
  publishClient({
    Map<String, Object?> published = const {
      'versionId': '2026.07.09.9', 'keyCount': 3,
    },
    bool free = false,
    int publishStatus = 201,
  }) {
    var pushed = free;
    return ({required baseUrl, required token}) => TranslationsApiClient(
      baseUrl: baseUrl, token: token,
      httpClient: MockClient((req) async {
        requests.add(req);
        if (req.url.path.endsWith('/publish')) {
          return publishStatus == 201
              ? http.Response(jsonEncode(published), 201)
              : http.Response(jsonEncode({'error': 'boom'}), publishStatus);
        }
        if (req.url.path.endsWith('/meta')) return http.Response('{}', 403);
        final units = (jsonDecode(req.body)['units'] as List).length;
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        final pending = dryRun && pushed ? <String>[] : <String>['fr'];
        if (!dryRun) pushed = true;

        return http.Response(jsonEncode({
          'dryRun': dryRun,
          'trackingToken': dryRun ? null : 'job_1',
          'estimatedCredits': pending.isEmpty ? 0 : units * 10000,
          'balance': 1000000,
          'accepted': true,
          'baseCode': 'en', 'targetLangs': ['fr'],
          'units': [
            for (var i = 0; i < units; i++)
              {'key': 'key_$i', 'token': 't', 'outcome': 'created',
                'translated': <String>[], 'pending': pending,
                'exhausted': <String>[]},
          ],
        }), 200);
      }),
    );
  }

  Future<int> run(List<String> args, {
    TranslationsApiClient Function({required String baseUrl, required String token})? client,
  }) async {
    final runner = Easyi18nCommandRunner(
      logger: CliLogger(out: transcript.out, err: transcript.err),
      environment: const {'EASYI18N_TOKEN': 'eik_x'},
      apiClientFactory: client ?? clientWith(),
    );
    return await runner.run(['--config', config, '--json', 'push', ...args]) ?? 0;
  }

  /// Exactly one stdout record, and it parses.
  Map<String, dynamic> payload() {
    final out = transcript.records.where((r) => r.channel == 'out').toList();
    expect(out, hasLength(1), reason: transcript.records.toString());
    return jsonDecode(out.single.line) as Map<String, dynamic>;
  }

  const estimateForTwo = {
    'units_needing_translation': 2,
    'estimated_credits': 20.0,
    'available_credits': 1000.0,
    'affordable': true,
    'would_exceed_key_cap': false,
    'skipped_gated': 0,
    'skipped_disabled': 0,
  };

  test('dry run: one record, every estimate field, nothing written', () async {
    writeSource("void f(c) { c.tr('Hello'); c.tr('Bye'); }\n");
    expect(await run(['--dry-run']), 0);
    final json = payload();
    expect(json['preview']['estimate'], estimateForTwo);
    expect(json['preview']['exhausted'], isEmpty);
    expect(json['preview']['scan']['total'], 2);
    expect(json['preview']['scan']['added'], 2);
    expect(json['pushed'], isNull);
    expect(json['published'], isNull);
    expect(json['lockfile_written'], isFalse);
    expect(json['dry_run'], isTrue);
    expect(dryRuns(), [true]);
    expect(lockFile().existsSync(), isFalse);
  });

  test('available_credits is what affordability was judged on', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run(['--dry-run'], client: clientWith(available: 5000)), 1);
    final estimate = payload()['preview']['estimate'];
    expect(estimate['estimated_credits'], 10.0);
    expect(estimate['available_credits'], 5.0);
    expect(estimate['affordable'], isFalse);
  });

  test('key cap, gated and disabled counts pass through', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run(['--dry-run'], client: clientWith(
      wouldExceedKeyCap: true, skippedGated: 3, skippedDisabled: 4)), 1);
    final estimate = payload()['preview']['estimate'];
    expect(estimate['would_exceed_key_cap'], isTrue);
    expect(estimate['skipped_gated'], 3);
    expect(estimate['skipped_disabled'], 4);
  });

  test('exhausted pairs are listed and redacted like every string', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run(['--dry-run'], client: clientWith(
      perUnitMc: 0, exhausted: ['de', 'eik_0123456789abcdef'])), 0);
    expect(payload()['preview']['exhausted'], [
      {'key': 'key_0', 'lang': 'de'},
      {'key': 'key_0', 'lang': '[REDACTED]'},
    ]);
  });

  test('--yes pushes, reports the jobs and writes the lockfile', () async {
    writeSource("void f(c) { c.tr('Hello'); c.tr('Bye'); }\n");
    expect(await run(['--yes']), 0);
    final json = payload();
    expect(json['preview']['estimate'], estimateForTwo);
    expect(json['pushed'], {
      'estimated_credits': 20.0,
      'tracking_tokens': ['job_1'],
      'exhausted': <Object>[],
    });
    expect(json['lockfile_written'], isTrue);
    expect(json['dry_run'], isFalse);
    expect(dryRuns(), [true, false]);
    expect(lockFile().existsSync(), isTrue);
  });

  test('a priced push without --yes is refused, not silently skipped', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run([]), 1);
    final json = payload();
    // Nothing was sent, so the record carries no report beside the error.
    expect(json.keys, ['error']);
    expect(json['error']['code'], 'confirmation_required');
    expect(json['error']['retryable'], isFalse);
    expect(json['error']['message'],
        startsWith('Refusing to spend ~10 credit(s) without --yes under --json'));
    expect(transcript.records.where((r) => r.channel == 'err'), isEmpty);
    expect(dryRuns(), [true]);
    expect(lockFile().existsSync(), isFalse);
  });

  test('an injected confirm is not consent under --json either', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    var asked = 0;
    final output = CliOutput(
        logger: CliLogger(out: transcript.out, err: transcript.err))
      ..json = true;
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config')
      ..addCommand(PushCommand(
        output: output,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
        apiClientFactory: clientWith(),
        confirm: (_) {
          asked++;
          return true;
        },
      ));
    await expectLater(runner.run(['--config', config, 'push']),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'confirmation_required')));
    expect(asked, 0);
    expect(dryRuns(), [true]);
    expect(lockFile().existsSync(), isFalse);
  });

  test('a free re-registration needs no consent', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run([], client: clientWith(perUnitMc: 0)), 0);
    final json = payload();
    expect(json['preview']['estimate']['estimated_credits'], 0.0);
    expect(json['pushed'], isNull);
    expect(json['lockfile_written'], isTrue);
    expect(dryRuns(), [true]);
    expect(lockFile().existsSync(), isTrue);
  });

  test('an empty scan reports the scan with no estimate and no request', () async {
    writeSource('void f() {}\n');
    expect(await run([]), 0);
    final json = payload();
    expect(json['preview']['scan']['files_scanned'], 1);
    expect(json['preview']['scan']['total'], 0);
    expect(json['preview']['estimate'], isNull);
    expect(json['preview']['exhausted'], isEmpty);
    expect(json['pushed'], isNull);
    expect(json['lockfile_written'], isFalse);
    expect(requests, isEmpty);
  });

  test('--publish carries the published version in the one record', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run(['--publish', '--yes'], client: publishClient()), 0,
        reason: transcript.records.toString());
    final json = payload();
    expect(json['published'], {
      'version_id': '2026.07.09.9',
      'key_count': 3,
      'unchanged': false,
      'refused': {'icu': [], 'icu_total': 0, 'markup': [], 'markup_total': 0},
    });
    expect(json['pushed'], isNotNull);
    expect(json['lockfile_written'], isTrue);
  });

  test('a push with nothing left to translate still reports its publish',
      () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(
      await run(['--publish', '--yes'], client: publishClient(free: true)),
      0,
    );
    final json = payload();
    expect(json['published']['version_id'], '2026.07.09.9');
    // The free path never posts for real, so this is the other publish exit.
    expect(json['pushed'], isNull);
    expect(json['lockfile_written'], isTrue);
    expect(dryRuns(), everyElement(isTrue));
  });

  test('a publish that changed nothing says so', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(
      await run(['--publish', '--yes'], client: publishClient(published: const {
        'versionId': '2026.07.09.9', 'keyCount': 3, 'unchanged': true,
      })),
      0,
    );
    final published = payload()['published'] as Map<String, dynamic>;
    expect(published['unchanged'], isTrue);
    expect(published['version_id'], '2026.07.09.9');
  });

  test('refused cells carry their rows AND the server totals, redacted',
      () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(
      await run(['--publish', '--yes'], client: publishClient(published: const {
        'versionId': 'v9', 'keyCount': 3,
        'icuRejected': ['greeting [fr]: bad plural', 'eik_0123456789abcdef'],
        // Above the two rows listed: the server caps each array at 50, so a
        // count off `length` would under-report this publish by 60 cells.
        'icuRejectedTotal': 62,
        'markupRejected': ['intro [de]: lost <b>'],
        'markupRejectedTotal': 1,
      })),
      0,
    );
    expect(payload()['published']['refused'], {
      'icu': ['greeting [fr]: bad plural', '[REDACTED]'],
      'icu_total': 62,
      'markup': ['intro [de]: lost <b>'],
      'markup_total': 1,
    });
  });

  test('publishing with nothing to extract still emits its one record',
      () async {
    writeSource('void f() {}\n');
    expect(await run(['--publish', '--yes'], client: publishClient()), 0);
    final json = payload();
    expect(json['published']['version_id'], '2026.07.09.9');
    expect(json['preview']['scan']['total'], 0);
    expect(json['preview']['estimate'], isNull);
    expect(json['pushed'], isNull);
    expect(json['lockfile_written'], isFalse);
    expect(lockFile().existsSync(), isFalse);
  });

  // The text run printed "Pushed." before the publish failed; the error
  // record is the only place an agent can read the same fact.
  test('a publish that fails after the push still reports what it did',
      () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(
      await run(['--publish', '--yes'],
          client: publishClient(publishStatus: 500)),
      1,
    );
    final json = payload();
    expect(json['error']['message'], startsWith('Publish failed: HTTP 500'));
    expect(json['error']['code'], 'boom');
    expect(json['error']['statusCode'], 500);
    expect(json['error']['retryable'], isTrue);
    expect(json['pushed'], {
      'estimated_credits': 10.0,
      'tracking_tokens': ['job_1'],
      'exhausted': <Object>[],
    });
    expect(json['lockfile_written'], isTrue);
    expect(json['published'], isNull);
    expect(json['dry_run'], isFalse);
    expect(json['preview']['estimate']['estimated_credits'], 10.0);
    expect(dryRuns().where((dryRun) => !dryRun), hasLength(1));
    expect(lockFile().existsSync(), isTrue);
  });

  test('a publish that fails after a free push says the lockfile moved',
      () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(
      await run(['--publish', '--yes'],
          client: publishClient(free: true, publishStatus: 500)),
      1,
    );
    final json = payload();
    expect(json['error']['code'], 'boom');
    expect(json['pushed'], isNull);
    expect(json['lockfile_written'], isTrue);
    expect(json['published'], isNull);
    expect(dryRuns(), everyElement(isTrue));
    expect(lockFile().existsSync(), isTrue);
  });

  test('a publish that fails with nothing extracted is the error alone',
      () async {
    writeSource('void f() {}\n');
    expect(
      await run(['--publish', '--yes'],
          client: publishClient(publishStatus: 500)),
      1,
    );
    expect(payload().keys, ['error']);
    expect(lockFile().existsSync(), isFalse);
  });

  // A real push goes out in batches of 500, and each accepted batch is
  // charged and queued. A failure on a later one reports the accepted ones.
  group('a failure inside the push', () {
    void writeStrings(int count) => writeSource(
      'void f(c) {\n'
      '${[for (var i = 0; i < count; i++) "  c.tr('s$i');"].join('\n')}\n}\n',
    );

    /// Real batches from [failFromBatch] on answer 400; a real batch charges
    /// [realPerUnitMc] a unit, the dry run 1 credit.
    TranslationsApiClient Function({required String baseUrl, required String token})
    batchClient({int? failFromBatch, int realPerUnitMc = 1000}) {
      var real = 0;
      return ({required baseUrl, required token}) => TranslationsApiClient(
        baseUrl: baseUrl, token: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path.endsWith('/meta')) return http.Response('{}', 403);
          final units = (jsonDecode(req.body)['units'] as List).length;
          final dryRun = req.url.queryParameters['dryRun'] == 'true';
          final batch = dryRun ? -1 : real++;
          if (failFromBatch != null && batch >= failFromBatch) {
            return http.Response('{"error":"boom"}', 400);
          }
          return http.Response(jsonEncode({
            'dryRun': dryRun,
            'trackingToken': dryRun ? null : 'job_$batch',
            'estimatedCredits': units * (dryRun ? 1000 : realPerUnitMc),
            'balance': 100000000, 'accepted': true,
            'baseCode': 'en', 'targetLangs': ['fr'],
            'units': [
              for (var i = 0; i < units; i++)
                {'key': 'k$i', 'token': 't', 'outcome': 'created',
                  'translated': <String>[], 'pending': ['fr'],
                  'exhausted': <String>[]},
            ],
          }), 200);
        }),
      );
    }

    test('a failed second batch keeps the first', () async {
      writeStrings(501);
      expect(await run(['--yes'], client: batchClient(failFromBatch: 1)), 1);
      final json = payload();
      expect(json['error']['code'], 'boom');
      expect(json['pushed'], {
        'estimated_credits': 500.0,
        'tracking_tokens': ['job_0'],
        'exhausted': <Object>[],
      });
      expect(json['lockfile_written'], isFalse);
      expect(json['published'], isNull);
      expect(lockFile().existsSync(), isFalse);
    });

    // The ceiling is checked after the batch that crossed it was charged.
    test('the --max-credits stop keeps the batch it charged', () async {
      writeStrings(501);
      expect(
        await run(['--yes', '--max-credits', '600'],
            client: batchClient(realPerUnitMc: 10000)),
        1,
      );
      final json = payload();
      expect(json['error']['message'], contains('Stopped before the remaining'));
      expect(json['pushed'], {
        'estimated_credits': 5000.0,
        'tracking_tokens': ['job_0'],
        'exhausted': <Object>[],
      });
      expect(json['lockfile_written'], isFalse);
    });

    test('a failed first batch is still the error alone', () async {
      writeStrings(501);
      expect(await run(['--yes'], client: batchClient(failFromBatch: 0)), 1);
      expect(payload().keys, ['error']);
      expect(dryRuns().where((dryRun) => !dryRun), hasLength(1));
    });
  });

  // The lockfile is written after the real push: a disk failure there keeps
  // the push, which already went out.
  test('a lockfile write that fails keeps the push beside the error',
      () async {
    writeSource("void f(c) { c.tr('Hello'); c.tr('Bye'); }\n");
    // A directory where the file goes: the write fails even as root.
    Directory(lockFile().path).createSync();
    expect(await run(['--yes']), 1);
    final json = payload();
    expect(json['error']['code'], 'file_system');
    expect(json['error']['retryable'], isFalse);
    expect(json['pushed'], {
      'estimated_credits': 20.0,
      'tracking_tokens': ['job_1'],
      'exhausted': <Object>[],
    });
    expect(json['lockfile_written'], isFalse);
  });

  // A free push writes the lockfile before anything reached the server.
  test('a lockfile write that fails on a free push is the error alone',
      () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    Directory(lockFile().path).createSync();
    expect(await run(['--yes'], client: clientWith(perUnitMc: 0)), 1);
    expect(payload().keys, ['error']);
    expect(payload()['error']['code'], 'file_system');
  });

  test('a lockfile write that fails without --json still throws', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    Directory(lockFile().path).createSync();
    final runner = Easyi18nCommandRunner(
      logger: CliLogger(out: transcript.out, err: transcript.err),
      environment: const {'EASYI18N_TOKEN': 'eik_x'},
      apiClientFactory: clientWith(),
    );
    await expectLater(runner.run(['--config', config, 'push', '--yes']),
        throwsA(isA<FileSystemException>()));
    expect(transcript.records.where((r) => r.line.startsWith('{')), isEmpty);
  });

  test('--max-credits keeps its text error and exit under --json', () async {
    writeSource("void f(c) => c.tr('Hello');\n");
    expect(await run(['--yes', '--max-credits', '1']), 1);
    expect(payload()['error']['message'], contains('exceeds --max-credits'));
    expect(dryRuns(), [true]);
  });
}
