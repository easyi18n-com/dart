@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:easyi18n_cli/src/mcp/client_config.dart';
import 'package:easyi18n_cli/src/mcp/prompts.dart';
import 'package:easyi18n_cli/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../tool/gen_agent_integrations.dart' as gen;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gen_agents'));
  tearDown(() => dir.deleteSync(recursive: true));

  int check(String root, StringBuffer err) =>
      gen.run(['--check'], root: root, out: StringBuffer(), err: err);

  File at(String root, String relative) => File(p.join(root, relative));

  String write() {
    expect(gen.run([], root: dir.path, out: StringBuffer()), 0);
    return dir.path;
  }

  const readme = 'clients/README.md';
  const setupSkill = 'claude-code/skills/setup/SKILL.md';

  test('the checked-in integrations are what the CLI renders', () {
    final err = StringBuffer();
    expect(check(gen.integrationsRoot, err), 0, reason: '$err');
    final text = at(gen.integrationsRoot, readme).readAsStringSync();
    for (final client in McpClient.values) {
      for (final runner in McpRunner.values) {
        expect(
          text,
          contains(client.snippet(runner)),
          reason: '${client.id} / ${runner.name}',
        );
      }
    }
  });

  test('the Gemini extension starts the server as `mcp config` does', () {
    // Gemini CLI names the server under its extension, so the key is `cli`
    // where the standalone snippet says `easyi18n` (#2737).
    final rendered = gen.renderIntegrations()['gemini-extension.json'];
    expect(rendered, isNotNull);
    final extension = jsonDecode(rendered!) as Map<String, dynamic>;
    final snippet =
        jsonDecode(McpClient.gemini.snippet(McpRunner.npx))
            as Map<String, dynamic>;
    expect(extension['name'], 'easyi18n');
    expect(extension['version'], packageVersion);
    expect(extension['mcpServers'], {
      'cli': (snippet['mcpServers'] as Map)['easyi18n'],
    });
  });

  test('the registry entry is the npm package the snippets launch', () {
    final rendered = gen.renderIntegrations()['server.json'];
    expect(rendered, isNotNull);
    final server = jsonDecode(rendered!) as Map<String, dynamic>;
    final [package as Map] = server['packages'] as List;
    // `npx -y <identifier>@<version> <packageArguments>` is McpRunner.npx.
    expect([
      'npx',
      '-y',
      '${package['identifier']}@${package['version']}',
      for (final arg in package['packageArguments'] as List)
        (arg as Map)['value'],
    ], McpRunner.npx.argv);
    expect(server['name'], 'com.easyi18n/cli');
    // What a registry client shows in place of the name: the brand, once.
    expect(server['title'], 'easyi18n');
    expect(server['version'], packageVersion);
    expect(package['registryType'], 'npm');
    expect(package['transport'], {'type': 'stdio'});
  });

  test('every MCP prompt is a plugin skill carrying its text verbatim', () {
    final files = gen.renderIntegrations();
    for (final prompt in mcpPrompts) {
      // Claude Code prefixes it with the plugin: `easyi18n:setup` (#2735).
      final name = prompt.prompt.name;
      final skill = files['claude-code/skills/$name/SKILL.md'];
      expect(skill, isNotNull, reason: name);
      expect(skill, startsWith('---\nname: $name\ndescription: '));
      expect(skill, endsWith('---\n\n${prompt.text}'));
    }
    expect(
      files.keys.where((k) => k.endsWith('SKILL.md')),
      hasLength(mcpPrompts.length),
    );
  });

  test('each skill frontmatter is YAML holding its trigger verbatim', () {
    // The triggers carry `: `, which a plain YAML scalar cannot.
    final files = gen.renderIntegrations();
    for (final skill in gen.agentSkills()) {
      final text = files['claude-code/skills/${skill.name}/SKILL.md']!;
      final front = text.split('---\n')[1];
      final yaml = loadYaml(front) as YamlMap;
      expect(yaml['name'], skill.name);
      expect(yaml['description'], skill.description);
    }
  });

  test('a new MCP prompt without a skill trigger stops the render', () {
    // An empty description would ship a skill Claude Code never loads.
    expect(
      () => gen.agentSkills([(prompt: Prompt(name: 'review'), text: 'x')]),
      throwsStateError,
    );
  });

  test('a hand edit fails the check and names the file and the fix', () {
    final root = write();
    final skill = at(root, setupSkill);
    skill.writeAsStringSync(
      skill.readAsStringSync().replaceFirst('Detect', 'Guess'),
    );
    final err = StringBuffer();
    expect(check(root, err), 1);
    expect('$err', contains(setupSkill));
    expect('$err', isNot(contains(readme)));
    expect('$err', contains('dart run tool/gen_agent_integrations.dart'));
  });

  test('a CRLF checkout of the same files passes', () {
    final root = write();
    for (final relative in gen.renderIntegrations().keys) {
      final file = at(root, relative);
      file.writeAsStringSync(file.readAsStringSync().replaceAll('\n', '\r\n'));
    }
    expect(check(root, StringBuffer()), 0);
  });

  test('a missing file is drift, not a pass', () {
    final root = write();
    at(root, setupSkill).deleteSync();
    final err = StringBuffer();
    expect(check(root, err), 1);
    expect('$err', contains(setupSkill));
  });

  test('a skill no prompt renders is drift, and a write removes it', () {
    // A renamed prompt must not leave its old skill in the published plugin.
    final root = write();
    final orphan = at(root, 'claude-code/skills/easyi18n-old/SKILL.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('---\nname: easyi18n-old\n---\n');
    final err = StringBuffer();
    expect(check(root, err), 1);
    expect('$err', contains('claude-code/skills/easyi18n-old/SKILL.md'));

    write();
    expect(orphan.parent.existsSync(), isFalse);
    expect(check(root, StringBuffer()), 0);
  });

  test('a prompt the skill loader would rewrite is refused', () {
    // Claude Code substitutes these in a SKILL.md body before the model
    // reads it, so the skill would say something the prompt does not; the
    // shell markers also run a command on the user's machine.
    for (final text in [
      r'run with $1',
      r'use $ARGUMENTS',
      r'see ${CLAUDE_PLUGIN_ROOT}',
      'check !`git status`',
      '!`flutter pub get`',
      'run:\n```!\nflutter pub get\n```',
    ]) {
      expect(
        () => gen.renderSkill((name: 'x', description: 'd', text: text)),
        throwsStateError,
        reason: text,
      );
    }
    for (final text in [r"'Hi $name'", 'Done! `doctor` is green.']) {
      expect(
        gen.renderSkill((name: 'x', description: 'd', text: text)),
        endsWith(text),
      );
    }
  });
}
