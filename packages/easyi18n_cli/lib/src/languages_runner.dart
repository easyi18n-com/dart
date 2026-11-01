import 'package:path/path.dart' as p;

import 'cli_output.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'logger.dart';
import 'session.dart';

/// `POST /v1/projects/{id}/languages`, shared by `easyi18n languages add` and
/// the MCP `add_language` tool.
class LanguageAddRunner {
  Future<LanguageAddResult> run({
    required Easyi18nConfig config,
    required String configPath,
    required String token,
    required CliLogger logger,
    required String code,
    String? fillMode,
    ApiClientFactory? apiClientFactory,
  }) => withProject(
    config: config, token: token, logger: logger,
    apiClientFactory: apiClientFactory,
    body: (client, projectId) async {
      final outcome = await client.addLanguage(
        projectId: projectId, code: code, fillMode: fillMode);
      return LanguageAddResult(
        code: outcome.code,
        fillMode: outcome.fillMode,
        projectDir: p.normalize(p.absolute(p.dirname(configPath))),
        baseUrl: config.baseUrl,
      );
    },
  );
}

class LanguageAddResult {
  LanguageAddResult({
    required this.code, required this.fillMode,
    required this.projectDir, required this.baseUrl,
  });

  final String code;
  final String fillMode;
  final String projectDir;
  final String baseUrl;

  Map<String, Object?> toJson() => sanitizeJson({
    'code': code, 'fill_mode': fillMode,
    'project_dir': projectDir, 'base_url': baseUrl,
    'next': 'easyi18n status',
  }) as Map<String, Object?>;
}
