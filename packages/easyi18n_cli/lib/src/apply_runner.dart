import 'dart:io';

import 'package:path/path.dart' as p;

import 'apply/tr_rewriter.dart';
import 'cli_output.dart';
import 'commands/apply_command.dart' show ApiClientFactory;
import 'config.dart';
import 'logger.dart';
import 'session.dart';

class ApplyRunner {
  ApplyRunner({TrRewriter? rewriter}) : _rewriter = rewriter ?? TrRewriter();
  final TrRewriter _rewriter;

  Future<ApplyPlan> plan({
    required Easyi18nConfig config, required String configPath,
    required String token, required CliLogger logger,
    String sourceDir = 'lib', ApiClientFactory? apiClientFactory,
  }) => withProject(
    config: config, token: token, logger: logger,
    apiClientFactory: apiClientFactory,
    body: (client, projectId) async {
      final changes = await client.fetchPendingCodeChanges(projectId: projectId);
      final root = p.dirname(configPath);
      return ApplyPlan(
        rewrites: changes.isEmpty
            ? const RewritePlan(edits: [], unmatched: [], filesScanned: 0)
            : _rewriter.plan(Directory(p.join(root, sourceDir)), changes, relativeTo: root),
        pendingCount: changes.length,
        projectDir: p.normalize(p.absolute(root)), baseUrl: config.baseUrl,
      );
    },
  );

  ApplyResult apply(ApplyPlan plan, {bool write = false}) => ApplyResult(
    plan: plan, write: write,
    filesChanged: write && !plan.rewrites.isEmpty ? _rewriter.applyPlan(plan.rewrites) : 0,
  );
}

/// Planning has closed the client; applying needs no network or presenter callback.
class ApplyPlan {
  const ApplyPlan({required this.rewrites, required this.pendingCount,
    required this.projectDir, required this.baseUrl});

  final RewritePlan rewrites;
  final int pendingCount;
  final String projectDir;
  final String baseUrl;
}

class ApplyResult {
  const ApplyResult({required this.plan, required this.filesChanged, required this.write});

  final ApplyPlan plan;
  final int filesChanged;
  final bool write;

  Map<String, Object?> toJson() => sanitizeJson({
    'edits': [for (final e in plan.rewrites.edits)
      {'file': e.file, 'line': e.line, 'old': e.oldSource, 'new': e.newSource}],
    'unmatched': [for (final c in plan.rewrites.unmatched)
      {'key': c.key, 'ctx': c.ctx, 'old': c.oldSource, 'new': c.newSource}],
    'files_changed': filesChanged, 'files_scanned': plan.rewrites.filesScanned,
    'pending_count': plan.pendingCount, 'write': write,
    'project_dir': plan.projectDir, 'base_url': plan.baseUrl,
  }) as Map<String, Object?>;
}
