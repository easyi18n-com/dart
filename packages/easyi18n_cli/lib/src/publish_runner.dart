import 'api_client.dart';
import 'push_runner.dart';

enum FillProgress { complete, retrying, timedOut, waiting, pending }

class PublishRunner {
  const PublishRunner();

  static const pollInterval = Duration(seconds: 5);
  static const pollTimeout = Duration(minutes: 10);
  static const maxFillRetries = 2;
  static const _push = PushRunner();

  // The command consumes the final poll for both completeness guards before publish.
  Future<PushResult> waitForFill(
    TranslationsApiClient client,
    String projectId,
    List<TranslateUnit> units,
    List<String> langs, {
    int? maxCreditsMc,
    required void Function(FillProgress, int, int) onProgress,
    required Future<void> Function(Duration) wait,
    required DateTime Function() now,
  }) async {
    final deadline = now().add(pollTimeout);
    var retriesLeft = maxFillRetries;
    var announced = false;
    while (true) {
      final poll = await _push.run(client, projectId, units, langs, dryRun: true);
      final pending = poll.unitsNeedingTranslation;
      if (pending == 0) {
        if (announced) onProgress(FillProgress.complete, pending, 0);
        return poll;
      }
      final timedOut = now().isAfter(deadline);
      // A priced poll means failed work; only a real re-ingestion can move it.
      if (poll.estimatedCredits > 0) {
        if (retriesLeft == 0 || timedOut) return poll;
        retriesLeft--;
        onProgress(FillProgress.retrying, pending, maxFillRetries - retriesLeft);
        await _push.run(
          client,
          projectId,
          units,
          langs,
          dryRun: false,
          maxCreditsMc: maxCreditsMc,
        );
      } else if (timedOut) {
        onProgress(FillProgress.timedOut, pending, 0);
        return poll;
      }
      if (!announced) {
        onProgress(FillProgress.waiting, pending, 0);
        announced = true;
      }
      onProgress(FillProgress.pending, pending, 0);
      await wait(pollInterval);
    }
  }

  Future<PublishOutcome> publish(
    TranslationsApiClient client,
    String projectId, {
    required bool approvedOnly,
    String? incompleteMode,
    String? requiredOutputFormat,
  }) => client.publish(
    projectId: projectId,
    approvedOnly: approvedOnly,
    incompleteMode: incompleteMode,
    requiredOutputFormat: requiredOutputFormat,
  );
}
