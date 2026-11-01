import 'dart:convert';
import 'dart:io';

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
    dir = Directory.systemTemp.createTempSync('formats_test');
    out = StringBuffer();
    transcript = Transcript();
    requests = [];
    status = 200;
    response = {'formats': ['strings', 'arb'], 'created': true};
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int?> run({bool alias = false, bool token = true,
    List<String> args = const ['formats', 'add', 'arb'], bool json = true,
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

  test('public barrel exposes the format runner and result', () async {
    final OutputFormatResult result = await OutputFormatRunner().run(
      config: Easyi18nConfig.load(File('${dir.path}/easyi18n.yaml')
        ..writeAsStringSync('projectId: p1\n'), logger: CliLogger(out: out)),
      configPath: '${dir.path}/easyi18n.yaml', token: 'test',
      logger: CliLogger(out: out), format: 'arb',
      apiClientFactory: ({required baseUrl, required token}) =>
        TranslationsApiClient(baseUrl: baseUrl, token: token,
          httpClient: MockClient((_) async =>
            http.Response(jsonEncode(response), 200))),
    );
    expect(result.enabled, ['strings', 'arb']);
    expect(result.toJson()['created'], true);
  });
  for (final alias in [false, true]) {
    test('real command resolves alias=$alias and emits confirmed list', () async {
      expect(await run(alias: alias), 0);
      expect(requests.length, alias ? 2 : 1);
      final req = requests.last;
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/projects/p1/output-formats');
      expect(req.headers['authorization'], 'Bearer eik_0123456789abcdef');
      expect(jsonDecode(req.body), {'format': 'arb', 'mode': 'add'});
      expect(jsonDecode(out.toString()), {
        'format': 'arb', 'enabled': ['strings', 'arb'], 'created': true,
        'project_dir': dir.path, 'base_url': 'https://api.easyi18n.com',
        'next': 'easyi18n status',
      });
    });
  }
  for (final created in [false, true]) {
    test('refuses success without requested format, created=$created', () async {
      response = {'formats': ['strings'], 'created': created};
      expect(await run(), 1);
      expect(requests, hasLength(1));
      final payload = jsonDecode(out.toString());
      expect(payload, isNot(contains('enabled')));
      expect(payload['error']['message'], contains('requested format'));
      expect(payload['error']['message'], contains('formats add <id>'));
    });
  }
  test('repeat reports created=false without changing returned legacy IDs', () async {
    expect(await run(), 0);
    out.clear();
    response = {'formats': ['strings', 'arb'], 'created': false};
    expect(await run(), 0);
    expect(jsonDecode(out.toString())['created'], false);
    expect(requests, hasLength(2));
  });
  test('missing write credential sends nothing', () async {
    expect(await run(token: false), 1);
    expect(requests, isEmpty);
    expect(out.toString(), contains('write scope'));
  });
  for (final entry in {400: 'invalid_format', 401: 'unauthenticated',
    402: 'plan_limit', 403: 'insufficient_scope',
    409: 'output_config_conflict'}.entries) {
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
    expect(await run(args: ['formats']), 64);
    expect(jsonDecode(out.toString())['error']['code'], 'json_unsupported');
    expect(requests, isEmpty);
  });
  for (final args in [['formats', 'add'], ['formats', 'add', 'arb', 'json']]) {
    test('requires exactly one format: $args', () async {
      expect(await run(args: args), 1);
      expect(requests, isEmpty);
    });
  }
  test('sanitizes requested and persisted strings', () async {
    response = {'formats': ['eik_0123456789abcdef'], 'created': false};
    expect(await run(args: ['formats', 'add', 'eik_0123456789abcdef']), 0);
    expect(out.toString(), isNot(contains('eik_0123456789abcdef')));
  });
  for (final json in [false, true]) {
    test('formats add golden json=$json', () async {
      final code = await run(json: json, golden: true);
      final records = transcript.records.map((r) =>
        (channel: r.channel, line: r.line.replaceAll(dir.path, '<tmp>'))).toList();
      if (json) {
        expectJsonGolden('formats_add_json', code!, records, check: (payload) {
          expect(payload['enabled'], ['strings', 'arb']);
          expect(payload['next'], 'easyi18n status');
        });
      } else {
        expectGolden('formats_add', code!, records);
      }
    });
  }
  test('text distinguishes materialization from no-op', () async {
    expect(await run(json: false), 0);
    expect(out.toString(), contains('Output formats updated'));
    expect(out.toString(), contains('strings, arb'));
    out.clear();
    response = {'formats': ['strings', 'arb'], 'created': false};
    expect(await run(json: false), 0);
    expect(out.toString(), contains('already enabled'));
  });
}
