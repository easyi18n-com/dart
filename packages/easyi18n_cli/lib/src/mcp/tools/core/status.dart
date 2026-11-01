import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../../../config.dart';
import '../../../security.dart';
import '../../../status_runner.dart';
import '../../deps.dart';
import '../../schemas.dart';

/// `status` — the published version against the last pull, plus the project's
/// languages, family and stack. Before `init` it is the first thing an agent
/// calls, so a missing config is an answer, not an error (#2445).
final statusTool = McpTool(
  Tool(
    name: 'status',
    description: 'Compare the published version with the last pull, and list '
        'the project languages and their fill modes. With no easyi18n.yaml it '
        'answers initialized: false, the project of EASYI18N_TOKEN and next: '
        'init.',
    annotations: ToolAnnotations(
      readOnlyHint: true, idempotentHint: true, openWorldHint: true,
    ),
    inputSchema: toolSchema(),
  ),
  (request, deps) async {
    final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
    if (!File(configPath).existsSync()) return _notInitialized(configPath, deps);
    final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
    refuseUntrustedTarget(config.baseUrl, environment: deps.environment);
    final result = await StatusRunner().run(
      config: config,
      configPath: configPath,
      token: deps.requireToken(),
      logger: deps.logger,
      apiClientFactory: deps.apiClientFactory,
    );
    return CallToolResult(
      content: [
        Content.text(
          text: 'status: ${result.state}\n'
              'remote: ${result.published ? result.remoteVersion : "(never published)"}\n'
              'local: ${result.localVersion ?? "(never pulled)"}\n'
              'languages: ${result.languages.length}',
        ),
      ],
      structuredContent: {'initialized': true, ...result.toJson()},
    );
  },
);

/// The project comes from the key, so the agent asks the human for nothing; a
/// backend without `GET /v1/credential` leaves it out and init asks instead.
Future<CallToolResult> _notInitialized(String configPath, McpDeps deps) async {
  final baseUrl = Easyi18nConfig.originFrom(deps.environment);
  final project = (await deps.keyProject(baseUrl))?.describe;
  return CallToolResult(
    content: [
      Content.text(
        text: 'status: not initialized\n'
            '${project == null ? '' : 'project: $project (from EASYI18N_TOKEN)\n'}'
            'next: init',
      ),
    ],
    structuredContent: {
      'initialized': false,
      'project': ?project,
      'next': 'init',
      'project_dir': p.normalize(p.absolute(p.dirname(configPath))),
      'base_url': baseUrl,
    },
  );
}
