import 'dart:convert';

import 'xcode_json.dart';

export 'xcode_json.dart' show writeXcodeStyleJson;

/// What happens to a key the server serves and the local catalog does not
/// carry. The two callers face opposite risks, so neither default is safe for
/// both.
enum XcstringsKeyPolicy {
  /// `sync`: the local catalog was just uploaded, so the server knows every
  /// key it has. A served-only key is therefore one deleted locally (the
  /// server keeps it as a disabled orphan) — re-adding it would resurrect a
  /// string the developer removed, on every sync.
  localOwnsKeySet,

  /// `pull`: nothing was uploaded, so the pull is the ONLY way a key created
  /// in the dashboard reaches the file. Served-only keys are appended (Xcode
  /// re-sorts them into place on its next save).
  union,
}

/// One base-language localization the merge replaced (#646): the local
/// catalog carried [forms] — form path (`text`, `plural.one`,
/// `device.iphone`, `subst.arg1.plural.one`) → the developer's text — that
/// the served catalog does not carry verbatim. The merge still applies the
/// served value (warn-and-apply; exempting the base language is refuted in
/// #646: it drops converted printf values, kills base plural forms, and
/// starves the empty shells Xcode creates), so when the file spells the tag
/// the way the server does this row is the only place the local text
/// survives. A tag the file spells differently ([lang] `EN` vs served `en`)
/// keeps its local entry — the merge writes by the served spelling, beside
/// it — but the row is still emitted: the served text now shadows the
/// local one in the same file, and which entry Xcode reads is not ours to
/// guess.
typedef XcstringsBaseReplacement = ({
  String key,
  String lang,
  Map<String, String> forms,
});

/// What [mergeXcstringsCatalog] produced: the catalog to write, plus every
/// base-language replacement it performed while producing it.
typedef XcstringsMergeResult = ({
  String content,
  List<XcstringsBaseReplacement> baseReplacements,
});

/// Merges served translations INTO the local String Catalog instead of
/// replacing it, and re-serializes in Xcode's exact style.
///
/// Why a merge (ci-sync.md, hallazgo del E2E 2026-08-12): opening a catalog in
/// Xcode rewrites the file — `" : "` separators, a **localized** key collation
/// (Finder-style, not Unicode order), re-added entries our parser drops (the
/// empty key), and Xcode-owned metadata (`extractionState`). A pull that
/// replaces the file with the server's rendering reverts all of that, Xcode
/// reverts it back, and every PR carries format churn forever. The local file
/// — which Xcode wrote — owns structure, order and extras; the server only
/// owns translated values. So: inject the served `localizations` per (key,
/// language) into the local document and print it back byte-stable.
XcstringsMergeResult mergeXcstringsCatalog({
  required String local,
  required String served,
  XcstringsKeyPolicy keyPolicy = XcstringsKeyPolicy.localOwnsKeySet,
}) {
  final Object? localDoc;
  final Object? servedDoc;
  try {
    // jsonDecode returns insertion-ordered maps, so the local file's key
    // order (Xcode's localized sort) survives decode → print untouched.
    localDoc = jsonDecode(local);
    servedDoc = jsonDecode(served);
  } on FormatException {
    // Unparseable local catalog: serve wins (the pre-merge behavior). The
    // next Xcode open normalizes it once. There is no readable local text
    // to report as replaced.
    return (
      content: normalizeXcstringsCatalog(served),
      baseReplacements: const [],
    );
  }
  if (localDoc is! Map<String, Object?> || servedDoc is! Map<String, Object?>) {
    return (
      content: normalizeXcstringsCatalog(served),
      baseReplacements: const [],
    );
  }
  final localStrings = localDoc['strings'];
  final servedStrings = servedDoc['strings'];
  if (localStrings is! Map<String, Object?> ||
      servedStrings is! Map<String, Object?>) {
    return (
      content: normalizeXcstringsCatalog(served),
      baseReplacements: const [],
    );
  }

  // #646: which language is the catalog's SOURCE. The local file's own
  // declaration wins — it is the file whose authorship the report protects —
  // with the served one as fallback; neither declares one → no rows, never a
  // crash. BCP-47 tags are case-insensitive, so the COMPARISON folds case,
  // but no spelling in the file is ever rewritten.
  final localBase = localDoc['sourceLanguage'];
  final servedBase = servedDoc['sourceLanguage'];
  final base = localBase is String && localBase.isNotEmpty
      ? localBase
      : servedBase is String && servedBase.isNotEmpty
      ? servedBase
      : null;
  final baseFolded = base?.toLowerCase();
  final baseReplacements = <XcstringsBaseReplacement>[];

  for (final entry in servedStrings.entries) {
    final servedEntry = entry.value;
    if (servedEntry is! Map<String, Object?>) {
      // The server can only ever deliver an object here; anything else is a
      // malformed payload, and there is nothing in it to merge.
      continue;
    }
    final localEntry = localStrings[entry.key];
    if (localEntry == null && keyPolicy == XcstringsKeyPolicy.union) {
      // Delivering a key the local file never had: take the served entry
      // whole (comment included), not just its translations.
      localStrings[entry.key] = servedEntry;
      continue;
    }
    if (localEntry is! Map<String, Object?>) {
      // Skipped under [XcstringsKeyPolicy.localOwnsKeySet], and whenever the
      // local file carries the key as something other than an object — a
      // malformed entry is still the developer's, never ours to overwrite.
      continue;
    }
    final servedLocs = servedEntry['localizations'];
    if (servedLocs is! Map<String, Object?>) continue;
    final localLocs =
        localEntry['localizations'] is Map<String, Object?>
            ? localEntry['localizations']! as Map<String, Object?>
            : <String, Object?>{};
    for (final lang in servedLocs.entries) {
      if (baseFolded != null && lang.key.toLowerCase() == baseFolded) {
        final row = _baseReplacement(entry.key, localLocs, lang.key, lang.value);
        if (row != null) baseReplacements.add(row);
      }
      localLocs[lang.key] = lang.value;
    }
    if (localLocs.isNotEmpty) localEntry['localizations'] = localLocs;
  }

  return (
    content: writeXcodeStyleJson(localDoc),
    baseReplacements: baseReplacements,
  );
}

