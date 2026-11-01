import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'extract/source_unit.dart';
import 'extract/tr_extractor.dart';
import 'lockfile.dart';
import 'logger.dart';

/// Read-only, offline extraction and comparison against the project lockfile.
class ExtractRunner {
  ExtractRunner({TrExtractor? extractor})
    : _extractor = extractor ?? TrExtractor();

  final TrExtractor _extractor;

  ExtractResult run({
    String configPath = Easyi18nConfig.fileName,
    String sourceDir = 'lib',
    CliLogger? logger,
  }) {
    final config = Easyi18nConfig.load(File(configPath), logger: logger);
    final root = p.normalize(p.absolute(p.dirname(configPath)));
    final extraction = _extractor.extractFromDirectory(
      Directory(p.join(root, sourceDir)),
      relativeTo: root,
    );
    final lock = Lockfile.loadOrEmpty(
      File(p.join(root, Lockfile.fileName)),
      // Inert seed: extract only diffs the lockfile, never writes it.
      project: config.ref.lockSeed,
    );
    return ExtractResult(
      extraction: extraction,
      diff: lock.diff(extraction.units),
      projectDir: root,
      baseUrl: config.baseUrl,
    );
  }
}

/// Full extraction for text presenters, with bounded lists for JSON consumers.
class ExtractResult {
  ExtractResult({
    required this.extraction,
    required this.diff,
    required this.projectDir,
    required this.baseUrl,
  });

  final ExtractionResult extraction;
  final LockfileDiff diff;
  final String projectDir;
  final String baseUrl;

  int get total => extraction.units.length;
  int get added => diff.added.length;
  int get orphans => diff.removed.length;

  /// [offset] pages the two lists: an index into the extraction's own order,
  /// which is stable for a given tree, so a caller that hit the MCP output
  /// budget can ask for the rest (spec section 4.4).
  ///
  /// The index itself is NOT echoed here. `extract --json` has its own pinned
  /// contract (#1517) and does not page, so the key would be a constant zero
  /// in every CLI transcript; the MCP tool, which is the surface that pages,
  /// adds it to what it returns.
  Map<String, Object?> toJson({int limit = 100, int offset = 0}) {
    RangeError.checkNotNegative(limit, 'limit');
    RangeError.checkNotNegative(offset, 'offset');
    return {
      'files_scanned': extraction.filesScanned,
      'total': total,
      'added': added,
      'orphans': orphans,
      'dynamics_count': extraction.dynamics.length,
      'dynamics': [
        for (final d in extraction.dynamics.skip(offset).take(limit))
          {'file': d.file, 'line': d.line, 'snippet': d.snippet},
      ],
      'dynamics_truncated': extraction.dynamics.length > offset + limit,
      'units': [
        for (final u in extraction.units.skip(offset).take(limit))
          {'source': u.source, 'ctx': u.ctx, 'file': u.file, 'line': u.line},
      ],
      'truncated': total > offset + limit,
      'project_dir': projectDir,
      'base_url': baseUrl,
    };
  }
}
