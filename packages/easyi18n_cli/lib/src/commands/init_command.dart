import 'dart:io';

import 'package:args/command_runner.dart';

import '../adapters/stack_adapters.dart' show defaultStack, supportedStacks;
import '../cli_output.dart';
import '../config.dart';
import '../init_runner.dart';
import '../logger.dart';

/// Text and JSON presentation of project setup.
class InitCommand extends Command<int> with JsonPresenter {
  InitCommand({required this.output, Prompt? prompt})
    : _prompt = prompt ?? _terminalPrompt {
    argParser
      ..addOption('stack', defaultsTo: defaultStack,
        help: 'Stack adapter (${supportedStacks.join(', ')}), or auto to '
            'detect the project stack.')
      ..addOption(
        'workspace',
        help:
            'The workspace handle (the @handle segment of your project '
            'URL). Use with --project.',
      )
      ..addOption(
        'project',
        help:
            'The project slug (unique within the workspace). Use with '
            '--workspace.',
      )
      ..addOption(
        'project-id',
        help:
            'The opaque easyi18n project id (legacy; prefer '
            '--workspace/--project).',
      )
      ..addOption(
        'base-url',
        help: 'Backend origin.',
        defaultsTo: Easyi18nConfig.defaultBaseUrl,
      )
      ..addOption(
        'format',
        help: 'Output format (arb, json, po, ...). A file-first stack picks '
            'its own when this is left alone.',
        defaultsTo: Easyi18nConfig.defaultFormat,
      )
      ..addOption(
        'output',
        help: 'Directory to write files into.',
        defaultsTo: Easyi18nConfig.defaultOutput,
      )
      ..addOption(
        'catalog',
        help: 'Path to the translation catalog `easyi18n sync` uploads and '
            'writes back (file-first stacks). Detected when omitted.',
      )
      ..addOption(
        'mode',
        allowed: ['a', 'b'],
        help:
            "Integration mode: 'a' keeps your gen_l10n setup (config + "
            ".gitignore only, no runtime scaffolding); 'b' wires the runtime "
            'SDK. Detected from l10n.yaml when omitted.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        negatable: false,
        help: 'Rewrite an existing easyi18n.yaml from the flags.',
      )
      ..addFlag(
        'agents',
        defaultsTo: true,
        help: 'Write the easyi18n block into AGENTS.md, for coding agents '
            'without MCP. Never touches CLAUDE.md or .cursorrules.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Report what would change without writing anything.',
      );
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final Prompt _prompt;

  @override
  String get name => 'init';

  @override
  String get description =>
      'Set up this project for easyi18n using its stack adapter.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final dryRun = results['dry-run'] as bool;
    final report = InitRunner().run(
      configPath: globalResults?['config'] as String? ?? Easyi18nConfig.fileName,
      logger: _logger, workspace: results['workspace'] as String?,
      project: results['project'] as String?, projectId: results['project-id'] as String?,
      // Only an explicit --base-url: its default would read as another origin
      // on every re-run over an emulator config.
      baseUrl: results.wasParsed('base-url') ? results['base-url'] as String? : null,
      // Only an EXPLICIT --format outranks the stack's own: `defaultsTo` makes
      // the two indistinguishable at the runner, and 'arb' would then silently
      // win over `xcstrings` on every file-first init.
      format: results.wasParsed('format') ? results['format'] as String? : null,
      // The same for --output: a stack that detects its own directory must
      // not lose it to this option's default.
      output: results.wasParsed('output') ? results['output'] as String? : null,
      mode: results['mode'] as String?,
      catalog: results['catalog'] as String?,
      force: results['force'] as bool, dryRun: dryRun,
      writeAgents: results['agents'] as bool,
      stack: results['stack'] as String,
      prompt: output.json ? null : _prompt,
      onStep: output.json ? null : (step) => _replay(step, dryRun),
    );
    if (output.json) {
      output.emit(report.toJson());
    } else {
      _logger.info(dryRun ? 'Dry run - nothing written.'
          : "Done. Set EASYI18N_TOKEN, then run 'easyi18n ${report.next}'.");
    }
    return 0;
  }

  void _replay(InitStep step, bool dryRun) {
    const wouldForms = {
      'created': 'would create', 'patched': 'would patch', 'rewrote': 'would rewrite',
      'updated': 'would update',
    };
    final prefix = dryRun ? (wouldForms[step.verb] ?? step.verb) : step.verb;
    _logger.detail('$prefix  ${step.target} - ${step.detail}');
    if (step.scopeSnippet != null) _logger.info(step.scopeSnippet!);
  }

  /// Asks for a value on the terminal. Returns null when stdin is not a TTY so
  /// the caller can fail (required) instead of blocking on `readLineSync`.
  static String? _terminalPrompt(String label) {
    if (!stdin.hasTerminal) return null;
    stdout.write('$label: ');
    return stdin.readLineSync();
  }
}
