import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'iso_zone.dart';

/// Derived local state: what the last `pull` actually wrote to disk. Kept in
/// `.easyi18n/state.json` next to the config - deliberately SEPARATE from
/// `easyi18n.yaml` (the config is user intent, this is derived; add the
/// `.easyi18n/` dir to your VCS ignore). Read by `easyi18n status` (version
/// comparison) and by `pull` itself ([format]/[output]/[files] drive pruning).
class CliState {
  const CliState({
    this.version,
    this.pulledAt,
    this.snapshotAt,
    this.format,
    this.output,
    this.catalog,
    this.catalogs = const [],
    this.files,
    this.digests,
  });

  /// Publish version id of the last pull (`YYYY.MM.DD.N`, or the legacy
  /// `YYYY.MM.DD` form for pre-counter servers).
  final String? version;

  /// When that pull happened (UTC). Null when the file named no zone — see
  /// [load]. This is what `status` DISPLAYS; it is not what `sync` claims.
  final DateTime? pulledAt;

  /// The instant the pulled content is not behind: the server's own stamp for
  /// the published snapshot those files were rendered from (UTC), null when
  /// the server did not report one or an older CLI wrote this file.
  ///
  /// Deliberately NOT [pulledAt] (#898). A pull serves the last PUBLISHED
  /// snapshot, never the live keys, so the two answer different questions:
  /// `pull --version 2026.08.20.1` run today writes 13-day-old content, and
  /// even a plain `pull` writes content as old as the last publish. `sync`
  /// sends THIS as the claim that arms the server's base-language guard;
  /// sending the pull time over-claims by that whole window and reverts a
  /// dashboard correction with no row.
  final DateTime? snapshotAt;

  /// Output format of the last pull. Scopes [files]: after a format switch
  /// the recorded list belongs to the old format and is never pruned against.
  final String? format;

  /// Config-relative output dir of the last pull. Scopes [files] like
  /// [format]: recorded paths are only meaningful under the dir they were
  /// written into, so a changed `output:` must never prune in the new dir.
  final String? output;

  /// Config-relative path of the catalog the last pull wrote, when it went to
  /// the configured `catalog:` instead of the output dir. Deliberately NOT
  /// [output]: that field scopes [files] for pruning, and a catalog write
  /// prunes nothing — recording it there would point a later pull's prune at
  /// the wrong directory.
  final String? catalog;

  /// The config-relative paths of the `catalogs:` the last pull wrote, empty
  /// when it wrote a single [catalog] or a directory.
  final List<String> catalogs;

  /// Output-relative paths the last pull wrote. This is what a later full
  /// pull may safely remove when the server stops serving a path (e.g. a
  /// locale renamed to its platform-canonical filename). Null on state
  /// written by older CLIs — those prune nothing.
  final List<String>? files;

  /// [contentDigest] of what the pull wrote into each entry of [files], by
  /// the same path. Absent for a file the pull merges instead of replacing,
  /// and on state written by older CLIs - which read this file unchanged.
  final Map<String, String>? digests;

  static const String dirName = '.easyi18n';
  static const String fileName = 'state.json';

  /// The state file that belongs to the config at [configPath].
  static File fileFor(String configPath) => File(
    '${File(configPath).parent.path}${Platform.pathSeparator}$dirName${Platform.pathSeparator}$fileName',
  );

