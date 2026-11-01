import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapter.dart';
import 'package:easyi18n_cli/src/agents_md.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/doctor_report.dart' show DoctorFindings;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late CliLogger logger;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('agents_md');
    logger = CliLogger(out: StringBuffer(), err: StringBuffer());
    File(p.join(dir.path, 'pubspec.yaml'))
        .writeAsStringSync('name: demo\nflutter:\n  uses-material-design: true\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File agents() => File(p.join(dir.path, 'AGENTS.md'));
  String configPath() => p.join(dir.path, 'easyi18n.yaml');
  Easyi18nConfig config() => Easyi18nConfig.load(File(configPath()));

  InitReport init({String project = 'demo', bool writeAgents = true,
          bool dryRun = false, bool force = false}) =>
      InitRunner().run(configPath: configPath(), logger: logger,
          workspace: 'acme', project: project, stack: 'flutter',
          writeAgents: writeAgents, dryRun: dryRun, force: force);

  InitStep agentsStep(InitReport report) =>
      report.steps.singleWhere((s) => s.target == agents().path);

  List<DoctorFinding> doctor([StackAdapter? adapter]) {
    final found = <DoctorFinding>[];
    checkAgentsMd(dir.path, config(), adapter ?? DartFlutterAdapter(),
        DoctorFindings(found.add));
    return found;
  }

  group('init', () {
    test('init writes AGENTS.md with the easyi18n block', () {
      final report = init();
      expect(agents().existsSync(), isTrue, reason: 'no AGENTS.md was written');
      final content = agents().readAsStringSync();
      expect(content, startsWith('# AGENTS.md\n'));
      expect(content, matches(RegExp(
          r'<!-- easyi18n:start v=1 stack=flutter sha=[0-9a-f]{8} -->\n')));
      expect(content, endsWith('<!-- easyi18n:end -->\n'));
      expect(report.steps.last.verb, 'created');
      expect(report.steps.last.target, agents().path);
    });

    test('the sha is the first 8 hex of the sha256 of the rendered body', () {
      init();
      final body = renderAgentsBody(config(), DartFlutterAdapter());
      final sha = sha256.convert(utf8.encode(body)).toString().substring(0, 8);
      expect(agents().readAsStringSync(),
          contains('sha=$sha -->\n$body<!-- easyi18n:end -->'));
    });

    test('a file without markers gets the block appended, its text kept', () {
      for (final existing in ['# Team rules\n\nBe nice.\n', 'no newline']) {
        agents().writeAsStringSync(existing);
        final step = agentsStep(init());
        expect(step.verb, 'patched');
        final content = agents().readAsStringSync();
        expect(content,
            contains('${existing.trimRight()}\n\n<!-- easyi18n:start'));
        expect(content, startsWith(existing.trimRight()));
        expect('<!-- easyi18n:start'.allMatches(content), hasLength(1));
      }
    });

    test('an identical block is ok and the file is not rewritten', () {
      init();
      final before = agents().readAsStringSync();
      agents().setLastModifiedSync(DateTime(2020));
      final step = agentsStep(init());
      expect(step.verb, 'ok');
      expect(agents().readAsStringSync(), before);
      expect(agents().lastModifiedSync(), DateTime(2020));
    });

    test('a stale block is updated in place, the text around it kept', () {
      init();
      final block =
          agents().readAsStringSync().split('\n\n').skip(1).join('\n\n');
      agents().writeAsStringSync('before\n\n${block}after\n');
      final step = agentsStep(init(project: 'other', force: true));
      expect(step.verb, 'updated');
      final content = agents().readAsStringSync();
      expect(content, startsWith('before\n\n<!-- easyi18n:start'));
      expect(content, endsWith('<!-- easyi18n:end -->\nafter\n'));
      expect(content, contains('`@acme/other`'));
      expect(content, isNot(contains('@acme/demo')));
    });

    test('a checkout with CRLF line endings reads as the same block', () {
      init();
      agents().writeAsStringSync(
          agents().readAsStringSync().replaceAll('\n', '\r\n'));
      expect(agentsStep(init()).verb, 'ok');
      expect(doctor().single.level, 'ok');
    });

    test('a start marker with no end is never rewritten', () {
      const broken = '# x\n'
          '<!-- easyi18n:start v=1 stack=flutter sha=00000000 -->\n'
          'keep me\n';
      agents().writeAsStringSync(broken);
      final step = agentsStep(init());
      expect(step.verb, 'skipped');
      expect(step.detail, contains('without'));
      expect(agents().readAsStringSync(), broken);
      expect(doctor().single.level, 'warn');
    });

    test('an orphan start before a whole block keeps the text between them',
        () {
      init();
      final orphan = '# x\n'
          '<!-- easyi18n:start v=1 stack=flutter sha=00000000 -->\n'
          'keep me\n\n${agents().readAsStringSync()}';
      agents().writeAsStringSync(orphan);
      final step = agentsStep(init(project: 'other', force: true));
      expect(step.verb, 'skipped');
      expect(agents().readAsStringSync(), orphan);
      expect(doctor().single.message, contains('start marker without'));
    });

    // The marker regex would not see a damaged second start, and the orphan
    // would pair with that block's end.
    test('an orphan start before a block with a damaged start keeps the text',
        () {
      init();
      final damaged = agents().readAsStringSync()
          .replaceFirst(RegExp('sha=[0-9a-f]{8}'), 'sha=zzzzzzzz');
      final orphan = '# x\n'
          '<!-- easyi18n:start v=1 stack=flutter sha=00000000 -->\n'
          'keep me\n\n$damaged';
      agents().writeAsStringSync(orphan);
      expect(agentsStep(init(project: 'other', force: true)).verb, 'skipped');
      expect(agents().readAsStringSync(), orphan);
    });

    test('a dry run reports each state and writes nothing', () {
      expect(agentsStep(init(dryRun: true)).verb, 'created');
      expect(agents().existsSync(), isFalse);
      init();
      final written = agents().readAsStringSync();
      expect(agentsStep(init(project: 'other', force: true, dryRun: true)).verb,
          'updated');
      expect(agents().readAsStringSync(), written);
    });

    test('an AGENTS.md that is not UTF-8 is reported and left alone', () {
      agents().writeAsBytesSync([0x23, 0x20, 0xe9, 0x0a]);
      final step = agentsStep(init());
      expect(step.verb, 'skipped');
      expect(step.detail, startsWith('cannot read it'));
      expect(agents().readAsBytesSync(), [0x23, 0x20, 0xe9, 0x0a]);
      final finding = doctor().single;
      expect(finding.level, 'warn');
      expect(finding.message, startsWith('cannot read it'));
    });

    test('--no-agents skips the block and writes no file', () {
      final step = agentsStep(init(writeAgents: false));
      expect(step.verb, 'skipped');
      expect(step.detail, '--no-agents');
      expect(agents().existsSync(), isFalse);
    });

    test('a value from the yaml cannot close the block early', () {
      File(configPath()).writeAsStringSync(
          'projectId: "p<!-- easyi18n:end -->\\nx`y"\n');
      InitReport run() => InitRunner().run(configPath: configPath(),
          logger: logger, stack: 'flutter');
      expect(agentsStep(run()).verb, 'created');
      expect(agentsStep(run()).verb, 'ok');
      final content = agents().readAsStringSync();
      expect('<!-- easyi18n:end -->'.allMatches(content), hasLength(1));
      expect(content, contains('`p?!-- easyi18n:end --??x?y`'));
    });
  });

  group('CLAUDE.md and .cursorrules', () {
    test('are never created, and a CLAUDE.md is never edited', () {
      File(p.join(dir.path, 'CLAUDE.md')).writeAsStringSync('# Mine\n');
      final step = agentsStep(init());
      expect(step.detail, contains('add a line `@AGENTS.md`'));
      expect(File(p.join(dir.path, 'CLAUDE.md')).readAsStringSync(), '# Mine\n');
      expect(File(p.join(dir.path, '.cursorrules')).existsSync(), isFalse);
    });

    test('a CLAUDE.md that is not UTF-8 costs the hint, not the init', () {
      final claude = File(p.join(dir.path, 'CLAUDE.md'))
        ..writeAsBytesSync([0x23, 0x20, 0xe9, 0x0a]);
      final step = agentsStep(init());
      expect(step.verb, 'created');
      expect(step.detail, isNot(contains('CLAUDE.md')));
      expect(claude.readAsBytesSync(), [0x23, 0x20, 0xe9, 0x0a]);
    });

    test('no hint when CLAUDE.md already names AGENTS.md, or is absent', () {
      expect(agentsStep(init()).detail, isNot(contains('CLAUDE.md')));
      File(p.join(dir.path, 'CLAUDE.md')).writeAsStringSync('@AGENTS.md\n');
      expect(agentsStep(init()).detail, isNot(contains('CLAUDE.md')));
      expect(File(p.join(dir.path, 'CLAUDE.md')).readAsStringSync(),
          '@AGENTS.md\n');
    });
  });

  group('the rendered block', () {
    Easyi18nConfig configWith(String yaml) {
      File(configPath()).writeAsStringSync(yaml);
      return config();
    }

    test('stays within 40 lines, markers included, for every section', () {
      final cases = <String, (Easyi18nConfig, StackAdapter)>{
        'flutter mode b': (configWith('projectId: p1\n'), DartFlutterAdapter()),
        'flutter mode a': (configWith('projectId: p1\nmode: a\n'),
            DartFlutterAdapter()),
        'xcode': (configWith('projectId: p1\nmode: a\nformat: xcstrings\n'
            'catalog: App/Localizable.xcstrings\n'), const XcstringsAdapter()),
      };
      for (final MapEntry(key: name, value: (c, adapter)) in cases.entries) {
        final block = renderAgentsBlock(c, adapter);
        expect('\n'.allMatches(block).length, lessThanOrEqualTo(40),
            reason: name);
      }
    });

    test('the Flutter section follows the mode, the Xcode one names the catalog',
        () {
      final modeB =
          DartFlutterAdapter().agentsMdSection(configWith('projectId: p1\n'));
      expect(modeB, contains("context.tr('Natural English')"));
      expect(modeB, contains(r"tr('Hi $name')"));
      final modeA = DartFlutterAdapter().agentsMdSection(
          configWith('projectId: p1\nmode: a\noutput: l10n\n'));
      expect(modeA, contains('writes every .arb file into `l10n`, the template too'));
      expect(modeA, isNot(contains('translated .arb')));
      expect(modeA, isNot(contains('context.tr')));
      // #2343: the template `init` reads from l10n.yaml is the truth.
      final template = DartFlutterAdapter().agentsMdSection(configWith(
          'projectId: p1\nmode: a\noutput: l10n\nsource: l10n/app_en.arb\n'));
      expect(template, contains('`l10n/app_en.arb` is the truth'));
      expect(template, contains('`easyi18n pull` never writes it'));
      expect(template, contains('Before the first pull, import the .arb files'));
      expect(template, isNot(contains('translated .arb')));
      expect(template, isNot(contains('the template too')));
      final empty = DartFlutterAdapter().agentsMdSection(configWith(
          'projectId: p1\nmode: a\noutput: l10n\nsource: ""\n'));
      expect(empty, contains('the template too'));
      final runtime = DartFlutterAdapter().agentsMdSection(configWith(
          'projectId: p1\nmode: b\nsource: l10n/app_en.arb\n'));
      expect(runtime, contains("context.tr('Natural English')"));
      expect(runtime, isNot(contains('is the truth')));
      final xcode = const XcstringsAdapter().agentsMdSection(configWith(
          'projectId: p1\nmode: a\nformat: xcstrings\n'
          'catalog: App/Localizable.xcstrings\n'));
      expect(xcode,
          contains('The catalog `App/Localizable.xcstrings` is the truth'));
    });

    test('the Xcode section names every catalog of a `catalogs:` config (#590)', () {
      final xcode = const XcstringsAdapter().agentsMdSection(configWith(
          'projectId: p1\nmode: a\nformat: xcstrings\ncatalogs:\n'
          '  - App/Localizable.xcstrings\n  - App/Shortcuts.xcstrings\n'));
      expect(xcode, contains('`App/Localizable.xcstrings`, `App/Shortcuts.xcstrings`'));
      expect(xcode, contains('are the truth'));
      expect(xcode, isNot(contains('`catalog:` in easyi18n.yaml')));
    });

    // An agent told that `--publish` publishes runs a plain `sync` as
    // translate-only, and `sync` publishes by default.
    test('every push or sync flag it names exists, and sync says it publishes',
        () {
      final output = CliOutput(logger: logger);
      final parsers = {
        'push': PushCommand(output: output).argParser,
        'sync': SyncCommand(output: output).argParser,
      };
      final block = renderAgentsBlock(configWith('projectId: p1\n'),
          DartFlutterAdapter());
      final named = RegExp(r'`(?:easyi18n )?(push|sync) --([a-z-]+)`')
          .allMatches(block).map((m) => (m.group(1)!, m.group(2)!)).toList();
      expect(named, containsAll([('push', 'publish'), ('sync', 'dry-run')]));
      for (final (command, flag) in named) {
        expect(parsers[command]!.options, contains(flag),
            reason: '$command --$flag');
      }
      expect(parsers['sync']!.options, isNot(contains('publish')));
      expect(block, contains('`sync` translates, publishes'));
      expect(block, contains('`--no-publish`'));
      expect(parsers['sync']!.options, contains('no-publish'));
    });
  });

  group('doctor agents_md', () {
    setUp(init);

    test('an up-to-date block is ok', () {
      final finding = doctor().single;
      expect(finding.check, 'agents_md');
      expect(finding.level, 'ok');
      expect(finding.subject, agents().path);
    });

    test('a missing file or block warns to run init', () {
      agents().deleteSync();
      expect(doctor().single.message, contains("run 'easyi18n init'"));
      agents().writeAsStringSync('# only notes\n');
      final finding = doctor().single;
      expect(finding.level, 'warn');
      expect(finding.message, startsWith('no easyi18n block'));
    });

    test('a block rendered for another project is stale', () {
      File(configPath()).writeAsStringSync('workspace: acme\nproject: other\n');
      final finding = doctor().single;
      expect(finding.level, 'warn');
      expect(finding.message, startsWith('stale easyi18n block (stack flutter'));
    });

    test('a block rendered for another stack is stale', () {
      final finding = doctor(const XcstringsAdapter()).single;
      expect(finding.level, 'warn');
      expect(finding.message, startsWith('stale easyi18n block'));
    });

    test('a hand edit under a current marker is named, not called stale', () {
      agents().writeAsStringSync(agents().readAsStringSync()
          .replaceFirst('## easyi18n\n', '## easyi18n\n\nMy own rule.\n'));
      final finding = doctor().single;
      expect(finding.level, 'warn');
      expect(finding.message, startsWith('easyi18n block edited by hand'));
    });
  });

  group('the init command', () {
    Future<String> run(List<String> args) async {
      final out = StringBuffer();
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: configPath())
        ..addCommand(InitCommand(output: CliOutput(
            logger: CliLogger(out: out, err: StringBuffer()))));
      await runner.run(['init', '--workspace', 'acme', '--project', 'demo',
        '--stack', 'flutter', ...args]);
      return out.toString();
    }

    test('--no-agents is the negated flag', () async {
      expect(await run(['--no-agents']),
          contains('skipped  ${agents().path} - --no-agents'));
      expect(agents().existsSync(), isFalse);
    });

    test('a dry-run update reads as would update', () async {
      await run([]);
      File(configPath()).writeAsStringSync('workspace: acme\nproject: x\n');
      expect(await run(['--dry-run']),
          contains('would update  ${agents().path}'));
    });
  });
}
