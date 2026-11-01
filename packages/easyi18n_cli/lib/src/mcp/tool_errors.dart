import 'package:dart_mcp/server.dart';

import '../api_client.dart' show kRetryableStatuses;
import '../cli_output.dart' show sanitizeJson;
import '../exceptions.dart';
import '../logger.dart';

/// A failure the agent is expected to read and act on, so it travels as
/// `isError` with the same actionable text the CLI prints — never as a
/// JSON-RPC error, which the model never sees.
CallToolResult toolError(
  String message, {
  required String code,
  int? statusCode,
  bool retryable = false,
  Map<String, Object?> extra = const {},
}) {
  final sanitized = CliLogger.sanitize(message);
  return CallToolResult(
    content: [Content.text(text: sanitized)],
    structuredContent: {
      'error': {
        'message': sanitized,
        'code': code,
        'statusCode': statusCode,
        'retryable': retryable,
        ...sanitizeJson(extra) as Map<String, Object?>,
      },
    },
    isError: true,
  );
}

CallToolResult errorFrom(CliException error) => toolError(
  error.message,
  code: error.code ?? 'cli_error',
  statusCode: error is ApiException ? error.statusCode : null,
  retryable: error is ApiException
      ? kRetryableStatuses.contains(error.statusCode)
      : error is TransientCliException,
  extra: error.details,
);

/// An adapter tool called on a project of the other family. The reply names
/// the tool that does apply, so the agent recovers in one step instead of
/// retrying the same call.
CallToolResult wrongFamily({
  required String tool,
  required String family,
  required String stack,
  required String useInstead,
}) => toolError(
  '`$tool` does not apply to this $stack ($family) project. '
  'Use `$useInstead` instead.',
  code: 'wrong_family',
  extra: {'family': family, 'stack': stack, 'use_instead': useInstead},
);
