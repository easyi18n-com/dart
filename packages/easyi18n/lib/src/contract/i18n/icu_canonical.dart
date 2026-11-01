/// Canonical ICU serialization for the **message token** (`messageToken`).
/// Frozen, normative, cross-SDK: a non-Dart SDK MUST reproduce these bytes
/// exactly so the token it computes for a source matches the one the backend
/// stored.
///
/// This is **written from scratch on purpose** - it does NOT reuse
/// `renderIcuPlural` (which orders categories by language, mutates Markdown via
/// `maybeMarkdown`, and does not escape literal `{`/`}`/`'`). None of those are
/// acceptable in a contract that must be byte-stable forever and reproducible
/// by third-party SDKs.
///
/// The canonical form is a **hashing artifact, not renderable ICU**: the
/// plural-variable name is normalized to a fixed placeholder and plural bodies
/// are escaped literally (placeholders inside a body become quoted), so the
/// string is unambiguous and reversible but is never fed to an ICU renderer.
/// The renderable ICU that ships in bundles comes from the formatters, not from
/// here.
///
/// Normative rules (frozen - the golden `contract_vectors.json` vectors are
/// the source of truth):
///
/// **Text path** (`TranslationText`): canonical = `canonicalizeSource(text)` -
/// Unicode NFC, line endings normalized to `\n`, outer whitespace trimmed,
/// internal whitespace and placeholders (`{name}`) preserved verbatim. No
/// ICU re-quoting: the authored string is the contract.
///
/// **Plural path** (`TranslationPlural`):
/// `{count, plural,<sp><selector>{<body>}<sp>…}` where:
/// - the plural variable is normalized to the fixed name [kCanonicalPluralVar]
///   (renaming the source variable does not churn the token; a future multi-var
///   form extends without re-hashing);
/// - selector order is **fixed and language-independent**: `=N` literals
///   ascending by N, then CLDR categories in [PluralCategory.values] order
///   (zero…other), then any non-CLDR selectors sorted lexicographically (so
///   nothing is silently dropped and order is deterministic across SDKs);
/// - each body is `canonicalizeSource`d then escaped with [escapeIcuLiteral]
///   (`'`→`''`, `{`→`'{'`, `}`→`'}'`) so the serialized string is unambiguous
///   and re-parseable.
/// - `other`-presence is NOT synthesized here (that is a validation concern);
///   the canonical form emits exactly the selectors present.
///
/// **Context** (`ctx`): NFC + outer trim, case-sensitive, `null`/empty/
/// whitespace-only ≡ no-ctx, control characters rejected. See [canonicalizeCtx].
library;

import '../models/translation_value.dart';
import 'cldr_plurals.dart';
import 'text_hash.dart' show canonicalizeSource;

/// The fixed plural-variable placeholder used by the canonical form. The source
/// variable name (e.g. `count`, `n`) is normalized to this so renaming it does
/// not change the message token.
const String kCanonicalPluralVar = 'count';

/// Canonical ICU serialization of [value] for message-token computation.
/// See library docs for the frozen rules.
String canonicalIcu(TranslationValue value) => switch (value) {
  TranslationText(:final text) => canonicalizeSource(text),
  TranslationPlural(:final forms) => _canonicalPlural(forms),
};

/// Escape a literal run for embedding inside a plural body using ICU quoting:
/// `'`→`''`, `{`→`'{'`, `}`→`'}'`. The mapping is applied per code point and is
/// injective (reversible), so distinct bodies never collide.
String escapeIcuLiteral(String s) {
  final buf = StringBuffer();
  for (final rune in s.runes) {
    switch (rune) {
      case 0x27: // '
        buf.write("''");
      case 0x7B: // {
        buf.write("'{'");
      case 0x7D: // }
        buf.write("'}'");
      default:
        buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

/// Canonicalize a context discriminator: NFC, outer-trim, case-preserved.
/// `null`, empty, and whitespace-only all collapse to `''` (≡ no-ctx). Throws
/// [ArgumentError] if the result contains a control character (C0 range or
/// DEL), which would corrupt the `\x1f`-separated token preimage.
String canonicalizeCtx(String? ctx) {
  if (ctx == null) return '';
  final normalized = canonicalizeSource(ctx);
  if (normalized.isEmpty) return '';
  for (final rune in normalized.runes) {
    if (rune <= 0x1F || rune == 0x7F) {
      throw ArgumentError.value(
        ctx,
        'ctx',
        'context must not contain control characters',
      );
    }
  }
  return normalized;
}

final RegExp _literalSelector = RegExp(r'^=(\d+)$');

String _canonicalPlural(Map<String, String> forms) {
  final cldrNames = {for (final c in PluralCategory.values) c.cldrName};
  // BigInt: same bytes as `int` for every N that fits one, and no throw past
  // it (#1923).
  final literals = <BigInt, String>{};
  final cldr = <String, String>{};
  final nonCldr = <String, String>{};

  for (final entry in forms.entries) {
    final match = _literalSelector.firstMatch(entry.key);
    if (match != null) {
      literals[BigInt.parse(match.group(1)!)] = entry.value;
    } else if (cldrNames.contains(entry.key)) {
      cldr[entry.key] = entry.value;
    } else {
      nonCldr[entry.key] = entry.value;
    }
  }

  final buf = StringBuffer('{$kCanonicalPluralVar, plural,');
  for (final n in literals.keys.toList()..sort()) {
    buf.write(' =$n{${_body(literals[n]!)}}');
  }
  for (final category in PluralCategory.values) {
    final name = category.cldrName;
    if (cldr.containsKey(name)) buf.write(' $name{${_body(cldr[name]!)}}');
  }
  for (final selector in nonCldr.keys.toList()..sort()) {
    buf.write(' $selector{${_body(nonCldr[selector]!)}}');
  }
  buf.write('}');
  return buf.toString();
}

String _body(String raw) => escapeIcuLiteral(canonicalizeSource(raw));
