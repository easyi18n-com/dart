import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contract.dart';
import 'exceptions.dart';
import 'http_capped.dart';

/// Builds the public delivery client used by the runtime health checks.
typedef DeliveryClientFactory = DeliveryClient Function({required String baseUrl});

/// Thin client over the **public, unauthenticated** delivery origin
/// (`GET /v1/projects/{id}/manifest` + the content-addressed bundles it points
/// at). This is what the runtime SDK consumes; `doctor` fetches through it so
/// the probe exercises the exact surface the app will — the runtime swallows
/// delivery errors (friction F3), the doctor must not.
class DeliveryClient {
  DeliveryClient({required this.baseUrl, http.Client? httpClient})
    : _client = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// The manifest URL for [projectId] on this origin (also what
  /// [fetchManifest] actually requests, so diagnostics can print it).
  Uri manifestUri(String projectId) =>
      Uri.parse('$baseUrl/v1/projects/$projectId/manifest');

  /// The public `@handle/slug` manifest URL (F1 alias route). Serves the same
  /// manifest as [manifestUri] with canonical (id-path) bundle URLs, so a
  /// handle-ref config can probe delivery WITHOUT resolving to an id first
  /// (and without a token — delivery is unauthenticated).
  Uri manifestUriByRef(String workspace, String project) =>
      Uri.parse('$baseUrl/v1/@$workspace/$project/manifest');

  /// Fetches the delivery manifest for [projectId]. See [_fetchManifestAt].
  Future<ManifestProbe> fetchManifest(String projectId) =>
      _fetchManifestAt(manifestUri(projectId));

  /// Fetches the delivery manifest by the `@handle/slug` ref. See
  /// [_fetchManifestAt].
  Future<ManifestProbe> fetchManifestByRef(String workspace, String project) =>
      _fetchManifestAt(manifestUriByRef(workspace, project));

  /// Fetches the delivery manifest at [uri], returning the raw probe (status +
  /// headers) plus the parsed pointer on a 200. Network failures throw
  /// [CliException]; HTTP errors do NOT throw — the caller grades them.
  ///
  /// Every field is TOLERANT: a value of the wrong type drops out (a bad
  /// `locales` entry is skipped, a bad `tokenAlgoVersions` reads as empty) and
  /// a body that is not a manifest at all surfaces as a null [revision], which
  /// is what `doctor` already grades. Nothing here throws on shape — the
  /// docstring used to claim it did, and the one field that actually threw did
  /// it with a `TypeError` that escaped the caller's `on Exception` (#972).
  Future<ManifestProbe> _fetchManifestAt(Uri uri) async {
    final response = await _get(uri);
    final headers = {
      for (final e in response.headers.entries) e.key.toLowerCase(): e.value,
    };

    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } on FormatException {
      // Graded by the caller: a 200 with a non-manifest body is a broken
      // delivery path, signalled by the null revision below.
    }

    final rawLocales = body?['locales'];
    final locales = <String, ManifestLocaleRef>{};
    if (rawLocales is Map) {
      for (final entry in rawLocales.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final url = v['url'];
        final hash = v['bundleHash'];
        if (url is! String || hash is! String) continue;
        locales[entry.key as String] = ManifestLocaleRef(
          bundleHash: hash,
          // Bundle URLs are root-relative on purpose (same-origin contract);
          // resolve against the manifest URI actually fetched, like the SDK.
          url: uri.resolve(url),
        );
      }
    }

