import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/doctor_command.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:test/test.dart';

void main() {
  test('ICU replay preserves detail order and elision byte for byte', () async {
    final dir = Directory.systemTemp.createTempSync('review_icu');
    try {
      File('${dir.path}/easyi18n.yaml').writeAsStringSync('projectId: p\nmode: a\n');
      Directory('${dir.path}/lib').createSync();
      File('${dir.path}/lib/main.dart').writeAsStringSync([
        for (var i = 0; i < 12; i++)
          "void f$i(dynamic context) { context.tr('broken $i {'); }",
      ].join('\n'));
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config');
      runner.addCommand(DoctorCommand(
        output: CliOutput(logger: CliLogger(out: out, err: err)),
        environment: {},
      ));
      expect(await runner.run([
        '--config', '${dir.path}/easyi18n.yaml', 'doctor',
      ]), 1);
      expect(err.toString(), isEmpty);
      expect(out.toString().replaceAll(dir.path, '<ROOT>'), '''
ok    <ROOT>/easyi18n.yaml - project p (Mode A: TMS)
warn  credential - EASYI18N_TOKEN not set - 'easyi18n push/pull' will need it
warn  <ROOT>/AGENTS.md - no easyi18n block - run 'easyi18n init' so agents without MCP read the loop and the credit rules
info  mode - runtime wiring checks not applicable (Mode A: pubspec dependency, assets floor, entitlements, Easyi18nScope)
info  mode - if this project's dashboard Settings has not been set to Mode A yet, do that too - it picks the right publish defaults
ok    scan - 1 file(s), 12 extractable tr() string(s)
  lib/main.dart:1  "broken 0 {" - unbalanced braces: '{' is never closed
  lib/main.dart:2  "broken 1 {" - unbalanced braces: '{' is never closed
  lib/main.dart:3  "broken 2 {" - unbalanced braces: '{' is never closed
  lib/main.dart:4  "broken 3 {" - unbalanced braces: '{' is never closed
  lib/main.dart:5  "broken 4 {" - unbalanced braces: '{' is never closed
  lib/main.dart:6  "broken 5 {" - unbalanced braces: '{' is never closed
  lib/main.dart:7  "broken 6 {" - unbalanced braces: '{' is never closed
  lib/main.dart:8  "broken 7 {" - unbalanced braces: '{' is never closed
  lib/main.dart:9  "broken 8 {" - unbalanced braces: '{' is never closed
  lib/main.dart:10  "broken 9 {" - unbalanced braces: '{' is never closed
  ... and 2 more
FAIL  icu - 12 ICU problem(s) - a malformed string renders RAW to users
info  delivery - not applicable (Mode A pulls files, no OTA runtime)
info  completeness - could not verify: EASYI18N_TOKEN not set (a key with the read scope grades it)
1 problem(s), 2 warning(s). 1 check(s) could not run - see `info` above. Most local issues are fixed by 'easyi18n init'.
''');
    } finally { dir.deleteSync(recursive: true); }
  });
}
