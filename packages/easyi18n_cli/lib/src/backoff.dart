import 'dart:math';

/// Exponential backoff with jitter, shared by every retry the CLI performs so
/// the policy cannot drift between the client and the commands.
///
/// **Equal jitter**, not full jitter: the delay is half the window plus a
/// random point inside the other half. Full jitter can return ~zero, and the
/// failure this exists for is a *quota-wide* write throttle — every CI job
/// hitting the same database is backing off at the same moment, so a retry
/// that may not wait at all is the one thing the guidance in Firestore's own
/// error message rules out.
///
/// [attempt] is 1-based: the delay before the first retry.
Duration backoffDelay(
  int attempt, {
  required Random random,
  Duration base = const Duration(seconds: 1),
  Duration cap = const Duration(seconds: 30),
}) {
  final window = min(
    cap.inMilliseconds,
    base.inMilliseconds * (1 << (attempt - 1).clamp(0, 16)),
  );
  final half = window ~/ 2;
  return Duration(milliseconds: half + random.nextInt(half + 1));
}

/// Attempts (1 initial + retries) for a request the CLI may replay.
const int kMaxApiAttempts = 3;
