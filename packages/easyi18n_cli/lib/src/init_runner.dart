import 'dart:io';

import 'package:path/path.dart' as p;

import 'adapters/stack_adapter.dart';
import 'adapters/stack_adapters.dart';
import 'agents_md.dart';
import 'config.dart';
import 'exceptions.dart';
import 'init_report.dart';
import 'logger.dart';
import 'project_ref.dart';
import 'scaffold.dart' show addGitignoreEntry, kStateIgnoreEntry;

export 'init_report.dart';

/// Optional interactive input; runners never access stdin themselves.
typedef Prompt = String? Function(String label);

class InitRunner {
  InitReport run({required String configPath, required CliLogger logger,
    String? workspace, String? project, String? projectId, String? baseUrl,
    String? format, String? output, String? mode, String? catalog,
    bool force = false, bool writeAgents = true,
    bool dryRun = false, String stack = defaultStack, bool forAgent = false,
    StackAdapter? adapter, Prompt? prompt, void Function(InitStep)? onStep,
    String? refSource}) {
    try {
      return _InitRun(configPath: configPath, logger: logger,
        workspace: workspace, project: project, projectId: projectId,
        baseUrl: baseUrl, format: format, output: output, mode: mode,
        catalog: catalog, force: force, writeAgents: writeAgents,
        dryRun: dryRun, prompt: prompt, refSource: refSource,
        adapter: adapter ?? selectStackAdapter(p.dirname(configPath),
            stack: stack, forAgent: forAgent),
        onStep: onStep).run();
    } on FileSystemException catch (e) {
      throw CliException('Cannot read or write ${e.path}: ${e.message}');
    }
  }
}

class _InitRun {
  _InitRun({required this.configPath, required CliLogger logger,
    required this.workspace, required this.project, required this.projectId,
    required this.baseUrl, required this.format, required this.output,
    required this.mode, required this.catalog,
    required this.force, required this.writeAgents, required this.dryRun,
    required this.prompt, required this.adapter, void Function(InitStep)? onStep,
    this.refSource})
      : _logger = logger, _replay = onStep;
  final String configPath;
  final CliLogger _logger;
  final String? workspace, project, projectId, baseUrl, format, output, mode,
      catalog;
  /// Where a ref the call did not pass came from, named in the config's step.
  final String? refSource;
  final bool force, writeAgents, dryRun;
  final Prompt? prompt;
  final StackAdapter adapter;
  final void Function(InitStep)? _replay;
  final _steps = <InitStep>[];
  late final _context = InitContext(root: p.dirname(configPath), dryRun: dryRun,
      onStep: _onStep, ignoreDerivedState: _ignoreDerivedState);
  bool _ignoredDerivedState = false;

  InitReport run() {
    final file = File(configPath);
    final root = file.parent.path;
    final config = _ensureConfig(file);
    adapter.initSteps(_context, config);
    _ignoreDerivedState();
    if (writeAgents) {
      writeAgentsMd(_context, config, adapter);
    } else {
      _context.report('skipped', p.join(root, kAgentsMdFile), '--no-agents');
    }
    return InitReport(stack: adapter.stack, family: adapter.family,
      projectDir: p.normalize(p.absolute(root)), baseUrl: config.baseUrl,
      dryRun: dryRun, next: adapter.nextCommand(config), steps: _steps);
  }

  void _onStep(InitStep step) { _steps.add(step); _replay?.call(step); }

  /// Writes (or keeps) `easyi18n.yaml` and returns the effective config.
  Easyi18nConfig _ensureConfig(File file) {
    final flagId = projectId?.trim();
    final flagWorkspace = workspace?.trim();
    final flagProject = project?.trim();

    final hasId = flagId != null && flagId.isNotEmpty;
    final hasWorkspace = flagWorkspace != null && flagWorkspace.isNotEmpty;
    final hasProject = flagProject != null && flagProject.isNotEmpty;
    if (hasId && (hasWorkspace || hasProject)) {
      throw CliException(
        'Pass either --project-id, or --workspace + --project (not both).',
      );
    }
    if (hasWorkspace != hasProject) {
      throw CliException(
        '--workspace and --project must be used together (the @handle/slug '
        'pair needs both).',
      );
    }

    if (file.existsSync() && !force) {
      final Easyi18nConfig config;
      try {
        config = Easyi18nConfig.load(file, logger: _logger);
      } on FileSystemException catch (e) {
        throw CliException('Cannot read ${file.path}: ${e.message}');
      }
      ProjectRef? flagRef;
      if (hasId || hasWorkspace) {
        try {
          flagRef = ProjectRef.parse(
            projectId: flagId,
            workspace: flagWorkspace,
            project: flagProject,
            source: 'flags',
          );
        } on CliException catch (e) {
          // A degenerate flag ref (e.g. a lone '@' handle). The config on
          // disk wins on this path anyway, so warn-and-keep instead of
          // failing the otherwise idempotent re-run.
          _logger.warn('Ignoring the ref flags: ${e.message}');
        }
      }
      _context.report('ok', file.path, 'kept existing config');
      _reportIgnored(file.path, config, flagRef);
      return config;
    }

    final config = _buildConfig(
      flagId: flagId,
      flagWorkspace: flagWorkspace,
      flagProject: flagProject,
      mode: adapter.resolveMode(file.parent.path, mode, _onStep),
    );
    final existed = file.existsSync();
    _context.write(file, config.toYaml());
    _context.report(
      existed ? 'rewrote' : 'created',
      file.path,
      'project ${config.describeRef}'
          '${refSource == null ? '' : ', read from $refSource'}',
    );
    return config;
  }

