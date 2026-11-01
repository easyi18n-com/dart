# easyi18n

[![pub package](https://img.shields.io/pub/v/easyi18n.svg)](https://pub.dev/packages/easyi18n)

Runtime SDK for [easyi18n](https://easyi18n.com). Translate UI strings with
**source-as-key** `tr()`, ship an **offline floor**, and get **automatic
hot-updates** from the delivery manifest: no code generation, no rebuild to
change a translation's value.

```dart
context.tr('Welcome {name}', args: {'name': user.name})
```

## Install

```sh
dart pub add easyi18n
```

## Quickstart

Wrap your `MaterialApp` with `Easyi18nScope`. The only required argument is your
project id. `MaterialApp` needs delegates for the locales you publish and a
`supportedLocales` list that follows them; `Easyi18nScope.localesOf` reads that
list from the scope (declared locales plus what the delivery manifest
advertises), so a language published later reaches the app without a code
change (`easyi18n init` writes exactly this):

```dart
import 'package:easyi18n/easyi18n.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

Easyi18nScope(
  projectId: 'your-project-id',
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: Easyi18nScope.localesOf(context),
      home: const HomePage(),
    ),
  ),
);
```

The app then follows the device language. Pass `locale:` to `MaterialApp`
only if your app has its own language switch.

Then translate anywhere with the source string as the key:

```dart
Text(context.tr('Hello {name}', args: {'name': 'Leo'}))

// Plurals are inline ICU in the source:
Text(context.tr(
  '{count, plural, one{You have {count} message} other{You have {count} messages}}',
  args: {'count': n},
))
```

That includes the widget that builds `MaterialApp`, such as a title passed to
`home:`: above the app's `Localizations`, `context.tr` follows the locale the
app runs in.

The source string IS the key; there is no separate key catalog to maintain.
Add a `ctx:` to disambiguate two identical strings with different meanings
(`context.tr('Open', ctx: 'verb')`).

`'string'.tr()` is a context-free shortcut (pass `locale:` yourself); prefer
`context.tr` in widgets so a hot-swap rebuilds the widget automatically.

## How resolution works

For each `tr(source)` the SDK computes a `messageToken` over the source text and
resolves it against a layered stack, newest first:

1. **hot**: the latest bundle from a manifest swap (live),
2. **persisted**: the last-good bundle from disk,
3. **baked**: the offline floor shipped in your app,
4. **raw source**: the base-language string itself (so the UI never shows a
   blank or a key).

The token is byte-identical to the one the backend stored, so lookups hit across
SDKs and platforms.

## Offline floor (baked assets)

Ship a bundle per locale so the app is fully translated on first launch, before
any network call. Place them at `assets/easyi18n/{locale}.json` (override the
path with `bakedAssetPathBuilder`) and list the folder in your `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/easyi18n/
```

You can export these bundles from the easyi18n dashboard or CLI.

## Hot-update

With just the scope wrapper, `Easyi18nScope` loads the floor + persisted bundles,
then conditionally checks the manifest (`If-None-Match` → 304) and downloads only
the immutable bundles whose content address changed, swapping them in atomically
and rebuilding dependents. The check runs at startup by default.

> Hot-update refreshes the **value** of `tr()` slots already compiled into the
> app. Text in a brand-new place still requires a build.

## Auto-capture (debug)

Pass a `capture`-scope dev token and, in **debug builds only**, any `tr()` source
the project doesn't know yet is registered as a draft (`captured`) key, so it
shows up in your dashboard to review and translate, with no CLI:

```dart
Easyi18nScope(
  projectId: '...',
  captureToken: const String.fromEnvironment('EASYI18N_CAPTURE_TOKEN'),
  ...
)
```

```sh
flutter run --dart-define=EASYI18N_CAPTURE_TOKEN=eik_your_dev_token
```

The token must **never ship in a release build**: the reporter is never
constructed in release, and is off entirely without a token. It is sent batched,
best-effort, and only once per unique source per session. Captured keys are
untranslated and never charge credits; translate them from the dashboard.

## Local development

Point the SDK at your local backend delivery origin:

```dart
Easyi18nScope(
  projectId: '...',
  baseUrl: const bool.fromEnvironment('USE_EMULATOR')
      ? Uri.parse('http://localhost:8080')
      : null, // defaults to the production origin
  ...
)
```

See `example/` for a runnable app.

## Contract parity

The token/hash algorithms are **vendored** from `easyi18n_core` (pub.dev forbids
`path:` deps) and kept in sync by `tool/sync_contract.dart`. CI runs
`dart run tool/sync_contract.dart --check` and the golden-vector tests so the
vendored copy can never silently drift from the backend.
