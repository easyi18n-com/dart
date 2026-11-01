import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('state precedence, version comparison and exact same-day behind', () async {
    final dir = Directory.systemTemp.createTempSync('status_runner');
    addTearDown(() => dir.deleteSync(recursive: true));
    final configPath = '${dir.path}/easyi18n.yaml';
    File(configPath).writeAsStringSync('projectId: proj_abc\n');
    final config = Easyi18nConfig.load(File(configPath));
    for (final (local, remote, state, behind) in [
      ('2026.07.04.2', '', 'never_published', null),
      (null, '', 'never_published', null),
      (null, '2026.07.04.2', 'never_pulled', null),
      ('2026.07.04.2', '2026.07.04.2', 'up_to_date', null),
      ('2026.07.04.4', '2026.07.04.2', 'up_to_date', null),
      ('2026.07.04', '2026.07.04.1', 'up_to_date', null),
      ('2026.07.04.1', '2026.07.04.3', 'out_of_date', 2),
      ('2026.07.03.1', '2026.07.04.3', 'out_of_date', null),
      ('aaa', 'zzz', 'out_of_date', null),
      ('2026.07.04.1', 'zzz', 'out_of_date', null),
    ]) {
      CliState(version: local).save(CliState.fileFor(configPath));
      final client = TranslationsApiClient(
        baseUrl: config.baseUrl, token: 'eik_test',
        httpClient: MockClient((_) async => http.Response(jsonEncode({
          'currentVersionId': remote, 'baseCode': 'en',
        }), 200)),
      );
      final result = await StatusRunner().run(
        config: config, configPath: configPath, token: 'eik_test',
        logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
        apiClientFactory: ({required baseUrl, required token}) => client,
      );
      expect(result.state, state, reason: '$local -> $remote');
      expect(result.exitCode, state == 'up_to_date' ? 0 : 1);
      expect(result.behind, behind);
      final json = result.toJson();
      expect(json['remote_version'], remote.isEmpty ? null : remote);
      expect(json['local_version'], local);
      expect(json.containsKey('behind'), behind != null);
      expect(json.containsKey('pulled_at'), false);
      expect(json.containsKey('catalog'), false);
      expect(json['languages'], isEmpty);
      expect(json['project_dir'], dir.absolute.path);
      expect(json['base_url'], config.baseUrl);
    }
  });

  test('the record lists the catalogs a pull wrote, and only then (#590)', () {
    StatusResult result({List<String> catalogs = const []}) => StatusResult(
        remoteVersion: '2026.07.04.1', localVersion: '2026.07.04.1',
        pulledAt: null, catalog: null, catalogs: catalogs, languages: const [],
        projectDir: '/p', baseUrl: 'https://api.easyi18n.com');
    expect(result(catalogs: ['A.xcstrings', 'B.xcstrings']).toJson()['catalogs'],
        ['A.xcstrings', 'B.xcstrings']);
    expect(result().toJson().containsKey('catalogs'), isFalse);
  });
}
