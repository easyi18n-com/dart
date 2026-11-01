import 'dart:io';

import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/delivery/bundle_store.dart';
import 'package:easyi18n/src/delivery/file_bundle_store.dart';
import 'package:flutter_test/flutter_test.dart';

Bundle sample(String locale) => Bundle.compute(
      locale: locale,
      messages: {'k': 'v-$locale'},
      tokenIndex: {'tok': 'k'},
    );

void main() {
  group('FileBundleStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('easyi18n_store_test');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('round-trips a content-addressed bundle', () async {
      final store = FileBundleStore(dir);
      final bundle = sample('es');
      await store.saveBundle(bundle);

      final loaded = await store.loadBundle('es', bundle.bundleHash);
      expect(loaded, isNotNull);
      expect(loaded!.messages['k'], 'v-es');
      expect(loaded.bundleHash, bundle.bundleHash);
    });

    test('missing bundle → null', () async {
      final store = FileBundleStore(dir);
      expect(await store.loadBundle('es', 'nope'), isNull);
    });

    test('round-trips delivery state per channel', () async {
      final store = FileBundleStore(dir);
      const state = DeliveryState(
        manifestEtag: '"v3"',
        hashByLocale: {'es': 'h-es', 'en': 'h-en'},
      );
      await store.saveState('production', state);

      final loaded = await store.loadState('production');
      expect(loaded.manifestEtag, '"v3"');
      expect(loaded.hashByLocale, {'es': 'h-es', 'en': 'h-en'});
      // A different channel is independent.
      expect((await store.loadState('staging')).manifestEtag, isNull);
    });

    test('round-trips the manifest stored beside its etag', () async {
      const manifest = {
        'project': 'p',
        'revision': 'r',
        'locales': {
          'es': {'version': 'r', 'bundleHash': 'h-es', 'url': '/es.json'},
        },
      };
      await FileBundleStore(dir).saveState(
          'production',
          const DeliveryState(
              manifestEtag: '"v3"',
              hashByLocale: {'es': 'h-es'},
              manifest: manifest));

      final loaded = await FileBundleStore(dir).loadState('production');
      expect(loaded.manifestEtag, '"v3"');
      expect(loaded.manifest, manifest);
    });

    test('copyWith replaces the manifest or keeps it', () {
      const old = DeliveryState(manifest: {'revision': 'a'});
      expect(old.copyWith(manifest: {'revision': 'b'}).manifest,
          {'revision': 'b'});
      expect(old.copyWith(manifestEtag: '"v2"').manifest, {'revision': 'a'});
    });

    test('reads the state file 0.2.0 wrote, which has no manifest', () async {
      await File('${dir.path}/state-production.json').writeAsString(
          '{"manifestEtag":"\\"4455\\"","hashByLocale":{"en":"8d3a","es":"0e71"}}');

      final loaded = await FileBundleStore(dir).loadState('production');
      expect(loaded.manifestEtag, '"4455"');
      expect(loaded.hashByLocale, {'en': '8d3a', 'es': '0e71'});
      expect(loaded.manifest, isNull);
    });

    test('survives a fresh store instance over the same dir (persistence)',
        () async {
      final bundle = sample('fr');
      await FileBundleStore(dir).saveBundle(bundle);
      final reopened = await FileBundleStore(dir).loadBundle('fr', bundle.bundleHash);
      expect(reopened!.messages['k'], 'v-fr');
    });

    test('rejects a traversing locale (no write, no load)', () async {
      final store = FileBundleStore(dir);
      // A malicious manifest author can compute a valid hash for any locale,
      // so the store itself must reject an unsafe path segment.
      final evil = Bundle.compute(
        locale: '../../pwned',
        messages: {'k': 'v'},
        tokenIndex: {'tok': 'k'},
      );
      await store.saveBundle(evil);
      expect(Directory('${dir.path}/bundles').existsSync(), isFalse);
      expect(await store.loadBundle('../../pwned', evil.bundleHash), isNull);
    });

    test('rejects a non-hex bundle hash on load', () async {
      final store = FileBundleStore(dir);
      expect(await store.loadBundle('es', '../../etc/passwd'), isNull);
    });

    test('rejects a traversing channel loudly (developer error)', () async {
      final store = FileBundleStore(dir);
      // channel is developer config, so an unsafe value throws rather than
      // silently disabling persistence.
      expect(
        () => store.saveState('../../evil', const DeliveryState()),
        throwsArgumentError,
      );
      expect(() => store.loadState('../../evil'), throwsArgumentError);
      expect(dir.listSync(), isEmpty);
    });

    test('accepts an uppercase-hex bundle hash', () async {
      final store = FileBundleStore(dir);
      // A producer emitting uppercase hex must not be silently dropped.
      final upper = 'A' * 64;
      expect(await store.loadBundle('es', upper), isNull); // valid path, no file
      expect(dir.listSync(), isEmpty);
    });
  });

  group('InMemoryBundleStore', () {
    test('round-trips bundle + state in memory', () async {
      final store = InMemoryBundleStore();
      final bundle = sample('de');
      await store.saveBundle(bundle);
      await store.saveState(
          'production', const DeliveryState(hashByLocale: {'de': 'x'}));

      expect((await store.loadBundle('de', bundle.bundleHash))!.messages['k'],
          'v-de');
      expect((await store.loadState('production')).hashByLocale, {'de': 'x'});
    });
  });
}
