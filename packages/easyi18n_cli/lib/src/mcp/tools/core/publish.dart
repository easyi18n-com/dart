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

/// The filters a publish runs under. `authorize` mints them into the
/// operation's scope and `publish` sends them to the door, which compares the
/// two: read separately they drift, and the drift is a 409 only a second
/// human approval can clear.
typedef PublishFilters = ({
  bool approvedOnly,
  bool requireComplete,
  String incompleteMode,
});

final publishInputs = <String, Schema>{
  'approved_only': Schema.bool(
    description: 'Publish only source-approved keys. Defaults to false.',
  ),
  'require_complete': Schema.bool(
    description: 'Refuse to publish an incomplete snapshot. The server '
        'measures it. Defaults to true; only the human may lower it.',
  ),
  'incomplete_mode': EnumSchema.untitledSingleSelect(
    values: ['skip', 'source'],
    description: 'What an untranslated cell does: leave it out, or ship the '
        'source text. Defaults to the project mode in easyi18n.yaml.',
  ),
};

PublishFilters publishFilters(CallToolRequest request, Easyi18nConfig config) =>
    (
      approvedOnly: boolArg(request, 'approved_only') ?? false,
      requireComplete: boolArg(request, 'require_complete') ?? true,
      // Never omitted, unlike the CLI's (`push_command.dart`): the scope holds
      // `skip` or `source` and the door compares it against `incompleteMode?.
      // name`, so an omitted field is a null that never matches. Mode A owns
      // its files, so an untranslated cell stays out of them; anything else
      // gets the source text — the resolution `publishProject` makes from the
      // project's own mode, made explicit here so the human approves a value
      // instead of a default.
      incompleteMode: stringArg(request, 'incomplete_mode') ??
          (config.mode == 'a' ? 'skip' : 'source'),
    );

/// The scope `POST /v1/operations` stores for a publish. `expected_pending` is
/// the literal 0 the backend requires: the approval is for a finished fill.
Map<String, Object?> publishScope(String projectId, PublishFilters filters) => {
      'project_id': projectId,
      'approved_only': filters.approvedOnly,
      'require_complete': filters.requireComplete,
      'incomplete_mode': filters.incompleteMode,
      'expected_pending': 0,
    };

/// `publish` — freezes the live state into a new version and serves it. Core,
/// not an adapter: what it publishes is the project's remote state, which is
/// the same question in both families.
final publishTool = McpTool(
  Tool(
    name: 'publish',
    description: 'Freeze the current translations into a new version and '
        'serve it. Needs the operation_id of an approved '
        'authorize {action: publish}: this is what readers see. The server '
        'refuses an incomplete snapshot unless the human lowers '
        'require_complete. Not undoable by itself; rollback is another '
        'approval.',
    annotations: ToolAnnotations(idempotentHint: false, openWorldHint: true),
    meta: Meta.fromMap({'anthropic/requiresUserInteraction': true}),
    inputSchema: toolSchema(
      properties: {
        'operation_id': Schema.string(
          description: 'The approved publish operation. Always required.',
        ),
        ...publishInputs,
        'skip_if_identical': Schema.bool(
          description: 'Answer with the current version instead of minting an '
              'identical one. Defaults to true.',
        ),
      },
    ),
  ),
  (request, deps) async {
    final operationId = stringArg(request, 'operation_id')?.trim();
    if (operationId == null || operationId.isEmpty) {
      return toolError(
        'publish needs an approved operation: call '
        'authorize {action: publish}, give the human the approval_url, and '
        'publish with its operation_id once the state is approved.',
        code: 'authorization_required',
      );
    }
    final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
    final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
    refuseUntrustedTarget(config.baseUrl, environment: deps.environment);
    final filters = publishFilters(request, config);
    return withProject(
      config: config,
      token: deps.requireToken(scope: 'publish'),
      logger: deps.logger,
      apiClientFactory: deps.apiClientFactory,
      body: (client, projectId) async {
        final PublishOutcome outcome;
        try {
          outcome = await client.publish(
            projectId: projectId,
            operationId: operationId,
            approvedOnly: filters.approvedOnly,
            requireComplete: filters.requireComplete,
            incompleteMode: filters.incompleteMode,
            skipIfIdentical: boolArg(request, 'skip_if_identical') ?? true,
          );
        } on ApiException catch (error) {
          return _refused(client, error, operationId, filters);
        }
        return _published(outcome, filters);
      },
    );
  },
);

