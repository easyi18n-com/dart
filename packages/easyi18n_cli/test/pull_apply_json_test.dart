import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/command_runner.dart';
import 'package:easyi18n_cli/src/commands/apply_command.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late String config;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pull_apply_json');
    out = StringBuffer();
    err = StringBuffer();
    config = '${dir.path}/easyi18n.yaml';
    File(config).writeAsStringSync('projectId: proj_abc\nmode: a\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));
  Easyi18nCommandRunner runner(Map<String, Object?> body) => Easyi18nCommandRunner(
    logger: CliLogger(out: out, err: err),
    environment: const {'EASYI18N_TOKEN': 'eik_x'},
    apiClientFactory: ({required baseUrl, required token}) => TranslationsApiClient(
      baseUrl: baseUrl, token: token,
      httpClient: MockClient((_) async => http.Response(jsonEncode(body), 200))),
  );
  Map<String, dynamic> payload() {
    expect(out.toString().trim().split('\n'), hasLength(1));
    final result = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(result, isNotEmpty);
    return result;
  }
  for (final pull in [false, true]) {
    test('injected output owns the effective logger for ${pull ? 'pull' : 'apply'}', () async {
      final logger = _ObservedLogger(out: out, err: err);
      final output = CliOutput(logger: logger)..json = true;
      TranslationsApiClient api({required String baseUrl, required String token}) =>
          TranslationsApiClient(baseUrl: baseUrl, token: token,
            httpClient: MockClient((_) async => http.Response(jsonEncode(pull
                ? {'version': '2026.09.08.7', 'files': {'arb/app_es.arb': '{}'}}
                : {'changes': [{'key': 'gone', 'oldSource': 'Absent', 'newSource': 'Present'}]}), 200)));
      final command = pull
          ? PullCommand( output: output,
              apiClientFactory: api, environment: const {'EASYI18N_TOKEN': 'eik_x'})
          : ApplyCommand( output: output,
              apiClientFactory: api, environment: const {'EASYI18N_TOKEN': 'eik_x'});
      final bare = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config')
        ..addCommand(command);
      expect(await bare.run(['--config', config, command.name]), 0);
      expect(logger.infoCalls, greaterThan(0));
      expect(payload(), isNotEmpty);
      if (!pull) expect(err.toString(), contains('1 change(s) had no matching literal'));
    });
  }
  test('pull JSON reports paths and coverage, never contents', () async {
    expect(await runner({
      'version': '2026.09.08.7', 'files': {'arb/app_es.arb': '{"hi":"Hola"}'},
      'coverageBasis': 'skip', 'coverage': {'es': {'translated': 1, 'total': 1}},
    }).run(['--config', config, '--json', 'pull', '--require-complete']), 0);
    final json = payload();
    expect(json['version'], '2026.09.08.7');
    expect(json['files_written'], ['${dir.path}/lib/l10n/app_es.arb']);
    expect(json['coverage'], {'es': {'translated': 1, 'total': 1}});
    expect(json['destination'], 'directory');
    expect(json['pruned'], isEmpty);
    expect(out.toString(), isNot(contains('Hola')));
    expect(File('${dir.path}/lib/l10n/app_es.arb').readAsStringSync(), '{"hi":"Hola"}');
  });
  // Nothing reached the server, but stdout is the wire: a disk failure is a
  // record, not an empty stdout and an unhandled exception.
  test('a pull that fails on disk emits the error record', () async {
    // A directory where the atomic write stages the file: fails even as root.
    Directory('${dir.path}/lib/l10n/app_es.arb.tmp').createSync(recursive: true);
    expect(await runner({
      'version': '2026.09.08.7', 'files': {'arb/app_es.arb': '{"hi":"Hola"}'},
    }).run(['--config', config, '--json', 'pull']), 1);
    final error = payload()['error'] as Map<String, dynamic>;
    expect(payload().keys, ['error']);
    expect(error['code'], 'file_system');
    expect(error['retryable'], false);
    expect(error['message'], contains('app_es.arb.tmp'));
  });
  // The files travel beside `error`, whose four fields are the contract of
  // every command (#2095).
  test('a pull over a file changed by hand names it beside the error',
      () async {
    final file = File('${dir.path}/lib/l10n/app_es.arb');
    await runner({
      'version': '2026.09.08.7', 'files': {'arb/app_es.arb': '{"hi":"Hola"}'},
    }).run(['--config', config, '--json', 'pull']);
    file.writeAsStringSync('{"hi":"Buenas"}');
    out.clear();
    expect(await runner({
      'version': '2026.09.09.1', 'files': {'arb/app_es.arb': '{"hi":"Qué tal"}'},
    }).run(['--config', config, '--json', 'pull']), 1);
    final json = payload();
    expect(json.keys, unorderedEquals(['edited', 'error']));
    expect(json['edited'], [
      {'file': 'lib/l10n/app_es.arb'},
    ]);
    final error = json['error'] as Map<String, dynamic>;
    expect(error.keys,
        unorderedEquals(['message', 'code', 'statusCode', 'retryable']));
    expect(error['code'], 'edited_targets');
    expect(error['retryable'], false);
    expect(file.readAsStringSync(), '{"hi":"Buenas"}');
  });
  // The prune and the files written before the failing one are on disk:
  // the record says which, beside the error.
  for (final blocked in ['es', 'fr']) {
    test('a pull that fails writing $blocked keeps what it pruned and wrote',
        () async {
      File('${dir.path}/.easyi18n/state.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'format': 'arb', 'output': 'lib/l10n', 'files': ['app_de.arb'],
        }));
      File('${dir.path}/lib/l10n/app_de.arb').createSync(recursive: true);
      Directory('${dir.path}/lib/l10n/app_$blocked.arb.tmp').createSync();
      expect(await runner({
        'version': '2026.09.08.7',
        'files': {'arb/app_es.arb': '{}', 'arb/app_fr.arb': '{}'},
      }).run(['--config', config, '--json', 'pull']), 1);
      final json = payload();
      expect(json['error']['code'], 'file_system');
      expect(json['files_written'],
          [if (blocked == 'fr') '${dir.path}/lib/l10n/app_es.arb']);
      expect(json['pruned'], ['${dir.path}/lib/l10n/app_de.arb']);
      expect(json['version'], '2026.09.08.7');
    });
  }
  // A dry run prunes nothing, so a planned prune is not applied work: the
  // failure after it is the error alone.
  test('a dry run that fails after planning a prune is the error alone',
      () async {
    File(config).writeAsStringSync(
        'projectId: proj_abc\nmode: a\nformat: xcstrings\noutput: App\n');
    File('${dir.path}/.easyi18n/state.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'format': 'xcstrings', 'output': 'App', 'files': ['Old.xcstrings'],
      }));
    File('${dir.path}/App/Old.xcstrings').createSync(recursive: true);
    // The merge reads the local catalog under --dry-run too; an unreadable
    // one has no directory equivalent.
    final local = '${dir.path}/App/Localizable.xcstrings';
    File(local).createSync();
    Process.runSync('chmod', ['000', local]);
    addTearDown(() => Process.runSync('chmod', ['644', local]));
    expect(await runner({
      'version': '2026.09.08.7',
      'files': {'xcstrings/Localizable.xcstrings': '{}'},
    }).run(['--config', config, '--json', 'pull', '--dry-run']), 1);
    expect(payload().keys, ['error']);
    expect(payload()['error']['code'], 'file_system');
    expect(File('${dir.path}/App/Old.xcstrings').existsSync(), isTrue);
  });
  test('a pull that fails on disk without --json still throws', () async {
    Directory('${dir.path}/lib/l10n/app_fr.arb.tmp').createSync(recursive: true);
    await expectLater(runner({
      'version': '2026.09.08.7',
      'files': {'arb/app_es.arb': '{}', 'arb/app_fr.arb': '{}'},
    }).run(['--config', config, 'pull']), throwsA(isA<FileSystemException>()));
    expect(out.toString(), isNot(contains('{')));
  });
  test('incomplete pull emits one error object after writing artifacts', () async {
    expect(await runner({
      'version': '2026.09.08.7', 'files': {'arb/app_es.arb': '{}'},
      'coverageBasis': 'skip', 'coverage': {'es': {'translated': 1, 'total': 3}},
    }).run(['--config', config, '--json', 'pull', '--require-complete']), 1);
    expect(payload()['error']['retryable'], false);
    // The files are on disk, so the record says which, and the coverage the
    // gate refused on (#1835).
    expect(payload()['files_written'], ['${dir.path}/lib/l10n/app_es.arb']);
    expect(payload()['coverage'], {'es': {'translated': 1, 'total': 3}});
    expect(err.toString(), 'error: es: 2 of 3 key(s) untranslated\n');
    expect(File('${dir.path}/lib/l10n/app_es.arb').readAsStringSync(), '{}');
  });
  test('empty apply still emits a nonempty result without scanning', () async {
    expect(await runner({'changes': []}).run(['--config', config, '--json', 'apply']), 0);
    final json = payload();
    expect(json['edits'], isEmpty);
    expect(json['unmatched'], isEmpty);
    expect(json['files_changed'], 0);
    expect(json['files_scanned'], 0);
    expect(err.toString(), isEmpty);
  });
  for (final write in [false, true]) {
    test('apply JSON write=$write redacts output, preserves original edits', () async {
      final file = File('${dir.path}/lib/main.dart')..parent.createSync();
      file.writeAsStringSync("void f(c) => c.tr('Helo');\n");
      expect(await runner({'changes': [
        {'key': 'hi', 'oldSource': 'Helo', 'newSource': 'Hello eik_0123456789abcdef'},
        {'key': 'gone', 'oldSource': 'Absent', 'newSource': 'Present'},
      ]}).run(['--config', config, 'apply', '--json', if (write) '--write']), 0);
      final json = payload();
      expect(json['edits'], [
        {'file': 'lib/main.dart', 'line': 1, 'old': 'Helo',
          'new': 'Hello [REDACTED]'},
      ]);
      expect(json['unmatched'], [
        {'key': 'gone', 'ctx': null, 'old': 'Absent', 'new': 'Present'},
      ]);
      expect(json['files_changed'], write ? 1 : 0);
      expect(err.toString(), contains('1 change(s) had no matching literal'));
      expect(file.readAsStringSync(), write
        ? "void f(c) => c.tr('Hello eik_0123456789abcdef');\n" : "void f(c) => c.tr('Helo');\n");
    });
  }
  for (final command in ['pull', 'apply']) {
    test('$command empty explicit token takes precedence in JSON', () async {
      expect(await runner({}).run([
        '--config', config, '--json', command, '--token', '',
      ]), 1);
      expect(payload()['error'], {
        'message': "No credential for https://api.easyi18n.com. Run 'easyi18n "
          "login', set EASYI18N_TOKEN or pass --token.\n"
          '${command == 'pull'
            ? 'Create an API key in your project settings with read scope. '
              'Adopting a missing format also requires write scope.'
            : 'Create an API key in your project settings (needs the read scope).'}',
        'code': 'cli_error', 'statusCode': null, 'retryable': false,
      });
    });
  }
  test('JSON watch refuses before requesting or writing', () async {
    expect(await runner({}).run(['--config', config, '--json', 'pull', '--watch']), 1);
    expect(payload()['error']['message'], contains('--watch'));
    expect(Directory('${dir.path}/lib').existsSync(), isFalse);
  });
}

class _ObservedLogger extends CliLogger {
  _ObservedLogger({super.out, super.err});
  int infoCalls = 0;
  @override
  void info(String message) { infoCalls++; super.info(message); }
}
