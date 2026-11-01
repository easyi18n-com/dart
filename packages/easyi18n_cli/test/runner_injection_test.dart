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
}
