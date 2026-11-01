import 'dart:io';

import 'package:args/args.dart';
import 'package:easyi18n_cli/src/email_bundle_gate.dart';

/// Deploy gate for transactional-email i18n
/// (docs/specs/transactional-emails-i18n-brief.md).
///
/// Guarantees no email ships in English by accident: every `tr()` source in the
/// email code must be present in the baked delivery bundles before a deploy.
///
/// **Self-activating / dormant by design.** The gate's condition IS the repo
/// state, so nobody has to remember to turn it on:
///   - No `*.json` bundles in the assets dir → email i18n is not activated yet
///     (English-only is the accepted state) → the gate passes (exit 0).
///   - Any bundle present → the flip has happened → every email source must be
///     covered or the deploy is blocked (exit 1). Committing the first bundles
///     (the P6 flip) both enables translations AND arms this gate, in one act.
///
///   dart run tool/email_bundle_gate.dart \
///     --source `dir of email tr() code` --bundles `baked bundles dir`
void main(List<String> argv) {
  final parser = ArgParser()
    ..addOption('source',
        defaultsTo: 'backend/lib/email',
        help: 'Directory of email tr() source code.')
    ..addOption('bundles',
        defaultsTo: 'backend/assets/easyi18n',
        help: 'Directory of baked delivery bundles (*.json).');
  final args = parser.parse(argv);

  final sourceDir = Directory(args['source'] as String);
  if (!sourceDir.existsSync()) {
    stderr.writeln('✗ email source dir not found: ${args['source']}');
    exit(2);
  }

  late final EmailGateResult result;
  try {
    result = checkEmailBundleCoverage(
      sourceDir: sourceDir,
      bundlesDir: Directory(args['bundles'] as String),
    );
  } on MalformedEmailBundleException catch (error) {
    stderr.writeln(
        '✗ malformed email bundle ${error.path}: ${error.reason}.');
    stderr.writeln('Replace or regenerate this bundle, then re-run the deploy.');
    exit(2);
  }

  if (result.dormant) {
    stdout.writeln('email i18n not activated (no baked bundles in '
        '${args['bundles']}) — English-only, gate dormant.');
    return;
  }
  if (result.passed) {
    stdout.writeln('✓ all ${result.totalStrings} email string(s) are covered '
        'by the baked bundles.');
    return;
  }

  stderr.writeln('✗ ${result.missing.length} email string(s) are not in the '
      'baked bundles — they would be delivered in English:');
  for (final m in result.missing) {
    stderr.writeln('  • $m');
  }
  stderr.writeln('\nRun the i18n-self-translate workflow (register + fill + '
      'publish) with the email keys, then\n'
      '`cd backend && dart run bin/refresh_email_bundles.dart`, commit the '
      'updated bundles, and re-run the deploy.');
  exit(1);
}
