// The EXAMPLE APP against a LIVE stack — row 14 of `docs/flows/v1-flows.md`.
//
// Row 15 drives `Easyi18nController` directly (`create` → `init` → `resolve`)
// and deliberately stops at the controller boundary. This file starts where
// that one stops: it pumps `MyApp` — the same widget tree a customer copies —
// and reads the string the AppBar actually renders. Everything between the
// controller and the pixel is what row 14 owns and row 15 cannot see: the
// scope's post-frame `init()`, the `InheritedNotifier` rebuild when the fetched
// bundle lands, `context.tr()` picking the ambient locale, and the fetched
// bundle displacing the BAKED FLOOR in `assets/easyi18n/es.json`.
//
// The floor is why this row needs its own witness. `Easyi18nScope` ships a
// baked bundle so the app is never blank, so "es renders Spanish" is true with
// no network at all. The flow guarantees the expected value is NOT a value of
// that floor (`tool/flows/api-flows.sh` refuses to run otherwise), and the
// failure reason below names which of the three the app rendered: the source,
// the floor, or the published translation.
//
// Without the defines the group skips itself, so `flutter test` in the example
// (no stack, no project) is unaffected — and, exactly as in row 15, a skipped
// run exits 0, which is why the runner reads `--reporter json` and refuses a
// run of zero tests instead of reading it as green.
library;

import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The source phrase the example's AppBar renders, and the value the flow
/// published for it in `es`. `EASYI18N_BASE_URL` / `EASYI18N_PROJECT_ID` are
/// read by `main.dart` itself — this app is the thing under test, not a
/// harness, so it keeps its own defines.
const String kSource = String.fromEnvironment('EASYI18N_FLOW_SOURCE');
const String kExpectedEs = String.fromEnvironment('EASYI18N_FLOW_ES');

/// `HttpOverrides` is abstract and its default `createHttpClient` returns the
/// real client, so an empty subclass IS the escape hatch out of the test
/// harness's 400-for-everything override. Global, not zone-scoped: the SDK's
/// sockets are opened from a post-frame callback, outside any zone this file
/// could wrap around the body.
class _RealHttp extends HttpOverrides {}

/// The es floor baked into the app's assets, by value. Read from the asset
/// rather than passed in, so it cannot drift from what the app actually ships.
/// Call it through [_floorValues]: `rootBundle` hands back a cached Future per
/// asset and a dead one under the fake clock waits forever.
Future<Set<String>> _bakedEsValues() async {
  final raw = await rootBundle.loadString('assets/easyi18n/es.json');
  final messages =
      (jsonDecode(raw) as Map<String, dynamic>)['messages'] as Map<String, dynamic>? ??
          const {};
  return messages.values.map((v) => '$v').toSet();
}

/// [_bakedEsValues] on the REAL clock with a hard ceiling, so no read in this
/// file can reach `testWidgets`'s own 10-minute timeout. Inside `runAsync` the
/// zone is the real one, so the `timeout` timer actually fires; a
/// `Future.timeout` under the fake clock would wait for a pump that never
/// comes. The ceiling is reported as what it is — a read that did not finish —
/// rather than as a guess about why.
Future<Set<String>> _floorValues(WidgetTester tester) async {
  Object? failure;
  final values = await tester.runAsync(() async {
    try {
      return await _bakedEsValues().timeout(const Duration(seconds: 20));
    } catch (error) {
      failure = error;
      return <String>{};
    }
  });
  if (failure != null) {
    fail('could not read assets/easyi18n/es.json within 20 s: $failure. '
        'rootBundle caches one Future per asset and never clears it between '
        'tests, so a Future left in flight by an earlier test can never '
        'complete — see the rootBundle.clear() in setUp');
  }
  return values ?? const <String>{};
}

/// The string the AppBar is showing right now, or null before the first frame.
String? _appBarTitle(WidgetTester tester) {
  final title =
      find.descendant(of: find.byType(AppBar), matching: find.byType(Text));
  if (title.evaluate().isEmpty) return null;
  return tester.widget<Text>(title.first).data;
}

