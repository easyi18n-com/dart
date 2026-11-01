import 'cli_output.dart' show sanitizeJson;

/// One completed setup action, replayed before the next action starts.
class InitStep {
  const InitStep(this.verb, this.target, this.detail, {this.scopeSnippet});
  final String verb;
  final String target;
  final String detail;
  final String? scopeSnippet;

  Map<String, Object?> toJson() => sanitizeJson({
    'verb': verb, 'target': target, 'detail': detail,
  }) as Map<String, Object?>;
}

class InitReport {
  InitReport({required this.stack, required this.family, required this.projectDir,
    required this.baseUrl, required this.dryRun, required this.next,
    required Iterable<InitStep> steps}) : steps = List.unmodifiable(steps);
  final String stack;
  final String family;
  final String projectDir;
  final String baseUrl;
  final bool dryRun;
  final String next;
  final List<InitStep> steps;

  Map<String, Object?> toJson() => sanitizeJson({
    'stack': stack, 'family': family, 'project_dir': projectDir,
    'base_url': baseUrl, 'dry_run': dryRun, 'next': next,
    'steps': [for (final step in steps) step.toJson()],
    for (final step in steps)
      if (step.scopeSnippet != null) 'scope_snippet': step.scopeSnippet,
  }) as Map<String, Object?>;
}