/// The door's refusal, in the vocabulary the agent acts on. Anything this
/// does not name keeps the API client's own code, so a 402 or a 500 still
/// reads as itself.
Future<CallToolResult> _refused(
  TranslationsApiClient client,
  ApiException error,
  String operationId,
  PublishFilters filters,
) async {
  switch (error.code) {
    case 'fill_incomplete':
      return toolError(
        _incomplete(error.details, filters),
        code: 'fill_incomplete',
        statusCode: error.statusCode,
        extra: {
          for (final field in [
            'pending',
            'exhausted',
            'exhausted_total',
            'refused',
          ])
            field: error.details[field],
        },
      );
    case 'scope_changed':
      return toolError(
        'The publish filters changed since the human approved this operation '
        '(approved_only ${filters.approvedOnly}, require_complete '
        '${filters.requireComplete}, incomplete_mode '
        '${filters.incompleteMode}), or the operation approves a different '
        'action, such as a translate. Authorize {action: publish} again with '
        'the filters you mean to publish with.',
        code: 'scope_changed',
        statusCode: error.statusCode,
      );
    case 'authorization_required':
    case 'operation_not_approved':
    case 'operation_not_found':
      return approvalRefused(client, error, operationId,
          action: 'publish', second: 'a second version');
    default:
      return errorFrom(error);
  }
}

/// The `fill_incomplete` text, from the fields the server counted and nothing
/// else. The door's `pending` also holds the cells a gate refused and, under
/// approved_only, the unapproved ones, while fill_status reads the local
/// catalog: a cause guessed here can send the agent to a poll that never
/// changes the answer.
String _incomplete(Map<String, Object?> details, PublishFilters filters) {
  int count(Object? value) => value is int ? value : 0;
  final refused = details['refused'];
  final gated = refused is Map
      ? count(refused['icu_total']) + count(refused['markup_total'])
      : 0;
  final exhausted = count(details['exhausted_total']);
  return [
    'The server refused to publish: the snapshot it would freeze is '
        'incomplete (see pending, exhausted and refused).',
    if (filters.approvedOnly)
      'Under approved_only a cell also needs its approval to count as '
          'complete.',
    if (gated > 0)
      '$gated cell(s) were refused by the ICU or markup gates; polling does '
          'not change them. Report them to the human.',
    if (exhausted > 0)
      '$exhausted pair(s) used up their fill attempts; polling does not '
          'change them. Report them to the human.',
    if (count(details['pending']) > 0)
      'Call fill_status and follow its next. If it says publish and this '
          'refusal comes back, do not publish again: report these counts and '
          'refusals to the human so they can review the snapshot.',
    "Publishing anyway is the human's call, and needs a new authorize "
        '{action: publish} with require_complete: false.',
  ].join(' ');
}

CallToolResult _published(PublishOutcome outcome, PublishFilters filters) {
  final refused = outcome.icuRejectedTotal + outcome.markupRejectedTotal;
  return CallToolResult(
    content: [
      Content.text(
        text: outcome.unchanged
            ? 'publish: nothing changed; ${outcome.versionId} is still the '
                'served version.'
            : 'publish: ${outcome.versionId} is live '
                '(${outcome.keyCount} key(s))'
                '${refused == 0 ? '' : ', $refused cell(s) refused by the '
                    'ICU or markup gates — see refused'}. Run pull to write '
                'the files.',
      ),
    ],
    structuredContent: {
      'version_id': outcome.versionId,
      'key_count': outcome.keyCount,
      'unchanged': outcome.unchanged,
      'refused': {
        'icu': outcome.icuRejected,
        'icu_total': outcome.icuRejectedTotal,
        'markup': outcome.markupRejected,
        'markup_total': outcome.markupRejectedTotal,
      },
      // Only under the server-side gate is this a measurement: with
      // require_complete off nobody counted, and a 0 here would be a claim
      // this call never checked.
      'pending_at_publish': filters.requireComplete ? 0 : null,
      'incomplete_mode': filters.incompleteMode,
      'next': 'pull',
    },
  );
}
