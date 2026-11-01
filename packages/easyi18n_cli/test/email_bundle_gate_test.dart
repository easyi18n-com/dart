import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/contract.dart';
import 'package:easyi18n_cli/src/email_bundle_gate.dart';
import 'package:test/test.dart';

/// The email i18n deploy gate: self-activating (dormant until bundles exist),
/// then blocks when an email `tr()` source isn't covered by a baked bundle.
void main() {
  late Directory tmp;
  late Directory source;
  late Directory bundles;
  late Directory toolTmp;
  late File toolSnapshot;

  setUpAll(() {
    toolTmp = Directory.systemTemp.createTempSync('email_gate_tool');
    toolSnapshot = File('${toolTmp.path}/email_bundle_gate.dill');
    final compile = Process.runSync(
      Platform.resolvedExecutable,
      [
        'compile',
        'kernel',
        'tool/email_bundle_gate.dart',
        '-o',
        toolSnapshot.path,
      ],
      workingDirectory: Directory.current.path,
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

  tearDownAll(() => toolTmp.deleteSync(recursive: true));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('email_gate');
    source = Directory('${tmp.path}/src')..createSync();
    bundles = Directory('${tmp.path}/bundles')..createSync();
    // A tiny email source tree with two email tr() calls.
    File('${source.path}/emails.dart').writeAsStringSync('''
      String subject(dynamic tr) => tr('Reset your password', ctx: 'email');
      String body(dynamic tr) => tr('Hi {name}', ctx: 'email');
    ''');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void writeBundle(Iterable<String> sources) {
    var i = 0;
    final tokenIndex = {
      for (final s in sources) messageTokenForText(s, ctx: 'email'): 'k${i++}',
    };
    File('${bundles.path}/es.json').writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'locale': 'es',
      'bundleHash': 'x',
      'messages': {for (final slug in tokenIndex.values) slug: 'trad'},
      'tokenIndex': tokenIndex,
    }));
  }

  ProcessResult runTool() => Process.runSync(
        Platform.resolvedExecutable,
        [
          '--disable-dart-dev',
          toolSnapshot.path,
          '--source',
          source.path,
          '--bundles',
          bundles.path,
        ],
        workingDirectory: Directory.current.path,
      );

  final malformedCases = <({String name, List<int> bytes, String reason})>[
    (
      name: 'invalid JSON',
      bytes: utf8.encode('{ not json'),
      reason: 'invalid JSON',
    ),
    (
      name: 'array root',
      bytes: utf8.encode('[]'),
      reason: 'the JSON root must be an object',
    ),
    (
      name: 'array tokenIndex',
      bytes: utf8.encode('{"tokenIndex":["a"]}'),
      reason: 'tokenIndex must be an object',
    ),
    (
      name: 'invalid UTF-8',
      bytes: [0xff, 0xfe],
      reason: 'invalid UTF-8 encoding',
    ),
  ];
  for (final c in malformedCases) {
    test('the caller reports ${c.name} without a stack trace', () {
      writeBundle(['Reset your password', 'Hi {name}']);
      final bundle = File('${bundles.path}/bad.json')
        ..writeAsBytesSync(c.bytes);
      final result = runTool();

      expect(result.exitCode, 2, reason: c.name);
      expect(result.stdout, isEmpty, reason: c.name);
      expect(result.stderr, contains(bundle.path), reason: c.name);
      expect(result.stderr, contains(c.reason), reason: c.name);
      expect(
        result.stderr,
        contains('Replace or regenerate this bundle'),
        reason: c.name,
      );
      expect(
        result.stderr,
        isNot(contains('Unhandled exception')),
        reason: c.name,
      );
    });
  }

  test('with several malformed bundles the error names the first by path', () {
    // APFS lists es.json after each of the others, whatever the write order.
    for (final lang in ['pt', 'ja', 'it', 'fr', 'es']) {
      File('${bundles.path}/$lang.json').writeAsStringSync('{ not json');
    }
    expect(
      () => checkEmailBundleCoverage(sourceDir: source, bundlesDir: bundles),
      throwsA(isA<MalformedEmailBundleException>()
          .having((e) => e.path, 'path', '${bundles.path}/es.json')),
    );
  });

  test('the caller passes a valid bundle', () {
    writeBundle(['Reset your password', 'Hi {name}']);
    final result = runTool();

    expect(result.exitCode, 0);
    expect(result.stdout, contains('✓ all 2 email string(s) are covered'));
    expect(result.stderr, isEmpty);
  });

  test('the caller preserves numeric tokenIndex values', () {
    File('${bundles.path}/es.json').writeAsStringSync(jsonEncode({
      'tokenIndex': {
        messageTokenForText('Reset your password', ctx: 'email'): 1,
        messageTokenForText('Hi {name}', ctx: 'email'): 2,
      },
    }));
    final result = runTool();

    expect(result.exitCode, 0);
    expect(result.stdout, contains('✓ all 2 email string(s) are covered'));
    expect(result.stderr, isEmpty);
  });

  test('dormant when no bundles exist (English-only pre-flip state)', () {
    final r = checkEmailBundleCoverage(sourceDir: source, bundlesDir: bundles);
    expect(r.dormant, isTrue);
    expect(r.passed, isTrue);
  });

  test('passes when every email source is covered', () {
    writeBundle(['Reset your password', 'Hi {name}']);
    final r = checkEmailBundleCoverage(sourceDir: source, bundlesDir: bundles);
    expect(r.dormant, isFalse);
    expect(r.totalStrings, 2);
    expect(r.missing, isEmpty);
    expect(r.passed, isTrue);
  });

  test('blocks when a source is missing from the bundles', () {
    writeBundle(['Reset your password']); // 'Hi {name}' not translated
    final r = checkEmailBundleCoverage(sourceDir: source, bundlesDir: bundles);
    expect(r.passed, isFalse);
    expect(r.missing, hasLength(1));
    expect(r.missing.single, contains('Hi {name}'));
    expect(r.missing.single, contains('[email]'));
  });

  test('a same-language variant bundle (es-419.json) still counts', () {
    File('${bundles.path}/es-419.json').writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'locale': 'es-419',
      'bundleHash': 'x',
      'messages': {'k0': 'trad', 'k1': 'trad'},
      'tokenIndex': {
        messageTokenForText('Reset your password', ctx: 'email'): 'k0',
        messageTokenForText('Hi {name}', ctx: 'email'): 'k1',
      },
    }));
    final r = checkEmailBundleCoverage(sourceDir: source, bundlesDir: bundles);
    expect(r.passed, isTrue);
  });

  test('non-json files in the bundles dir do not activate the gate', () {
    File('${bundles.path}/README.md').writeAsStringSync('# not a bundle');
    final r = checkEmailBundleCoverage(sourceDir: source, bundlesDir: bundles);
    expect(r.dormant, isTrue);
  });
}
