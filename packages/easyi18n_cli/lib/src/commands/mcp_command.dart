import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_mcp/stdio.dart';

import '../cli_output.dart';
import '../exceptions.dart';
import '../extract/tr_extractor.dart';
import '../logger.dart';
import '../mcp/client_config.dart';
import '../mcp/deps.dart';
import '../mcp/server.dart';
import '../session.dart' show findCredential;
import 'pull_command.dart' show ApiClientFactory;

/// `easyi18n mcp` — the stdio MCP server (D1, D2).
///
/// stdout is the JSON-RPC wire, so nothing else may ever be written to it: the
/// logger this command builds goes to stderr, the interactive hooks are
/// neutralized (a server has no terminal to confirm on), and the process is
/// never torn down with `exit()`, which would drop buffered frames.
class McpCommand extends Command<int> {
  McpCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    TrExtractor? extractor,
    Map<String, String>? environment,
  }) : _apiClientFactory = apiClientFactory,
       _extractor = extractor,
       _environment = environment ?? Platform.environment {
    argParser.addFlag('require-agent-key', negatable: false,
        help: 'Require an API key in EASYI18N_TOKEN and disable personal login.');
    addSubcommand(McpConfigCommand(output: output));
  }

  final CliOutput output;
  final ApiClientFactory? _apiClientFactory;
  final TrExtractor? _extractor;
  final Map<String, String> _environment;

  @override
  String get name => 'mcp';

  @override
  String get description =>
      'Run the easyi18n MCP server on stdio, for an AI agent to drive.';

  @override
  String get invocation => 'easyi18n mcp [config]';

  /// Runs the server. The runner calls this for a bare `easyi18n mcp`: with a
  /// subcommand registered, `package:args` refuses to run the parent itself.
  Future<int> serve({required String configPath, required bool requireAgentKey}) async {
    if (requireAgentKey) {
      final key = findCredential(environment: _environment, baseUrl: null)?.token;
      if (key == null || !key.startsWith('eik_')) {
        throw CliException('Set EASYI18N_TOKEN to an AI agent key before starting the MCP server.',
            code: 'agent_key_required');
      }
    }
    final server = Easyi18nMcpServer.fromStreamChannel(
      stdioChannel(input: stdin, output: stdout),
      deps: McpDeps(
        logger: CliLogger(out: stderr, err: stderr),
        environment: _environment,
        configFileName: configPath,
        apiClientFactory: _apiClientFactory,
        extractor: _extractor,
      ),
    );
    await server.done;
    await stdout.flush();
    return 0;
  }
}

/// `easyi18n mcp config --client <x>`: the snippet that registers the server
/// in one MCP client. stdout carries only the snippet, so it can be piped or
/// appended; where it goes is on stderr.
class McpConfigCommand extends Command<int> with JsonPresenter {
  McpConfigCommand({required this.output}) {
    argParser
      ..addOption(
        'client',
        allowed: [for (final client in McpClient.values) client.id],
        help: 'The MCP client to print the snippet for.',
      )
      ..addOption(
        'runner',
        allowed: [for (final runner in McpRunner.values) runner.name],
        defaultsTo: McpRunner.npx.name,
        allowedHelp: {
          'npx': 'The npm package @easyi18n.com/cli; needs Node, no Dart SDK.',
          'dart':
              'The package activated with '
              '`dart pub global activate easyi18n_cli`.',
        },
      )
      ..addFlag(
        'agent-key',
        negatable: false,
        help: 'Have the server send an AI agent key (eik_), for CI or an agent '
            'whose spending waits for approval. Left out, it sends your '
            'easyi18n login.',
      );
  }

  final CliOutput output;

  @override
  String get name => 'config';

  @override
  String get description =>
      'Print the snippet that registers the MCP server in an AI client.';

  @override
  Future<int> run() async {
    final id = argResults!.option('client');
    if (id == null) usageException('--client is required.');
    final client = McpClient.values.firstWhere((c) => c.id == id);
    final runner = McpRunner.values.byName(argResults!.option('runner')!);
    final agentKey = argResults!.flag('agent-key');
    final snippet = client.snippet(runner, agentKey: agentKey);
    final target = client.target(agentKey: agentKey);
    if (output.json) {
      output.emit({
        'client': client.id,
        'runner': runner.name,
        'format': client.format,
        'target': target,
        'snippet': snippet,
        'agent_key': agentKey,
      });
      return 0;
    }
    output.logger.err.writeln(target);
    if (!agentKey) {
      output.logger.err.writeln("The server sends this machine's easyi18n login. "
          'For CI, or an agent whose spending waits for approval, pass --agent-key.');
    }
    output.logger.info(snippet);
    return 0;
  }
}
