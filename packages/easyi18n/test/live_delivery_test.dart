// The SDK against a LIVE stack — rows 15 and 24 of `docs/flows/v1-flows.md`.
//
// It is the first flow producer outside `tool/flows/api-flows.sh`: that script
// sets a project up through the API, publishes it, and then runs THIS file with
// `flutter test --dart-define=…`. Without those defines the group skips, so
// `flutter test` in the `easyi18n (SDK)` CI job (no stack, no project) is
// unaffected — and the flow, not CI, is what asserts the file actually ran (it
// reads `--reporter json` and refuses a run with zero tests).
//
// Driven through `Easyi18nController`, the entry point `Easyi18nScope` builds
// for a customer: `create` → `init` → `resolve`. Not through the widget layer,
// which would fight `flutter_test`'s fake clock for a real network round trip
// and measure the pump, not the delivery.
library;

import 'dart:io';

import 'package:easyi18n/easyi18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

const String kBaseUrl = String.fromEnvironment('EASYI18N_FLOW_BASE_URL');
const String kProjectId = String.fromEnvironment('EASYI18N_FLOW_PROJECT_ID');
const String kSource = String.fromEnvironment('EASYI18N_FLOW_SOURCE');
const String kExpectedEs = String.fromEnvironment('EASYI18N_FLOW_ES');

/// `HttpOverrides` is abstract; its default `createHttpClient` returns the real
/// client, so an empty subclass IS the escape hatch out of the test harness's
/// 400-for-everything override.
class _RealHttp extends HttpOverrides {}

Future<Easyi18nController> _controller(List<String> locales) async {
  final http = IOClient(HttpClient());
  addTearDown(http.close);
  final controller = await Easyi18nController.create(
    projectId: kProjectId,
    baseUrl: Uri.parse(kBaseUrl),
    supportedLocales: locales,
    httpClient: http,
    // Explicit: the default store goes through path_provider, a plugin with
    // no implementation under `flutter test`.
    store: InMemoryBundleStore(),
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  group('live delivery', () {
    // Two tests, two witnesses. The first one exists because the obvious
    // witness is not one: `Easyi18nController` seeds `_available` from
    // `supportedLocales` in its constructor, so `availableLocales` contains
    // 'es' with no network at all. Declaring ONLY 'en' makes 'es' reachable
    // exclusively through the manifest the SDK fetched.
    test('the manifest reaches the SDK', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final controller = await _controller(const ['en']);
        await controller.init();
        expect(controller.availableLocales, contains('es'),
            reason: 'the manifest never reached the SDK: es is published and '
                'was not declared, so only a fetched manifest can offer it');
      }, _RealHttp());
    });

    test('a published project delivers its first translated string', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final controller = await _controller(const ['en', 'es']);
        await controller.init();
        // `init` swallows a DeliveryException on purpose ("the floor still
        // serves"), so a stack that never answered leaves `resolve` returning
        // the raw source — which is also what an untranslated cell returns.
        // The test above is what tells those two apart.
        expect(controller.resolve(source: kSource, locale: 'es'), kExpectedEs,
            reason: 'the es cell did not resolve to its published translation');
        expect(controller.resolve(source: kSource, locale: 'en'), kSource,
            reason: 'the base locale must resolve to the source phrase');
      }, _RealHttp());
    });
  }, skip: kBaseUrl.isEmpty ? 'live stack only: run it through tool/flows/api-flows.sh --only 15' : null);
}
