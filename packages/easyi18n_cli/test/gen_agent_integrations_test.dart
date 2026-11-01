@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:easyi18n_cli/src/mcp/client_config.dart';
import 'package:easyi18n_cli/src/mcp/prompts.dart';
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
  const setupSkill = 'claude-code/skills/easyi18n-setup/SKILL.md';

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

  test('every MCP prompt is a plugin skill carrying its text verbatim', () {
    final files = gen.renderIntegrations();
    for (final prompt in mcpPrompts) {
      final name = 'easyi18n-${prompt.prompt.name}';
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
