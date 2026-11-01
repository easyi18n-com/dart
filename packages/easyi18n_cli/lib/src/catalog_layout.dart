import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'exceptions.dart';

/// The `sourceLayout` values whose base-language catalog is several files
/// (#2093): i18next namespaces (`locales/en/<ns>.json`) and Transloco scopes
/// (`public/i18n/en.json` plus `public/i18n/<scope>/en.json`). The server
/// keeps one catalog per project, so `sync` uploads the files merged, each
/// under its namespace or scope, and `pull` splits every language back.
const Set<String> mergedLayouts = {'namespaces', 'scopes'};

/// One base-language file of a merged layout.
class CatalogPart {
  const CatalogPart(this.prefix, this.name, this.file);

  /// The first segment of the file's keys on the server: the namespace or
  /// the scope directory. Empty for the Transloco root file, whose keys stay
  /// bare.
  final String prefix;

  /// The file as messages name it, relative to the project.
  final String name;

  /// The file on disk.
  final String file;

  /// Where `pull` writes [lang]'s copy of this file, relative to `output:`.
  String target(String layout, String lang) => layout == 'namespaces'
      ? '$lang/$prefix.json'
      : prefix.isEmpty ? '$lang.json' : '$prefix/$lang.json';
}

/// The prefix [layout] gives [relative] (a selected file, relative to
/// `sourceRoot` with forward slashes), or null when the layout has no place
/// for it: a namespace is a file directly in the root, a scope a directory
/// one level down, and the scopes' root file is `source:`.
String? partPrefix(String layout, String relative, {required bool isSource}) {
  final segments = relative.split('/');
  return switch (layout) {
    'namespaces' when segments.length == 1 =>
      relative.substring(0, relative.length - '.json'.length),
    'scopes' when segments.length == 1 && isSource => '',
    'scopes' when segments.length == 2 => segments.first,
    _ => null,
  };
}

/// The part a key of the merged catalog belongs to: the longest prefix the
/// key equals or continues after a dot, else the root file. Upload and pull
/// both ask this, so a key the upload accepts goes back to the file it came
/// from.
CatalogPart? ownerOf(String key, List<CatalogPart> parts) {
  CatalogPart? owner;
  for (final part in parts) {
    final matches = part.prefix.isEmpty ||
        key == part.prefix || key.startsWith('${part.prefix}.');
    if (matches && (owner == null || part.prefix.length > owner.prefix.length)) {
      owner = part;
    }
  }
  return owner;
}

/// The one upload of [parts]: each file's object under its prefix, the root
/// file's keys bare. Refuses, before upload, a key that [ownerOf] hands
/// to another file: the nested export keeps one of the two (N4b and N4c of
/// #2093), and a pull would write it into that other file.
({Uint8List bytes, String format}) mergeCatalog(List<CatalogPart> parts) {
  final merged = <String, Object?>{};
  for (final part in parts) {
    final content = readCatalogPart(part);
    for (final key in _flat(content).keys) {
      final full = part.prefix.isEmpty ? key : '${part.prefix}.$key';
      final owner = ownerOf(full, parts)!;
      if (owner != part) {
        throw CliException(
          '`$full` is a key of ${part.name}, but on the server it falls under '
          '`${owner.prefix}`, which holds the keys of ${owner.name}, so a pull '
          'would write it there. Rename the key. Nothing was uploaded.',
          code: 'catalog_key_collision',
          details: {'key': full, 'files': [part.name, owner.name]},
        );
      }
    }
    if (part.prefix.isEmpty) {
      merged.addAll(content);
    } else if (content.isNotEmpty) {
      merged[part.prefix] = content;
    }
  }
  // The server names the format from the bytes and refuses another one, and
  // an object under an `@key` is metadata that nests nothing.
  final nests = merged.entries
      .any((e) => e.value is Map && !e.key.startsWith('@'));
  return (bytes: utf8.encode(jsonEncode(merged)), format: nests ? 'nested_json' : 'json');
}

/// One language of the merged catalog, as [served], split into the files of
/// [parts] by their path relative to `output:`. Each file takes the key order
/// and the shape of its base file, so `home.title` stays flat where the base
/// writes it flat; a served key the base file lacks goes flat at the end.
/// [unplaced] lists the keys no file owns, which nothing writes.
({Map<String, String> files, List<String> unplaced}) splitCatalog(
    String served, String lang, String layout, List<CatalogPart> parts) {
  final decoded = jsonDecode(served);
  if (decoded is! Map) {
    throw CliException('The served $lang file is not a JSON object.');
  }
  final values = {for (final part in parts) part: <String, Object?>{}};
  final unplaced = <String>[];
  for (final e in _flat(decoded.cast<String, Object?>()).entries) {
    final owner = ownerOf(e.key, parts);
    if (owner == null || e.key == owner.prefix) {
      unplaced.add(e.key);
    } else {
      values[owner]![owner.prefix.isEmpty
          ? e.key : e.key.substring(owner.prefix.length + 1)] = e.value;
    }
  }
  return (
    files: {
      for (final part in parts)
        part.target(layout, lang): _shapedLike(readCatalogPart(part), values[part]!),
    },
    unplaced: unplaced,
  );
}

/// The decoded base file of [part], refused by name when it is not a JSON
/// object of keys.
Map<String, Object?> readCatalogPart(CatalogPart part) {
  final Object? decoded;
  try {
    decoded = jsonDecode(File(part.file).readAsStringSync());
  } on FormatException catch (e) {
    throw CliException('${part.name} is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw CliException('${part.name} is not a JSON object of keys.');
  }
  return decoded.cast<String, Object?>();
}

String _shapedLike(Map<String, Object?> base, Map<String, Object?> values) {
  final left = Map.of(values);
  Map<String, Object?> place(Map<String, Object?> node, String path) {
    final shaped = <String, Object?>{};
    for (final e in node.entries) {
      final key = '$path${e.key}';
      if (e.value is Map) {
        final child = place((e.value as Map).cast<String, Object?>(), '$key.');
        if (child.isNotEmpty) shaped[e.key] = child;
      } else if (left.containsKey(key)) {
        shaped[e.key] = left.remove(key);
      }
    }
    return shaped;
  }
  final shaped = {...place(base, ''), ...left};
  return '${const JsonEncoder.withIndent('  ').convert(shaped)}\n';
}

Map<String, Object?> _flat(Map<String, Object?> node, [String path = '']) => {
  for (final e in node.entries)
    if (e.value is Map)
      ..._flat((e.value as Map).cast<String, Object?>(), '$path${e.key}.')
    else
      '$path${e.key}': e.value,
};
