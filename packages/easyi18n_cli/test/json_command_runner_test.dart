@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:test/test.dart';

import 'support/transcript.dart';

void main() {
  Future<({int code, Transcript transcript, List<String> printed})> invoke(
    List<String> args, {
    void Function(Easyi18nCommandRunner)? configure,
  }) async {
    final transcript = Transcript();
    final printed = <String>[];
    final runner = Easyi18nCommandRunner(
      logger: CliLogger(out: transcript.out, err: transcript.err),
    );
    configure?.call(runner);
    final code = await runZoned(
      () => runner.run(args),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    return (code: code ?? 0, transcript: transcript, printed: printed);
  }

  test('--version --json emits only the version object', () async {
    final result = await invoke(['--version', '--json']);
    expectJsonGolden('version_json', result.code, result.transcript.records,
        check: (payload) => expect(payload['version'], packageVersion));
    expect(result.code, 0);
    expect(result.printed, isEmpty);
    expect(result.transcript.records, [
      (channel: 'out', line: jsonEncode({'version': packageVersion})),
    ]);
  });

  // Every shipped command is a JsonPresenter now (`sync` was the last one,
  // #1408), so the rule is anchored on a command that deliberately is not
  // rather than on whichever real one happens to be behind.
  for (final command in ['', 'legacy']) {
    test('--json refuses unsupported command "$command"', () async {
      final result = await invoke(
        ['--json', if (command.isNotEmpty) command],
        configure: (runner) => runner.addCommand(_Legacy()),
      );
      expect(result.code, 64);
      expect(result.printed, isEmpty);
      expect(result.transcript.records, hasLength(1));
      expect(result.transcript.records.single.channel, 'out');
      final payload = jsonDecode(result.transcript.records.single.line) as Map;
      expect(payload['error']['code'], 'json_unsupported');
      expect(payload['error']['retryable'], false);
      expectJsonGolden('json_unsupported', result.code, result.transcript.records,
          check: (payload) => expect(payload['error']['code'], 'json_unsupported'));
    });
  }

  test('--json --help preserves text help', () async {
    final result = await invoke(['--json', '--help']);
    expect(result.code, 0);
    expect(result.transcript.records, isEmpty);
    expect(result.printed.single, contains('Usage: easyi18n'));
  });
  test('presenter membership accepts a new command and preserves warnings', () async {
    final result = await invoke(['--json', 'probe'], configure: (runner) {
      runner.addCommand(_Probe(runner.output));
    });
    expect(result.code, 0);
    expect(result.printed, isEmpty);
    expect(result.transcript.records, [
      (channel: 'err', line: 'warning: careful'),
      (channel: 'out', line: '{"ok":true}'),
    ]);
  });

  test('JSON preserves the exception exit code, text still throws', () async {
    final result = await invoke(['probe', '--json'], configure: (runner) {
      runner.addCommand(_Probe(runner.output, fail: true));
    });
    expect(result.code, 3);
    expect(result.printed, isEmpty);
    expect(result.transcript.records, hasLength(1));
    final payload = jsonDecode(result.transcript.records.single.line) as Map;
    expect(payload['error'], {
      'message': 'offline', 'code': 'cli_error',
      'statusCode': null, 'retryable': false,
    });
    expect(invoke(['probe'], configure: (runner) {
      runner.addCommand(_Probe(runner.output, fail: true));
    }), throwsA(isA<CliException>()));
  });

  test('the public runner constructor remains extensible', () async {
    final t = Transcript();
    final runner = _ExtendedRunner(CliOutput(out: t.out, err: t.err));
    expect(await runner.run(['--version', '--json']), 0);
    expect(jsonDecode(t.records.single.line), {'version': packageVersion});
  });

  test('conflicting output injection is refused', () {
    expect(() => Easyi18nCommandRunner(
        logger: CliLogger(), output: CliOutput()), throwsArgumentError);
  });

  test('reusing the runner resets JSON mode', () async {
    final t = Transcript();
    final output = CliOutput(out: t.out, err: t.err);
    final runner = Easyi18nCommandRunner(output: output);
    await runner.run(['--version', '--json']);
    await runner.run(['--version']);
    expect(t.records.last, (channel: 'out', line: 'easyi18n $packageVersion'));
  });

  group('usage errors', () {
    // One row per producer: the parser (unknown option on either side of the
    // command, refused value), the runner after parsing, and a command.
    for (final (args, needle) in [
      (['status', '--json', '--bogus'], '"--bogus"'),
      (['--json', 'status', '--bogus'], '"--bogus"'),
      (['--json', 'sync', '--on-conflict', 'nope'], '"--on-conflict"'),
      (['--json', '--version', 'status'], 'drop the flag to run `status`'),
      (['--json', 'rollback', '--version', 'previous'], '`rollback`'),
      (['mcp', 'config', '--json'], '--client is required'),
    ]) {
      test('easyi18n ${args.join(' ')} answers one usage_error record', () async {
        final result = await invoke(args);
        expect(result.code, 64);
        expect(result.printed, isEmpty);
        expect(result.transcript.records, hasLength(1));
        expect(result.transcript.records.single.channel, 'out');
        final payload = jsonDecode(result.transcript.records.single.line) as Map;
        expect(payload.keys, ['error']);
        expect(payload['error'], {
          'message': contains(needle), 'code': 'usage_error',
          'statusCode': null, 'retryable': false,
        });
      });
    }

    test('the usage_error record is pinned byte for byte', () async {
      final result = await invoke(['status', '--json', '--bogus']);
      expectJsonGolden('usage_error_json', result.code, result.transcript.records,
          check: (payload) => expect(payload['error']['code'], 'usage_error'));
    });

    for (final args in [
      ['status', '--bogus'],
      ['status', '--bogus', '--', '--json'],
      ['status', '--jsonx'],
      ['status', '--json=true'],
      // The parser read `--json` as the value of --config, so the flag is off.
      ['--version', '--config', '--json', 'status'],
    ]) {
      test('easyi18n ${args.join(' ')} stays a thrown usage error', () async {
        final transcript = Transcript();
        final output = CliOutput(out: transcript.out, err: transcript.err);
        await expectLater(Easyi18nCommandRunner(output: output).run(args),
            throwsA(isA<UsageException>()));
        expect(transcript.records, isEmpty);
        expect(output.json, isFalse);
      });
    }

    test('a text usage error after a JSON run does not inherit JSON mode', () async {
      final t = Transcript();
      final output = CliOutput(out: t.out, err: t.err);
      final runner = Easyi18nCommandRunner(output: output);
      expect(await runner.run(['status', '--json', '--bogus']), 64);
      await expectLater(runner.run(['status', '--bogus']),
          throwsA(isA<UsageException>()));
      expect(output.json, isFalse);
      expect(t.records, hasLength(1));
    });

    test('a credential echoed by the parser is redacted in the record', () async {
      const key = 'eik_0123456789abcdefghij';
      final result = await invoke(['--json', 'sync', '--on-conflict', key]);
      expect(result.code, 64);
      final line = result.transcript.records.single.line;
      expect(line, isNot(contains(key)));
      expect(jsonDecode(line)['error']['message'], contains('[REDACTED]'));
    });
  });

  test('subcommand help remains text under JSON', () async {
    final result = await invoke(['push', '--json', '--help']);
    expect(result.code, 0);
    expect(result.transcript.records, isEmpty);
    expect(result.printed.single, contains('Usage: easyi18n push'));
  });

  group('executable', () {
    late Directory snapshotDir;
    late File snapshot;

    // Compile once to avoid repeated compilation under load. The snapshot
    // probes our entrypoint output; dartdev wrapper output is outside this test.
    setUpAll(() {
      snapshotDir = Directory.systemTemp.createTempSync('easyi18n_cli_json');
      snapshot = File('${snapshotDir.path}/easyi18n.dill');
      final compile = Process.runSync(
        Platform.resolvedExecutable,
        ['compile', 'kernel', 'bin/easyi18n.dart', '-o', snapshot.path],
        environment: {
          ...Platform.environment,
          'CI': 'true',
          'DART_SUPPRESS_ANALYTICS': 'true',
        },
      );
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
    });

    tearDownAll(() => snapshotDir.deleteSync(recursive: true));

    for (final corrupt in [null, 'pubspec.yaml',
      'macos/Runner/DebugProfile.entitlements', 'easyi18n.yaml']) {
      test('doctor process emits JSON with unreadable file $corrupt', () async {
        final fixture = Directory('${snapshotDir.path}/fixture')..createSync();
        final config = File('${fixture.path}/easyi18n.yaml')
          ..writeAsStringSync('projectId: p\nbaseUrl: http://localhost:9\n');
        if (corrupt != null) {
          File('${fixture.path}/$corrupt')..createSync(recursive: true)
            ..writeAsBytesSync([0xff, 0xfe, 0x00]);
        }
        try {
          final result = await Process.run(Platform.resolvedExecutable,
            ['--disable-dart-dev', snapshot.path,
              if (corrupt != null) ...['--config', config.path],
              'doctor', '--json'],
            workingDirectory: fixture.path,
            environment: {'EASYI18N_TOKEN': ''});
          expect(result.exitCode, 1, reason: '${result.stderr}');
          expect(result.stderr, isEmpty);
          final lines = (result.stdout as String).trim().split('\n');
          expect(lines, hasLength(1));
          final payload = jsonDecode(lines.single) as Map;
          expect(payload, isNotEmpty);
          if (corrupt == 'easyi18n.yaml') {
            expect(payload['error']['retryable'], isFalse);
          } else if (corrupt != null) {
            expect(payload['project_dir'], fixture.path);
            expect(payload['base_url'], 'http://localhost:9');
            final finding = (payload['findings'] as List).singleWhere((f) =>
                f['subject'] == '${fixture.path}/$corrupt');
            expect(finding['level'], 'unverified');
            expect(finding['message'], contains('Cannot read'));
          } else {
            expect(payload['findings'], isNotEmpty);
            expect(payload['project_dir'], fixture.resolveSymbolicLinksSync());
            expect(payload['base_url'], 'http://localhost:9');
          }
        } finally { fixture.deleteSync(recursive: true); }
      });
    }

    test('stdout is JSON and has no stray process writes', () async {
      for (final row in [
        (['--version', '--json'], 0),
        // `sync --json` is a presenter now, so this row exercises a real
        // command's JSON error path instead of the membership refusal.
        (['sync', '--json'], 1),
      ]) {
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['--disable-dart-dev', snapshot.path, ...row.$1],
        );
        expect(result.exitCode, row.$2, reason: '${result.stderr}');
        expect(result.stderr, isEmpty);
        final lines = (result.stdout as String).trim().split('\n');
        expect(lines, hasLength(1));
        expect(jsonDecode(lines.single), isA<Map<String, dynamic>>());
      }
    });

    test('a usage error under --json is one record on stdout', () async {
      final result = await Process.run(Platform.resolvedExecutable,
        ['--disable-dart-dev', snapshot.path, 'status', '--json', '--bogus']);
      expect(result.stderr, isEmpty);
      expect(result.exitCode, 64);
      final lines = (result.stdout as String).trim().split('\n');
      expect(lines, hasLength(1));
      final payload = jsonDecode(lines.single) as Map;
      expect(payload['error']['code'], 'usage_error');
      expect(payload['error']['message'], contains('"--bogus"'));
    });

    test('a usage error without --json stays text on stderr', () async {
      final result = await Process.run(Platform.resolvedExecutable,
        ['--disable-dart-dev', snapshot.path, 'status', '--bogus']);
      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr, startsWith(
          'Could not find an option named "--bogus".\n\nUsage: easyi18n status'));
    });

    // The keys are made-up strings in the shape of a credential.
    for (final (args, message) in [
      (['sync', '--on-conflict', 'eik_0123456789abcdefghij'],
        '"[REDACTED]" is not an allowed value for option "--on-conflict".'),
      (['sync', '--on-conflict', 'eip_0123456789abcdefghij'],
        '"[REDACTED]" is not an allowed value for option "--on-conflict".'),
      (['eik_0123456789abcdefghij'],
        'Could not find a command named "[REDACTED]".'),
    ]) {
      test('easyi18n ${args.join(' ')} redacts the key on stderr', () async {
        final result = await Process.run(Platform.resolvedExecutable,
          ['--disable-dart-dev', snapshot.path, ...args]);
        expect(result.exitCode, 64);
        expect(result.stdout, isEmpty);
        expect(result.stderr, startsWith('$message\n\nUsage: easyi18n'));
        expect(result.stderr, isNot(contains(args.last)));
      });
    }

    test('a refused argument cannot write a terminal escape to stderr', () async {
      final result = await Process.run(Platform.resolvedExecutable,
        ['--disable-dart-dev', snapshot.path,
          'sync', '--on-conflict', 'a\x1b[31mb']);
      expect(result.exitCode, 64);
      expect(result.stderr, startsWith(
          '"a[31mb" is not an allowed value for option "--on-conflict".\n'));
    });

    test('a redacted usage error under --json is not repeated on stderr', () async {
      const key = 'eik_0123456789abcdefghij';
      final result = await Process.run(Platform.resolvedExecutable,
        ['--disable-dart-dev', snapshot.path,
          'sync', '--on-conflict', key, '--json']);
      expect(result.exitCode, 64);
      expect(result.stderr, isEmpty);
      final lines = (result.stdout as String).trim().split('\n');
      expect(lines, hasLength(1));
      expect(lines.single, isNot(contains(key)));
      expect(jsonDecode(lines.single), {
        'error': {
          'message':
              '"[REDACTED]" is not an allowed value for option "--on-conflict".',
          'code': 'usage_error', 'statusCode': null, 'retryable': false,
        },
      });
    });

    test('a usage error without a key prints the exception unchanged', () async {
      const args = ['sync', '--on-conflict', 'bogus'];
      final sinks = CliOutput(out: StringBuffer(), err: StringBuffer());
      final thrown = await Easyi18nCommandRunner(output: sinks)
          .run(args)
          .then<Object?>((_) => null, onError: (Object error) => error);
      expect(thrown, isA<UsageException>());
      final result = await Process.run(Platform.resolvedExecutable,
        ['--disable-dart-dev', snapshot.path, ...args]);
      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect(result.stderr, '$thrown\n');
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

}

/// A command that never opted into structured output — the membership gate's
/// only remaining subject.
class _Legacy extends Command<int> {
  @override
  String get name => 'legacy';
  @override
  String get description => 'Not a presenter';
  @override
  int run() => 0;
}

class _Probe extends Command<int> with JsonPresenter {
  _Probe(this.output, {this.fail = false});
  final CliOutput output;
  final bool fail;
  @override
  String get name => 'probe';
  @override
  String get description => 'Test presenter';
  @override
  int run() {
    if (fail) throw CliException('offline', exitCode: 3);
    output.logger.info('hidden');
    output.logger.detail('hidden detail');
    output.logger.warn('careful');
    output.emit({'ok': true});
    return 0;
  }
}

class _ExtendedRunner extends Easyi18nCommandRunner {
  _ExtendedRunner(CliOutput output) : super(output: output);
}