  /// Loads the state, tolerating a missing or corrupt file (→ empty state -
  /// it's a cache, never worth failing a command over).
  static CliState load(File file) {
    if (!file.existsSync()) return const CliState();
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return const CliState();
      // Both instants go through `parseZonedInstant`, which DROPS a stamp
      // that declares no zone rather than guessing one — see `iso_zone.dart`
      // for why the guess is silent and unsafe, and the server's mirror of
      // the same refusal in `public_sync_api.dart`. `save` always writes `Z`;
      // this is for a file a hand or a third party wrote.
      final at = raw['pulledAt'];
      final version = raw['version'];
      final format = raw['format'];
      final output = raw['output'];
      final catalog = raw['catalog'];
      final catalogs = raw['catalogs'];
      final files = raw['files'];
      final digests = raw['digests'];
      return CliState(
        version: version is String ? version : null,
        pulledAt: parseZonedInstant(at),
        snapshotAt: parseZonedInstant(raw['snapshotAt']),
        format: format is String ? format : null,
        output: output is String ? output : null,
        catalog: catalog is String ? catalog : null,
        catalogs: catalogs is List ? catalogs.whereType<String>().toList() : const [],
        files: files is List ? files.whereType<String>().toList() : null,
        digests: digests is Map
            ? {
                for (final e in digests.entries)
                  if (e.value case final String digest) '${e.key}': digest,
              }
            : null,
      );
    } on FormatException {
      return const CliState();
    }
  }

  void save(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        if (version != null) 'version': version,
        if (pulledAt != null) 'pulledAt': pulledAt!.toUtc().toIso8601String(),
        if (snapshotAt != null)
          'snapshotAt': snapshotAt!.toUtc().toIso8601String(),
        if (format != null) 'format': format,
        if (output != null) 'output': output,
        if (catalog != null) 'catalog': catalog,
        if (catalogs.isNotEmpty) 'catalogs': catalogs,
        if (files != null) 'files': files,
        if (digests != null) 'digests': digests,
      }),
    );
  }

  /// The recorded files that no longer say what the pull wrote, as paths
  /// relative to [projectDir]. Only [among] is read when given. A file that
  /// is gone has nothing to lose, and one that says [incoming] loses nothing
  /// to a pull that writes it.
  ///
  /// The record vouches for the directory it was written into, so another
  /// [output] finds nothing; the format is not asked, because a file keeps
  /// its digest under any format that keeps its name.
  List<String> changedSincePull(
    String projectDir,
    String output, {
    Iterable<String>? among,
    Map<String, String> incoming = const {},
  }) {
    final recorded = this.output;
    if (recorded == null || p.normalize(recorded) != p.normalize(output)) {
      return const [];
    }
    final changed = <String>[];
    for (final rel in among ?? digests?.keys ?? const <String>[]) {
      final digest = digests?[rel];
      final file = File(p.join(projectDir, output, rel));
      if (digest == null || !file.existsSync()) continue;
      final local = contentDigest(
          utf8.decode(file.readAsBytesSync(), allowMalformed: true));
      if (local == digest) continue;
      final served = incoming[rel];
      if (served != null && contentDigest(served) == local) continue;
      changed.add(p.split(p.normalize(p.join(output, rel))).join('/'));
    }
    return changed..sort();
  }
}

/// What a pulled file says, apart from how it is laid out: a formatter over
/// the locale directory or a CRLF checkout changes the bytes and loses
/// nothing. JSON is digested decoded, with its keys sorted; any other format
/// only has its line ends folded.
///
/// An ARB render stamps `@@last_modified` with the moment of the request, so
/// two renders of one version differ there and nowhere else: the stamp is
/// left out, or no file would ever say what the pull serves.
String contentDigest(String content) {
  if (content.startsWith('\uFEFF')) content = content.substring(1);
  Object? sorted(Object? value) => switch (value) {
    Map() => {
      for (final key in value.keys.map((k) => '$k').toList()..sort())
        key: sorted(value[key]),
    },
    List() => value.map(sorted).toList(),
    _ => value,
  };
  String canonical;
  try {
    final decoded = sorted(jsonDecode(content));
    if (decoded is Map) decoded.remove('@@last_modified');
    canonical = jsonEncode(decoded);
  } on FormatException {
    canonical = content.replaceAll('\r\n', '\n');
  }
  return 'sha256:${sha256.convert(utf8.encode(canonical))}';
}

/// What `doctor` says of a file [contentDigest] no longer matches, after its
/// name: what happens next and where the fix lives.
const String changedSincePullFinding =
    'changed since the `pull` that wrote it - the next pull or sync stops on '
    'it instead of replacing it; make the change in the dashboard and publish '
    'it, or discard it with `easyi18n pull --force`';

/// The refusal of a pull or a sync that would replace [files]: paths relative
/// to the project, named in the message and listed for a caller that reads
/// no text.
CliException editedTargets(List<String> files, {required String untouched}) =>
    CliException(
      '${files.join(', ')}: changed since the pull that wrote '
      '${files.length == 1 ? 'it' : 'them'}, and this would replace '
      '${files.length == 1 ? 'it' : 'them'}. $untouched Make the change in '
      'the dashboard and publish it, then run `easyi18n pull`: a file that '
      'already says what the pull serves is kept. To discard the change, run '
      '`easyi18n pull --force`.',
      code: 'edited_targets',
      details: {
        'edited': [
          for (final file in files) {'file': file},
        ],
      },
    );

/// Parses a publish version id (`YYYY.MM.DD.N`, legacy `YYYY.MM.DD` = `.1`)
/// into a comparable (date, n) pair, or null. Local mini-parser - the CLI is a
/// standalone package and doesn't depend on `easyi18n_core`.
({int date, int n})? parsePublishVersion(String raw) {
  final m = RegExp(
    r'^(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  return (
    date: int.parse(m[1]!) * 10000 + int.parse(m[2]!) * 100 + int.parse(m[3]!),
    n: m[4] == null ? 1 : int.parse(m[4]!),
  );
}

/// Chronological comparison of two version ids; unparseable ids compare as
/// plain strings (deterministic, never throws).
int comparePublishVersions(String a, String b) {
  final pa = parsePublishVersion(a);
  final pb = parsePublishVersion(b);
  if (pa == null || pb == null) return a.compareTo(b);
  final byDate = pa.date.compareTo(pb.date);
  return byDate != 0 ? byDate : pa.n.compareTo(pb.n);
}
