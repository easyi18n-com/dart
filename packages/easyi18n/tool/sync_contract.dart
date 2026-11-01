// Vendors the algorithmic contract files from `easyi18n_core` into this SDK so
// the runtime computes byte-identical tokens/hashes without a path dependency
// (pub.dev forbids `path:` deps). Run from the package root:
//
//   dart run tool/sync_contract.dart          # copy core → vendored
//   dart run tool/sync_contract.dart --check   # CI: fail if they drifted
//
// Only the THREE algorithmic files + the golden vectors are synced. The flat
// models (`bundle.dart`, `manifest.dart`, `translation_value.dart`) are
// hand-maintained on purpose (no freezed for consumers) and gated by the
// vectors test, not by this tool.
import 'dart:io';

/// (source relative to core root) → (dest relative to this package root).
const _files = <String, String>{
  'lib/src/i18n/text_hash.dart': 'lib/src/contract/i18n/text_hash.dart',
  'lib/src/i18n/icu_canonical.dart': 'lib/src/contract/i18n/icu_canonical.dart',
  'lib/src/i18n/cldr_plurals.dart': 'lib/src/contract/i18n/cldr_plurals.dart',
  // `part` of the file above (the generated CLDR table): both or neither.
  'lib/src/i18n/cldr_plural_data.dart':
      'lib/src/contract/i18n/cldr_plural_data.dart',
  'test/i18n/contract_vectors.json': 'lib/src/contract/contract_vectors.json',
  'test/i18n/resolver_vectors.json': 'lib/src/contract/resolver_vectors.json',
};

const _coreRoot = '../easyi18n_core';

void main(List<String> args) {
  final check = args.contains('--check');
  final drifted = <String>[];

  for (final entry in _files.entries) {
    final src = File('$_coreRoot/${entry.key}');
    final dst = File(entry.value);
    if (!src.existsSync()) {
      stderr.writeln('✗ missing core source: ${src.path}');
      exit(2);
    }
    final srcBytes = src.readAsStringSync();

    if (check) {
      final dstBytes = dst.existsSync() ? dst.readAsStringSync() : null;
      if (dstBytes != srcBytes) drifted.add(entry.value);
    } else {
      dst.parent.createSync(recursive: true);
      dst.writeAsStringSync(srcBytes);
      stdout.writeln('✓ synced ${entry.value}');
    }
  }

  if (check) {
    if (drifted.isEmpty) {
      stdout.writeln('✓ vendored contract is in sync with easyi18n_core');
      return;
    }
    stderr.writeln('✗ vendored contract drifted from easyi18n_core:');
    for (final f in drifted) {
      stderr.writeln('  - $f');
    }
    stderr.writeln('Run: dart run tool/sync_contract.dart');
    exit(1);
  }
}
