// Writes the files under `integrations/agents/` that the CLI is the source of
// (D9), so what the public agents repo ships and what the CLI says cannot
// disagree. Run from the package root:
//
//   dart run tool/gen_agent_integrations.dart           # regenerate
//   dart run tool/gen_agent_integrations.dart --check   # CI: fail if it drifted
//
// A missing file is drift, not a pass: a check that goes quiet when it cannot
// find what it guards is the failure `sync_contract.dart` was written against.
import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/mcp/client_config.dart';
import 'package:easyi18n_cli/src/mcp/prompts.dart';
import 'package:path/path.dart' as p;

const integrationsRoot = '../../integrations/agents';

const _fences = {'json': 'json', 'toml': 'toml', 'shell': 'sh'};

String renderClientsReadme() {
  final out = StringBuffer()
    ..writeln('# Connect an MCP client')
    ..writeln()
    ..writeln('Generated from `easyi18n mcp config --client <client>` by')
    ..writeln('`packages/easyi18n_cli/tool/gen_agent_integrations.dart`. Edit')
    ..writeln('`packages/easyi18n_cli/lib/src/mcp/client_config.dart` and')
    ..writeln('regenerate: CI fails on a hand edit.')
    ..writeln()
    ..writeln('The first snippet of each client runs the npm package')
    ..writeln(
      '`@easyi18n.com/cli`, which needs Node and no Dart SDK. The second',
    )
    ..writeln(
      'runs the Dart package after `dart pub global activate easyi18n_cli`.',
    )
    ..writeln('`$keyPlaceholder` stands for an AI agent key, created in the')
    ..writeln(
      'dashboard: every spend, publish and rollback it makes waits for a',
    )
    ..writeln('human approval.');
  for (final client in McpClient.values) {
    final fence = _fences[client.format]!;
    out
      ..writeln()
      ..writeln('## ${client.label} (`${client.id}`)')
      ..writeln()
      ..writeln(client.target)
      ..writeln()
      ..writeln('```$fence')
      ..writeln(client.snippet(McpRunner.npx))
      ..writeln('```')
      ..writeln()
      ..writeln('With the Dart SDK:')
      ..writeln()
      ..writeln('```$fence')
      ..writeln(client.snippet(McpRunner.dart))
      ..writeln('```');
  }
  return out.toString();
}

typedef AgentSkill = ({String name, String description, String text});

const _skillsDir = 'claude-code/skills';

// What Claude Code matches a request against to load the skill on its own;
// the MCP prompt descriptions are for a client's prompt picker instead.
const _skillDescriptions = {
  'setup':
      'Set up easyi18n in this repository: detect the stack (Flutter, Xcode, '
      'web or Android), wire up the SDK and config, convert user-facing '
      'strings and show what would be translated. Use when the user wants to '
      'add easyi18n, internationalize or localize an app, or connect a '
      'project to easyi18n.',
  'translate':
      'Translate and publish with easyi18n: preview the credit spend, get '
      'the human approval in the dashboard, wait for the fill, publish and '
      'write the result back. Use when the user asks to translate strings, '
      'fill missing translations, publish or roll back translations, or add '
      'a language with easyi18n.',
};

/// The plugin skills: one per MCP prompt, with the prompt text as the body.
List<AgentSkill> agentSkills([List<McpPrompt>? prompts]) => [
  for (final (:prompt, :text) in prompts ?? mcpPrompts)
    (
      name: 'easyi18n-${prompt.name}',
      description:
          _skillDescriptions[prompt.name] ??
          (throw StateError('MCP prompt ${prompt.name} has no skill trigger')),
      text: text,
    ),
];

// The skill loader substitutes these in a SKILL.md body, and runs an inline
// !`cmd` or a ```! block in the user's shell (Claude Code 2.1.280).
final _loaderSubstitutes = RegExp(r'\$(ARGUMENTS|\d|\{)|!`|```!');

String renderSkill(AgentSkill skill) {
  if (_loaderSubstitutes.hasMatch(skill.text)) {
    throw StateError(
      'Skill ${skill.name}: Claude Code would rewrite or run '
      '"${_loaderSubstitutes.firstMatch(skill.text)![0]}" in its body',
    );
  }
  // A JSON string is YAML that holds any text, `: ` included.
  return '---\nname: ${skill.name}\n'
      'description: ${jsonEncode(skill.description)}\n---\n\n${skill.text}';
}

/// Every generated file, keyed by its path under [integrationsRoot].
Map<String, String> renderIntegrations() => {
  'clients/README.md': renderClientsReadme(),
  for (final skill in agentSkills())
    '$_skillsDir/${skill.name}/SKILL.md': renderSkill(skill),
};

/// Skill files under [root] that no prompt renders any more.
List<String> _orphanSkills(String root, Map<String, String> expected) {
  final dir = Directory(p.join(root, _skillsDir));
  if (!dir.existsSync()) return const [];
  return [
    for (final file in dir.listSync(recursive: true).whereType<File>())
      if (p.basename(file.path) == 'SKILL.md')
        p.posix.joinAll(p.split(p.relative(file.path, from: root))),
  ].where((relative) => !expected.containsKey(relative)).toList()..sort();
}

/// 0 when the files under [root] match the renderers (or were just written),
/// 1 when one drifted.
int run(
  List<String> args, {
  String root = integrationsRoot,
  StringSink? out,
  StringSink? err,
}) {
  out ??= stdout;
  err ??= stderr;
  final expected = renderIntegrations();
  final orphans = _orphanSkills(root, expected);
  if (!args.contains('--check')) {
    for (final relative in orphans) {
      File(p.join(root, relative)).parent.deleteSync(recursive: true);
      out.writeln('✓ removed $relative');
    }
    for (final MapEntry(key: relative, value: text) in expected.entries) {
      File(p.join(root, relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);
      out.writeln('✓ wrote $relative');
    }
    return 0;
  }
  final drifted = [
    for (final MapEntry(key: relative, value: text) in expected.entries)
      if (_read(File(p.join(root, relative))) != text) relative,
  ];
  if (drifted.isEmpty && orphans.isEmpty) {
    out.writeln('✓ $root matches the CLI');
    return 0;
  }
  for (final relative in drifted) {
    err.writeln('✗ $relative drifted from the CLI.');
  }
  for (final relative in orphans) {
    err.writeln('✗ $relative is rendered by no MCP prompt.');
  }
  err.writeln('Run: dart run tool/gen_agent_integrations.dart');
  return 1;
}

// A Windows checkout with core.autocrlf rewrites the line endings only.
String? _read(File file) =>
    file.existsSync() ? file.readAsStringSync().replaceAll('\r\n', '\n') : null;

void main(List<String> args) => exitCode = run(args);
