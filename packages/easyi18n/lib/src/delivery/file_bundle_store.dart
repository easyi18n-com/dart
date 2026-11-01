import 'dart:convert';
import 'dart:io';

import '../contract/models/bundle.dart';
import 'bundle_store.dart';

/// Filesystem-backed [BundleStore] for IO platforms (desktop/mobile). Layout
/// under [dir]:
///
/// ```
/// {dir}/state-{channel}.json            ← etag, manifest and hash pointer
/// {dir}/bundles/{locale}/{hash}.json    ← immutable, content-addressed
/// ```
///
/// Writes are atomic (write a temp sibling, then `rename`) so a crash mid-write
/// never leaves a torn file the next launch would read as a valid bundle. The
/// [dir] is injected (e.g. from `path_provider`) which keeps this testable with
/// a plain temp directory - no platform-channel mock needed.
class FileBundleStore implements BundleStore {
  FileBundleStore(this.dir);
  final Directory dir;

  // `locale`, `channel` and `hash` become path segments; a value like
  // `../../etc` would otherwise escape [dir]. `_segment` allows only a single
  // safe path component (no `.`, `/`, or separators). The hash is a known
  // SHA-256 hex (either case, in case a producer emits uppercase).
  static final RegExp _segment = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _hash = RegExp(r'^[0-9a-fA-F]{64}$');

  // `channel` is developer configuration, not attacker data: an invalid value
  // is a programming error, so fail loudly rather than silently disabling
  // persistence (which would re-download everything on every launch).
  File _stateFile(String channel) {
    if (!_segment.hasMatch(channel)) {
      throw ArgumentError.value(channel, 'channel', 'not a safe path segment');
    }
    return File('${dir.path}/state-$channel.json');
  }

  // `locale`/`hash` come from server-controlled bundles: a bad value is defended
  // silently here (the primary check is in CdnClient.fetchBundle) so a hostile
  // manifest can never crash the app.
  File? _bundleFile(String locale, String hash) =>
      _segment.hasMatch(locale) && _hash.hasMatch(hash)
          ? File('${dir.path}/bundles/$locale/$hash.json')
          : null;

  Future<void> _atomicWrite(File file, String contents) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<DeliveryState> loadState(String channel) async {
    final file = _stateFile(channel);
    if (!await file.exists()) return const DeliveryState();
    try {
      return DeliveryState.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return const DeliveryState();
    }
  }

  @override
  Future<void> saveState(String channel, DeliveryState state) =>
      _atomicWrite(_stateFile(channel), jsonEncode(state.toJson()));

  @override
  Future<Bundle?> loadBundle(String locale, String bundleHash) async {
    final file = _bundleFile(locale, bundleHash);
    if (file == null || !await file.exists()) return null;
    try {
      return Bundle.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveBundle(Bundle bundle) async {
    final file = _bundleFile(bundle.locale, bundle.bundleHash);
    if (file == null) return;
    await _atomicWrite(file, jsonEncode(bundle.toJson()));
  }
}