/// The row for one key whose base-language localization the merge is about to
/// replace, or null when nothing the developer authored is being discarded:
/// no local base localization at all, an empty Xcode shell (blank values are
/// nobody's prose), or served text identical form-for-form (`state` and other
/// metadata are not compared — replacing them loses no authorship).
XcstringsBaseReplacement? _baseReplacement(
  String key,
  Map<String, Object?> localLocs,
  String servedLang,
  Object? servedLoc,
) {
  var lang = servedLang;
  var localLoc = localLocs[servedLang];
  if (localLoc == null) {
    // The file may spell the tag differently (`EN` vs `en`): fold to find it,
    // and report under the FILE's spelling — that is the one the developer
    // can search for.
    for (final e in localLocs.entries) {
      if (e.key.toLowerCase() == servedLang.toLowerCase()) {
        lang = e.key;
        localLoc = e.value;
        break;
      }
    }
  }
  if (localLoc == null) return null;
  final localForms = _localizationForms(localLoc);
  final servedForms = _localizationForms(servedLoc);
  final discarded = <String, String>{
    for (final f in localForms.entries)
      if (f.value.trim().isNotEmpty && servedForms[f.key] != f.value)
        f.key: f.value,
  };
  if (discarded.isEmpty) return null;
  return (key: key, lang: lang, forms: discarded);
}

/// Flattens one localization object into form path → text: a plain
/// `stringUnit` is `text`; `variations` nest as `plural.one`,
/// `device.iphone`, `device.iphone.plural.few`. Only `stringUnit.value` is
/// read — never `state`.
Map<String, String> _localizationForms(Object? loc) {
  final out = <String, String>{};
  _collectForms(loc, '', out);
  return out;
}

void _collectForms(Object? node, String prefix, Map<String, String> out) {
  if (node is! Map<String, Object?>) return;
  final unit = node['stringUnit'];
  if (unit is Map<String, Object?> && unit['value'] is String) {
    out[prefix.isEmpty ? 'text' : prefix] = unit['value']! as String;
  }
  final variations = node['variations'];
  if (variations is Map<String, Object?>) {
    for (final axis in variations.entries) {
      final forms = axis.value;
      if (forms is! Map<String, Object?>) continue;
      for (final form in forms.entries) {
        final path = prefix.isEmpty
            ? '${axis.key}.${form.key}'
            : '$prefix.${axis.key}.${form.key}';
        _collectForms(form.value, path, out);
      }
    }
  }
  // A multi-arg plural keeps its prose under `substitutions.<arg>.variations`
  // while the top-level `stringUnit` is only format tokens (`%1$#@arg1@`) —
  // without descending, the row would name the key but list a token as the
  // "discarded text" and the real prose would die unlogged.
  final substitutions = node['substitutions'];
  if (substitutions is Map<String, Object?>) {
    for (final sub in substitutions.entries) {
      final path = prefix.isEmpty
          ? 'subst.${sub.key}'
          : '$prefix.subst.${sub.key}';
      _collectForms(sub.value, path, out);
    }
  }
}

