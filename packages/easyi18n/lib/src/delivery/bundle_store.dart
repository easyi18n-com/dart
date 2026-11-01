import '../contract/models/bundle.dart';

/// What the SDK persists between launches so it can serve the last-good
/// translations offline before the network answers: the manifest validator
/// (ETag), the manifest it validates and the current `{locale → bundleHash}`
/// pointer for a channel.
class DeliveryState {
  const DeliveryState(
      {this.manifestEtag, this.hashByLocale = const {}, this.manifest});

  final String? manifestEtag;
  final Map<String, String> hashByLocale;

  /// The manifest JSON [manifestEtag] validates. A 304 is decided against it,
  /// so without it the SDK sends no `If-None-Match`.
  final Map<String, dynamic>? manifest;

  DeliveryState copyWith({
    String? manifestEtag,
    Map<String, String>? hashByLocale,
    Map<String, dynamic>? manifest,
  }) =>
      DeliveryState(
        manifestEtag: manifestEtag ?? this.manifestEtag,
        hashByLocale: hashByLocale ?? this.hashByLocale,
        manifest: manifest ?? this.manifest,
      );

  Map<String, dynamic> toJson() => {
        if (manifestEtag != null) 'manifestEtag': manifestEtag,
        'hashByLocale': hashByLocale,
        if (manifest != null) 'manifest': manifest,
      };

  factory DeliveryState.fromJson(Map<String, dynamic> json) => DeliveryState(
        manifestEtag: json['manifestEtag'] as String?,
        hashByLocale:
            (json['hashByLocale'] as Map?)?.cast<String, String>() ?? const {},
        manifest: (json['manifest'] as Map?)?.cast<String, dynamic>(),
      );
}

/// Persistence for delivered bundles + delivery state. Bundles are
/// content-addressed (`locale + bundleHash`), so a write is idempotent and a
/// stale hash never collides with a fresh one. Implementations must make
/// [saveBundle] atomic (no torn reads).
abstract class BundleStore {
  Future<DeliveryState> loadState(String channel);
  Future<void> saveState(String channel, DeliveryState state);

  Future<Bundle?> loadBundle(String locale, String bundleHash);
  Future<void> saveBundle(Bundle bundle);
}

/// Wraps a store that is still being created (e.g. `path_provider` is async) so
/// the rest of the SDK can be wired synchronously. Each call awaits the future
/// once; resolution is cheap thereafter.
class LazyBundleStore implements BundleStore {
  LazyBundleStore(this._future);
  final Future<BundleStore> _future;

  @override
  Future<DeliveryState> loadState(String channel) async =>
      (await _future).loadState(channel);

  @override
  Future<void> saveState(String channel, DeliveryState state) async =>
      (await _future).saveState(channel, state);

  @override
  Future<Bundle?> loadBundle(String locale, String bundleHash) async =>
      (await _future).loadBundle(locale, bundleHash);

  @override
  Future<void> saveBundle(Bundle bundle) async =>
      (await _future).saveBundle(bundle);
}

/// In-memory store: the always-available fallback (used on platforms without a
/// filesystem, and in tests). Persists nothing across launches - the baked
/// asset floor covers cold starts there.
class InMemoryBundleStore implements BundleStore {
  final Map<String, DeliveryState> _state = {};
  final Map<String, Bundle> _bundles = {};

  String _key(String locale, String hash) => '$locale/$hash';

  @override
  Future<DeliveryState> loadState(String channel) async =>
      _state[channel] ?? const DeliveryState();

  @override
  Future<void> saveState(String channel, DeliveryState state) async {
    _state[channel] = state;
  }

  @override
  Future<Bundle?> loadBundle(String locale, String bundleHash) async =>
      _bundles[_key(locale, bundleHash)];

  @override
  Future<void> saveBundle(Bundle bundle) async {
    _bundles[_key(bundle.locale, bundle.bundleHash)] = bundle;
  }
}
