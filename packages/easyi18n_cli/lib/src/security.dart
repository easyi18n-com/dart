import 'config.dart';
import 'exceptions.dart';
import 'logger.dart';

/// The production origin the token is expected to go to, derived from the
/// single source of truth in [Easyi18nConfig]. Anything else is treated as
/// untrusted for credential purposes.
final String _defaultHost = Uri.parse(Easyi18nConfig.defaultBaseUrl).host;

bool _isLoopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

/// Warns before the API token is sent to a host that is not the default
/// production origin, or over plaintext HTTP to a non-loopback host.
///
/// The token is a bearer secret and `baseUrl` comes from a checked-in
/// `easyi18n.yaml`; a value planted in a hostile repo could otherwise redirect
/// the credential to an attacker. Loopback http (the local emulator) is trusted
/// silently so the dev workflow is unaffected.
void warnOnUntrustedTarget(String baseUrl, CliLogger logger) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return;
  final loopback = _isLoopback(uri.host);
  if (uri.scheme == 'http' && !loopback) {
    logger.warn(
      'Sending your API token over plaintext HTTP to ${uri.host}. '
      'Use https unless you fully trust this network.',
    );
  }
  if (uri.host != _defaultHost && !loopback) {
    logger.warn(
      'baseUrl points at ${uri.host}, not $_defaultHost. Your API token will '
      'be sent there - make sure you trust this easyi18n.yaml.',
    );
  }
}

/// D4: under MCP the warning is not enough — nobody reads stderr, and a
/// planted `easyi18n.yaml` would exfiltrate the bearer with an "ok" result.
/// So the same two conditions [warnOnUntrustedTarget] warns about REFUSE here.
///
/// The escape hatch is the client's own config, not the repo's: an operator who
/// runs against staging sets `EASYI18N_BASE_URL` in the MCP server block, which
/// a hostile checkout cannot reach. Loopback stays trusted so the local
/// emulator works with no env at all.
void refuseUntrustedTarget(String baseUrl,
    {required Map<String, String> environment}) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) {
    throw FatalCliException(
      'baseUrl "$baseUrl" is not a URL with a host. Refusing to send your '
      'API token to it.',
      code: 'untrusted_base_url',
    );
  }
  if (_isLoopback(uri.host)) return;
  if (_sameOrigin(baseUrl, environment['EASYI18N_BASE_URL'])) return;
  if (uri.scheme == 'http') {
    throw FatalCliException(
      'Refusing to send your API token over plaintext HTTP to ${uri.host}. '
      'Use https, or set EASYI18N_BASE_URL to this exact origin in the MCP '
      'server config if you trust it.',
      code: 'untrusted_base_url',
    );
  }
  if (uri.host != _defaultHost) {
    throw FatalCliException(
      'Refusing to send your API token to ${uri.host}: easyi18n.yaml points '
      'somewhere other than $_defaultHost. Set EASYI18N_BASE_URL to this '
      'exact origin in the MCP server config if you trust it.',
      code: 'untrusted_base_url',
    );
  }
}

/// Scheme, host and port must all match; a trailing slash is not a difference.
bool _sameOrigin(String a, String? b) {
  if (b == null || b.trim().isEmpty) return false;
  final left = Uri.tryParse(a.trim());
  final right = Uri.tryParse(b.trim());
  if (left == null || right == null) return false;
  return left.scheme == right.scheme &&
      left.host == right.host &&
      left.port == right.port;
}
