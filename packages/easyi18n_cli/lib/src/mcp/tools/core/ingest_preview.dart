import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../../../adapters/android_adapter.dart';
import '../../../adapters/angular_adapter.dart' show angularMessages, kAngularFormat;
import '../../../adapters/stack_adapters.dart';
import '../../../api_client.dart';
import '../../../config.dart';
import '../../../fill_completeness.dart';
import '../../../push_runner.dart';
import '../../../sync_runner.dart';
import '../../deps.dart';
import '../../schemas.dart';
import '../dart/push_preview.dart';
import '../xcstrings/sync_preview.dart';

/// What the next ingest of either family would do: the part of its dry run
/// `authorize` and `fill_status` read, so neither names an adapter (D0).
class IngestPreview {
  IngestPreview.push(PushPreview preview)
    : ingest = 'push',
      estimate = preview.result?.estimatedCredits ?? 0,
      pending = preview.result?.pendingPairs ?? 0,
      complete = (preview.result?.pendingPairs ?? 0) == 0,
      exhausted = preview.result?.exhaustedPairs ?? const [],
      budgetExhausted = preview.result?.budgetExhaustedPairs ?? const [],
      langs = preview.result?.targetLangs ?? const [],
      overKeyCap = preview.result?.wouldExceedKeyCap ?? false,
      manifest = preview.result?.manifest;

  /// The dry run of a sync prices the pairs it would fill but does not count
  /// them: [pending] is only what a fill in flight holds, so [complete] also
  /// needs nothing left to spend. A catalog is one request, one batch.
  IngestPreview.sync(SyncPreview preview)
    : ingest = 'sync',
      estimate = preview.result.estimatedCredits,
      pending = preview.result.pendingSkipped,
      complete =
          preview.result.pendingSkipped == 0 &&
          preview.result.estimatedCredits == 0,
      exhausted = preview.result.exhaustedPairs,
      budgetExhausted = preview.result.budgetExhaustedPairs,
      langs = preview.result.targetLangs,
      overKeyCap = preview.result.wouldExceedKeyCap,
      manifest = switch (preview.result.batchSha256) {
        final sha? => OperationManifest([
          ManifestBatch(sha, _catalogEntries(preview.bytes, preview.format)),
        ]),
        null => null,
      };

  /// The tool that ingests: `push` or `sync`.
  final String ingest;

  /// In millicredits.
  final int estimate;
  final int pending;
  final bool complete;
  final List<ExhaustedPair> exhausted;
  final List<ExhaustedPair> budgetExhausted;
  final List<String> langs;

  /// The real ingest would take the project past its plan's key cap.
  final bool overKeyCap;

  /// What `authorize` submits, or null when the server hashed no batch.
  final OperationManifest? manifest;
}

/// The entries of the uploaded file as the server's parser of [format]
/// counts them, from the same bytes decoded the same way: the `strings` of
/// an `.xcstrings` catalog, the top-level strings of a `json` file and the
/// leaves of a `nested_json` one, blank ones left out, the ids under the
/// `translations` of an Angular file, and the resources of a `strings.xml`
/// that `doctor` counts. The human reads the count on the approval screen,
/// and the server refuses an operation that counts none.
int _catalogEntries(List<int> bytes, String? format) {
  final text = utf8.decode(bytes, allowMalformed: true);
  if (format == kAndroidFormat) return AndroidAdapter.translatableKeys(text) ?? 0;
  final doc = jsonDecode(text) as Map;
  if (format == kAngularFormat) {
    return (angularMessages(doc) ?? const {}).values
        .where((text) => text.trim().isNotEmpty).length;
  }
  if (format != 'json' && format != 'nested_json') {
    final strings = doc['strings'];
    return strings is Map ? strings.length : 0;
  }
  return _strings(doc, deep: format == 'nested_json');
}

int _strings(Map<Object?, Object?> node, {required bool deep}) =>
    node.values.fold(0, (count, value) => count + switch (value) {
      final String text => text.trim().isEmpty ? 0 : 1,
      final Map<Object?, Object?> child when deep => _strings(child, deep: deep),
      _ => 0,
    });

/// The tool that ingests for the project at [configPath]: `sync` for a
/// file-first project, `push` otherwise.
String ingestOf(String configPath, Easyi18nConfig config, McpDeps deps) {
  final root = p.normalize(p.absolute(p.dirname(configPath)));
  return adapterFor(root, config, extractor: deps.extractor).family ==
          'file-first'
      ? 'sync'
      : 'push';
}

/// The dry run of the ingest this project's family makes.
Future<CallToolResult> withIngestPreview(
  CallToolRequest request,
  McpDeps deps, {
  required String tool,
  required FutureOr<CallToolResult> Function(
    TranslationsApiClient client,
    String projectId,
    IngestPreview preview,
  )
  body,
}) async {
  final configPath = deps.configPathFor(stringArg(request, 'project_dir'));
  final config = Easyi18nConfig.load(File(configPath), logger: deps.logger);
  return ingestOf(configPath, config, deps) == 'sync'
      ? withSyncPreview(
          request,
          deps,
          tool: tool,
          body: (client, id, preview) =>
              body(client, id, IngestPreview.sync(preview)),
        )
      : withPushPreview(
          request,
          deps,
          tool: tool,
          body: (client, id, preview) =>
              body(client, id, IngestPreview.push(preview)),
        );
}
