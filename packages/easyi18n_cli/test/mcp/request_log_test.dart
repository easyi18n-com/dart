@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/mcp/request_log.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('request_log'));
  tearDown(() => root.deleteSync(recursive: true));

  File logFile(String relative) =>
      File(p.join(root.path, '.easyi18n', 'operations', relative));

  Map<String, Object?> read(String relative) =>
      (jsonDecode(logFile(relative).readAsStringSync()) as Map)
          .cast<String, Object?>();

  List<Map> requestsIn(String relative) =>
      (read(relative)['requests'] as List).cast<Map>();

  RequestLog open({String? operationId = 'op_1', String attemptId = 'a_1'}) =>
      RequestLog.open(root.path,
          operationId: operationId,
          attemptId: attemptId,
          header: {'family': 'code-first', 'authorized_mc': 50000});

  void writeRaw(String relative, String content) => logFile(relative)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  group('continuation', () {
    Map<String, Object?> accepted(int index, {String attempt = 'a_1'}) => {
      'request_id': 'r_$index', 'attempt_id': attempt,
      'batch_index': index, 'batch_sha256': 'hash_$index', 'state': 'accepted',
    };
    void seed(List<Map<String, Object?>> records,
        {String file = 'op_1.json', String? payload = 'payload'}) {
      writeRaw(file, jsonEncode({'payload_sha256': payload, 'target': 'backend/project', 'requests': records}));
    }
    ({String attemptId, int startBatch, String? requestId})? resume({
      String? operation = 'op_1', String? payload = 'payload',
      String target = 'backend/project',
      List<String?> hashes = const ['hash_0', 'hash_1', 'hash_2'],
    }) => RequestLog.continuation(root.path, operationId: operation,
        payloadSha256: payload, target: target, batchHashes: hashes);

    test('no previous attempt starts from scratch', () {
      expect(resume(), isNull);
      seed([]);
      expect(resume(), isNull);
    });
    test('accepted prefix resumes with absolute batch index', () {
      seed([accepted(0), accepted(1)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 2, requestId: null));
    });
    Map<String, Object?> failed(int index) => accepted(index)
      ..['state'] = 'refused'
      ..['response'] = {'server_state': 'failed'};
    test('failed last batch retries even when record count fills the manifest', () {
      seed([accepted(0), accepted(1), failed(2)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 2, requestId: null));
    });
    test('repeated failed replacements retain the batch and attempt', () {
      seed([accepted(0), failed(1), failed(1)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 1, requestId: null));
    });
    test('accepted replacement advances once across repeated failures', () {
      seed([accepted(0), failed(1), failed(1), accepted(1)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 2, requestId: null));
    });
    test('completed replacement permits a new attempt', () {
      seed([accepted(0), failed(1), accepted(1), accepted(2)]);
      expect(resume(), isNull);
    });
    test('an accepted batch cannot be replaced', () {
      seed([accepted(0), accepted(0)]);
      expect(resume(), isNull);
    });
    test('records past the manifest are not a continuation', () {
      seed([accepted(0), accepted(1), accepted(2), accepted(3)]);
      expect(() => resume(), returnsNormally);
      expect(resume(), isNull);
    });
    test('failed batch identity must match before retrying', () {
      seed([failed(0)..['batch_sha256'] = 'other']);
      expect(resume(), isNull);
    });
    test('server failed alone does not override a non-refused local state', () {
      seed([failed(0)..['state'] = 'expired']);
      expect(resume(), isNull);
    });
    test('only failed on the server permits a refused replacement', () {
      seed([failed(0)..['response'] = {'server_state': 'done'}]);
      expect(resume(), isNull);
    });
    test('rc2 operation logs need no new header to continue', () {
      writeRaw('op_1.json', jsonEncode({'requests': [accepted(0)]}));
      expect(resume(), (attemptId: 'a_1', startBatch: 1, requestId: null));
    });
    test('a completed attempt allows a new ingest', () {
      seed([accepted(0), accepted(1), accepted(2)]);
      expect(resume(), isNull);
    });
    test('only the newest attempt can continue', () {
      seed([accepted(0), accepted(1), accepted(2), accepted(0, attempt: 'a_2')]);
      expect(resume(), (attemptId: 'a_2', startBatch: 1, requestId: null));
    });
    test('another operation cannot supply the prefix', () {
      seed([accepted(0)], file: 'op_2.json');
      expect(resume(), isNull);
    });
    Map<String, Object?> lost(int index) => accepted(index)
      ..['state'] = 'lost'
      ..['response'] = {'server_state': 'unknown'};
    test('a lost batch goes again under its attempt with its request id', () {
      seed([accepted(0), lost(1)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 1, requestId: 'r_1'));
      seed([lost(0)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 0, requestId: 'r_0'));
    });
    test('a batch lost twice keeps the same request id', () {
      seed([accepted(0), lost(1), lost(1)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 1, requestId: 'r_1'));
    });
    test('an accepted resend ends the reuse of its request id', () {
      seed([accepted(0), lost(1), accepted(1)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 2, requestId: null));
    });
    test('a failed resend of a lost batch takes a new request id', () {
      seed([lost(0), failed(0)]);
      expect(resume(), (attemptId: 'a_1', startBatch: 0, requestId: null));
    });
    test('only unknown on the server permits a lost resend', () {
      seed([lost(0)..['response'] = {'server_state': 'expired'}]);
      expect(resume(), isNull);
    });
    test('server unknown alone does not override a non-lost local state', () {
      seed([lost(0)..['state'] = 'expired']);
      expect(resume(), isNull);
    });
    test('lost batch identity must match before it goes again', () {
      seed([lost(0)..['batch_sha256'] = 'other']);
      expect(resume(), isNull);
    });
    test('a lost record without a request id cannot be continued', () {
      seed([lost(0)..remove('request_id')]);
      expect(resume(), isNull);
    });
    for (final state in ['sent', 'refused', 'lost', 'expired']) {
      test('$state is not an accepted prefix', () {
        seed([accepted(0)..['state'] = state]);
        expect(resume(), isNull);
      });
    }
    test('a gap is not an accepted prefix', () {
      seed([accepted(1)..['batch_sha256'] = 'hash_0']);
      expect(resume(), isNull);
    });
    test('a changed hash cannot skip a batch', () {
      seed([accepted(0)..['batch_sha256'] = 'other']);
      expect(resume(), isNull);
    });
    test('missing hashes do not prove identity', () {
      seed([accepted(0)..['batch_sha256'] = null]);
      expect(resume(hashes: [null, 'hash_1']), isNull);
    });
    test('a malformed attempt id cannot be continued', () {
      seed([accepted(0)..remove('attempt_id')]);
      expect(resume(), isNull);
    });
    test('an unsafe attempt id is refused before it names a free log', () {
      seed([accepted(0, attempt: '../outside')], file: 'free/a_1.json');
      expect(() => resume(operation: null), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'invalid_operation_id')));
    });
    test('free continuation requires the full manifest', () {
      seed([accepted(0)], file: 'free/a_1.json');
      expect(resume(operation: null), (attemptId: 'a_1', startBatch: 1, requestId: null));
      expect(resume(operation: null, payload: 'changed_tail'), isNull);
      expect(resume(operation: null, target: 'backend/other'), isNull);
      expect(resume(operation: null, target: 'staging/project'), isNull);
      seed([accepted(0)], file: 'free/a_1.json', payload: null);
      expect(resume(operation: null, payload: null), isNull);
    });
    test('free continuation chooses the newest matching log', () {
      seed([accepted(0, attempt: 'z')], file: 'free/z.json');
      seed([accepted(0, attempt: 'a'), accepted(1, attempt: 'a')], file: 'free/a.json');
      logFile('free/z.json').setLastModifiedSync(DateTime(2020));
      logFile('free/a.json').setLastModifiedSync(DateTime(2021));
      expect(resume(operation: null), (attemptId: 'a', startBatch: 2, requestId: null));
      logFile('free/z.json').setLastModifiedSync(DateTime(2022));
      expect(resume(operation: null), (attemptId: 'z', startBatch: 1, requestId: null));
    });
  });

  test('an intent is on disk as sent before anything answers it', () {
    open().sent(
        requestId: 'r_1', attemptId: 'a_1', batchIndex: 0, batchSha256: 'x');
    final entry = requestsIn('op_1.json').single;
    expect(entry, containsPair('request_id', 'r_1'));
    expect(entry, containsPair('attempt_id', 'a_1'));
    expect(entry, containsPair('batch_index', 0));
    expect(entry, containsPair('action', 'translate'));
    expect(entry, containsPair('batch_sha256', 'x'));
    expect(entry, containsPair('state', 'sent'));
    expect(DateTime.parse(entry['sent_at'] as String).isUtc, isTrue);
    expect(read('op_1.json'), containsPair('authorized_mc', 50000));
    expect(read('op_1.json'), containsPair('family', 'code-first'));
  });

  test('the answer resolves that intent and keeps what the server said', () {
    final log = open()
      ..sent(requestId: 'r_1', attemptId: 'a_1', batchIndex: 0,
          batchSha256: 'x')
      ..sent(requestId: 'r_2', attemptId: 'a_1', batchIndex: 1,
          batchSha256: 'y');
    log.resolve('r_1', 'accepted', {'tracking_token': 'job_1'});
    final entries = requestsIn('op_1.json');
    expect(entries.map((e) => e['state']), ['accepted', 'sent']);
    expect(entries.first['response'], {'tracking_token': 'job_1'});
    expect(logFile('op_1.json.tmp').existsSync(), isFalse);
  });

  test('an ingest without an operation logs under free/ by attempt', () {
    open(operationId: null, attemptId: 'a_9').sent(
        requestId: 'r_1', attemptId: 'a_9', batchIndex: 0, batchSha256: null);
    expect(requestsIn(p.join('free', 'a_9.json')), hasLength(1));
    expect(logFile('a_9.json').existsSync(), isFalse);
  });

  test('a new attempt under the same operation keeps the earlier ones', () {
    open(attemptId: 'a_1').sent(
        requestId: 'r_1', attemptId: 'a_1', batchIndex: 0, batchSha256: 'x');
    open(attemptId: 'a_2').sent(
        requestId: 'r_2', attemptId: 'a_2', batchIndex: 0, batchSha256: 'x');
    expect(requestsIn('op_1.json').map((e) => e['attempt_id']), ['a_1', 'a_2']);
  });

  for (final id in ['../escape', 'a/b', '', '__x__']) {
    test('id "$id" never names a file', () {
      expect(
        () => open(operationId: id),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'invalid_operation_id')),
      );
      expect(
        () => open(operationId: null, attemptId: id),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'invalid_operation_id')),
      );
    });
  }

  group('a log file read back', () {
    test('resolving re-reads the file, so a record another writer appended '
        'since survives', () {
      open().sent(
          requestId: 'r_1', attemptId: 'a_1', batchIndex: 0, batchSha256: 'x');
      final log = RequestLog.all(root.path).single;
      // Another process appends between this read and the write below.
      open(attemptId: 'a_2').sent(
          requestId: 'r_2', attemptId: 'a_2', batchIndex: 0, batchSha256: 'y');
      log.resolve('r_1', 'accepted', {'tracking_token': 'job_1'});
      expect(requestsIn('op_1.json').map((e) => e['request_id']),
          ['r_1', 'r_2']);
      expect(requestsIn('op_1.json').map((e) => e['state']),
          ['accepted', 'sent']);
    });

    test('names its operation by the file, never the header', () {
      writeRaw('op_1.json',
          '{"operation_id": "../x", "requests": [{"state": "sent"}]}');
      writeRaw(p.join('free', 'a_1.json'),
          '{"operation_id": "op_9", "requests": []}');
      final logs = RequestLog.all(root.path);
      expect(logs.map((l) => l.operationId), [null, 'op_1']);
      expect(logs.map((l) => l.sent.length), [0, 1]);
    });

    test('one that does not parse has no data and stays on the list', () {
      writeRaw('op_1.json', '{"requests": ["sent"]}');
      writeRaw('op_2.json', '{"requests": [');
      expect(RequestLog.all(root.path).map((l) => l.data), [null, null]);
    });
  });

  group('unresolved', () {
    test('none without a log directory', () {
      expect(RequestLog.unresolved(root.path), isEmpty);
    });

    test('lists every log holding a sent intent, and only those', () {
      open(attemptId: 'a_1')
        ..sent(requestId: 'r_1', attemptId: 'a_1', batchIndex: 0,
            batchSha256: 'x')
        ..resolve('r_1', 'accepted', const {});
      expect(RequestLog.unresolved(root.path), isEmpty);
      open(operationId: null, attemptId: 'a_2').sent(
          requestId: 'r_2', attemptId: 'a_2', batchIndex: 0, batchSha256: 'x');
      expect(RequestLog.unresolved(root.path),
          [p.join('.easyi18n', 'operations', 'free', 'a_2.json')]);
    });

    test('a refused intent is resolved', () {
      open()
        ..sent(requestId: 'r_1', attemptId: 'a_1', batchIndex: 0,
            batchSha256: 'x')
        ..resolve('r_1', 'refused', {'status_code': 409});
      expect(RequestLog.unresolved(root.path), isEmpty);
    });

    test('a log it cannot read fails closed', () {
      writeRaw('op_1.json', '{"requests": [');
      expect(RequestLog.unresolved(root.path), hasLength(1));
    });

    test('an entry that is not a record fails closed', () {
      writeRaw('op_1.json', '{"requests": ["sent"]}');
      expect(RequestLog.unresolved(root.path), hasLength(1));
    });

    test('a log the process cannot open fails closed, like one that does '
        'not parse', () {
      writeRaw('op_1.json', '{"requests": []}');
      final file = logFile('op_1.json');
      Process.runSync('chmod', ['000', file.path]);
      addTearDown(() => Process.runSync('chmod', ['644', file.path]));
      expect(RequestLog.unresolved(root.path), hasLength(1));
    });

    for (final raw in ['[]', '{"requests": {}}', '{"requests": "sent"}']) {
      test('a log that parses to the wrong shape ($raw) fails closed', () {
        writeRaw('op_1.json', raw);
        expect(RequestLog.unresolved(root.path), hasLength(1));
      });
    }

    test('a leftover temp file from a killed write is not a log', () {
      writeRaw('op_1.json.tmp', '{"requests": [');
      expect(RequestLog.unresolved(root.path), isEmpty);
    });
  });

  group('recordedKeyPolicy', () {
    void record(Map<String, Object?> header) => writeRaw('op_1.json', jsonEncode({
      'family': 'file-first', 'key_policy': 'local_owns', ...header,
      'requests': <Object?>[],
    }));

    test('matches a record by the catalogs list, not by one name (#590)', () {
      record({'catalog': null, 'catalogs': ['A.xcstrings', 'B.xcstrings']});
      expect(RequestLog.recordedKeyPolicy(root.path, null, ['A.xcstrings', 'B.xcstrings']),
          'local_owns');
      expect(RequestLog.recordedKeyPolicy(root.path, null, ['A.xcstrings']), isNull);
      expect(RequestLog.recordedKeyPolicy(root.path, null, ['B.xcstrings', 'A.xcstrings']),
          isNull, reason: 'order is part of the declaration');
      expect(RequestLog.recordedKeyPolicy(root.path, null), isNull,
          reason: 'a project without catalogs does not inherit it');
    });

    test('a single-catalog record does not match a catalogs project', () {
      record({'catalog': 'A.xcstrings'});
      expect(RequestLog.recordedKeyPolicy(root.path, 'A.xcstrings'), 'local_owns');
      expect(RequestLog.recordedKeyPolicy(root.path, null, ['A.xcstrings']), isNull);
    });
  });
}
