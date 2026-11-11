import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../exceptions.dart';
import '../version.dart';
import 'deps.dart';
import 'instructions.dart';
import 'output_budget.dart';
import 'prompts.dart';
import 'tool_errors.dart';
import 'tools/core/add_language.dart';
import 'tools/core/authorize.dart';
import 'tools/core/doctor.dart';
import 'tools/core/fill_status.dart';
import 'tools/core/init.dart';
import 'tools/core/publish.dart';
import 'tools/core/pull.dart';
import 'tools/core/rollback.dart';
import 'tools/core/status.dart';
import 'tools/dart/apply.dart';
import 'tools/dart/extract.dart';
import 'tools/dart/push.dart';
import 'tools/dart/push_preview.dart';
import 'tools/xcstrings/sync.dart';
import 'tools/xcstrings/sync_preview.dart';

/// The tool list, fixed and ordered: core first, then the adapters. The order
/// is what `test/mcp/tools.golden.json` pins, so a client sees the same list
/// on every release and a reordering is a reviewed change.
final List<McpTool> mcpTools = List.unmodifiable([
  initTool,
  doctorTool,
  statusTool,
  authorizeTool,
  fillStatusTool,
  publishTool,
  rollbackTool,
  pullTool,
  addLanguageTool,
  extractTool,
  pushPreviewTool,
  pushTool,
  applyTool,
  syncPreviewTool,
  syncTool,
]);

/// `easyi18n mcp` over an already-established channel.
///
/// Every failure a tool can produce reaches the agent as `isError` content
/// (see [toolError]): a JSON-RPC error would be invisible to the model, which
/// is the one that has to correct course.
final class Easyi18nMcpServer extends MCPServer
    with ToolsSupport, PromptsSupport {
  Easyi18nMcpServer.fromStreamChannel(
    super.channel, {
    required this.deps,
    List<McpTool>? tools,
    List<McpPrompt>? prompts,
  }) : tools = tools ?? mcpTools,
       prompts = prompts ?? mcpPrompts,
       super.fromStreamChannel(
         implementation: Implementation(
           name: 'easyi18n',
           version: packageVersion,
         ),
         instructions: mcpInstructions,
       ) {
    deps
      ..notifyProgress = notifyProgress
      ..connected = () => isActive;
  }

  final McpDeps deps;
  final List<McpTool> tools;
  final List<McpPrompt> prompts;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) {
    for (final tool in tools) {
      // The package's own validation answers before the callback runs, so its
      // rejection would skip the error contract below. Validate here instead,
      // with the same schema and the same strictness.
      registerTool(
        tool.tool,
        (call) async => _bounded(await _guarded(tool, call)),
        validateArguments: false,
      );
    }
    for (final entry in prompts) {
      addPrompt(
        entry.prompt,
        (_) => GetPromptResult(
          messages: [
            PromptMessage(
              role: Role.user,
              content: Content.text(text: entry.text),
            ),
          ],
        ),
      );
    }
    return super.initialize(request);
  }

  /// Sanitizing and the output budget live here, not in each tool: a tool
  /// added later cannot forget them, and a credential in project data must not
  /// reach the model through any of them (spec section 4.4).
  CallToolResult _bounded(CallToolResult result) {
    final content = result.structuredContent;
    if (content == null) return result;
    try {
      final bounded = boundOutput(content);
      final error = bounded['error'];
      final message = error is Map<String, Object?> ? error['message'] : null;
      return CallToolResult(
        content: result.isError == true && message is String
            ? [Content.text(text: message)]
            : result.content,
        structuredContent: bounded,
        isError: result.isError,
      );
    } on OutputBudgetExceeded {
      return toolError(
        'The tool result exceeds the 32 KiB output limit. '
        'Reduce the requested data or shorten oversized project metadata.',
        code: 'output_too_large',
      );
    }
  }

  Future<CallToolResult> _guarded(McpTool tool, CallToolRequest call) async {
    try {
      final invalid = tool.tool.inputSchema.validate(
        call.arguments ?? const <String, Object?>{},
      );
      if (invalid.isNotEmpty) {
        return toolError(
          invalid.map((e) => e.toErrorString()).join('; '),
          code: 'invalid_arguments',
        );
      }
      return await tool.call(call, deps);
    } on CliException catch (error) {
      return errorFrom(error);
    } catch (error, stack) {
      // The text is generic on purpose: an unexpected error's message can
      // carry paths or payload fragments. The detail goes to stderr, which is
      // the operator's channel, never the wire.
      deps.logger.err.writeln(
        'easyi18n mcp: ${tool.name} failed: $error\n$stack',
      );
      return toolError(
        'easyi18n mcp failed while running `${tool.name}`. See the server log.',
        code: 'internal_error',
      );
    }
  }
}
