import 'dart:convert';

import 'package:easyi18n/easyi18n.dart';
import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/manifest.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A delivery origin that honours `If-None-Match` and logs every request, so a
/// test can tell a 304 from a 200 and see which bundles were fetched.
class _Origin {
  _Origin(this.bundles, this.etag, {this.sendsEtag = true});

  Map<String, Bundle> bundles;
  String etag;
  final bool sendsEtag;
  final List<String> log = [];

  Manifest get manifest => Manifest(
        project: 'p',
        revision: etag,
        locales: {
          for (final e in bundles.entries)
            e.key: ManifestLocale(
              version: etag,
              bundleHash: e.value.bundleHash,
              url: 'https://cdn/${e.key}.json',
            ),
        },
      );

  http.Client client() => MockClient((req) async {
        if (req.url.path.endsWith('manifest')) {
          final sent = req.headers['If-None-Match'];
          if (sent == etag) {
            log.add('manifest 304');
            return http.Response('', 304);
          }
          log.add(sent == null ? 'manifest 200' : 'manifest 200 after $sent');
          return http.Response(jsonEncode(manifest.toJson()), 200,
              headers: {if (sendsEtag) 'etag': etag});
        }
        final locale = req.url.pathSegments.last.split('.').first;
        log.add('bundle $locale');
        return http.Response(jsonEncode(bundles[locale]!.toJson()), 200);
      });

  DeliveryService delivery(BundleStore store) => DeliveryService(
        client: CdnClient(client()),
        store: store,
        manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
      );
}

/// Counts the store calls a refresh makes, to pin what a 304 costs.
class _CountingStore extends InMemoryBundleStore {
  int bundleReads = 0;
  int stateWrites = 0;

  @override
  Future<Bundle?> loadBundle(String locale, String bundleHash) {
    bundleReads++;
    return super.loadBundle(locale, bundleHash);
  }

  @override
  Future<void> saveState(String channel, DeliveryState state) {
    stateWrites++;
    return super.saveState(channel, state);
  }
}

Bundle _bundle(String locale, String greeting) {
  final token = messageTokenForValue(const TranslationText('Hello'));
  return Bundle.compute(
    locale: locale,
    messages: {'greeting': greeting},
    tokenIndex: {token: 'greeting'},
  );
}

/// One app launch over [store], as two runs of an app share its container:
/// `init` as the scope runs it after the first frame, then a `tr` in [shown].
/// In the shape `setup` writes (only `en` declared) that `tr` happens once the
/// manifest has taught the scope the locale, so after init's refresh.
Future<String> _launch(_Origin origin, BundleStore store,
    {List<String> declared = const ['en'],
    String shown = 'es',
    http.Client? client}) async {
  final controller = Easyi18nController(
    supportedLocales: declared,
    bakedLoader: (_) async => null,
    delivery: DeliveryService(
      client: CdnClient(client ?? origin.client()),
      store: store,
      manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
    ),
  );
  await controller.init();
  controller.resolve(source: 'Hello', locale: shown);
  await pumpEventQueue();
  final out = controller.resolve(source: 'Hello', locale: shown);
  controller.dispose();
  return out;
}

final _en = _bundle('en', 'Hello');

/// Launch 1 with v2 published, then v3 changes `es` while the app is closed.
Future<_Origin> _publishV3AfterOneLaunch(BundleStore store,
    {List<String> declared = const ['en']}) async {
  final origin = _Origin({'en': _en, 'es': _bundle('es', 'Hola (v2)')}, '"v2"');
  expect(await _launch(origin, store, declared: declared), 'Hola (v2)');
  origin
    ..bundles = {'en': _en, 'es': _bundle('es', 'Hola (v3)')}
    ..etag = '"v3"'
    ..log.clear();
  return origin;
}

