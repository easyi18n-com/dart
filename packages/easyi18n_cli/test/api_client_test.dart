import 'dart:convert';
import 'dart:math';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/backoff.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Distinguishes "the backend sent `snapshotAt: null`" from "the backend
/// never sent the field at all" in the fixtures below.
const Object _absent = Object();

void main() {
  // Every retry the client performs asks [waits] for its delay instead of
  // sleeping, so a test asserting on backoff neither waits nor flakes.
  late List<Duration> waits;
  setUp(() => waits = []);

  TranslationsApiClient clientReturning(
    http.Response Function(http.Request) handler,
  ) => TranslationsApiClient(
    baseUrl: 'https://api.easyi18n.com',
    token: 'eik_secret',
    httpClient: MockClient((req) async => handler(req)),
    wait: (d) async => waits.add(d),
    random: Random(7),
  );

  test('sends bearer auth and parses the file map', () async {
    late http.Request captured;
    final client = clientReturning((req) {
      captured = req;
      return http.Response(
        jsonEncode({
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb'],
          'files': {
            'arb/app_en.arb': '{"hi":"Hi"}',
            'arb/app_es.arb': '{"hi":"Hola"}',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final result = await client.fetchTranslations(
      projectId: 'proj_abc',
      format: 'arb',
    );

    expect(captured.headers['authorization'], 'Bearer eik_secret');
    expect(captured.url.path, '/v1/projects/proj_abc/translations');
    expect(captured.url.queryParameters['format'], 'arb');
    expect(result.version, '2026.06.26');
    expect(result.baseCode, 'en');
    expect(result.files, hasLength(2));
    expect(result.files['arb/app_es.arb'], '{"hi":"Hola"}');
  });

  test('forwards version and lang as query params', () async {
    late http.Request captured;
    final client = clientReturning((req) {
      captured = req;
      return http.Response(jsonEncode({'files': <String, String>{}}), 200);
    });

    await client.fetchTranslations(
      projectId: 'p',
      format: 'arb',
      version: '2026.01.01',
      lang: 'es',
    );

    expect(captured.url.queryParameters['version'], '2026.01.01');
    expect(captured.url.queryParameters['lang'], 'es');
  });

  group('snapshotAt (#898)', () {
    Future<PulledTranslations> pullWith(Object? snapshotAt) {
      final client = clientReturning(
        (req) => http.Response(
          jsonEncode({
            'version': '2026.08.20.1',
            'files': <String, String>{'arb/app_en.arb': '{}'},
            if (snapshotAt != _absent) 'snapshotAt': snapshotAt,
          }),
          200,
        ),
      );
      return client.fetchTranslations(projectId: 'p', format: 'arb');
    }

    test('a zoned instant is parsed to UTC', () async {
      expect(
        (await pullWith('2026-08-20T09:00:00.000Z')).snapshotAt,
        DateTime.utc(2026, 8, 20, 9),
      );
      // An offset is a zone too, and normalizing it is what makes the claim
      // comparable to the server's own stamps.
      expect(
        (await pullWith('2026-08-20T11:00:00+02:00')).snapshotAt,
        DateTime.utc(2026, 8, 20, 9),
      );
    });

    test('an older backend reports nothing, and that is not an error',
        () async {
      expect((await pullWith(_absent)).snapshotAt, isNull);
      expect((await pullWith(null)).snapshotAt, isNull);
    });

    test('a stamp naming no zone is dropped, never guessed', () async {
      // `DateTime.parse` would read it as the CLI process's local time, and
      // west of UTC that runs FORWARD — silently disarming the server's
      // base-language guard, which refuses the same guess on its own side.
      expect((await pullWith('2026-08-20T09:00:00')).snapshotAt, isNull);
      expect((await pullWith('2026-08-20')).snapshotAt, isNull);
    });

    test('a wrong-shaped value degrades the field, it does NOT fail the pull',
        () async {
      // `_str` throws on a non-String. Reading this field through it would
      // turn a 200 of an odd shape into a failed pull — a new refusal in a
      // purely additive change (#972).
      for (final bad in <Object>[42, true, const ['x'], <String, int>{'a': 1}]) {
        final pulled = await pullWith(bad);
        expect(pulled.snapshotAt, isNull, reason: '$bad');
        expect(pulled.files, hasLength(1), reason: '$bad');
      }
    });
  });

  test('omits empty version and lang', () async {
    late http.Request captured;
    final client = clientReturning((req) {
      captured = req;
      return http.Response(jsonEncode({'files': <String, String>{}}), 200);
    });

    await client.fetchTranslations(projectId: 'p', format: 'arb', version: '');

    expect(captured.url.queryParameters.containsKey('version'), isFalse);
    expect(captured.url.queryParameters.containsKey('lang'), isFalse);
  });

  test('rejects a declared-oversize response body', () async {
    // MockClient.streaming lets the response lie about its size; the cap must
    // reject on the declared Content-Length before buffering it.
    final client = TranslationsApiClient(
      baseUrl: 'https://api.easyi18n.com',
      token: 'eik_secret',
      httpClient: MockClient.streaming((req, body) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{}')),
          200,
          contentLength: 128 * 1024 * 1024,
        );
      }),
    );

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(isA<CliException>()),
    );
  });

  test('surfaces the backend error message on 404', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'not_published',
          'message': 'no published version',
        }),
        404,
      ),
    );

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('no published version'),
        ),
      ),
    );
  });

  test('gives an auth hint on 401', () async {
    final client = clientReturning(
      (req) => http.Response(jsonEncode({'error': 'unauthorized'}), 401),
    );

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('EASYI18N_TOKEN'),
        ),
      ),
    );
  });

  test('gives a credits hint on a 402 out-of-credits push', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'insufficient_credits',
          'message': 'Not enough credits.',
        }),
        402,
      ),
    );

    expect(
      () => client.translate(
        projectId: 'p',
        units: [TranslateUnit(source: 'Hi')],
      ),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('Top up'),
        ),
      ),
    );
  });

  // #653 — the server now says the cap refused the run; a "top up" hint next to
  // that tells the operator to do the one thing that cannot clear a cap.
  test('a 402 spend_cap_exceeded points at the cap, never at topping up',
      () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'spend_cap_exceeded',
          'message': 'estimated 541 credits exceeds the 100 left this month '
              'under the spending cap of 100000',
          'capRemaining': 100,
          'spendingCap': 100000,
        }),
        402,
      ),
    );

    expect(
      () => client.translate(
        projectId: 'p',
        units: [TranslateUnit(source: 'Hi')],
      ),
      throwsA(
        isA<CliException>()
            .having((e) => e.message, 'server message',
                contains('100 left this month'))
            .having((e) => e.message, 'points at the cap',
                contains('monthly spending cap refused'))
            .having((e) => e.message, 'no top-up hint',
                isNot(contains('Top up'))),
      ),
    );
  });

  // Same pair on the SYNC route: a contract belongs to its route (#556), and
  // `easyi18n sync` is the command CI actually runs — the hint has to hold
  // where the operator meets it, not only on the sibling that shares the
  // helper today.
  test('sync: a 402 spend_cap_exceeded points at the cap, never at topping up',
      () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'spend_cap_exceeded',
          'message': 'estimated 541 credits exceeds the 100 left this month '
              'under the spending cap of 100000 (99900 credits are reserved '
              'by runs in flight)',
          'capRemaining': 100,
          'spendingCap': 100000,
          'capReserved': 99900,
        }),
        402,
      ),
    );

    expect(
      () => client.sync(
        projectId: 'p',
        fileName: 'app.xcstrings',
        bytes: [1, 2, 3],
      ),
      throwsA(
        isA<CliException>()
            .having((e) => e.message, 'server message, reserved clause too',
                contains('99900 credits are reserved'))
            .having((e) => e.message, 'points at the cap',
                contains('monthly spending cap refused'))
            .having((e) => e.message, 'no top-up hint',
                isNot(contains('Top up'))),
      ),
    );
  });

  test('sync: a 402 out-of-credits still hints at topping up', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'insufficient_credits',
          'message': 'estimated 541 credits exceeds the available balance '
              'of 1',
          'availableCredits': 1,
        }),
        402,
      ),
    );

    expect(
      () => client.sync(
        projectId: 'p',
        fileName: 'app.xcstrings',
        bytes: [1, 2, 3],
      ),
      throwsA(
        isA<CliException>().having(
            (e) => e.message, 'message', contains('Top up')),
      ),
    );
  });

  test('omits the credits hint on a 402 plan_limit push', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'error': 'plan_limit',
          'message': 'This plan allows up to 1000 keys. Upgrade for more.',
        }),
        402,
      ),
    );

    expect(
      () => client.translate(
        projectId: 'p',
        units: [TranslateUnit(source: 'Hi')],
      ),
      throwsA(
        isA<CliException>()
            .having((e) => e.message, 'message', contains('Upgrade for more'))
            .having(
              (e) => e.message,
              'no credits hint',
              isNot(contains('Top up')),
            ),
      ),
    );
  });

  test('parses skippedGated/skippedDisabled + their per-unit flags', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'trackingToken': 'job_1',
          'estimatedCredits': 5,
          'balance': 100,
          'skippedGated': 2,
          'skippedDisabled': 1,
          'units': [
            {
              'key': 'k1',
              'outcome': 'matched',
              'pending': ['fr'],
              'translated': <String>[],
            },
            {
              'key': 'k2',
              'outcome': 'created',
              'gated': true,
              'pending': <String>[],
              'translated': <String>[],
            },
            {
              'key': 'k3',
              'outcome': 'matched',
              'disabled': true,
              'pending': <String>[],
              'translated': <String>[],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final result = await client.translate(
      projectId: 'p',
      units: [
        TranslateUnit(source: 'Hi'),
        TranslateUnit(source: 'Bye'),
        TranslateUnit(source: 'Off'),
      ],
    );

    expect(result.skippedGated, 2);
    expect(result.skippedDisabled, 1);
    expect(result.units[0].gated, isFalse);
    expect(result.units[1].gated, isTrue);
    // Distinct axes: a gated unit is not disabled and vice versa.
    expect(result.units[1].disabled, isFalse);
    expect(result.units[2].disabled, isTrue);
    expect(result.units[2].gated, isFalse);
  });

  test('defaults skippedGated to 0 and gated to false when absent', () async {
    final client = clientReturning(
      (req) => http.Response(
        jsonEncode({
          'trackingToken': 'job_1',
          'estimatedCredits': 5,
          'balance': 100,
          'units': [
            {
              'key': 'k1',
              'outcome': 'matched',
              'pending': <String>[],
              'translated': ['fr'],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    final result = await client.translate(
      projectId: 'p',
      units: [TranslateUnit(source: 'Hi')],
    );

    expect(result.skippedGated, 0);
    // A backend that predates the field must not read as "everything skipped".
    expect(result.skippedDisabled, 0);
    expect(result.units.single.gated, isFalse);
    expect(result.units.single.disabled, isFalse);
  });

  test('handles a non-JSON error body', () async {
    final client = clientReturning((req) => http.Response('Bad Gateway', 502));

    expect(
      () => client.fetchTranslations(projectId: 'p', format: 'arb'),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('502'),
        ),
      ),
    );
  });

  group('getRequest (#1823)', () {
    test('reads the request record by id, encoded, with the state', () async {
      late http.Request captured;
      final client = clientReturning((req) {
        captured = req;
        return http.Response(jsonEncode({
          'requestId': 'r 1', 'state': 'processing',
          'leaseUntil': '2026-09-22T16:00:00Z',
        }), 200);
      });
      final view = await client.getRequest(projectId: 'p', requestId: 'r 1');
      expect(captured.method, 'GET');
      expect(captured.url.path, '/v1/projects/p/requests/r%201');
      expect(captured.headers['authorization'], 'Bearer eik_secret');
      expect(view['state'], 'processing');
      expect(view['leaseUntil'], '2026-09-22T16:00:00Z');
    });

    test('a body without a state, or with an empty one, is a shape failure, '
        'never a guess', () async {
      for (final body in [
        {'requestId': 'r_1'},
        {'requestId': 'r_1', 'state': ''},
      ]) {
        final client =
            clientReturning((_) => http.Response(jsonEncode(body), 200));
        await expectLater(
          client.getRequest(projectId: 'p', requestId: 'r_1'),
          throwsA(isA<CliException>()
              .having((e) => e.message, 'message', contains("'state'"))),
          reason: '$body',
        );
      }
    });

    test('a non-200 is the API error with its status', () async {
      final client = clientReturning((_) => http.Response(
          jsonEncode({'error': 'invalid_argument', 'message': 'bad id'}), 400));
      await expectLater(
        client.getRequest(projectId: 'p', requestId: 'r_1'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 400)
            .having((e) => e.code, 'code', 'invalid_argument')),
      );
    });
  });

  group('resolveProjectRef', () {
    test('GETs /projects/resolve with the ref params and bearer', () async {
      late http.Request captured;
      final client = clientReturning((req) {
        captured = req;
        return http.Response(
          jsonEncode({'projectId': 'proj_abc', 'workspaceId': 'ws_1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ref = await client.resolveProjectRef(
        workspace: 'acme',
        project: 'dogfood',
      );

      expect(captured.headers['authorization'], 'Bearer eik_secret');
      expect(captured.url.path, '/v1/projects/resolve');
      expect(captured.url.queryParameters['workspace'], 'acme');
      expect(captured.url.queryParameters['project'], 'dogfood');
      expect(ref.projectId, 'proj_abc');
      expect(ref.workspaceId, 'ws_1');
    });

    test('surfaces a 404 as an actionable CliException', () async {
      final client = clientReturning(
        (req) => http.Response(
          jsonEncode({'error': 'not_found', 'message': 'project not found'}),
          404,
        ),
      );

      expect(
        () => client.resolveProjectRef(workspace: 'acme', project: 'ghost'),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains('easyi18n.yaml'),
          ),
        ),
      );
    });
  });

  group('fetchMeta', () {
    test('parses the enabled output formats', () async {
      final client = clientReturning(
        (req) => http.Response(
          jsonEncode({
            'baseCode': 'es',
            'currentVersionId': '2026.08.11.1',
            'languages': [
              {'code': 'es', 'isBase': true},
              {'code': 'en', 'isBase': false},
            ],
            'formats': ['xcstrings', 'json'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final meta = await client.fetchMeta(projectId: 'p1');

      expect(meta.formats, ['xcstrings', 'json']);
      expect(meta.targets.map((l) => l.code), ['en']);
    });

    test('an absent or malformed formats list reads as none enabled',
        () async {
      final client = clientReturning(
        (req) => http.Response(
          jsonEncode({
            'baseCode': 'es',
            'formats': [42, '', null],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      // Not "unknown": /meta has always carried this field, so nothing here
      // may be read as a format the project has.
      expect((await client.fetchMeta(projectId: 'p1')).formats, isEmpty);
    });
  });

  group('transient failures (#591)', () {
    Map<String, Object?> summaryBody() => {
          'status': 'running',
          'summary': {'total': 1, 'translated': 0, 'pending': 1, 'failed': 0},
        };

    test('a GET replays a 500 and converges', () async {
      var calls = 0;
      final client = clientReturning((req) {
        calls++;
        // A transient that outlives the backend's own read retries surfaces as
        // a 500, and the request it kills is the poll — after the spend.
        if (calls < 3) return http.Response('{"error":"internal"}', 500);
        return http.Response(jsonEncode(summaryBody()), 200,
            headers: {'content-type': 'application/json'});
      });

      final summary = await client.fetchJobSummary(
          projectId: 'p1', trackingToken: 't1');
      expect(summary.pending, 1);
      expect(calls, 3);
      expect(waits, hasLength(2));
      expect(waits.every((d) => d > Duration.zero), isTrue,
          reason: 'equal jitter never returns a zero-length wait');
      expect(waits[1], greaterThan(waits[0]),
          reason: 'the window doubles, and its lower half is deterministic');
    });

    test('a GET that keeps failing gives up as a typed error', () async {
      var calls = 0;
      final client = clientReturning((req) {
        calls++;
        return http.Response('{"error":"internal"}', 500);
      });

      await expectLater(
        client.fetchJobSummary(projectId: 'p1', trackingToken: 't1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 500)),
      );
      expect(calls, kMaxApiAttempts);
    });

    test('a real sync does NOT replay 503 unavailable: it may still hold '
        'credits', () async {
      var calls = 0;
      final client = clientReturning((req) {
        calls++;
        return http.Response(
            jsonEncode({'error': 'unavailable', 'message': 'busy'}), 503,
            headers: {'content-type': 'application/json'});
      });

      await expectLater(
        client.sync(
            projectId: 'p1', fileName: 'L.xcstrings', bytes: const [1, 2]),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 503)),
      );
      // The route releases its credit hold on the way out, and that release is
      // itself a write against the database that is throttling — so the hold
      // can survive the failure. A replay would then hit `402
      // insufficient_credits` on a workspace that has the credits, and leak
      // one more hold per attempt.
      expect(calls, 1);
      expect(waits, isEmpty);
    });

    test('a real sync DOES replay 503 contended: that one proves no hold',
        () async {
      var calls = 0;
      final client = clientReturning((req) {
        calls++;
        if (calls == 1) {
          return http.Response(
              jsonEncode({'error': 'contended', 'message': 'workspace busy'}),
              503,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(jsonEncode({'created': 1, 'accepted': true}), 200,
            headers: {'content-type': 'application/json'});
      });

      // `contended` comes from a lost CAS on the credits document, which
      // returns WITHOUT writing — so unlike `unavailable`, no reservation can
      // have survived the failure.
      final res = await client.sync(
          projectId: 'p1', fileName: 'L.xcstrings', bytes: const [1, 2]);
      expect(res.created, 1);
      expect(calls, 2);
      expect(waits, hasLength(1));
    });

    test('a one-language file names its lang in the body, and only then',
        () async {
      final bodies = <Map<String, Object?>>[];
      final client = clientReturning((req) {
        bodies.add((jsonDecode(req.body) as Map).cast<String, Object?>());
        return http.Response(jsonEncode({'accepted': true}), 200,
            headers: {'content-type': 'application/json'});
      });
      await client.sync(projectId: 'p1', fileName: 'values-es/strings.xml',
          bytes: const [1], lang: 'es');
      await client.sync(projectId: 'p1', fileName: 'strings.xml',
          bytes: const [1]);
      expect(bodies.first['lang'], 'es');
      expect(bodies.last.containsKey('lang'), isFalse);
    });

    test('the dry run replays any 503: it returns before writing anything',
        () async {
      var calls = 0;
      final client = clientReturning((req) {
        calls++;
        if (calls < 3) {
          return http.Response(jsonEncode({'error': 'unavailable'}), 503,
              headers: {'content-type': 'application/json'});
        }
        return http.Response(
            jsonEncode({'dryRun': true, 'created': 2, 'accepted': true}), 200,
            headers: {'content-type': 'application/json'});
      });

      // The preview is the FIRST call the command makes and the route returns
      // before the apply and before the hold — so a throttle there used to
      // kill the whole run before a single write had been attempted.
      final res = await client.sync(
          projectId: 'p1',
          fileName: 'L.xcstrings',
          bytes: const [1, 2],
          dryRun: true);
      expect(res.created, 2);
      expect(calls, 3);
    });

    test('sync does NOT replay a POST it got no answer to', () async {
      var calls = 0;
      final client = TranslationsApiClient(
        baseUrl: 'https://api.easyi18n.com',
        token: 'eik_secret',
        httpClient: MockClient((req) async {
          calls++;
          throw http.ClientException('Connection closed before full header');
        }),
        wait: (d) async => waits.add(d),
        random: Random(7),
      );

      await expectLater(
        client.sync(projectId: 'p1', fileName: 'L.xcstrings', bytes: const [1]),
        throwsA(isA<CliException>()),
      );
      // The whole point: without an answer, "it failed" and "Cloud Run is
      // still applying it" are the same observation, and re-posting fabricates
      // the double-spend window of #564/#567.
      expect(calls, 1);
      expect(waits, isEmpty);
    });

    test('publish is not replayed on 503, idempotent flag or not', () async {
      var calls = 0;
      http.Response handler(http.Request req) {
        calls++;
        return http.Response(jsonEncode({'error': 'unavailable'}), 503,
            headers: {'content-type': 'application/json'});
      }

      // `skipIfIdentical` makes a publish idempotent against an UNCHANGED
      // project, and sync publishes while other fills are in flight — so the
      // live state can move between attempts, the digest differs, and the
      // retry mints a SECOND version (another slot of the daily cap, another
      // round of webhooks).
      await expectLater(
        clientReturning(handler).publish(projectId: 'p1', skipIfIdentical: true),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'unavailable')),
      );
      expect(calls, 1);
      expect(waits, isEmpty);
    });
  });

  group('a 5xx leaves the person an id to quote (#1235)', () {
    const id = '3fa94c1e0b7d2a68';

    Future<String> pushFailure(http.Response response) async {
      final client = clientReturning((req) => response);
      try {
        await client.translate(
          projectId: 'p',
          units: [TranslateUnit(source: 'Hi')],
        );
      } on CliException catch (e) {
        return e.message;
      }
      fail('the push did not fail');
    }

    test('a 500 says the server failed and cites the body id', () async {
      final message = await pushFailure(
        http.Response(
          jsonEncode({
            'error': 'internal',
            'message': 'internal error',
            'correlationId': id,
          }),
          500,
        ),
      );
      expect(message, startsWith('Push failed: internal error\n'));
      expect(message, contains('server'));
      expect(message, endsWith('quote this id: $id'));
    });

    test('falls back to the x-correlation-id header', () async {
      final message = await pushFailure(
        http.Response('Internal Server Error', 500,
            headers: {'x-correlation-id': id}),
      );
      expect(message, endsWith('quote this id: $id'));
    });

    test('the body id wins over the header', () async {
      final message = await pushFailure(
        http.Response(jsonEncode({'correlationId': id}), 500,
            headers: {'x-correlation-id': 'ffffffffffffffff'}),
      );
      expect(message, endsWith('quote this id: $id'));
    });

    test('a 500 with no id still gets the server hint, and no id line',
        () async {
      final message = await pushFailure(
        http.Response(jsonEncode({'message': 'internal error'}), 500),
      );
      expect(message, contains('server'));
      expect(message, isNot(contains('quote this id')));
    });

    test('a 503 keeps its busy hint and cites the id', () async {
      final message = await pushFailure(
        http.Response(
          jsonEncode({'error': 'unavailable', 'correlationId': id}),
          503,
        ),
      );
      expect(message, contains('The service was busy'));
      expect(message, endsWith('quote this id: $id'));
    });

    test('a 4xx quotes no id', () async {
      final message = await pushFailure(
        http.Response(
          jsonEncode({'message': 'nope', 'correlationId': id}),
          403,
          headers: {'x-correlation-id': id},
        ),
      );
      expect(message, isNot(contains(id)));
    });

    test('an id that is not a short token is not rendered', () async {
      for (final bad in ['two words', 'a' * 65, '', '\x1b[31mred']) {
        final message = await pushFailure(
          http.Response(jsonEncode({'correlationId': bad}), 500),
        );
        expect(message, isNot(contains('quote this id')), reason: bad);
      }
    });
  });

  group('a 403 names what is missing (#1835)', () {
    Future<String> pushFailure(http.Response response) async {
      try {
        await clientReturning((req) => response).translate(
          projectId: 'p',
          units: [TranslateUnit(source: 'Hi')],
        );
      } on CliException catch (e) {
        return e.message;
      }
      fail('the push did not fail');
    }

    // The token has the scope; what is missing is an approved operation, and
    // the scope line sent agents to the key settings instead (#1835).
    test('a 403 authorization_required carries no scope hint, a forbidden '
        'one does', () async {
      final authorization = await pushFailure(
        http.Response(
          jsonEncode({
            'error': 'authorization_required',
            'message': 'an Agent key needs an approved translate operation',
          }),
          403,
        ),
      );
      expect(authorization, isNot(contains('lacks the required scope')));
      final forbidden = await pushFailure(
        http.Response(
          jsonEncode({
            'error': 'forbidden',
            'message': 'credential lacks translate scope',
          }),
          403,
        ),
      );
      expect(forbidden, contains('lacks the required scope for this project'));
    });
  });

  group('a well-formed body of the wrong shape (#972)', () {
    TranslationsApiClient serving(Object? body, {int status = 200}) =>
        clientReturning((_) => http.Response(jsonEncode(body), status));

    Future<TranslateResult> translateFrom(Object? body) => serving(body)
        .translate(projectId: 'p', units: [TranslateUnit(source: 'Hi')]);

    Future<SyncResult> syncFrom(Object? body) => serving(body)
        .sync(projectId: 'p', fileName: 'app_en.arb', bytes: const [1]);

    test(
      'a 200 whose body is a JSON array fails as a CliException, not an '
      'uncaught TypeError',
      () async {
        final client = clientReturning((_) => http.Response('[]', 200));
        await expectLater(
          client.fetchTranslations(projectId: 'p', format: 'arb'),
          throwsA(isA<CliException>()),
        );
      },
    );

    // The eight success-body decodes. Each one used to run `as
    // Map<String, dynamic>` straight off `jsonDecode`, so a body that was
    // valid JSON of another shape left the process with exit 255 and a stack
    // trace instead of a sentence.
    test('every entry point refuses a non-object envelope', () async {
      final client = serving(<String>[]);
      final publishing = serving(<String>[], status: 201);
      await expectLater(
        client.fetchTranslations(projectId: 'p', format: 'arb'),
        throwsA(isA<FatalCliException>()),
      );
      await expectLater(
        serving(42).fetchMeta(projectId: 'p'),
        throwsA(isA<FatalCliException>()),
      );
      await expectLater(
        client.fetchPendingCodeChanges(projectId: 'p'),
        throwsA(isA<FatalCliException>()),
      );
      await expectLater(
        serving(null).resolveProjectRef(workspace: 'w', project: 'p'),
        throwsA(isA<FatalCliException>()),
      );
      await expectLater(
        translateFrom(<String>[]),
        throwsA(isA<FatalCliException>()),
      );
      await expectLater(
        publishing.publish(projectId: 'p'),
        throwsA(isA<FatalCliException>()),
      );
      await expectLater(syncFrom('ok'), throwsA(isA<FatalCliException>()));
      await expectLater(
        serving(42).fetchJobSummary(projectId: 'p', trackingToken: 't'),
        throwsA(isA<FatalCliException>()),
      );
    });

    test('the headline case: a file whose content is not a string', () async {
      // The repro as the issue writes it. `Map.map` is eager, so this one blew
      // up inside the client rather than in the consumer — with a message that
      // named neither the field nor the endpoint.
      await expectLater(
        serving({
          'files': {'arb/app_en.arb': 1},
        }).fetchTranslations(projectId: 'p', format: 'arb'),
        throwsA(
          isA<FatalCliException>().having(
            (e) => e.message,
            'message',
            allOf(contains("'files'"), contains('api.easyi18n.com')),
          ),
        ),
      );
    });

    test('a field of the wrong type names the field, per reader', () async {
      // One representative per reader, top level...
      await expectLater(
        serving({'version': 7}).fetchTranslations(projectId: 'p', format: 'a'),
        throwsA(
          isA<FatalCliException>()
              .having((e) => e.message, 'message', contains("'version'")),
        ),
      );
      await expectLater(
        translateFrom({'estimatedCredits': '12'}),
        throwsA(
          isA<FatalCliException>().having(
            (e) => e.message,
            'message',
            contains("'estimatedCredits'"),
          ),
        ),
      );
      await expectLater(
        translateFrom({'accepted': 'yes'}),
        throwsA(
          isA<FatalCliException>()
              .having((e) => e.message, 'message', contains("'accepted'")),
        ),
      );
      await expectLater(
        serving({'languages': 5}).fetchMeta(projectId: 'p'),
        throwsA(
          isA<FatalCliException>()
              .having((e) => e.message, 'message', contains("'languages'")),
        ),
      );
      await expectLater(
        serving({
          'summary': 3,
        }).fetchJobSummary(projectId: 'p', trackingToken: 't'),
        throwsA(
          isA<FatalCliException>()
              .having((e) => e.message, 'message', contains("'summary'")),
        ),
      );
      // ...and nested, which is the half the envelope guard alone cannot see:
      // inside an element the `is Map` filter already admitted, and inside the
      // `summary` object.
      await expectLater(
        serving({
          'languages': [
            {'code': 'es', 'name': 7},
          ],
        }).fetchMeta(projectId: 'p'),
        throwsA(
          isA<FatalCliException>()
              .having((e) => e.message, 'message', contains("'name'")),
        ),
      );
      await expectLater(
        serving({
          'summary': {'total': 'x'},
        }).fetchJobSummary(projectId: 'p', trackingToken: 't'),
        throwsA(
          isA<FatalCliException>()
              .having((e) => e.message, 'message', contains("'total'")),
        ),
      );
    });

    test('a body that is not JSON at all still retries, as before', () async {
      // Unchanged on purpose: HTML from a proxy or a captive portal is a
      // transient signal, and `pull --watch` must keep watching through it.
      // Only the WRONG-SHAPE branch is fatal.
      await expectLater(
        clientReturning(
          (_) => http.Response('<html>502</html>', 200),
        ).fetchTranslations(projectId: 'p', format: 'arb'),
        throwsA(
          allOf(isA<CliException>(), isNot(isA<FatalCliException>())),
        ),
      );
    });

    group('a list nobody iterates stays tolerant', () {
      // Measured on develop: these three responses complete the run today —
      // `pull` writes its files and exits 0, `push` reports its token. A
      // strict reader here would refuse a response that works, which in a
      // published CLI is a new refusal, not a fix.
      test('a pull whose `formats` holds a non-string still succeeds',
          () async {
        final r = await serving({
          'version': 'v1',
          'formats': ['arb', 1],
          'files': {'arb/app_en.arb': '{"hi":"Hi"}'},
        }).fetchTranslations(projectId: 'p', format: 'arb');
        expect(r.files, hasLength(1));
        expect(r.version, 'v1');
        expect(r.formats, ['arb']);
      });

      test('a push whose `pending` holds a non-string still succeeds',
          () async {
        // `pending` is only ever read through `needsTranslation`
        // (`isNotEmpty`), which a lazy cast never forced — so this response
        // returns a token today and has to keep returning one.
        final r = await translateFrom({
          'trackingToken': 'tk',
          'units': [
            {'outcome': 'created', 'key': 'k', 'pending': ['fr', 1]},
          ],
        });
        expect(r.trackingToken, 'tk');
        expect(r.unitsNeedingTranslation, 1);
        expect(r.units.single.pending, ['fr']);
      });

      test('a push whose `translated` holds a non-string still succeeds',
          () async {
        // `translated` has no consumer at all in this package.
        final r = await translateFrom({
          'trackingToken': 'tk',
          'units': [
            {'outcome': 'created', 'translated': ['fr', 1]},
          ],
        });
        expect(r.trackingToken, 'tk');
        expect(r.units.single.translated, ['fr']);
      });

      test('a `pending` of only non-strings stops counting as needing a fill',
          () async {
        // The one observable delta of the tolerant reader, and it is a count
        // printed over garbage, not an acceptance decision: today the lazy
        // cast reports length 1 without casting anything, so the unit reads as
        // needing translation.
        final r = await translateFrom({
          'units': [
            {'outcome': 'created', 'pending': [1]},
          ],
        });
        expect(r.unitsNeedingTranslation, 0);
        expect(r.units.single.pending, isEmpty);
      });
    });

    test('`budgetExhausted` is decoded per unit, strict like `exhausted`',
        () async {
      final r = await translateFrom({
        'units': [
          {'outcome': 'matched', 'key': 'k', 'pending': ['fr'],
            'budgetExhausted': ['fr']},
        ],
      });
      expect(r.units.single.budgetExhausted, ['fr']);
      await expectLater(
        translateFrom({
          'units': [
            {'outcome': 'matched', 'budgetExhausted': ['fr', 1]},
          ],
        }),
        throwsA(isA<CliException>().having(
            (e) => e.message, 'message', contains("'budgetExhausted'"))),
      );
    });

    test('a `exhausted` holding a non-string is refused, not silently dropped',
        () async {
      // The opposite call, and the reason the split is per-field: `push_command`
      // iterates `exhausted` on every batch, so this response ALREADY dies
      // today — three frames further up, with no field name. Dropping the
      // element instead would under-report pairs the fill will never retry,
      // which is the bug #752 exists to prevent.
      await expectLater(
        translateFrom({
          'units': [
            {'outcome': 'created', 'exhausted': ['fr', 1]},
          ],
        }),
        throwsA(
          isA<CliException>()
              .having((e) => e.message, 'message', contains("'exhausted'")),
        ),
      );
    });

    group('nothing that parses today stops parsing', () {
      test('the `is` filters still drop a bad element', () async {
        final r = await syncFrom({
          'targetLangs': ['es', 1],
          'fillableLangs': ['es', 1],
          'conflicts': [
            {'key': 'k'},
            'not a row',
          ],
        });
        expect(r.targetLangs, ['es']);
        expect(r.fillableLangs, ['es']);
        expect(r.conflicts, hasLength(1));
      });

      test('the `== true` comparisons still tolerate a non-boolean', () async {
        final r = await syncFrom({'dryRun': 'yes', 'accepted': 1});
        expect(r.dryRun, isFalse);
        expect(r.accepted, isFalse);
        final meta = await serving({
          'languages': [
            {'code': 'es', 'isBase': 'yes'},
          ],
        }).fetchMeta(projectId: 'p');
        expect(meta.languages.single.isBase, isFalse);
      });

      test('an absent field still falls back to its default', () async {
        final r = await syncFrom(<String, Object?>{});
        expect(r.created, 0);
        expect(r.onConflict, 'server');
        expect(r.trackingToken, isNull);
        expect(r.targetLangs, isEmpty);
        final pulled = await serving(
          <String, Object?>{},
        ).fetchTranslations(projectId: 'proj_abc', format: 'arb');
        expect(pulled.project, 'proj_abc');
        expect(pulled.files, isEmpty);
      });

      test('an explicitly null field still falls back to its default',
          () async {
        // The direction that decides "no new refusals": a reader that stopped
        // accepting null would turn every server that spells an empty field
        // this way into a failing run.
        final r = await syncFrom({
          'created': null,
          'onConflict': null,
          'trackingToken': null,
          'targetLangs': null,
          'conflicts': null,
          'dryRun': null,
        });
        expect(r.created, 0);
        expect(r.onConflict, 'server');
        expect(r.trackingToken, isNull);
        expect(r.targetLangs, isEmpty);
        expect(r.conflicts, isEmpty);
        final summary = await serving({
          'status': null,
          'summary': null,
        }).fetchJobSummary(projectId: 'p', trackingToken: 't');
        expect(summary.status, 'unknown');
        expect(summary.total, 0);
      });
    });

    group('a failure after the server already acted says what to do', () {
      test('push names the remedy without claiming the run was charged',
          () async {
        // Modal, because it has to be: a run with nothing to do is charged 0
        // and answers the same 200, so from an unreadable body the CLI cannot
        // know whether this one spent anything.
        await expectLater(
          translateFrom(<String>[]),
          throwsA(
            isA<CliException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('may have reserved credits'),
                contains('not paid for twice'),
                contains('easyi18n push'),
              ),
            ),
          ),
        );
      });

      test('sync names the remedy too', () async {
        await expectLater(
          syncFrom('ok'),
          throwsA(
            isA<CliException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('may have reserved credits'),
                contains('easyi18n sync'),
              ),
            ),
          ),
        );
      });

      // The note is false on a dry run and this is the likelier half of the
      // two: `sync` opens with a preview, and `push --watch` polls one in a
      // loop. `?dryRun=true` is answered before the hold and before the
      // enqueue (`public_sync_api` returns ahead of the apply loop off a
      // read-only precheck; `_translateDryRun` writes no key, marker or job),
      // so there is nothing to re-run into (#972).
      test('a dry run says nothing about credits, on either route', () async {
        final calls = <Future<Object?>>[
          serving(<String>[]).translate(
            projectId: 'p',
            units: [TranslateUnit(source: 'Hi')],
            dryRun: true,
          ),
          serving('ok').sync(
            projectId: 'p',
            fileName: 'app_en.arb',
            bytes: const [1],
            dryRun: true,
          ),
        ];
        for (final call in calls) {
          await expectLater(
            call,
            throwsA(
              isA<FatalCliException>().having(
                (e) => e.message,
                'message',
                allOf(
                  // Still diagnosed, and still fatal — only the remedy for a
                  // charge that never happened is gone.
                  contains('the body should be a JSON object'),
                  isNot(contains('reserved credits')),
                  isNot(contains('not paid for twice')),
                ),
              ),
            ),
          );
        }
      });

      test('publish warns the version may exist', () async {
        await expectLater(
          serving(<String>[], status: 201).publish(projectId: 'p'),
          throwsA(
            isA<CliException>().having(
              (e) => e.message,
              'message',
              contains('version may already exist'),
            ),
          ),
        );
      });

      test('a route that acted on nothing yet keeps its bare message',
          () async {
        // The read routes must NOT inherit the charged-run wording — there is
        // nothing to re-run and nothing was reserved.
        await expectLater(
          serving(42).fetchMeta(projectId: 'p'),
          throwsA(
            isA<CliException>().having(
              (e) => e.message,
              'message',
              isNot(contains('credits')),
            ),
          ),
        );
      });
    });
  });
}
