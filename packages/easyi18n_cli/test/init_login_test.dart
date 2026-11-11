@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/login_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/transcript.dart';

// #2584 through the real runner: what a developer with `easyi18n login` and no
// project ref used to get from `init` (A3).
void main() {
  const origin = 'http://localhost:8080';
  late Directory tmp;
  late Transcript transcript;
  late List<String> paths;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('init_login');
    File(p.join(tmp.path, 'app', 'App.xcodeproj', 'project.pbxproj')).createSync(recursive: true);
    File(p.join(tmp.path, 'app', 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"sourceLanguage":"en","strings":{"Hi":{}},"version":"1.0"}');
    LoginStore(File(p.join(tmp.path, 'home', '.config', 'easyi18n', 'credentials.json')))
        .write(origin, StoredLogin(token: 'eip_${'k' * 40}', expiresAt: DateTime.utc(2100)));
    transcript = Transcript();
    paths = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<int?> run(List<String> args) => Easyi18nCommandRunner(
        logger: CliLogger(out: transcript.out, err: transcript.err),
        environment: {'HOME': p.join(tmp.path, 'home'), 'EASYI18N_BASE_URL': origin},
        apiClientFactory: ({required baseUrl, required token}) => TranslationsApiClient(
            baseUrl: baseUrl, token: token, wait: (_) async {},
            httpClient: MockClient((req) async {
              paths.add(req.url.path);
              return http.Response(jsonEncode({'workspaces': <Object>[]}), 200);
            })),
      ).run(['--config', p.join(tmp.path, 'app', 'easyi18n.yaml'), ...args]);

  String everything() => transcript.records.map((r) => r.line).join('\n');

  test('without a terminal and a ref, init names the flags that create one', () async {
    expect(await run(['--json', 'init', '--no-agents']), 1);
    expect(paths, ['/v1/me/workspaces']);
    expect(everything(), contains('--workspace and --project (add --create to create it)'));
  });

  test('with a login, the text ending does not send anyone to EASYI18N_TOKEN', () async {
    expect(await run(['init', '--no-agents', '--workspace', 'h', '--project', 's',
        '--base-url', origin]), 0);
    expect(paths, isEmpty);
    expect(transcript.records.last.line, "Done. Run 'easyi18n sync'.");
  });
}
