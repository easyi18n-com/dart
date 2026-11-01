import 'dart:io';
import 'dart:math';

import 'package:dart_mcp/server.dart';

import '../../../config.dart';
import '../../../credits.dart';
import '../../../push_runner.dart';
import '../../../security.dart';
import '../../../session.dart';
import '../../ceiling.dart';
import '../../deps.dart';
import '../../schemas.dart';
import '../../tool_errors.dart';
import '../dart/push_preview.dart';
import '../xcstrings/sync_preview.dart';
import 'ingest_gate.dart';
import 'ingest_preview.dart';
import 'publish.dart';
import 'rollback.dart';

/// `authorize` — asks the backend for a human approval (D17) and returns the
/// link the human has to open. It spends nothing itself, so it is not rUI;
/// what the approval lets a push charge is capped by the backend.
final authorizeTool = McpTool(
  Tool(
    name: 'authorize',
    description: 'Request a human approval: a translate (the next push or '
        'sync), '
        'capped at max_credits, a publish, or a rollback. Returns an '
        'approval_url for the human. With operation_id it only reads that '
        'operation: that is how you wait for the approval. Never raise '
        'max_credits on your own.',
    annotations: ToolAnnotations(idempotentHint: true, openWorldHint: true),
    inputSchema: toolSchema(
      properties: {
        'action': EnumSchema.untitledSingleSelect(
          values: ['translate', 'publish', 'rollback'],
          description: 'What the approval covers.',
        ),
        'max_credits': Schema.int(
          minimum: 1,
          description: 'The most the human agrees to spend, in credits. '
              'Required to create a translate authorization; a publish or a '
              'rollback spends nothing and takes none.',
        ),
        'operation_id': Schema.string(
          description: 'An operation to read instead of creating one.',
        ),
        ...pushInputs,
        ...syncInputs,
        ...publishInputs,
        ...rollbackInputs,
      },
    ),
  ),
  (request, deps) async {
    final operationId = stringArg(request, 'operation_id');
    if (operationId != null) {
      final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
      final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
      refuseUntrustedTarget(config.baseUrl, environment: deps.environment);
      return withProject(
        config: config,
        token: deps.requireToken(scope: 'translate'),
        logger: deps.logger,
        apiClientFactory: deps.apiClientFactory,
        body: (client, _) async => _operationResult(
          await client.getOperation(operationId),
          ingest: ingestOf(configPath, config, deps),
        ),
      );
    }
    final action = stringArg(request, 'action');
    if (action == null) {
      return toolError(
        'authorize needs action (translate, publish or rollback), or the '
        'operation_id of an authorization to read.',
        code: 'action_required',
      );
    }
    if (action == 'publish' || action == 'rollback') {
      return _authorizeVersionAction(request, deps, action);
    }
    final maxCredits = intArg(request, 'max_credits');
    if (maxCredits == null) {
      return toolError(
        'authorize {action: translate} needs max_credits: the most the human '
        'agrees to spend, in credits. Show them the push_preview or '
        'sync_preview estimate and ask.',
        code: 'max_credits_required',
      );
    }
    final ceiling = mcpCeiling(deps.environment);
    return withIngestPreview(request, deps, tool: 'authorize',
        body: (client, projectId, preview) async {
      final ingest = preview.ingest;
      if (preview.overKeyCap) return planLimit(ingest);
      final estimate = preview.estimate;
      if (estimate == 0) {
        return toolError(
          'Nothing to authorize: this $ingest costs 0 credits. Call $ingest '
          'without an operation_id.',
          code: 'nothing_to_authorize',
        );
      }
      final manifest = preview.manifest;
      if (manifest == null) {
        return toolError(
          'The server returned no batch hashes, so it cannot approve a '
          '$ingest. Update the easyi18n backend, or $ingest from the CLI.',
          code: 'operations_unsupported',
        );
      }
      final narrow = ingest == 'push' ? ', or narrow the push with langs' : '';
      // The ceiling clamps M rather than refusing a max_credits above it:
      // ceil(42 x 1.2) = 51 against the default 50 is a push the human can
      // approve at 50 (D7). Only an M below the estimate aborts.
      final authorized =
          authorizedCredits(estimate, min(maxCredits, ceiling));
      if (authorized * kMillicreditsPerCredit < estimate) {
        final ceilingShort = ceiling * kMillicreditsPerCredit < estimate;
        return toolError(
          ceilingShort
              ? 'The $ingest is estimated at ~${creditsOf(estimate)} credits '
                  'and this server allows $ceiling per authorization '
                  '(EASYI18N_MCP_MAX_CREDITS${ceiling == 0 ? '=0 disables '
                      'real ingests' : ''}). Only the human can raise it, in '
                  'the MCP client config$narrow.'
              : 'The $ingest is estimated at ~${creditsOf(estimate)} credits, '
                  'above max_credits $maxCredits. Ask the human for a higher '
                  'max_credits$narrow.',
          code: ceilingShort ? 'ceiling_below_estimate' : 'below_estimate',
          extra: {
            'estimated_credits': creditsOf(estimate),
            'max_credits': maxCredits,
            'env_max': ceiling,
          },
        );
      }
      final operation = await client.createOperation(
        action: 'translate',
        maxCredits: authorized,
        scope: {
          'project_id': projectId,
          'langs': preview.langs,
          'unit_count': manifest.unitCount,
          'batches': manifest.toJson(),
          'payload_sha256': manifest.payloadSha256,
        },
      );
      return _operationResult(operation, extra: {
        'estimated_credits': creditsOf(estimate),
        'max_credits': authorized,
        'ceiling': {'env_max': ceiling},
      }, ingest: ingest);
    });
  },
);

