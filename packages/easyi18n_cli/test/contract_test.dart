import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/contract.dart';
import 'package:test/test.dart';

/// The CLI's contract must be byte-exact with the runtime SDK and the backend.
/// `contract_vectors.json` is copied verbatim from
/// `packages/easyi18n_core/test/i18n/contract_vectors.json` by
/// `tool/sync_contract.dart` — never edit it here. That tool's `--check` runs in
/// CI and at release, so a stale copy is red rather than a convention nobody
/// remembers (it silently lagged core by two vectors until #455).
void main() {
  final raw =
      jsonDecode(File('test/contract_vectors.json').readAsStringSync())
          as Map<String, dynamic>;

  test('algo version matches the vectors file', () {
    expect(kMessageTokenAlgoVersion, raw['messageTokenAlgo']);
  });

  group('text vectors', () {
    final vectors = (raw['tokens'] as List).cast<Map<String, dynamic>>().where(
      (v) => v['kind'] == 'text',
    );
    // Only the text vectors apply: the CLI has no plural path (statically
    // extracted tr() sources are always text).
    test('the file still has text vectors', () {
      expect(vectors, isNotEmpty);
    });

    for (final v in vectors) {
      test(v['name'] as String, () {
        final source = v['source'] as String;
        final ctx = v['ctx'] as String?;
        expect(canonicalizeSource(source), v['canonical']);
        expect(messageTokenForText(source, ctx: ctx), v['token']);
      });
    }
  });

  group('canonicalizeCtx', () {
    test('null, empty and whitespace-only collapse to no-ctx', () {
      expect(canonicalizeCtx(null), '');
      expect(canonicalizeCtx(''), '');
      expect(canonicalizeCtx('   '), '');
      expect(
        messageTokenForText('Open', ctx: '  '),
        messageTokenForText('Open'),
      );
    });

    test('rejects control characters', () {
      expect(() => canonicalizeCtx('a\x00b'), throwsArgumentError);
    });
  });

  test('canonicalization: CRLF, NFC and outer trim', () {
    expect(canonicalizeSource('  a\r\nb\r'), 'a\nb');
    // e + combining acute → precomposed é.
    expect(canonicalizeSource('café'), 'café');
  });

  // The CLI verifies a downloaded bundle's content address (`delivery.dart`),
  // so its hand-copied encoder is load-bearing here too: a drift would make it
  // reject bundles the backend published correctly.
  group('canonical json vectors', () {
    for (final v
        in (raw['canonicalJson'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'] as String, () {
        expect(canonicalJsonEncode(v['value']), v['canonical']);
      });
    }
  });

  group('bundle hash vectors', () {
    for (final b in (raw['bundles'] as List).cast<Map<String, dynamic>>()) {
      test('bundle ${b['locale']}', () {
        expect(
          computeBundleHash(
            schemaVersion: raw['bundleSchemaVersion'] as int,
            locale: b['locale'] as String,
            messages: (b['messages'] as Map).cast<String, String>(),
            tokenIndex: (b['tokenIndex'] as Map).cast<String, String>(),
          ),
          b['bundleHash'],
        );
      });
    }
  });
}
