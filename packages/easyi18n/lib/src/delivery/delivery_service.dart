import '../contract/models/bundle.dart';
import '../contract/models/manifest.dart';
import 'bundle_store.dart';
import 'cdn_client.dart';

/// The manifest endpoint for a project on a delivery origin:
/// `{baseUrl}/v1/projects/{projectId}/manifest?channel={channel}`. Bundle URLs
/// are then read from the manifest itself, so they can point at the CDN or the
/// backend origin transparently.
Uri buildManifestUrl(Uri baseUrl, String projectId, String channel) {
  final base = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
  return Uri.parse('$base/v1/projects/$projectId/manifest?channel=$channel');
}

/// The manifest endpoint addressed by the human-readable pair:
/// `{baseUrl}/v1/@{handle}/{slug}/manifest?channel={channel}` (F1). Same payload
/// as [buildManifestUrl]; the bundle URLs it advertises point back at the
/// canonical `/v1/projects/{id}/...` path, so bundles stay on the cached origin.
Uri buildManifestUrlByHandle(
    Uri baseUrl, String handle, String slug, String channel) {
  final base = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
  return Uri.parse('$base/v1/@$handle/$slug/manifest?channel=$channel');
}

/// The auto-capture endpoint for a project:
/// `{baseUrl}/v1/projects/{projectId}/capture`.
Uri buildCaptureUrl(Uri baseUrl, String projectId) {
  final base = baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
  return Uri.parse('$base/v1/projects/$projectId/capture');
}

/// Orchestrates offline-first delivery: load the last-good persisted bundles at
/// startup, then conditionally refresh against the manifest and download only
/// the bundles whose content address changed. Throws nothing on a network/parse
/// failure during [refresh] except a [DeliveryException] the caller swallows -
/// hot-update is best-effort, the floor always serves.
class DeliveryService {
  DeliveryService({
    required this.client,
    required this.store,
    required this.manifestUrl,
    this.channel = 'production',
  });

  final CdnClient client;
  final BundleStore store;
  final Uri manifestUrl;
  final String channel;

  /// Last-good bundles for [locales] from the previous session's saved pointer.
  Future<Map<String, Bundle>> loadPersisted(Iterable<String> locales) async {
    final state = await store.loadState(channel);
    final out = <String, Bundle>{};
    for (final locale in locales) {
      final hash = state.hashByLocale[locale];
      if (hash == null) continue;
      final bundle = await store.loadBundle(locale, hash);
      if (bundle != null) out[locale] = bundle;
    }
    return out;
  }

  /// Serializes all delivery mutations: each [refresh] runs after the previous
  /// one completes, so a startup refresh and an ad-hoc per-locale fetch can't
  /// read-modify-write the persisted state concurrently and drop a locale's
  /// hash pointer (which would force a redundant refetch next cold start).
  Future<void> _refreshLock = Future<void>.value();

  /// Conditional manifest check → download the changed bundles for [locales],
  /// persist them + the new state, and return the bundles that changed (the
  /// caller swaps those into the hot layer) alongside the full set of locales
  /// the manifest advertises (for language discovery). `changed` empty =
  /// nothing to swap; `locales` is still populated so the caller learns which
  /// languages the project publishes even on a 304.
  Future<RefreshResult> refresh(Iterable<String> locales) {
    final list = locales.toList(growable: false);
    final result = _refreshLock.then((_) => _refresh(list));
    // Chain the lock so the next refresh waits for this one; swallow errors so
    // a failed refresh doesn't wedge the chain.
    _refreshLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<RefreshResult> _refresh(List<String> locales) async {
    final state = await store.loadState(channel);
    final stored = _storedManifest(state);
    // A 304 only confirms the manifest stored beside the etag, so the etag
    // goes out only with one (a 0.2.0 store holds the etag alone).
    final fetch = await client.fetchManifest(
      manifestUrl,
      etag: stored == null ? null : state.manifestEtag,
    );
    final (manifest, etag) = switch (fetch) {
      ManifestUpdated(:final manifest, :final etag) => (manifest, etag),
      ManifestNotModified() => (
          stored ?? (throw DeliveryException('manifest 304 to no validator')),
          state.manifestEtag,
        ),
    };
    final updated = fetch is ManifestUpdated;

    final changed = <String, Bundle>{};
    final hashes = Map<String, String>.from(state.hashByLocale);
    for (final locale in locales) {
      final entry = manifest.locales[locale];
      if (entry == null) continue;
      // On a 304 the pointer is enough (it is saved after its bundle), which
      // keeps an unchanged manifest from reading every bundle off the disk.
      if (state.hashByLocale[locale] == entry.bundleHash &&
          (!updated ||
              await store.loadBundle(locale, entry.bundleHash) != null)) {
        continue; // already have this exact bundle persisted.
      }
      // Resolve the (root-relative) bundle URL against the manifest URL we
      // actually fetched, so the bundle is pulled from the same host/CDN as the
      // manifest. Absolute URLs (legacy manifests) resolve to themselves.
      final bundle = await client.fetchBundle(
        manifestUrl.resolveUri(Uri.parse(entry.url)),
        locale: locale,
        expectedHash: entry.bundleHash,
      );
      await store.saveBundle(bundle);
      changed[locale] = bundle;
      hashes[locale] = entry.bundleHash;
    }

    // Built whole, not with copyWith: its `??` would keep an older etag beside
    // a manifest that came without one.
    if (updated || changed.isNotEmpty) {
      await store.saveState(
        channel,
        DeliveryState(
          manifestEtag: etag,
          hashByLocale: hashes,
          manifest: manifest.toJson(),
        ),
      );
    }
    // Every locale the manifest lists is offerable, even if we didn't fetch its
    // bundle this pass (only [locales] were requested for download).
    return RefreshResult(
        changed: changed,
        locales: manifest.locales.keys.toSet(),
        project: manifest.project);
  }

  /// The manifest [state] stored beside its etag, or null when there is none
  /// or this SDK can't read its shape (the next fetch then goes unconditional).
  Manifest? _storedManifest(DeliveryState state) {
    final json = state.manifest;
    if (json == null) return null;
    try {
      return Manifest.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}

/// The outcome of a [DeliveryService.refresh]: the bundles that changed (to swap
/// into the hot layer) and the full set of locales the manifest advertises (so
/// the runtime can discover languages it wasn't told about up front).
class RefreshResult {
  const RefreshResult({
    required this.changed,
    required this.locales,
    this.project,
  });

  /// Locales whose bundle content changed this refresh (empty = nothing to do).
  final Map<String, Bundle> changed;

  /// Every locale the project currently publishes, from the manifest (the
  /// stored one on a 304).
  final Set<String> locales;

  /// The project's opaque doc-id, from the manifest — the delivery ref may be a
  /// `@handle/slug` pair, so this is how the runtime learns the id (to build the
  /// id-only capture endpoint, F1 B4). On a 304 it comes from the stored
  /// manifest, so a launch that only gets 304s learns it too.
  final String? project;
}
