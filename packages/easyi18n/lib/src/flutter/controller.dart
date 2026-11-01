import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../contract/models/bundle.dart';
import '../delivery/bundle_store.dart';
import '../delivery/capture_reporter.dart';
import '../delivery/cdn_client.dart';
import '../delivery/default_store.dart';
import '../delivery/delivery_service.dart';
import '../resolver/bundle_stack.dart';
import '../resolver/message_resolver.dart';

/// Loads the offline-floor bundle for a locale (e.g. a shipped asset). Returns
/// null when none is baked for that locale.
typedef BakedLoader = Future<Bundle?> Function(String locale);

/// The runtime brain: owns the per-locale [BundleStack]s and resolves `tr()`.
/// It is a [ChangeNotifier] so the Flutter layer rebuilds on a hot-swap.
///
/// Never does async work in a synchronous resolve: a locale that isn't loaded
/// yet resolves against the raw source (base language) and schedules a load that
/// notifies when ready. Load order per locale: baked floor → persisted last-good
/// → network hot-update; each phase that changes anything notifies.
class Easyi18nController extends ChangeNotifier {
  Easyi18nController({
    required this.supportedLocales,
    required DeliveryService delivery,
    BakedLoader? bakedLoader,
    CaptureReporter? capture,
    Uri Function(String projectId)? captureEndpointBuilder,
    MessageResolver resolver = const MessageResolver(),
  })  : _delivery = delivery,
        _bakedLoader = bakedLoader,
        _capture = capture,
        _captureEndpointBuilder = captureEndpointBuilder,
        _resolver = resolver {
    // The declared locales seed the offerable set; the manifest grows it (§Fase
    // 1: languages from the manifest).
    _available.addAll(supportedLocales);
  }

  /// Wire a production controller against a delivery origin (CDN or backend).
  /// [baseUrl] is the API origin; the manifest is fetched from
  /// `…/v1/projects/{projectId}/manifest?channel=…` and bundle URLs come from
  /// the manifest itself.
  static Future<Easyi18nController> create({
    required String projectId,
    required Uri baseUrl,
    required List<String> supportedLocales,
    String channel = 'production',
    BakedLoader? bakedLoader,
    http.Client? httpClient,
    BundleStore? store,
  }) async {
    final resolvedStore = store ?? await createBundleStore();
    final client = httpClient ?? http.Client();
    final delivery = DeliveryService(
      client: CdnClient(client),
      store: resolvedStore,
      manifestUrl: buildManifestUrl(baseUrl, projectId, channel),
      channel: channel,
    );
    final controller = Easyi18nController(
      supportedLocales: supportedLocales,
      delivery: delivery,
      bakedLoader: bakedLoader,
    );
    if (httpClient == null) controller._ownedClient = client;
    return controller;
  }

  final List<String> supportedLocales;
  final DeliveryService _delivery;
  final BakedLoader? _bakedLoader;
  final CaptureReporter? _capture;

  /// The client [create] BUILT, or null when the caller injected one (or built
  /// the controller directly). Closing an injected client would take down a
  /// connection pool the caller still uses, so only the owned one is closed.
  http.Client? _ownedClient;

  /// Builds the id-only capture endpoint once the manifest reveals the project
  /// id (F1 B4 — the delivery ref may be a `@handle/slug` pair with no id). Null
  /// when the scope built the reporter with an eager endpoint (id ref).
  final Uri Function(String projectId)? _captureEndpointBuilder;
  final MessageResolver _resolver;

  /// Feed the manifest's project id to the deferred capture reporter (no-op once
  /// its endpoint is set, or when there's nothing to defer).
  void _learnProject(String? projectId) {
    final build = _captureEndpointBuilder;
    if (projectId != null && build != null) {
      _capture?.setEndpoint(build(projectId));
    }
  }

  final Map<String, BundleStack> _stacks = {};
  final Set<String> _loading = {};
  bool _disposed = false;

  /// Locales the app can switch to: the declared [supportedLocales] plus any the
  /// manifest advertises. A [LocaleCubit] reads this (via the scope's notifier)
  /// to build a language menu from what the project actually publishes, instead
  /// of a hardcoded list. Insertion order = declared first, then discovered.
  final Set<String> _available = {};

  /// The locales the app may present, declared + manifest-discovered. Updates
  /// (and notifies) as a refresh learns new published languages.
  List<String> get availableLocales => List.unmodifiable(_available);

