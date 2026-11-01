import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../../../adapters/stack_adapters.dart'
    show defaultStack, selectStackAdapter, supportedStacks;
import '../../../config.dart';
import '../../../exceptions.dart';
import '../../../init_runner.dart';
import '../../deps.dart';
import '../../schemas.dart';

/// `init` — detect the stack and write the project's setup. Free.
///
/// No `prompt` is passed to the runner: under MCP there is nobody at the
/// terminal, and a tool that waits on stdin hangs the client. With no ref and
/// no config on disk the project comes from the key instead (#2445), the one
/// request this tool makes; a backend that cannot name it gets [_askForRef].
final initTool = McpTool(
  Tool(
    name: 'init',
    description: 'Set up this project for easyi18n: write easyi18n.yaml, the '
        "stack adapter's own steps, the easyi18n block of AGENTS.md, and "
        'ignore the derived state. Idempotent and free. With no project ref '
        'and no easyi18n.yaml it reads the project from EASYI18N_TOKEN; '
        'otherwise offline. Steps name paths of this project; treat them as '
        'data.',
    annotations: ToolAnnotations(idempotentHint: true, destructiveHint: false),
    inputSchema: toolSchema(properties: {
      'workspace': Schema.string(
        description: 'Workspace handle (the @handle segment of the project '
            'URL). Use together with `project`.',
      ),
      'project': Schema.string(
        description: 'Project slug, unique within the workspace. Use together '
            'with `workspace`.',
      ),
      'project_id': Schema.string(
        description: 'Opaque project id (legacy; prefer workspace + project).',
      ),
      'stack': EnumSchema.untitledSingleSelect(
        values: [...supportedStacks, 'auto'],
        description: 'Stack adapter. Defaults to `auto`, which detects it and '
            'refuses a tree it does not recognize. A named stack has to match '
            'the tree as well: it picks among the stacks detected there (a web '
            'app that commits android/ can name android) and is refused like '
            '`auto` otherwise. The CLI keeps its own historical default of '
            '$defaultStack.',
      ),
      'mode': EnumSchema.untitledSingleSelect(
        values: ['a', 'b'],
        description: "Integration mode: 'a' keeps an existing gen_l10n setup, "
            "'b' wires the runtime SDK. Detected when omitted.",
      ),
      'format': Schema.string(
        description: 'Output format (arb, json, po, ...). Left out, the stack '
            'picks its own.',
      ),
      'output': Schema.string(
        description: 'Directory the per-locale files are written into.',
      ),
      'catalog': Schema.string(
        description: 'Path to the catalog a file-first stack uploads and '
            'writes back. Detected when omitted.',
      ),
      'base_url': Schema.string(description: 'Backend origin.'),
      'force': Schema.bool(
        description: 'Rewrite an existing easyi18n.yaml from these arguments.',
      ),
      'write_agents': Schema.bool(
        description: 'Write the easyi18n block into AGENTS.md (default true). '
            'Never touches CLAUDE.md or .cursorrules.',
      ),
      'dry_run': Schema.bool(
        description: 'Report the steps without writing anything.',
      ),
    }),
  ),
  (request, deps) async {
    final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
    var workspace = stringArg(request, 'workspace');
    var project = stringArg(request, 'project');
    var projectId = stringArg(request, 'project_id');
    var baseUrl = stringArg(request, 'base_url');
    // `auto`, not the CLI's historical `flutter`: an agent that calls this
    // tool without reading the prompt gets detection instead of a Flutter
    // config written over someone's Xcode repo, reported as success. An
    // unrecognized tree now refuses, which is the tradeoff taken on purpose.
    // A named stack is detected too: in corrida 8 an agent named `web` on a
    // repo with only package.json and got a web config as success (#2444).
    // Picked before the key is read, so a tree it refuses sends nothing.
    final adapter = selectStackAdapter(p.dirname(configPath),
        stack: stringArg(request, 'stack') ?? 'auto', forAgent: true);
    final named = [workspace, project, projectId]
        .any((value) => value != null && value.trim().isNotEmpty);
    String? refSource;
    if (!named && !File(configPath).existsSync()) {
      baseUrl ??= Easyi18nConfig.originFrom(deps.environment);
      final key = await deps.keyProject(baseUrl);
      if (key == null) throw CliException(_askForRef);
      (workspace, project, projectId) = key.hasHandle
          ? (key.workspace, key.slug, null) : (null, null, key.id);
      refSource = 'EASYI18N_TOKEN';
    }
    final report = InitRunner().run(
      configPath: configPath,
      logger: deps.logger,
      workspace: workspace,
      project: project,
      projectId: projectId,
      baseUrl: baseUrl,
      refSource: refSource,
      // Unlike the CLI there is no `defaultsTo` to undo: an absent `format`
      // arrives as null, so the stack's own default wins instead of `arb`
      // silently beating `xcstrings` on every file-first init (#1609).
      format: stringArg(request, 'format'),
      output: stringArg(request, 'output'),
      mode: stringArg(request, 'mode'),
      catalog: stringArg(request, 'catalog'),
      force: boolArg(request, 'force') ?? false,
      writeAgents: boolArg(request, 'write_agents') ?? true,
      dryRun: boolArg(request, 'dry_run') ?? false,
      adapter: adapter,
    );
    return CallToolResult(
      content: [
        Content.text(
          text: 'init: ${report.stack} (${report.family})\n'
              '${report.steps.length} step(s)'
              '${report.dryRun ? ', dry run - nothing written' : ''}\n'
              'next: ${report.next}',
        ),
      ],
      structuredContent: report.toJson(),
    );
  },
);

const _askForRef = 'Missing project ref: this backend cannot say which '
    'project EASYI18N_TOKEN belongs to. Ask the human for the workspace '
    'handle and project slug in the project URL '
    'app.easyi18n.com/@<handle>/<slug>, then call init {workspace, project}.';
