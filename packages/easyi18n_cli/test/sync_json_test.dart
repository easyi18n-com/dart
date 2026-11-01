import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/command_runner.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/transcript.dart';

/// The `sync --json` contract: the record an agent budgets and diffs against,
/// and the rule that `--json` is never consent to spend.
void main() {
  late Directory dir;
  late Transcript transcript;
  late List<http.Request> requests;
  late String config;
  var syncCall = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_json');
    transcript = Transcript();
    requests = [];
    syncCall = 0;
    config = p.join(dir.path, 'easyi18n.yaml');
    File(config).writeAsStringSync(
      'projectId: p1\nformat: xcstrings\ncatalog: App/Localizable.xcstrings\n',
    );
    File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"sourceLanguage":"es","strings":{"Hola":{}},"version":"1.0"}',
      );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<http.Request> syncCalls() =>
      requests.where((r) => r.url.path.endsWith('/sync')).toList();
  bool published() => requests.any((r) => r.url.path.endsWith('/publish'));

  MockClient clientWith({
    int estimatedCredits = 12000,
    Map<String, Object?> publishExtra = const {},
    /// Per real-POST overrides, by index: what only THAT attempt reported.
    List<Map<String, Object?>> perAttempt = const [],
    List<Map<String, Object?>> conflicts = const [],
    List<Map<String, Object?>> diagnostics = const [],
    List<Map<String, Object?>> exhausted = const [],
    int pendingSkipped = 0,
    int publishStatus = 201,
    int pullStatus = 200,
    /// Real POSTs from this index on answer 500.
    int? failFromAttempt,
    Map<String, Object?> job = const {'status': 'done'},
    int jobStatus = 200,
    /// The files of a per-locale `json` project, served instead of the catalog.
    Map<String, String>? perLocale,
  }) => MockClient((req) async {
    requests.add(req);
    const headers = {'content-type': 'application/json'};
    final path = req.url.path;
    if (path.endsWith('/meta')) {
      return http.Response(jsonEncode({
        'baseCode': perLocale == null ? 'es' : 'en', 'outputFormatsApiVersion': 1, 'currentVersionId': 'v1',
        'languages': const [],
        'formats': [perLocale == null ? 'xcstrings' : 'json'],
      }), 200, headers: headers);
    }
    if (path.endsWith('/sync')) {
      final dryRun = req.url.queryParameters['dryRun'] == 'true';
      final attempt = dryRun ? -1 : syncCall++;
      if (failFromAttempt != null && attempt >= failFromAttempt) {
        return http.Response('{"error":"sync_down"}', 500);
      }
      final override = attempt >= 0 && attempt < perAttempt.length
          ? perAttempt[attempt]
          : const <String, Object?>{};
      return http.Response(jsonEncode({
        'dryRun': dryRun, 'format': perLocale == null ? 'xcstrings' : 'json',
        'baseCode': perLocale == null ? 'es' : 'en',
        'targetLangs': [perLocale == null ? 'en' : 'es'],
        'fillableLangs': [perLocale == null ? 'en' : 'es'],
        'created': 1, 'updatedSources': 0, 'matchedSources': 0,
        'updatedTranslations': 0, 'unchangedTranslations': 0,
        'disabledOrphans': 0, 'reenabled': 0,
        'failedEntries': const [], 'exhausted': exhausted,
        'conflicts': conflicts, 'conflictsTotal': conflicts.length,
        'onConflict': 'server', 'diagnostics': diagnostics,
        'pendingSkipped': pendingSkipped,
        'trackingToken': null, 'estimatedCredits': estimatedCredits,
        'balance': 500000, 'availableCredits': 400000, 'accepted': true,
        ...override,
      }), 200, headers: headers);
    }
    if (path.endsWith('/publish')) {
      if (publishStatus != 201) {
        return http.Response('{"error":"publish_down"}', publishStatus);
      }
      return http.Response(
        jsonEncode({
          'versionId': '2026.08.11.1', 'keyCount': 2, ...publishExtra,
        }),
        201, headers: headers,
      );
    }
    if (req.url.queryParameters.containsKey('trackingToken')) {
      return jobStatus == 200
          ? http.Response(jsonEncode(job), 200, headers: headers)
          : http.Response('{"error":"poll_down"}', jobStatus);
    }
    if (path.endsWith('/translations')) {
      if (pullStatus != 200) {
        return http.Response('{"error":"pull_down"}', pullStatus);
      }
      return http.Response(jsonEncode({
        'project': 'p1', 'version': '2026.08.11.1', 'baseCode': perLocale == null ? 'es' : 'en',
        'formats': [perLocale == null ? 'xcstrings' : 'json'],
        'files': perLocale ?? {
          'xcstrings/Localizable.xcstrings':
              '{"sourceLanguage":"es","strings":{"Hola":{"localizations":'
              '{"en":{"stringUnit":{"state":"translated","value":"Hello"}}}}}}',
        },
      }), 200, headers: headers);
    }
    return http.Response('{"error":"not_found"}', 404);
  });

  Future<int> run(MockClient mock, List<String> args) async {
    final runner = Easyi18nCommandRunner(
      logger: CliLogger(out: transcript.out, err: transcript.err),
      environment: const {'EASYI18N_TOKEN': 'eik_x'},
      apiClientFactory: ({required baseUrl, required token}) =>
          TranslationsApiClient(
            baseUrl: baseUrl, token: token, httpClient: mock,
          ),
    );
    return await runner.run(['--config', config, '--json', 'sync', ...args]) ?? 0;
  }

  Map<String, Object?> payloadOf() {
    final out = transcript.records.where((r) => r.channel == 'out').toList();
    expect(out, hasLength(1), reason: '--json emits exactly one record');
    return jsonDecode(out.single.line) as Map<String, Object?>;
  }

  group('consent', () {
    // JSON is a wire, not a person. Exiting 0 having spent nothing would read
    // as success to an agent that keys on the exit code.
    test('a priced sync without --yes refuses instead of prompting', () async {
      final code = await run(clientWith(), []);
      expect(code, 1);
      final error = payloadOf()['error']! as Map<String, Object?>;
      expect(error['code'], 'confirmation_required');
      expect(error['message'], contains('--yes'));
      // The dry run is the only call it made: nothing was posted for real.
      expect(syncCalls(), hasLength(1));
      expect(syncCalls().single.url.queryParameters['dryRun'], 'true');
      expect(published(), isFalse);
    });

    test('--yes is the consent a priced sync accepts', () async {
      expect(await run(clientWith(), ['--yes']), 0);
      // The preview asks for the dry run; the real POST omits the flag.
      expect(syncCalls().map((r) => r.url.queryParameters['dryRun']),
          ['true', null]);
      expect(published(), isTrue);
    });

    // An injected `confirm` is not consent either: under --json the prompt
    // must never be reached, so stdout stays the wire.
    test('the injected confirm is never consulted under --json', () async {
      var asked = false;
      final command = SyncCommand(
        output: CliOutput(
          logger: CliLogger(out: transcript.out, err: transcript.err),
        )..json = true,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
        apiClientFactory: ({required baseUrl, required token}) =>
            TranslationsApiClient(
              baseUrl: baseUrl, token: token, httpClient: clientWith(),
            ),
        confirm: (_) {
          asked = true;
          return true;
        },
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config')
        ..addCommand(command);
      await expectLater(
        runner.run(['--config', config, 'sync']),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'confirmation_required')),
      );
      expect(asked, isFalse);
      expect(published(), isFalse);
    });

    // A free sync has nothing to consent to, so it runs unattended.
    test('a zero estimate needs no consent', () async {
      expect(await run(clientWith(estimatedCredits: 0), []), 0);
      expect(syncCalls(), hasLength(2));
      expect(published(), isTrue);
    });

    test('--dry-run prices without consent and delivers nothing', () async {
      expect(await run(clientWith(), ['--dry-run']), 0);
      expect(syncCalls(), hasLength(1));
      expect(published(), isFalse);
      final json = payloadOf();
      expect(json['dry_run'], isTrue);
      expect(json['synced'], isNull);
      expect(json['delivery'], isNull);
    });
  });

  test('a budget refusal reaches the JSON consumer as a record', () async {
    // `sync` is a JsonPresenter now, so an exit that only writes stderr text
    // leaves an agent with a bare exit code and nothing to read.
    final code = await run(clientWith(), ['--yes', '--max-credits', '1']);
    expect(code, 1);
    final error = payloadOf()['error']! as Map<String, Object?>;
    expect(error['code'], 'budget_exceeded');
    expect(error['message'], contains('exceeds --max-credits'));
    // And it still refuses before spending: the dry run and nothing else.
    expect(syncCalls(), hasLength(1));
    expect(syncCalls().single.url.queryParameters['dryRun'], 'true');
    expect(published(), isFalse);
  });

  // Every response is a report of something that HAPPENED. Serializing only
  // the last one drops any row a superseded attempt was the sole carrier of —
  // a dashboard edit landing after the preview, overwritten by the first real
  // POST, is gone by the retry that a contended row forces.
  test('rows only an intermediate attempt reported still reach the JSON',
      () async {
    final conflict = {
      'key': 'Hola', 'lang': 'es', 'origin': 'human',
      'stage': 'reviewed', 'resolution': 'overwritten',
    };
    const diagnostic = {
      'code': 'PLURAL_BEHIND_PROJECT', 'field': 'Hola', 'lang': 'en',
      'message': 'the project carries a newer plural',
    };
    final code = await run(
      clientWith(perAttempt: [
        {
          'conflicts': [conflict], 'conflictsTotal': 1,
          'diagnostics': const [diagnostic],
          'failedEntries': [
            {'key': 'Chau', 'code': 'contended', 'reason': 'peer sync'},
          ],
        },
        const <String, Object?>{},
      ]),
      ['--yes'],
    );
    expect(code, 0);
    expect(syncCalls(), hasLength(3), reason: 'preview, first POST, retry');
    final json = payloadOf();
    final attempts = json['attempts']! as List;
    expect(attempts, hasLength(2), reason: 'one entry per real POST');
    expect((attempts.first as Map)['conflicts'], [conflict],
        reason: 'the row the retry no longer reports was dropped');
    expect((attempts.first as Map)['diagnostics'], [diagnostic],
        reason: 'a diagnostic only one attempt carried was dropped');
    // `synced` is the state the publish was judged on, and it stays the last
    // response — rows and total from the same server at the same moment.
    final synced = json['synced']! as Map<String, Object?>;
    expect(synced['conflicts'], isEmpty);
    expect(synced['conflicts_total'], 0);
  });

  // Every object in the record must be self-consistent: a row list and a
  // total that disagree let a consumer summarising off the total conclude
  // there were no conflicts while the record describes one.
  test('no object mixes one attempt rows with another total', () async {
    await run(
      clientWith(perAttempt: [
        {
          'conflicts': [
            {'key': 'Hola', 'lang': 'es', 'resolution': 'kept'},
          ],
          'conflictsTotal': 1,
          'failedEntries': [
            {'key': 'Chau', 'code': 'contended', 'reason': 'peer sync'},
          ],
        },
        const <String, Object?>{},
      ]),
      ['--yes'],
    );
    final json = payloadOf();
    for (final object in [
      json['synced']! as Map<String, Object?>,
      ...(json['attempts']! as List).cast<Map<String, Object?>>(),
    ]) {
      expect(
        object['conflicts_total'],
        greaterThanOrEqualTo((object['conflicts']! as List).length),
        reason: 'a total that belongs to a different set of rows',
      );
    }
  });

  // The server caps each list and sends the real total alongside, so a total
  // ABOVE the rows is the honest case — and the one a union's length would
  // have silently rewritten downwards.
  test('an attempt total above its capped rows survives', () async {
    await run(
      clientWith(perAttempt: [
        {
          'conflicts': [
            {'key': 'a', 'lang': 'en', 'resolution': 'kept'},
            {'key': 'b', 'lang': 'en', 'resolution': 'kept'},
          ],
          'conflictsTotal': 57,
        },
      ]),
      ['--yes'],
    );
    final json = payloadOf();
    final attempt = (json['attempts']! as List).single as Map<String, Object?>;
    expect((attempt['conflicts']! as List), hasLength(2));
    expect(attempt['conflicts_total'], 57);
    expect((json['synced']! as Map)['conflicts_total'], 57);
  });

  // What the run already did when a later stage fails. The ingest and the
  // publish are effects on the server, and the text run has already printed
  // them, so the error record carries them beside `error` (#1835).
  group('a failure after the ingest', () {
    test('a failed publish keeps the synced run in the error record',
        () async {
      final code = await run(clientWith(publishStatus: 500), ['--yes']);
      expect(code, 1);
      expect(syncCalls(), hasLength(2));
      expect(published(), isTrue);
      final json = payloadOf();
      final error = json['error']! as Map<String, Object?>;
      expect(error['code'], 'publish_down');
      expect(error['statusCode'], 500);
      expect(json['synced'],
          isA<Map>().having((m) => m['created'], 'created', 1));
      expect(json['attempts'], hasLength(1));
      expect(json['still_incomplete'], isFalse);
      expect(json['delivery'], isNull);
      expect(json['dry_run'], isFalse);
    });

    // The version is live once the publish answered: a record that dropped
    // it would tell the agent nothing was published.
    test('a failed pull keeps the published version and no catalog check',
        () async {
      final code = await run(clientWith(pullStatus: 500), ['--yes']);
      expect(code, 1);
      final json = payloadOf();
      expect((json['error']! as Map)['statusCode'], 500);
      expect(json['attempts'], hasLength(1));
      final delivery = json['delivery']! as Map<String, Object?>;
      expect(delivery['version_id'], '2026.08.11.1');
      expect(delivery['key_count'], 2);
      expect(delivery['pulled_version'], isNull);
      // Nothing was read back, so nothing can be said about its languages.
      expect(delivery['languages'], isNull);
    });

    test('a --require-complete refusal after the run keeps the synced run',
        () async {
      final code = await run(
        clientWith(perAttempt: [{'pendingSkipped': 2}]),
        ['--yes', '--require-complete'],
      );
      expect(code, 1);
      expect(published(), isFalse);
      final json = payloadOf();
      expect((json['error']! as Map)['message'],
          contains('--require-complete'));
      expect(json['synced'],
          isA<Map>().having((m) => m['pending_skipped'], 'pending_skipped', 2));
      expect(json['delivery'], isNull);
    });

    // The consent refusal is the last exit before the real POST, and it runs
    // after the report is built: nothing has happened yet to report.
    test('a refusal before the ingest is still the error alone', () async {
      await run(clientWith(), []);
      expect(syncCalls(), hasLength(1));
      expect(payloadOf().keys, ['error']);
    });

    // The first real POST is the first effect: a failure on it has nothing
    // to report yet.
    test('a first real POST that fails is still the error alone', () async {
      final code = await run(
        clientWith(estimatedCredits: 0, failFromAttempt: 0),
        ['--yes'],
      );
      expect(code, 1);
      expect(syncCall, 1);
      expect(payloadOf().keys, ['error']);
    });

    test('without --json the failure still throws', () async {
      final runner = Easyi18nCommandRunner(
        logger: CliLogger(out: transcript.out, err: transcript.err),
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
        apiClientFactory: ({required baseUrl, required token}) =>
            TranslationsApiClient(
              baseUrl: baseUrl,
              token: token,
              httpClient: clientWith(publishStatus: 500),
            ),
      );
      await expectLater(
        runner.run(['--config', config, 'sync', '--yes']),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
      expect(transcript.records.where((r) => r.line.startsWith('{')),
          isEmpty);
    });
  });

  // Every answered POST applied the catalog, so a run that fails before it
  // settles still reports them. `synced` is the last answer; what only a
  // settled run decides stays null.
  group('a failure inside the run', () {
    void expectUnsettled(Map<String, Object?> json, {required int attempts}) {
      expect(json['attempts'], hasLength(attempts));
      expect(json['still_incomplete'], isNull);
      expect(json['stopped_short'], isNull);
      expect(json['delivery'], isNull);
      expect(json['dry_run'], isFalse);
      expect(published(), isFalse);
    }

    test('contended entries left after the retries keep every attempt',
        () async {
      const contended = {
        'failedEntries': [
          {'key': 'Chau', 'code': 'contended', 'reason': 'peer sync'},
        ],
      };
      final code = await run(
        clientWith(
          estimatedCredits: 0,
          perAttempt: [
            for (var i = 0; i < 3; i++) {...contended, 'pendingSkipped': i},
          ],
        ),
        ['--yes'],
      );
      expect(code, 1);
      expect(syncCall, 3);
      final json = payloadOf();
      expect((json['error']! as Map)['message'], contains('Chau'));
      expectUnsettled(json, attempts: 3);
      expect((json['synced']! as Map)['failed_entries'],
          contended['failedEntries']);
      // The last answer, not the first: each attempt reports its own count.
      expect((json['synced']! as Map)['pending_skipped'], 2);
    });

    test('a failed job poll keeps the POST that queued the job', () async {
      final code = await run(
        clientWith(
          estimatedCredits: 0,
          perAttempt: [{'trackingToken': 'job_1'}],
          jobStatus: 500,
        ),
        ['--yes'],
      );
      expect(code, 1);
      final json = payloadOf();
      expect((json['error']! as Map)['statusCode'], 500);
      expectUnsettled(json, attempts: 1);
      expect((json['synced']! as Map)['tracking_token'], 'job_1');
    });

    test('a failed re-POST keeps the POSTs that were answered', () async {
      final code = await run(
        clientWith(
          estimatedCredits: 0,
          perAttempt: [{'trackingToken': 'job_1'}],
          job: const {
            'status': 'done',
            'summary': {'total': 2, 'translated': 1, 'pending': 1},
          },
          failFromAttempt: 1,
        ),
        ['--yes'],
      );
      expect(code, 1);
      expect(syncCall, 2, reason: 'the fill retry re-POSTed');
      final json = payloadOf();
      expect((json['error']! as Map)['code'], 'sync_down');
      expectUnsettled(json, attempts: 1);
      expect((json['synced']! as Map)['tracking_token'], 'job_1');
    });
  });

  // A write-back that fails on disk comes after the publish: the version is
  // live, so the record names it instead of leaving stdout empty.
  group('a disk failure', () {
    void blockWriteBack() =>
        Directory(p.join(dir.path, 'App', 'Localizable.xcstrings.tmp'))
            .createSync();

    test('after the publish keeps the published version', () async {
      blockWriteBack();
      final code = await run(clientWith(estimatedCredits: 0), ['--yes']);
      expect(code, 1);
      expect(published(), isTrue);
      final json = payloadOf();
      final error = json['error']! as Map<String, Object?>;
      expect(error['code'], 'file_system');
      expect(error['retryable'], isFalse);
      expect(error['message'], contains('Localizable.xcstrings.tmp'));
      expect(json['attempts'], hasLength(1));
      final delivery = json['delivery']! as Map<String, Object?>;
      expect(delivery['version_id'], '2026.08.11.1');
      expect(delivery['pulled_version'], isNull);
    });

    // The catalog exists, so the scan passes; the preview is what reads it,
    // before anything reached the server.
    test('reading the catalog is the error alone', () async {
      final catalog = p.join(dir.path, 'App', 'Localizable.xcstrings');
      Process.runSync('chmod', ['000', catalog]);
      addTearDown(() => Process.runSync('chmod', ['644', catalog]));
      expect(await run(clientWith(), ['--yes']), 1);
      expect(requests.where((r) => r.url.path.endsWith('/sync')), isEmpty);
      expect(payloadOf().keys, ['error']);
      expect((payloadOf()['error']! as Map)['code'], 'file_system');
    });

    test('without --json still throws', () async {
      blockWriteBack();
      final runner = Easyi18nCommandRunner(
        logger: CliLogger(out: transcript.out, err: transcript.err),
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
        apiClientFactory: ({required baseUrl, required token}) =>
            TranslationsApiClient(
              baseUrl: baseUrl,
              token: token,
              httpClient: clientWith(estimatedCredits: 0),
            ),
      );
      await expectLater(
        runner.run(['--config', config, 'sync', '--yes']),
        throwsA(isA<FileSystemException>()),
      );
      expect(transcript.records.where((r) => r.line.startsWith('{')),
          isEmpty);
    });
  });

  group('payload', () {
    // The two channels `/v1/sync` is the ONLY reporter for. A code this
    // serialization drops is a code the agent never sees.
    test('conflicts and diagnostics ride verbatim, codes and all', () async {
      final conflict = {
        'key': 'Hola', 'lang': 'es', 'origin': 'human',
        'stage': 'reviewed', 'resolution': 'kept',
        'updatedAt': '2026-08-20T00:00:00Z',
      };
      final diagnostics = [
        {'code': 'DUPLICATE_PLURAL_FORM', 'field': 'Hola', 'lang': 'en',
          'message': 'selector "one" repeated'},
        {'code': 'PLURAL_SHAPE_MISMATCH', 'field': 'Chau', 'lang': 'fr',
          'message': 'the catalog lost a plural branch'},
        {'code': 'LANG_NOT_IN_FILE', 'field': 'de',
          'alsoSpelled': ['de-DE']},
      ];
      await run(
        clientWith(conflicts: [conflict], diagnostics: diagnostics),
        ['--yes'],
      );
      final json = payloadOf();
      expect(((json['attempts']! as List).single as Map)['conflicts'],
          [conflict]);
      for (final side in ['preview', 'synced']) {
        final r = json[side]! as Map<String, Object?>;
        expect(r['conflicts'], [conflict],
            reason: '$side dropped or reshaped the #671 base-language row');
        expect(r['diagnostics'], diagnostics,
            reason: '$side dropped a #727 parse code');
        expect(r['conflicts_total'], 1);
        expect(r['on_conflict'], 'server');
      }
    });

    test('exhausted pairs and held pairs survive the serialization', () async {
      await run(
        clientWith(
          exhausted: [{'key': 'Hola', 'lang': 'en'}],
          pendingSkipped: 3,
        ),
        ['--yes'],
      );
      final synced = payloadOf()['synced']! as Map<String, Object?>;
      expect(synced['exhausted'], [{'key': 'Hola', 'lang': 'en'}]);
      expect(synced['pending_skipped'], 3);
    });

    test('credits are credits, not millicredits', () async {
      await run(clientWith(estimatedCredits: 12500), ['--yes']);
      final preview = payloadOf()['preview']! as Map<String, Object?>;
      expect(preview['estimated_credits'], 12.5);
      expect(preview['available_credits'], 400.0);
    });

    test('--no-publish reports the run and no delivery', () async {
      final code = await run(clientWith(), ['--yes', '--no-publish']);
      expect(code, 0);
      expect(published(), isFalse);
      final json = payloadOf();
      expect(json['delivery'], isNull);
      expect((json['synced']! as Map)['dry_run'], isFalse);
      expect(json['still_incomplete'], isFalse);
    });

    // The server caps each rejection array at 50 and sends the real totals
    // alongside. A count taken off `list.length` under-reports exactly the
    // publishes carrying the most damage — and every other fixture has zero
    // rejections, where the two numbers agree. The rows ride along because
    // the text run names them one per line (#609): a `--json` consumer that
    // only got the totals would read the publish as clean where a human does
    // not.
    test('refused carries the capped rows and the real totals', () async {
      await run(
        clientWith(publishExtra: {
          'icuRejected': ['a [en]: bad ICU', 'b [en]: bad ICU'],
          'icuRejectedTotal': 57,
          'markupRejected': ['c [fr]: lost markup'],
          'markupRejectedTotal': 12,
        }),
        ['--yes'],
      );
      final delivery = payloadOf()['delivery']! as Map<String, Object?>;
      expect(delivery['refused'], {
        'icu': ['a [en]: bad ICU', 'b [en]: bad ICU'],
        'icu_total': 57,
        'markup': ['c [fr]: lost markup'],
        'markup_total': 12,
      });
    });

    test('the delivery names the version written and both language gaps',
        () async {
      await run(clientWith(), ['--yes']);
      final delivery = payloadOf()['delivery']! as Map<String, Object?>;
      expect(delivery['version_id'], '2026.08.11.1');
      expect(delivery['unchanged'], isFalse);
      expect(delivery['key_count'], 2);
      expect(delivery['pulled_version'], '2026.08.11.1');
      expect(delivery['refused'],
          {'icu': [], 'icu_total': 0, 'markup': [], 'markup_total': 0});
      expect(delivery['languages'], {'missing': [], 'extra': []});
    });

    // The write-back of a per-locale project reads no catalog back, so it
    // has nothing to say about gaps: null, never an empty record.
    test('a per-locale project delivers its version and no language record',
        () async {
      File(config).writeAsStringSync('projectId: p1\nmode: a\nformat: json\n'
          'output: i18n\nsource: i18n/en.json\nsourceRoot: i18n\nsourceLayout: locale-files\n');
      File(p.join(dir.path, 'i18n', 'en.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"hello": "Hello"}');
      final code = await run(
        clientWith(perLocale: const {
          'json/en.json': '{"hello":"Hello"}',
          'json/es.json': '{"hello":"Hola"}',
        }),
        ['--yes'],
      );
      expect(code, 0);
      final delivery = payloadOf()['delivery']! as Map<String, Object?>;
      expect(delivery['pulled_version'], '2026.08.11.1');
      expect(delivery['languages'], isNull);
      expect(File(p.join(dir.path, 'i18n', 'es.json')).readAsStringSync(),
          '{"hello":"Hola"}');
    });
  });
}
