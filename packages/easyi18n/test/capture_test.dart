import 'dart:convert';

import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/manifest.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:easyi18n/src/delivery/bundle_store.dart';
import 'package:easyi18n/src/delivery/capture_reporter.dart';
import 'package:easyi18n/src/delivery/cdn_client.dart';
import 'package:easyi18n/src/delivery/delivery_service.dart';
import 'package:easyi18n/src/flutter/controller.dart';
import 'package:easyi18n/src/resolver/bundle_stack.dart';
import 'package:easyi18n/src/resolver/message_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('CaptureReporter', () {
    test('dedups per session, posts one authenticated batch on flush',
        () async {
      final bodies = <String>[];
      String? authHeader;
      final reporter = CaptureReporter(
        endpoint: Uri.parse('https://x/v1/projects/p/capture'),
        token: 'eik_dev',
        client: MockClient((req) async {
          bodies.add(req.body);
          authHeader = req.headers['authorization'];
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1), // flush manually
      );

      reporter.record('Alpha', null);
      reporter.record('Alpha', null); // duplicate → ignored
      reporter.record('Open', 'verb');
      await reporter.flush();

      expect(bodies, hasLength(1));
      expect(authHeader, 'Bearer eik_dev');
      final units = ((jsonDecode(bodies.single) as Map)['units'] as List)
          .cast<Map<String, dynamic>>();
      expect(units, hasLength(2));
      expect(units.map((u) => u['source']), containsAll(['Alpha', 'Open']));
      final open = units.firstWhere((u) => u['source'] == 'Open');
      expect(open['ctx'], 'verb');
    });

    test('deferred endpoint buffers misses until set, then posts (F1 B4)',
        () async {
      Uri? postedTo;
      final reporter = CaptureReporter(
        endpoint: null, // handle/slug ref → id unknown yet
        token: 'eik_dev',
        client: MockClient((req) async {
          postedTo = req.url;
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1),
      );
      reporter.record('Early miss', null);
      await reporter.flush(); // no endpoint → buffered, nothing posted
      expect(postedTo, isNull);

      reporter.setEndpoint(Uri.parse('https://x/v1/projects/p123/capture'));
      await pumpEventQueue(); // let setEndpoint's drain flush complete
      expect(postedTo, Uri.parse('https://x/v1/projects/p123/capture'));
    });

    test('a swallowed POST error does not throw', () async {
      final reporter = CaptureReporter(
        endpoint: Uri.parse('https://x/v1/projects/p/capture'),
        token: 'eik_dev',
        client: MockClient((req) async => throw Exception('network down')),
        flushInterval: const Duration(hours: 1),
      );
      reporter.record('Z', null);
      await reporter.flush(); // must not rethrow
    });

    test('flushes automatically when the batch hits maxBatch', () async {
      var posts = 0;
      final reporter = CaptureReporter(
        endpoint: Uri.parse('https://x/v1/projects/p/capture'),
        token: 'eik_dev',
        client: MockClient((req) async {
          posts++;
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1),
        maxBatch: 2,
      );
      reporter.record('a', null);
      reporter.record('b', null); // hits maxBatch → auto-flush
      await Future<void>.delayed(Duration.zero);
      expect(posts, 1);
    });
  });

  group('resolver onMiss', () {
    test('fires on a raw fallback, not on a hit', () {
      const resolver = MessageResolver();
      final token = messageTokenForValue(const TranslationText('Hi'));
      final stack = BundleStack(
        hot: Bundle.compute(
          locale: 'es',
          messages: {'g': 'Hola'},
          tokenIndex: {token: 'g'},
        ),
      );

      var misses = 0;
      resolver.resolve(
          source: 'Hi', locale: 'es', stack: stack, onMiss: () => misses++);
      expect(misses, 0, reason: 'a hit must not report a miss');

      resolver.resolve(
          source: 'Unknown', locale: 'es', stack: stack, onMiss: () => misses++);
      expect(misses, 1, reason: 'a raw fallback must report a miss');
    });
  });

  group('controller → capture', () {
    test('a missed tr() is reported to the capture endpoint', () async {
      String? captureBody;
      final reporter = CaptureReporter(
        endpoint: buildCaptureUrl(Uri.parse('https://x'), 'p'),
        token: 'eik_dev',
        client: MockClient((req) async {
          captureBody = req.body;
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1),
      );
      final controller = Easyi18nController(
        supportedLocales: const ['es'],
        capture: reporter,
        delivery: DeliveryService(
          client: CdnClient(
              MockClient((req) async => http.Response('', 404))),
          store: InMemoryBundleStore(),
          manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
        ),
      );

      // No bundles loaded → raw fallback → miss recorded.
      controller.resolve(source: 'Fresh source', locale: 'es');
      await reporter.flush();

      expect(captureBody, isNotNull);
      final units = (jsonDecode(captureBody!) as Map)['units'] as List;
      expect(units.map((u) => (u as Map)['source']), contains('Fresh source'));

      controller.dispose();
    });

    test('a handle/slug controller learns the id from the manifest and '
        'captures to the id endpoint (F1 B4)', () async {
      Uri? postedTo;
      final reporter = CaptureReporter(
        endpoint: null, // deferred: the ref is @handle/slug, no id yet
        token: 'eik_dev',
        client: MockClient((req) async {
          postedTo = req.url;
          return http.Response('{}', 200);
        }),
        flushInterval: const Duration(hours: 1),
      );
      final manifest = Manifest(
          project: 'p123', revision: 'r', locales: const <String, ManifestLocale>{});
      final controller = Easyi18nController(
        supportedLocales: const ['es'],
        capture: reporter,
        captureEndpointBuilder: (id) =>
            buildCaptureUrl(Uri.parse('https://x'), id),
        delivery: DeliveryService(
          client: CdnClient(MockClient((req) async => http.Response(
              jsonEncode(manifest.toJson()), 200,
              headers: {'etag': '"v1"'}))),
          store: InMemoryBundleStore(),
          manifestUrl: Uri.parse('https://x/v1/@acme/dogfood/manifest'),
        ),
      );

      controller.resolve(source: 'Fresh source', locale: 'es'); // miss buffered
      await controller.refresh(); // learns p123 → setEndpoint → drains
      await pumpEventQueue(); // let the drain flush complete

      expect(postedTo, buildCaptureUrl(Uri.parse('https://x'), 'p123'));
      controller.dispose();
    });

    test('a handle/slug controller learns the id on a launch whose manifest '
        'did not change', () async {
      final manifest = Manifest(
          project: 'p123', revision: 'r', locales: const <String, ManifestLocale>{});
      final store = InMemoryBundleStore();
      final requests = <String>[];
      final origin = MockClient((req) async {
        if (req.url.path.endsWith('/capture')) {
          requests.add('capture ${req.url.path}');
          return http.Response('{}', 200);
        }
        if (req.headers['If-None-Match'] == '"v1"') {
          requests.add('manifest 304');
          return http.Response('', 304);
        }
        requests.add('manifest 200');
        return http.Response(jsonEncode(manifest.toJson()), 200,
            headers: {'etag': '"v1"'});
      });
      Future<void> launch() async {
        final controller = Easyi18nController(
          supportedLocales: const ['es'],
          capture: CaptureReporter(
              endpoint: null,
              token: 'eik_dev',
              client: origin,
              flushInterval: const Duration(hours: 1)),
          captureEndpointBuilder: (id) =>
              buildCaptureUrl(Uri.parse('https://x'), id),
          delivery: DeliveryService(
            client: CdnClient(origin),
            store: store,
            manifestUrl: Uri.parse('https://x/v1/@acme/dogfood/manifest'),
          ),
        );
        controller.resolve(source: 'Fresh source', locale: 'es');
        await controller.refresh();
        await pumpEventQueue();
        controller.dispose();
      }

      await launch();
      requests.clear();
      await launch();

      expect(requests, isNot(contains('manifest 200')));
      expect(requests, contains('capture /v1/projects/p123/capture'));
    });
  });
}
