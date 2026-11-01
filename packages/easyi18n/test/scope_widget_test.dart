import 'dart:convert';

import 'package:easyi18n/easyi18n.dart';
import 'package:easyi18n/src/contract/i18n/text_hash.dart';
import 'package:easyi18n/src/contract/models/bundle.dart';
import 'package:easyi18n/src/contract/models/manifest.dart';
import 'package:easyi18n/src/contract/models/translation_value.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A controller whose delivery origin serves one `es` bundle translating
/// `Hello → Hola`, via an in-memory store + MockClient.
Easyi18nController buildController({
  List<String> declared = const ['en', 'es'],
}) {
  final token = messageTokenForValue(const TranslationText('Hello'));
  final bundle = Bundle.compute(
    locale: 'es',
    messages: {'greeting': 'Hola'},
    tokenIndex: {token: 'greeting'},
  );
  final manifest = Manifest(
    project: 'p',
    revision: 'r',
    locales: {
      'es': ManifestLocale(
        version: 'r',
        bundleHash: bundle.bundleHash,
        url: 'https://cdn/es.json',
      ),
    },
  );
  final client = MockClient((req) async {
    if (req.url.path.endsWith('manifest')) {
      return http.Response(jsonEncode(manifest.toJson()), 200,
          headers: {'etag': '"v1"'});
    }
    return http.Response(jsonEncode(bundle.toJson()), 200);
  });
  return Easyi18nController(
    supportedLocales: declared,
    bakedLoader: (_) async => null,
    delivery: DeliveryService(
      client: CdnClient(client),
      store: InMemoryBundleStore(),
      manifestUrl: Uri.parse('https://x/v1/projects/p/manifest'),
    ),
  );
}

/// Counts `close()` so a test can tell an injected client (the scope must NOT
/// close it) from one the scope built for itself (#1545). Every request answers
/// 404, which `refresh()` swallows as a `DeliveryException`.
class _CloseSpyClient extends http.BaseClient {
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream<List<int>>.empty(), 404);

  @override
  void close() => closes++;
}

/// A bare `Localizations` (not `MaterialApp`) is enough for `context.tr`, which
/// only reads the ambient locale - and it sidesteps MaterialApp's delegate-
/// coverage warning for locales the default Material delegates don't ship.
Widget appWith(Easyi18nController controller, Locale locale) => Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: Localizations(
        locale: locale,
        delegates: const [DefaultWidgetsLocalizations.delegate],
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => Text(context.tr('Hello')),
          ),
        ),
      ),
    );