/// Re-prints a served catalog in Xcode's style with nothing to merge into —
/// the first pull on a machine that has no local catalog yet.
///
/// Writing the server's rendering verbatim would make the NEXT pull (which
/// merges, and therefore re-prints) rewrite the whole file, so a pull that
/// changed nothing would still land as a five-figure diff. Normalizing here
/// makes the first write and every later one byte-comparable. Unparseable
/// input passes through untouched: whatever it is, it is not ours to reshape.
String normalizeXcstringsCatalog(String served) {
  final Object? doc;
  try {
    doc = jsonDecode(served);
  } on FormatException {
    return served;
  }
  return doc is Map<String, Object?> ? writeXcodeStyleJson(doc) : served;
}

/// Every locale the catalog [content] carries in any entry's `localizations`,
/// in the file's own spelling.
///
/// `sync` compares this against the languages the server said it would deliver.
/// It has to read the file that was just WRITTEN, not the served bytes: the
/// merge above is a pure upsert with no deletion, so the written catalog is the
/// union of the served locales and whatever the developer's file already had —
/// and that union is the only thing a reviewer of the PR ever sees (#592).
///
/// **Null when the content is not a readable catalog**, which is not the same
/// answer as the empty set and must not collapse into it: the merge passes an
/// unparseable local file through untouched, and reading "no locales" out of
/// those bytes would let the caller announce that every configured language
/// went missing. An empty *readable* catalog really does carry no locales.
/// Whether [content] holds a single entry a fill could ever put a locale on,
/// i.e. one that is not `"shouldTranslate": false`. Null when the content is
/// not a readable catalog.
///
/// A catalog where every entry opted out is a legal, ordinary file — a
/// dev-only `InfoPlist.xcstrings` is one or two usage descriptions and "all of
/// them" is its normal state (#612). No fill will ever write a locale into it,
/// so the caller must not read "carries none of the configured languages" as
/// "this run failed to deliver them" and tell the operator to re-run: that is
/// advice that can never work, printed on every CI run forever.
bool? xcstringsHasTranslatableEntry(String content) {
  final entries = _xcstringsEntries(content);
  if (entries == null) return null;
  return entries.any((e) => e['shouldTranslate'] != false);
}

Set<String>? xcstringsLocales(String content) {
  final entries = _xcstringsEntries(content);
  if (entries == null) return null;
  final out = <String>{};
  for (final entry in entries) {
    final locs = entry['localizations'];
    if (locs is Map<String, Object?>) out.addAll(locs.keys);
  }
  return out;
}

/// Every `strings` entry of [content], or null when it is not a readable
/// catalog. Null and the empty list are different answers and neither caller
/// may collapse them.
List<Map<String, Object?>>? _xcstringsEntries(String content) {
  final Object? doc;
  try {
    doc = jsonDecode(content);
  } on FormatException {
    return null;
  }
  if (doc is! Map<String, Object?>) return null;
  final strings = doc['strings'];
  if (strings is! Map<String, Object?>) return null;
  return [
    for (final entry in strings.values)
      if (entry is Map<String, Object?>) entry,
  ];
}

/// Everything `doctor` reads off a catalog in ONE parse: the base language
/// Xcode stamped, how many entries it holds, how many of those a fill could
/// ever put a locale on, and the locales already in the file.
///
/// **Null when the content is not a readable catalog**, the same distinction
/// [xcstringsLocales] draws and for the same reason: "cannot read" must never
/// be reported as "carries nothing". `sync` keeps reading through
/// [xcstringsLocales] / [xcstringsHasTranslatableEntry] — its two answers are
/// pinned by their own contracts and this one must not widen them.
({String? sourceLanguage, int entries, int translatable, Set<String> locales})?
xcstringsCatalogSummary(String content) {
  final Object? doc;
  try {
    doc = jsonDecode(content);
  } on FormatException {
    return null;
  }
  if (doc is! Map<String, Object?>) return null;
  final strings = doc['strings'];
  if (strings is! Map<String, Object?>) return null;
  final locales = <String>{};
  var entries = 0;
  var translatable = 0;
  for (final entry in strings.values) {
    if (entry is! Map<String, Object?>) continue;
    entries++;
    if (entry['shouldTranslate'] != false) translatable++;
    final locs = entry['localizations'];
    if (locs is Map<String, Object?>) locales.addAll(locs.keys);
  }
  final base = doc['sourceLanguage'];
  return (
    sourceLanguage: base is String && base.isNotEmpty ? base : null,
    entries: entries,
    translatable: translatable,
    locales: locales,
  );
}
