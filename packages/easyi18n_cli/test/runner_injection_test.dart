import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:test/test.dart';

void main() {
  for (final command in ['status', 'pull', 'push', 'sync', 'apply', 'rollback', 'doctor']) {
    for (final flagToken in [false, true]) {
      test('$command uses injected factory and ${flagToken ? 'flag' : 'environment'} token', () async {
        final dir = Directory.systemTemp.createTempSync('runner_injection');
        addTearDown(() => dir.deleteSync(recursive: true));
        final config = File('${dir.path}/easyi18n.yaml')..writeAsStringSync(
          'projectId: proj_test\nmode: a\nbaseUrl: http://localhost:8080\n'
          'format: xcstrings\ncatalog: Localizable.xcstrings\n',
        );
        Directory('${dir.path}/lib').createSync();
        File('${dir.path}/lib/app.dart').writeAsStringSync("void f(c) { c.tr('Hello'); }");
        File('${dir.path}/Localizable.xcstrings').writeAsStringSync('{}');
        final reachedFactory = StateError('injected factory reached');
        var calls = 0;
        final runner = Easyi18nCommandRunner(
          logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
          environment: const {'EASYI18N_TOKEN': 'eik_injected'},
          apiClientFactory: ({required baseUrl, required token}) {
            calls++;
            expect(baseUrl, 'http://localhost:8080');
            expect(token == (flagToken ? 'eik_flag' : 'eik_injected'), isTrue);
            throw reachedFactory;
          },
        );
        await expectLater(
          HttpOverrides.runZoned(
            () => runner.run(['--config', config.path, command,
              if (flagToken) ...['--token', 'eik_flag']]),
            createHttpClient: (_) => throw StateError('real HTTP client forbidden'),
          ),
          throwsA(same(reachedFactory)),
        );
        expect(calls, 1);
      });
    }
  }

  // #2583: the login `easyi18n login` stores is the third credential, after
  // `--token` and `EASYI18N_TOKEN`, for the origin the call goes to.
  group('a stored login', () {
    const origin = 'http://localhost:8080';
    late Directory dir;
    late Directory home;
    late File config;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('runner_injection_login');
      home = Directory('${dir.path}/home')..createSync();
      config = File('${dir.path}/easyi18n.yaml')..writeAsStringSync(
        'projectId: proj_test\nmode: a\nbaseUrl: $origin\n'
        'format: xcstrings\ncatalog: Localizable.xcstrings\n',
      );
      Directory('${dir.path}/lib').createSync();
      File('${dir.path}/lib/app.dart').writeAsStringSync("void f(c) { c.tr('Hello'); }");
      File('${dir.path}/Localizable.xcstrings').writeAsStringSync('{}');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    void store(Map<String, Object?> logins) =>
        (File('${home.path}/.config/easyi18n/credentials.json')
              ..createSync(recursive: true))
            .writeAsStringSync(jsonEncode({'version': 1, 'logins': logins}));

    Map<String, Object?> login(String token) => {
          'token': token, 'email': 'dev@acme.test',
          'expires_at': '2100-01-01T00:00:00.000Z'};

    /// The token [args] hands the injected factory, or the error it ends on.
    Future<Object?> tokenOf(List<String> args, Map<String, String> environment) async {
      final reached = <String>[];
      final runner = Easyi18nCommandRunner(
        logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
        environment: {'HOME': home.path, ...environment},
        apiClientFactory: ({required baseUrl, required token}) {
          expect(baseUrl, origin);
          reached.add(token);
          throw StateError('injected factory reached');
        },
      );
      try {
        await HttpOverrides.runZoned(
          () => runner.run(['--config', config.path, ...args]),
          createHttpClient: (_) => throw StateError('real HTTP client forbidden'),
        );
      } on StateError {
        return reached.single;
      } on CliException catch (e) {
        return e;
      }
      return null;
    }

    const commands = [
      ['status'], ['pull'], ['push'], ['sync'], ['apply'], ['rollback'],
      ['doctor'], ['languages', 'add', 'es'], ['formats', 'add', 'json'],
    ];
    for (final args in commands) {
      final name = args.join(' ');
      test('$name sends the login stored for its origin, without EASYI18N_TOKEN', () async {
        store({origin: login('eip_stored'), 'https://api.easyi18n.com': login('eip_prod')});
        expect(await tokenOf(args, const {}), 'eip_stored');
      });

      test('$name: EASYI18N_TOKEN wins over the stored login', () async {
        store({origin: login('eip_stored')});
        expect(await tokenOf(args, const {'EASYI18N_TOKEN': 'eik_env'}), 'eik_env');
      });

      for (final unset in ['', '  ', 'eik_YOUR_AGENT_KEY']) {
        test('$name reads EASYI18N_TOKEN="$unset" as unset', () async {
          store({origin: login('eip_stored')});
          expect(await tokenOf(args, {'EASYI18N_TOKEN': unset}), 'eip_stored');
        });
      }
    }

    for (final args in commands.where((a) => a.first != 'doctor')) {
      test('${args.join(' ')} sends no login of another origin', () async {
        store({'http://localhost:9999': login('eip_other')});
        final error = await tokenOf(args, const {});
        expect(error, isA<CliException>().having((e) => e.message, 'message',
            allOf(contains('No credential for $origin'),
                contains('easyi18n login'))));
      });
    }
  });
}
