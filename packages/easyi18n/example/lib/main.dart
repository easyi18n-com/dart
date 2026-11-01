import 'package:easyi18n/easyi18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Your easyi18n project. Prefer the human-readable `@handle/slug` pair via
/// `--dart-define=EASYI18N_WORKSPACE=…` + `EASYI18N_PROJECT=…` (the workspace
/// handle + project slug from the dashboard URL); fall back to the opaque
/// `EASYI18N_PROJECT_ID` when the workspace isn't set.
const String kWorkspace = String.fromEnvironment('EASYI18N_WORKSPACE');
const String kProject = String.fromEnvironment('EASYI18N_PROJECT');
const String kProjectId = String.fromEnvironment(
  'EASYI18N_PROJECT_ID',
  defaultValue: 'demo',
);
const bool kUseHandleRef = kWorkspace != '' && kProject != '';

/// The delivery origin. `--dart-define=USE_EMULATOR=true` points the SDK at the
/// singleton local stack on `:8080` (`tool/backend-up.sh`);
/// `--dart-define=EASYI18N_BASE_URL=http://127.0.0.1:<port>` names an origin
/// explicitly and wins over it. The explicit form is what flow 14 of
/// `docs/flows/v1-flows.md` uses: `tool/flows/stack-ephemeral.sh` binds a FREE
/// port, so `localhost:8080` is not an address a run can assume. Neither set
/// leaves the SDK on its default (production) origin.
const bool kUseEmulator = bool.fromEnvironment('USE_EMULATOR');
const String kBaseUrlOverride = String.fromEnvironment('EASYI18N_BASE_URL');

Uri? get _deliveryBaseUrl {
  if (kBaseUrlOverride.isNotEmpty) return Uri.parse(kBaseUrlOverride);
  return kUseEmulator ? Uri.parse('http://localhost:8080') : null;
}

/// A `capture`-scope dev token enables auto-capture in debug:
/// `--dart-define=EASYI18N_CAPTURE_TOKEN=eik_…`. Never ship it in release.
const String kCaptureToken = String.fromEnvironment('EASYI18N_CAPTURE_TOKEN');

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Start locale: `?locale=es` on web (handy for headless screenshots), else en.
  Locale _locale = Locale(
    Uri.base.queryParameters['locale'] == 'es' ? 'es' : 'en',
  );

  @override
  Widget build(BuildContext context) {
    // Easyi18nScope wraps MaterialApp - identify the project by `@handle/slug`
    // or the opaque id. Baked floors live in assets/easyi18n/{locale}.json; the
    // SDK hot-updates them from the manifest with no extra code.
    return Easyi18nScope(
      workspace: kUseHandleRef ? kWorkspace : null,
      slug: kUseHandleRef ? kProject : null,
      projectId: kUseHandleRef ? null : kProjectId,
      baseUrl: _deliveryBaseUrl,
      supportedLocales: const ['en', 'es'],
      captureToken: kCaptureToken.isEmpty ? null : kCaptureToken,
      // Poll for freshly-published versions while running, so a publish hot-swaps
      // into the open app with no restart (on-resume is on by default too).
      refreshInterval: const Duration(seconds: 3),
      child: MaterialApp(
        locale: _locale,
        supportedLocales: const [Locale('en'), Locale('es')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: _HomePage(
          locale: _locale,
          onToggleLocale: () => setState(() {
            _locale = _locale.languageCode == 'en'
                ? const Locale('es')
                : const Locale('en');
          }),
        ),
      ),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({required this.locale, required this.onToggleLocale});
  final Locale locale;
  final VoidCallback onToggleLocale;

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  int _count = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Welcome to easyi18n'))),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.tr('Hello {name}', args: {'name': 'Leo'})),
            const SizedBox(height: 12),
            Text(
              context.tr(
                '{count, plural, one{You have {count} message} '
                'other{You have {count} messages}}',
                args: {'count': _count},
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => setState(() => _count++),
              child: const Text('+1'),
            ),
            TextButton(
              onPressed: widget.onToggleLocale,
              child: Text('Locale: ${widget.locale.languageCode}'),
            ),
          ],
        ),
      ),
    );
  }
}