/// A publish or a rollback approval spends nothing, so there is no estimate to
/// compare and no ceiling to clamp: the whole call is the scope the door will
/// check. Both scopes are built by the same function the acting tool uses —
/// two readings of the same arguments are a 409 only a second human approval
/// clears.
Future<CallToolResult> _authorizeVersionAction(
  CallToolRequest request,
  McpDeps deps,
  String action,
) async {
  if (intArg(request, 'max_credits') != null) {
    return toolError(
      'A $action approval spends nothing, so it takes no max_credits. Drop '
      'it, or authorize {action: translate} if you meant the fill.',
      code: 'max_credits_not_applicable',
    );
  }
  final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
  final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
  refuseUntrustedTarget(config.baseUrl, environment: deps.environment);
  return withProject(
    config: config,
    token: deps.requireToken(scope: 'publish'),
    logger: deps.logger,
    apiClientFactory: deps.apiClientFactory,
    body: (client, projectId) async => _operationResult(
      await client.createOperation(
        action: action,
        scope: action == 'publish'
            ? publishScope(projectId, publishFilters(request, config))
            : rollbackScope(projectId, rollbackTarget(request)),
      ),
    ),
  );
}

CallToolResult _operationResult(
  Map<String, Object?> operation, {
  Map<String, Object?> extra = const {},
  String ingest = 'push',
}) {
  final state = operation['state'];
  // The action picks a branch, it is never echoed: with operation_id alone
  // the tool knows only what the operation says it is.
  final approved = switch (operation['action']) {
    'publish' => 'publish',
    'rollback' => 'rollback',
    _ => ingest,
  };
  final next = switch (state) {
    'pending_approval' => 'wait',
    'approved' => approved,
    _ => 'authorize',
  };
  return CallToolResult(
    content: [
      Content.text(
        // Derived from `next`, never the server's `state`: a string the
        // server sent travels only in structuredContent (spec section 4.4).
        text: switch (next) {
          'wait' => 'authorize: waiting for the human. Give them the '
              'approval_url from this result, then call authorize with this '
              'operation_id to see the approval.',
          'push' || 'sync' =>
            'authorize: approved. Call $next with this operation_id.',
          'publish' => 'authorize: approved. Call publish with this '
              'operation_id. It is good for one publish.',
          'rollback' => 'authorize: approved. Call rollback with this '
              'operation_id. It is good for one rollback.',
          _ => 'authorize: this operation cannot be used. Report what it '
              'charged and ask the human before authorizing again.',
        },
      ),
    ],
    structuredContent: {...operation, ...extra, 'next': next},
  );
}
