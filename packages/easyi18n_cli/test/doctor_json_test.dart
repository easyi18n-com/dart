import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/command_runner.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/agents_md.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('doctor_json');
    File('${dir.path}/easyi18n.yaml').writeAsStringSync('''
projectId: proj_abc
mode: a
baseUrl: http://localhost:9
''');
    Directory('${dir.path}/lib').createSync();
    writeAgentsBlock('${dir.path}/easyi18n.yaml');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(int?, Map<String, dynamic>, String)> run({
    Map<String, Object?> coverage = const {},
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'env-token'},
    List<String> arguments = const [],
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final runner = Easyi18nCommandRunner(
      logger: CliLogger(out: out, err: err), environment: environment,
      apiClientFactory: ({required baseUrl, required token}) {
        expect(token, 'env-token');
        return TranslationsApiClient(baseUrl: baseUrl, token: token,
          httpClient: MockClient((request) async {
            expect(request.method, 'GET');
            return http.Response(jsonEncode({
              'version': 'v1', 'format': 'arb', 'files': {},
              'coverageBasis': 'skip', 'coverage': coverage,
            }), 200);
          }));
      },
    );
    final code = await runner.run([
      '--json', '--config', '${dir.path}/easyi18n.yaml', 'doctor', ...arguments,
    ]);
    final payload = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(payload, isNotEmpty);
    expect(payload.containsKey('error'), isFalse);
    return (code, payload, err.toString());
  }

  test('JSON preserves ordered findings and skip is a passing verdict', () async {
    final (code, report, err) = await run();
    expect(code, 0);
    expect(report['counts'], {'failures': 0, 'warnings': 0, 'unchecked': 0});
    expect(report['verdict'], 'passed');
    final findings = report['findings'] as List;
    expect(findings.map((f) => f['check']), [
      'config', 'credential', 'agents_md', 'mode', 'mode', 'scan', 'icu',
      'delivery', 'completeness',
    ]);
    expect(findings.last['level'], 'skip');
    for (final finding in findings) {
      expect((finding as Map).keys.toSet(),
          {'check', 'subject', 'level', 'message', 'details'});
    }
    expect(err, isEmpty);
  });

  test('unverified stays distinct from skip, including empty explicit token', () async {
    final (code, report, _) = await run(arguments: ['--token', '']);
    expect(code, 0);
    expect(report['counts'], {'failures': 0, 'warnings': 1, 'unchecked': 1});
    expect(report['verdict'], 'unverified');
    expect(report['findings'].last['level'], 'unverified');
  });

  test('configuration warnings stay on stderr beside one JSON object', () async {
    File('${dir.path}/easyi18n.yaml').writeAsStringSync('unknown_setting: true\n',
        mode: FileMode.append);
    final (_, report, err) = await run();
    expect(report['verdict'], 'passed');
    expect(err, startsWith('warning: Ignoring unknown setting(s)'));
    expect(err, contains('unknown_setting'));
  });

  test('multiple incomplete locales are ordered failures', () async {
    final (code, report, _) = await run(coverage: {
      'fr': {'translated': 1, 'total': 3},
      'es': {'translated': 2, 'total': 3},
    });
    expect(code, 1);
    expect(report['counts'], {'failures': 2, 'warnings': 0, 'unchecked': 0});
    expect(report['verdict'], 'failed');
    expect((report['findings'] as List).where((f) => f['level'] == 'fail')
        .map((f) => f['message']), [
      'fr: 2 of 3 entry(ies) untranslated in version v1',
      'es: 1 of 3 entry(ies) untranslated in version v1',
    ]);
  });
}
