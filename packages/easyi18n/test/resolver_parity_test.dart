import 'dart:convert';
import 'dart:io';

import 'package:easyi18n/easyi18n.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/resolver/bundle_stack.dart';
import 'package:easyi18n/src/resolver/message_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Runs the SAME golden vectors as `easyi18n_core`'s vendored resolver copy
/// (`test/i18n/resolver_vectors.json`, synced verbatim into this package by
/// `tool/sync_contract.dart`). The backend renders transactional emails
/// through core's copy; this test is the anti-drift gate keeping the app's
/// resolution — including the controller's `matchLocale` cascade — behaviorally
/// identical to it.
void main() {
  final raw =
      File('lib/src/contract/resolver_vectors.json').readAsStringSync();
  final vectors = jsonDecode(raw) as Map<String, dynamic>;

  Easyi18nController controllerWith(List<String> available) =>
      Easyi18nController(
        supportedLocales: available,
        delivery: DeliveryService(
          client: CdnClient(
              MockClient((_) async => http.Response('not found', 404))),
          store: InMemoryBundleStore(),
          manifestUrl: Uri.parse('https://unused/v1/projects/p/manifest'),
        ),
      );

  group('matchLocale vectors (golden)', () {
    for (final entry in vectors['localeMatches'] as List) {
      final v = entry as Map<String, dynamic>;
      test(v['name'] as String, () {
        final controller =
            controllerWith((v['available'] as List).cast<String>());
        expect(controller.matchLocale(v['requested'] as String), v['expected']);
      });
    }
  });

  group('resolution vectors (golden)', () {
    final available = (vectors['available'] as List).cast<String>();
    final bundles = (vectors['bundles'] as Map<String, dynamic>).map(
      (locale, b) => MapEntry(
        locale,
        Bundle.compute(
          locale: locale,
          messages: ((b as Map)['messages'] as Map).cast<String, String>(),
          tokenIndex: (b['tokenIndex'] as Map).cast<String, String>(),
        ),
      ),
    );
    const resolver = MessageResolver();

    for (final entry in vectors['resolutions'] as List) {
      final v = entry as Map<String, dynamic>;
      test(v['name'] as String, () {
        final code =
            controllerWith(available).matchLocale(v['requested'] as String);
        expect(code, v['expectedLocale'],
            reason: 'locale match drift for "${v['name']}"');
        expect(
          resolver.resolve(
            source: v['source'] as String,
            ctx: v['ctx'] as String?,
            args: ((v['args'] as Map?) ?? const {}).cast<String, Object>(),
            locale: code,
            stack: BundleStack(baked: bundles[code]),
          ),
          v['expected'],
        );
      });
    }
  });
}
