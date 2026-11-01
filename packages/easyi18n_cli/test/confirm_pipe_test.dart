@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A pipe on stdin is not a terminal, and a `yes` written into it is not a
/// person consenting to a spend. Both spending commands must warn and abort
/// instead of reading it, while `--yes` still carries the consent. The probe
/// is a real process: `stdin.hasTerminal` cannot be injected.
void main() {
  late Directory dir;
  late String snapshot;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('confirm_pipe');
    snapshot = p.join(dir.path, 'confirm_probe.dill');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile', 'kernel', 'test/support/confirm_probe.dart', '-o', snapshot,
    ], environment: {'CI': 'true', 'DART_SUPPRESS_ANALYTICS': 'true'});
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  for (final command in ['push', 'sync']) {
    test('$command: piped yes cannot confirm, but --yes still bypasses the prompt',
        () async {
      final project = Directory(p.join(dir.path, command))..createSync();
      final config = p.join(project.path, 'easyi18n.yaml');
      final lock = File(p.join(project.path, 'easyi18n.lock'));
      if (command == 'push') {
        File(config).writeAsStringSync('projectId: proj_abc\n');
        File(p.join(project.path, 'lib', 'app.dart'))
          ..parent.createSync()
          ..writeAsStringSync("void f(c) => c.tr('Hello');\n");
      } else {
        File(config).writeAsStringSync(
          'projectId: proj_abc\nformat: xcstrings\n'
          'catalog: Localizable.xcstrings\n',
        );
        File(p.join(project.path, 'Localizable.xcstrings'))
            .writeAsStringSync('{"sourceLanguage":"es","strings":{}}');
      }
      for (final assumeYes in [false, true]) {
        final process = await Process.start(Platform.resolvedExecutable, [
          snapshot, command, config,
          if (command == 'sync') '--no-publish',
          if (assumeYes) '--yes',
        ]);
        addTearDown(process.kill);
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln('yes');
        await process.stdin.close();
        final diagnostic = await errors;
        // `sync` exits 1 on an abort, `push` exits 0; both contracts predate
        // the guard and neither moves here.
        expect(await process.exitCode,
            assumeYes || command == 'push' ? 0 : 1, reason: diagnostic);
        expect(diagnostic, assumeYes ? isEmpty :
          'warning: No terminal to confirm on; pass --yes to $command '
          'non-interactively.\n');
        final text = await output;
        expect(text, contains('real spends: ${assumeYes ? 1 : 0}'));
        expect(text, isNot(contains('[y/N]')));
        if (command == 'push') expect(lock.existsSync(), assumeYes);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