    return ManifestProbe(
      uri: uri,
      statusCode: response.statusCode,
      headers: headers,
      revision: _stringOrNull(body?['revision']),
      // Tested, never cast, like `locales` above and `revision` below: a 200
      // that is not a manifest is exactly what this probe exists to grade, and
      // the `as List?` here threw a `TypeError` — an `Error`, which `doctor`'s
      // `on Exception` cannot catch — straight out of the command (#972).
      tokenAlgoVersions: switch (body?['tokenAlgoVersions']) {
        final List l => l.whereType<String>().toList(),
        _ => const <String>[],
      },
      locales: locales,
      errorCode: _stringOrNull(body?['error']),
      errorMessage: _stringOrNull(body?['message']),
    );
  }

  /// Fetches, parses and **integrity-checks** one locale bundle: the content
  /// must hash to [expectedHash] (its own address) and carry a schema version
  /// this CLI understands — the runtime SDK rejects the bundle on either, so a
  /// stale CDN object must fail doctor too. Throws [CliException] on any
  /// fetch/parse/verify failure.
  Future<DeliveryBundle> fetchBundle(Uri url, {String? expectedHash}) async {
    final response = await _get(url);
    if (response.statusCode != 200) {
      throw CliException('bundle fetch failed: HTTP ${response.statusCode}');
    }
    final dynamic body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw CliException('bundle at $url is not JSON');
    }
    if (body is! Map<String, dynamic>) {
      throw CliException('bundle at $url has an unexpected shape');
    }
    Map<String, String> stringMap(String key) {
      final raw = body[key];
      if (raw == null) return const {};
      if (raw is! Map) {
        throw CliException("bundle at $url: '$key' is not a map");
      }
      final out = <String, String>{};
      for (final e in raw.entries) {
        final v = e.value;
        if (e.key is! String || v is! String) {
          throw CliException("bundle at $url: '$key' holds a non-string");
        }
        out[e.key as String] = v;
      }
      return out;
    }

    final schemaVersion = body['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != kBundleSchemaVersion) {
      throw CliException(
        'bundle schema version $schemaVersion not supported '
        '(this CLI speaks $kBundleSchemaVersion) - update the CLI',
      );
    }
    final bundle = DeliveryBundle(
      locale: _stringOrNull(body['locale']) ?? '',
      messages: stringMap('messages'),
      tokenIndex: stringMap('tokenIndex'),
    );
    if (expectedHash != null) {
      final actual = computeBundleHash(
        schemaVersion: schemaVersion,
        locale: bundle.locale,
        messages: bundle.messages,
        tokenIndex: bundle.tokenIndex,
      );
      if (actual != expectedHash) {
        throw CliException(
          'bundle content does not match its address (stale CDN object?)',
        );
      }
    }
    return bundle;
  }

  void close() => _client.close();

  Future<http.Response> _get(Uri uri) async {
    try {
      return await sendCapped(
        _client,
        http.Request('GET', uri)..headers['accept'] = 'application/json',
      );
    } on http.ClientException catch (e) {
      // Covers both connect failures and a connection dropped mid-body.
      throw TransientCliException('Could not reach ${uri.host}: ${e.message}');
    }
  }

  static String? _stringOrNull(Object? v) => v is String ? v : null;
}

/// One locale entry of a fetched manifest, with the bundle URL already
/// resolved absolute.
class ManifestLocaleRef {
  ManifestLocaleRef({required this.bundleHash, required this.url});

  final String bundleHash;
  final Uri url;
}

/// The outcome of a manifest fetch: the raw HTTP evidence (for the
/// reachability + CORS checks) plus the parsed pointer when it was a 200.
class ManifestProbe {
  ManifestProbe({
    required this.uri,
    required this.statusCode,
    required this.headers,
    required this.revision,
    required this.tokenAlgoVersions,
    required this.locales,
    required this.errorCode,
    required this.errorMessage,
  });

  /// The URL that was actually requested (for diagnostics).
  final Uri uri;

  final int statusCode;

  /// Response headers with lower-cased names.
  final Map<String, String> headers;

  final String? revision;
  final List<String> tokenAlgoVersions;
  final Map<String, ManifestLocaleRef> locales;

  /// Backend error envelope (`{error, message}`) on a non-200.
  final String? errorCode;
  final String? errorMessage;
}

/// One parsed locale bundle: `messages` is `{slug → ICU}` for the keys that
/// HAVE a value in this locale (the base locale always carries every live
/// key); `tokenIndex` is the locale-independent `{messageToken → slug}` map.
class DeliveryBundle {
  DeliveryBundle({
    required this.locale,
    required this.messages,
    required this.tokenIndex,
  });

  final String locale;
  final Map<String, String> messages;
  final Map<String, String> tokenIndex;
}
