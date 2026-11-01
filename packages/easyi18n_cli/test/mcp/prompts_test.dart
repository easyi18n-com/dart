@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapters.dart' show stackRoadmap;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show project;

/// The prompts are the single source of the agent-facing text (D9): the plugin
/// skills of PR 19 are generated from them and `AGENTS.md` is the same content
/// without MCP. So the assertion is against the spec section itself, not
/// against a copy of it in this file — a copy would pin the drift instead of
/// catching it.
String specPromptBlock(String section) {
  final file = File(p.join('..', '..', 'docs', 'specs', 'agent-native.md'));
  if (!file.existsSync()) {
    fail(
      'the spec is the fixture of this test and it is missing: '
      '${file.absolute.path} (cwd ${Directory.current.path})',
    );
  }
  final lines = file.readAsLinesSync();
  final heading = lines.indexWhere((l) => l.startsWith('### $section '));
  if (heading < 0) fail('no "### $section " heading in ${file.path}');
  final open = lines.indexWhere((l) => l.trimRight() == '```', heading);
  if (open < 0) fail('no opening fence under "### $section "');
  final close = lines.indexWhere((l) => l.trimRight() == '```', open + 1);
  if (close < 0) fail('unterminated fence under "### $section "');
  final body = lines.sublist(open + 1, close);
  if (body.isEmpty) fail('the fence under "### $section " is empty');
  return '${body.join('\n')}\n';
}

String textOf(GetPromptResult result) {
  final message = result.messages.single;
  expect(message.role, Role.user);
  return (message.content as TextContent).text;
}

