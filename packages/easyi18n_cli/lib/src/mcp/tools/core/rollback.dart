import 'dart:io';

import 'package:dart_mcp/server.dart';

import '../../../api_client.dart';
import '../../../config.dart';
import '../../../exceptions.dart';
import '../../../security.dart';
import '../../../session.dart';
import '../../deps.dart';
import '../../schemas.dart';
import '../../tool_errors.dart';
import 'approval.dart';

final rollbackInputs = <String, Schema>{
  'version': Schema.string(
    description: 'The version to restore. Defaults to "previous", the one '
        'served before the current version: the undo of the last publish.',
  ),
};

/// The version an agent asks to go back to. `previous` is the only target it
/// can name on its own: `/v1` lists no versions, so the backend resolves the
/// alias when it mints the operation and the human approves an id.
String rollbackTarget(CallToolRequest request) {
  final raw = stringArg(request, 'version')?.trim();
  return raw == null || raw.isEmpty ? 'previous' : raw;
}

/// The scope `POST /v1/operations` stores for a rollback. `from_version` is
/// always the alias `current`: an agent never picks which version it is
/// leaving. The mint resolves every alias in this scope against one read of
/// the project, so the pair the human approves is a pair that coexisted.
Map<String, Object?> rollbackScope(String projectId, String version) => {
      'project_id': projectId,
      'from_version': 'current',
      'to_version': version,
    };

/// `rollback` — restores a published version as a NEW version. History is
/// never rewritten, but every served pointer moves and the webhooks fire, so
/// this is destructive in the sense that matters to a reader.
final rollbackTool = McpTool(
  Tool(
    name: 'rollback',
    description: 'Restore a previously published version and serve it again, '
        'as a new version. Call authorize {action: rollback} first. With a '
        'key in EASYI18N_TOKEN, pass the operation_id it returns once the '
        'human approves; when it answers that none is needed, as it does for '
        "the human's easyi18n login, roll back without one. Use it to undo a "
        'bad publish: readers see the restored content immediately.',
    annotations: ToolAnnotations(
      idempotentHint: false,
      openWorldHint: true,
      destructiveHint: true,
    ),
    meta: Meta.fromMap({'anthropic/requiresUserInteraction': true}),
    inputSchema: toolSchema(
      properties: {
        'operation_id': Schema.string(
          description: 'The approved rollback operation. Required unless '
              'authorize answered that none is needed.',
        ),
        ...rollbackInputs,
      },
    ),
  ),
  (request, deps) async {
    final operationId = switch (stringArg(request, 'operation_id')?.trim()) {
      null || '' => null,
      final id => id,
    };
    final version = rollbackTarget(request);
    final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
    final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
    refuseUntrustedTarget(config.baseUrl, environment: deps.environment);
    // The login rolls back as its human (decision 1 of #2579); a key needs
    // the operation (D17).
    if (operationId == null && !deps.usesLogin(config.baseUrl)) {
      return _unapproved();
    }
    return withProject(
      config: config,
      token: deps.requireToken(config.baseUrl, scope: 'publish'),
      logger: deps.logger,
      apiClientFactory: deps.apiClientFactory,
      body: (client, projectId) async {
        final PublishOutcome outcome;
        try {
          outcome = await client.restoreVersion(
            projectId: projectId,
            versionId: version,
            operationId: operationId,
          );
        } on ApiException catch (error) {
          return _refused(client, error, operationId, version);
        }
        return _restored(outcome, version);
      },
    );
  },
);

/// A rollback with no operation, refused here for a key or by the door for a
/// login it makes ask.
CallToolResult _unapproved({int? statusCode}) => toolError(
  'rollback needs an approved operation: call '
  'authorize {action: rollback}, give the human the approval_url, and '
  'roll back with its operation_id once the state is approved.',
  code: 'authorization_required',
  statusCode: statusCode,
);

Future<CallToolResult> _refused(
  TranslationsApiClient client,
  ApiException error,
  String? operationId,
  String version,
) async {
  switch (error.code) {
    case 'scope_changed':
      return toolError(
        'This approval no longer describes the rollback: either the project '
        'was published again since the human approved it, or "$version" now '
        'names a different version, or the operation approves another action. '
        'Authorize {action: rollback} again and show the human the new '
        'target.',
        code: 'scope_changed',
        statusCode: error.statusCode,
      );
    case 'authorization_required' ||
          'operation_not_approved' ||
          'operation_not_found' when operationId != null:
      return approvalRefused(client, error, operationId,
          action: 'rollback', second: 'to go back again');
    case 'authorization_required':
      return _unapproved(statusCode: error.statusCode);
    default:
      return errorFrom(error);
  }
}

CallToolResult _restored(PublishOutcome outcome, String version) {
  // The opposite verdict to publish's (#605): the snapshot is copied verbatim,
  // so the named cells ARE being served — today's publish gates would refuse
  // them. Nothing fell back.
  final flagged = outcome.icuRejectedTotal + outcome.markupRejectedTotal;
  final restoredFrom = outcome.restoredFrom ?? version;
  return CallToolResult(
    content: [
      Content.text(
        text: 'rollback: $restoredFrom is live again as ${outcome.versionId} '
            '(${outcome.keyCount} key(s))'
            '${flagged == 0 ? '' : ', $flagged cell(s) in it would be refused '
                "by today's publish gates and are being served, listed under "
                'flagged'}. '
            'Run pull to write the files.',
      ),
    ],
    structuredContent: {
      'restored_from': restoredFrom,
      'version_id': outcome.versionId,
      'key_count': outcome.keyCount,
      'flagged': {
        'icu': outcome.icuRejected,
        'icu_total': outcome.icuRejectedTotal,
        'markup': outcome.markupRejected,
        'markup_total': outcome.markupRejectedTotal,
      },
      'next': 'pull',
    },
  );
}
