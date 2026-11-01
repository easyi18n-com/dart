import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/transcript.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late Transcript transcript;
  late List<http.Request> requests;
  late int status;
  late Object response;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('languages_test');
    out = StringBuffer();
    transcript = Transcript();
    requests = [];
    status = 201;
    response = {'code': 'fr', 'isBase': false, 'fillMode': 'ai'};
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int?> run({bool alias = false, bool token = true,
    List<String> args = const ['languages', 'add', 'fr'], bool json = true,
    bool golden = false}) {
    final config = File('${dir.path}/easyi18n.yaml')..writeAsStringSync(
      alias ? "workspace: '@team'\nproject: app\n" : 'projectId: p1\n');
    return Easyi18nCommandRunner(
      output: CliOutput(out: golden ? transcript.out : out,
        err: golden ? transcript.err : StringBuffer()),
      environment: token ? {'EASYI18N_TOKEN': 'eik_0123456789abcdef'} : {},
      apiClientFactory: ({required baseUrl, required token}) =>
        TranslationsApiClient(baseUrl: baseUrl, token: token,
          httpClient: MockClient((req) async {
            requests.add(req);
            if (req.url.path.endsWith('/resolve')) {
              return http.Response('{"projectId":"p1"}', 200);
            }
            return http.Response(jsonEncode(response), status);
          })),
    ).run(['--config', config.path, if (json) '--json', ...args]);
  }

  test('public barrel exposes the language runner and result', () async {
    final LanguageAddResult result = await LanguageAddRunner().run(
      config: Easyi18nConfig.load(File('${dir.path}/easyi18n.yaml')
        ..writeAsStringSync('projectId: p1\n'), logger: CliLogger(out: out)),
      configPath: '${dir.path}/easyi18n.yaml', token: 'test',
      logger: CliLogger(out: out), code: 'fr',
      apiClientFactory: ({required baseUrl, required token}) =>
        TranslationsApiClient(baseUrl: baseUrl, token: token,
          httpClient: MockClient((_) async =>
            http.Response(jsonEncode(response), 201))),
    );
    expect(result.code, 'fr');
    expect(result.toJson()['fill_mode'], 'ai');
  });

  for (final alias in [false, true]) {
    test('real command resolves alias=$alias and posts only the code',
        () async {
      expect(await run(alias: alias), 0);
      expect(requests.length, alias ? 2 : 1);
      final req = requests.last;
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/projects/p1/languages');
      expect(req.headers['authorization'], 'Bearer eik_0123456789abcdef');
      expect(jsonDecode(req.body), {'code': 'fr'});
      expect(jsonDecode(out.toString()), {
        'code': 'fr', 'fill_mode': 'ai',
        'project_dir': dir.path, 'base_url': 'https://api.easyi18n.com',
        'next': 'easyi18n status',
      });
    });
  }

  test('--fill-mode manual travels and the stored code is reported', () async {
    response = {'code': 'pt-br', 'isBase': false, 'fillMode': 'manual'};
    expect(await run(args: ['languages', 'add', 'PT_BR', '--fill-mode',
      'manual']), 0);
    expect(jsonDecode(requests.single.body),
        {'code': 'PT_BR', 'fillMode': 'manual'});
    final payload = jsonDecode(out.toString());
    expect(payload['code'], 'pt-br');
    expect(payload['fill_mode'], 'manual');
  });

  test('an unknown --fill-mode is a usage error that sends nothing', () async {
    const args = ['languages', 'add', 'fr', '--fill-mode', 'auto'];
    await expectLater(
        run(args: args, json: false),
        throwsA(isA<UsageException>()
            .having((e) => e.message, 'message', contains('fill-mode'))));
    expect(out.toString(), isEmpty);
    expect(await run(args: args), 64);
    final error = jsonDecode(out.toString())['error'];
    expect(error['code'], 'usage_error');
    expect(error['message'], contains('fill-mode'));
    expect(requests, isEmpty);
  });

  test('a stored fill mode other than the requested one is refused', () async {
    expect(await run(args: ['languages', 'add', 'fr', '--fill-mode',
      'manual']), 1);
    expect(requests, hasLength(1));
    final message = jsonDecode(out.toString())['error']['message'];
    expect(message, contains('fill mode'));
    expect(message, contains('languages add <code>'));
  });

  for (final body in [
    {'code': 'fr', 'isBase': false, 'fillMode': 'auto'},
    {'code': '', 'isBase': false, 'fillMode': 'ai'},
    {'isBase': false, 'fillMode': 'ai'},
  ]) {
    test('a success body with the wrong shape is refused: $body', () async {
      response = body;
      expect(await run(), 1);
      final payload = jsonDecode(out.toString());
      expect(payload, isNot(contains('code')));
      expect(payload['error']['message'], contains('languages add <code>'));
    });
  }

  test('missing write credential sends nothing', () async {
    expect(await run(token: false), 1);
    expect(requests, isEmpty);
    expect(out.toString(), contains('write scope'));
  });

  for (final entry in {400: 'invalid_argument', 401: 'unauthorized',
    402: 'plan_limit', 403: 'forbidden', 404: 'not_found'}.entries) {
    test('server ${entry.key}/${entry.value} propagates', () async {
      status = entry.key;
      response = {'error': entry.value, 'message': 'refused'};
      expect(await run(), 1);
      final error = jsonDecode(out.toString())['error'];
      expect(error['code'], entry.value);
      expect(error['statusCode'], entry.key);
      expect(requests, hasLength(1));
    });
  }

  test('group is not a JSON presenter', () async {
    expect(await run(args: ['languages']), 64);
    expect(jsonDecode(out.toString())['error']['code'], 'json_unsupported');
    expect(requests, isEmpty);
  });

  for (final args in [['languages', 'add'], ['languages', 'add', 'fr', 'de']]) {
    test('requires exactly one code: $args', () async {
      expect(await run(args: args), 1);
      expect(requests, isEmpty);
    });
  }

  for (final json in [false, true]) {
    test('languages add golden json=$json', () async {
      final code = await run(json: json, golden: true);
      final records = transcript.records.map((r) =>
        (channel: r.channel, line: r.line.replaceAll(dir.path, '<tmp>'))).toList();
      if (json) {
        expectJsonGolden('languages_add_json', code!, records,
            check: (payload) {
          expect(payload['code'], 'fr');
          expect(payload['next'], 'easyi18n status');
        });
      } else {
        expectGolden('languages_add', code!, records);
      }
    });
  }
}
