import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/status_command.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_status');
    out = StringBuffer();
    logger = CliLogger(out: out, err: StringBuffer());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig() {
    final path = '${dir.path}/easyi18n.yaml';
    File(path).writeAsStringSync('projectId: proj_abc\n');
    return path;
  }

  CommandRunner<int> runnerWith({required String? remoteVersion}) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        expect(req.url.path, endsWith('/meta'));
        return http.Response(
          jsonEncode({'currentVersionId': remoteVersion, 'baseCode': 'en'}),
          200,
        );
      }),
    );
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      StatusCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ),
    );
    return runner;
  }

  void writeState(String configPath, String version) {
    CliState(
      version: version,
      pulledAt: DateTime.now().toUtc(),
    ).save(CliState.fileFor(configPath));
  }

  test('a catalog project is told where its pull landed', () async {
    final config = writeConfig();
    CliState(
      version: '2026.07.04.2',
      pulledAt: DateTime.now().toUtc(),
      format: 'xcstrings',
      catalog: 'EscapeCall/Localizable.xcstrings',
    ).save(CliState.fileFor(config));

    await runnerWith(
      remoteVersion: '2026.07.04.2',
    ).run(['--config', config, 'status']);

    expect(out.toString(), contains('EscapeCall/Localizable.xcstrings'));
  });

  test('a directory pull says nothing about a catalog', () async {
    final config = writeConfig();
    writeState(config, '2026.07.04.2');

    await runnerWith(
      remoteVersion: '2026.07.04.2',
    ).run(['--config', config, 'status']);

    expect(out.toString(), isNot(contains('catalog')));
  });

  test('up to date → exit 0', () async {
    final config = writeConfig();
    writeState(config, '2026.07.04.2');
    final code = await runnerWith(
      remoteVersion: '2026.07.04.2',
    ).run(['--config', config, 'status']);
    expect(code, 0);
    expect(out.toString(), contains('Up to date.'));
  });

  test('behind same day → exact publish count + exit 1', () async {
    final config = writeConfig();
    writeState(config, '2026.07.04.1');
    final code = await runnerWith(
      remoteVersion: '2026.07.04.3',
    ).run(['--config', config, 'status']);
    expect(code, 1);
    expect(out.toString(), contains('2 publishes behind'));
    expect(out.toString(), contains("run 'easyi18n pull'"));
  });

  test('behind across days → out of date, no count', () async {
    final config = writeConfig();
    writeState(config, '2026.07.03.5');
    final code = await runnerWith(
      remoteVersion: '2026.07.04.1',
    ).run(['--config', config, 'status']);
    expect(code, 1);
    expect(out.toString(), contains('Out of date'));
    expect(out.toString(), isNot(contains('behind')));
  });

  test('legacy local version equals its .1 form', () async {
    final config = writeConfig();
    writeState(config, '2026.07.04');
    final code = await runnerWith(
      remoteVersion: '2026.07.04.1',
    ).run(['--config', config, 'status']);
    expect(code, 0);
    expect(out.toString(), contains('Up to date.'));
  });

  test('never pulled → hint + exit 1', () async {
    final config = writeConfig();
    final code = await runnerWith(
      remoteVersion: '2026.07.04.1',
    ).run(['--config', config, 'status']);
    expect(code, 1);
    expect(out.toString(), contains('(never pulled)'));
  });

  test('unpublished remote (null version) → never-published hint, exit 1',
      () async {
    final config = writeConfig();
    // Local state present is the dangerous case: without the guard, the
    // string-compare fallback reads any local version as newer than '' and
    // prints "Up to date." against a blank remote.
    writeState(config, '2026.07.04.2');
    final code = await runnerWith(
      remoteVersion: null,
    ).run(['--config', config, 'status']);
    expect(code, 1);
    expect(out.toString(), contains('(never published)'));
    expect(out.toString(), isNot(contains('Up to date.')));
  });

  test('a catalogs project is told every file its pull landed in (#590)', () async {
    final config = writeConfig();
    CliState(
      version: '2026.07.04.2',
      pulledAt: DateTime.now().toUtc(),
      format: 'xcstrings',
      catalogs: const ['App/Localizable.xcstrings', 'App/AppShortcuts.xcstrings'],
    ).save(CliState.fileFor(config));

    await runnerWith(remoteVersion: '2026.07.04.2')
        .run(['--config', config, 'status']);

    expect(out.toString(),
        contains('catalogs: App/Localizable.xcstrings, App/AppShortcuts.xcstrings'));
  });
}
