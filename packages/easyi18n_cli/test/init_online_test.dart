@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapter.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/init_online.dart';
import 'package:easyi18n_cli/src/init_report.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/login_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/transcript.dart';

// #2584: with a stored login and no ref, `easyi18n init` sets the project up
// on the server (ci-sync §9) before it writes easyi18n.yaml.
void main() {
  const origin = 'http://localhost:8080';
  final raw = 'eip_${'k' * 40}';
  final ciKey = 'eik_${'c' * 40}';
  late Directory tmp, home;
  late String root;
  late Transcript transcript;
  late List<http.Request> requests;
  late List<Map<String, Object?>> workspaces;
  late http.Response Function(http.Request) create;
  late List<String> formats, languages, prompts;
  late List<String?> answers;
  late String minted;
  late CliOutput output;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('init_online');
    home = Directory.systemTemp.createTempSync('init_online_home');
    root = p.join(tmp.path, 'acc-x');
    File(p.join(root, 'App.xcodeproj', 'project.pbxproj')).createSync(recursive: true);
    File(p.join(root, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"sourceLanguage":"en","strings":{"Hello":{}},"version":"1.0"}');
    transcript = Transcript();
    requests = [];
    answers = [];
    prompts = [];
    formats = [];
    languages = ['en'];
    minted = ciKey;
    workspaces = [
      {'id': 'personal_u1', 'name': 'Personal', 'plan': 'free', 'role': 'owner',
        'projects': [{'id': 'p_app', 'workspace_id': 'personal_u1', 'slug': 'app',
          'name': 'App', 'base_code': 'en', 'role': 'owner'}]},
    ];
    create = (req) {
      final body = jsonDecode(req.body) as Map;
      return http.Response(jsonEncode({'id': 'p_new', 'workspace_id': 'personal_u1',
        'slug': body['slug'] ?? 'acc-x', 'name': body['name'], 'base_code': body['base_code'],
        'role': 'owner'}), 201);
    };
    LoginStore(File(p.join(home.path, '.config', 'easyi18n', 'credentials.json')))
        .write(origin, StoredLogin(token: raw, email: 'me@acme.test', expiresAt: DateTime.utc(2100)));
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
    home.deleteSync(recursive: true);
  });

  http.Response ok(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

  MockClient server() => MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      return switch ((req.method, path)) {
        ('GET', '/v1/me/workspaces') => ok({'workspaces': workspaces}),
        ('POST', _) when path.startsWith('/v1/workspaces/') => create(req),
        ('GET', _) when path.endsWith('/meta') => ok({'baseCode': 'en', 'currentVersionId': '',
          'languages': [for (final code in languages)
            {'code': code, 'name': code, 'isBase': code == 'en', 'fillMode': 'ai'}],
          'formats': formats, 'outputFormatsApiVersion': 1}),
        ('POST', _) when path.endsWith('/languages') =>
          ok({'code': (jsonDecode(req.body) as Map)['code'], 'fillMode': 'ai'}, 201),
        ('POST', _) when path.endsWith('/output-formats') =>
          ok({'formats': [(jsonDecode(req.body) as Map)['format']], 'created': true}),
        ('POST', _) when path.endsWith('/api-keys') => ok({'id': 'k1', 'label': 'CI (easyi18n init)',
          'prefix': ciKey.substring(0, 8), 'scopes': ['read', 'write', 'translate', 'publish'],
          'requires_operation_approval': false, 'raw_key': minted}, 201),
        _ => throw StateError('unexpected ${req.method} ${req.url}'),
      };
    });

  Future<int> run(List<String> args, {bool json = false, bool useTerminalPrompt = false,
      Map<String, String>? environment}) async {
    output = CliOutput(logger: CliLogger(out: transcript.out, err: transcript.err))..json = json;
    final mock = server();
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(InitCommand(output: output,
          prompt: useTerminalPrompt ? null : (label) {
            prompts.add(label);
            return answers.isEmpty ? null : answers.removeAt(0);
          },
          apiClientFactory: ({required baseUrl, required token}) =>
              TranslationsApiClient(baseUrl: baseUrl, token: token, httpClient: mock,
                  wait: (_) async {}),
          environment: environment ?? {'HOME': home.path, 'EASYI18N_BASE_URL': origin}));
    try {
      return await runner.run(['--config', p.join(root, 'easyi18n.yaml'), ...args]) ?? 0;
    } on CliException catch (e) {
      output.emitError(e);
      return e.exitCode;
    }
  }

  File config() => File(p.join(root, 'easyi18n.yaml'));
  Iterable<String> lines(String channel) =>
      transcript.records.where((r) => r.channel == channel).map((r) => r.line);
  String everything() => transcript.records.map((r) => r.line).join('\n');
  Iterable<String> calls() => requests.map((r) => '${r.method} ${r.url.path}');
  Map<String, Object?> bodyOf(String suffix) =>
      jsonDecode(requests.lastWhere((r) => r.url.path.endsWith(suffix)).body) as Map<String, Object?>;

  test('creates the project from a terminal, adopts the format and writes its ref',
      () async {
    answers = ['2', '', 'es, fr'];
    expect(await run(['init', '--no-agents']), 0);
    expect(prompts, ['Project [1-2]', 'Project name [acc-x]',
        'Target languages, comma-separated (e.g. es,fr)']);
    expect(lines('out'), containsAllInOrder(['  1) p_app  App', '  2) a new project']));
    expect(calls(), ['GET /v1/me/workspaces', 'POST /v1/workspaces/personal_u1/projects',
        'GET /v1/projects/p_new/meta', 'POST /v1/projects/p_new/output-formats']);
    expect(bodyOf('/projects'), {'name': 'acc-x', 'base_code': 'en',
        'target_languages': ['es', 'fr'], 'stack': 'xcode'});
    expect(bodyOf('/output-formats'), {'format': 'xcstrings', 'mode': 'adopt'});
    expect(requests.map((r) => r.headers['authorization']).toSet(), {'Bearer $raw'});
    final yaml = config().readAsStringSync();
    expect(yaml, contains('projectId: p_new'));
    expect(yaml, contains('baseUrl: $origin'));
    expect(lines('out').last, "Done. Run 'easyi18n sync'.");
    expect(everything(), isNot(contains('EASYI18N_TOKEN')));
    expect(everything(), isNot(contains(raw)));
  });

  test('links a listed project, adds the languages it lacks and writes @handle/slug',
      () async {
    workspaces.add({'id': 'w_acme', 'workspace': 'acme', 'name': 'Acme', 'plan': 'pro',
      'role': 'editor', 'projects': [{'id': 'p_web', 'workspace_id': 'w_acme',
        'workspace': 'acme', 'slug': 'web', 'name': 'Web', 'base_code': 'en', 'role': 'editor'}]});
    languages = ['en', 'fr'];
    formats = ['xcstrings'];
    answers = ['2', '1', 'fr,es'];
    expect(await run(['init', '--no-agents']), 0);
    expect(prompts.first, 'Workspace [1-2]');
    expect(calls(), ['GET /v1/me/workspaces', 'GET /v1/projects/p_web/meta',
        'POST /v1/projects/p_web/languages']);
    expect(bodyOf('/languages'), {'code': 'es'});
    final yaml = config().readAsStringSync();
    expect(yaml, contains('workspace: acme'));
    expect(yaml, contains('project: web'));
  });

  test('without a terminal the flags create it, and --json reports the steps', () async {
    expect(await run(['init', '--no-agents', '--workspace', 'personal_u1',
        '--project', 'acc-x3', '--create', '--languages', 'es'], json: true), 0);
    expect(prompts, isEmpty);
    expect(bodyOf('/projects'), {'name': 'acc-x3', 'slug': 'acc-x3', 'base_code': 'en',
        'target_languages': ['es'], 'stack': 'xcode'});
    final json = jsonDecode(lines('out').single) as Map;
    expect([for (final s in json['steps'] as List) '${s['verb']} ${s['target']}'],
        containsAllInOrder(['created project p_new', 'enabled format xcstrings']));
    expect(config().readAsStringSync(), contains('projectId: p_new'));
  });

  test('--workspace takes the @handle, and --base wins over the catalog', () async {
    workspaces.add({'id': 'w_acme', 'workspace': 'acme', 'name': 'Acme', 'plan': 'pro',
      'role': 'editor', 'projects': <Object>[]});
    create = (req) => ok({'id': 'p_acme', 'workspace_id': 'w_acme', 'workspace': 'acme',
      'slug': 'site', 'name': 'site', 'base_code': 'fr', 'role': 'owner'}, 201);
    expect(await run(['init', '--no-agents', '--workspace', '@acme', '--project', 'site',
        '--create', '--base', 'fr'], json: true), 0, reason: everything());
    expect(calls().take(2), ['GET /v1/me/workspaces', 'POST /v1/workspaces/w_acme/projects']);
    expect(bodyOf('/projects')['base_code'], 'fr');
    expect(config().readAsStringSync(), contains('workspace: acme'));
  });

  test('--project names a project to link before it creates one', () async {
    formats = ['xcstrings'];
    expect(await run(['init', '--no-agents', '--project', 'app', '--create'], json: true), 0);
    expect(calls(), ['GET /v1/me/workspaces', 'GET /v1/projects/p_app/meta']);
  });

  test('without a terminal and without a ref it names the flags and reads nothing',
      () async {
    for (final json in [true, false]) {
      transcript = Transcript();
      expect(await run(['init', '--no-agents'], json: json), 1);
      expect(everything(), contains('--workspace and --project (add --create to create it)'));
      expect(config().existsSync(), isFalse);
    }
    expect(prompts, ['Project [1-2]']);
  });

  test('any other refusal to create is the one the server gave, with no billing hint',
      () async {
    create = (_) => ok({'error': 'forbidden', 'message': 'not a member'}, 403);
    expect(await run(['init', '--no-agents', '--create'], json: true), 1);
    final error = (jsonDecode(lines('out').single) as Map)['error'] as Map;
    expect((error['code'], error['statusCode']), ('forbidden', 403));
    expect(error['message'], isNot(contains('Billing')));
  });

  test('a linked project serving another format is refused before any file', () async {
    formats = ['json'];
    answers = ['1', ''];
    expect(await run(['init', '--no-agents']), 1);
    expect(lines('err').last, 'error: p_app serves json, not "xcstrings", and init wrote '
        'nothing: link another project, create one with --create, or pass --format json '
        'if your files are in it.');
    expect(calls().where((c) => c.startsWith('POST')), isEmpty);
    expect(config().existsSync(), isFalse);
  });

  test('a 402 that is not the project cap gets no offer to link', () async {
    create = (_) => ok({'error': 'workspace_locked', 'message': 'the workspace is locked'}, 402);
    expect(await run(['init', '--no-agents', '--create'], json: true), 1);
    final error = (jsonDecode(lines('out').single) as Map)['error'] as Map;
    expect((error['code'], error['statusCode']), ('workspace_locked', 402));
    expect(error['message'], isNot(contains('Billing')));
  });

  test('an answer outside the list is no answer', () async {
    answers = ['9'];
    expect(await run(['init', '--no-agents']), 1);
    expect(calls(), ['GET /v1/me/workspaces']);
    expect(config().existsSync(), isFalse);
  });

  test('a plaintext origin that is not loopback is warned about before the login goes',
      () async {
    LoginStore(File(p.join(home.path, '.config', 'easyi18n', 'credentials.json')))
        .write('http://evil.example', StoredLogin(token: raw, expiresAt: DateTime.utc(2100)));
    expect(await run(['init', '--no-agents'], json: true,
        environment: {'HOME': home.path, 'EASYI18N_BASE_URL': 'http://evil.example'}), 1);
    expect(calls(), ['GET /v1/me/workspaces']);
    expect(lines('err'), contains(startsWith('warning: Sending your API token over plaintext HTTP')));
  });

  group('the Free cap', () {
    setUp(() => create = (_) => ok({'error': 'plan_limit',
      'message': 'This plan allows up to 3 projects. Upgrade for more.',
      'details': [{'feature': 'projects'}]}, 402));

    test('shows the server message, offers to link and writes nothing', () async {
      answers = ['2', '', 'es'];
      expect(await run(['init', '--no-agents']), 1);
      expect(lines('err').first, 'warning: Create project failed: This plan allows up to 3 '
          'projects. Upgrade for more. Upgrade under Workspace > Billing in the dashboard, '
          'or link one of its projects.');
      expect(prompts.last, 'Project to link [1-1]');
      expect(lines('err').last, startsWith('error: Create project failed: This plan allows'));
      expect(lines('err').last, endsWith('to link one, pass --project with app'));
      expect(config().existsSync(), isFalse);
    });

    test('links the project picked after it', () async {
      formats = ['xcstrings'];
      answers = ['2', '', 'es', '1', ''];
      expect(await run(['init', '--no-agents']), 0);
      expect(config().readAsStringSync(), contains('projectId: p_app'));
    });

    test('text on a pipe names the slugs to link after the cap', () async {
      final code = await IOOverrides.runZoned(
          () => run(['init', '--create'], useTerminalPrompt: true),
          stdin: () => _PipedInput());
      expect(code, 1);
      expect(lines('err'), hasLength(1));
      expect(lines('err').last, contains('to link one, pass --project with app'));
      expect(config().existsSync(), isFalse);
    });

    test('without a terminal names the projects --project can link', () async {
      expect(await run(['init', '--no-agents', '--create'], json: true), 1);
      final error = (jsonDecode(lines('out').single) as Map)['error'] as Map;
      expect(error['code'], 'plan_limit');
      expect(error['statusCode'], 402);
      expect(error['message'], endsWith('; to link one, pass --project with app'));
      expect(config().existsSync(), isFalse);
    });
  });

  group('--ci', () {
    test('mints a CI key once and prints the gh secret line', () async {
      answers = ['1', ''];
      formats = ['xcstrings'];
      expect(await run(['init', '--no-agents', '--ci']), 0);
      expect(bodyOf('/api-keys'), {'label': 'CI (easyi18n init)',
          'scopes': ['read', 'write', 'translate', 'publish']});
      expect(RegExp(ciKey).allMatches(everything()), hasLength(1));
      expect(lines('out'), contains('  gh secret set EASYI18N_TOKEN'));
      expect(everything(), isNot(contains(raw)));
    });

    test('on a kept easyi18n.yaml mints for its project; --json carries ci.raw_key',
        () async {
      config().writeAsStringSync('projectId: p_kept\nbaseUrl: $origin\n');
      expect(await run(['init', '--no-agents', '--ci'], json: true), 0);
      expect(calls(), ['POST /v1/projects/p_kept/api-keys']);
      final json = jsonDecode(lines('out').single) as Map;
      expect((json['ci'] as Map)['raw_key'], ciKey);
      expect(everything(), isNot(contains(raw)));
    });
  });

  test('--ci prints nothing that is not an API key', () async {
    config().writeAsStringSync('projectId: p_kept\nbaseUrl: $origin\n');
    minted = 'eip_${'m' * 40}';
    for (final json in [false, true]) {
      transcript = Transcript();
      expect(await run(['init', '--no-agents', '--ci'], json: json), isNonZero);
      expect(everything(), isNot(contains(minted)));
      expect(everything(), contains('the minted key is not an API key'));
    }
  });

  group('what stays as it was', () {
    test('ref flags alone, or an API key, never ask the server', () async {
      expect(await run(['init', '--no-agents', '--workspace', 'h', '--project', 's',
          '--base-url', origin]), 0);
      expect(lines('out').last, "Done. Run 'easyi18n sync'.");
      config().deleteSync();
      transcript = Transcript();
      expect(await run(['init', '--no-agents', '--workspace', 'h', '--project', 's'],
          environment: {'HOME': home.path, 'EASYI18N_BASE_URL': origin,
            'EASYI18N_TOKEN': 'eik_env'}), 0);
      expect(lines('out').last, "Done. Set EASYI18N_TOKEN, then run 'easyi18n sync'.");
      config().deleteSync();
      transcript = Transcript();
      expect(await run(['init', '--no-agents'],
          environment: {'HOME': home.path, 'EASYI18N_TOKEN': 'eik_env'}), 1);
      expect(prompts, ['Workspace handle (@handle)', 'Project id']);
      expect(requests, isEmpty);
    });

    test('--dry-run refuses what would change the server, and asks it nothing', () async {
      for (final flag in ['--create', '--ci']) {
        await expectLater(run(['init', '--dry-run', flag]), throwsA(isA<UsageException>()));
      }
      expect(await run(['init', '--no-agents', '--dry-run']), 1);
      expect(requests, isEmpty);
    });

    test('--project-id keeps a login offline', () async {
      expect(await run(['init', '--no-agents', '--project-id', 'p1']), 0);
      expect(requests, isEmpty);
    });

    test('a kept easyi18n.yaml refuses --create instead of ignoring it', () async {
      config().writeAsStringSync('projectId: p_kept\n');
      expect(await run(['init', '--create']), 1);
      expect(lines('err').single, contains('already names a project'));
      expect(requests, isEmpty);
    });

    test('a workspace the login does not have is named, with its own', () async {
      expect(await run(['init', '--workspace', '@nope', '--create']), 1);
      expect(lines('err').single, 'error: No workspace "@nope" for this login. Yours: '
          'personal_u1.');
    });
  });

  test('an Angular project is created with the web stack the onboarding knows', () async {
    await OnlineInit(client: TranslationsApiClient(baseUrl: origin, token: raw,
        httpClient: server(), wait: (_) async {}),
        logger: CliLogger(out: transcript.out, err: transcript.err), onStep: (_) {})
        .run(root: root, adapter: _Angular(), create: true, base: 'en');
    expect(bodyOf('/projects')['stack'], 'web');
    expect(bodyOf('/output-formats')['format'], 'json');
  });

  group('detectBase', () {
    StackConfigDefaults at({String? catalog, String? source}) =>
        (format: null, catalog: catalog, output: null, source: source, sourceLayout: null);

    test('reads the Xcode catalog, then the name of the source file', () {
      expect(detectBase(root, at(catalog: 'App/Localizable.xcstrings')), 'en');
      for (final (source, base) in [('lib/l10n/app_en.arb', 'en'), ('i18n/pt-BR.json', 'pt-BR'),
          ('res/values/strings.xml', null), ('i18n/messages.json', null)]) {
        expect(detectBase(root, at(source: source)), base, reason: source);
      }
    });

    test('a catalog it cannot read is no base, not an abort', () {
      File(p.join(root, 'App', 'Localizable.xcstrings')).writeAsBytesSync([0xff, 0xfe, 0x00]);
      expect(detectBase(root, at(catalog: 'App/Localizable.xcstrings')), isNull);
      expect(detectBase(root, at(catalog: 'App/Missing.xcstrings')), isNull);
    });
  });
}

class _Angular implements StackAdapter {
  @override
  String get stack => 'angular';
  @override
  String resolveMode(String root, String? mode, void Function(InitStep) report) => 'a';
  @override
  StackConfigDefaults configDefaults(String root, String mode, void Function(InitStep) report) =>
      (format: 'json', catalog: null, output: null, source: null, sourceLayout: null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PipedInput implements Stdin {
  @override
  bool get hasTerminal => false;
  @override
  String? readLineSync({Encoding encoding = systemEncoding, bool retainNewlines = false}) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