/// The shape `setup` leaves on `flutter create` (#2472): the widget that builds
/// MaterialApp passes `context.tr(...)` to the home page from a context ABOVE
/// the app's Localizations. An inner override must not stand in for the app's.
Widget appAbove(
  Easyi18nController controller, {
  Locale? locale,
  List<Locale>? supportedLocales,
}) =>
    Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: Builder(
        builder: (above) => MaterialApp(
          locale: locale,
          supportedLocales: supportedLocales ?? Easyi18nScope.localesOf(above),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            appBar: AppBar(
              title: Text(above.tr('Hello'), key: const Key('above')),
              actions: [Text('Hello'.tr(), key: const Key('sugar'))],
            ),
            body: Builder(
              builder: (below) => Column(children: [
                Text(below.tr('Hello'), key: const Key('below')),
                Localizations.override(
                  context: below,
                  locale: const Locale('fr'),
                  child: Builder(
                    builder: (inner) =>
                        Text(inner.tr('Hello'), key: const Key('inner')),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );

String textOf(WidgetTester tester, String key) =>
    (tester.widget(find.byKey(Key(key))) as Text).data!;

/// The language switch of #2491: the title is computed above the widget that
/// holds the locale and builds MaterialApp, so the switch rebuilds MaterialApp
/// and never the widget that called tr. Pumps the switch twice and checks the
/// title followed it without leaving a frame scheduled. With [titleLater], the
/// scope first runs frames with no tr above it, as behind a splash.
Future<void> expectSwitchBelowReaches(
  WidgetTester tester, {
  required Locale from,
  required Locale to,
  required bool trBelow,
  bool titleLater = false,
}) async {
  String inLocale(Locale l) => l.languageCode == 'es' ? 'Hola' : 'Hello';
  final controller = buildController();
  addTearDown(controller.dispose);
  await controller.refresh();
  if (titleLater) {
    await tester.pumpWidget(Easyi18nScope(
        projectId: 'p', controller: controller, child: const SizedBox()));
    await tester.pump();
  }
  var locale = from;
  late StateSetter setLocale;
  await tester.pumpWidget(Easyi18nScope(
    projectId: 'p',
    controller: controller,
    child: Builder(builder: (above) {
      final title = above.tr('Hello');
      return StatefulBuilder(builder: (_, setState) {
        setLocale = setState;
        return MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('es')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            appBar: AppBar(title: Text(title, key: const Key('above'))),
            body: trBelow
                ? Builder(
                    builder: (below) =>
                        Text(below.tr('Hello'), key: const Key('below')))
                : const Text('static'),
          ),
        );
      });
    }),
  ));
  await tester.pump();
  expect(textOf(tester, 'above'), inLocale(from));

  setLocale(() => locale = to);
  await tester.pump();
  await tester.pump();
  if (trBelow) expect(textOf(tester, 'below'), inLocale(to));
  expect(textOf(tester, 'above'), inLocale(to),
      reason: 'the app switched to ${to.languageCode} below the widget that '
          'called tr, and nothing rebuilt that widget');
  expect(tester.binding.hasScheduledFrame, isFalse,
      reason: 'the switch settled; reading it must not schedule more frames');
}

void main() {
  testWidgets('raw source first, then hot-swap rebuilds in place',
      (tester) async {
    final controller = buildController();
    await tester.pumpWidget(appWith(controller, const Locale('es')));

    // Before any bundle lands, the raw (base-language) source shows.
    expect(find.text('Hello'), findsOneWidget);

    await controller.init();
    await tester.pump();

    // The hot bundle swapped in and the widget rebuilt via the notifier.
    expect(find.text('Hola'), findsOneWidget);
    expect(find.text('Hello'), findsNothing);

    controller.dispose();
  });

  testWidgets('locale with no translation falls back to the raw source',
      (tester) async {
    final controller = buildController();
    await tester.pumpWidget(appWith(controller, const Locale('en')));
    await controller.init();
    await tester.pump();

    // The manifest has no `en` bundle → raw source serves.
    expect(find.text('Hello'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('the scope closes the client it BUILT', (tester) async {
    // The built client IS reachable from a test: `runWithClient` installs a
    // zone-local factory that `http.Client()` picks up, so the scope builds
    // the spy without being told about it. An unmounted scope that keeps its
    // client keeps a socket and the 15 s idle timer `dart:io` arms with it
    // (#1545); row 14 of docs/flows/v1-flows.md sees the same defect from the
    // other end, as a pending timer at teardown.
    final spy = _CloseSpyClient();
    await http.runWithClient(() async {
      await tester.pumpWidget(Easyi18nScope(
        projectId: 'p',
        baseUrl: Uri.parse('http://127.0.0.1:1'),
        store: InMemoryBundleStore(),
        child: const SizedBox(),
      ));
      await tester.pumpWidget(const SizedBox());
    }, () => spy);

    expect(spy.closes, 1,
        reason: 'the scope left the client it built open: every mount holds a '
            'connection pool, and its idle timer outlives the widget');
  });

  testWidgets('an INJECTED http client outlives the scope that used it',
      (tester) async {
    // The other half, and the expensive one to get wrong: closing a client
    // the caller passed in would take down a pool that caller still uses.
    final spy = _CloseSpyClient();
    await tester.pumpWidget(Easyi18nScope(
      projectId: 'p',
      baseUrl: Uri.parse('http://127.0.0.1:1'),
      httpClient: spy,
      store: InMemoryBundleStore(),
      child: const SizedBox(),
    ));
    await tester.pumpWidget(const SizedBox());

    expect(spy.closes, 0,
        reason: 'the scope closed a client it did not build: any caller '
            'sharing that client loses its connection pool');
  });

  testWidgets('a MaterialApp wired by init shows a published locale',
      (tester) async {
    // The device prefers Spanish; the scope init writes declares no target
    // locale, so `es` has to reach MaterialApp.supportedLocales from the
    // manifest, through localesOf, before Localizations can resolve it.
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final controller = buildController(declared: const ['en']);
    await tester.pumpWidget(Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: Easyi18nScope.localesOf(context),
          home: Builder(builder: (context) => Text(context.tr('Hello'))),
        ),
      ),
    ));
    expect(find.text('Hello'), findsOneWidget);

    await controller.init();
    await tester.pumpAndSettle();

    expect(find.text('Hola'), findsOneWidget,
        reason: 'the manifest advertised es, the device asks for es, and the '
            'app still resolves en: supportedLocales did not follow the scope');
    controller.dispose();
  });

  testWidgets('a tr above MaterialApp follows the locale the app runs in',
      (tester) async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(appAbove(controller,
        locale: const Locale('es'),
        supportedLocales: const [Locale('en'), Locale('es')]));
    await controller.refresh();
    await tester.pump();

    expect(textOf(tester, 'below'), 'Hola');
    expect(textOf(tester, 'above'), 'Hola',
        reason: 'the app runs in es and the bundle has Hola, but the title '
            'built above MaterialApp has no Localizations to read');
    expect(textOf(tester, 'inner'), 'Hello',
        reason: 'fr has no bundle, so the inner override serves the source');
    expect(textOf(tester, 'sugar'), 'Hello',
        reason: "'src'.tr() without a locale stays in the base locale");
  });

  testWidgets('a tr above MaterialApp stays in the base when the app does not '
      'declare the device language', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final controller = buildController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
        appAbove(controller, supportedLocales: const [Locale('en')]));
    await controller.refresh();
    await tester.pump();

    expect(textOf(tester, 'below'), 'Hello');
    expect(textOf(tester, 'above'), 'Hello',
        reason: 'the app resolved en; the device language is not the one '
            'the app runs in');
  });

  testWidgets('the first frame above MaterialApp already follows the device '
      'with the wiring init writes', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(appAbove(controller));

    expect(textOf(tester, 'above'), 'Hola',
        reason: 'before the app locale is read, the device locale resolved '
            'against localesOf is what MaterialApp picks too');
    await tester.pump();
    expect(textOf(tester, 'above'), 'Hola');
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'an unchanged app locale must not schedule another frame');
  });

  testWidgets('a MaterialApp.locale switch reaches the tr above it',
      (tester) async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.refresh();
    var locale = const Locale('es');
    late StateSetter setLocale;
    await tester.pumpWidget(Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: StatefulBuilder(builder: (above, setState) {
        setLocale = setState;
        return MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('es')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Text(above.tr('Hello'), key: const Key('above')),
        );
      }),
    ));
    await tester.pump();
    expect(textOf(tester, 'above'), 'Hola');

    setLocale(() => locale = const Locale('en'));
    await tester.pump();
    await tester.pump();
    expect(textOf(tester, 'above'), 'Hello',
        reason: 'the language switch rebuilt MaterialApp in en and the title '
            'above it kept es');
  });

  testWidgets('a switch below the widget that called tr reaches the title, '
      'es to en', (tester) async {
    await expectSwitchBelowReaches(tester,
        from: const Locale('es'), to: const Locale('en'), trBelow: true);
  });

  testWidgets('a switch below the widget that called tr reaches the title, '
      'en to es', (tester) async {
    await expectSwitchBelowReaches(tester,
        from: const Locale('en'), to: const Locale('es'), trBelow: true);
  });

  testWidgets('a switch below the widget that called tr reaches the title '
      'with no tr below MaterialApp, es to en', (tester) async {
    await expectSwitchBelowReaches(tester,
        from: const Locale('es'), to: const Locale('en'), trBelow: false);
  });

  testWidgets('a switch below the widget that called tr reaches the title '
      'with no tr below MaterialApp, en to es', (tester) async {
    await expectSwitchBelowReaches(tester,
        from: const Locale('en'), to: const Locale('es'), trBelow: false);
  });

  testWidgets('a title first built after the scope mounted follows a switch '
      'below it', (tester) async {
    await expectSwitchBelowReaches(tester,
        from: const Locale('es'),
        to: const Locale('en'),
        trBelow: false,
        titleLater: true);
  });

  testWidgets('a language switch with no tr above MaterialApp schedules no '
      'extra frame', (tester) async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.refresh();
    var locale = const Locale('es');
    late StateSetter setLocale;
    await tester.pumpWidget(Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: StatefulBuilder(builder: (_, setState) {
        setLocale = setState;
        return MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('es')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Builder(
              builder: (below) =>
                  Text(below.tr('Hello'), key: const Key('below'))),
        );
      }),
    ));
    await tester.pump();
    expect(textOf(tester, 'below'), 'Hola');

    setLocale(() => locale = const Locale('en'));
    await tester.pump();
    expect(textOf(tester, 'below'), 'Hello');
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'no tr reads the app locale from above MaterialApp, so the '
            'switch must not rebuild every tr a second time');
  });

  testWidgets('a device language change reaches the tr above MaterialApp',
      (tester) async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(appAbove(controller));
    await tester.pump();
    expect(textOf(tester, 'above'), 'Hello');

    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pump();
    await tester.pump();
    expect(textOf(tester, 'below'), 'Hola');
    expect(textOf(tester, 'above'), 'Hola',
        reason: 'WidgetsApp followed the device to es; nothing rebuilt the '
            'title above it');
  });

  testWidgets('a scope unmounted before its locale read runs does not throw',
      (tester) async {
    final controller = buildController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(appAbove(controller));
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('localesOf on a scope declaring no locale is the English floor',
      (tester) async {
    // MaterialApp asserts a non-empty supportedLocales.
    late List<Locale> seen;
    final controller = buildController(declared: const []);
    addTearDown(controller.dispose);
    await tester.pumpWidget(Easyi18nScope(
      projectId: 'p',
      controller: controller,
      child: Builder(builder: (context) {
        seen = Easyi18nScope.localesOf(context);
        return const SizedBox();
      }),
    ));
    expect(seen, const [Locale('en')]);
  });

  testWidgets('localesOf without a scope is the English floor', (tester) async {
    late List<Locale> seen;
    await tester.pumpWidget(Builder(builder: (context) {
      seen = Easyi18nScope.localesOf(context);
      return const SizedBox();
    }));
    expect(seen, const [Locale('en')]);
  });

  test('localeFromTag cases subtags the way Flutter does', () {
    expect(localeFromTag('en'), const Locale('en'));
    expect(localeFromTag('PT-br'), const Locale('pt', 'BR'));
    expect(localeFromTag('es-419'), const Locale('es', '419'));
    expect(localeFromTag('zh-hant'),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(
        localeFromTag('sr_latn_rs'),
        const Locale.fromSubtags(
            languageCode: 'sr', scriptCode: 'Latn', countryCode: 'RS'));
    // The parse stops at the first part outside the grammar, and a script
    // after the region is outside it.
    expect(localeFromTag('x-weird-br'), const Locale('x'));
    expect(localeFromTag('en-US-Latn'), const Locale('en', 'US'));
  });
}
