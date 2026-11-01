/// Whether an ISO-8601 string names its zone (`Z`/`z`, or `±hh[:mm]`).
/// Anchored past the time separator on purpose: a bare `2026-08-27` ends in
/// `-27`, which an offset pattern read against the whole string would take
/// for `-27:00`. Mirrors the server's own check on `pulledAt`
/// (`public_sync_api.dart`) — the ONLY other copy of this predicate, and
/// keeping it that way is the point of this file: every CLI reader of a wire
/// instant goes through [parseZonedInstant].
bool namesItsZone(String raw) {
  final t = raw.lastIndexOf(RegExp(r'[Tt ]'));
  if (t < 0) return false; // a date with no time names no instant either
  return RegExp(r'([zZ]|[+-]\d{2}(:?\d{2})?)$').hasMatch(raw.substring(t + 1));
}

/// The UTC instant [raw] names, or null when it is not a string, does not
/// parse, or names no zone.
///
/// Dropping the zoneless case is the whole point: `DateTime.parse` reads a
/// bare timestamp as the PROCESS's local time, so the instant depends on
/// where the CLI runs — and both values this parses arm the server's
/// base-language guard (#671/#898). The unsafe direction is silent: west of
/// UTC a bare stamp moves FORWARD, so an in-app source edit inside that
/// window stops looking newer than the pull and gets reverted with no row.
/// Returning null degrades to the pre-#898 behavior; guessing does not.
DateTime? parseZonedInstant(Object? raw) =>
    raw is String && namesItsZone(raw) ? DateTime.tryParse(raw)?.toUtc() : null;
