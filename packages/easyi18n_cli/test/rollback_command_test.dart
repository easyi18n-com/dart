import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/rollback_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late List<http.Request> requests;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_rollback');
    out = StringBuffer();
    requests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig() {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync('projectId: proj_abc\n');
    return path;
  }

  CommandRunner<int> runner({int status = 201}) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        requests.add(req);
        if (status != 201) {
          return http.Response(
            jsonEncode({'error': 'version_not_found', 'message': 'nope'}),
            status,
          );
        }
        return http.Response(
          jsonEncode({
            'versionId': '2026.07.09.4',
            'keyCount': 3,
            'restoredFrom': '2026.07.08.2',
          }),
          201,
        );
      }),
    );
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    r.addCommand(
      RollbackCommand(
        output: CliOutput(logger: CliLogger(out: out, err: StringBuffer())),
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ),
    );
    return r;
  }

  test('flagged cells reach the success line and stderr — present, not '
      'dropped (#605)', () async {
    final err = StringBuffer();
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(
          jsonEncode({
            'versionId': '2026.07.09.4',
            'keyCount': 3,
            'restoredFrom': '2026.07.08.2',
            'icuRejected': ['apples [es]: plural value is missing the '
                "mandatory 'other' form"],
            'icuRejectedTotal': 2,
          }),
          201,
        );
      }),
    );
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    r.addCommand(
      RollbackCommand(
        output: CliOutput(logger: CliLogger(out: out, err: err)),
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ),
    );
    final code = await r.run(['--config', writeConfig(), 'rollback']);
    expect(code, 0);
    expect(
      out.toString(),
      contains("2 cell(s) would be refused by today's publish gates"),
    );
    // The whole heading, noun included (#1175): asserting the tail alone
    // ('are being served:') left this the one refusal line in the package
    // whose noun nothing pinned — it is the second of rollback's two, and
    // the source guard's `$what` pattern does not reach it either, because
    // here the noun and `$what` are not adjacent.
    expect(
      err.toString(),
      contains('2 cell(s) in the restored version fail ICU validation and '
          'are being served:'),
    );
    expect(err.toString(), contains('apples [es]:'));
    expect(err.toString(), contains('...and 1 more'));
  });

  test('no argument rolls back to `previous`', () async {
    final code = await runner().run(['--config', writeConfig(), 'rollback']);
    expect(code, 0);
    expect(
      requests.single.url.path,
      '/v1/projects/proj_abc/versions/previous/restore',
    );
    expect(
      out.toString(),
      contains('Rolled back: 2026.07.08.2 restored as 2026.07.09.4'),
    );
  });

  test('an explicit version id is passed through', () async {
    final code = await runner().run([
      '--config',
      writeConfig(),
      'rollback',
      '2026.07.01.1',
    ]);
    expect(code, 0);
    expect(
      requests.single.url.path,
      '/v1/projects/proj_abc/versions/2026.07.01.1/restore',
    );
  });

  test('a server error surfaces as a CliException', () async {
    await expectLater(
      runner(status: 404).run(['--config', writeConfig(), 'rollback']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('nope'),
        ),
      ),
    );
  });

  test('missing token throws before any network', () async {
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    r.addCommand(
      RollbackCommand(
        output: CliOutput(logger: CliLogger(out: out, err: StringBuffer())),
        environment: const {},
      ),
    );
    await expectLater(
      r.run(['--config', writeConfig(), 'rollback']),
      throwsA(isA<CliException>()),
    );
    expect(requests, isEmpty);
  });
}
