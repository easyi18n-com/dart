@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/mcp/deps.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/stored_login.dart';
import 'harness.dart';

// #2584 (duda 13): with the stored login and no ref, the MCP init answers the
// login's workspaces and projects, and `create` makes one, as `easyi18n init`
// does on a terminal (ci-sync §9 steps 2 to 4).
void main() {
  late Directory dir;
  late List<http.Request> requests;
  late List<Map<String, Object?>> workspaces;
  late http.Response Function(http.Request) workspacesReply;
  late http.Response Function(http.Request) createReply;
  late List<String> formats;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mcp_init_login');
    File(p.join(dir.path, 'App.xcodeproj', 'project.pbxproj'))
        .createSync(recursive: true);
    File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
          '{"sourceLanguage":"en","strings":{"Hello":{}},"version":"1.0"}');
    requests = [];
    formats = [];
    workspaces = [
      {'id': 'personal_u1', 'name': 'Personal', 'plan': 'free', 'role': 'owner',
        'projects': [{'id': 'p_app', 'workspace_id': 'personal_u1',
          'slug': 'app', 'name': 'App', 'base_code': 'en', 'role': 'owner'}]},
      {'id': 'w_acme', 'workspace': 'acme', 'name': 'Acme', 'plan': 'pro',
        'role': 'editor', 'projects': []},
    ];
    workspacesReply = (_) => http.Response(jsonEncode({'workspaces': workspaces}), 200);
    // The real route derives the slug from the name when none is sent, and
    // since #2589 a project created with a stack serves its format at birth.
    createReply = (req) {
      final body = jsonDecode(req.body) as Map;
      final wid = req.url.pathSegments[2];
      final handle = workspaces.firstWhere((w) => w['id'] == wid)['workspace'];
      if (body['stack'] == 'xcode') formats = ['xcstrings'];
      return http.Response(jsonEncode({'id': 'p_new', 'workspace_id': wid,
        'workspace': ?handle,
        'slug': body['slug'] ?? (body['name'] as String).toLowerCase()
            .replaceAll(RegExp('[^a-z0-9]+'), '-'),
        'name': body['name'], 'base_code': body['base_code'], 'role': 'owner'}), 201);
    };
  });
  tearDown(() => dir.deleteSync(recursive: true));

  MockClient server() => MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        return switch ((req.method, path)) {
          ('GET', '/v1/me/workspaces') => workspacesReply(req),
          ('POST', _) when path.startsWith('/v1/workspaces/') => createReply(req),
          ('GET', _) when path.endsWith('/meta') => http.Response(jsonEncode({
              'baseCode': 'en', 'currentVersionId': '', 'formats': formats,
              'outputFormatsApiVersion': 1, 'languages': [
                {'code': 'en', 'isBase': true, 'fillMode': 'ai'},
                {'code': 'es', 'isBase': false, 'fillMode': 'ai'},
              ]}), 200),
          ('POST', _) when path.endsWith('/output-formats') => http.Response(
              jsonEncode({'formats': [(jsonDecode(req.body) as Map)['format']],
                'created': true}), 200),
          ('GET', '/v1/credential') => http.Response(jsonEncode({
              'scopes': ['read'], 'requires_operation_approval': true,
              'project': {'id': 'p_key', 'workspace_id': 'w1',
                'workspace': 'acme', 'slug': 'from-key'}}), 200),
          _ => throw StateError('unexpected ${req.method} ${req.url}'),
        };
      });

  Future<CallToolResult> call(Map<String, Object?> arguments,
      {Map<String, String>? environment}) async {
    final mock = server();
    final harness = await McpHarness.start(McpDeps(
      logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
      environment: environment ?? loggedInHome(token: 'eip_${'k' * 40}'),
      currentDirectory: () => dir.path,
      apiClientFactory: ({required baseUrl, required token}) =>
          TranslationsApiClient(baseUrl: baseUrl, token: token, httpClient: mock),
    ));
    addTearDown(harness.shutdown);
    return harness.call('init', arguments);
  }

  File yaml() => File(p.join(dir.path, 'easyi18n.yaml'));
  Map<String, Object?> errorOf(CallToolResult result) {
    expect(result.isError, isTrue, reason: '${result.structuredContent}');
    return (result.structuredContent!['error'] as Map).cast<String, Object?>();
  }
  List<String> sent() => [for (final r in requests) '${r.method} ${r.url.path}'];

  test('with the stored login init lists the workspaces and writes nothing',
      () async {
    final result = await call({'stack': 'auto'});
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    final out = result.structuredContent!;
    expect(out['workspaces'], workspaces);
    expect(out['steps'], isEmpty);
    expect(out['next'], 'ask_human');
    expect(out['stack'], 'xcode');
    expect(sent(), ['GET /v1/me/workspaces']);
    expect(requests.single.headers['authorization'], 'Bearer eip_${'k' * 40}');
    expect(yaml().existsSync(), isFalse);
    final text = (result.content.single as TextContent).text;
    expect(text, contains('2 workspace(s), 1 project(s)'));
    expect(text, contains('create'));
    expect(jsonEncode(out), isNot(contains('eip_')));
  });

  test('create makes the project with the catalog base and writes its ref',
      () async {
    final result = await call({'workspace': 'personal_u1',
      'create': {'name': 'Acc 2584', 'target_languages': ['es']}});
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    expect(sent(), ['GET /v1/me/workspaces',
      'POST /v1/workspaces/personal_u1/projects', 'GET /v1/projects/p_new/meta']);
    expect(jsonDecode(requests[1].body), {'name': 'Acc 2584', 'base_code': 'en',
      'target_languages': ['es'], 'stack': 'xcode'},
        reason: 'no slug: a retry within a minute gets the same project');
    expect(yaml().readAsStringSync(), contains('projectId: p_new\n'));
    final steps = [
      for (final s in result.structuredContent!['steps'] as List)
        '${(s as Map)['verb']} ${s['target']}',
    ];
    expect(steps.take(2), ['created project p_new', 'ok format xcstrings']);
    expect(steps, contains('created ${yaml().path}'));
  });

  test('create in a workspace with a claimed handle writes @handle/slug',
      () async {
    final result = await call({'workspace': '@acme',
      'create': {'name': 'acc-2584', 'base_code': 'fr'}});
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    expect(jsonDecode(requests[1].body),
        {'name': 'acc-2584', 'base_code': 'fr', 'stack': 'xcode'});
    final config = yaml().readAsStringSync();
    expect(config, contains('workspace: acme\n'));
    expect(config, contains('project: acc-2584\n'));
  });

  test('force lets create start over an existing easyi18n.yaml', () async {
    yaml().writeAsStringSync('projectId: p_old\n');
    final result = await call({'workspace': 'personal_u1', 'force': true,
      'create': {'name': 'Fresh'}});
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    expect(yaml().readAsStringSync(), contains('projectId: p_new\n'));
  });

  test('a project slug with create keeps the name create gives', () async {
    final result = await call({'workspace': 'personal_u1', 'project': 'ios',
      'create': {'name': 'iOS App'}});
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    expect(jsonDecode(requests[1].body),
        {'name': 'iOS App', 'slug': 'ios', 'base_code': 'en', 'stack': 'xcode'});
  });

  test('the Free cap answers the 402 and writes nothing', () async {
    createReply = (_) => http.Response(jsonEncode({'error': 'plan_limit',
      'message': 'This plan allows up to 3 projects. Upgrade for more.',
      'details': [{'feature': 'projects'}]}), 402);
    final error = errorOf(await call({'workspace': 'personal_u1',
      'create': {'name': 'Fourth'}}));
    expect(error['code'], 'plan_limit');
    expect(error['message'], contains('This plan allows up to 3 projects.'));
    expect(error['message'], contains('to link one, pass project with app'),
        reason: 'a tool argument, not the terminal flag');
    expect(yaml().existsSync(), isFalse);
  });

  test('a tree that declares no base language asks for create.base_code',
      () async {
    File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
        .writeAsStringSync('{"strings":{"Hello":{}},"version":"1.0"}');
    final error = errorOf(await call({'workspace': 'personal_u1',
      'create': {'name': 'x'}}));
    expect(error['message'],
        'No base language in this project: pass create.base_code.');
    expect(sent(), ['GET /v1/me/workspaces']);
    expect(yaml().existsSync(), isFalse);
  });

  group('create is refused before any request', () {
    Future<void> refused(Map<String, Object?> arguments, String code,
        {Map<String, String>? environment, String? naming}) async {
      final error = errorOf(await call(arguments, environment: environment));
      expect(error['code'], code);
      if (naming != null) expect(error['message'], contains(naming));
      expect(requests, isEmpty);
    }

    test('with an API key in EASYI18N_TOKEN, which cannot create', () async {
      await refused({'workspace': 'personal_u1', 'create': {'name': 'x'}},
          'login_required',
          environment: loggedInHome(also: const {'EASYI18N_TOKEN': 'eik_test'}));
      expect(yaml().existsSync(), isFalse);
    });

    test('over an easyi18n.yaml, unless force', () async {
      yaml().writeAsStringSync('projectId: p_old\n');
      await refused({'workspace': 'personal_u1', 'create': {'name': 'x'}},
          'config_exists');
      expect(yaml().readAsStringSync(), 'projectId: p_old\n');
    });

    test('with dry_run, which writes nothing on the server', () async {
      await refused({'workspace': 'personal_u1', 'dry_run': true,
        'create': {'name': 'x'}}, 'invalid_arguments', naming: 'dry_run');
    });

    test('without the workspace to create it in', () async {
      for (final workspace in [null, '', '  ']) {
        await refused({'workspace': ?workspace, 'create': {'name': 'x'}},
            'invalid_arguments', naming: 'workspace');
      }
    });

    test('with an argument the create object does not declare', () async {
      await refused({'workspace': 'personal_u1',
        'create': {'name': 'x', 'token': 'eik_x'}}, 'invalid_arguments',
          naming: 'token');
    });
  });

  // The store already keys the login by origin (#2583), so the login here is
  // one stored for that origin: only D4 stands between it and the request.
  test('D4 refuses a foreign base_url before the login leaves', () async {
    for (final arguments in [
      {'base_url': 'https://evil.example'},
      {'base_url': 'https://evil.example', 'workspace': 'personal_u1',
        'create': {'name': 'x'}},
    ]) {
      final error = errorOf(await call(arguments,
          environment: loggedInHome(origin: 'https://evil.example')));
      expect(error['code'], 'untrusted_base_url', reason: '$arguments');
      expect(requests, isEmpty, reason: '$arguments');
    }
    expect(yaml().existsSync(), isFalse);
  });

  test('a backend without the account routes still asks for the ref',
      () async {
    workspacesReply = (_) => http.Response('Route not found', 404);
    final error = errorOf(await call({}));
    expect(error['message'], startsWith('Missing project ref'));
    expect(yaml().existsSync(), isFalse);
  });

  for (final (status, code) in [(404, 'not_found'), (400, null)]) {
    test('an account refusal ($status, $code) keeps its HTTP error', () async {
      workspacesReply = (_) => http.Response(jsonEncode({
        'error': ?code,
        'message': 'Account lookup refused',
      }), status);
      final error = errorOf(await call({}));
      expect(error['statusCode'], status);
      expect(error['code'], code ?? 'cli_error');
      expect(error['message'], contains('Account lookup refused'));
      expect(yaml().existsSync(), isFalse);
    });
  }

  // A6: a key in EASYI18N_TOKEN wins over the login, and first contact keeps
  // reading the key's project (#2445).
  test('with a key and the login, init with no ref reads the key project',
      () async {
    final result = await call({},
        environment: loggedInHome(also: const {'EASYI18N_TOKEN': 'eik_test'}));
    expect(result.isError, isNot(true), reason: '${result.structuredContent}');
    expect(sent(), ['GET /v1/credential']);
    expect(yaml().readAsStringSync(), contains('project: from-key\n'));
  });
}