/// Pump until [until] holds or the deadline passes, letting REAL time (and so
/// real sockets) run between frames. `tester.pump()` cannot be called from
/// inside `runAsync`, so the two alternate: `runAsync` hands the network its
/// slice, `pump` renders what arrived.
Future<void> _pumpLive(
  WidgetTester tester,
  bool Function() until, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump();
    if (until()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? store;

  // Per test, not once: `TestWidgetsFlutterBinding` installs its own
  // 400-for-everything override globally, and re-asserting the real client
  // before each test is cheaper than depending on when it does that.
  setUp(() {
    HttpOverrides.global = _RealHttp();
    // `rootBundle` is a `CachingAssetBundle`: it memoizes the FUTURE of each
    // asset (`asset_bundle.dart`, `_stringCache.putIfAbsent`) and nothing in
    // `flutter_test` clears it between tests. The scope loads `es.json` from
    // its post-frame `init()`, and the first test ends while that load is
    // still in flight — leaving a Future that its own binding will never
    // complete. Without this line the second test inherits it: the floor never
    // lands (the SOURCE stays on screen for the whole pump loop) and the
    // test's own read of the same asset waits until `testWidgets` times the
    // file out after 10 minutes. Measured 2026-09-07 and again on 2026-09-14.
    rootBundle.clear();
  });

  setUpAll(() {
    // The scope's default store goes through `path_provider`, a plugin with no
    // implementation under `flutter test`. Answering its channel keeps the app
    // on its real store code path instead of injecting a test-only one.
    store = Directory.systemTemp.createTempSync('easyi18n-flow14');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => store!.path,
    );
  });

  tearDownAll(() {
    HttpOverrides.global = null;
    if (store != null && store!.existsSync()) {
      store!.deleteSync(recursive: true);
    }
  });

  group('the published translation reaches the screen', () {
    // The witness that the app renders at all. Without it, a red on the test
    // below is ambiguous: a widget tree that never built and a translation
    // that never arrived both leave the expected string absent.
    testWidgets('the base locale renders the source phrase', (tester) async {
      await tester.pumpWidget(const MyApp());
      await _pumpLive(tester, () => _appBarTitle(tester) == kSource);
      expect(_appBarTitle(tester), kSource,
          reason: 'the example app did not render its own base-locale source '
              'phrase: nothing below this line is about delivery');
    });

    testWidgets('es renders what was published, not the baked floor',
        (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pump();
      // The app starts in `en` under `flutter test` (`Uri.base` carries no
      // `?locale=`), so the locale switch is driven the way a person drives it.
      await tester.tap(find.textContaining('Locale:'));
      await _pumpLive(tester, () => _appBarTitle(tester) == kExpectedEs);

      final rendered = _appBarTitle(tester);
      if (rendered == kExpectedEs) return;

      // The classification has to LEAVE this process, and neither `expect`'s
      // reason nor `fail`'s message does: `flutter_test` catches a TestFailure
      // itself and package:test then emits the generic "Test failed. See
      // exception logs above." as the only `error` event. So the reason is
      // announced on its own `FLOW-REASON:` line, which `read_flutter_json`
      // (tool/flows/api-flows.sh) prefers over that generic error — measured
      // 2026-09-14, when the negative control tripped "for the wrong reason"
      // because the verdict quoted "Test failed" instead of this.
      // The floor is read only when the answer depends on it: telling the
      // SOURCE apart needs no asset, and reading one anyway would replace a
      // precise verdict with whatever the read failed on.
      final String why;
      if (rendered == kSource) {
        why = 'the app rendered the SOURCE ("$rendered"): no published '
            'translation reached the widget tree at all';
      } else if ((await _floorValues(tester)).contains(rendered)) {
        why = 'the app rendered the BAKED FLOOR ("$rendered"): the published '
            'bundle never displaced assets/easyi18n/es.json';
      } else {
        why = 'the app rendered "$rendered", which is neither the source nor '
            'a value of the baked floor: delivery landed something other than '
            'what was published';
      }
      final reason = '$why — expected "$kExpectedEs"';
      debugPrint('FLOW-REASON: $reason');
      fail(reason);
    });
  },
      skip: kExpectedEs.isEmpty
          ? 'live stack only: run it through tool/flows/api-flows.sh --only 14'
          : null);
}
