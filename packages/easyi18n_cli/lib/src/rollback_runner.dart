import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'cli_output.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'logger.dart';
import 'session.dart';

class RollbackRunner {
  Future<RollbackResult> run({
    required Easyi18nConfig config,
    required String configPath,
    required String token,
    required CliLogger logger,
    String versionId = 'previous',
    ApiClientFactory? apiClientFactory,
  }) => withProject(
    config: config, token: token, logger: logger,
    apiClientFactory: apiClientFactory,
    body: (client, projectId) async => RollbackResult(
      await client.restoreVersion(projectId: projectId, versionId: versionId),
      requestedVersion: versionId,
      projectDir: p.normalize(p.absolute(p.dirname(configPath))),
      baseUrl: config.baseUrl,
    ),
  );
}

/// The flagged cells are still served by the restored snapshot.
class RollbackResult {
  RollbackResult(PublishOutcome outcome, {
    required String requestedVersion,
    required this.projectDir,
    required this.baseUrl,
  }) : restoredFrom = outcome.restoredFrom ?? requestedVersion,
       versionId = outcome.versionId,
       keyCount = outcome.keyCount,
       icuRejected = List.unmodifiable(outcome.icuRejected),
       icuRejectedTotal = outcome.icuRejectedTotal,
       markupRejected = List.unmodifiable(outcome.markupRejected),
       markupRejectedTotal = outcome.markupRejectedTotal;

  final String restoredFrom;
  final String versionId;
  final int keyCount;
  final List<String> icuRejected;
  final int icuRejectedTotal;
  final List<String> markupRejected;
  final int markupRejectedTotal;
  final String projectDir;
  final String baseUrl;

  Map<String, Object?> toJson() => sanitizeJson({
    'restored_from': restoredFrom,
    'version_id': versionId,
    'key_count': keyCount,
    'flagged': {
      'icu': icuRejected, 'icu_total': icuRejectedTotal,
      'markup': markupRejected, 'markup_total': markupRejectedTotal,
    },
    'project_dir': projectDir,
    'base_url': baseUrl,
  }) as Map<String, Object?>;
}
