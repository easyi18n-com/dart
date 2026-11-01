import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'extract/source_unit.dart';

/// One registered source in the lockfile - the (source, ctx) identity of a
/// managed key, mirroring [ExtractedUnit] without its source location.
class LockUnit {
  LockUnit({required this.source, this.ctx});

  final String source;
  final String? ctx;

  /// Same injective identity as [ExtractedUnit.identity] so the two diff
  /// against each other directly.
  String get identity => '${source.length}:$source:${ctx ?? ''}';

  Map<String, Object?> toJson() => {
    'source': source,
    if (ctx != null && ctx!.isNotEmpty) 'ctx': ctx,
  };
}

/// What changed between a fresh scan and the committed lockfile.
class LockfileDiff {
  LockfileDiff({required this.added, required this.removed});

  /// Scanned units absent from the lockfile - new strings to register.
  final List<ExtractedUnit> added;

  /// Lockfile units absent from the scan - orphans (the string was removed or
  /// edited in code). Their translations are NOT deleted; this is informational
  /// unless `--prune` drops them from the lockfile.
  final List<LockUnit> removed;

  bool get isEmpty => added.isEmpty && removed.isEmpty;

  /// Unambiguous 1:1 renames (copy-edits): within a `ctx` bucket, exactly one
  /// added and one removed unit → the add carried over from the remove (an edit
  /// keeps the ctx, changes the source). Maps each such added unit's identity to
  /// the previous `(source, ctx)`. Buckets with multiple adds/removes - notably
  /// the common empty-ctx bucket with several edits - are left UNPAIRED: a
  /// mis-pair would link unrelated strings, so pairing is only done when it is
  /// unambiguous.
  Map<String, ({String source, String? ctx})> renamePairs() {
    final addedByCtx = <String, List<ExtractedUnit>>{};
    final removedByCtx = <String, List<LockUnit>>{};
    for (final a in added) {
      (addedByCtx[a.ctx ?? ''] ??= []).add(a);
    }
    for (final r in removed) {
      (removedByCtx[r.ctx ?? ''] ??= []).add(r);
    }
    final out = <String, ({String source, String? ctx})>{};
    for (final entry in addedByCtx.entries) {
      final adds = entry.value;
      final removes = removedByCtx[entry.key] ?? const <LockUnit>[];
      if (adds.length == 1 && removes.length == 1) {
        out[adds.first.identity] = (
          source: removes.first.source,
          ctx: removes.first.ctx,
        );
      }
    }
    return out;
  }
}

/// The `easyi18n.lock` file: the set of `tr()` sources known to the backend
/// after the last `push`/`extract`. Machine-managed (commit it); used to detect
/// new strings to send and orphans removed from code. Identity is the raw
/// (source, ctx) pair - the CLI never tokenizes (the backend does), so the lock
/// stores sources verbatim.
class Lockfile {
  Lockfile({required this.project, required List<LockUnit> units})
    : units = _sorted(units);

  final String project;
  final List<LockUnit> units;

  static const String fileName = 'easyi18n.lock';
  static const int schemaVersion = 1;

  /// Builds a lockfile from a completed scan.
  factory Lockfile.fromExtraction(String project, List<ExtractedUnit> units) =>
      Lockfile(
        project: project,
        units: [for (final u in units) LockUnit(source: u.source, ctx: u.ctx)],
      );

  /// Loads [file], or returns an empty lockfile (for [project]) when it does not
  /// exist yet - the first push starts from nothing. Throws [CliException] on a
  /// malformed file.
  factory Lockfile.loadOrEmpty(File file, {required String project}) {
    if (!file.existsSync()) return Lockfile(project: project, units: const []);

    final dynamic parsed;
    try {
      parsed = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw CliException('Malformed ${file.path}: ${e.message}');
    }
    if (parsed is! Map) {
      throw CliException('${file.path} must be a JSON object.');
    }
    final rawUnits = parsed['units'];
    if (rawUnits is! List) {
      throw CliException("${file.path} is missing a 'units' array.");
    }
    final units = <LockUnit>[];
    for (final raw in rawUnits) {
      if (raw is! Map) continue;
      final source = raw['source'];
      if (source is! String) continue;
      final ctx = raw['ctx'];
      units.add(LockUnit(source: source, ctx: ctx is String ? ctx : null));
    }
    final rawProject = parsed['project'];
    return Lockfile(
      project: rawProject is String ? rawProject : project,
      units: units,
    );
  }

  /// New strings to register and orphans, comparing this lockfile against a scan.
  LockfileDiff diff(List<ExtractedUnit> scanned) {
    final lockIds = {for (final u in units) u.identity: u};
    final scanIds = {for (final u in scanned) u.identity: u};
    return LockfileDiff(
      added: [
        for (final e in scanIds.entries)
          if (!lockIds.containsKey(e.key)) e.value,
      ],
      removed: [
        for (final e in lockIds.entries)
          if (!scanIds.containsKey(e.key)) e.value,
      ],
    );
  }

  /// Serializes to deterministic, pretty JSON (sorted units, trailing newline)
  /// so commits stay reviewable.
  String toJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert({
      'version': schemaVersion,
      'project': project,
      'units': [for (final u in units) u.toJson()],
    })}\n';
  }

  void write(File file) => file.writeAsStringSync(toJsonString());

  static List<LockUnit> _sorted(List<LockUnit> units) =>
      [...units]..sort((a, b) => a.identity.compareTo(b.identity));
}
