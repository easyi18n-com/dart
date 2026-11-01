import 'dart:convert';

import 'package:easyi18n/easyi18n.dart';
import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/manifest.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A mutable delivery origin: swap [manifest]/[bundles]/[etag] between refreshes
/// to simulate a live publish, and honour `If-None-Match` so a 304 is exercised.
class _Origin {
  _Origin({required this.manifest, required this.bundles, required this.etag});

  Manifest manifest;
  Map<String, Bundle> bundles; // by locale
  String etag;

  http.Client client() => MockClient((req) async {
        if (req.url.path.endsWith('manifest')) {
          if (req.headers['If-None-Match'] == etag) {
            return http.Response('', 304);
          }
          return http.Response(jsonEncode(manifest.toJson()), 200,
              headers: {'etag': etag});
        }
        // Bundle path ends in `<locale>.json` (see _manifest urls).
        final locale = req.url.pathSegments.last.split('.').first;
        return http.Response(jsonEncode(bundles[locale]!.toJson()), 200);
      });

  DeliveryService delivery() => DeliveryService(
        client: CdnClient(client()),
        store: InMemoryBundleStore(),
        manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
      );
}

Bundle _bundle(String locale, String greeting) {
  final token = messageTokenForValue(const TranslationText('Hello'));
  return Bundle.compute(
    locale: locale,
    messages: {'greeting': greeting},
    tokenIndex: {token: 'greeting'},
  );
}

Manifest _manifest(Map<String, Bundle> bundles) => Manifest(
      project: 'p',
      revision: 'r',
      locales: {
        for (final e in bundles.entries)
          e.key: ManifestLocale(
            version: 'r',
            bundleHash: e.value.bundleHash,
            url: 'https://cdn/${e.key}.json',
          ),
      },
    );

String _resolve(Easyi18nController c, String locale) =>
    c.resolve(source: 'Hello', locale: locale);

/// Counts `close()` calls so the two ownership branches can be told apart.
class _CloseSpyClient extends http.BaseClient {
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream<List<int>>.empty(), 404);

  @override
  void close() => closes++;
}

/// `create` with an in-memory store (the default store goes through
/// `path_provider`) and a dead origin: no test here lets it reach the network.
Future<Easyi18nController> _create({http.Client? httpClient}) =>
    Easyi18nController.create(
      projectId: 'p',
      baseUrl: Uri.parse('http://127.0.0.1:1'),
      supportedLocales: const ['en'],
      httpClient: httpClient,
      store: InMemoryBundleStore(),
    );

void main() {
  test('availableLocales grows from the manifest and unknown locales load '
      'on demand', () async {
    final es = _bundle('es', 'Hola');
    final fr = _bundle('fr', 'Bonjour');
    final origin = _Origin(
      manifest: _manifest({'es': es, 'fr': fr}),
      bundles: {'es': es, 'fr': fr},
      etag: '"v1"',
    );
    // The dev only declared `en`; the project actually publishes es + fr.
    final controller = Easyi18nController(
      supportedLocales: const ['en'],
      bakedLoader: (_) async => null,
      delivery: origin.delivery(),
    );

    await controller.init();
    // Discovered from the manifest, not the declared list.
    expect(controller.availableLocales, containsAll(<String>['en', 'es', 'fr']));

    // Switching to a discovered locale resolves to itself (not collapsed to the
    // base) and lazy-loads its bundle.
    expect(controller.matchLocale('fr'), 'fr');
    expect(_resolve(controller, 'fr'), 'Hello'); // schedules the load
    await pumpEventQueue();
    expect(_resolve(controller, 'fr'), 'Bonjour');

    controller.dispose();
  });

  test('refresh() hot-swaps a bundle republished while running', () async {
    final v1 = _bundle('es', 'Hola');
    final origin = _Origin(
      manifest: _manifest({'es': v1}),
      bundles: {'es': v1},
      etag: '"v1"',
    );
    final controller = Easyi18nController(
      supportedLocales: const ['en', 'es'],
      bakedLoader: (_) async => null,
      delivery: origin.delivery(),
    );

    await controller.init();
    expect(_resolve(controller, 'es'), 'Hola');

    // A no-op refresh (manifest unchanged → 304) must not disturb the value.
    await controller.refresh();
    expect(_resolve(controller, 'es'), 'Hola');

    // Publish v2: new content, new hash, new etag.
    final v2 = _bundle('es', 'Hola de nuevo');
    origin
      ..bundles = {'es': v2}
      ..manifest = _manifest({'es': v2})
      ..etag = '"v2"';

    var notified = 0;
    controller.addListener(() => notified++);
    await controller.refresh();

    expect(_resolve(controller, 'es'), 'Hola de nuevo');
    expect(notified, greaterThan(0)); // the swap notified dependents

    controller.dispose();
  });

  test('create() closes the http client it BUILT', () async {
    // On IO an `http.Client` wraps a connection pool whose 15 s idle timer only
    // `close()` cancels (#1545), so a controller that outlives its use holds a
    // socket. `runWithClient` hands the spy to the bare `http.Client()` inside
    // `create`, which is the only way to observe the client it builds itself.
    final spy = _CloseSpyClient();
    final controller = await http.runWithClient(_create, () => spy);

    controller.dispose();

    expect(spy.closes, 1,
        reason: 'create() left the client it built open: nothing else '
            'references it, so its idle timer outlives the controller');
  });

  test('an INJECTED http client outlives the controller create() built',
      () async {
    // The other half, and the expensive one to get wrong: closing a client the
    // caller passed in takes down a pool that caller still uses. Without this
    // test a fix that closes everything passes just the same.
    final spy = _CloseSpyClient();
    final controller = await _create(httpClient: spy);

    controller.dispose();

    expect(spy.closes, 0,
        reason: 'the controller closed a client it did not build: any caller '
            'sharing that client loses its connection pool');
  });
}