  /// Resolve `tr(source)` for [locale]. Pure + synchronous; schedules a load if
  /// the locale's bundles aren't in memory yet (raw source serves meanwhile).
  String resolve({
    required String source,
    String? ctx,
    Map<String, Object> args = const {},
    required String locale,
  }) {
    final code = matchLocale(locale);
    final capture = _capture;
    final onMiss =
        capture == null ? null : () => capture.record(source, ctx);
    final stack = _stacks[code];
    if (stack == null) {
      _ensureLocale(code);
      return _resolver.resolve(
          source: source, ctx: ctx, args: args, locale: code,
          stack: const BundleStack(), onMiss: onMiss);
    }
    return _resolver.resolve(
        source: source, ctx: ctx, args: args, locale: code, stack: stack,
        onMiss: onMiss);
  }

  /// Best offerable bundle code for a requested locale tag: exact match, else a
  /// language-only match, else the base (first declared) locale. Matches against
  /// the live [_available] set so a manifest-discovered locale resolves to
  /// itself instead of collapsing to the base.
  String matchLocale(String requested) {
    if (_available.contains(requested)) return requested;
    final lang = _lang(requested);
    for (final l in _available) {
      if (_lang(l) == lang) return l;
    }
    return supportedLocales.isNotEmpty ? supportedLocales.first : requested;
  }

  String _lang(String code) => code.split(RegExp('[-_]')).first.toLowerCase();

  /// Full startup: baked floor → persisted → network, for all supported
  /// locales. Safe to await; each phase notifies as bundles land.
  Future<void> init() async {
    await _loadBaked(supportedLocales);
    await _loadPersisted(supportedLocales);
    await refresh();
  }

  /// Re-check the manifest and hot-swap any changed bundles. Public so a live
  /// trigger (on-resume / poll interval, wired by [Easyi18nScope]) can pull a
  /// freshly-published version into a running app with no rebuild. Refreshes
  /// every locale currently loaded (not just the declared ones), so whichever
  /// language the user is viewing gets the update. Idempotent + serialized by
  /// the delivery lock, so concurrent triggers are safe.
  Future<void> refresh() async {
    final locales = <String>{...supportedLocales, ..._stacks.keys};
    try {
      final result = await _delivery.refresh(locales);
      _learnProject(result.project);
      if (result.changed.isNotEmpty) _applyHot(result.changed);
      _mergeAvailable(result.locales);
    } on DeliveryException {
      // Best-effort: the floor still serves.
    }
  }

  /// Fold manifest-discovered locales into [_available]; notify if it grew so a
  /// language menu bound to the notifier rebuilds.
  void _mergeAvailable(Set<String> locales) {
    final before = _available.length;
    _available.addAll(locales);
    if (_available.length != before) _notify();
  }

  Future<void> _loadBaked(Iterable<String> locales) async {
    final loader = _bakedLoader;
    if (loader == null) return;
    var any = false;
    for (final locale in locales) {
      final baked = await loader(locale);
      if (baked == null) continue;
      _stacks[locale] = (_stacks[locale] ?? const BundleStack())
          .copyWith(baked: baked);
      any = true;
    }
    if (any) _notify();
  }

  Future<void> _loadPersisted(Iterable<String> locales) async {
    final persisted = await _delivery.loadPersisted(locales);
    if (persisted.isEmpty) return;
    for (final e in persisted.entries) {
      _stacks[e.key] =
          (_stacks[e.key] ?? const BundleStack()).copyWith(persisted: e.value);
    }
    _notify();
  }

  void _applyHot(Map<String, Bundle> changed) {
    for (final e in changed.entries) {
      _stacks[e.key] =
          (_stacks[e.key] ?? const BundleStack()).copyWith(hot: e.value);
    }
    _notify();
  }

  /// Load a single locale requested at runtime that wasn't pre-loaded.
  Future<void> _ensureLocale(String code) async {
    if (_loading.contains(code) || _stacks.containsKey(code)) return;
    _loading.add(code);
    try {
      await _loadBaked([code]);
      await _loadPersisted([code]);
      try {
        final result = await _delivery.refresh([code]);
        _learnProject(result.project);
        if (result.changed.isNotEmpty) _applyHot(result.changed);
        _mergeAvailable(result.locales);
      } on DeliveryException {
        // floor serves
      }
      // Mark as attempted even if empty, so we don't reschedule every frame.
      _stacks[code] ??= const BundleStack();
    } finally {
      _loading.remove(code);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _capture?.dispose();
    // On IO an `http.Client` wraps a `dart:io` connection pool and each
    // returned socket arms a 15 s idle Timer that only `close()` cancels
    // (#1545).
    _ownedClient?.close();
    super.dispose();
  }
}
