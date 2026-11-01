import 'package:path/path.dart' as p;

import 'api_client.dart';
import 'cli_output.dart';
import 'commands/pull_command.dart' show ApiClientFactory;
import 'config.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'session.dart';

class OutputFormatRunner {
  Future<OutputFormatResult> run({
    required Easyi18nConfig config,
    required String configPath,
    required String token,
    required CliLogger logger,
    required String format,
    ApiClientFactory? apiClientFactory,
  }) => withProject(
    config: config, token: token, logger: logger,
    apiClientFactory: apiClientFactory,
    body: (client, projectId) async => OutputFormatResult(
      await client.addOutputFormat(projectId: projectId, format: format),
      format: format,
      projectDir: p.normalize(p.absolute(p.dirname(configPath))),
      baseUrl: config.baseUrl,
    ),
  );
}

class OutputFormatResult {
  OutputFormatResult(OutputFormatOutcome outcome, {
    required this.format, required this.projectDir, required this.baseUrl,
  }) : enabled = outcome.formats, created = outcome.created;

  final String format;
  final List<String> enabled;
  final bool created;
  final String projectDir;
  final String baseUrl;

  Map<String, Object?> toJson() => sanitizeJson({
    'format': format, 'enabled': enabled, 'created': created,
    'project_dir': projectDir, 'base_url': baseUrl,
    'next': 'easyi18n status',
  }) as Map<String, Object?>;
}

enum OutputFormatState {
  alreadyEnabled, wouldAdopt, conflict;

  /// A project with no format takes the first one conditionally; one that
  /// has others never grows a second without `formats add`.
  static OutputFormatState of(List<String> enabled, String format) =>
      enabled.contains(format) ? alreadyEnabled
          : enabled.isEmpty ? wouldAdopt : conflict;
}

/// Whether `pull` can write [format] with this key, asked before any spend.
///
/// `pull` enables the format of a project that has none, and that takes the
/// `write` scope: an Agent key with `read, translate, publish` spends and
/// publishes, then stops at `pull` with the files unwritten (#2133).
enum OutputFormatReadiness {
  enabled, adoptable, missing, conflict, unknown;

  bool get blocksPull => this == missing || this == conflict;
}

class OutputFormatCheck {
  const OutputFormatCheck(this.format, this.readiness, this.message,
      {this.enabled = const [], this.remedy = const []});

  final String format;
  final OutputFormatReadiness readiness;
  final List<String> enabled;

  /// [message] and each line of [remedy] stay under the 200 characters an
  /// MCP result keeps of a string inside a list (`output_budget.dart`).
  final String message;
  final List<String> remedy;

  /// Only a code-first Mode B project never pulls: the SDK reads the CDN.
  static bool pulls(Easyi18nConfig config, {required String family}) =>
      config.mode == 'a' || family == 'file-first';

  /// Reads `/meta`, and `/credential` only for a project with no format.
  static Future<OutputFormatCheck> of(TranslationsApiClient client,
      String projectId, String format) async {
    final meta = await client.fetchMeta(projectId: projectId);
    if (meta.outputFormatsApiVersion != 1 || !meta.formatsKnown) {
      return OutputFormatCheck(format, OutputFormatReadiness.unknown,
          'the server did not report the output formats of this project - '
          'upgrade the backend');
    }
    final enable = 'human enables "$format" under Project > Settings > '
        'Output in the dashboard.';
    final add = 'Or a human runs `easyi18n formats add $format` with a key '
        'that has the write scope.';
    switch (OutputFormatState.of(meta.formats, format)) {
      case OutputFormatState.alreadyEnabled:
        return OutputFormatCheck(format, OutputFormatReadiness.enabled,
            '"$format" is enabled', enabled: meta.formats);
      case OutputFormatState.conflict:
        return OutputFormatCheck(format, OutputFormatReadiness.conflict,
            'output format "$format" is not enabled (enabled: '
            '${meta.formats.join(', ')}): pull refuses with any key',
            enabled: meta.formats,
            remedy: [
              'Set `format:` in easyi18n.yaml to an enabled format if that '
                  'matches your files.',
              'Or a $enable',
              add,
            ]);
      case OutputFormatState.wouldAdopt:
        final key = await client.fetchCredential(projectId: projectId);
        if (key.grants('write')) {
          return OutputFormatCheck(format, OutputFormatReadiness.adoptable,
              'no output format is enabled yet; pull enables "$format" with '
              'this key');
        }
        return OutputFormatCheck(format, OutputFormatReadiness.missing,
            'this project has no output format and this key cannot enable '
            'one (scopes: ${key.scopes.join(', ')}): pull would stop after '
            'the spend and the publish', remedy: ['A $enable', add]);
    }
  }

