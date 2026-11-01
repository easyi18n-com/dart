import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';

/// The write-ahead record of every real ingest request (agent-native section
/// 4.4): `.easyi18n/operations/<operation_id>.json`, or
/// `free/<attempt_id>.json` for an ingest without an operation.
///
/// An intent is on disk, flushed, before its request leaves; the answer is
/// written after. A kill between the two leaves `sent`, and only the server
/// knows whether it acted: `fill_status` asks it, nothing here guesses.
class RequestLog {
  RequestLog._(this._file, this._data);

  /// Runs [body] after every earlier [serialized] body in this process. Two
  /// logs open over the same file rewrite it whole and drop each other's
  /// records (measured: 4 requests, 3 on disk), so every tool that reads the
  /// log and then writes it, `push` and `fill_status`, takes its turn here.
  static Future<T> serialized<T>(Future<T> Function() body) {
    final run = _inFlight.then((_) => body());
    _inFlight = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<void> _inFlight = Future.value();

  /// Every log under [root], parsed. One that does not parse comes back with
  /// [LogFile.data] null: what it held is unknown, so it fails closed.
  static List<LogFile> all(String root) {
    final dir = Directory(_dir(root));
    if (!dir.existsSync()) return const [];
    final found = <LogFile>[];
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      Map<String, Object?>? data;
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        final requests = decoded is Map ? decoded['requests'] : null;
        if (requests is List && requests.every((r) => r is Map)) {
          data = decoded!.cast<String, Object?>();
        }
      } on FormatException {
        // Unreadable: reported by path, never rewritten.
      } on FileSystemException {
        // Same: a log the process cannot open held an unknown intent.
      }
      found.add(LogFile(file, p.relative(file.path, from: root), data));
    }
    return found..sort((a, b) => a.relative.compareTo(b.relative));
  }

  /// D16: the catalog merge policy the local record implies. A file-first
  /// ingest of [catalog] recorded `key_policy: local_owns`, so a key the
  /// catalog no longer has was deleted locally and must not come back.
  static String? recordedKeyPolicy(String root, String? catalog,
      [List<String> catalogs = const []]) {
    for (final log in all(root)) {
      final data = log.data;
      if (data == null || data['catalog'] != catalog ||
          jsonEncode(data['catalogs'] ?? const []) != jsonEncode(catalogs)) {
        continue;
      }
      if (data['key_policy'] == 'local_owns') return 'local_owns';
    }
    return null;
  }

  /// Accepted batches advance; a server-confirmed failure retries its index.
  /// A batch the server never recorded goes again as [requestId]: if the
  /// first send lands late, the same id replays it instead of doubling it.
  static ({String attemptId, int startBatch, String? requestId})? continuation(
    String root, {
    required String? operationId,
    required String? payloadSha256,
    required String target,
    required List<String?> batchHashes,
  }) {
    final candidates = all(root).where((log) =>
        log.operationId == operationId &&
        (operationId != null ||
            (payloadSha256 != null &&
                log.data?['payload_sha256'] == payloadSha256 &&
                log.data?['target'] == target)));
    LogFile? latest;
    for (final log in candidates) {
      if (latest == null ||
          log.file.lastModifiedSync().isAfter(latest.file.lastModifiedSync())) {
        latest = log;
      }
    }
    final records = latest?.requests ?? const <Map<String, Object?>>[];
    if (records.isEmpty) return null;
    final attemptId = records.last['attempt_id'];
    if (attemptId is! String) return null;
    final prefix = records.where((r) => r['attempt_id'] == attemptId).toList();
    var next = 0;
    String? resend;
    for (final record in prefix) {
      if (next >= batchHashes.length ||
          record['batch_index'] != next ||
          batchHashes[next] == null ||
          record['batch_sha256'] != batchHashes[next]) {
        return null;
      }
      final serverState = (record['response'] as Map?)?['server_state'];
      final id = record['request_id'];
      if (record['state'] == 'accepted') {
        next++;
        resend = null;
      } else if (record['state'] == 'refused' && serverState == 'failed') {
        resend = null;
      } else if (record['state'] == 'lost' &&
          serverState == 'unknown' &&
          id is String) {
        resend = id;
      } else {
        return null;
      }
    }
    if (next == batchHashes.length) return null;
    return (
      attemptId: checkedId(attemptId),
      startBatch: next,
      requestId: resend,
    );
  }

  /// The log of [operationId], or of [attemptId] when there is none. Earlier
  /// attempts under the same operation stay in the file.
  factory RequestLog.open(
    String root, {
    required String? operationId,
    required String attemptId,
    required Map<String, Object?> header,
  }) {
    final file = File(p.join(
      _dir(root),
      operationId == null
          ? p.join('free', '${checkedId(attemptId)}.json')
          : '${checkedId(operationId)}.json',
    ));
    final data = file.existsSync()
        ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>()
        : <String, Object?>{'requests': <Object?>[]};
    return RequestLog._(file, {...data, ...header});
  }

  final File _file;
  final Map<String, Object?> _data;

  List<Object?> get _requests => _data['requests'] as List<Object?>;

  void sent({
    required String requestId,
    required String attemptId,
    required int batchIndex,
    required String? batchSha256,
  }) {
    _requests.add({
      'request_id': requestId,
      'attempt_id': attemptId,
      'batch_index': batchIndex,
      'action': 'translate',
      'batch_sha256': batchSha256,
      'sent_at': DateTime.now().toUtc().toIso8601String(),
      'state': 'sent',
    });
    _write();
  }

  /// `accepted` or `refused`, with what the server answered.
  void resolve(String requestId, String state, Map<String, Object?> response) {
    final entry = _requests.cast<Map>().lastWhere(
          (r) => r['request_id'] == requestId,
        );
    entry['state'] = state;
    entry['response'] = response;
    _write();
  }

  /// A rename over a flushed temp file: a kill leaves the old log or the new
  /// one, never half of one.
  void _write() {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp')
      ..writeAsStringSync(jsonEncode(_data), flush: true);
    tmp.renameSync(_file.path);
  }

  /// Every log file still holding an intent in `sent`. A file that does not
  /// parse counts: what it held is unknown, so it fails closed.
  static List<String> unresolved(String root) => [
    for (final log in all(root))
      if (log.data == null || log.sent.isNotEmpty) log.relative,
  ];

  static String _dir(String root) => p.join(root, '.easyi18n', 'operations');
}