void main() {
  group('after a publish the app was closed for', () {
    test('an undeclared locale shows the new publish on the next launch',
        () async {
      final store = InMemoryBundleStore();
      final origin = await _publishV3AfterOneLaunch(store);

      expect(await _launch(origin, store), 'Hola (v3)');
      expect(origin.log, contains('bundle es'));
    });

    test('a declared locale shows the new publish too', () async {
      final store = InMemoryBundleStore();
      final origin =
          await _publishV3AfterOneLaunch(store, declared: const ['en', 'es']);

      expect(await _launch(origin, store, declared: const ['en', 'es']),
          'Hola (v3)');
    });

    test('the launch after that costs one 304 per refresh and no bundle',
        () async {
      final store = InMemoryBundleStore();
      final origin = await _publishV3AfterOneLaunch(store);
      await _launch(origin, store);
      origin.log.clear();

      expect(await _launch(origin, store), 'Hola (v3)');
      expect(origin.log, ['manifest 304', 'manifest 304']);
    });

    test('without the network a declared locale serves its persisted bundle',
        () async {
      final store = InMemoryBundleStore();
      final origin =
          await _publishV3AfterOneLaunch(store, declared: const ['en', 'es']);
      final offline = MockClient((_) async => throw http.ClientException('x'));

      expect(
          await _launch(origin, store,
              declared: const ['en', 'es'], client: offline),
          'Hola (v2)');
    });
  });

  test('a store 0.2.0 left with the new etag beside the old pointer heals on '
      'the first launch', () async {
    final store = InMemoryBundleStore();
    final esOld = _bundle('es', 'Hola (v2)');
    await store.saveBundle(_en);
    await store.saveBundle(esOld);
    await store.saveState(
        'production',
        DeliveryState(manifestEtag: '"v3"', hashByLocale: {
          'en': _en.bundleHash,
          'es': esOld.bundleHash,
        }));
    final origin = _Origin({'en': _en, 'es': _bundle('es', 'Hola (v3)')}, '"v3"');

    expect(await _launch(origin, store), 'Hola (v3)');
    expect(origin.log.first, 'manifest 200');
  });

  group('DeliveryService.refresh', () {
    test('a 304 with every pointer current reads no bundle and writes no '
        'state', () async {
      final store = _CountingStore();
      final origin =
          _Origin({'en': _en, 'es': _bundle('es', 'Hola')}, '"v1"');
      final delivery = origin.delivery(store);
      await delivery.refresh(['en', 'es']);
      store
        ..bundleReads = 0
        ..stateWrites = 0;

      final result = await delivery.refresh(['en', 'es']);

      expect(origin.log.last, 'manifest 304');
      expect(result.changed, isEmpty);
      expect(result.locales, {'en', 'es'});
      expect(result.project, 'p');
      expect(store.bundleReads, 0);
      expect(store.stateWrites, 0);
    });

    test('a 304 lists the locales of the stored manifest', () async {
      final store = InMemoryBundleStore();
      final origin = _Origin(
          {'en': _en, 'es': _bundle('es', 'Hola'), 'fr': _bundle('fr', 'Salut')},
          '"v1"');
      final delivery = origin.delivery(store);
      await delivery.refresh(['en']);

      final result = await delivery.refresh(['en']);

      expect(origin.log.last, 'manifest 304');
      expect(result.locales, {'en', 'es', 'fr'});
    });

    test('a 200 fetches a bundle whose file is gone though its pointer is '
        'current', () async {
      final es = _bundle('es', 'Hola');
      final store = InMemoryBundleStore();
      await store.saveState('production',
          DeliveryState(hashByLocale: {'es': es.bundleHash}));
      final origin = _Origin({'es': es}, '"v1"');

      final result = await origin.delivery(store).refresh(['es']);

      expect(origin.log, ['manifest 200', 'bundle es']);
      expect(result.changed.keys, ['es']);
    });

    test('a stored manifest that does not parse sends no If-None-Match',
        () async {
      final store = InMemoryBundleStore();
      await store.saveState(
          'production',
          const DeliveryState(
              manifestEtag: '"v1"', manifest: {'locales': 'not a map'}));
      final origin = _Origin({'en': _en}, '"v1"');

      final result = await origin.delivery(store).refresh(['en']);

      expect(origin.log, ['manifest 200', 'bundle en']);
      expect(result.changed.keys, ['en']);
    });

    test('an etag is never stored beside a manifest it did not come with',
        () async {
      final store = InMemoryBundleStore();
      await store.saveState(
          'production', const DeliveryState(manifestEtag: '"v0"'));
      final origin = _Origin({'en': _en}, '"v1"', sendsEtag: false);

      await origin.delivery(store).refresh(['en']);

      final state = await store.loadState('production');
      expect(state.manifest, isNotNull);
      expect(state.manifestEtag, isNull);
    });

    test('a 200 without an etag to a conditional request stores no etag',
        () async {
      final store = InMemoryBundleStore();
      final origin = _Origin({'en': _en}, '"v1"');
      final delivery = origin.delivery(store);
      await delivery.refresh(['en']);
      final v2 = _Origin({'en': _bundle('en', 'Hi')}, '"v2"', sendsEtag: false);

      await v2.delivery(store).refresh(['en']);

      expect(v2.log.first, 'manifest 200 after "v1"');
      final state = await store.loadState('production');
      expect(state.manifest!['revision'], '"v2"');
      expect(state.manifestEtag, isNull);
    });

    test('a 304 to a request without a validator is a DeliveryException',
        () async {
      final delivery = DeliveryService(
        client: CdnClient(MockClient((_) async => http.Response('', 304))),
        store: InMemoryBundleStore(),
        manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
      );

      await expectLater(
          delivery.refresh(['en']), throwsA(isA<DeliveryException>()));
    });
  });
}
