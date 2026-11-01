import 'dart:convert';
import 'dart:io';

import 'package:easyi18n/src/contract/i18n/icu_canonical.dart';
import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored contract must reproduce the SAME golden vectors as the backend
/// (`easyi18n_core/test/i18n/contract_vectors.json`). The JSON is copied verbatim
/// into the SDK by `tool/sync_contract.dart`; this test is the anti-drift gate:
/// if the vendored algorithm ever diverges from the backend's, a token/hash
/// stops matching here before it can ship a bundle the runtime can't resolve.
void main() {
  final raw =
      File('lib/src/contract/contract_vectors.json').readAsStringSync();
  final vectors = jsonDecode(raw) as Map<String, dynamic>;

  TranslationValue valueOf(Map<String, dynamic> v) {
    if (v['kind'] == 'text') return TranslationText(v['source'] as String);
    final forms = (v['source'] as Map).map(
      (k, val) => MapEntry(k as String, val as String),
    );
    return TranslationPlural(forms);
  }

  group('token vectors (golden)', () {
    test('algo version matches the JSON header', () {
      expect(vectors['messageTokenAlgo'], kMessageTokenAlgoVersion);
    });
    for (final entry in vectors['tokens'] as List) {
      final v = entry as Map<String, dynamic>;
      final name = v['name'] as String;
      test(name, () {
        final value = valueOf(v);
        final ctx = v['ctx'] as String?;
        expect(canonicalIcu(value), v['canonical'],
            reason: 'canonicalIcu drift for "$name"');
        expect(messageTokenForValue(value, ctx: ctx), v['token'],
            reason: 'messageToken drift for "$name"');
        expect(messageToken(v['canonical'] as String, ctx: ctx), v['token']);
      });
    }
  });

  group('bundle hash vectors (golden)', () {
    test('schema version matches the JSON header', () {
      expect(vectors['bundleSchemaVersion'], kBundleSchemaVersion);
    });
    for (final entry in vectors['bundles'] as List) {
      final b = entry as Map<String, dynamic>;
      final locale = b['locale'] as String;
      test('bundle $locale', () {
        final messages = (b['messages'] as Map).cast<String, String>();
        final tokenIndex = (b['tokenIndex'] as Map).cast<String, String>();
        final hash = computeBundleHash(
          schemaVersion: kBundleSchemaVersion,
          locale: locale,
          messages: messages,
          tokenIndex: tokenIndex,
        );
        expect(hash, b['bundleHash'], reason: 'bundleHash drift for $locale');
        expect(
          Bundle.compute(
            locale: locale,
            messages: messages,
            tokenIndex: tokenIndex,
          ).bundleHash,
          b['bundleHash'],
        );
      });
    }
  });

  group('canonical invariants', () {
    test('empty/whitespace/null ctx are equivalent', () {
      const value = TranslationText('Open');
      final base = messageTokenForValue(value);
      expect(messageTokenForValue(value, ctx: ''), base);
      expect(messageTokenForValue(value, ctx: '   '), base);
    });
  });

  // `bundle.dart` is hand-maintained here (not synced by sync_contract.dart),
  // so its encoder needs the goldens as much as the synced files do. The other
  // new blocks in the JSON (`revisions`, `localeRenders`) have no port in this
  // runtime — they are gated in core and in the plugin.
  group('canonical json vectors (golden)', () {
    final cases =
        (vectors['canonicalJson'] as List).cast<Map<String, dynamic>>();

    test('the file still has canonical json vectors', () {
      expect(cases, isNotEmpty);
    });

    for (final v in cases) {
      test(v['name'] as String, () {
        expect(canonicalJsonEncode(v['value']), v['canonical'],
            reason: 'canonicalJsonEncode drift for "${v['name']}"');
      });
    }
  });
}
