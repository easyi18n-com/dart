@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// stdout is the JSON-RPC wire. A single stray `print` — or one line of a
/// logger left pointing at stdout — corrupts the channel for the whole
/// session, and no in-memory harness can see it: there, the channel is a
/// StreamChannel and the process streams are untouched. So this one runs the
/// real entrypoint and reads its real stdout.
void main() {
  late Directory dir;
  late String snapshot;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('mcp_stdio');
    snapshot = p.join(dir.path, 'easyi18n.dill');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile', 'kernel', 'bin/easyi18n.dart', '-o', snapshot,
    ], environment: {'CI': 'true', 'DART_SUPPRESS_ANALYTICS': 'true'});
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  test('explicit agent key mode refuses missing keys before opening stdio', () async {
    for (final token in [null, '  ', 'eik_YOUR_AGENT_KEY', 'eip_personal']) {
      final process = await Process.start(Platform.resolvedExecutable,
          [snapshot, 'mcp', '--require-agent-key'], includeParentEnvironment: false,
          environment: {'HOME': dir.path, 'EASYI18N_TOKEN': ?token});
      final out = utf8.decodeStream(process.stdout);
      final err = utf8.decodeStream(process.stderr);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 1);
      expect(await out, isEmpty);
      expect(await err, contains('Set EASYI18N_TOKEN to an AI agent key'));
    }
  });

  test('a bare `mcp` starts with no key, for the login of the keyless snippet', () async {
    final process = await Process.start(Platform.resolvedExecutable, [snapshot, 'mcp'],
        includeParentEnvironment: false, environment: {'HOME': dir.path});
    addTearDown(process.kill);
    process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
      'params': {'protocolVersion': '2025-06-18', 'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'probe', 'version': '1.0.0'}}}));
    final first = await process.stdout.transform(utf8.decoder)
        .transform(const LineSplitter()).first.timeout(const Duration(seconds: 60));
    expect((jsonDecode(first) as Map)['id'], 1);
  });

  test('every stdout line of `easyi18n mcp` is a JSON message', () async {
    // A free push reaches a real server over loopback: the one tool that
    // writes the lockfile and the request log has to keep stdout clean too.
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => backend.close(force: true));
    final pushes = <Map<String, Object?>>[];
    backend.listen((request) async {
      final body = jsonDecode(await utf8.decodeStream(request)) as Map;
      final dryRun = request.uri.queryParameters['dryRun'] == 'true';
      if (!dryRun) pushes.add(body.cast<String, Object?>());
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'dryRun': dryRun,
          'batchSha256': 'c' * 64,
          'trackingToken': dryRun ? null : 'job_1',
          'estimatedCredits': 0,
          'balance': 0,
          'accepted': true,
          'units': [],
        }));
      await request.response.close();
    });

    final project = Directory(p.join(dir.path, 'project'))..createSync();
    // Not the default name: the runner hands the global --config to the
    // server itself, and only a launch that passes it can see that it did.
    File(p.join(project.path, 'custom.yaml')).writeAsStringSync(
        'projectId: proj_abc\nbaseUrl: http://127.0.0.1:${backend.port}\n');
    File(p.join(project.path, 'lib', 'app.dart'))
      ..parent.createSync()
      ..writeAsStringSync("void f(c) => c.tr('Hello');\n");

    final process = await Process.start(
      Platform.resolvedExecutable,
      [snapshot, '--config', 'custom.yaml', 'mcp'],
      workingDirectory: project.path,
      environment: {'EASYI18N_TOKEN': 'eik_test'},
    );
    addTearDown(process.kill);

    final lines = <String>[];
    final done = Completer<void>();
    final allAnswered = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      lines.add(line);
      if (lines.length == 4) allAnswered.complete();
    }, onDone: done.complete);
    final stderrText = process.stderr.transform(utf8.decoder).join();

    void send(Map<String, Object?> message) =>
        process.stdin.writeln(jsonEncode(message));

    send({
      'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'probe', 'version': '1.0.0'},
      },
    });
    send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    send({
      'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
      'params': {'name': 'extract', 'arguments': <String, Object?>{}},
    });
    send({
      'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call',
      'params': {'name': 'push', 'arguments': <String, Object?>{}},
    });
    // The push answers after two HTTP round trips; closing stdin first would
    // end the session before it does.
    await allAnswered.future
        .timeout(const Duration(seconds: 60), onTimeout: () {});
    await process.stdin.close();
    await done.future.timeout(const Duration(seconds: 60));
    await process.exitCode.timeout(const Duration(seconds: 60));

    // Liveness first: an empty stdout satisfies "every line is JSON".
    expect(lines, hasLength(4), reason: 'stdout: $lines\n${await stderrText}');
    final replies = [for (final line in lines) jsonDecode(line) as Map];
    expect(replies.map((r) => r['id']), [1, 2, 3, 4]);
    expect(replies[0]['result']['serverInfo']['name'], 'easyi18n');
    expect(
      [for (final t in replies[1]['result']['tools'] as List) t['name']],
      ['init', 'doctor', 'status', 'authorize', 'fill_status', 'publish',
        'rollback', 'pull', 'add_language',
        'extract', 'push_preview', 'push', 'apply', 'sync_preview', 'sync'],
    );
    expect(replies[2]['result']['structuredContent']['total'], 1);
    final pushed = replies[3]['result']['structuredContent'] as Map;
    expect(pushed['lockfile_written'], isTrue, reason: '$pushed');
    expect(pushes.single['requestId'], isA<String>());
    expect(File(p.join(project.path, 'easyi18n.lock')).existsSync(), isTrue);
  });

  test('killed between the intent and the answer, the next process settles '
      'the request with the server before it pushes again (spec section '
      '13 a)', () async {
    // The real push is held until the process dies: the intent is on disk,
    // the server has acted, and no handler in the killed process ever runs.
    final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => backend.close(force: true));
    final seenPush = Completer<String>();
    var holdPushes = true;
    final heldIds = <String>{};
    final pushes = <Map<String, Object?>>[];
    backend.listen((request) async {
      final path = request.uri.path;
      Future<void> reply(Object body) async {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(body));
        await request.response.close();
      }
      if (path.endsWith('/translate')) {
        final body = jsonDecode(await utf8.decodeStream(request)) as Map;
        final dryRun = request.uri.queryParameters['dryRun'] == 'true';
        if (!dryRun) {
          pushes.add(body.cast<String, Object?>());
          final id = body['requestId'] as String;
          if (holdPushes) {
            heldIds.add(id);
            if (!seenPush.isCompleted) seenPush.complete(id);
            return;
          }
        }
        await reply({
          'dryRun': dryRun,
          'batchSha256': 'c' * 64,
          'trackingToken': dryRun ? null : 'job_1',
          'estimatedCredits': 0,
          'balance': 0,
          'accepted': true,
          'units': [],
        });
        return;
      }
      final id = RegExp(r'/requests/([^/]+)$').firstMatch(path)?.group(1);
      if (id != null) {
        await reply(heldIds.contains(id)
            ? {'requestId': id, 'state': 'done',
                'response': {'trackingToken': 'job_held'}}
            : {'requestId': id, 'state': 'unknown'});
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    final project = Directory(p.join(dir.path, 'killed'))..createSync();
    File(p.join(project.path, 'easyi18n.yaml')).writeAsStringSync(
        'projectId: proj_abc\nbaseUrl: http://127.0.0.1:${backend.port}\n');
    File(p.join(project.path, 'lib', 'app.dart'))
      ..parent.createSync()
      ..writeAsStringSync("void f(c) => c.tr('Hello');\n");
    final logDir = Directory(p.join(project.path, '.easyi18n', 'operations'));
    List<Map<String, Object?>> intents() => [
      for (final f in logDir.listSync(recursive: true).whereType<File>())
        for (final r in (jsonDecode(f.readAsStringSync()) as Map)['requests']
            as List)
          (r as Map).cast<String, Object?>(),
    ];

    final first = await _McpProcess.start(snapshot, project.path);
    first.call(1, 'push');
    final heldId = await seenPush.future.timeout(const Duration(seconds: 60));
    expect(intents().single, containsPair('state', 'sent'),
        reason: 'the intent has to be on disk before the request leaves');
    expect(intents().single['request_id'], heldId);
    first.process.kill(ProcessSignal.sigkill);
    await first.process.exitCode.timeout(const Duration(seconds: 30));
    expect(intents().single['state'], 'sent',
        reason: 'no handler of the killed process may have run');

    holdPushes = false;
    final second = await _McpProcess.start(snapshot, project.path);
    final refused = await second.call(1, 'push');
    expect(refused['isError'], isTrue, reason: '$refused');
    expect(((refused['structuredContent'] as Map)['error'] as Map)['code'],
        'request_unresolved');
    expect(pushes, hasLength(1), reason: 'refused before any request');

    final status = await second.call(2, 'fill_status');
    expect(status['isError'], isNot(true), reason: '$status');
    final content = status['structuredContent'] as Map;
    expect(content['reconciled'], [
      {'request_id': heldId, 'was': 'sent', 'state': 'accepted',
        'server_state': 'done'},
    ]);
    expect(content['unresolved'], isEmpty);
    expect(intents().single['state'], 'accepted');
    expect(pushes, hasLength(1), reason: 'fill_status never ingests');

    final pushed = await second.call(3, 'push');
    expect(pushed['isError'], isNot(true), reason: '$pushed');
    expect(pushes, hasLength(2));
    expect(pushes[1]['requestId'], isNot(heldId));
    await second.close();
  });
}