void main() {
  test('initialize advertises the prompts capability', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    expect(harness.initializeResult.capabilities.prompts, isNotNull);
  });

  test(
    'the two canonical prompts are listed, in order, with a description',
    () async {
      final fixture = project();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final prompts = await harness.listPrompts();
      expect(prompts.map((prompt) => prompt.name), ['setup', 'translate']);
      for (final prompt in prompts) {
        expect(prompt.description, isNotNull, reason: prompt.name);
        expect(prompt.description, isNotEmpty, reason: prompt.name);
        // Nothing to template: the agent reads the text and calls the tools.
        expect(prompt.arguments ?? const [], isEmpty, reason: prompt.name);
      }
    },
  );

  test('setup is the spec section 5.2, character for character', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    expect(textOf(await harness.getPrompt('setup')), specPromptBlock('5.2'));
  });

  // Asserted on the prompt the client receives, not on the spec file: the
  // drift test above already reads the file, so a guard that reads it too is
  // blind to a const edited on its own. Without this call an init defaults to
  // flutter and writes a Flutter config over an Xcode project, which is what
  // `server_test.dart` pins. Reviewed on PR #1641.
  test('setup makes the stack detection binding', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    expect(textOf(await harness.getPrompt('setup')), contains('stack: "auto"'));
  });

  // init answers "No supported stack found" on a repository easyi18n does not
  // support (a Node one, #1835), so step 3 may not read that answer as "you
  // are above the app". Asserted on the prompt the client receives, for the
  // reason given above; the detection it points to is the adapters' own.
  test('setup retries init only on a directory it detects, and stops when '
      'there is none', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final text = textOf(
      await harness.getPrompt('setup'),
    ).replaceAll(RegExp(r'\s+'), ' ');
    expect(
      text,
      contains(
        'retry with project_dir only if you find a directory that meets a '
        'stack detection of step 1. If you find none, stop and say you found '
        'no supported stack.',
      ),
    );
    expect(text, isNot(contains('the stack is not unsupported')));
    expect(
      text,
      contains(
        'Xcode: an *.xcodeproj or *.xcworkspace plus an .xcstrings catalog '
        'other than InfoPlist.xcstrings.',
      ),
    );
  });

  // Compare the roadmap value with the refusal's constant. A literal copy
  // with the same value remains indistinguishable until the constant changes.
  test('setup names the roadmap from the constant the refusal reads', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    expect(
      textOf(await harness.getPrompt('setup')),
      contains('roadmap: $stackRoadmap).'),
    );
  });

  // On the prompt the client receives, for the reason given above. Each
  // sentence is one a web repository cannot be set up or translated without.
  test('setup and translate carry the web branch', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    Future<String> flat(String name) async => textOf(
      await harness.getPrompt(name),
    ).replaceAll(RegExp(r'\s+'), ' ');
    final setup = await flat('setup');
    for (final sentence in [
      'Web: a package.json that depends on @jsverse/transloco, '
          '@ngx-translate/core or i18next, with one JSON file per locale.',
      'supported: Flutter, Xcode, web JSON catalogs, Android strings.xml;',
      'web, the ICU transpiler a step names, installed first with the '
          "project's package manager.",
      'Web: move user-facing literals into the base file (`source:` in '
          'easyi18n.yaml) as ICU',
      'Never edit the other locale files: pull writes them.',
      'extract (Flutter Mode B) or sync_preview (file-first);',
    ]) {
      expect(setup, contains(sentence));
    }
    final translate = await flat('translate');
    expect(
      translate,
      contains('Web: one file per target language into `output:`; the base '
          'file is never rewritten.'),
    );
    expect(translate, contains('Web: reload the app.'));
  });

  // A gen_l10n template is `source:` and pull never writes it, so the step
  // that brings its keys and translations to the server comes before the
  // first pull: the dashboard import (#2343).
  test('setup and translate carry the Flutter Mode A branch', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    Future<String> flat(String name) async => textOf(
      await harness.getPrompt(name),
    ).replaceAll(RegExp(r'\s+'), ' ');
    final setup = await flat('setup');
    for (final sentence in [
      'Flutter Mode A (gen_l10n): the template .arb (`source:` in '
          'easyi18n.yaml) stays the truth and pull never writes it;',
      'Before the first pull, ask the human to import the existing .arb '
          'files in the dashboard (Keys → Import a file, the template first) '
          'and publish:',
    ]) {
      expect(setup, contains(sentence));
    }
    final translate = await flat('translate');
    expect(translate, contains('Flutter Mode A pushes nothing: its keys reach '
        'the server through the dashboard import (setup step 4)'));
    expect(translate, contains('Mode A Flutter: every .arb in `output:` but '
        'the template (`source:`), which is never rewritten.'));
    expect(translate, isNot(contains('this writes the .arb files')));
  });

  // On the prompt the client receives, for the reason given above. An Android
  // app keeps its strings in resources, so the branch is where they live, what
  // sync uploads and what pull writes back (#2286).
  test('setup and translate carry the Android branch', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    Future<String> flat(String name) async => textOf(
      await harness.getPrompt(name),
    ).replaceAll(RegExp(r'\s+'), ' ');
    final setup = await flat('setup');
    for (final sentence in [
      // Kotlin DSL is what Android Studio writes: a list without `.kts`
      // would stop the agent on the stack init detects.
      'Android: a res/values/strings.xml plus a Gradle script '
          '(settings.gradle or build.gradle, .kts too) or an '
          'AndroidManifest.xml.',
      'Android: the strings already live in res/values/strings.xml;',
      r'with Android escapes and %1$s placeholders',
      'sync uploads each values-<lang>/strings.xml of a project language as '
          'its translations; after that, never edit those files: pull writes '
          'them.',
    ]) {
      expect(setup, contains(sentence));
    }
    final translate = await flat('translate');
    expect(
      translate,
      contains('Android: values-<lang>/strings.xml per target language into '
          '`output:`, the res/ folder; values/strings.xml is never rewritten.'),
    );
    expect(translate,
        contains('Mode A (.arb), Xcode and Android: rebuild to see the '
            'translations.'));
  });

  test('translate is the spec section 5.3, character for character', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    expect(
      textOf(await harness.getPrompt('translate')),
      specPromptBlock('5.3'),
    );
  });
}
