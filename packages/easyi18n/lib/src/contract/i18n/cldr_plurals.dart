/// CLDR plural categories for a given locale.
///
/// The table is GENERATED from the Unicode CLDR cardinal plural rules by
/// `tool/gen-cldr-plurals.py` (see `cldr_plural_data.dart`), and gated against
/// the vendored upstream file by `test/i18n/cldr_source_agreement_test.dart` —
/// it is never edited by hand.
///
/// Lookup honours a region: CLDR states rules for `pt-PT` separately from `pt`
/// (European Portuguese keeps `0` plural, Brazilian does not), so the full
/// locale is tried before falling back to the language subtag.
library;

part 'cldr_plural_data.dart';

/// CLDR plural categories. The set returned by [pluralFormsFor] is a subset
/// of these.
enum PluralCategory { zero, one, two, few, many, other }

/// Returns the ordered set of plural categories that [langCode] uses.
/// `other` is always present (every CLDR language has it). Order is
/// canonical CLDR order - important for golden tests where the emitted
/// `{count, plural, ...}` strings must be byte-stable.
///
/// An unmodelled language gets [kPluralFallbackCategories]; ask
/// [isPluralModelled] when the difference matters.
List<PluralCategory> pluralFormsFor(String langCode) =>
    lookupPluralTable(_kCldrCategories, langCode) ?? _fallbackCategories;

/// Whether CLDR categories are stated for [langCode], as opposed to guessed.
/// CLDR states rules for 217 locales, 210 of which are among the catalogue's
/// 638 base languages: the fallback still answers for the other 428, so it is
/// reachable — just no longer the common case.
// NOT the guard for a gettext consumer — `gettextRuleFor(...).isModelled` is.
// This answers "does CLDR state CATEGORIES", which is a weaker question than
// "do we have a rule": the two tables differ by well over a hundred locales, so
// `sl` is CLDR-modelled with four categories while its gettext answer is the
// 2-form guess, and `hi` is CLDR-modelled with the same two categories as the
// fallback but the opposite boundary (CLDR `hi one` is `i = 0 or n = 1`, so
// zero is singular). Both flags are pinned per locale in the `pluralForms`
// block of `contract_vectors.json` (#486), with rows that disagree.
//
// wired-ignore: published for consumers outside this repo. R8 reports this as
// called, but those "call sites" are the [isPluralModelled] links in the
// docblocks above.
bool isPluralModelled(String langCode) =>
    lookupPluralTable(_kCldrCategories, langCode) != null;

/// Resolves [langCode] against a table keyed by lowercase, `-` separated
/// locales, truncating one subtag at a time: `pt-PT` before `pt`, so a
/// region-specific rule wins over its language's.
///
/// Shared with `gettext_rules.dart` so both tables answer the same locale the
/// same way — a rule that applied to `pt` but not to `pt-PT` in one table and
/// not the other is the drift the agreement test exists to catch.
///
/// This replaced a `basePluralLanguage` that dropped region and script before
/// the lookup: with it, one of `pt` / `pt-PT` was always answered with the
/// other's rule. A port of these tables has to port this resolution too.
T? lookupPluralTable<T>(Map<String, T> table, String langCode) {
  final subtags = langCode.toLowerCase().replaceAll('_', '-').split('-');
  final hit = table[subtags.join('-')];
  if (hit != null) return hit;

  // `pt-Latn-PT` must not answer with Brazil's rule: truncating right-to-left
  // drops the region before the script, so try language+region on the way
  // down. Region is a 2-letter or 3-digit subtag (BCP-47).
  final region = subtags.skip(1).firstWhere(
        (s) => RegExp(r'^([a-z]{2}|[0-9]{3})$').hasMatch(s),
        orElse: () => '',
      );
  if (subtags.length > 2 && region.isNotEmpty) {
    final byRegion = table['${subtags.first}-$region'];
    if (byRegion != null) return byRegion;
  }

  for (var i = subtags.length - 1; i > 0; i--) {
    final byPrefix = table[subtags.take(i).join('-')];
    if (byPrefix != null) return byPrefix;
  }
  return null;
}

/// What an unmodelled language is assumed to do, shared by the CLDR categories
/// and the gettext rule so the two cannot drift apart again.
///
/// Two forms, not one. The alternative — collapsing to `other` — reads as
/// "this language has no singular", which silently drops the singular field
/// from the editor, from the fill prompt and from every export. Two forms is
/// still a **guess**: it is wrong for a language whose singular is not
/// `n == 1` (French is `n > 1`, and it is only right because it is modelled).
/// Anything that cannot absorb a wrong plural must branch on the flag for the
/// table it is reading — [isPluralModelled] for the categories, and
/// `gettextRuleFor(...).isModelled` for the rule. They are not
/// interchangeable: the gettext table states far fewer locales, so a locale
/// can be CLDR-modelled and still get the guessed header.
///
/// Named in backticks rather than linked: this file is vendored verbatim into
/// the published SDK, which does not ship the gettext table, so a doc link
/// here would resolve in core and dangle there.
const List<PluralCategory> kPluralFallbackCategories = [
  PluralCategory.one,
  PluralCategory.other,
];

/// The `Plural-Forms` header matching [kPluralFallbackCategories].
const String kPluralFallbackHeader = 'nplurals=2; plural=(n != 1);';

/// [kPluralFallbackCategories] as CLDR names, for the gettext table (a const
/// cannot map an enum). The two are kept in step by
/// `plural_rules_agreement_test.dart`, which compares them directly.
const List<String> kPluralFallbackFormNames = ['one', 'other'];

const List<PluralCategory> _fallbackCategories = kPluralFallbackCategories;

extension PluralCategoryName on PluralCategory {
  /// CLDR canonical lowercase name (`one`, `other`, `few`, ...).
  String get cldrName => switch (this) {
    PluralCategory.zero => 'zero',
    PluralCategory.one => 'one',
    PluralCategory.two => 'two',
    PluralCategory.few => 'few',
    PluralCategory.many => 'many',
    PluralCategory.other => 'other',
  };
}
