import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/extract_command.dart';
import 'package:easyi18n_cli/src/lockfile.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_extract');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig() {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync('projectId: proj_abc\n');
    return path;
  }

  void writeSource(String relPath, String content) {
    final f = File(p.join(dir.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  CommandRunner<int> runner() {
    final r = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    return r..addCommand(ExtractCommand(output: CliOutput(logger: logger)));
  }

  test('reports extracted strings and never writes the lockfile', () async {
    writeSource('lib/main.dart', '''
void f(c, name) {
  c.tr('Hello');
  c.tr(name);
}
''');
    final code = await runner().run(['--config', writeConfig(), 'extract']);

    expect(code, 0);
    expect(out.toString(), contains('1 extractable'));
    expect(err.toString(), contains('non-literal source'));
    expect(File(p.join(dir.path, Lockfile.fileName)).existsSync(), isFalse);
  });

  test('a numeric lock project keeps its units in a handle extract', () async {
    final config = p.join(dir.path, 'easyi18n.yaml');
    File(config).writeAsStringSync('workspace: acme\nproject: demo\n');
    File(p.join(dir.path, Lockfile.fileName)).writeAsStringSync(jsonEncode({
      'version': 1,
      'project': 123,
      'units': [
        {'source': 'Kept'},
        {'source': 'Gone'},
      ],
    }));
    writeSource('lib/a.dart', '''
void f(c) {
  c.tr('Kept');
  c.tr('Fresh');
}
''');

    final code = await runner().run(['--config', config, 'extract']);

    expect(code, 0);
    expect(out.toString(), contains('1 new since last push'));
    expect(out.toString(), contains('1 orphan(s)'));
  });

  test(
    '--fail-on-orphans exits non-zero when the lockfile has orphans',
    () async {
      File(p.join(dir.path, Lockfile.fileName)).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'project': 'proj_abc',
          'units': [
            {'source': 'Gone'},
          ],
        }),
      );
      writeSource('lib/main.dart', "void f(c) => c.tr('Hi');\n");

      final code = await runner().run([
        '--config',
        writeConfig(),
        'extract',
        '--fail-on-orphans',
      ]);
      expect(code, 1);
      expect(out.toString(), contains('orphan'));
    },
  );
}
