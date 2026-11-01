import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'logger.dart';
import 'session.dart';
import 'state.dart';

/// Read-only comparison of the last pull with the project's live metadata.
class StatusRunner {
  Future<StatusResult> run({
    required Easyi18nConfig config,
    required String configPath,
    required String token,
    required CliLogger logger,
    ApiClientFactory? apiClientFactory,
  }) => withProject(
    config: config, token: token, logger: logger,
    apiClientFactory: apiClientFactory,
    body: (client, projectId) async {
      final local = CliState.load(CliState.fileFor(configPath));
      final meta = await client.fetchMeta(projectId: projectId);
      return StatusResult(
        remoteVersion: meta.currentVersionId,
        localVersion: local.version,
        pulledAt: local.pulledAt,
        catalog: local.catalog,
        catalogs: local.catalogs,
        languages: meta.languages,
        projectDir: p.normalize(p.absolute(p.dirname(configPath))),
        baseUrl: config.baseUrl,
      );
    },
  );
}

class StatusResult {
  StatusResult({
    required this.remoteVersion,
    required this.localVersion,
    required this.pulledAt,
    required this.catalog,
    this.catalogs = const [],
    required List<ProjectLanguage> languages,
    required this.projectDir,
    required this.baseUrl,
  }) : languages = List.unmodifiable(languages);

  final String remoteVersion;
  final String? localVersion;
  final DateTime? pulledAt;
  final String? catalog;
  final List<String> catalogs;
  final List<ProjectLanguage> languages;
  final String projectDir;
  final String baseUrl;

  bool get published => remoteVersion.isNotEmpty;

  String get state {
    // An unpublished remote must win even when a local version exists (#552).
    if (!published) return 'never_published';
    if (localVersion == null) return 'never_pulled';
    return comparePublishVersions(localVersion!, remoteVersion) >= 0
        ? 'up_to_date'
        : 'out_of_date';
  }

  int get exitCode => state == 'up_to_date' ? 0 : 1;
  int? get behind => state == 'out_of_date'
      ? _behind(localVersion!, remoteVersion)
      : null;

  Map<String, Object?> toJson() => {
    'published': published,
    'remote_version': published ? remoteVersion : null,
    'local_version': localVersion,
    'state': state,
    if (behind != null) 'behind': behind,
    if (catalog != null) 'catalog': catalog,
    if (catalogs.isNotEmpty) 'catalogs': catalogs,
    if (pulledAt != null) 'pulled_at': pulledAt!.toUtc().toIso8601String(),
    'languages': [
      for (final language in languages)
        {'code': language.code, 'is_base': language.isBase,
          'fill_mode': language.fillMode},
    ],
    'project_dir': projectDir,
    'base_url': baseUrl,
  };
}

int? _behind(String local, String remote) {
  final pl = parsePublishVersion(local);
  final pr = parsePublishVersion(remote);
  if (pl == null || pr == null || pl.date != pr.date) return null;
  return pr.n - pl.n;
}
