import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../contract/i18n/text_hash.dart' show kMessageTokenAlgoVersion;
import '../contract/models/bundle.dart';
import '../contract/models/manifest.dart';

/// Raised when a delivery fetch fails in a way the caller should treat as "no
/// update available" (network error, bad status, or a content-integrity
/// violation). Hot-update is best-effort: the offline floor still serves.
class DeliveryException implements Exception {
  DeliveryException(this.message);
  final String message;
  @override
  String toString() => 'DeliveryException: $message';
}

/// Result of a conditional manifest fetch.
sealed class ManifestFetch {
  const ManifestFetch();
}

/// The manifest is unchanged since [etag] (HTTP 304).
class ManifestNotModified extends ManifestFetch {
  const ManifestNotModified();
}

/// The manifest changed; [manifest] is the new pointer, [etag] its validator.
class ManifestUpdated extends ManifestFetch {
  const ManifestUpdated(this.manifest, this.etag);
  final Manifest manifest;
  final String? etag;
}

/// Thin HTTP client for the delivery origin (CDN or backend-origin - the SDK is
/// agnostic, it only follows the URLs the manifest hands it). Injectable
/// [http.Client] so tests run against a `MockClient`.
class CdnClient {
  CdnClient(this._client);
  final http.Client _client;

  /// Upper bound on a delivery response body. The origin is only as trusted as
  /// the manifest author; an unbounded stream would otherwise OOM the client
  /// before the bundle hash can even be checked.
  static const int _maxResponseBytes = 32 * 1024 * 1024;

  /// GET [url] streaming into a buffer, aborting a body that declares or grows
  /// past [_maxResponseBytes] instead of reading it whole.
  Future<http.Response> _getCapped(Uri url,
      {Map<String, String>? headers}) async {
    final request = http.Request('GET', url);
    if (headers != null) request.headers.addAll(headers);
    final streamed = await _client.send(request);
    final declared = streamed.contentLength;
    if (declared != null && declared > _maxResponseBytes) {
      // Rejecting before reading would otherwise leave the response stream
      // unlistened and leak the socket; cancel it explicitly.
      await streamed.stream.listen(null).cancel();
      throw DeliveryException('response too large ($declared bytes)');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > _maxResponseBytes) {
        throw DeliveryException('response exceeded $_maxResponseBytes bytes');
      }
    }
    return http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      request: request,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  /// Conditional GET of the manifest. Sends `If-None-Match: <etag>` when known
  /// so an unchanged manifest costs a cheap 304.
  ///
  /// Web caveat: freshness is driven by the **origin's** `cache-control` on the
  /// manifest response (it ships `no-cache`, so the browser revalidates on every
  /// poll and a publish reaches an open app within one interval). We do NOT set
  /// a request `cache-control` header: on web that is not a CORS-safelisted
  /// header, so it would trigger a preflight the delivery origin doesn't allow
  /// and the fetch would fail. `if-none-match` is only readable/effective off
  /// the web (the origin doesn't expose `etag` cross-origin), where it stays a
  /// cheap 304; on web the browser does its own revalidation.
  Future<ManifestFetch> fetchManifest(Uri url, {String? etag}) async {
    final http.Response res;
    try {
      res = await _getCapped(url, headers: {
        'if-none-match': ?etag,
      });
    } on DeliveryException {
      rethrow;
    } catch (e) {
      throw DeliveryException('manifest fetch failed: $e');
    }
    if (res.statusCode == 304) return const ManifestNotModified();
    if (res.statusCode != 200) {
      throw DeliveryException('manifest status ${res.statusCode}');
    }
    final Manifest manifest;
    try {
      manifest = Manifest.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      throw DeliveryException('manifest parse failed: $e');
    }
    // The SDK can only resolve source-as-key if the served tokenIndex uses an
    // algorithm version it understands.
    if (!manifest.tokenAlgoVersions.contains(kMessageTokenAlgoVersion)) {
      throw DeliveryException(
          'manifest tokenAlgoVersions ${manifest.tokenAlgoVersions} '
          'lacks $kMessageTokenAlgoVersion');
    }
    // Not the etag we sent: it validates the previous manifest, not this one.
    return ManifestUpdated(manifest, res.headers['etag']);
  }

  /// GET + verify one immutable bundle. Rejects an unknown future schema and a
  /// content address that does not match [expectedHash] (tamper / wrong object).
  Future<Bundle> fetchBundle(
    Uri url, {
    required String locale,
    required String expectedHash,
  }) async {
    final http.Response res;
    try {
      res = await _getCapped(url);
    } on DeliveryException {
      rethrow;
    } catch (e) {
      throw DeliveryException('bundle fetch failed: $e');
    }
    if (res.statusCode != 200) {
      throw DeliveryException('bundle status ${res.statusCode}');
    }
    final Bundle bundle;
    try {
      bundle = Bundle.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (e) {
      throw DeliveryException('bundle parse failed: $e');
    }
    // The bundle's own locale is folded into its content hash, so a
    // self-consistent bundle can still declare a locale other than the one the
    // manifest pointed us at. Reject the mismatch here: otherwise the store
    // keys the file by the wrong (or unsafe) locale while delivery records the
    // hash under the requested one, forcing a silent refetch on every refresh.
    if (bundle.locale != locale) {
      throw DeliveryException(
          'bundle locale "${bundle.locale}" != requested "$locale"');
    }
    if (bundle.schemaVersion > kBundleSchemaVersion) {
      throw DeliveryException(
          'bundle schemaVersion ${bundle.schemaVersion} > $kBundleSchemaVersion');
    }
    final computed = computeBundleHash(
      schemaVersion: bundle.schemaVersion,
      locale: bundle.locale,
      messages: bundle.messages,
      tokenIndex: bundle.tokenIndex,
    );
    if (computed != expectedHash || bundle.bundleHash != expectedHash) {
      throw DeliveryException('bundle hash mismatch for $locale');
    }
    return bundle;
  }
}
