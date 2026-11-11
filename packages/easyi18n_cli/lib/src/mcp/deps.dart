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
import '../login_store.dart';
import '../security.dart';
import '../session.dart' show findCredential;

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
    // wired-ignore: test seams. Production takes the wall clock and a real
    // delay; the suite waits for an approval without waiting 45 s.
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : environment = environment ?? Platform.environment,
       configFileName = configFileName ?? Easyi18nConfig.fileName,
       _currentDirectory = currentDirectory ?? (() => Directory.current.path),
       clock = clock ?? DateTime.now,
       sleep = sleep ?? Future<void>.delayed;

  /// Never stdout: that is the JSON-RPC wire.
  final CliLogger logger;
  final Map<String, String> environment;

  /// What `--config` named, as a file name resolved inside the project dir.
  final String configFileName;
  final ApiClientFactory? apiClientFactory;
  final DeliveryClientFactory? deliveryFactory;
  final TrExtractor? extractor;
  final String Function() _currentDirectory;
  final DateTime Function() clock;
  final Future<void> Function(Duration) sleep;

  /// `notifications/progress` on the wire; the server connects it.
  void Function(ProgressNotification) notifyProgress = (_) {};

  /// False once the client closed the channel; the server connects it.
  bool Function() connected = () => true;

  /// When this process first saw each pending operation: the wait for its
  /// approval is capped from there (#2446).
  final Map<String, DateTime> approvalSeen = {};

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

  /// What a call to [baseUrl] sends, as the CLI resolves it: EASYI18N_TOKEN,
  /// then the login `easyi18n login` stored for that origin, read on every
  /// call so a login in another terminal needs no restart (#2583). It never
  /// travels as a tool argument (D3): a missing one is for the human to fix.
  String requireToken(String baseUrl, {String scope = 'read'}) {
    final found = findCredential(environment: environment, baseUrl: baseUrl);
    if (found != null) return found.token;
    final unreadable =
        (LoginStore.locate(environment)?..read(baseUrl))?.unreadableNote ?? '';
    throw CliException(
      'No credential for $baseUrl$unreadable. Ask the human to run '
      "'easyi18n login' in a terminal, or to set EASYI18N_TOKEN in this MCP "
      "server's env (an API key with the $scope scope).",
      code: 'no_credential',
    );
  }

  /// Whether a call to [baseUrl] sends the stored login rather than a key.
  /// The login spends and publishes as its human (decision 1 of #2579); a key
  /// in EASYI18N_TOKEN keeps D17. A blank one, or the placeholder of
  /// `mcp config`, is unset, as in [findCredential].
  bool usesLogin(String baseUrl) =>
      findCredential(environment: environment, baseUrl: baseUrl)?.login != null;

  String configPathFor(String? fromRequest) =>
      p.isAbsolute(configFileName)
          ? configFileName
          : p.join(resolveProjectDir(fromRequest), configFileName);

  /// The project EASYI18N_TOKEN belongs to, asked of [baseUrl] only after D4
  /// (#2445). Null from a backend that cannot name it, and for a login, which
  /// names no project: `GET /v1/credential` is for keys (#2580).
  Future<KeyProject?> keyProject(String baseUrl) async {
    final token = requireToken(baseUrl);
    if (usesLogin(baseUrl)) return null;
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
