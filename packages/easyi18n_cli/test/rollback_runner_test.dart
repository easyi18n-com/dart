import 'dart:convert';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('rollback result retains both totals, sanitizes JSON and falls back to requested version', () async {
    final result = await RollbackRunner().run(
      config: Easyi18nConfig(ref: IdRef('proj_abc')),
      configPath: 'nested/../easyi18n.yaml', token: 'eik_test',
      logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
      versionId: '2026.07.01.1',
      apiClientFactory: ({required baseUrl, required token}) => TranslationsApiClient(
        baseUrl: baseUrl, token: token,
        httpClient: MockClient((request) async {
          expect(request.url.path,
              '/v1/projects/proj_abc/versions/2026.07.01.1/restore');
          return http.Response(jsonEncode({
            'versionId': '2026.07.09.4', 'keyCount': 8,
            'icuRejected': ['icu\x1b[31m'], 'icuRejectedTotal': 7,
            'markupRejected': ['markup'], 'markupRejectedTotal': 9,
          }), 201);
        }),
      ),
    );
    expect(result.icuRejected, ['icu\x1b[31m']);
    expect(result.toJson(), {
      'restored_from': '2026.07.01.1', 'version_id': '2026.07.09.4',
      'key_count': 8,
      'flagged': {'icu': ['icu[31m'], 'icu_total': 7, 'markup': ['markup'], 'markup_total': 9},
      'project_dir': p.normalize(p.absolute('.')),
      'base_url': 'https://api.easyi18n.com',
    });
  });
}
