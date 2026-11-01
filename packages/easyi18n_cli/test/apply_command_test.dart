import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/apply_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_apply');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig() {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync('projectId: proj_abc\n');
    return path;
  }

  void writeSource(String rel, String content) {
    final f = File(p.join(dir.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String readSource(String rel) =>
      File(p.join(dir.path, rel)).readAsStringSync();

  /// Runner whose apply command talks to a MockClient returning [changes] from
  /// the pending-code-changes endpoint.
  CommandRunner<int> runnerWith(List<Map<String, Object?>> changes) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        expect(req.url.path, endsWith('/pending-code-changes'));
        expect(req.headers['authorization'], 'Bearer eik_x');
        return http.Response(jsonEncode({'changes': changes}), 200);
      }),
    );

    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      ApplyCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ),
    );
    return runner;
  }

  test('previews without writing by default', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Helo');\n");
    final code = await runnerWith([
      {
        'key': 'greeting',
        'ctx': null,
        'oldSource': 'Helo',
        'newSource': 'Hello',
      },
    ]).run(['--config', writeConfig(), 'apply']);

    expect(code, 0);
    expect(out.toString(), contains('1 call site(s) to update'));
    expect(out.toString(), contains('Re-run with --write'));
    // File untouched in preview mode.
    expect(readSource('lib/main.dart'), contains("c.tr('Helo')"));
  });

  test('--write rewrites the matched literals', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Helo');\n");
    final code = await runnerWith([
      {
        'key': 'greeting',
        'ctx': null,
        'oldSource': 'Helo',
        'newSource': 'Hello',
      },
    ]).run(['--config', writeConfig(), 'apply', '--write']);

    expect(code, 0);
    expect(readSource('lib/main.dart'), contains("c.tr('Hello')"));
    expect(out.toString(), contains('Updated 1 call site(s)'));
  });

  test('reports nothing to apply when the list is empty', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Helo');\n");
    final code = await runnerWith([]).run(['--config', writeConfig(), 'apply']);
    expect(code, 0);
    expect(out.toString(), contains('No pending code changes'));
  });

  test('reports changes with no matching call site as unmatched', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Present');\n");
    final code = await runnerWith([
      {'key': 'gone', 'ctx': null, 'oldSource': 'Absent', 'newSource': 'X'},
    ]).run(['--config', writeConfig(), 'apply']);

    expect(code, 0);
    expect(out.toString(), contains('no matching tr() call site'));
    expect(err.toString(), contains('had no matching literal'));
  });

  test('fails without a credential', () async {
    writeSource('lib/main.dart', "void f(c) => c.tr('Helo');\n");
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      ApplyCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: ({required baseUrl, required token}) =>
            throw StateError('should not build a client without a token'),
        environment: const {},
      ),
    );
    await expectLater(
      runner.run(['--config', writeConfig(), 'apply']),
      throwsA(isA<CliException>()),
    );
  });
}
