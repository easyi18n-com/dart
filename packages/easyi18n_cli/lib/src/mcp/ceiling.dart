import 'dart:math';

import '../credits.dart';
import '../exceptions.dart';

/// D7: the most one `authorize` may ask for, in credits, unless the client's
/// env says otherwise. It is the client's brake; what an approved operation
/// can charge is capped by the backend (agent-native D14).
const kDefaultMcpMaxCredits = 50;

/// `EASYI18N_MCP_MAX_CREDITS`, where `0` disables real ingests. A value that
/// does not read as a whole number fails closed: falling back to the default
/// would raise the ceiling of someone who meant to lower it.
int mcpCeiling(Map<String, String> environment) {
  final raw = environment['EASYI18N_MCP_MAX_CREDITS']?.trim();
  if (raw == null || raw.isEmpty) return kDefaultMcpMaxCredits;
  final value = int.tryParse(raw);
  if (value == null || value < 0) {
    throw CliException(
      'EASYI18N_MCP_MAX_CREDITS must be a whole number of credits (0 disables '
      'real ingests); got "$raw". Fix it in this MCP server\'s env.',
      code: 'invalid_ceiling',
    );
  }
  return value;
}

/// `M = min(ceil(C × 1.2), cap)` in credits, for an estimate in
/// millicredits. The margin covers the gap between the estimate and the
/// provider's real token count; the backend never charges above `M`.
int authorizedCredits(int estimateMc, int cap) {
  const denominator = 5 * kMillicreditsPerCredit;
  return min((estimateMc * 6 + denominator - 1) ~/ denominator, cap);
}
