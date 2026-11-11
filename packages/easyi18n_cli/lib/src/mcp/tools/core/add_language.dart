import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../config.dart';
import '../../../languages_runner.dart';
import '../../../security.dart';
import '../../deps.dart';
import '../../schemas.dart';

/// `add_language` — `POST /v1/projects/{id}/languages` with a write-scoped
/// key (D12). No approval: it charges nothing and runs no AI.
final addLanguageTool = McpTool(
  Tool(
    name: 'add_language',
    description: 'Add a target language to the project, or revive one that '
        "was removed. Needs the human's easyi18n login or a key with the "
        'write scope in EASYI18N_TOKEN. Charges nothing; the language is '
        'filled by the next push or sync unless fill_mode is manual.',
    annotations: ToolAnnotations(idempotentHint: true, openWorldHint: true),
    inputSchema: toolSchema(
      properties: {
        'code': Schema.string(
          description: 'Locale code, e.g. fr or pt-BR. The server normalizes '
              'it and answers with the stored form.',
        ),
        'fill_mode': EnumSchema.untitledSingleSelect(
          values: ['ai', 'manual'],
          description: 'manual keeps the language out of AI fills. Omitted, '
              'a live language keeps its mode and a new one gets ai.',
        ),
      },
      required: ['code'],
    ),
  ),
  (request, deps) async {
    final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
    final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
    refuseUntrustedTarget(config.baseUrl, environment: deps.environment);
    final result = await LanguageAddRunner().run(
      config: config,
      configPath: configPath,
      token: deps.requireToken(config.baseUrl, scope: 'write'),
      logger: deps.logger,
      code: stringArg(request, 'code')!,
      fillMode: stringArg(request, 'fill_mode'),
      apiClientFactory: deps.apiClientFactory,
    );
    return CallToolResult(
      content: [
        Content.text(
          text: 'added: ${result.code} (fill mode: ${result.fillMode})\n'
              'next: status',
        ),
      ],
      structuredContent: {
        'code': result.code,
        'fill_mode': result.fillMode,
        'next': 'status',
      },
    );
  },
);
