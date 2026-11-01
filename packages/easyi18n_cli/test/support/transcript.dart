import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// One recorded emission: which channel it went to, and the line itself.
typedef TranscriptRecord = ({String channel, String line});

/// Records `(channel, line)` pairs for a command's stdout and stderr **in
/// emission order**, which is the point: two per-channel `StringBuffer`s
/// cannot hold the interleaving, so a line that moves from one channel to the
/// other, or past a line on the other channel, is invisible to them.
///
/// Wire it into a command with `CliLogger(out: t.out, err: t.err)`.
///
/// ## What no sink can see
///
/// Three sites write to the process streams without going through
/// `CliLogger`, so they are outside every golden recorded here:
///
/// - `init_command.dart` `_terminalPrompt` - `stdout.write('$label: ')`
/// - `push_command.dart` / `sync_command.dart` `_stdinConfirm` -
///   `stdout.write(prompt)`
///
/// They never fire under test (`prompt:` / `confirm:` are injected), but a
/// later PR that moved a line onto one of those paths would leave every
/// golden green.
///
/// `bin/easyi18n.dart` prints a text usage error outside the runner, through
/// the logger's `err` sink and `CliLogger.sanitize`. No sink here sees that
/// write either; the `executable` group of `json_command_runner_test.dart`
/// pins it from the compiled entrypoint.
///
/// ## What the goldens do not cover
///
/// The scenarios build a bare `CommandRunner<int>` with a hand-added
/// `--config` option, the same construction the per-command suites use - not
/// `Easyi18nCommandRunner`. So a golden records what the *command* prints,
/// not what the real runner's global flags do to it.
class Transcript {
  final List<TranscriptRecord> _records = [];
  final Map<String, StringBuffer> _pending = {};

  late final StringSink out = _TranscriptSink(this, 'out');
  late final StringSink err = _TranscriptSink(this, 'err');

  /// How many lines [records] holds so far. The progress-order test reads
  /// this at the moment each request arrives and then indexes [records], so
  /// the two must count the same thing - `_records.length` alone would drop
  /// a pending partial line and slide that test's last window.
  int get length => records.length;

  /// Everything recorded, with any unterminated partial line flushed last on
  /// its own channel - a runner that emits a half line must not vanish.
  List<TranscriptRecord> get records => [
    ..._records,
    for (final e in _pending.entries)
      if (e.value.isNotEmpty) (channel: e.key, line: e.value.toString()),
  ];

  void _record(String channel, String text) {
    final buffer = _pending.putIfAbsent(channel, StringBuffer.new);
    for (final ch in text.split('')) {
      if (ch == '\n') {
        _records.add((channel: channel, line: buffer.toString()));
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
  }
}

/// A `StringSink` that tags everything written to it with a channel. All four
/// `StringSink` methods record - `CliLogger` only calls `writeln` today, but a
/// future presenter that calls `write` must not disappear from the goldens.
class _TranscriptSink implements StringSink {
  _TranscriptSink(this._transcript, this._channel);

  final Transcript _transcript;
  final String _channel;

  @override
  void write(Object? object) => _transcript._record(_channel, '$object');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}

/// The on-disk form of a recorded run: the exit code first, then one record
/// per line, channel first.
///
/// ```
/// exit|1
/// out|remote: 2026.07.04.3
/// err|warning: something
/// ```
///
/// The exit code leads because a refactor that preserves every printed byte
/// and changes the code is exactly the regression class this PR exists to
/// catch.
String encodeGolden(int exitCode, List<TranscriptRecord> records) => [
  'exit|$exitCode',
  for (final r in records) '${r.channel}|${r.line}',
  '',
].join('\n');

/// Set `EASYI18N_REGRAB_GOLDENS=1` to rewrite the goldens from the current
/// behaviour. This is the **only** writer: a plain `dart test` never creates
/// or updates a golden file, and a missing one is a hard failure rather than
/// a skip or a silent write - a harness that writes what it then compares is
/// a tautology, not a guard. A regrab run writes every golden and then
/// **fails**, so a leaked environment variable cannot leave the guard
/// announcing success.
bool get regrabbingGoldens =>
    Platform.environment['EASYI18N_REGRAB_GOLDENS'] == '1';

/// Compares [records] + [exitCode] against `test/goldens/<name>.txt`.
///
/// Each [scrub] pair weakens the golden by exactly what it replaces, so each
/// one carries its reason at the call site.
void expectGolden(
  String name,
  int exitCode,
  List<TranscriptRecord> records, {
  List<(Pattern, String)> scrub = const [],
}) {
  final scrubbed = [
    for (final r in records)
      (
        channel: r.channel,
        line: scrub.fold(r.line, (line, s) => line.replaceAll(s.$1, s.$2)),
      ),
  ];

  // Liveness, modelled on the positive control in `rejection_noun_test.dart`:
  // a scrubber that ate the transcript would otherwise compare "" to "" for
  // ever, and every mutation would survive a green run.
  expect(
    scrubbed.length,
    greaterThanOrEqualTo(3),
    reason: '$name recorded almost nothing - the scenario did not run',
  );
  expect(
    scrubbed.any((r) => r.channel == 'out'),
    isTrue,
    reason: '$name recorded no stdout at all',
  );

  final file = File('test/goldens/$name.txt');
  final actual = encodeGolden(exitCode, scrubbed);
  if (regrabbingGoldens) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(actual);
    // A regrab must never be able to END GREEN. The liveness check above
    // closes the empty-transcript tautology; this closes the other one - an
    // `EASYI18N_REGRAB_GOLDENS` left exported by a shell profile, a wrapper
    // that sources a `.env`, or a workflow `env:` turns every scenario into
    // a comparison of the file against itself and the suite still announces
    // success. Reporting success without having looked at anything is the
    // way every guard in this repo has failed.
    fail(
      'regrabbed test/goldens/$name.txt - review the diff and re-run '
      'WITHOUT EASYI18N_REGRAB_GOLDENS. A regrab is never a pass.',
    );
  }
  expect(
    file.existsSync(),
    isTrue,
    reason:
        'Missing golden test/goldens/$name.txt. Record it with '
        'EASYI18N_REGRAB_GOLDENS=1 dart test test/transcript_golden_test.dart '
        'and review the diff - a missing golden is a failure, never a pass.',
  );
  expect(file.readAsStringSync(), actual, reason: 'transcript drift: $name');
}

/// A JSON transcript has one non-empty object, independently of text goldens.
void expectJsonGolden(
  String name,
  int exitCode,
  List<TranscriptRecord> records, {
  required void Function(Map<String, dynamic>) check,
}) {
  final stdout = records.where((r) => r.channel == 'out').toList();
  expect(stdout, hasLength(1));
  final payload = jsonDecode(stdout.single.line);
  expect(payload, isA<Map<String, dynamic>>());
  expect(payload as Map<String, dynamic>, isNotEmpty);
  check(payload);
  final file = File('test/goldens/$name.txt');
  final actual = encodeGolden(exitCode, records);
  if (regrabbingGoldens) {
    file.writeAsStringSync(actual);
    fail('regrabbed $name - review and re-run without EASYI18N_REGRAB_GOLDENS');
  }
  expect(file.existsSync(), isTrue, reason: 'Missing golden $name');
  expect(file.readAsStringSync(), actual, reason: 'transcript drift: $name');
}
