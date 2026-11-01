import 'dart:convert';

import '../cli_output.dart' show sanitizeJson;

/// Spec section 4.4: every tool serializes `structuredContent` under a hard
/// 32 KiB UTF-8 ceiling.
///
/// Capping rows alone bounds nothing — 100 sources of 5000 chars are 500 KB —
/// so the cap is in bytes, and the guarantee is the byte ceiling: the relation
/// to a client's token budget depends on its tokenizer (CJK and emoji weigh
/// more) and is not promised.
const kMcpOutputBudgetBytes = 32 * 1024;

/// Data strings inside LISTS are clipped to this many characters. Never what
/// goes up for translation — this is the reading copy, not the payload.
const kMcpListStringCap = 200;

/// The response cannot fit without changing non-list data such as identifiers.
class OutputBudgetExceeded implements Exception {
  const OutputBudgetExceeded();
}

/// Sanitizes, clips and truncates [payload] until it fits the budget.
///
/// Order matters: sanitize first (a credential must not survive as a clipped
/// prefix), then clip list strings, then drop list items — largest list first
/// — marking `truncated: true` so the caller knows to page with `offset`.
Map<String, Object?> boundOutput(Map<String, Object?> payload) {
  final out = _clip(sanitizeJson(payload), inList: false) as Map<String, Object?>;
  if (_bytes(out) <= kMcpOutputBudgetBytes) return out;
  final error = out['error'];
  final message = error is Map<String, Object?> ? error['message'] : null;
  // Keep the machine-readable error intact while shortening its explanation —
  // and only when there is something to shorten: the marker is a claim about
  // the message, read by a model that cannot check it against the original.
  if (error is Map<String, Object?> &&
      message is String &&
      message.runes.length > kMcpListStringCap) {
    error['message'] =
        '${String.fromCharCodes(message.runes.take(kMcpListStringCap))}…';
    out['truncated'] = true;
    if (_bytes(out) <= kMcpOutputBudgetBytes) return out;
  }
  for (var guard = 0; guard < 64; guard++) {
    final longest = _longestList(out);
    if (longest == null || longest.isEmpty) break;
    // Halve, then settle: a linear walk over a 10k-item list would serialize
    // the payload once per dropped row.
    longest.removeRange(longest.length ~/ 2, longest.length);
    out['truncated'] = true;
    if (_bytes(out) <= kMcpOutputBudgetBytes) return out;
  }
  throw const OutputBudgetExceeded();
}

int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;

Object? _clip(Object? value, {required bool inList}) => switch (value) {
  String() when inList && value.length > kMcpListStringCap =>
    '${value.substring(0, kMcpListStringCap)}…',
  Map<String, Object?>() => {
    for (final e in value.entries) e.key: _clip(e.value, inList: inList),
  },
  List() => [for (final item in value) _clip(item, inList: true)],
  _ => value,
};

/// The list that costs the most bytes, at any depth. Mutable: the caller
/// truncates it in place.
List<Object?>? _longestList(Object? value) {
  List<Object?>? best;
  var bestBytes = 0;
  void walk(Object? node) {
    if (node is List) {
      final size = _bytes(node);
      if (size > bestBytes) {
        best = node;
        bestBytes = size;
      }
      for (final item in node) {
        walk(item);
      }
    } else if (node is Map) {
      for (final item in node.values) {
        walk(item);
      }
    }
  }

  walk(value);
  return best;
}
