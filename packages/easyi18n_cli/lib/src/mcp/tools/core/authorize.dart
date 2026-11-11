import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dart_mcp/server.dart';

import '../../../api_client.dart';
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
        'capped at max_credits, a publish, or a rollback. With a key in '
        'EASYI18N_TOKEN it returns an approval_url for the human. With '
        'operation_id it reads that operation and, while it is pending, '
        'waits up to 45 s for the human\'s answer: call it again in the same '
        'turn while next is wait. With the human\'s easyi18n login it '
        'creates nothing and answers approval: not_needed with the tool to '
        'call next, unless the server says that login needs an approval too. '
        'Never raise max_credits on your own.',
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
      final client = (deps.apiClientFactory ?? TranslationsApiClient.new)(
        baseUrl: config.baseUrl,
        token: deps.requireToken(config.baseUrl, scope: 'translate'),
      );
      try {
        return await _awaitDecision(request, deps, client, operationId,
            ingest: ingestOf(configPath, config, deps));
      } finally {
        client.close();
      }
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
      if (await _loginNeedsNone(deps, client, projectId)) {
        return _noneNeeded(ingest);
      }
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
      return _operationResult(operation, deps, extra: {
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
    token: deps.requireToken(config.baseUrl, scope: 'publish'),
    logger: deps.logger,
    apiClientFactory: deps.apiClientFactory,
    body: (client, projectId) async =>
        await _loginNeedsNone(deps, client, projectId)
            ? _noneNeeded(action)
            : _operationResult(
                await client.createOperation(
                  action: action,
                  scope: action == 'publish'
                      ? publishScope(projectId, publishFilters(request, config))
                      : rollbackScope(projectId, rollbackTarget(request)),
                ),
                deps,
              ),
  );
}

/// A login spends and publishes as its human (decision 1 of #2579) unless
/// the server says it needs an approval after all: the flag that puts a login
/// back under D17 (agent-native D3). Asked of the server so that day mints the
/// operation the 403 sends the agent here for. A key never asks.
Future<bool> _loginNeedsNone(McpDeps deps, TranslationsApiClient client,
        String projectId) async =>
    deps.usesLogin(client.baseUrl) &&
    !(await client.fetchCredential(projectId: projectId))
        .requiresOperationApproval;

CallToolResult _noneNeeded(String next) => CallToolResult(
  content: [
    Content.text(
      text: 'authorize: not needed. This MCP server uses the login of '
          "'easyi18n login', which spends and publishes as its human without "
          'an approval. Call $next without an operation_id.',
    ),
  ],
  structuredContent: {'approval': 'not_needed', 'next': next},
);

/// Under the lowest tool timeout measured: 60 s in Cursor CLI and the MCP
/// TypeScript SDK (#2446).
const _waitPerCall = Duration(seconds: 45);

/// T, fixed by Leo on 2026-10-28 (#2446).
const _waitTotal = Duration(minutes: 10);
const _pollEvery = Duration(seconds: 5);
const _progressEvery = Duration(seconds: 10);

/// EASYI18N_MCP_APPROVAL_WAIT_SECONDS can only shorten T, so a test of the
/// give-up need not wait ten minutes.
Duration _waitTotalIn(Map<String, String> environment) {
  final seconds = int.tryParse(
      environment['EASYI18N_MCP_APPROVAL_WAIT_SECONDS']?.trim() ?? '');
  if (seconds == null || seconds < 0) return _waitTotal;
  final asked = Duration(seconds: seconds);
  return asked < _waitTotal ? asked : _waitTotal;
}

/// Reads [operationId] again every 5 s while it is pending, until the human
/// answers, 45 s pass, or T since this process first saw it runs out. The
/// answer reaches the agent only through a call still open: no measured
/// client starts a turn on a server notification (#2446).
Future<CallToolResult> _awaitDecision(
  CallToolRequest request,
  McpDeps deps,
  TranslationsApiClient client,
  String operationId, {
  required String ingest,
}) async {
  final started = deps.clock();
  final giveUpAt = deps.approvalSeen
      .putIfAbsent(operationId, () => started)
      .add(_waitTotalIn(deps.environment));
  final callEnds = started.add(_waitPerCall);
  final deadline = giveUpAt.isBefore(callEnds) ? giveUpAt : callEnds;
  final token = request.meta?.progressToken;
  var reported = 0;
  final initialBudget = deadline.difference(started);
  Map<String, Object?> operation;
  try {
    operation = await client.getOperation(operationId).timeout(
        initialBudget > Duration.zero ? initialBudget : _waitPerCall);
  } on TimeoutException {
    return toolError('Could not read the approval in time. Retry authorize '
        'with the same operation_id.', code: 'approval_read_timeout',
        retryable: true);
  }
  while (operation['state'] == 'pending_approval') {
    final left = deadline.difference(deps.clock());
    // A client that closed stdin waits for the process to exit.
    if (left <= Duration.zero || !deps.connected()) break;
    await deps.sleep(left < _pollEvery ? left : _pollEvery);
    final ticks = deps.clock().difference(started).inSeconds ~/
        _progressEvery.inSeconds;
    if (token != null && ticks > reported) {
      reported = ticks;
      deps.notifyProgress(ProgressNotification(
        progressToken: token,
        progress: reported,
        message: 'Waiting for the human to approve or deny',
      ));
    }
    final remaining = deadline.difference(deps.clock());
    if (remaining <= Duration.zero || !deps.connected()) break;
    operation = await client.getOperation(operationId).timeout(remaining,
        onTimeout: () => operation);
  }
  return _operationResult(operation, deps,
      ingest: ingest, read: true, waitOver: !deps.clock().isBefore(giveUpAt));
}

/// [read] is a call with operation_id; [waitOver], that T ran out on it.
CallToolResult _operationResult(
  Map<String, Object?> operation,
  McpDeps deps, {
  Map<String, Object?> extra = const {},
  String ingest = 'push',
  bool read = false,
  bool waitOver = false,
}) {
  final state = operation['state'];
  if (state == 'pending_approval' && !read) {
    deps.approvalSeen.putIfAbsent('${operation['operation_id']}', deps.clock);
  }
  // The action picks a branch, it is never echoed: with operation_id alone
  // the tool knows only what the operation says it is.
  final approved = switch (operation['action']) {
    'publish' => 'publish',
    'rollback' => 'rollback',
    _ => ingest,
  };
  final next = switch (state) {
    'pending_approval' => waitOver ? 'ask_human' : 'wait',
    'approved' => approved,
    'denied' => 'stop',
    'expired' => 'reauthorize',
    _ => 'authorize',
  };
  return CallToolResult(
    content: [
      Content.text(
        // Derived from `next`, never the server's `state`: a string the
        // server sent travels only in structuredContent (spec section 4.4).
        text: switch (next) {
          'wait' when read => 'authorize: still waiting for the human. Call '
              'authorize with this operation_id again now, in this same '
              'turn, without repeating the approval_url.',
          'wait' => 'authorize: waiting for the human. Give them the '
              'approval_url from this result, then call authorize with this '
              'operation_id in this same turn: it waits up to 45 s for their '
              'answer. Do not end your turn to wait.',
          'ask_human' => 'authorize: the human has not answered, and the '
              'wait is over. Stop waiting: tell them the approval_url stays '
              'open until expires_at, and read this operation_id again when '
              'they say they answered.',
          'stop' => 'authorize: the human denied this operation, so nothing '
              'was charged. Tell them, and authorize again only if they ask.',
          'reauthorize' => 'authorize: this approval expired. Tell the human, '
              'and authorize again only if they still want it.',
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
