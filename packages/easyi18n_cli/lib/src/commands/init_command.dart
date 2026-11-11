import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../adapters/stack_adapter.dart';
import '../adapters/stack_adapters.dart' show supportedStacks;
import '../api_client.dart';
import '../cli_output.dart';
import '../config.dart';
import '../exceptions.dart';
import '../init_online.dart';
import '../init_runner.dart';
import '../logger.dart';
import '../security.dart';
import '../session.dart';
import 'pull_command.dart' show ApiClientFactory;

/// Text and JSON presentation of project setup.
class InitCommand extends Command<int> with JsonPresenter {
  InitCommand({required this.output, Prompt? prompt,
      ApiClientFactory? apiClientFactory, Map<String, String>? environment})
    : _prompt = prompt ?? (stdin.hasTerminal ? _terminalPrompt : null),
      _factory = apiClientFactory ?? _client,
      _environment = environment ?? Platform.environment {
    argParser
      ..addOption('stack',
        help: 'Stack adapter (${supportedStacks.join(', ')}), or auto to '
            'detect the project stack. Left out, init sets up the stack '
            'doctor checks: the detected one, else the one an existing '
            'easyi18n.yaml declares, else flutter.')
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
      )
      ..addFlag('create', negatable: false,
        help: 'With your easyi18n login: create the project --project names '
            '(or one named after this directory) when it does not exist.')
      ..addOption('languages',
        help: 'With your easyi18n login: target languages to add, comma-separated '
            '(es,fr).')
      ..addOption('base',
        help: 'The base language of a project init creates, when the tree does '
            'not declare one.')
      ..addFlag('ci', negatable: false,
        help: 'Mint an API key for CI on this project, print it once and the '
            'gh secret set line. Needs your easyi18n login.');
  }

  final CliOutput output;
  CliLogger get _logger => output.logger;
  final Prompt? _prompt;
  final ApiClientFactory _factory;
  final Map<String, String> _environment;

  @override
  String get name => 'init';

  @override
  String get description =>
      'Set up this project for easyi18n using its stack adapter.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final dryRun = results['dry-run'] as bool;
    final configPath = globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final create = results.flag('create'), ci = results.flag('ci');
    final languages = results.option('languages'), base = results.option('base');
    final setup = create || languages != null || base != null;
    if (dryRun && (setup || ci)) {
      usageException('--dry-run writes nothing on the server: drop --create, '
          '--languages, --base and --ci.');
    }
    final fresh = results.flag('force') || !File(configPath).existsSync();
    if (setup && !fresh) {
      throw CliException('easyi18n.yaml already names a project, so --create, '
          "--languages and --base have nothing to set up. Use 'easyi18n languages "
          "add', or --force to start over.");
    }
    // Only an explicit --base-url: its default would read as another origin
    // on every re-run over an emulator config.
    final flagBaseUrl = results.wasParsed('base-url') ? results['base-url'] as String? : null;
    final origin = flagBaseUrl == null ? Easyi18nConfig.originFrom(_environment)
        : Easyi18nConfig.trimBaseUrl(flagBaseUrl);
    final found = findCredential(environment: _environment, baseUrl: origin);
    final adapter = initAdapter(configPath, stack: results['stack'] as String?);
    final online = fresh && !dryRun && results['project-id'] == null && (setup ||
        (results['workspace'] == null && results['project'] == null && found?.login != null));
    final before = <InitStep>[];
    final linked = online ? await _setUp(origin, found?.token, configPath, adapter,
        results, before) : null;
    final report = InitRunner().run(
      configPath: configPath, adapter: adapter, before: before,
      logger: _logger,
      workspace: linked == null ? results['workspace'] as String?
          : linked.hasHandle ? linked.workspace : null,
      project: linked == null ? results['project'] as String?
          : linked.hasHandle ? linked.slug : null,
      projectId: linked == null ? results['project-id'] as String?
          : linked.hasHandle ? null : linked.id,
      baseUrl: linked == null ? flagBaseUrl : origin,
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
      prompt: output.json ? null : _prompt,
      onStep: output.json ? null : (step) => _replay(step, dryRun),
    );
    final key = ci ? await _mintCiKey(configPath) : null;
    if (output.json) {
      // Every other secret-shaped string is redacted; the key --ci asked for
      // is the one thing this record exists to carry.
      final record = sanitizeJson({...report.toJson(), 'ci': ?key}) as Map<String, Object?>;
      if (key != null) (record['ci'] as Map)['raw_key'] = key['raw_key'];
      _logger.out.writeln(jsonEncode(record));
    } else {
      final login = findCredential(environment: _environment, baseUrl: report.baseUrl)?.login;
      _logger.info(dryRun ? 'Dry run - nothing written.'
          : login != null ? "Done. Run 'easyi18n ${report.next}'."
          : "Done. Set EASYI18N_TOKEN, then run 'easyi18n ${report.next}'.");
    }
    return 0;
  }

  /// The online half (#2584): what the login can see, picked on the terminal
  /// or by the flags, set up on the server before any file is written.
  Future<AccountProject> _setUp(String origin, String? token, String configPath,
      StackAdapter adapter, ArgResults results, List<InitStep> before) async {
    warnOnUntrustedTarget(origin, _logger);
    final client = _factory(baseUrl: origin, token: token ?? requireCredential(
        environment: _environment, baseUrl: origin,
        need: 'Creating or linking a project needs your easyi18n login.'));
    try {
      return await OnlineInit(client: client, logger: _logger,
          prompt: output.json ? null : _prompt,
          onStep: (step) {
            before.add(step);
            if (!output.json) _replay(step, false);
          }).run(root: p.dirname(configPath), adapter: adapter,
          mode: results['mode'] as String?,
          format: results.wasParsed('format') ? results['format'] as String? : null,
          workspace: results['workspace'] as String?,
          project: results['project'] as String?, create: results.flag('create'),
          languages: results.option('languages'), base: results.option('base'));
    } finally {
      client.close();
    }
  }

  /// `--ci`: a key CI keeps in `EASYI18N_TOKEN`, minted by the login for the
  /// project the config names. The server shows the secret once; so does this.
  Future<Map<String, Object?>> _mintCiKey(String configPath) async {
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);
    final key = await withProject(config: config, logger: _logger,
        apiClientFactory: _factory,
        token: requireCredential(environment: _environment, baseUrl: config.baseUrl,
            need: 'Minting a CI key needs your easyi18n login.'),
        body: (client, projectId) => client.mintApiKey(projectId: projectId,
            label: 'CI (easyi18n init)',
            scopes: const ['read', 'write', 'translate', 'publish']));
    // Printed raw, past the logger's redaction, so only an API key's shape.
    if (!RegExp(r'^eik_[A-Za-z0-9_-]{16,}$').hasMatch(key.rawKey)) {
      throw FatalCliException('Unexpected response from ${config.baseUrl}: the '
          'minted key is not an API key. Revoke it under Settings > API keys.');
    }
    if (!output.json) {
      _logger.info('CI key for ${config.describeRef}, shown only now:');
      _logger.out.writeln('  ${key.rawKey}');
      _logger.info('Store it as the repository secret EASYI18N_TOKEN (gh asks '
          'for the value):');
      _logger.info('  gh secret set EASYI18N_TOKEN');
    }
    return {'id': key.id, 'prefix': key.prefix, 'raw_key': key.rawKey};
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

  static TranslationsApiClient _client({required String baseUrl,
      required String token}) => TranslationsApiClient(baseUrl: baseUrl, token: token);

  static String? _terminalPrompt(String label) {
    stdout.write('$label: ');
    return stdin.readLineSync();
  }
}
