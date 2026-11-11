import 'dart:math';

import 'package:dart_mcp/server.dart';

import '../../../api_client.dart';
import '../../../config.dart';
import '../../../credits.dart';
import '../../../exceptions.dart';
import '../../../output_format.dart';
import '../../../push_runner.dart';
import '../../ceiling.dart';
import '../../request_log.dart';
import '../../tool_errors.dart';

// The consent gate `push` and `sync` share, so a guard added to one ingest
// cannot miss the other. `ingest` names the tool in what the agent reads.

/// The refusal that comes before any request, or null with the ceiling (D7)
/// the operation is judged on.
({CallToolResult? refusal, int ceiling}) ingestPreflight(
  String root,
  Map<String, String> environment, {
  required String ingest,
}) {
  final unresolved = RequestLog.unresolved(root);
  if (unresolved.isNotEmpty) {
    return (
      refusal: toolError(
        'An earlier request may have reached the server without an answer, '
        'so ${ingest}ing again could ingest twice. Call fill_status to '
        'reconcile it; do not $ingest until it is resolved.',
        code: 'request_unresolved',
        extra: {'logs': unresolved},
      ),
      ceiling: 0,
    );
  }
  final ceiling = mcpCeiling(environment);
  if (ceiling == 0) {
    return (
      refusal: toolError(
        'EASYI18N_MCP_MAX_CREDITS=0 disables real ingests from this MCP '
        'server. Only the human can change it, in the MCP client config.',
        code: 'ingests_disabled',
      ),
      ceiling: 0,
    );
  }
  return (refusal: null, ceiling: ceiling);
}

/// A billable ingest sent without an operation. [estimate] is null when the
/// server refused without a readable one.
CallToolResult authorizationRequired(
  String ingest,
  int? estimate, {
  Map<String, Object?>? attempt,
}) => toolError(
  'This $ingest '
  '${estimate == null ? '' : 'is estimated at ~${creditsOf(estimate)} credits and '}'
  'needs a human approval: call authorize {action: translate}, give '
  'the human the approval_url, and $ingest with its operation_id once '
  'approved.',
  code: 'authorization_required',
  statusCode: attempt == null ? null : 403,
  extra: {
    'attempt': ?attempt,
    if (estimate != null) 'estimated_credits': creditsOf(estimate),
  },
);

/// Why an ingest with no operation cannot go: a key needs one for any spend
/// (D17), and the login, which spends as its human (decision 1 of #2579), is
/// still held to the ceiling the human set (D7). Null when it can.
CallToolResult? refuseUnauthorized(String ingest, int estimate, int ceiling,
    {required bool login}) {
  if (estimate <= 0) return null;
  if (!login) return authorizationRequired(ingest, estimate);
  if (estimate <= ceiling * kMillicreditsPerCredit) return null;
  return toolError(
    'This $ingest is estimated at ~${creditsOf(estimate)} credits, above the '
    '$ceiling this MCP server allows (EASYI18N_MCP_MAX_CREDITS). Only the '
    'human can raise it, in the MCP client config.',
    code: 'above_ceiling',
    extra: {'estimated_credits': creditsOf(estimate), 'env_max': ceiling},
  );
}

/// The dry run says the plan refuses the keys this ingest would create. The
/// server answers the real one with a 402 whatever is authorized, so this
/// stops before an approval is asked for or an attempt is spent.
CallToolResult planLimit(String ingest) =>
    toolError(planLimitText(ingest), code: 'plan_limit');

/// What the agent reads wherever `next` is `plan_limit`.
String planLimitText(String ingest) =>
    'This $ingest would take the project past the key limit of its plan, so '
    'the server refuses it with plan_limit whatever is authorized. Tell the '
    'human: a plan upgrade or fewer keys clears it; authorizing or '
    '${ingest}ing again does not.';

/// Whether the `pull` that ends this loop can write its files, graded with
/// the preview so the agent stops before the spend (#2133). Null where the
/// loop never pulls. A read that fails is `unknown`, which blocks nothing: it
/// must not hide the estimate.
Future<OutputFormatCheck?> gradeOutputFormat(
  TranslationsApiClient client,
  String projectId,
  Easyi18nConfig config, {
  required String family,
}) async {
  if (!OutputFormatCheck.pulls(config, family: family)) return null;
  try {
    return await OutputFormatCheck.of(client, projectId, config.format);
  } on CliException catch (e) {
    return OutputFormatCheck(
        config.format, OutputFormatReadiness.unknown, e.message);
  }
}

