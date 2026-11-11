import 'dart:io';

import 'package:path/path.dart' as p;

import 'adapters/stack_adapter.dart';
import 'api_client.dart';
import 'config.dart';
import 'exceptions.dart';
import 'init_report.dart';
import 'init_runner.dart' show Prompt;
import 'logger.dart';
import 'output_format.dart';
import 'xcstrings_merge.dart' show xcstringsCatalogSummary;

/// What `init` sets up on the server when a login names no project (ci-sync
/// §9 steps 2 to 4 and 6, #2584): the workspace, the project it links or
/// creates, its target languages and its output format. [InitRunner] then
/// writes the ref, so a refusal here leaves no `easyi18n.yaml`.
class OnlineInit {
  OnlineInit({required this.client, required this.logger, required this.onStep,
      this.prompt, this.argument = _flag});

  final TranslationsApiClient client;
  final CliLogger logger;
  final void Function(InitStep) onStep;

  /// Null without a terminal: every choice then comes from a flag.
  final Prompt? prompt;

  /// How a refusal names an input: a flag here, a tool argument under MCP.
  final String Function(String flag) argument;

  Future<AccountProject> run({required String root, required StackAdapter adapter,
      String? mode, String? format, String? workspace, String? project,
      bool create = false, String? name, String? languages, String? base}) async {
    final defaults = adapter.configDefaults(
        root, adapter.resolveMode(root, mode, (_) {}), (_) {});
    final ws = _workspace(await client.fetchWorkspaces(), workspace);
    var target = _project(ws, project, create);
    var add = languages == null ? null : _codes(languages);
    if (target == null) {
      try {
        target = await _create(ws, root, adapter, defaults, project, name, add, base);
        add = const [];
      } on ApiException catch (e) {
        if (e.statusCode != 402 || e.code != 'plan_limit') rethrow;
        target = _afterPlanLimit(ws, e);
      }
    }
    final adoption =
        OutputFormatAdoption(format ?? defaults.format ?? Easyi18nConfig.defaultFormat);
    final ProjectMeta meta;
    try {
      meta = await adoption.preflight(client, target.id);
    } on FatalCliException {
      if (adoption.state != OutputFormatState.conflict) rethrow;
      // No easyi18n.yaml yet: the remedy sync gives (`format:`, `formats add`)
      // has nothing to act on, so name what this command can do instead.
      final enabled = (await client.fetchMeta(projectId: target.id)).formats.join(', ');
      throw CliException('${target.describe} serves $enabled, not "${adoption.format}", '
          'and init wrote nothing: link another project, create one with '
          '${argument('create')}, or pass ${argument('format')} $enabled if your '
          'files are in it.',
          code: 'output_format_conflict');
    }
    final have = {for (final language in meta.languages) language.code};
    add ??= _codes(prompt?.call('Target languages to add, comma-separated '
        '(${have.isEmpty ? 'none yet' : 'has ${have.join(', ')}'})'));
    for (final code in add) {
      if (have.contains(code)) continue;
      await client.addLanguage(projectId: target.id, code: code);
      onStep(InitStep('added', 'language $code', 'to ${target.describe}'));
    }
    await adoption.apply(client, target.id, CliLogger(out: logger.out, err: logger.err)
      ..outputQuiet = true);
    onStep(InitStep(adoption.created ? 'enabled' : 'ok', 'format ${adoption.format}',
        adoption.created ? 'on ${target.describe}' : 'already enabled'));
    return target;
  }

  AccountWorkspace _workspace(List<AccountWorkspace> all, String? flag) {
    if (flag != null) {
      final name = flag.startsWith('@') ? flag.substring(1) : flag;
      for (final w in all) {
        if (w.handle == name || w.id == name) return w;
      }
      throw CliException('No workspace "$flag" for this login. Yours: '
          '${all.map((w) => w.describe).join(', ')}.');
    }
    if (all.length == 1) return all.single;
    final i = _choose('Workspace',
        [for (final w in all) '${w.describe}  ${w.name ?? ''} (${w.role})']);
    return i == null ? throw _missingRef : all[i];
  }

