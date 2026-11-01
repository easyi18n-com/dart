/// A user-facing CLI failure: printed without a stack trace and mapped to a
/// non-zero exit code. Anything else bubbles up as an unexpected error.
class CliException implements Exception {
  CliException(this.message,
      {this.exitCode = 1, this.code, this.details = const {}});

  final String message;
  final int exitCode;

  /// Structured detail for a caller that reads fields instead of a sentence.
  /// The MCP error contract carries it beside `code` (spec section 4.4), which
  /// is the only channel an agent reads: it never sees stderr.
  final Map<String, Object?> details;

  /// Machine-readable name for `--json` consumers; null reads as `cli_error`.
  /// [ApiException] fills it with the `/v1` envelope's `error` field.
  final String? code;

  @override
  String toString() => message;
}

/// A connection failure, distinct from invalid input or configuration.
class TransientCliException extends CliException {
  TransientCliException(super.message, {super.exitCode});
}

/// A [CliException] that retrying cannot fix: the configuration, or the shape
/// of what the backend serves for it, can never produce a successful run.
///
/// `pull --watch` warns and retries on a plain [CliException] — a watcher that
/// dies overnight on one backend hiccup is worse than one that retries. That
/// is the wrong answer for a permanent fault: it warns once per cycle, forever,
/// while never writing a file and never failing. Throw this instead, and the
/// watch loop lets it out.
class FatalCliException extends CliException {
  FatalCliException(super.message, {super.exitCode, super.code});
}

/// A [CliException] carrying the HTTP status and error code the backend
/// answered with, so a caller can decide (retry, warn, give up) instead of
/// pattern-matching a human sentence.
///
/// Still a [CliException]: every existing handler keeps printing the message
/// and exiting non-zero exactly as before.
class ApiException extends CliException {
  ApiException(super.message,
      {required this.statusCode, super.code, super.details});

  final int statusCode;
}
