import 'dart:convert';
import 'dart:io';

import 'contract.dart';
import 'extract/tr_extractor.dart';

class MalformedEmailBundleException implements Exception {
  const MalformedEmailBundleException(this.path, this.reason);

  final String path;
  final String reason;
}

/// Result of the email i18n bundle-coverage gate
/// (docs/specs/transactional-emails-i18n-brief.md).
class EmailGateResult {
  const EmailGateResult.dormant()
      : dormant = true,
        totalStrings = 0,
        missing = const [];
  const EmailGateResult.active({required this.totalStrings, required this.missing})
      : dormant = false;

  /// True when email i18n is not activated yet (no baked bundles) — the gate
  /// passes and callers should not block.
  final bool dormant;

  /// Number of static email `tr()` strings extracted from the source.
  final int totalStrings;

  /// Email `tr()` sources (as one-line snippets, ctx-tagged) whose token is in
  /// no baked bundle — they would be delivered in English. Empty ⇒ full cover.
  final List<String> missing;

  bool get passed => dormant || missing.isEmpty;
}

/// Checks that every static email `tr()` source in [sourceDir] is covered by a
/// baked bundle in [bundlesDir]. Self-activating: no `*.json` bundles ⇒
/// [EmailGateResult.dormant] (English-only is the accepted pre-flip state).
///
/// Uses the registrar's [TrExtractor] and the runtime [messageTokenForText] so
/// it can't drift from what actually gets registered/resolved.
EmailGateResult checkEmailBundleCoverage({
  required Directory sourceDir,
  required Directory bundlesDir,
}) {
  // Sorted: `listSync` order is the filesystem's, and the first malformed
  // bundle is the one the error names.
  final bundleFiles = bundlesDir.existsSync()
      ? (bundlesDir.listSync().whereType<File>().toList()
        ..removeWhere((f) => !f.path.endsWith('.json'))
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];
  if (bundleFiles.isEmpty) return const EmailGateResult.dormant();

  final bakedTokens = <String>{};
  for (final f in bundleFiles) {
    final bytes = f.readAsBytesSync();
    late final String contents;
    try {
      contents = utf8.decode(bytes);
    } on FormatException {
      throw MalformedEmailBundleException(f.path, 'invalid UTF-8 encoding');
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException {
      throw MalformedEmailBundleException(f.path, 'invalid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw MalformedEmailBundleException(
          f.path, 'the JSON root must be an object');
    }

    final tokenIndex = decoded['tokenIndex'];
    if (tokenIndex != null && tokenIndex is! Map) {
      throw MalformedEmailBundleException(
          f.path, 'tokenIndex must be an object');
    }
    if (tokenIndex is Map) {
      bakedTokens.addAll(tokenIndex.keys.whereType<String>());
    }
  }

  final extraction =
      TrExtractor().extractFromDirectory(sourceDir, relativeTo: sourceDir.path);
  final missing = <String>[];
  for (final unit in extraction.units) {
    final token = messageTokenForText(unit.source, ctx: unit.ctx);
    if (!bakedTokens.contains(token)) {
      final ctxTag = unit.ctx == null ? '' : '[${unit.ctx}] ';
      missing.add('$ctxTag"${_short(unit.source)}"');
    }
  }
  return EmailGateResult.active(
      totalStrings: extraction.units.length, missing: missing);
}

String _short(String s) {
  final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length > 64 ? '${oneLine.substring(0, 61)}...' : oneLine;
}
