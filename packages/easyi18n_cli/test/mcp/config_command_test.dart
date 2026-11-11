@TestOn('vm')
library;

import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:test/test.dart';

import '../support/transcript.dart';

// Pinned to the binary that prints it: while npm's `latest` trailed `next`, an
// unpinned snippet printed by rc.4 installed rc.1 (#1930).
const _npx = ['npx', '-y', '@easyi18n.com/cli@$packageVersion', 'mcp'];
const _dart = ['dart', 'pub', 'global', 'run', 'easyi18n_cli:easyi18n', 'mcp'];

/// Where each client's JSON keeps its servers, from each client's own docs
/// (2026-09-23). Written here rather than read from the renderer, so a wrong
/// key there cannot agree with itself.
const _jsonServers = {
  'claude-desktop': 'mcpServers',
  'cursor': 'mcpServers',
  'vscode': 'servers',
  'gemini': 'mcpServers',
  'windsurf': 'mcpServers',
  'zed': 'context_servers',
  'generic': 'mcpServers',
};

/// The clients whose file lives in the repo, where a key would be committed.
const _projectFiles = ['cursor', 'vscode', 'gemini'];

Future<({int code, Transcript transcript})> _invoke(
  List<String> args, {
  Map<String, String>? environment,
}) async {
  final transcript = Transcript();
  final runner = Easyi18nCommandRunner(
    logger: CliLogger(out: transcript.out, err: transcript.err),
    environment: environment,
  );
  final code = await runner.run(args);
  return (code: code ?? 0, transcript: transcript);
}

Future<Map<String, dynamic>> _record(String client,
    {String? runner, bool agentKey = false}) async {
  final result = await _invoke([
    '--json',
    'mcp',
    'config',
    '--client',
    client,
    if (runner != null) ...['--runner', runner],
    if (agentKey) '--agent-key',
  ]);
  expect(result.code, 0);
  final records = result.transcript.records;
  expect(records, hasLength(1));
  expect(records.single.channel, 'out');
  return jsonDecode(records.single.line) as Map<String, dynamic>;
}

