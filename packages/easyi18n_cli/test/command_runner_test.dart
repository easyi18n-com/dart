@TestOn('vm')
library;

import 'dart:async';

import 'package:args/command_runner.dart' show UsageException;
// Through the barrel, not `src/`: it is the package's public surface, and
// nothing else in the suite imports it, so a dropped `export` would otherwise
// go unnoticed until an embedder hit it.
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:test/test.dart';

import 'support/transcript.dart';

/// The first suite in this package that builds the real
/// [Easyi18nCommandRunner]. Every other suite - the goldens included - wires a
/// bare `CommandRunner<int>` with a hand-added `--config`, so none of them can
/// see what a *global* flag does (`test/support/transcript.dart`, "What the
/// goldens do not cover").
///
/// It records `print()` next to the injected sinks on purpose.
/// `CommandRunner.runCommand` answers a bare invocation with `printUsage()`,
/// which writes through `print()` - outside every sink a [CliLogger] can be
/// given. So a test that only read the transcript would see the very same
/// empty list whether `--version` short-circuits correctly, prints usage on
/// top of the version line, or the scenario never ran at all. `printed` is
/// what separates those three, and `--help` below is its positive control.
void main() {
  /// Runs [args] through the real runner and returns everything a caller can
  /// observe: the exit code the shell would see, the sink transcript in
  /// emission order, and every line `print()` emitted.
  Future<({int exit, List<TranscriptRecord> records, List<String> printed})>
  invoke(List<String> args) {
    final transcript = Transcript();
    final printed = <String>[];
    final runner = Easyi18nCommandRunner(
      logger: CliLogger(out: transcript.out, err: transcript.err),
    );
    return runZoned(
      () async {
        final exit = await runner.run(args) ?? 0;
        return (exit: exit, records: transcript.records, printed: printed);
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
  }

  test('--version prints the pinned version and stops there', () async {
    final result = await invoke(['--version']);

    expect(result.records, [
      (channel: 'out', line: 'easyi18n $packageVersion'),
    ]);
    expect(result.exit, 0);
    expect(
      result.printed,
      isEmpty,
      reason:
          'the version line must be the whole answer: falling through to '
          "super's printUsage() would dump the command list under it, on a "
          'channel no golden and no sink can see',
    );
  });

  // `package:args` resolves a subcommand's unknown option against the *parent*
  // parser, so the global `--version` is set from either side of the command
  // name. Neither side may be answered: printing the version would swallow the
  // command and still exit 0 - `easyi18n rollback --version previous` is the
  // natural typo, because `rollback` takes its version as a positional while
  // its sibling `pull` really does have a `--version` option - and letting the
  // command win would make `easyi18n --version rollback` restore a version
  // nobody asked for. Refusing is the only answer that is silent about
  // nothing.
  for (final args in [
    ['rollback', '--version', 'previous'],
    ['--version', 'rollback'],
    ['status', '--version'],
  ]) {
    test('easyi18n ${args.join(' ')} is a usage error', () {
      expect(
        invoke(args),
        throwsA(
          isA<UsageException>().having(
            (e) => e.message,
            'message',
            contains('--version'),
          ),
        ),
        reason:
            'answering --version here exits 0 without running the command, so '
            'a script reads a no-op as success',
      );
    });
  }

  test('pull --version <id> still reaches the command', () {
    // The guard above must not cost `pull` its own `--version` option, which
    // is the documented way to ask for a published version. `package:args`
    // gives the subcommand's parser precedence, so the global flag is never
    // set here - asserted rather than assumed, because this is exactly what
    // the refusal would break.
    final results = Easyi18nCommandRunner(
      logger: CliLogger(),
    ).parse(['pull', '--version', '2026.01.01.1']);

    expect(results.flag('version'), isFalse);
    expect(results.command?.name, 'pull');
    expect(results.command?.option('version'), '2026.01.01.1');
  });

  test('--help still prints usage through print()', () async {
    // Positive control for `printed`. Without it, "printed is empty" above is
    // satisfied just as well by a harness that cannot see print() at all.
    final result = await invoke(['--help']);

    expect(
      result.printed,
      isNotEmpty,
      reason: 'the zone does not capture print() - the assertion above is void',
    );
    expect(result.printed.single, contains('Usage: easyi18n'));
    expect(
      result.records,
      isEmpty,
      reason: 'usage does not go through the logger, so no sink records it',
    );
  });
}
