/// Credit units at the CLI edge.
///
/// The translate API reports `estimatedCredits` and `balance` in
/// **millicredits (mc)** — `1 credit = 1000 mc` — so the server ledger never
/// drifts on fractional charges. The CLI converts only at this edge:
/// `--max-credits` is read in credits and compared in mc, and every amount is
/// printed in credits. Mirrors the app's display convention
/// (`credit_format.dart` / `credit_units.dart` in the main repo).
library;

/// Millicredits per credit. The single fixed conversion factor.
const int kMillicreditsPerCredit = 1000;

/// Parses a credit amount (decimals allowed: `120`, `0.5`) into millicredits.
/// Returns null for null/empty input; throws [FormatException] on anything
/// that isn't a non-negative number.
int? parseCreditsToMc(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final v = num.tryParse(raw.trim());
  if (v == null || v < 0 || !v.isFinite) {
    throw const FormatException('expected a non-negative number of credits');
  }
  return (v * kMillicreditsPerCredit).round();
}

/// Formats a millicredit amount as credits with up to one decimal:
/// `426 → "0.4"`, `200000 → "200"`, `5000000 → "5,000"`. A tiny non-zero
/// amount that rounds to `0.0` shows `"<0.1"`. Number only — callers add the
/// `credit(s)` suffix.
String formatCredits(int mc) {
  if (mc == 0) return '0';
  final negative = mc < 0;
  // round-half-up to tenths of a credit (100 mc = 0.1 cr).
  final tenths = (mc.abs() / 100).round();
  if (tenths == 0) return negative ? '-<0.1' : '<0.1';
  final whole = tenths ~/ 10;
  final frac = tenths % 10;
  final body = frac == 0 ? _grp(whole) : '${_grp(whole)}.$frac';
  return negative ? '-$body' : body;
}

/// Thousands separator for the integer part.
String _grp(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
