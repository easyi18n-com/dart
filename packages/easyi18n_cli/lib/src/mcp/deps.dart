import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../api_client.dart';
import '../commands/pull_command.dart' show ApiClientFactory;
import '../config.dart';
import '../delivery.dart' show DeliveryClientFactory;
import '../exceptions.dart';
import '../extract/tr_extractor.dart';
import '../logger.dart';
import '../security.dart';
import '../session.dart' show readToken;

/// Everything a tool needs from the process, injected so the suite can drive
/// the server without a filesystem-rooted cwd or a real backend.
class McpDeps {
  McpDeps({
    required this.logger,
    Map<String, String>? environment,
    String? configFileName,
    this.apiClientFactory,
    this.deliveryFactory,
    this.extractor,
    // wired-ignore: test seam. Production takes the default (the process
    // cwd); the suite needs a project root without chdir'ing the test runner.
    String Function()? currentDirectory,
  }) : environment = environment ?? Platform.environment,
       configFileName = configFileName ?? Easyi18nConfig.fileName,
       _currentDirectory = currentDirectory ?? (() => Directory.current.path);

  /// Never stdout: that is the JSON-RPC wire.
  final CliLogger logger;
  final Map<String, String> environment;

  /// What `--config` named, as a file name resolved inside the project dir.
  final String configFileName;
  final ApiClientFactory? apiClientFactory;
  final DeliveryClientFactory? deliveryFactory;
  final TrExtractor? extractor;
  final String Function() _currentDirectory;

  /// `project_dir` argument, then `EASYI18N_PROJECT_DIR`, then the process cwd.
  ///
  /// The MCP server's cwd is the client's, which is not necessarily the
  /// project — a relative path here would silently grade the wrong tree, so an
  /// argument that is not absolute is refused rather than joined onto cwd.
  String resolveProjectDir(String? fromRequest) {
    final requested = fromRequest?.trim();
    if (requested != null && requested.isNotEmpty) {
      if (!p.isAbsolute(requested)) {
        throw CliException(
          'project_dir must be an absolute path; got "$requested".',
          code: 'invalid_project_dir',
        );
      }
      return p.normalize(requested);
    }
    final fromEnv = environment['EASYI18N_PROJECT_DIR']?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) return p.normalize(fromEnv);
    return p.normalize(_currentDirectory());
  }

  /// The credential never travels as a tool argument (D3): it comes from the
  /// client's own env block, so a missing one is a config fix for the human,
  /// not something to ask the model for.
  String requireToken({String scope = 'read'}) {
    final token = readToken(environment: environment);
    if (token == null || token.isEmpty) {
      throw CliException(
        'No credential. Set EASYI18N_TOKEN in this MCP server\'s env '
        '(needs the $scope scope).',
        code: 'no_credential',
      );
    }
    return token;
  }

  String configPathFor(String? fromRequest) =>
      p.isAbsolute(configFileName)
          ? configFileName
          : p.join(resolveProjectDir(fromRequest), configFileName);

  /// The project EASYI18N_TOKEN belongs to, asked of [baseUrl] only after D4
  /// (#2445). Null from a backend that cannot name it.
  Future<KeyProject?> keyProject(String baseUrl) async {
    final token = requireToken();
    refuseUntrustedTarget(baseUrl, environment: environment);
    final client = (apiClientFactory ?? TranslationsApiClient.new)(
        baseUrl: baseUrl, token: token);
    try {
      return await client.fetchKeyProject();
    } finally {
      client.close();
    }
  }
}

/// One registered tool: its declaration and the body that answers a call.
class McpTool {
  const McpTool(this.tool, this.call);

  final Tool tool;
  final FutureOr<CallToolResult> Function(CallToolRequest, McpDeps) call;

  String get name => tool.name;
}