/// One `easyi18n mcp` process on its real stdio, initialized.
class _McpProcess {
  _McpProcess(this.process);

  final Process process;
  final _replies = <int, Completer<Map<String, Object?>>>{};

  static Future<_McpProcess> start(String snapshot, String cwd) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [snapshot, 'mcp', '--require-agent-key'],
      workingDirectory: cwd,
      environment: {'EASYI18N_TOKEN': 'eik_test'},
    );
    addTearDown(process.kill);
    final session = _McpProcess(process);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final reply = (jsonDecode(line) as Map).cast<String, Object?>();
      session._replies[reply['id'] as int]?.complete(reply);
    });
    process.stderr.transform(utf8.decoder).listen((_) {});
    session._send({
      'jsonrpc': '2.0', 'id': 0, 'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'probe', 'version': '1.0.0'},
      },
    });
    session._replies[0] = Completer();
    await session._replies[0]!.future.timeout(const Duration(seconds: 60));
    session._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    return session;
  }

  void _send(Map<String, Object?> message) =>
      process.stdin.writeln(jsonEncode(message));

  /// The `result` of a tools/call. [id] has to be unique per process.
  Future<Map<String, Object?>> call(int id, String tool) {
    _replies[id] = Completer();
    _send({
      'jsonrpc': '2.0', 'id': id, 'method': 'tools/call',
      'params': {'name': tool, 'arguments': <String, Object?>{}},
    });
    return _replies[id]!
        .future
        .timeout(const Duration(seconds: 60))
        .then((r) => (r['result'] as Map).cast<String, Object?>());
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 60));
  }
}
