import 'package:dart_mcp/server.dart';

import '../../../api_client.dart';
import '../../../exceptions.dart';
import '../../tool_errors.dart';

/// What an agent is told when the door refuses the approval it presented.
///
/// The door says the operation cannot authorize; only the operation says why,
/// and its `approval_url` is what the human needs. Read on refusal only: the
/// happy path never spends this call. Shared by `publish` and `rollback`
/// because the three refusals and the three states are the door's, not the
/// action's — only the sentence that names the action differs.
Future<CallToolResult> approvalRefused(
  TranslationsApiClient client,
  ApiException error,
  String operationId, {
  required String action,
  required String second,
}) async {
  Map<String, Object?>? operation;
  try {
    operation = await client.getOperation(operationId);
  } on CliException {
    operation = null;
  }
  final state = operation?['state'];
  return toolError(
    state == 'expired'
        ? 'This approval expired before it was used. Ask the human whether to '
            'authorize the $action again.'
        : state == 'exhausted'
            ? 'This approval was already used: a $action approval is good for '
                'one $action. Authorize again only if the human wants $second.'
            : state == 'pending_approval'
                ? 'This $action is not approved. Give the human the approval_url, '
                    'wait with authorize {operation_id}, and $action once the '
                    'state is approved.'
                : 'This $action is not approved. Ask the human whether to '
                    'authorize the $action again.',
    code: state == 'expired' ? 'expired' : 'authorization_required',
    statusCode: error.statusCode,
    extra: {
      'state': state,
      'approval_url': operation?['approval_url'],
    },
  );
}