  /// Names each value the call passed that the kept [config] does not hold, as
  /// a step: under MCP the result is all the agent reads (#2135).
  void _reportIgnored(String path, Easyi18nConfig config, ProjectRef? flagRef) {
    String? normalized(String? value) => value == null ? null : p.normalize(value);
    final flagBaseUrl = baseUrl;
    for (final (setting, kept, asked) in [
      ('project ', config.describeRef, flagRef?.describe),
      ('mode: ', config.mode, mode),
      ('baseUrl: ', config.baseUrl,
          flagBaseUrl == null ? null : Easyi18nConfig.trimBaseUrl(flagBaseUrl)),
      ('format: ', config.format, format),
      ('output: ', normalized(config.output), normalized(output)),
      if (config.catalogs.isEmpty)
        ('catalog: ', normalized(config.catalog), normalized(catalog))
      else
        ('catalogs: ', config.catalogs.join(', '), normalized(catalog)),
    ]) {
      if (asked == null || asked == kept) continue;
      _context.report('skipped', path,
          'keeps $setting${kept ?? '(none)'}, not $asked (use --force to rewrite)');
    }
  }

  /// Builds the config from the flags, prompting on a terminal when no ref
  /// flag is set (handle pair first, falling back to a legacy project id).
  Easyi18nConfig _buildConfig({
    required String? flagId,
    required String? flagWorkspace,
    required String? flagProject,
    required String mode,
  }) {
    // Before the prompt: what the stack fills in is reported as a step, and a
    // step must not land after the line the terminal is waiting on.
    final defaults = adapter.configDefaults(p.dirname(configPath), mode, _onStep);
    String? workspace = flagWorkspace;
    String? project = flagProject;
    String? projectId = flagId;

    final prompted =
        (workspace == null || workspace.isEmpty) &&
        (projectId == null || projectId.isEmpty);
    if (prompted) {
      workspace = prompt?.call('Workspace handle (@handle)')?.trim();
      if (workspace != null && workspace.isNotEmpty) {
        project = prompt?.call('Project slug')?.trim();
        if (project == null || project.isEmpty) {
          throw CliException('A workspace handle needs a project slug.');
        }
      } else {
        // No handle given — fall back to the legacy opaque id.
        workspace = null;
        projectId = prompt?.call('Project id')?.trim();
      }
    }

    final hasId = projectId != null && projectId.isNotEmpty;
    final hasWorkspace = workspace != null && workspace.isNotEmpty;
    if (!hasId && !hasWorkspace) {
      throw CliException(
        'Missing project ref. Pass --workspace + --project (or --project-id), '
        "or run 'easyi18n init' in a terminal.",
      );
    }

    return Easyi18nConfig(
      ref: ProjectRef.parse(
        projectId: projectId,
        workspace: workspace,
        project: project,
        // Label the parse error with the surface the values came from.
        source: prompted ? 'easyi18n init' : 'flags',
      ),
      baseUrl: baseUrl,
      format: format ?? defaults.format,
      output: output ?? defaults.output,
      mode: mode,
      catalog: catalog ?? defaults.catalog,
      source: defaults.source,
      sourceRoot: defaults.source == null ? null : p.dirname(defaults.source!),
      sourceLayout: defaults.source == null ? null : defaults.sourceLayout,
    );
  }

  void _ignoreDerivedState() {
    if (_ignoredDerivedState) return;
    _patchGitignore(File(p.join(_context.root, '.gitignore')));
    _ignoredDerivedState = true;
  }

  void _patchGitignore(File gitignore) {
    final content = gitignore.existsSync() ? gitignore.readAsStringSync() : '';
    final patched = addGitignoreEntry(content);
    if (patched == null) {
      _context.report('ok', gitignore.path, '$kStateIgnoreEntry already ignored');
      return;
    }
    _context.write(gitignore, patched);
    _context.report('patched', gitignore.path, 'ignored $kStateIgnoreEntry');
  }

}
