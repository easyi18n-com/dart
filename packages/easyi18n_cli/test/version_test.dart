@TestOn('vm')
library;

import 'dart:io';

import 'package:easyi18n_cli/src/version.dart';
import 'package:test/test.dart';

/// Pulls the `version:` of a pubspec out of [source], or null when there is
/// none. Deliberately a *parser over text*, not a yaml load: the guard below
/// has to be able to fail, and a loader that threw on a malformed pubspec
/// would report the same red for a reason that has nothing to do with drift.
String? pubspecVersion(String source) {
  final match = RegExp(
    r'^version:[ \t]*(\S+)[ \t]*$',
    multiLine: true,
  ).firstMatch(source);
  return match?.group(1);
}

void main() {
  test('packageVersion is the version pubspec.yaml declares', () {
    final declared = pubspecVersion(File('pubspec.yaml').readAsStringSync());

    // Liveness first. A parser that quietly stopped matching - a reformatted
    // pubspec, a `version :`, a CRLF checkout - must say *that*, not be read
    // as drift.
    expect(
      declared,
      isNotNull,
      reason:
          'pubspec.yaml has no `version:` line this parser can see, so the '
          'comparison below would be measuring nothing',
    );
    expect(
      packageVersion,
      declared,
      reason:
          'packageVersion (lib/src/version.dart) drifted from pubspec.yaml. '
          'Edit that constant to match. `--version` would otherwise report a '
          'version that was never published - worse than no flag at all, '
          'because the answer looks authoritative (#695).',
    );
  });

  // The `publish` job of release.yml refuses a tag whose version has no
  // heading, and `pub publish --dry-run` exits 65; both run only after the tag
  // is pushed. Same pattern as that job: `## 1.3.0-rc.1` is not `## 1.3.0`.
  test('CHANGELOG.md has a heading for the pubspec version', () {
    final declared = pubspecVersion(File('pubspec.yaml').readAsStringSync());
    expect(declared, isNotNull);
    expect(
      File('CHANGELOG.md').readAsStringSync(),
      matches(
        RegExp('^## ${RegExp.escape(declared!)}(\\s|\$)', multiLine: true),
      ),
      reason:
          'The release bump renames the CHANGELOG heading to the pubspec '
          'version (docs/guides/sdk-release.md, "A release candidate").',
    );
  });

  group('the parser', () {
    // Positive control. The test above compares a hand-written constant
    // against whatever this parser returns, so a parser that returned
    // `packageVersion` - or that read the constant's own file - would be a
    // tautology green for ever, through every future bump.
    test('reports the version it is given, not the one we ship', () {
      expect(
        pubspecVersion('name: easyi18n_cli\nversion: 9.9.9-probe\n'),
        '9.9.9-probe',
      );
      expect(pubspecVersion('name: easyi18n_cli\nversion: 0.0.1\n'), '0.0.1');
    });

    test('reports nothing when there is no version line', () {
      expect(pubspecVersion('name: easyi18n_cli\ndescription: x\n'), isNull);
      // Not a top-level key: an indented `version:` belongs to a dependency.
      expect(
        pubspecVersion('dependencies:\n  args:\n    version: 2.7.0\n'),
        isNull,
      );
    });
  });
}
