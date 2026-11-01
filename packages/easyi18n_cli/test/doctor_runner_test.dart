import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _Client extends MockClient {
  _Client(super.handler);
  bool closed = false;
  @override
  void close() { closed = true; super.close(); }
}

class _Logger extends CliLogger {
  _Logger() : super(out: StringBuffer(), err: StringBuffer());
  final warnings = <String>[];
  final details = <String>[];
  @override
  void warn(String message) { warnings.add(message); super.warn(message); }
  @override
  void detail(String message) { details.add(message); super.detail(message); }
}

class _CloseFailure extends _Client {
  _CloseFailure(super.handler);
  @override
  void close() { super.close(); throw StateError('close failed'); }
}

class _WarnFailure extends _Logger {
  @override
  void warn(String message) { throw StateError('warn failed'); }
}

void main() {
  late Directory dir;
  late String config;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('doctor_runner');
    config = '${dir.path}/easyi18n.yaml';
    File(config).writeAsStringSync('''
workspace: acme
project: app
mode: a
baseUrl: https://untrusted.example
''');
    Directory('${dir.path}/lib').createSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  for (final failure in ['close', 'warn']) {
    test('propagates $failure override failure', () async {
      final logger = failure == 'warn' ? _WarnFailure() : _Logger();
      final client = _CloseFailure((request) async => http.Response('{}', 200));
      await expectLater(DoctorRunner().run(configPath: config, logger: logger,
        environment: {'EASYI18N_TOKEN': 'env'},
        apiClientFactory: ({required baseUrl, required token}) =>
          TranslationsApiClient(baseUrl: baseUrl, token: token, httpClient: client),
      ), throwsA(isA<StateError>()
          .having((e) => e.message, 'message', '$failure failed')));
    });
  }

  for (final failure in ['none', 'resolve', 'coverage']) {
    test('preserves diagnostics and closes client on $failure', () async {
      final logger = _Logger();
      final replayed = <DoctorFinding>[];
      final client = _Client((request) async {
        expect(logger.warnings, hasLength(1));
        expect(replayed.last.check, 'delivery');
        if (request.url.path.endsWith('/resolve')) {
          if (failure == 'resolve') throw const SocketException('resolve down');
          return http.Response('{"projectId":"resolved-id","workspaceId":"workspace-id"}', 200);
        }
        expect(request.url.path, contains('/resolved-id/'));
        if (failure == 'coverage') throw const SocketException('coverage down');
        return http.Response(jsonEncode({
          'version': 'v1', 'format': 'arb', 'files': {},
          'coverageBasis': 'skip', 'coverage': {},
        }), 200);
      });
      final report = await DoctorRunner().run(
        configPath: config, logger: logger, onFinding: replayed.add,
        environment: {'EASYI18N_TOKEN': 'env'},
        apiClientFactory: ({required baseUrl, required token}) {
          expect(logger.warnings, hasLength(1));
          expect(token, 'env');
          return TranslationsApiClient(baseUrl: baseUrl, token: token,
              httpClient: client, wait: (_) async {});
        },
      );
      expect(client.closed, isTrue);
      expect(report.findings, orderedEquals(replayed));
      expect(report.unchecked, failure == 'none' ? 0 : 1);
      expect(logger.details, failure == 'resolve' ? isEmpty
          : ['Resolved @acme/app -> resolved-id']);
      expect(() => report.findings.clear(), throwsUnsupportedError);
    });
  }

  test('runner retains all details and sanitizes only the serialized view', () async {
    const secret = 'eik_abcdefghijklmnopqrstuv';
    File('${dir.path}/lib/main.dart').writeAsStringSync([
      for (var i = 0; i < 12; i++)
        "void f$i(dynamic context) { context.tr('broken $i { $secret'); }",
    ].join('\n'));
    final logger = _Logger();
    final runner = DoctorRunner();
    final report = await runner.run(configPath: config, logger: logger,
        environment: {});
    final icu = report.findings.singleWhere((f) => f.check == 'icu');
    expect(icu.details, hasLength(12));
    expect(icu.details.last, contains('lib/main.dart:12'));
    expect(icu.details.first, contains(secret));
    expect(jsonEncode(report.toJson()), isNot(contains(secret)));
    expect(jsonEncode(report.toJson()), contains('[REDACTED]'));
    expect(() => icu.details.clear(), throwsUnsupportedError);
    expect(logger.out.toString(), isEmpty);
    expect(report.failures, 1);
    expect(report.verdict, 'failed');
    File('${dir.path}/lib/main.dart').writeAsStringSync('');
    final next = await runner.run(configPath: config, logger: logger,
        environment: {});
    expect(next.failures, 0);
    expect(report.failures, 1);
  });

  test('only an agent session asks which kind the key is (#1633)', () async {
    // A CI key is the other valid kind, and the CLI doctor sends the token
    // nowhere on a Mode B project.
    File(config).writeAsStringSync(
        'projectId: p1\nbaseUrl: https://untrusted.example\n');
    final asked = <String>[];
    var logger = _Logger();
    final client = _Client((request) async {
      expect(logger.warnings, hasLength(1),
          reason: 'the untrusted target is named before the token leaves');
      asked.add(request.url.path);
      return http.Response(
          '{"scopes":["read"],"requires_operation_approval":false}', 200);
    });
    TranslationsApiClient factory({required String baseUrl,
        required String token}) => TranslationsApiClient(baseUrl: baseUrl,
        token: token, httpClient: client);
    final human = await DoctorRunner().run(configPath: config,
        logger: logger, environment: {'EASYI18N_TOKEN': 'env'},
        apiClientFactory: factory);
    expect(asked, isEmpty);
    expect(logger.warnings, isEmpty);
    expect(human.findings.where((f) => f.check == 'agent_key'), isEmpty);
    logger = _Logger();
    final agent = await DoctorRunner().run(configPath: config,
        logger: logger, environment: {'EASYI18N_TOKEN': 'env'},
        apiClientFactory: factory, agentSession: true);
    expect(asked, ['/v1/projects/p1/credential']);
    expect(client.closed, isTrue);
    expect(agent.findings.singleWhere((f) => f.check == 'agent_key').level,
        'warn');
  });

  test('a web doctor names an untrusted target before it asks for the '
      'languages, and closes that client', () async {
    // Mode B and no agent session, so this read is the only one that puts
    // the key on the wire.
    File(config).writeAsStringSync('projectId: p1\nmode: b\n'
        'baseUrl: https://untrusted.example\nformat: json\n'
        'output: public/i18n\nsource: public/i18n/en.json\n');
    File('${dir.path}/package.json')
        .writeAsStringSync('{"dependencies": {"i18next": "^26.0.0"}}');
    File('${dir.path}/public/i18n/en.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    final logger = _Logger();
    final asked = <String>[];
    int? warnedBefore;
    final client = _Client((request) async {
      warnedBefore ??= logger.warnings.length;
      asked.add(request.url.path);
      return http.Response(jsonEncode({
        'baseCode': 'en',
        'languages': [{'code': 'en', 'isBase': true}],
      }), 200);
    });
    final report = await DoctorRunner().run(configPath: config, logger: logger,
        environment: {'EASYI18N_TOKEN': 'env'},
        apiClientFactory: ({required baseUrl, required token}) =>
            TranslationsApiClient(
                baseUrl: baseUrl, token: token, httpClient: client));
    expect(report.stack, 'web');
    expect(asked, ['/v1/projects/p1/meta']);
    expect(warnedBefore, 1,
        reason: 'the untrusted target is named before the token leaves');
    expect(client.closed, isTrue);
    expect(report.findings.singleWhere((f) => f.check == 'languages').level,
        'ok');
  });

  group('the output format in an agent session (#2133)', () {
    // `pull` enables the format of a project that has none, which takes the
    // `write` scope the setup prompt's Agent key does not carry.
    const agentScopes = ['read', 'translate', 'publish'];
    late List<String> asked;

    late _Logger logger;
    // Warnings on record when `/meta` was asked.
    late int warnedBeforeMeta;

    Future<DoctorReport> doctor({
      Object? formats = const <String>[],
      List<String> scopes = agentScopes,
      String yaml = 'projectId: p1\nmode: a\nformat: nested_json\n',
      bool agentSession = true,
      int metaStatus = 200,
    }) {
      File(config).writeAsStringSync(yaml);
      asked = [];
      logger = _Logger();
      final client = _Client((request) async {
        final path = request.url.path;
        asked.add(path);
        if (path.endsWith('/meta')) warnedBeforeMeta = logger.warnings.length;
        if (path.endsWith('/credential')) {
          return http.Response(jsonEncode(
              {'scopes': scopes, 'requires_operation_approval': true}), 200);
        }
        if (path.endsWith('/meta')) {
          return http.Response(jsonEncode({
            'baseCode': 'en',
            'formats': ?formats,
            if (formats != null) 'outputFormatsApiVersion': 1,
          }), metaStatus);
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      return DoctorRunner().run(configPath: config, logger: logger,
          environment: {'EASYI18N_TOKEN': 'env'}, agentSession: agentSession,
          apiClientFactory: ({required baseUrl, required token}) =>
              TranslationsApiClient(
                  baseUrl: baseUrl, token: token, httpClient: client));
    }

    List<DoctorFinding> gradings(DoctorReport report) =>
        [...report.findings.where((f) => f.check == 'output_format')];
    DoctorFinding graded(DoctorReport report) {
      expect(gradings(report), hasLength(1),
          reason: 'doctor grades the output format once');
      return gradings(report).single;
    }

    test('no format and a key that cannot enable one fails before any spend, '
        'naming the format and both remedies', () async {
      final finding = graded(await doctor());
      expect(finding.level, 'fail');
      expect(finding.message,
          contains('cannot enable one (scopes: read, translate, publish)'));
      expect(finding.details, [
        'A human enables "nested_json" under Project > Settings > Output in '
            'the dashboard.',
        'Or a human runs `easyi18n formats add nested_json` with a key that '
            'has the write scope.',
      ]);
    });

    test('no format and a key with write is ok: pull enables it', () async {
      final finding = graded(await doctor(scopes: [...agentScopes, 'write']));
      expect(finding.level, 'ok');
      expect(finding.message, contains('pull enables "nested_json"'));
    });

    test('an enabled format is ok and costs no second credential read',
        () async {
      final finding = graded(await doctor(formats: ['json', 'nested_json']));
      expect(finding.level, 'ok');
      expect(asked.where((path) => path.endsWith('/credential')), hasLength(1),
          reason: 'only agent_key reads the credential');
    });

    test('another format enabled fails for a key with write too: pull '
        'refuses instead of adding a second format', () async {
      final finding = graded(await doctor(
          formats: ['json'], scopes: [...agentScopes, 'write']));
      expect(finding.level, 'fail');
      expect(finding.message, contains('enabled: json'));
      expect(finding.details, hasLength(3));
      expect(finding.details.first, startsWith('Set `format:` in easyi18n.yaml'));
      expect(finding.details.last,
          contains('`easyi18n formats add nested_json`'));
    });

    test('a server that does not report its formats is unverified, never a '
        'pass', () async {
      expect(graded(await doctor(formats: null)).level, 'unverified');
      final refused = graded(await doctor(metaStatus: 503));
      expect(refused.level, 'unverified');
      expect(refused.message, 'the API answered 503');
    });

    test('an untrusted target is named before this read sends the key',
        () async {
      await doctor(yaml: 'projectId: p1\nformat: xcstrings\n'
          'baseUrl: https://untrusted.example\n');
      expect(warnedBeforeMeta, 2,
          reason: 'one from agent_key, one from this read');
    });

    test('a Flutter Mode B project never pulls, so nothing is graded or '
        'asked', () async {
      final report = await doctor(yaml: 'projectId: p1\n');
      expect(gradings(report), isEmpty);
      expect(asked, ['/v1/projects/p1/credential']);
    });

    test('a file-first project is graded whatever its mode', () async {
      File('${dir.path}/Localizable.xcstrings').writeAsStringSync(
          '{"sourceLanguage":"en","version":"1.0","strings":{}}');
      final report = await doctor(yaml: 'projectId: p1\nformat: xcstrings\n'
          'catalog: Localizable.xcstrings\n');
      expect(report.family, 'file-first');
      expect(graded(report).level, 'fail');
    });

    test('the CLI doctor asks nothing new outside an agent session',
        () async {
      final report = await doctor(agentSession: false);
      expect(gradings(report), isEmpty);
      expect(asked.where((path) =>
          path.endsWith('/meta') || path.endsWith('/credential')), isEmpty);
    });
  });
}
