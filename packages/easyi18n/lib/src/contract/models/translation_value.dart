/// Vendored, flat copy of the core `TranslationValue` (translation-API
/// contract). The runtime SDK only needs the sealed type + `fromJson`/`toJson`,
/// so this drops the freezed/json_serializable converter the backend uses -
/// keeping it a plain, dependency-light value the vendored hashing files
/// (`text_hash.dart`, `icu_canonical.dart`) can pattern-match on.
///
/// Byte-parity with the backend is guaranteed by the golden vectors
/// (`contract_vectors.json`), not by sharing code.
library;

import 'package:meta/meta.dart';

/// A translation payload - either a plain [TranslationText] for a non-plural
/// source, or a [TranslationPlural] map of CLDR plural categories to strings.
@immutable
sealed class TranslationValue {
  const TranslationValue();

  /// Decode either a String or a `Map<String, String>` payload into the
  /// matching variant. Throws if the JSON is neither.
  factory TranslationValue.fromJson(Object json) {
    if (json is String) return TranslationText(json);
    if (json is Map) {
      return TranslationPlural({
        for (final e in json.entries) e.key as String: e.value as String,
      });
    }
    throw ArgumentError.value(
      json,
      'json',
      'TranslationValue expected String or Map, got ${json.runtimeType}',
    );
  }

  Object toJson();
}

class TranslationText extends TranslationValue {
  const TranslationText(this.text);
  final String text;

  @override
  Object toJson() => text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is TranslationText && other.text == text);

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TranslationText($text)';
}

/// NOTE: unlike `easyi18n_core`'s twin, this one has no `.normalized`
/// constructor. Core enforces "a form is present with text or absent" (#492)
/// at its doors — Firestore, the importers, the `/v1` payloads — and the SDK
/// has none of those: it only pattern-matches values inside the contract
/// recipes, and a delivered bundle carries rendered ICU strings, not form
/// maps. If the SDK ever parses raw values, port the invariant with it.
class TranslationPlural extends TranslationValue {
  const TranslationPlural(this.forms);
  final Map<String, String> forms;

  @override
  Object toJson() => forms;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TranslationPlural && _mapEquals(other.forms, forms));

  @override
  int get hashCode {
    var h = 0;
    for (final e in forms.entries) {
      h ^= e.key.hashCode ^ e.value.hashCode;
    }
    return h;
  }

  @override
  String toString() => 'TranslationPlural($forms)';
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}
