import 'exceptions.dart';
import 'logger.dart';

/// One (key, lang) pair whose AI retry budget is spent (#752).
///
/// The engine will never fill it again on its own — only a human action in
/// the dashboard, a source edit or a model change moves the anchor — which is
/// why the server keeps it OUT of `pending`: the poll loops would otherwise
/// wait forever on a pair that is not coming.
class ExhaustedPair {
  const ExhaustedPair(this.key, this.lang);

  final String key;
  final String lang;

  @override
  String toString() => '$key [$lang]';
}

/// The ONE place `push` and `sync` decide what an exhausted pair does to a
/// run: refuse under `--require-complete`, warn otherwise. Both commands call
/// this, so the policy and the wording cannot drift apart again — the drift
/// is how `push --require-complete` spent months exiting 0 on a catalog the
/// server knew was short (#752).
///
/// Only the DECISION lives here. The decode cannot be shared: `/v1/sync`
/// reports `[{key, lang}]` rows at the top level while `/v1/translate`
/// reports `exhausted: [lang]` per unit, and unifying that is a server-side
/// wire change this deliberately is not. The two decoders are pinned against
/// each other by `require_complete_differential_test.dart`.
///
/// Whether a PREVIEW is governed by `--require-complete` is each command's
/// own call, on purpose (#955): `push` refuses the flag without `--publish`
/// (it governs a publish the dry run never reaches), while `sync --dry-run`
/// gates on the same rows the real run refuses on, because there the flag
/// governs the whole run and the preview already carries them.
void reportExhausted(
  CliLogger logger,
  List<ExhaustedPair> pairs, {
  required bool requireComplete,
}) {
  if (pairs.isEmpty) return;
  final joined = pairs.join(', ');
  if (requireComplete) {
    throw CliException(
      'Exhausted pairs need attention in the dashboard (their AI retry '
      'budget is spent): $joined',
    );
  }
  logger.warn(
    'Skipped exhausted pair(s) — retry them from the dashboard: $joined',
  );
}
