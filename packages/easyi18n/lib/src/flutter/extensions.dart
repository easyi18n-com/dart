import 'package:flutter/widgets.dart';

import '../resolver/bundle_stack.dart';
import '../resolver/message_resolver.dart';
import 'controller.dart';
import 'scope.dart';

/// Ambient controller for the context-free `'src'.tr()` sugar. Set by the
/// mounted [Easyi18nScope]. Reactivity is weaker than `context.tr` (no
/// [BuildContext] dependency → a hot-swap won't auto-rebuild the caller), so
/// prefer `context.tr` in widget `build` methods.
Easyi18nController? _ambient;

const MessageResolver _rawResolver = MessageResolver();

void setAmbientController(Easyi18nController controller) =>
    _ambient = controller;

void clearAmbientController(Easyi18nController controller) {
  if (identical(_ambient, controller)) _ambient = null;
}

extension Easyi18nContext on BuildContext {
  /// Translate [source] (source-as-key), interpolating [args]. Registers a
  /// dependency on the hot-swap notifier so the widget rebuilds when a new
  /// bundle lands. Locale comes from the nearest [Localizations] (the dev's
  /// `MaterialApp.locale` / `supportedLocales`); above it, in the widget that
  /// builds `MaterialApp`, from the locale the app below runs in.
  String tr(String source, {String? ctx, Map<String, Object> args = const {}}) {
    final controller = Easyi18nScope.of(this);
    final locale = Localizations.maybeLocaleOf(this)?.toLanguageTag() ??
        appLocaleAbove(this) ??
        'en';
    if (controller == null) {
      return _rawResolver.resolve(
        source: source,
        ctx: ctx,
        args: args,
        locale: locale,
        stack: const BundleStack(),
      );
    }
    return controller.resolve(
      source: source,
      ctx: ctx,
      args: args,
      locale: locale,
    );
  }
}

extension Easyi18nString on String {
  /// Context-free sugar for `tr` via the ambient controller. There is no
  /// [BuildContext] to read the locale from, so pass [locale] explicitly; when
  /// omitted it defaults to the project's base locale (the ambient controller's
  /// first supported locale), NOT a hardcoded `en`. Prefer `context.tr` in
  /// widgets - it follows the active UI locale and rebuilds on hot-swap.
  String tr({
    String? ctx,
    Map<String, Object> args = const {},
    String? locale,
  }) {
    final controller = _ambient;
    if (controller == null) {
      return _rawResolver.resolve(
        source: this,
        ctx: ctx,
        args: args,
        locale: locale ?? 'en',
        stack: const BundleStack(),
      );
    }
    final resolved =
        locale ??
        (controller.supportedLocales.isNotEmpty
            ? controller.supportedLocales.first
            : 'en');
    return controller.resolve(
      source: this,
      ctx: ctx,
      args: args,
      locale: resolved,
    );
  }
}
