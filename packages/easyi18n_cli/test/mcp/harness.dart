import 'dart:async';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/mcp/deps.dart';
import 'package:easyi18n_cli/src/mcp/server.dart';
import 'package:stream_channel/stream_channel.dart';

/// An initialized client/server pair over an in-memory channel: the same wire
/// a real client speaks, without a process or a filesystem cwd.
class McpHarness {
  McpHarness._(this.server, this.connection, this._client);

  final Easyi18nMcpServer server;
  final ServerConnection connection;
  final MCPClient _client;

  static Future<McpHarness> start(McpDeps deps) async {
    final controller = StreamChannelController<String>();
    final server = Easyi18nMcpServer.fromStreamChannel(
      controller.foreign,
      deps: deps,
    );
    final client = MCPClient(Implementation(name: 'harness', version: '1.0.0'));
    final connection = client.connectServer(controller.local);
    final result = await connection.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    connection.notifyInitialized();
    return McpHarness._(server, connection, client)..initializeResult = result;
  }

  late final InitializeResult initializeResult;

  Future<List<Tool>> listTools() async => (await connection.listTools()).tools;

  Future<List<Prompt>> listPrompts() async =>
      (await connection.listPrompts()).prompts;

  Future<GetPromptResult> getPrompt(String name) =>
      connection.getPrompt(GetPromptRequest(name: name));

  Future<CallToolResult> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) => connection.callTool(CallToolRequest(name: name, arguments: arguments));

  /// [call] with a `progressToken`, and what the server reported while it ran.
  Future<({CallToolResult result, List<ProgressNotification> progress})>
      callWithProgress(String name, Map<String, Object?> arguments,
          String token) async {
    final request = CallToolRequest(
      name: name,
      arguments: arguments,
      meta: MetaWithProgressToken(progressToken: ProgressToken(token)),
    );
    final progress = <ProgressNotification>[];
    final listening = connection.onProgress(request).listen(progress.add);
    final result = await connection.callTool(request);
    await listening.cancel();
    return (result: result, progress: progress);
  }

  Future<void> shutdown() async {
    await _client.shutdown();
    await server.shutdown();
  }
}
