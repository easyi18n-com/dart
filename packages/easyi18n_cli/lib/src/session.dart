import 'api_client.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'resolve.dart';
import 'security.dart';

String? readToken({String? token, required Map<String, String> environment}) =>
    token?.trim() ?? environment['EASYI18N_TOKEN']?.trim();

String requireToken({
  String? token,
  required Map<String, String> environment,
  String scope = 'read',
}) {
  final value = readToken(token: token, environment: environment);
  if (value == null || value.isEmpty) {
    throw CliException(
      'No credential. Set EASYI18N_TOKEN or pass --token.\n'
      'Create an API key in your project settings (needs the $scope scope).',
    );
  }
  return value;
}

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
