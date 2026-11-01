import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'contract.dart';
import 'delivery.dart';
import 'exceptions.dart';
import 'scaffold.dart';

/// The offline floor of a Mode B Flutter app: `assets/easyi18n/<locale>.json`,
/// the bundles `Easyi18nScope` loads before any network call. `init` creates
/// the folder empty; `pull` fills it with the verified content served by the
/// live delivery manifest (#1835).
class OfflineFloor {
  OfflineFloor._(this.dir, this._pubspec);

  final Directory dir;
  final String _pubspec;

  /// The floor of the app at [root], or null when its pubspec does not bundle
  /// `assets/easyi18n/`: files written there would never reach the app.
  static OfflineFloor? of(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    try {
      final content = pubspec.readAsStringSync();
      if (!floorRegistered(content)) return null;
      return OfflineFloor._(Directory(p.join(root, 'assets', 'easyi18n')), content);
    } on FileSystemException {
      return null;
    }
  }

  /// Every locale the manifest serves ([lang] narrows it to one), as
  /// `{path: content}`. Each bundle is checked against its content address:
  /// the SDK loads a baked bundle without verifying it.
  Future<Map<String, String>> fetch(
    DeliveryClient client,
    String projectId, {
    String? lang,
  }) async {
    final manifest = await client.fetchManifest(projectId);
    if (manifest.statusCode != 200 || manifest.revision == null) {
      throw CliException(
        'Could not bake the offline floor: GET '
        '${manifest.uri} -> HTTP ${manifest.statusCode}'
        '${manifest.errorMessage == null ? '' : ' (${manifest.errorMessage})'}.',
      );
    }
    final files = <String, String>{};
    for (final locale in manifest.locales.keys.toList()..sort()) {
      if (lang != null && locale != lang) continue;
      if (!RegExp(r'^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*$').hasMatch(locale)) {
        throw CliException('Invalid offline-floor locale "$locale".');
      }
      if (!floorRegistered(_pubspec, locale: locale)) {
        throw CliException('assets/easyi18n/$locale.json is not registered '
            "in pubspec.yaml; run 'easyi18n init', then pull again.");
      }
      final ref = manifest.locales[locale]!;
      final bundle = await client.fetchBundle(
        ref.url,
        expectedHash: ref.bundleHash,
      );
      if (bundle.locale != locale) {
        throw CliException(
          'The manifest serves "${bundle.locale}" as $locale; '
          'the offline floor was not baked.',
        );
      }
      final json = {
        'schemaVersion': kBundleSchemaVersion,
        'locale': locale,
        'bundleHash': ref.bundleHash,
        'messages': bundle.messages,
        'tokenIndex': bundle.tokenIndex,
      };
      files[p.join(dir.path, '$locale.json')] =
          '${const JsonEncoder.withIndent('  ').convert(json)}\n';
    }
    return files;
  }
}
