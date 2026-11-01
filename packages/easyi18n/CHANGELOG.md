# Changelog

## 1.0.0

- `context.tr` called above the app's `Localizations`, as in the widget that
  builds `MaterialApp` (where `flutter create` leaves the home page title),
  now resolves in the locale the app runs in. It used to fall back to `en`,
  so that title stayed in English while the rest of the screen showed the
  translation. The scope reads the locale of the topmost `Localizations`
  under it after the frame; until that first read, it uses the device
  locales resolved against `Easyi18nScope.localesOf`, which is what
  `MaterialApp` picks by default. A `tr` below `MaterialApp` and
  `'src'.tr()` resolve as before. (#2472)
- That `context.tr` also follows a language switch made inside the app when
  nothing rebuilds the widget that called it, such as a title computed above
  the widget that holds the locale and builds `MaterialApp`. It used to keep
  the language the app had before the switch. Once a `tr` above
  `Localizations` has built, the scope reads the app's locale after every
  frame and rebuilds the readers above only when it changed. (#2491)
- A language the scope does not declare, such as the device's language
  under the `Easyi18nScope` that `setup` writes, now shows the latest
  publish after the app restarts. It used to keep the previous publish
  until the next one: the startup refresh saved the new manifest etag beside
  that language's old pointer, and every later check got a 304. The
  persisted state now keeps the manifest its etag validates
  (`DeliveryState.manifest`), a 304 is decided against it, and without it
  the SDK sends no `If-None-Match`, so a device 0.2.0 left in that state
  shows the latest publish on its first launch. A custom `BundleStore` that
  persists the state field by field should store `manifest` too; without it
  every launch fetches the whole manifest. On a 304, `RefreshResult.locales`
  now lists the stored manifest's locales and `RefreshResult.project` is its
  id, so a `workspace`/`slug` scope learns its capture endpoint on a launch
  whose manifest did not change. (#2490)
- An exact-number plural case (`=N`) past the range of an `int` no longer
  throws while a message is canonicalised. (#1923)

## 0.2.0

- `Easyi18nScope.localesOf(context)`: the locales the app can offer, as
  `Locale`s, for `MaterialApp.supportedLocales`. It is the scope's declared
  list plus every locale the delivery manifest advertises, and it registers
  the caller on the scope's notifier, so publishing a new language reaches
  `MaterialApp` without a rebuild of the app's code. `localeFromTag` parses a
  delivery tag (`pt-br`, `zh-hant`, `es-419`) with Flutter's subtag casing.
  This is what `easyi18n init` 0.13 wires; an app that hardcodes
  `supportedLocales` keeps working.
- The scope and `Easyi18nController.create` close the `http.Client` they
  built when disposed; an injected client is left open. Before this every
  unmounted scope kept a socket and the 15 s idle timer `dart:io` arms with
  it. (#1545, #1660, #1689)

## 0.1.1

**No behaviour change for an app already on 0.1.0.** The resolver, the ICU
canonicaliser and the bundle hashing are byte-identical, and the public API is
unchanged. This release re-syncs the vendored contract with `easyi18n_core`.

- The vendored CLDR plural table is now generated from Unicode's own cardinal
  plural rules instead of hand-listed, and its lookup honours a region before
  falling back to the language subtag (CLDR states `pt-PT` separately from
  `pt`). The SDK never reads this table itself — it is vendored for consumers
  outside this repo, and a delivered bundle carries rendered ICU rather than
  form maps — so nothing an app renders moves. (#486, #491, #496)
- Golden contract vectors extended: the served and parsed ICU plural recipes,
  the three previously unvectored recipes, adversarial cross-SDK cases, and key
  order where UTF-16 and code point ordering disagree. (#326, #455, #486)

## 0.1.0

- Initial runtime SDK: `Easyi18nScope` + `context.tr(source, args:)` /
  `'source'.tr()` source-as-key resolution.
- Offline floor from baked assets (`assets/easyi18n/{locale}.json`).
- Automatic hot-update from a delivery manifest (conditional `If-None-Match`,
  content-addressed immutable bundles, atomic swap with rebuild).
- Vendored, byte-parity contract (token + bundle hashing) gated by golden
  vectors and `tool/sync_contract.dart`.
