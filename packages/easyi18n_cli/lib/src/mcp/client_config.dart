import 'dart:convert';

import '../version.dart';

/// How a client starts `easyi18n mcp`: the npm wrapper, which needs no Dart
/// SDK (D11), or the package activated with `dart pub global activate`.
///
/// The npm one installs the version that printed the snippet, as the plugin's
/// `cli-version` does: unpinned, it followed npm's `latest`, which can trail
/// the binary that printed it (rc.1 under rc.4, #1930).
enum McpRunner {
  npx(['npx', '-y', '@easyi18n.com/cli@$packageVersion', 'mcp']),
  dart(['dart', 'pub', 'global', 'run', 'easyi18n_cli:easyi18n', 'mcp']);

  const McpRunner(this.argv);

  final List<String> argv;
}

const _server = 'easyi18n';
const _token = 'EASYI18N_TOKEN';
const _projectDir = 'EASYI18N_PROJECT_DIR';

/// What a file in the user's home carries where the client cannot read the key
/// from its environment. It is never the caller's key: a snippet gets pasted
/// into chats and docs, so `mcp config` does not read `EASYI18N_TOKEN` at all.
const keyPlaceholder = 'eik_YOUR_AGENT_KEY';

/// One MCP client and the snippet that registers the server in it (D9). A
/// file that lives in the repo (Cursor, VS Code, Gemini) reads the key through
/// the client's own interpolation, so committing it commits no key.
enum McpClient {
  claudeCode(
    'claude-code',
    'Claude Code',
    'shell',
    'Run it in a terminal in the project. It registers the server in local '
        'scope, which stays out of the repo.',
  ),
  claudeDesktop(
    'claude-desktop',
    'Claude Desktop',
    'json',
    'Merge it into claude_desktop_config.json (Settings, Developer, Edit '
        'Config) and restart Claude. Claude Desktop has no project, so the agent '
        'names one with project_dir.',
  ),
  cursor(
    'cursor',
    'Cursor',
    'json',
    'Merge it into .cursor/mcp.json in the project. Cursor reads '
        'EASYI18N_TOKEN from the environment it was started in.',
  ),
  vscode(
    'vscode',
    'VS Code',
    'json',
    'Merge it into .vscode/mcp.json in the project. VS Code asks for the key '
        'once and stores it.',
  ),
  codex(
    'codex',
    'Codex CLI',
    'toml',
    'Append it to ~/.codex/config.toml. Codex forwards EASYI18N_TOKEN from '
        'the shell it runs in.',
  ),
  gemini(
    'gemini',
    'Gemini CLI',
    'json',
    'Merge it into .gemini/settings.json in the project. Gemini CLI reads '
        'EASYI18N_TOKEN from the shell it runs in.',
  ),
  windsurf(
    'windsurf',
    'Windsurf',
    'json',
    "Merge it into Windsurf's mcp_config.json.",
  ),
  zed('zed', 'Zed', 'json', "Merge it into Zed's user settings.json."),
  generic(
    'generic',
    'Any other MCP client',
    'json',
    "Merge it into the client's MCP config: most read this mcpServers "
        'shape.',
  );

  const McpClient(this.id, this.label, this.format, this.target);

  /// The `--client` value.
  final String id;
  final String label;

  /// `json`, `toml` or `shell`.
  final String format;

  /// Where the snippet goes, for a human.
  final String target;

  String snippet(McpRunner runner) {
    final command = runner.argv.first;
    final args = runner.argv.sublist(1);
    Map<String, Object?> entry(Map<String, String> env) => {
      'command': command,
      'args': args,
      'env': env,
    };
    const literal = {_token: keyPlaceholder};
    return switch (this) {
      claudeCode =>
        'claude mcp add --env $_token=$keyPlaceholder '
            '--transport stdio $_server -- ${runner.argv.join(' ')}',
      codex => [
        '[mcp_servers.$_server]',
        'command = ${jsonEncode(command)}',
        'args = [${args.map(jsonEncode).join(', ')}]',
        'env_vars = ["$_token"]',
        // Codex gives a server 10 s to start; a cold `npx` took 19.9 s.
        'startup_timeout_sec = 60',
        'required = true',
        'omit_tools_from = ["deferred"]',
      ].join('\n'),
      vscode => _json({
        'inputs': [
          {
            'type': 'promptString',
            'id': 'easyi18n-token',
            'description': 'easyi18n AI agent key (eik_)',
            'password': true,
          },
        ],
        'servers': {
          _server: {
            'type': 'stdio',
            ...entry({
              _token: r'${input:easyi18n-token}',
              _projectDir: r'${workspaceFolder}',
            }),
          },
        },
      }),
      cursor => _json({
        'mcpServers': {
          _server: entry({
            _token: '\${env:$_token}',
            _projectDir: r'${workspaceFolder}',
          }),
        },
      }),
      gemini => _json({
        'mcpServers': {
          _server: entry({_token: '\$$_token'}),
        },
      }),
      zed => _json({
        'context_servers': {_server: entry(literal)},
      }),
      claudeDesktop || windsurf || generic => _json({
        'mcpServers': {_server: entry(literal)},
      }),
    };
  }

  static String _json(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}
