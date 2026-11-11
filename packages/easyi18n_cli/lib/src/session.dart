import 'api_client.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'login_store.dart';
import 'mcp/client_config.dart' show keyPlaceholder;
import 'resolve.dart';
import 'security.dart';

/// What a command sends to [baseUrl] (ci-sync §9 step 1): `--token`, then
/// `EASYI18N_TOKEN`, then the login `easyi18n login` stored for that origin.
/// A blank `EASYI18N_TOKEN`, or the placeholder `mcp config` prints, is unset:
/// either would hide the login. Null when there is none.
({String token, StoredLogin? login})? findCredential({
  String? token,
  required Map<String, String> environment,
  required String? baseUrl,
}) {
  final given = token?.trim() ??
      switch (environment['EASYI18N_TOKEN']?.trim()) {
        null || '' || keyPlaceholder => null,
        final value => value,
      };
  if (given != null) return given.isEmpty ? null : (token: given, login: null);
  final login = baseUrl == null
      ? null
      : LoginStore.locate(environment)?.read(baseUrl);
  return login == null ? null : (token: login.token, login: login);
}

/// [findCredential], or a refusal that names the login and, after it, [need]:
/// the API key a CI would use instead.
String requireCredential({
  String? token,
  required Map<String, String> environment,
  required String? baseUrl,
  required String need,
}) {
  final found =
      findCredential(token: token, environment: environment, baseUrl: baseUrl);
  if (found != null) return found.token;
  if (baseUrl == null) {
    throw CliException('No credential. Set EASYI18N_TOKEN or pass --token.\n$need');
  }
  final unreadable =
      (LoginStore.locate(environment)?..read(baseUrl))?.unreadableNote ?? '';
  throw CliException(
    "No credential for $baseUrl$unreadable. Run 'easyi18n login', set "
    'EASYI18N_TOKEN or pass --token.\n$need',
  );
}

String requireToken({
  String? token,
  required Map<String, String> environment,
  String scope = 'read',
  String? baseUrl,
}) => requireCredential(token: token, environment: environment,
    baseUrl: baseUrl,
    need: 'Create an API key in your project settings (needs the $scope scope).');

/// Owns the client through resolution and the body, including either failure.
Future<T> withProject<T>({
  required Easyi18nConfig config,
  required String token,
  required CliLogger logger,
  ApiClientFactory? apiClientFactory,
  required Future<T> Function(TranslationsApiClient client, String projectId) body,
}) async {
  warnOnUntrustedTarget(config.baseUrl, logger);
  final client = (apiClientFactory ?? _defaultFactory)(
    baseUrl: config.baseUrl, token: token,
  );
  try {
    final projectId = await resolveProjectId(config, client, logger: logger);
    return await body(client, projectId);
  } finally {
    client.close();
  }
}

TranslationsApiClient _defaultFactory({
  required String baseUrl,
  required String token,
}) => TranslationsApiClient(baseUrl: baseUrl, token: token);