/// One log on disk, as [RequestLog.all] found it.
class LogFile {
  LogFile(this.file, this.relative, this.data);

  final File file;
  final String relative;
  final Map<String, Object?>? data;

  /// The operation this log belongs to, from its file name: the name went
  /// through [checkedId] when the log was written, and the `operation_id`
  /// the header echoes from the server never names anything (#1822 M27).
  String? get operationId => p.basename(p.dirname(file.path)) == 'free'
      ? null
      : p.basenameWithoutExtension(file.path);

  List<Map<String, Object?>> get requests => [
    for (final r in data?['requests'] as List? ?? const [])
      (r as Map).cast<String, Object?>(),
  ];

  List<Map<String, Object?>> get sent =>
      [for (final r in requests) if (r['state'] == 'sent') r];

  /// Closes the `sent` intent [requestId] as [state], with what settled it.
  /// The file is re-read first: another writer may have appended since.
  void resolve(String requestId, String state, Map<String, Object?> response) {
    final data =
        (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    final entry = (data['requests'] as List).cast<Map>().lastWhere(
          (r) => r['request_id'] == requestId,
        );
    entry['state'] = state;
    entry['response'] = response;
    RequestLog._(file, data)._write();
  }
}

/// The shape the backend gives operation, attempt and request ids. An id
/// names a file here, so one that is not this shape is refused before it
/// touches the disk: `../x` or `a/b` would leave `.easyi18n/operations/`.
final _idShape = RegExp(r'^(?!__.*__$)[A-Za-z0-9_-]{1,128}$');

String checkedId(String raw) {
  if (!_idShape.hasMatch(raw)) {
    throw CliException(
      '"$raw" is not an operation id. Use the operation_id authorize '
      'returned.',
      code: 'invalid_operation_id',
    );
  }
  return raw;
}
