import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapters.dart' show stackRoadmap;
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:test/test.dart';

class _Logger extends CliLogger {
  _Logger(StringSink superOut, StringSink superErr) : super(out: superOut, err: superErr);
  final warnings = <String>[];
  final details = <String>[];
  @override
  void warn(String message) { warnings.add(message); super.warn(message); }
  @override
  void detail(String message) { details.add(message); super.detail(message); }
}

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late Easyi18nCommandRunner runner;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('init_json');
    out = StringBuffer();
    err = StringBuffer();
    runner = Easyi18nCommandRunner(output: CliOutput(out: out, err: err));
    File('${dir.path}/pubspec.yaml').writeAsStringSync(
        'name: demo\ndependencies:\n  flutter:\n    sdk: flutter\nflutter:\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int?> run(List<String> flags) => runner.run([
    '--json', '--config', '${dir.path}/easyi18n.yaml', 'init', ...flags,
  ]);

  test('auto selects a detected Flutter project', () async {
    expect(await run(['--stack', 'auto', '--project-id', 'p1']), 0);
    expect(jsonDecode(out.toString())['stack'], 'flutter');
  });

  test('the command keeps the directory a web tree was detected with: its '
      '--output default must not replace it', () async {
    File('${dir.path}/pubspec.yaml').deleteSync();
    File('${dir.path}/package.json')
        .writeAsStringSync('{"dependencies": {"i18next": "^26.0.0"}}');
    File('${dir.path}/src/assets/i18n/en.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"hello": "Hello"}');
    expect(await run(['--stack', 'auto', '--project-id', 'p1']), 0);
    expect(jsonDecode(out.toString())['stack'], 'web');
    final yaml = File('${dir.path}/easyi18n.yaml').readAsStringSync();
    expect(yaml, contains('\noutput: src/assets/i18n\n'));
    expect(yaml, contains('\nsource: src/assets/i18n/en.json\n'));
    expect(yaml, contains('\nformat: json\n'));
    final loaded = Easyi18nConfig.load(File('${dir.path}/easyi18n.yaml'));
    expect(loaded.sourceRoot, 'src/assets/i18n');
    expect(loaded.sourceLayout, 'locale-files');
  });

  test('the command keeps the format and res/ an Android tree was detected '
      'with: neither --format nor --output defaults replace them (#2285)',
      () async {
    File('${dir.path}/pubspec.yaml').deleteSync();
    File('${dir.path}/settings.gradle').writeAsStringSync("include ':app'\n");
    File('${dir.path}/app/src/main/res/values/strings.xml')
      ..createSync(recursive: true)
      ..writeAsStringSync('<resources><string name="hi">Hi</string></resources>');
    expect(await run(['--stack', 'auto', '--project-id', 'p1']), 0);
    final report = jsonDecode(out.toString());
    expect((report['stack'], report['family'], report['next']),
        ('android', 'file-first', 'sync'));
    final loaded = Easyi18nConfig.load(File('${dir.path}/easyi18n.yaml'));
    expect(loaded.format, 'android_xml');
    expect(loaded.source, 'app/src/main/res/values/strings.xml');
    expect(loaded.output, 'app/src/main/res');
    expect(loaded.mode, 'a');
  });

  test('an explicit --output still wins on a web tree', () async {
    File('${dir.path}/pubspec.yaml').deleteSync();
    File('${dir.path}/package.json')
        .writeAsStringSync('{"dependencies": {"i18next": "^26.0.0"}}');
    expect(await run(['--stack', 'auto', '--project-id', 'p1',
        '--output', 'lib/l10n']), 0);
    expect(File('${dir.path}/easyi18n.yaml').readAsStringSync(),
        contains('\noutput: lib/l10n\n'));
  });

  test('auto refuses an unsupported tree before writing config', () async {
    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: plain_dart\n');
    expect(await run(['--stack', 'auto', '--project-id', 'p1']), 1);
    final error = jsonDecode(out.toString())['error'];
    final message = error['message'];
    expect(message, startsWith('No supported stack'));
    expect(message, endsWith('; roadmap: $stackRoadmap.'));
    expect(error['code'], 'unsupported_stack');
    expect(File('${dir.path}/easyi18n.yaml').existsSync(), isFalse);
    expect(File('${dir.path}/.gitignore').existsSync(), isFalse);
  });

  // Whoever types `init` decides what to change, so the CLI keeps naming what
  // web detection needs; only the MCP refusal leaves it out (#2470).
  test('the CLI refusal names what web detection needs', () async {
    File('${dir.path}/pubspec.yaml').deleteSync();
    File('${dir.path}/package.json').writeAsStringSync('{}');
    expect(await run(['--stack', 'auto', '--project-id', 'p1']), 1);
    expect(jsonDecode(out.toString())['error']['message'],
        'No supported stack found at ${dir.path} (web needs one of '
        '@jsverse/transloco, @ngx-translate/core, i18next in package.json). '
        'Supported: flutter, xcode, web, android; roadmap: $stackRoadmap.');
  });

  for (final stack in ['swift', 'Flutter']) {
    test('unknown stack $stack is distinct from failed detection in JSON', () async {
      expect(await run(['--stack', stack, '--project-id', 'p1']), 1);
      final error = jsonDecode(out.toString())['error'];
      expect(error['message'],
          'Unknown stack "$stack". Supported: flutter, xcode, web, android, auto; '
          'roadmap: $stackRoadmap.');
      expect(error['retryable'], false);
      expect(File('${dir.path}/easyi18n.yaml').existsSync(), isFalse);
      expect(File('${dir.path}/.gitignore').existsSync(), isFalse);
    });
  }

  test('JSON without a project ref fails without prompting', () async {
    expect(await run([]), 1);
    expect(jsonDecode(out.toString())['error']['message'], startsWith('Missing project ref.'));
    expect(File('${dir.path}/easyi18n.yaml').existsSync(), isFalse);
  });

  test('bare presenter shares logger overrides and never prompts under JSON', () async {
    final logger = _Logger(out, err);
    final output = CliOutput(logger: logger)..json = true;
    var prompts = 0;
    final command = InitCommand(output: output, prompt: (_) { prompts++; return 'p1'; });
    final bare = CommandRunner<int>('test', '')
      ..argParser.addOption('config', defaultsTo: '${dir.path}/easyi18n.yaml')
      ..addCommand(command);
    await expectLater(bare.run(['init']), throwsA(isA<CliException>()));
    expect(prompts, 0);
    File('${dir.path}/easyi18n.yaml').writeAsStringSync('projectId: old\nmode: a\n');
    expect(await bare.run(['init', '--workspace', '@', '--project', 'new']), 0);
    expect(logger.warnings, hasLength(1));
    expect(logger.details, isEmpty);
    expect(jsonDecode(out.toString())['next'], 'pull');
    output.json = false;
    expect(await bare.run(['init']), 0);
    expect(logger.details, hasLength(3));
    expect(logger.details.last, contains('AGENTS.md - easyi18n block up to date'));
  });

  test('JSON reports the scaffold and manual snippet in one object', () async {
    expect(await run(['--project-id', 'p1']), 0);
    final payload = jsonDecode(out.toString()) as Map;
    expect(payload['stack'], 'flutter');
    expect(payload['family'], 'code-first');
    expect(payload['next'], 'push');
    expect(payload['scope_snippet'], contains('Easyi18nScope'));
    expect((payload['steps'] as List).first, {
      'verb': 'created', 'target': '${dir.path}/easyi18n.yaml',
      'detail': 'project p1',
    });
    expect(File('${dir.path}/assets/easyi18n/.gitkeep').existsSync(), isTrue);
    expect(err.toString(), isEmpty);
  });

  test('dry-run reports intended changes and leaves the tree untouched', () async {
    final before = File('${dir.path}/pubspec.yaml').readAsBytesSync();
    expect(await run(['--project-id', 'p1', '--dry-run']), 0);
    final payload = jsonDecode(out.toString()) as Map;
    expect(payload['dry_run'], true);
    expect((payload['steps'] as List).first['verb'], 'created');
    expect(File('${dir.path}/easyi18n.yaml').existsSync(), isFalse);
    expect(Directory('${dir.path}/assets').existsSync(), isFalse);
    expect(File('${dir.path}/pubspec.yaml').readAsBytesSync(), before);
  });

  test('existing config differences are steps, with the effective mode', () async {
    File('${dir.path}/easyi18n.yaml').writeAsStringSync('projectId: old\nmode: a\n');
    expect(await run(['--project-id', 'new', '--mode', 'b']), 0);
    final payload = jsonDecode(out.toString()) as Map;
    expect(payload['next'], 'pull');
    expect(payload.containsKey('scope_snippet'), isFalse);
    final steps = payload['steps'] as List;
    expect(steps.map((s) => s['verb']),
        ['ok', 'skipped', 'skipped', 'patched', 'created']);
    expect(steps[1]['detail'], 'keeps project old, not new (use --force to rewrite)');
    expect(steps[2]['detail'], 'keeps mode: a, not b (use --force to rewrite)');
    expect(err.toString(), isEmpty);
  });

  test('unreadable config is a nonretryable JSON error', () async {
    File('${dir.path}/easyi18n.yaml').writeAsBytesSync([0xff]);
    expect(await run([]), 1);
    final payload = jsonDecode(out.toString()) as Map;
    expect(payload['error']['code'], 'cli_error');
    expect(payload['error']['retryable'], false);
    expect(payload['error']['message'], startsWith('Cannot read '));
    expect(Directory('${dir.path}/assets').existsSync(), isFalse);
  });
}