  Map<String, Object?> toJson() => sanitizeJson({
    'format': format, 'state': readiness.name, 'enabled': enabled,
    'remedy': remedy,
  }) as Map<String, Object?>;
}

class OutputFormatAdoption {
  OutputFormatAdoption(this.format);

  final String format;
  OutputFormatState? state;
  bool created = false;
  bool _attempted = false;

  Future<ProjectMeta> preflight(
    TranslationsApiClient client, String projectId, {
    ApiException? recoveryError,
  }) async {
    final meta = await client.fetchMeta(projectId: projectId);
    if (meta.outputFormatsApiVersion != 1) {
      throw recoveryError ?? FatalCliException(
          'This server does not support output formats API version 1. '
          'Update the backend before running this file workflow.');
    }
    if (!meta.formatsKnown) {
      throw FatalCliException('The server returned invalid output format '
          'metadata. No automatic adoption is authorized.');
    }
    state = OutputFormatState.of(meta.formats, format);
    if (state == OutputFormatState.conflict) {
      throw FatalCliException('Output format "$format" is not enabled '
          '(enabled: ${meta.formats.join(', ')}). Set `format:` in '
          '`easyi18n.yaml` to an enabled format if that matches your files, '
          'or run `easyi18n formats add $format` to add it explicitly.');
    }
    return meta;
  }

  Future<void> apply(TranslationsApiClient client, String projectId,
      CliLogger logger) async {
    if (state == OutputFormatState.alreadyEnabled) return;
    if (state != OutputFormatState.wouldAdopt || _attempted) {
      throw FatalCliException('Automatic output format adoption is unavailable. '
          'Run `easyi18n formats add $format` with a key that has write scope.');
    }
    _attempted = true;
    final OutputFormatOutcome outcome;
    try {
      outcome = await client.adoptOutputFormat(projectId: projectId, format: format);
    } on ApiException catch (e) {
      if (e.statusCode != 403) rethrow;
      throw ApiException('${e.message} A holder of write scope must run '
          '`easyi18n formats add $format` before retrying.',
          statusCode: e.statusCode, code: e.code, details: e.details);
    }
    created = outcome.created;
    state = OutputFormatState.alreadyEnabled;
    if (created) logger.info('Enabled output format "$format" on this project.');
  }

  String get confirmedMessage => 'Output format "$format" configuration was '
      'updated earlier in this run. Subsequent work may also have completed. '
      'No automatic rollback was performed.';

  CliException annotate(CliException error) {
    if (!created || error.message.endsWith(confirmedMessage)) return error;
    final message = '${error.message}\n$confirmedMessage';
    return switch (error) {
      // Rewrapping drops whatever the constructor is not given, and the
      // structured half of a refusal is the only one an agent reads.
      ApiException e => ApiException(message,
          statusCode: e.statusCode, code: e.code, details: e.details),
      FatalCliException e => FatalCliException(message, exitCode: e.exitCode),
      TransientCliException e => TransientCliException(message, exitCode: e.exitCode),
      _ => CliException(message,
          exitCode: error.exitCode, code: error.code, details: error.details),
    };
  }

  Map<String, Object?> toJson() => {
    'format': format, 'state': state?.name, 'created': created,
  };
}
