// One pair of counters, one noun (#1175).
//
// `icuRejected`/`markupRejected` are reported by three commands, and each had
// picked its own word: `translation(s)` on the two success lines, `value(s)`
// in push's warning heading, `cell(s)` in rollback. The rows they count are
// of two natures — a refused target cell IS a translation, a refused base row
// is the stored SOURCE — so two of the three words were wrong for part of
// what they counted.
//
// The behavioural assertions live with each command's tests. This one exists
// because the defect was DRIFT: three surfaces, no single place saying they
// agree. So it may not be satisfiable by anything a drift would leave intact:
//
//   * the surfaces are DISCOVERED from `lib/src/commands/`, not listed here,
//     because a hardcoded list pins values and not membership — a fourth
//     command reporting the same counters would never be looked at;
//   * comments are stripped before any assertion, because the prose this
//     very file's subject added already contains the word `cell(s)` — a
//     `contains` over the raw source is satisfied by a comment, which is not
//     the code;
//   * the noun is read off the INTERPOLATION of the counter itself
//     (`$refused cell(s)`), reached from `icuRejectedTotal` through the local
//     that sums the pair and through the `int` parameter of the warning
//     helper — so every site is found by following the data, and a site that
//     stops being found is a red (the per-command counts below), not a
//     silent pass.
import 'dart:io';

import 'package:test/test.dart';

/// A place where one of the two counters is printed with a noun:
/// `<command>:$<variable> <noun>(s)`.
typedef NounSite = ({String command, String variable, String noun});

const commandsDir = 'lib/src/commands';

/// Source of [file] with whole-line `//` and `///` comments removed and
/// whitespace collapsed, so a declaration split across lines still matches.
String codeOf(String path) {
  final lines = File(path)
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'));
  return lines.join(' ').replaceAll(RegExp(r'\s+'), ' ');
}

/// Every command source that reads the refusal counters, by command name.
Map<String, String> discoverSurfaces() {
  final out = <String, String>{};
  for (final entry in Directory(commandsDir).listSync().whereType<File>()) {
    if (!entry.path.endsWith('_command.dart')) continue;
    final code = codeOf(entry.path);
    if (!code.contains('icuRejectedTotal')) continue;
    final name = entry.uri.pathSegments.last.replaceAll('_command.dart', '');
    out[name] = code;
  }
  return out;
}

/// The identifiers that carry a refusal count into a printed string: the
/// local that sums the pair, and the `int` parameter of any helper called
/// with `icuRejectedTotal` as an argument.
Set<String> counterVariables(String code) {
  final vars = <String>{};
  final summed = RegExp(
    r'(?:final|var)\s+(\w+)\s*=\s*[\w.]+\.icuRejectedTotal\s*\+\s*'
    r'[\w.]+\.markupRejectedTotal\s*;',
  );
  for (final m in summed.allMatches(code)) {
    vars.add(m.group(1)!);
  }
  final call = RegExp(r'(_\w+)\(\s*[\w.]+\.icuRejected\s*,\s*'
      r'[\w.]+\.icuRejectedTotal\s*,');
  for (final m in call.allMatches(code)) {
    final decl = RegExp(
      '${RegExp.escape(m.group(1)!)}'
      r'\(\s*List<String>\s+\w+\s*,\s*int\s+(\w+)\s*,',
    ).firstMatch(code);
    if (decl != null) vars.add(decl.group(1)!);
  }
  return vars;
}

List<NounSite> nounSites(String command, String code) {
  final sites = <NounSite>[];
  for (final v in counterVariables(code)) {
    for (final m in RegExp(r'\$' '$v' r'\s+(\w+)\(s\)').allMatches(code)) {
      sites.add((command: command, variable: v, noun: m.group(1)!));
    }
  }
  return sites;
}

void main() {
  late Map<String, String> surfaces;

  setUpAll(() {
    surfaces = discoverSurfaces();
  });

  test('the command sources are readable from here', () {
    // Positive control: an unreadable path would make every assertion below
    // pass over an empty set. The CWD holds on both real routes — CI runs
    // this job with `working-directory: packages/easyi18n_cli`, and
    // `tool/analyze.sh` cds in.
    expect(Directory(commandsDir).existsSync(), isTrue);
    for (final e in surfaces.entries) {
      expect(e.value.length, greaterThan(1000), reason: e.key);
    }
  });

  test('the surfaces that report the counters are the three known ones', () {
    // Membership, not values: a fourth command that reports the same pair
    // has to be looked at — its noun is not automatically right just because
    // the other three agree.
    expect(
      surfaces.keys.toSet(),
      {'push', 'sync', 'rollback'},
      reason: 'a new command reporting icuRejectedTotal/markupRejectedTotal: '
          'check the noun it prints, then add it here',
    );
  });

  test('every printed refusal count is found, and there are five', () {
    // The positive control for the discovery above: these counts go red when
    // a site stops being reachable from `icuRejectedTotal`, which is the way
    // a source-reading guard goes quietly blind. sync reports one (its
    // warning helper prints `$label: <row>` with no noun at all).
    final byCommand = {
      for (final e in surfaces.entries) e.key: nounSites(e.key, e.value),
    };
    expect(
      {for (final e in byCommand.entries) e.key: e.value.length},
      {'push': 2, 'sync': 1, 'rollback': 2},
      reason: 'sites found: $byCommand',
    );
  });

  test('every one of them prints the same noun', () {
    for (final e in surfaces.entries) {
      for (final site in nounSites(e.key, e.value)) {
        expect(site.noun, 'cell', reason: '${site.command}: \$${site.variable}');
      }
    }
  });

  test('no command spells the refusal counters another way', () {
    for (final e in surfaces.entries) {
      expect(e.value, isNot(contains('translation(s) refused')), reason: e.key);
      expect(e.value, isNot(contains('value(s) refused')), reason: e.key);
      expect(e.value, isNot(contains(r'value(s) $what')), reason: e.key);
    }
  });
}