  AccountProject? _project(AccountWorkspace ws, String? flag, bool create) {
    if (flag != null) {
      for (final row in ws.projects) {
        if (row.slug == flag || row.id == flag) return row;
      }
      if (create) return null;
      throw CliException('No project "$flag" in ${ws.describe}: pass --create to '
          'create it${_linkable(ws)}.');
    }
    if (create) return null;
    final i = _choose('Project',
        [for (final row in ws.projects) '${row.describe}  ${row.name ?? ''}'],
        extra: 'a new project');
    if (i == null) throw _missingRef;
    return i == ws.projects.length ? null : ws.projects[i];
  }

  Future<AccountProject> _create(AccountWorkspace ws, String root,
      StackAdapter adapter, StackConfigDefaults defaults, String? slug,
      String? named, List<String>? languages, String? base) async {
    final folder = p.basename(p.normalize(p.absolute(root)));
    final name = named ?? slug ?? _ask('Project name [$folder]') ?? folder;
    final baseCode = base ?? detectBase(root, defaults) ??
        _ask('Base language (e.g. en)') ??
        (throw CliException('No base language in this project: pass ${argument('base')}.'));
    final targets = languages ?? _codes(_ask('Target languages, comma-separated '
        '(e.g. es,fr)'));
    final project = await client.createProject(workspaceId: ws.id, name: name,
        slug: slug, baseCode: baseCode, targetLanguages: targets,
        stack: adapter.stack == 'angular' ? 'web' : adapter.stack);
    onStep(InitStep('created', 'project ${project.describe}', 'in ${ws.describe}, '
        'base $baseCode${targets.isEmpty ? '' : ', targets ${targets.join(', ')}'}'));
    return project;
  }

  /// The Free cap: the server's message, the page that lifts it, and on a
  /// terminal the projects the workspace already has, to link one instead.
  AccountProject _afterPlanLimit(AccountWorkspace ws, ApiException e) {
    final why = '${e.message} Upgrade under Workspace > Billing in the dashboard';
    if (prompt != null && ws.projects.isNotEmpty) {
      logger.warn('$why, or link one of its projects.');
      final i = _choose('Project to link',
          [for (final row in ws.projects) '${row.describe}  ${row.name ?? ''}']);
      if (i != null) return ws.projects[i];
    }
    throw ApiException('$why${_linkable(ws)}',
        statusCode: e.statusCode, code: e.code, details: e.details);
  }

  /// The index of the option the person picked, or null without an answer.
  int? _choose(String what, List<String> options, {String? extra}) {
    if (prompt == null) return null;
    final all = [...options, ?extra];
    for (final (i, option) in all.indexed) {
      logger.info('  ${i + 1}) $option');
    }
    final answer = int.tryParse(prompt!('$what [1-${all.length}]')?.trim() ?? '');
    return answer == null || answer < 1 || answer > all.length ? null : answer - 1;
  }

  String? _ask(String label) {
    final answer = prompt?.call(label)?.trim();
    return answer == null || answer.isEmpty ? null : answer;
  }

  String _linkable(AccountWorkspace ws) => ws.projects.isEmpty ? ''
      : '; to link one, pass ${argument('project')} with '
          '${ws.projects.map((row) => row.slug ?? row.id).join(', ')}';

  static String _flag(String name) => '--$name';

  static List<String> _codes(String? raw) =>
      [for (final code in (raw ?? '').split(',')) if (code.trim().isNotEmpty) code.trim()];

  static CliException get _missingRef => CliException('Missing project ref. Pass '
      '--workspace and --project (add --create to create it), or run '
      "'easyi18n init' in a terminal.");
}

/// The base language the tree already declares: the `sourceLanguage` of the
/// Xcode catalog, or the locale that names the source file (`en.json`,
/// `app_en.arb`). Null when there is none, or it cannot be read.
String? detectBase(String root, StackConfigDefaults defaults) {
  try {
    if (defaults.catalog case final catalog?) {
      return xcstringsCatalogSummary(File(p.join(root, catalog)).readAsStringSync())
          ?.sourceLanguage;
    }
    final name = defaults.source == null ? null
        : p.basenameWithoutExtension(defaults.source!).split('_').last;
    return name != null && RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(name)
        ? name : null;
  } on FileSystemException {
    return null;
  }
}