/// What the agent reads wherever `next` is `output_format`.
String outputFormatText(OutputFormatCheck check) =>
    'Stop and tell the human: ${check.message}. ${check.remedy.join(' ')} '
    'Authorizing or ingesting does not clear it.';

/// Why [operation] cannot spend on the ingest whose batches hash to
/// [manifest], or null when it can. Checked here so a refusal costs no
/// request; the server checks all of it again.
CallToolResult? refuseOperation(
  Map<String, Object?> operation,
  OperationManifest? manifest,
  int ceiling, {
  required String ingest,
}) {
  // First, whatever the state: a publish or rollback approval never lets an
  // ingest spend, so waiting for it or re-approving it leads nowhere. The
  // text names the action from this closed set; the server's string travels
  // only in `action`.
  final action = operation['action'];
  if (action != 'translate') {
    final named = switch (action) {
      'publish' => 'a publish',
      'rollback' => 'a rollback',
      _ => 'an action this client does not know',
    };
    return toolError(
      'This operation approves $named, not a translate, so this $ingest '
      'cannot spend it. Call ${ingest}_preview and authorize '
      '{action: translate}.',
      code: 'action_mismatch',
      extra: {'action': action, 'state': operation['state']},
    );
  }
  final state = operation['state'];
  if (state != 'approved') {
    const ask = ' Report what it charged and call authorize again only if the '
        'human agrees.';
    final (code, message) = switch (state) {
      // A second authorize on this scope returns this same operation, so the
      // human is asked to approve, never whether to authorize again.
      'pending_approval' => (
          'authorization_required',
          'This operation is waiting for the human. Give them the '
              'approval_url, wait with authorize {operation_id} until the state '
              'is approved, then $ingest with this operation_id. Do not request '
              'a new authorization.',
        ),
      'expired' =>
        ('expired', 'This operation expired before it was used.$ask'),
      'exhausted' =>
        ('budget_exhausted', 'This operation has no budget left.$ask'),
      _ => ('authorization_required', 'This operation is not approved.$ask'),
    };
    return toolError(
      message,
      code: code,
      extra: {
        'state': state,
        'approval_url': operation['approval_url'],
        'charged_mc': operation['charged_mc'],
      },
    );
  }
  final authorized = operation['authorized_mc'];
  if (authorized is! int || authorized > ceiling * kMillicreditsPerCredit) {
    return toolError(
      'This operation authorizes more than this MCP server allows per '
      'authorization ($ceiling credits, EASYI18N_MCP_MAX_CREDITS). Ask the '
      'human to authorize again, or to raise the ceiling in the MCP client '
      'config.',
      code: 'above_ceiling',
      extra: {'authorized_mc': authorized, 'env_max': ceiling},
    );
  }
  final scope = operation['scope'];
  final approved = scope is Map ? scope['payload_sha256'] : null;
  if (manifest?.payloadSha256 != approved) {
    return toolError(
      'The strings changed since the human approved this operation, so this '
      '$ingest is not the one they approved. Call ${ingest}_preview and '
      'authorize again.',
      code: 'scope_changed',
    );
  }
  return null;
}

/// An ingest's answered 4xx, with its attempt. A 403 `authorization_required`
/// means a pair became payable after the dry run: the server's text names the
/// REST door, so the agent reads the same remedy the local gate gives, with
/// the estimate the server sends in millicredits.
CallToolResult ingestRefused(
  String ingest,
  ApiException error,
  Map<String, Object?> attempt,
) {
  if (error.statusCode == 403 && error.code == 'authorization_required') {
    final mc = error.details['estimatedCredits'];
    return authorizationRequired(
      ingest,
      mc is int ? mc : null,
      attempt: attempt,
    );
  }
  return toolError(
    error.message,
    code: error.code ?? '${ingest}_refused',
    statusCode: error.statusCode,
    extra: {'attempt': attempt},
  );
}

/// A request that left without a readable answer: the server may have acted.
CallToolResult unresolvedRequest(
  String ingest,
  Map<String, Object?> attempt, {
  Map<String, Object?> extra = const {},
}) => toolError(
  'A request left without a readable answer: the server may have acted on '
  'it. Call fill_status to reconcile before ${ingest}ing again.',
  code: 'request_unresolved',
  extra: {'attempt': attempt, ...extra},
);

/// The `operation` block of an ingest result.
Map<String, Object?>? operationSummary(Map<String, Object?>? operation) =>
    operation == null
    ? null
    : {
        'id': operation['operation_id'],
        for (final k in ['authorized_mc', 'reserved_mc', 'charged_mc'])
          k: operation[k],
      };

final _random = Random.secure();

/// An attempt or request id: the shape [checkedId] accepts.
String mintId() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
