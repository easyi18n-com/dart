/// One accepted source-verify fix the backend recorded: retire the old `tr()`
/// literal the dev still has in their repo and swap in the corrected one. The
/// wire shape of `GET /v1/projects/{id}/pending-code-changes`.
class PendingCodeChange {
  const PendingCodeChange({
    required this.key,
    required this.ctx,
    required this.oldSource,
    required this.newSource,
  });

  final String key;
  final String? ctx;
  final String oldSource;
  final String newSource;

  /// The (source, ctx) identity the rewriter matches call sites against — the
  /// same length-prefixed form the extractor/lockfile use.
  String get identity => '${oldSource.length}:$oldSource:${ctx ?? ''}';
}
