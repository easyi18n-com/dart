import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'exceptions.dart';

/// One file of `catalogs:`: [name] as the config spells it, [path] resolved
/// against the config's directory.
class CatalogFile {
  const CatalogFile(this.name, this.path);

  final String name;
  final String path;

  static List<CatalogFile> of(Easyi18nConfig config, String configPath) => [
    for (final name in config.catalogs)
      CatalogFile(name, p.normalize(p.join(p.dirname(configPath), name))),
  ];
}

/// The String Catalogs of a `catalogs:` config, read once. The server keeps one
/// catalog per project, so `sync` uploads their entries as one file with every
/// key intact (a catalog is usually source-as-key: the key IS the text, and a
/// table prefix would rename it), and `pull` gives each served key back to the
/// file that holds it today.
class XcstringsCatalogs {
  XcstringsCatalogs._(this.files, this._docs, this._owner);

  final List<CatalogFile> files;
  final List<Map<String, Object?>> _docs;
  final Map<String, int> _owner;

  /// Refuses, by file name and before anything is sent or written, a file that
  /// is missing or not a catalog, a key two files hold (one key on the server,
  /// so a pull could not tell where it goes back to) and a base language the
  /// files do not share.
  factory XcstringsCatalogs.read(List<CatalogFile> files) {
    final docs = <Map<String, Object?>>[];
    final owner = <String, int>{};
    for (final (i, file) in files.indexed) {
      final f = File(file.path);
      if (!f.existsSync()) throw CliException('Catalog not found: ${file.path}');
      final Object? doc;
      try {
        doc = jsonDecode(f.readAsStringSync());
      } on FormatException catch (e) {
        throw CliException('${file.name} is not valid JSON: ${e.message}');
      }
      if (doc is! Map<String, Object?> || doc['strings'] is! Map) {
        throw CliException('${file.name} is not a String Catalog.');
      }
      if (docs.isNotEmpty && doc['sourceLanguage'] != docs.first['sourceLanguage']) {
        throw CliException(
          '${file.name} has base language "${doc['sourceLanguage'] ?? 'none'}" but '
          '${files.first.name} has "${docs.first['sourceLanguage'] ?? 'none'}". A project '
          'has one base language. Nothing was sent or written.',
          code: 'catalog_base_language_mismatch',
          details: {'files': [files.first.name, file.name]},
        );
      }
      docs.add(doc);
      for (final key in (doc['strings'] as Map).keys.cast<String>()) {
        final first = owner[key];
        if (first != null) {
          throw CliException(
            'The key `$key` is in both ${files[first].name} and ${file.name}. '
            'It is one key on the server, so a pull could not tell which file '
            'it goes back to. Rename it in one of them. Nothing was sent or written.',
            code: 'catalog_key_collision',
            details: {'key': key, 'files': [files[first].name, file.name]},
          );
        }
        owner[key] = i;
      }
    }
    return XcstringsCatalogs._(files, docs, owner);
  }

  /// The one upload: the first file's document with the entries of all.
  Uint8List get upload => utf8.encode(jsonEncode({
    ..._docs.first,
    'strings': {for (final doc in _docs) ...(doc['strings'] as Map)},
  }));

  /// [served] cut into one document per file (parallel to [files]), each with
  /// the served entries of the keys that file holds. [unplaced] are the served
  /// keys no file holds, which nothing writes.
  ({List<String> parts, List<String> unplaced}) split(String served) {
    final Object? doc;
    try {
      doc = jsonDecode(served);
    } on FormatException {
      throw CliException('The served catalog is not valid JSON.');
    }
    if (doc is! Map<String, Object?> || doc['strings'] is! Map) {
      throw CliException('The served catalog is not a String Catalog.');
    }
    final entries = (doc['strings'] as Map).cast<String, Object?>();
    return (
      parts: [
        for (var i = 0; i < files.length; i++)
          jsonEncode({
            ...doc,
            'strings': {
              for (final e in entries.entries)
                if (_owner[e.key] == i) e.key: e.value,
            },
          }),
      ],
      unplaced: [
        for (final key in entries.keys)
          if (!_owner.containsKey(key)) key,
      ],
    );
  }
}
