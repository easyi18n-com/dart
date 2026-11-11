@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/login_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/login_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/transcript.dart';

// #2583: `easyi18n login`, `logout` and `whoami` (ci-sync §6) against a double
// of the device flow, with the wait and the browser opener injected.
void main() {
  const origin = 'http://localhost:8080';
  const other = 'https://api.easyi18n.com';
  final raw = 'eip_${'k' * 40}';
  const expiresAt = '2026-12-03T21:44:13.324Z';
  const asked = {
    'device_code': 'dc_secret', 'user_code': 'BCDF-GHJK',
    'verification_uri': 'http://localhost:8090/device',
    'verification_uri_complete': 'http://localhost:8090/device?code=BCDF-GHJK',
    'interval': 5, 'expires_in': 900,
  };

  late Directory home;
  late Transcript transcript;
  late List<http.Request> requests;
  late List<http.Response> polls;
  late List<Duration> waits;
  late List<String> opened;
  late http.Response Function() device;
  late http.Response Function() logout;
  late http.Response Function() me;
  late http.Response Function() workspaces;
  late CliOutput output;

  setUp(() {
    home = Directory.systemTemp.createTempSync('login_command');
    transcript = Transcript();
    requests = [];
    waits = [];
    opened = [];
    device = () => http.Response(jsonEncode(asked), 200);
    logout = () => http.Response('', 204);
    me = () => http.Response(jsonEncode({'email': 'me@acme.test',
        'expires_at': '2100-01-01T00:00:00.000Z'}), 200);
    workspaces = () => http.Response(jsonEncode({'workspaces': [
      {'id': 'w_acme', 'workspace': 'acme', 'name': 'Acme', 'plan': 'pro',
        'role': 'owner', 'projects': [{'id': 'p_app', 'workspace_id': 'w_acme',
          'workspace': 'acme', 'slug': 'app', 'name': 'App', 'base_code': 'en',
          'role': 'editor'}]},
      {'id': 'personal_u1', 'name': 'Personal', 'plan': 'free', 'role': 'owner',
        'projects': [{'id': 'p_side', 'workspace_id': 'personal_u1', 'slug': 'side',
          'name': 'Side', 'base_code': 'fr', 'role': 'owner'}]},
    ]}), 200);
    polls = [];
  });
  tearDown(() => home.deleteSync(recursive: true));

  http.Response refused(int status, String code, [Map<String, String> headers = const {}]) =>
      http.Response(jsonEncode({'error': code, 'message': 'refused: $code'}), status,
          headers: headers);
  http.Response delivered() => http.Response(jsonEncode({'access_token': raw,
      'token_type': 'Bearer', 'expires_at': expiresAt, 'email': 'dev@acme.test'}), 200);

  File storeFile() => File(p.join(home.path, '.config', 'easyi18n', 'credentials.json'));
  LoginStore store() => LoginStore(storeFile());
  Map<String, String> env([Map<String, String> extra = const {}]) => {'HOME': home.path, ...extra};
  String config([String baseUrl = origin]) {
    final file = File(p.join(home.path, 'easyi18n.yaml'))
      ..writeAsStringSync('projectId: proj_abc\nbaseUrl: $baseUrl\n');
    return file.path;
  }

  Iterable<String> lines(String channel) =>
      transcript.records.where((r) => r.channel == channel).map((r) => r.line);
  String everything() => transcript.records.map((r) => r.line).join('\n');

  CommandRunner<int> runner({Map<String, String>? environment, bool json = false,
      bool opens = true}) {
    output = CliOutput(logger: CliLogger(out: transcript.out, err: transcript.err))
      ..json = json;
    final mock = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/v1/auth/device' => device(),
        '/v1/auth/device/token' => polls.length > 1 ? polls.removeAt(0) : polls.single,
        '/v1/auth/logout' => logout(),
        '/v1/me' => me(),
        '/v1/me/workspaces' => workspaces(),
        _ => throw StateError('unexpected ${request.url}'),
      };
    });
    TranslationsApiClient factory({required String baseUrl, required String token}) =>
        TranslationsApiClient(baseUrl: baseUrl, token: token, httpClient: mock,
            wait: (_) async {});
    final e = environment ?? env();
    return CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(LoginCommand(output: output, apiClientFactory: factory, environment: e,
          // A microtask wait starves the timers, so a poll loop that never
          // ends would hang the suite instead of failing it.
          wait: (d) async {
            waits.add(d);
            if (waits.length > 500) throw StateError('the poll loop does not end');
          },
          openBrowser: (url) async {
            opened.add(url);
            return opens;
          }))
      ..addCommand(LogoutCommand(output: output, apiClientFactory: factory, environment: e))
      ..addCommand(WhoamiCommand(output: output, apiClientFactory: factory, environment: e));
  }

  Future<int> run(List<String> args, {Map<String, String>? environment, bool json = false,
      bool opens = true}) async {
    try {
      return await runner(environment: environment, json: json, opens: opens).run(args) ?? 0;
    } on CliException catch (e) {
      // What Easyi18nCommandRunner does with a command's refusal.
      output.emitError(e);
      return e.exitCode;
    }
  }

  Iterable<String> paths() => requests.map((r) => r.url.path);

  group('login', () {
    test('opens the approval page, waits and keeps the login for its origin', () async {
      polls = [refused(428, 'authorization_pending'), refused(429, 'slow_down'), delivered()];
      final code = await run(['--config', config(), 'login']);
      expect(code, 0, reason: everything());
      expect(opened, ['http://localhost:8090/device?code=BCDF-GHJK']);
      expect(lines('err').first, 'Opening your browser. Confirm you see the code BCDF-GHJK');
      expect(waits, [5, 5, 10].map((s) => Duration(seconds: s)));
      final ask = requests.first;
      expect(jsonDecode(ask.body), {'client': 'cli', 'device_name': Platform.localHostname});
      expect(requests.where((r) => r.headers.containsKey('authorization')), isEmpty);
      expect(jsonDecode(requests.last.body), {'device_code': 'dc_secret'});
      final kept = store().read(origin)!;
      expect((kept.token, kept.email, kept.expiresAt),
          (raw, 'dev@acme.test', DateTime.parse(expiresAt)));
      expect(lines('out'), ['Logged in as dev@acme.test to $origin until $expiresAt.']);
      expect(everything(), isNot(anyOf(contains('eip_'), contains('REDACTED'),
          contains('dc_secret'))));
    });

    test('--no-browser prints the page and the code and opens nothing', () async {
      polls = [delivered()];
      expect(await run(['--config', config(), 'login', '--no-browser']), 0);
      expect(opened, isEmpty);
      expect(lines('err').first,
          'Open http://localhost:8090/device and enter the code BCDF-GHJK');
    });

    test('a browser that does not open prints the same and keeps waiting', () async {
      polls = [refused(428, 'authorization_pending'), delivered()];
      expect(await run(['--config', config(), 'login'], opens: false), 0);
      expect(opened, hasLength(1));
      expect(lines('err').take(2), [
        'Opening your browser. Confirm you see the code BCDF-GHJK',
        'Open http://localhost:8090/device and enter the code BCDF-GHJK',
      ]);
      expect(store().read(origin), isNotNull);
    });

    test('a page that is not http is never opened', () async {
      device = () => http.Response(jsonEncode({...asked,
          'verification_uri_complete': 'file:///etc/passwd'}), 200);
      polls = [delivered()];
      expect(await run(['--config', config(), 'login']), 0);
      expect(opened, isEmpty);
    });

    test('rate_limited waits its Retry-After, then the interval again', () async {
      polls = [refused(429, 'rate_limited', {'retry-after': '42'}),
          refused(428, 'authorization_pending'), delivered()];
      expect(await run(['--config', config(), 'login']), 0);
      expect(waits, [5, 42, 5].map((s) => Duration(seconds: s)));
    });

    for (final (status, server, says) in [
      (400, 'denied', 'denied in the browser'),
      (400, 'expired', "expired before it was approved. Run 'easyi18n login' again"),
      (409, 'login_limit_reached', 'Account > Security'),
    ]) {
      test('$server ends with exit 1 and nothing saved', () async {
        polls = [refused(status, server)];
        expect(await run(['--config', config(), 'login']), 1);
        expect(lines('err').last, contains(says));
        expect(storeFile().existsSync(), isFalse);

        transcript = Transcript();
        expect(await run(['--config', config(), 'login'], json: true), 1);
        expect(jsonDecode(lines('out').single)['error']['code'], server);
      });
    }

    test('a request the server keeps pending ends at expires_in', () async {
      device = () => http.Response(jsonEncode({...asked, 'expires_in': 10}), 200);
      polls = [refused(428, 'authorization_pending')];
      expect(await run(['--config', config(), 'login']), 1);
      expect(paths().where((p) => p.endsWith('/token')), hasLength(2));
      expect(lines('err').last, contains("Run 'easyi18n login' again"));
      expect(storeFile().existsSync(), isFalse);
    });

    test('a limit on asking names its Retry-After', () async {
      device = () => refused(429, 'rate_limited', {'retry-after': '30'});
      expect(await run(['--config', config(), 'login']), 1);
      expect(lines('err').last, contains('Try again in 30 seconds.'));
    });

    test('a second login revokes the one it replaces, after saving', () async {
      store().write(origin, StoredLogin(token: 'eip_old'));
      store().write(other, StoredLogin(token: 'eip_other'));
      String? keptWhenRevoked;
      logout = () {
        keptWhenRevoked = store().read(origin)?.token;
        return http.Response('', 204);
      };
      polls = [delivered()];
      expect(await run(['--config', config(), 'login']), 0);
      final revoke = requests.last;
      expect(revoke.url.path, '/v1/auth/logout');
      expect(revoke.headers['authorization'], 'Bearer eip_old');
      expect(keptWhenRevoked, raw);
      expect(store().read(other)!.token, 'eip_other');
      expect(everything(), isNot(contains('warning')));
    });

    test('a replaced login the server no longer knows goes without a warning', () async {
      store().write(origin, StoredLogin(token: 'eip_old'));
      logout = () => refused(401, 'login_revoked');
      polls = [delivered()];
      expect(await run(['--config', config(), 'login']), 0);
      expect(paths().last, '/v1/auth/logout');
      expect(everything(), isNot(contains('warning')));
    });

    for (final body in [<String, Object?>{}, {'access_token': ''}]) {
      test('a delivery without a token is refused and nothing is saved: $body', () async {
        polls = [http.Response(jsonEncode({'token_type': 'Bearer', ...body}), 200)];
        expect(await run(['--config', config(), 'login']), 1);
        expect(lines('err').last, contains("'access_token' should be a non-empty string"));
        expect(storeFile().existsSync(), isFalse);
      });
    }

    test('a replaced login the server cannot revoke keeps the new one', () async {
      store().write(origin, StoredLogin(token: 'eip_old'));
      logout = () => throw http.ClientException('down');
      polls = [delivered()];
      expect(await run(['--config', config(), 'login']), 0);
      expect(store().read(origin)!.token, raw);
      expect(lines('err').last, contains('Account > Security'));
    });

    test('a TLS failure revoking the replaced login keeps the new one', () async {
      store().write(origin, StoredLogin(token: 'eip_old'));
      logout = () => throw const HandshakeException('certificate refused');
      polls = [delivered()];
      await expectLater(run(['--config', config(), 'login']).then<Object>(
          (code) => code, onError: (Object e) => e), completion(0));
      expect(store().read(origin)!.token, raw);
      expect(lines('err').last, contains('Account > Security'));
    });

    test('an untrusted origin is refused before any call', () async {
      expect(await run(['--config', config('https://evil.example'), 'login']), 1);
      expect(requests, isEmpty);
      expect(lines('err').last, contains('Refusing to log in to https://evil.example'));
    });

    test('no home to keep the login in is refused before any call', () async {
      expect(await run(['--config', config(), 'login'], environment: const {}), 1);
      expect(requests, isEmpty);
      expect(lines('err').last, contains('set HOME or XDG_CONFIG_HOME'));
    });

    test('a store of a newer CLI is refused before any call', () async {
      (storeFile()..createSync(recursive: true)).writeAsStringSync('{"version": 2}');
      expect(await run(['--config', config(), 'login']), 1);
      expect(requests, isEmpty);
    });

    test('without easyi18n.yaml the origin is EASYI18N_BASE_URL', () async {
      polls = [delivered()];
      const at = 'http://127.0.0.1:9000';
      expect(await run(['--config', p.join(home.path, 'none.yaml'), 'login'],
          environment: env({'EASYI18N_BASE_URL': '$at/'})), 0);
      expect(requests.first.url.origin, at);
      expect(store().read(at)!.token, raw);
    });

    test('login --json golden', () async {
      polls = [delivered()];
      final code = await run(['--config', config(), 'login'], json: true);
      expectJsonGolden('login_json', code, transcript.records, check: (json) {
        expect(json, {'email': 'dev@acme.test', 'base_url': origin, 'expires_at': expiresAt});
      });
      expect(everything(), isNot(anyOf(contains('eip_'), contains('REDACTED'))));
    });
  });

  group('logout', () {
    setUp(() {
      store().write(origin, StoredLogin(token: 'eip_a'));
      store().write(other, StoredLogin(token: 'eip_other'));
    });

    test('revokes the login and forgets only its own origin', () async {
      expect(await run(['--config', config(), 'logout']), 0);
      expect(paths(), ['/v1/auth/logout']);
      expect(requests.single.headers['authorization'], 'Bearer eip_a');
      expect(store().read(origin), isNull);
      expect(store().read(other)!.token, 'eip_other');
      expect(lines('out'), ['Logged out of $origin.']);
    });

    for (final (name, answer, revoked, says) in [
      ('a login the server no longer knows', () => refused(401, 'login_expired'), false,
          'the server no longer knew this login'),
      ('a server it cannot reach', () => throw http.ClientException('down'), null,
          'could not reach the server'),
      ('a TLS handshake that fails', () => throw const HandshakeException('certificate refused'), null,
          'could not reach the server'),
      ('a server that fails', () => refused(503, 'unavailable'), null,
          'could not reach the server'),
    ]) {
      test('$name still loses the entry, and says so', () async {
        logout = answer;
        await expectLater(run(['--config', config(), 'logout']).then<Object>(
            (code) => code, onError: (Object e) => e), completion(0));
        expect(store().read(origin), isNull);
        expect(lines('out').single, contains(says));
        transcript = Transcript();
        store().write(origin, StoredLogin(token: 'eip_a'));
        expect(await run(['--config', config(), 'logout'], json: true), 0);
        expect(jsonDecode(lines('out').single),
            {'base_url': origin, 'removed': true, 'revoked': revoked});
      });
    }

    test('no login is exit 0 and no call', () async {
      store().remove(origin);
      expect(await run(['--config', config(), 'logout']), 0);
      expect(requests, isEmpty);
      expect(lines('out'), ['Not logged in to $origin.']);
      transcript = Transcript();
      expect(await run(['--config', config(), 'logout'], json: true), 0);
      expect(jsonDecode(lines('out').single),
          {'base_url': origin, 'removed': false, 'revoked': null});
    });

    test('a file it cannot read is named, never printed', () async {
      storeFile().writeAsStringSync('{"logins": "eip_secret"');
      expect(await run(['--config', config(), 'logout']), 0);
      expect(requests, isEmpty);
      expect(lines('out'), ['Not logged in to $origin (${storeFile().path} '
          'is not a login file this CLI can read).']);
      expect(everything(), isNot(contains('eip_secret')));
    });

    test('logout --json golden', () async {
      final code = await run(['--config', config(), 'logout'], json: true);
      expectJsonGolden('logout_json', code, transcript.records, check: (json) {
        expect(json, {'base_url': origin, 'removed': true, 'revoked': true});
      });
    });
  });

  group('whoami', () {
    final later = DateTime.utc(2100);

    test('a file it cannot read is named, never printed', () async {
      storeFile()
        ..createSync(recursive: true)
        ..writeAsStringSync('{"logins": "eip_secret"');
      expect(await run(['--config', config(), 'whoami']), 1);
      expect(lines('err').last, 'error: Not logged in to $origin (${storeFile().path} '
          "is not a login file this CLI can read). Run 'easyi18n login'.");
      expect(everything(), isNot(contains('eip_secret')));
    });

    test('the server confirms the login and names where it works', () async {
      store().write(origin, StoredLogin(token: raw, email: 'dev@acme.test', expiresAt: DateTime.utc(2099)));
      expect(await run(['--config', config(), 'whoami']), 0);
      expect(paths(), ['/v1/me', '/v1/me/workspaces']);
      expect(requests.map((r) => r.headers['authorization']).toSet(), {'Bearer $raw'});
      expect(lines('out'), [
        'Logged in to $origin as me@acme.test until 2100-01-01T00:00:00.000Z.',
        '@acme  Acme (owner, pro)',
        '  @acme/app  App (editor)',
        'personal_u1  Personal (owner, free)',
        '  p_side  Side (owner)',
      ]);
      expect(everything(), isNot(contains(raw)));
    });

    test('an account the server refuses is exit 1 with valid false', () async {
      store().write(origin, StoredLogin(token: raw, expiresAt: later));
      for (final code in ['account_deleted', 'account_disabled']) {
        transcript = Transcript();
        me = () => refused(403, code);
        expect(await run(['--config', config(), 'whoami'], json: true), 1, reason: code);
        final json = jsonDecode(lines('out').single);
        expect((json['valid'], json['logged_in'], json['error']['code']), (false, false, code));
      }
      // Any other refusal says nothing about the login itself.
      transcript = Transcript();
      me = () => refused(403, 'forbidden');
      expect(await run(['--config', config(), 'whoami'], json: true), 0);
      expect(jsonDecode(lines('out').single)['valid'], isNull);
    });

    test('a login the server refuses is exit 1 with valid false', () async {
      store().write(origin, StoredLogin(token: raw, email: 'dev@acme.test', expiresAt: later));
      me = () => refused(401, 'login_revoked');
      expect(await run(['--config', config(), 'whoami'], json: true), 1);
      final json = jsonDecode(lines('out').single);
      expect(json['valid'], false);
      expect(json['logged_in'], false);
      expect(json['workspaces'], isNull);
      expect(json['error']['code'], 'login_revoked');
      expect(json['error']['message'], 'Whoami failed: refused: login_revoked');
      expect(paths(), ['/v1/me']);
      expect(everything(), isNot(contains(raw)));
    });

    test('a server it cannot reach leaves the store record, valid null, exit 0',
        () async {
      store().write(origin, StoredLogin(token: raw, email: 'dev@acme.test', expiresAt: later));
      for (final (down, why) in <(http.Response Function(), String)>[
        (() => throw http.ClientException('Connection refused'),
            'Could not reach $origin: Connection refused'),
        (() => throw const TlsException('CERTIFICATE_VERIFY_FAILED'),
            'Could not reach $origin: TlsException: CERTIFICATE_VERIFY_FAILED'),
        // A backend that predates the route: its 404 carries no /v1 envelope.
        (() => http.Response('Route not found', 404),
            'the server does not answer GET /v1/me yet'),
      ]) {
        transcript = Transcript();
        me = down;
        expect(await run(['--config', config(), 'whoami'], json: true), 0);
        final json = jsonDecode(lines('out').single);
        expect(json['valid'], isNull);
        expect(json['logged_in'], true);
        expect(json['email'], 'dev@acme.test');
        expect(json['workspaces'], isNull);
        transcript = Transcript();
        expect(await run(['--config', config(), 'whoami']), 0);
        expect(lines('out').first,
            'Logged in to $origin as dev@acme.test until 2100-01-01T00:00:00.000Z.');
        expect(lines('err'), ['warning: could not confirm this login with $origin: $why']);
      }
    });

    test('a missing workspace route names the request that failed', () async {
      store().write(origin, StoredLogin(token: raw, expiresAt: later));
      workspaces = () => http.Response('Route not found', 404);
      expect(await run(['--config', config(), 'whoami']), 0);
      expect(lines('err'), ['warning: could not confirm this login with $origin: '
          'the server does not answer GET /v1/me/workspaces yet']);
    });

    test('an expired login is not sent', () async {
      store().write(origin, StoredLogin(token: raw, expiresAt: DateTime.utc(2000)));
      expect(await run(['--config', config(), 'whoami'], json: true), 1);
      expect(requests, isEmpty);
      expect(jsonDecode(lines('out').single)['valid'], false);
    });

    test('says when EASYI18N_TOKEN wins, and a blank or placeholder one does not', () async {
      store().write(origin, StoredLogin(token: 'eip_a', expiresAt: later));
      for (final (value, wins) in [('eik_ci', true), (' ', false), ('eik_YOUR_AGENT_KEY', false)]) {
        transcript = Transcript();
        expect(await run(['--config', config(), 'whoami'], json: true,
            environment: env({'EASYI18N_TOKEN': value})), 0);
        expect(jsonDecode(lines('out').single)['uses_env_token'], wins, reason: value);
      }
      transcript = Transcript();
      await run(['--config', config(), 'whoami'], environment: env({'EASYI18N_TOKEN': 'eik_ci'}));
      expect(lines('out').last, 'EASYI18N_TOKEN is set: commands send it, not the login.');
    });

    test('no login and an expired one are exit 1 with the remedy', () async {
      expect(await run(['--config', config(), 'whoami']), 1);
      expect(lines('err').last, "error: Not logged in to $origin. Run 'easyi18n login'.");
      store().write(origin, StoredLogin(token: 'eip_a', email: 'dev@acme.test',
          expiresAt: DateTime.utc(2000)));
      transcript = Transcript();
      expect(await run(['--config', config(), 'whoami'], json: true), 1);
      final json = jsonDecode(lines('out').single);
      expect(json['error']['code'], 'login_expired');
      expect(json['error']['message'], contains("Run 'easyi18n login'"));
      expect(json['logged_in'], false);
      expect(json['email'], 'dev@acme.test');
    });

    test('no home to keep a login in is an error, not a crash', () async {
      expect(await run(['--config', config(), 'whoami'], environment: const {}), 1);
      expect(lines('err').last, contains('set HOME or XDG_CONFIG_HOME'));
    });

    test('whoami --json golden', () async {
      store().write(origin, StoredLogin(token: 'eip_a', email: 'dev@acme.test', expiresAt: later));
      final code = await run(['--config', config(), 'whoami'], json: true);
      expectJsonGolden('whoami_json', code, transcript.records, check: (json) {
        expect(json, {'logged_in': true, 'email': 'me@acme.test', 'base_url': origin,
            'expires_at': '2100-01-01T00:00:00.000Z', 'uses_env_token': false,
            'valid': true, 'workspaces': jsonDecode(workspaces().body)['workspaces']});
      });
    });

    test('whoami --json golden without a login', () async {
      final code = await run(['--config', config(), 'whoami'], json: true);
      expectJsonGolden('whoami_json_error', code, transcript.records, check: (json) {
        expect(json['logged_in'], false);
        expect(json['error']['code'], 'not_logged_in');
      });
    });
  });
}
