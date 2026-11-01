import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'api_client.dart' show kRetryableStatuses;
import 'exceptions.dart';
import 'logger.dart';
import 'version.dart';

/// One output mode shared by the runner and its command presenters.
class CliOutput {
  CliOutput({StringSink? out, StringSink? err, CliLogger? logger})
    : logger = logger ?? CliLogger(out: out ?? stdout, err: err ?? stderr) {
    if (logger != null && (out != null || err != null)) {
      throw ArgumentError('Pass either logger or sinks, not both.');
    }
  }

  final CliLogger logger;
  bool get json => logger.outputQuiet;
  set json(bool value) => logger.outputQuiet = value;

  void emit(Map<String, Object?> payload) =>
      logger.out.writeln(jsonEncode(sanitizeJson(payload)));

  void emitVersion() {
    if (json) {
      emit({'version': packageVersion});
    } else {
      logger.info('easyi18n $packageVersion');
    }
  }

  /// [report] is what the run already did when it failed, emitted beside
  /// `error` in the same record. So are the files of a refusal that names
  /// them (`edited`): `error` keeps its four fields for every command.
  void emitError(
    CliException error, {
    String? code,
    Map<String, Object?> report = const {},
  }) {
    if (!json) {
      logger.error(error.message);
      return;
    }
    emit({
      ...report,
      if (error.code == 'edited_targets') 'edited': error.details['edited'],
      'error': {
        'message': error.message,
        'code': code ?? error.code ?? 'cli_error',
        'statusCode': error is ApiException ? error.statusCode : null,
        'retryable': retryableOf(error),
      },
    });
  }
}

Object? sanitizeJson(Object? value) => switch (value) {
  String() => CliLogger.sanitize(value),
  Map<String, Object?>() => {
    for (final entry in value.entries)
      CliLogger.sanitize(entry.key): sanitizeJson(entry.value),
  },
  List() => value.map(sanitizeJson).toList(),
  _ => value,
};

/// A disk failure as the error of a `--json` record: the command ran, so it
/// answers with a record rather than an empty stdout (#1835).
CliException fileSystemError(FileSystemException error) =>
    CliException(error.toString(), code: 'file_system');

bool retryableOf(CliException error) {
  if (error is ApiException) {
    return kRetryableStatuses.contains(error.statusCode);
  }
  return error is TransientCliException;
}

/// Opts a command into structured output; the presenter owns its payload.
mixin JsonPresenter on Command<int> {}
