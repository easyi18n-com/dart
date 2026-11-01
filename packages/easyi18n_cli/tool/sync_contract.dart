// Vendors the golden contract vectors from `easyi18n_core` into this package so
// the CLI's hand-written port of the contract (`lib/src/contract.dart`) is gated
// by the same JSON the backend and the runtime SDK are gated by. A path
// dependency is not an option (pub.dev forbids it), which is why the algorithms
// are reproduced here at all. Run from the package root:
//
//   dart run tool/sync_contract.dart           # copy core → vendored
//   dart run tool/sync_contract.dart --check   # CI: fail if they drifted
//
// This exists because "re-copy it by hand when the contract gains vectors" is a
// convention, not a gate: the copy silently lagged core by two vectors until
// #455. A missing source is a hard error on purpose — a guard that goes quiet
// when it cannot find what it guards is the bug it was written to prevent.
//
// `lib/src/contract.dart` is hand-maintained (the CLI ships no dependency on
// core) and is gated BY the vectors, not by this tool. `lib/src/xcode_json.dart`
// is the opposite: it is synced as source, so the two packages cannot disagree
// on a byte of the Xcode style at all.
import 'dart:io';

/// (source relative to core root) → (dest relative to this package root).
const _files = <String, String>{
  'test/i18n/contract_vectors.json': 'test/contract_vectors.json',
  // The Xcode JSON writer, synced as SOURCE (it imports nothing, so the same
  // bytes compile in both packages) — the export and the CLI's merge have to
  // agree byte-for-byte or Xcode and the sync PR reformat each other's work
  // forever. Its golden rides along: one catalog Xcode actually wrote, gating
  // both copies.
  'lib/src/formatters/xcode_json.dart': 'lib/src/xcode_json.dart',
  'test/formatters/fixtures/xcstrings/xcode_canonical.xcstrings':
      'test/fixtures/xcode_canonical.xcstrings',
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
      stdout.writeln('✓ vendored vectors are in sync with easyi18n_core');
      return;
    }
    stderr.writeln('✗ vendored vectors drifted from easyi18n_core:');
    for (final f in drifted) {
      stderr.writeln('  - $f');
    }
    stderr.writeln('Run: dart run tool/sync_contract.dart');
    exit(1);
  }
}
