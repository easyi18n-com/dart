@TestOn('vm')
library;

import 'dart:io';

import 'package:easyi18n_cli/src/mcp/client_config.dart';
import 'package:test/test.dart';

/// The public "Connect your AI" page is written by hand, so nothing but this
/// test ties its snippets to what `easyi18n mcp config --client` prints. CI runs
/// the `cli` job for a change to that page (ci.yml, tool/analyze.sh).
const pagePath = '../../docs-site/docs/developers/agents/connect-your-ai.md';

final _fence = RegExp(
  r'^```[a-z]*\n(.*?)\n```$',
  multiLine: true,
  dotAll: true,
);

List<String> _blocks(String page) => [
  for (final m in _fence.allMatches(page.replaceAll('\r\n', '\n'))) m[1]!,
];

String pageSnippet(McpClient client, McpRunner runner, {required bool agentKey}) =>
    client.snippet(runner, agentKey: agentKey);

void main() {
  late List<String> blocks;
  setUpAll(() => blocks = _blocks(File(pagePath).readAsStringSync()));

  test('the page carries the npx snippet of every client', () {
    for (final client in McpClient.values) {
      expect(
        blocks,
        contains(pageSnippet(client, McpRunner.npx, agentKey: true)),
        reason:
            '${client.id}: run `easyi18n mcp config --client '
            '${client.id} --agent-key` and paste its snippet',
      );
    }
  });

  test('every server snippet on the page is one `mcp config` prints', () {
    final printed = {
      for (final client in McpClient.values)
        for (final runner in McpRunner.values)
          for (final agentKey in [false, true])
            pageSnippet(client, runner, agentKey: agentKey),
    };
    // What each runner launches: the argument before `mcp`.
    final launched = [
      for (final runner in McpRunner.values)
        runner.argv[runner.argv.length - 2],
    ];
    final servers = blocks.where((b) => launched.any(b.contains));
    expect(servers, isNotEmpty);
    for (final block in servers) {
      expect(printed, contains(block), reason: 'hand-edited snippet:\n$block');
    }
  });
}