void main() {
  for (final (runner, agentKey) in [
    for (final runner in [(null, _npx), ('dart', _dart)])
      for (final agentKey in [false, true]) (runner, agentKey),
  ]) {
    final label = '${runner.$1 ?? 'npx (default)'}${agentKey ? ', --agent-key' : ''}';
    final argv = [...runner.$2, if (agentKey) '--require-agent-key'];
    group('runner $label', () {
      for (final MapEntry(key: client, value: key) in _jsonServers.entries) {
        test('$client prints JSON that launches the server', () async {
          final record = await _record(client, runner: runner.$1, agentKey: agentKey);
          expect(record['agent_key'], agentKey);
          expect(record['format'], 'json');
          final snippet = jsonDecode(record['snippet'] as String) as Map;
          final server = (snippet[key] as Map)['easyi18n'] as Map;
          expect([server['command'], ...server['args'] as List], argv);
        });
      }

      test('codex prints a TOML table, forwarding the key only with one', () async {
        final record = await _record('codex', runner: runner.$1, agentKey: agentKey);
        expect(record['format'], 'toml');
        expect((record['snippet'] as String).split('\n'), [
          '[mcp_servers.easyi18n]',
          'command = "${runner.$2.first}"',
          'args = [${argv.skip(1).map((a) => '"$a"').join(', ')}]',
          if (agentKey) 'env_vars = ["EASYI18N_TOKEN"]',
          // A cold `npx` took 19.9 s against Codex's 10 s default (#1930).
          'startup_timeout_sec = 60',
          'required = true',
          'omit_tools_from = ["deferred"]',
        ]);
      });

      test('claude-code prints one `claude mcp add` command', () async {
        final record = await _record('claude-code', runner: runner.$1, agentKey: agentKey);
        expect(record['format'], 'shell');
        expect(
          record['snippet'],
          'claude mcp add ${agentKey ? '--env EASYI18N_TOKEN=eik_YOUR_AGENT_KEY ' : ''}'
          '--transport stdio easyi18n -- ${argv.join(' ')}',
        );
      });
    });
  }

  test('without --agent-key no snippet names a key: the server sends the login',
      () async {
    for (final client in [..._jsonServers.keys, 'codex', 'claude-code']) {
      for (final runner in ['npx', 'dart']) {
        final record = await _record(client, runner: runner);
        expect(record['snippet'], isNot(contains('EASYI18N_TOKEN')), reason: client);
        expect(record['snippet'], isNot(contains('eik_')), reason: client);
        expect(record['target'], isNot(contains('EASYI18N_TOKEN')), reason: client);
        if (_jsonServers[client] case final key?) {
          final snippet = jsonDecode(record['snippet'] as String) as Map;
          final server = (snippet[key] as Map)['easyi18n'] as Map;
          expect(server['env'],
              ['cursor', 'vscode'].contains(client)
                  ? {'EASYI18N_PROJECT_DIR': r'${workspaceFolder}'}
                  : isNull,
              reason: client);
          expect(snippet.containsKey('inputs'), isFalse, reason: client);
        }
      }
    }
  });

  test('a file that lives in the repo never carries a key', () async {
    for (final client in _projectFiles) {
      final record = await _record(client, agentKey: true);
      expect(
        record['snippet'],
        isNot(contains(RegExp(r'eik_\w'))),
        reason: client,
      );
      final snippet = jsonDecode(record['snippet'] as String) as Map;
      final server = (snippet[_jsonServers[client]] as Map)['easyi18n'] as Map;
      expect(
        (server['env'] as Map)['EASYI18N_TOKEN'],
        contains(r'$'),
        reason: '$client reads the key from somewhere else',
      );
    }
  });

  test('vscode asks for the agent key through a password input', () async {
    final record = await _record('vscode', agentKey: true);
    final snippet = jsonDecode(record['snippet'] as String) as Map;
    final input = (snippet['inputs'] as List).single as Map;
    expect(input['type'], 'promptString');
    expect(input['password'], isTrue);
    final server = (snippet['servers'] as Map)['easyi18n'] as Map;
    expect(server['type'], 'stdio');
    expect(
      (server['env'] as Map)['EASYI18N_TOKEN'],
      '\${input:${input['id']}}',
    );
  });

  test("never writes the caller's own key into a snippet", () async {
    const live = 'eik_live_0123456789abcdef';
    for (final client in [..._jsonServers.keys, 'codex', 'claude-code']) {
      for (final agentKey in [false, true]) {
        final result = await _invoke(
          ['mcp', 'config', '--client', client, if (agentKey) '--agent-key'],
          environment: {'EASYI18N_TOKEN': live},
        );
        final text = result.transcript.records.map((r) => r.line).join('\n');
        expect(text, isNot(contains('live_0123')), reason: client);
      }
    }
  });

  test(
    'text mode prints only the snippet on stdout, where it goes on stderr',
    () async {
      final record = await _record('codex');
      final result = await _invoke(['mcp', 'config', '--client', 'codex']);
      expect(result.code, 0);
      final out = result.transcript.records.where((r) => r.channel == 'out');
      final err = result.transcript.records.where((r) => r.channel == 'err');
      expect(out.map((r) => r.line).join('\n'), record['snippet']);
      expect(err.map((r) => r.line).join('\n'), contains(record['target']));
      expect(err.last.line, "The server sends this machine's easyi18n login. For CI, "
          'or an agent whose spending waits for approval, pass --agent-key.');
      expect(record['target'], 'Append it to ~/.codex/config.toml.');
      final keyed = await _invoke(['mcp', 'config', '--client', 'codex', '--agent-key']);
      expect(keyed.transcript.records.where((r) => r.channel == 'err').map((r) => r.line),
          ['Append it to ~/.codex/config.toml. Codex forwards EASYI18N_TOKEN from the '
              'shell it runs in.']);
    },
  );

  test('an unknown client is a usage error naming the allowed ones', () async {
    await expectLater(
      _invoke(['mcp', 'config', '--client', 'notepad']),
      throwsA(
        isA<UsageException>().having(
          (e) => e.toString(),
          'toString',
          contains('claude-desktop'),
        ),
      ),
    );
    await expectLater(
      _invoke(['mcp', 'config']),
      throwsA(isA<UsageException>()),
    );
  });

  test('a mistyped subcommand is a usage error, not a server', () async {
    await expectLater(
      _invoke(['mcp', 'conifg']),
      throwsA(
        isA<UsageException>().having(
          (e) => e.message,
          'message',
          contains('conifg'),
        ),
      ),
    );
  });
}
