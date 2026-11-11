@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapters.dart'
    show roadmapStacks, stackRoadmap, supportedStacks;
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/mcp/deps.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/agents_md.dart';
import '../support/stored_login.dart';
import 'harness.dart';

/// A project on disk plus the deps a tool needs to reach it.
({Directory dir, McpDeps deps}) project({
  // Null writes no config at all, which is the tree `init` is called on.
  String? config = 'projectId: proj_abc\n',
  Map<String, String> files = const {},
  Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
  http.Client? httpClient,
  DateTime Function()? clock,
  Future<void> Function(Duration)? sleep,
}) {
  final dir = Directory.systemTemp.createTempSync('mcp_project');
  if (config != null) {
    File(p.join(dir.path, 'easyi18n.yaml')).writeAsStringSync(config);
  }
  for (final entry in files.entries) {
    File(p.join(dir.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  return (
    dir: dir,
    deps: McpDeps(
      logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
      environment: environment,
      currentDirectory: () => dir.path,
      apiClientFactory: httpClient == null
          ? null
          : ({required baseUrl, required token}) => TranslationsApiClient(
                baseUrl: baseUrl, token: token, httpClient: httpClient,
              ),
      clock: clock,
      sleep: sleep,
    ),
  );
}

Map<String, Object?> errorOf(CallToolResult result) {
  expect(result.isError, isTrue);
  return (result.structuredContent!['error'] as Map).cast<String, Object?>();
}

/// The MCP `init` refusal of a tree no stack detects, spelled out because the
/// sentence is the contract an agent acts on (#2470). The lists sit inside
/// what the human is told: asked to tell them "with the roadmap", Codex named
/// the supported stacks and left the roadmap out.
String agentRefusal(String finding) => '$finding. If the app is in a '
    'subdirectory, call init again with project_dir set to it. Otherwise do '
    'not add dependencies or files to make init accept this repository, and '
    'tell the human: "easyi18n does not support this repository yet. '
    'Supported: flutter, xcode, web, android, angular; roadmap: web t() extraction, '
    'gettext."';

void main() {
  test('initialize advertises tools and carries the instructions', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    expect(harness.initializeResult.instructions, contains('Safety rules'));
    expect(harness.initializeResult.capabilities.tools, isNotNull);
    expect(
      (await harness.listTools()).map((t) => t.name),
      ['init', 'doctor', 'status', 'authorize', 'fill_status', 'publish',
        'rollback', 'pull', 'add_language',
        'extract', 'push_preview', 'push', 'apply', 'sync_preview', 'sync'],
    );
  });

  test('doctor answers with the report, not an exception, on a bare project',
      () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('doctor');
    expect(result.isError, isNot(true));
    final content = result.structuredContent!;
    expect(content['verdict'], isNotNull);
    expect(content['stack'], 'flutter');
    expect(content['family'], 'code-first');
    expect(content['project_dir'], p.normalize(fixture.dir.absolute.path));
    expect((result.content.first as TextContent).text, contains('doctor:'));
  });

  group('doctor reads whether the key is an Agent key (#1633)', () {
    final summaries = <String>[];
    setUp(summaries.clear);
    Future<List<Map<String, Object?>>> findings(http.Response Function() reply,
        {List<String>? paths,
        Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
        String check = 'agent_key'}) async {
      final fixture = project(environment: environment,
          httpClient: MockClient((request) async {
        paths?.add(request.url.path);
        return reply();
      }));
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness.call('doctor');
      expect(result.isError, isNot(true));
      summaries.add((result.content.first as TextContent).text);
      return [
        for (final f in result.structuredContent!['findings'] as List)
          if ((f as Map)['check'] == check) f.cast<String, Object?>(),
      ];
    }

    http.Response key(bool agent) => http.Response(jsonEncode({
          'scopes': ['read', 'translate', 'publish'],
          'requires_operation_approval': agent,
        }), 200);

    test('a key without the flag is a warning naming where to create one',
        () async {
      final paths = <String>[];
      final found = await findings(() => key(false), paths: paths);
      expect(paths, ['/v1/projects/proj_abc/credential']);
      expect(found, hasLength(1));
      expect(found.single['level'], 'warn');
      expect(found.single['message'], contains('not an Agent key'));
      expect(found.single['message'], contains('Used by: AI agent'));
      // A client that hands the model only `content` still learns which
      // warning it is; the bare project's three failures fill the other slots.
      expect(summaries.single.split('\n'), contains('warn: agent_key'));
    });

    test('without a token it asks nothing', () async {
      final paths = <String>[];
      final fixture = project(environment: const {},
          httpClient: MockClient((request) async {
            paths.add(request.url.path);
            return key(false);
          }));
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      writeAgentsBlock(p.join(fixture.dir.path, 'easyi18n.yaml'));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      final result = await harness.call('doctor');
      expect(paths, isEmpty);
      expect([
        for (final f in result.structuredContent!['findings'] as List)
          (f as Map)['check'],
      ], allOf(contains('credential'), isNot(contains('agent_key'))));
      // The `credential` warning is there, and it is not the one named.
      expect((result.content.first as TextContent).text,
          allOf(contains('1 warning(s)'), isNot(contains('agent_key'))));
    });

    // Decision 1 of #2579: the login is not a key that forgot its flag. It
    // spends as its human, which is what the human chose (#2583, duda 11).
    test('the stored login passes, named as the human it spends as', () async {
      final environment = loggedInHome();
      final found = await findings(() => key(false), environment: environment);
      expect(found.single['level'], 'ok');
      expect(found.single['message'], contains('your login'));
      expect(found.single['message'], isNot(contains('not an Agent key')));
      expect(summaries.single, isNot(contains('agent_key')));
      final credential = await findings(() => key(false),
          environment: environment, check: 'credential');
      expect(credential.single['message'],
          'logged in as dev@acme.test until 2099-01-01T00:00:00.000Z');
    });

    test('a login the server makes ask passes as an Agent key does', () async {
      final found = await findings(() => key(true), environment: loggedInHome());
      expect(found.single['message'], contains('every spend and publish waits'));
    });

    test('an Agent key passes', () async {
      final found = await findings(() => key(true));
      expect(found.single['level'], 'ok');
      expect(summaries.single, isNot(contains('agent_key')));
    });

    test('a server that cannot say is unverified, never a pass', () async {
      final missing = await findings(() => http.Response(
          '{"error":"not_found","message":"no route"}', 404));
      expect(missing.single['level'], 'unverified');
      expect(missing.single['message'], contains('404'));
      final shapeless = await findings(() => http.Response(
          '{"scopes":["read"]}', 200));
      expect(shapeless.single['level'], 'unverified');
    });
  });

  test('status reports the published version through the injected client',
      () async {
    final fixture = project(
      httpClient: MockClient((_) async => http.Response(
            jsonEncode({'currentVersionId': '2026.09.12.1', 'baseCode': 'en'}),
            200,
          )),
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('status');
    expect(result.isError, isNot(true));
    expect(result.structuredContent!['remote_version'], '2026.09.12.1');
    expect(result.structuredContent!['state'], 'never_pulled');
  });

  test('a missing credential is a no_credential error, never a question',
      () async {
    final fixture = project(environment: const {});
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('status');
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'no_credential');
    expect(errorOf(result)['retryable'], isFalse);
  });

  // #2646: a refused certificate answered `internal_error`, "See the server log".
  test('a TLS failure is a retryable connection error, as a server down is',
      () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(McpDeps(
      logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
      environment: const {'EASYI18N_TOKEN': 'eik_test'},
      currentDirectory: () => fixture.dir.path,
      apiClientFactory: ({required baseUrl, required token}) => TranslationsApiClient(
          baseUrl: baseUrl, token: token, wait: (_) async {},
          httpClient: MockClient((_) async =>
              throw const HandshakeException('Handshake error in client'))),
    ));
    addTearDown(harness.shutdown);

    final error = errorOf(await harness.call('status'));
    expect(error['code'], 'cli_error');
    expect(error['retryable'], isTrue);
    expect(error['message'], startsWith('Could not reach https://api.easyi18n.com: '
        'HandshakeException: Handshake error in client'));
  });

  test('extract diffs sources against the lockfile', () async {
    final fixture = project(files: {
      'lib/app.dart': "void f(c) { c.tr('Hello'); }\n",
    });
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract');
    expect(result.isError, isNot(true));
    expect(result.structuredContent!['total'], 1);
    expect(result.structuredContent!['added'], 1);
    expect((result.structuredContent!['units'] as List).single,
        containsPair('source', 'Hello'));
  });

  test('extract on a file-first project answers wrong_family with the right '
      'tool', () async {
    final fixture = project(
      config: 'projectId: proj_abc\nformat: xcstrings\n'
          'catalog: Localizable.xcstrings\n',
      files: {'Localizable.xcstrings': '{"sourceLanguage":"en","strings":{}}'},
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract');
    expect(result.isError, isTrue);
    final error = errorOf(result);
    expect(error['code'], 'wrong_family');
    expect(error['family'], 'file-first');
    expect(error['use_instead'], 'sync_preview');
  });

  group('D4 refuses a target the operator did not name', () {
    Future<CallToolResult> statusAgainst(String baseUrl,
        {Map<String, String> environment = const {
          'EASYI18N_TOKEN': 'eik_test',
        }}) async {
      final fixture = project(
        config: 'projectId: proj_abc\nbaseUrl: $baseUrl\n',
        environment: environment,
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({'currentVersionId': '', 'baseCode': 'en'}), 200)),
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      return harness.call('status');
    }

    test('a foreign https host is refused', () async {
      final result = await statusAgainst('https://evil.example');
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'untrusted_base_url');
    });

    // The production HOST over plaintext: the only case the http branch alone
    // can catch — with a foreign host the other branch refuses it anyway, and
    // a mutation that deleted this branch stayed green until this case existed.
    test('plaintext http to the production host is refused', () async {
      final result = await statusAgainst('http://api.easyi18n.com');
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(errorOf(result)['message'], contains('plaintext'));
    });

    test('plaintext http to a non-loopback host is refused', () async {
      final result = await statusAgainst('http://staging.example');
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'untrusted_base_url');
    });

    // The negative controls: without them every mutation of the guard that
    // refuses MORE would stay green.
    test('loopback is trusted with no env at all', () async {
      final result = await statusAgainst('http://localhost:8080',
          environment: const {'EASYI18N_TOKEN': 'eik_test'});
      expect(result.isError, isNot(true), reason: 'the emulator must work');
    });

    test('the operator env opens exactly its own origin', () async {
      final allowed = await statusAgainst('https://staging.example',
          environment: const {
            'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_BASE_URL': 'https://staging.example',
          });
      expect(allowed.isError, isNot(true));

      final other = await statusAgainst('https://evil.example',
          environment: const {
            'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_BASE_URL': 'https://staging.example',
          });
      expect(other.isError, isTrue);
      expect(errorOf(other)['code'], 'untrusted_base_url');
    });

    test('production is trusted', () async {
      final result = await statusAgainst('https://api.easyi18n.com');
      expect(result.isError, isNot(true));
    });
  });

  test('an unknown argument is rejected, not ignored', () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('doctor', {'token': 'eik_leaked'});
    expect(result.isError, isTrue);
  });

  test('a credential in project data never reaches structuredContent', () async {
    final fixture = project(files: {
      'lib/app.dart':
          "void f(c) => c.tr('Token eik_ABCDEFGHIJKLMNOPQR', ctx: 'noun');\n",
    });
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract');
    expect(jsonEncode(result.structuredContent), isNot(contains('eik_ABCD')));
    expect((result.structuredContent!['units'] as List).single,
        containsPair('source', 'Token [REDACTED]'));
  });

  test('structuredContent stays inside the 32 KiB output budget', () async {
    final long = 'x' * 40000;
    final fixture = project(files: {
      'lib/app.dart': "void f(c) => c.tr('$long');\n",
    });
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract');
    final bytes = utf8.encode(jsonEncode(result.structuredContent)).length;
    expect(bytes, lessThanOrEqualTo(32 * 1024), reason: '$bytes bytes');
    final source =
        (result.structuredContent!['units'] as List).single as Map;
    expect(source['source'], endsWith('…'));
    expect((source['source'] as String).length, 201);
  });

  test('a long non-ASCII list is cut where the budget runs out', () async {
    // The shape row caps cannot bound: many rows, each one long, and CJK at
    // three bytes a character.
    final unit = '文' * 400;
    final files = {
      for (var i = 0; i < 200; i++)
        'lib/a$i.dart': "void f$i(c) => c.tr('$unit$i');\n",
    };
    final fixture = project(files: files);
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract', {'limit': 200});
    final bytes = utf8.encode(jsonEncode(result.structuredContent)).length;
    expect(bytes, lessThanOrEqualTo(32 * 1024), reason: '$bytes bytes');
    expect(result.structuredContent!['truncated'], isTrue);
    expect(result.structuredContent!['total'], 200,
        reason: 'the total survives the cut, it is what paging needs');
    expect((result.structuredContent!['units'] as List).length, lessThan(200));
  });

  test('offset pages past what the budget cut', () async {
    final fixture = project(files: {
      'lib/app.dart': [
        'void f(c) {',
        for (final name in ['A', 'B', 'C', 'D', 'E']) "  c.tr('Source $name');",
        '}',
      ].join('\n'),
    });
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final first = await harness.call('extract', {'limit': 2});
    expect(first.structuredContent!['truncated'], isTrue);
    expect(first.structuredContent!['offset'], 0);
    final second = await harness.call('extract', {'limit': 2, 'offset': 2});
    expect(second.structuredContent!['offset'], 2);
    expect(second.structuredContent!['truncated'], isTrue);
    final last = await harness.call('extract', {'limit': 2, 'offset': 4});
    expect(last.structuredContent!['truncated'], isFalse);
    List<Object?> sourcesOf(CallToolResult r) => [
      for (final u in r.structuredContent!['units'] as List)
        (u as Map)['source'],
    ];
    expect(sourcesOf(first), isNot(sourcesOf(second)));
    expect([...sourcesOf(first), ...sourcesOf(second), ...sourcesOf(last)],
        hasLength(5));
  });

  test('the family is decided on the tree the runner will scan', () async {
    // cwd is a Flutter project; --config points at a file-first one elsewhere.
    final flutter = project(files: {'pubspec.yaml': 'name: app\nflutter:\n  uses-material-design: true\n'});
    addTearDown(() => flutter.dir.deleteSync(recursive: true));
    final xcode = project(
      config: 'projectId: proj_abc\nformat: xcstrings\n'
          'catalog: Localizable.xcstrings\n',
      files: {'Localizable.xcstrings': '{"sourceLanguage":"en","strings":{}}'},
    );
    addTearDown(() => xcode.dir.deleteSync(recursive: true));

    final deps = McpDeps(
      logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
      environment: const {'EASYI18N_TOKEN': 'eik_test'},
      currentDirectory: () => flutter.dir.path,
      configFileName: p.join(xcode.dir.path, 'easyi18n.yaml'),
    );
    final harness = await McpHarness.start(deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract');
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'wrong_family');
  });

  test('doctor refuses a source_dir that leaves the project root', () async {
    // The fixture has to reach the reporting branch: a well-formed `tr()`
    // produces no finding at all, so a probe with one reads "no leak". With
    // malformed ICU the finding quotes the outside file's path and its source.
    final fixture = project(files: {'pubspec.yaml': 'name: app\n'});
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final outside = Directory.systemTemp.createTempSync('mcp_outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    File(p.join(outside.path, 'bad.dart'))
        .writeAsStringSync("f(c) => c.tr('OUTSIDE {n, plural, one{x}}');\n");
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('doctor', {'source_dir': outside.path});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'source_dir_outside_project');
    expect(jsonEncode(result.structuredContent), isNot(contains('OUTSIDE')),
        reason: 'the findings used to carry the outside file and its source');
    expect(jsonEncode(result.structuredContent), isNot(contains('bad.dart')));
  });

  test('extract refuses a source_dir that leaves the project root', () async {
    // `extract` only reads, but it returns what it read: `units` and
    // `dynamics` carry the file, the line and the snippet.
    final fixture = project(files: {'lib/a.dart': "f(c) => c.tr('Hi');\n"});
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final outside = Directory.systemTemp.createTempSync('mcp_outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    File(p.join(outside.path, 'secret.dart'))
        .writeAsStringSync("f(c) => c.tr('Secret');\n");
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final absolute = await harness.call('extract', {'source_dir': outside.path});
    expect(absolute.isError, isTrue);
    expect(errorOf(absolute)['code'], 'source_dir_outside_project');
    expect(jsonEncode(absolute.structuredContent), isNot(contains('Secret')));
    final relative = await harness.call(
        'extract', {'source_dir': p.join('..', p.basename(outside.path))});
    expect(errorOf(relative)['code'], 'source_dir_outside_project');
  });

  test('a schema rejection carries the same error contract as any failure',
      () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('doctor', {'token': 'eik_leaked'});
    expect(result.isError, isTrue);
    expect(result.structuredContent, isNotNull);
    expect(errorOf(result)['code'], 'invalid_arguments');
    expect(errorOf(result)['retryable'], isFalse);
    expect(jsonEncode(result.structuredContent), isNot(contains('eik_leaked')));
  });

  test('a relative project_dir is refused instead of joined onto cwd',
      () async {
    final fixture = project();
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);

    final result = await harness.call('extract', {'project_dir': '../other'});
    expect(result.isError, isTrue);
    expect(errorOf(result)['code'], 'invalid_project_dir');
  });

  group('init', () {
    /// The config the NEXT tool will load, reloaded from disk. A report says
    /// what init meant to write; only the file says what it wrote (#1609).
    Easyi18nConfig reload(Directory dir) => Easyi18nConfig.load(
          File(p.join(dir.path, 'easyi18n.yaml')),
          logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
        );

    // A named stack has to be one the tree has (#2444), so a test about
    // something else that names `flutter` runs on a Flutter app.
    const flutterApp = {'pubspec.yaml': 'name: probe\nflutter:\n'};

    test('writes a config the loader reads back', () async {
      final fixture = project(config: null, files: {
        'pubspec.yaml': 'name: app\nflutter:\n  uses-material-design: true\n',
      });
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call(
        'init', {'workspace': '@acme', 'project': 'web'});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['stack'], 'flutter');
      expect(result.structuredContent!['family'], 'code-first');
      expect(result.structuredContent!['steps'], isNotEmpty);
      expect(reload(fixture.dir).describeRef, contains('acme'));
    });

    // The agent reads the steps, not the terminal: the one that names the
    // template carries the import that comes before the first pull (#2343).
    test('a gen_l10n tree declares its template and names the import',
        () async {
      final fixture = project(config: null, files: {
        'pubspec.yaml': 'name: app\nflutter:\n  generate: true\n',
        'l10n.yaml': 'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n',
        'lib/l10n/app_en.arb': '{"@@locale":"en","welcome":"Welcome"}\n',
      });
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('init', {'project_id': 'proj_abc'});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['next'], 'pull');
      final steps = (result.structuredContent!['steps'] as List).cast<Map>();
      final named = steps.where((s) => (s['target'] as String)
          .endsWith(p.join('lib', 'l10n', 'app_en.arb'))).toList();
      expect(named, hasLength(1));
      final template = named.single;
      expect(template['verb'], 'detected');
      expect(template['detail'], contains('pull never writes it'));
      expect(template['detail'],
          contains('Before the first pull, import the .arb files'));
      expect(reload(fixture.dir).source, 'lib/l10n/app_en.arb');
    });

    test('lets the stack pick the format when none is given', () async {
      // The CLI has to undo its own `defaultsTo: arb` for this; here an absent
      // argument is null, and the file is the only place the difference shows.
      final fixture = project(config: null, files: {
        'App.xcodeproj/project.pbxproj': '// fixture\n',
        'Localizable.xcstrings': '{"sourceLanguage":"en","strings":{}}',
      });
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call(
        'init', {'project_id': 'proj_abc', 'stack': 'xcode'});
      expect(result.isError, isNot(true));
      expect(reload(fixture.dir).format, 'xcstrings');
      // The catalog is the destination, so the file names no directory: it
      // used to carry Flutter's `output: lib/l10n` (#1858).
      final written =
          File('${fixture.dir.path}/easyi18n.yaml').readAsStringSync();
      expect(written, contains('\ncatalog: Localizable.xcstrings\n'));
      expect(written, isNot(contains('output:')));
    });

    // Detection is the default, so the pair here is what the default does and
    // what naming a stack does over it. Until #1641 the default was `flutter`
    // and this same Xcode tree came back as a Flutter project, reported as
    // success: mode b, format arb, an assets dir, a Dart scope snippet. Until
    // #2444 naming `flutter` still did.
    test('an absent stack detects, a named one the tree lacks is refused',
        () async {
      final files = {
        'App.xcodeproj/project.pbxproj': '// fixture\n',
        'Localizable.xcstrings': '{"sourceLanguage":"en","strings":{}}',
        'pubspec.yaml': 'name: probe\n',
      };

      final detectedFixture = project(config: null, files: files);
      addTearDown(() => detectedFixture.dir.deleteSync(recursive: true));
      final detectedHarness = await McpHarness.start(detectedFixture.deps);
      addTearDown(detectedHarness.shutdown);
      final detected =
          await detectedHarness.call('init', {'project_id': 'proj_abc'});
      expect(detected.isError, isNot(true));
      expect(detected.structuredContent!['stack'], 'xcode');
      expect(detected.structuredContent!['family'], 'file-first');
      expect(reload(detectedFixture.dir).format, 'xcstrings');

      final namedFixture = project(config: null, files: files);
      addTearDown(() => namedFixture.dir.deleteSync(recursive: true));
      final namedHarness = await McpHarness.start(namedFixture.deps);
      addTearDown(namedHarness.shutdown);
      final named = await namedHarness
          .call('init', {'project_id': 'proj_abc', 'stack': 'flutter'});
      expect(named.isError, isTrue);
      expect(errorOf(named)['code'], 'unsupported_stack');
      // The tree is supported, as another stack: telling the human it is not
      // would be false (#2470).
      expect(errorOf(named)['message'],
          'No flutter project found at ${namedFixture.dir.path} '
          '(detected there: xcode). Supported: '
          '${supportedStacks.join(', ')}; roadmap: $stackRoadmap. Call init '
          'again with one of the detected stacks or with stack auto.');
      expect(File(p.join(namedFixture.dir.path, 'easyi18n.yaml')).existsSync(),
          isFalse);
    });

    // An unrecognized tree refuses now, so a test about something else has to
    // name a stack or it fails on detection before reaching its subject.
    test('an unrecognized tree refuses instead of writing a Flutter config',
        () async {
      final fixture = project(config: null);
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('init', {'project_id': 'proj_abc'});
      expect(result.isError, isTrue);
      expect(errorOf(result)['message'], contains('No supported stack found'));
      // Codex loads no MCP prompts, so this refusal is where it learns the
      // roadmap the `setup` prompt names (#1930).
      expect(errorOf(result)['message'], contains('roadmap: $stackRoadmap'));
      expect(File(p.join(fixture.dir.path, 'easyi18n.yaml')).existsSync(),
          isFalse);
    });

    test('an unrecognized tree answers a code and the stack lists as fields',
        () async {
      final fixture = project(config: null, files: {'package.json': '{}'});
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('init', {'stack': 'auto'});
      final error = errorOf(result);
      expect(error['code'], 'unsupported_stack');
      expect(error['retryable'], isFalse);
      expect(error['supported'], ['flutter', 'xcode', 'web', 'android', 'angular']);
      expect(error['roadmap'], isList);
      final roadmap = (error['roadmap'] as List).cast<String>();
      // One entry per stack: a list holding the whole sentence fragment is
      // non-empty too, and an agent cannot enumerate it.
      expect(roadmap.length, greaterThan(1));
      expect(roadmap, everyElement(isNot(contains(','))));
      const sentence = 'Supported: flutter, xcode, web, android, angular; roadmap: ';
      expect(error['message'], contains('$sentence${roadmap.join(', ')}.'));
      expect((result.content.single as TextContent).text, error['message']);
    });

    // In corrida 9 Codex read "web needs one of … i18next in package.json" as
    // a step, installed i18next and never told the human (#2470). The agent
    // is told to stop instead; the CLI keeps the diagnosis for a person.
    test('an unrecognized tree tells the agent to stop, not what to install',
        () async {
      final fixture = project(config: null, files: {'package.json': '{}'});
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('init', {'dry_run': true});
      expect(errorOf(result)['message'], agentRefusal(
          'No supported stack found at ${fixture.dir.path}'));
      expect(fixture.dir.listSync().map((e) => p.basename(e.path)),
          ['package.json']);
    });

    // In corrida 8 Codex named `web` on such a tree and got a config written
    // as success where `auto` refuses (#2444). Every named stack answers alike.
    for (final stack in supportedStacks) {
      test('a named $stack the tree does not have answers unsupported_stack',
          () async {
        final fixture = project(config: null, files: {'package.json': '{}'});
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);

        final result = await harness
            .call('init', {'project_id': 'proj_abc', 'stack': stack});
        expect(result.isError, isTrue);
        final error = errorOf(result);
        expect(error['code'], 'unsupported_stack');
        expect(error['supported'], supportedStacks);
        expect(error['roadmap'], roadmapStacks);
        expect(error['message'], agentRefusal(
            'No $stack project found at ${fixture.dir.path}'));
        expect(fixture.dir.listSync().map((e) => p.basename(e.path)),
            ['package.json']);
      });
    }

    test('dry_run writes nothing', () async {
      final fixture = project(config: null, files: flutterApp);
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('init',
          {'project_id': 'proj_abc', 'dry_run': true, 'stack': 'flutter'});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['dry_run'], isTrue);
      expect(File(p.join(fixture.dir.path, 'easyi18n.yaml')).existsSync(),
          isFalse, reason: 'a dry run must leave the tree untouched');
    });

    test('write_agents writes the AGENTS.md block, and false skips it',
        () async {
      for (final writeAgents in [null, false]) {
        final fixture = project(config: null, files: flutterApp);
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call('init', {
          'project_id': 'proj_abc', 'stack': 'flutter',
          'write_agents': ?writeAgents,
        });
        expect(result.isError, isNot(true));
        final agents = File(p.join(fixture.dir.path, 'AGENTS.md'));
        final last = (result.structuredContent!['steps'] as List).last as Map;
        expect(last['target'], agents.path);
        expect(last['verb'], writeAgents == false ? 'skipped' : 'created');
        expect(agents.existsSync(), writeAgents != false);
      }
    });

    test('with no project ref it fails instead of waiting on stdin', () async {
      // A backend that predates `GET /v1/credential` cannot name the key's
      // project, so the ref has to come from the human (#2445).
      final fixture = project(config: null, files: flutterApp,
          httpClient: MockClient((_) async =>
              http.Response('Route not found', 404)));
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      // A Flutter app, so the refusal under test is the missing ref and not
      // detection.
      final result = await harness.call('init', {'stack': 'flutter'});
      expect(result.isError, isTrue);
      final message = errorOf(result)['message'] as String;
      expect(message, contains('Missing project ref'));
      expect(message, contains('app.easyi18n.com/@<handle>/<slug>'));
      expect(message, contains('init {workspace, project}'));
      expect(message, isNot(contains('terminal')),
          reason: 'an MCP agent has no terminal to run init in');
      expect(File(p.join(fixture.dir.path, 'easyi18n.yaml')).existsSync(),
          isFalse);
    });

    group('on an existing easyi18n.yaml', () {
      // Not the default origin: a comparison against the default instead of
      // the file would pass on the default.
      const onDisk = 'projectId: proj_abc\nbaseUrl: http://localhost:8080\n';

      Future<({CallToolResult result, File yaml})> rerun(
          Map<String, Object?> arguments,
          {String config = onDisk}) async {
        final fixture = project(config: config, files: flutterApp);
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call('init', {'stack': 'flutter', ...arguments});
        expect(result.isError, isNot(true));
        return (result: result, yaml: File(p.join(fixture.dir.path, 'easyi18n.yaml')));
      }

      List<Map<String, Object?>> yamlSteps(CallToolResult result, File yaml) => [
        for (final step in result.structuredContent!['steps'] as List)
          if ((step as Map)['target'] == yaml.path) step.cast<String, Object?>(),
      ];

      // The agent only reads this result: a server-side stderr warning, or
      // none at all, let it report success against the other backend (#2135).
      test('a different base_url is kept and named, with force', () async {
        final (:result, :yaml) = await rerun(
            {'project_id': 'proj_abc', 'base_url': 'http://localhost:59514'});
        expect(yamlSteps(result, yaml), [
          {'verb': 'ok', 'target': yaml.path, 'detail': 'kept existing config'},
          {'verb': 'skipped', 'target': yaml.path,
            'detail': 'keeps baseUrl: http://localhost:8080, not '
                'http://localhost:59514 (use --force to rewrite)'},
        ]);
        expect(result.structuredContent!['base_url'], 'http://localhost:8080');
        expect(yaml.readAsStringSync(), onDisk);
      });

      test('equal arguments, spelled differently, add no step', () async {
        final (:result, :yaml) = await rerun({
          'project_id': 'proj_abc', 'base_url': 'http://localhost:8080/',
          'mode': 'b', 'format': 'arb', 'output': 'lib/l10n/',
          'catalog': './App/Localizable.xcstrings',
        }, config: '${onDisk}catalog: App/Localizable.xcstrings\n');
        expect(yamlSteps(result, yaml), [
          {'verb': 'ok', 'target': yaml.path, 'detail': 'kept existing config'},
        ]);
      });

      test('force rewrites from the arguments', () async {
        final (:result, :yaml) = await rerun({'project_id': 'proj_abc',
          'base_url': 'http://localhost:59514', 'force': true});
        expect(yamlSteps(result, yaml).single['verb'], 'rewrote');
        expect(result.structuredContent!['base_url'], 'http://localhost:59514');
        expect(yaml.readAsStringSync(), contains('\nbaseUrl: http://localhost:59514\n'));
      });

      test('every other key the call names is compared too', () async {
        const config = 'workspace: demo\nproject: shop\nmode: a\n'
            'baseUrl: http://localhost:8080\nformat: json\noutput: public/i18n\n';
        final (:result, :yaml) = await rerun({
          'workspace': 'other', 'project': 'shop2', 'mode': 'b',
          // Not a URL: the re-run still answers, as with a degenerate ref.
          'base_url': 'localhost:9090', 'format': 'po', 'output': 'elsewhere',
          'catalog': 'App/Localizable.xcstrings',
        }, config: config);
        const force = ' (use --force to rewrite)';
        expect([for (final step in yamlSteps(result, yaml).skip(1)) step['detail']], [
          'keeps project @demo/shop, not @other/shop2$force',
          'keeps mode: a, not b$force',
          'keeps baseUrl: http://localhost:8080, not localhost:9090$force',
          'keeps format: json, not po$force',
          'keeps output: public/i18n, not elsewhere$force',
          'keeps catalog: (none), not App/Localizable.xcstrings$force',
        ]);
        expect(yaml.readAsStringSync(), config);
      });

      test('a `catalogs:` config is named, not reported as having no catalog (#590)',
          () async {
        const config = 'workspace: demo\nproject: shop\nmode: a\n'
            'baseUrl: http://localhost:8080\nformat: xcstrings\n'
            'catalogs:\n  - App/A.xcstrings\n  - App/B.xcstrings\n';
        final (:result, :yaml) = await rerun(
            {'catalog': 'App/Localizable.xcstrings'}, config: config);
        expect([for (final step in yamlSteps(result, yaml).skip(1)) step['detail']], [
          'keeps catalogs: App/A.xcstrings, App/B.xcstrings, '
              'not App/Localizable.xcstrings (use --force to rewrite)',
        ]);
      });
    });

    test('an unknown stack is rejected by the schema, not by the runner',
        () async {
      final fixture = project(config: null);
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness
          .call('init', {'project_id': 'proj_abc', 'stack': 'gettext'});
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'invalid_arguments');
    });
  });

  // #2445: an agent with the key and no easyi18n.yaml gets no tool in red and
  // asks the human for no identifier: the server names the key's project.
  group('first contact reads the project from the key', () {
    const flutterApp = {'pubspec.yaml': 'name: probe\nflutter:\n'};
    Map<String, Object?> keyProject(
            {String? handle = 'acme', String? slug = 'acceptance-codex'}) => {
          'scopes': ['read', 'translate', 'publish'],
          'requires_operation_approval': true,
          'project': {'id': 'p1', 'workspace_id': 'w1',
            'workspace': ?handle, 'slug': ?slug},
        };

    Future<({CallToolResult result, Directory dir, List<Uri> requests})> call(
        String tool, Map<String, Object?> arguments,
        {http.Response Function()? reply,
        Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'},
        String? config, Map<String, String> files = flutterApp}) async {
      final requests = <Uri>[];
      final fixture = project(config: config, files: files,
          environment: environment,
          httpClient: MockClient((request) async {
            requests.add(request.url);
            return (reply ?? () => http.Response(jsonEncode(keyProject()), 200))();
          }));
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);
      return (result: await harness.call(tool, arguments), dir: fixture.dir,
          requests: requests);
    }

    String? yamlOf(Directory dir) {
      final file = File(p.join(dir.path, 'easyi18n.yaml'));
      return file.existsSync() ? file.readAsStringSync() : null;
    }

    test('status is not an error: it names the project and init', () async {
      final (:result, :dir, :requests) = await call('status', {});
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(result.structuredContent, {
        'initialized': false,
        'project': '@acme/acceptance-codex',
        'next': 'init',
        'project_dir': p.normalize(dir.absolute.path),
        'base_url': Easyi18nConfig.defaultBaseUrl,
      });
      expect(requests.map((u) => '$u'),
          ['${Easyi18nConfig.defaultBaseUrl}/v1/credential']);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('not initialized'));
      expect(text, contains('@acme/acceptance-codex'));
      expect(yamlOf(dir), isNull, reason: 'status writes nothing');
    });

    test('status asks the origin the operator named in the MCP block',
        () async {
      final (:result, dir: _, :requests) = await call('status', {},
          environment: const {'EASYI18N_TOKEN': 'eik_test',
            'EASYI18N_BASE_URL': 'http://localhost:9001/'});
      expect(result.structuredContent!['base_url'], 'http://localhost:9001');
      expect(requests.map((u) => '$u'), ['http://localhost:9001/v1/credential']);
    });

    test('a blank operator origin uses the default before init', () async {
      for (final origin in ['', '   ']) {
        final (:result, dir: _, :requests) = await call('status', {},
            environment: {'EASYI18N_TOKEN': 'eik_test',
              'EASYI18N_BASE_URL': origin});
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['base_url'],
            Easyi18nConfig.defaultBaseUrl);
        expect(requests.map((u) => '$u'),
            ['${Easyi18nConfig.defaultBaseUrl}/v1/credential']);
      }
    });

    test('a credential response without a project id writes nothing',
        () async {
      for (final id in [null, '']) {
        final body = keyProject();
        if (id == null) {
          (body['project'] as Map).remove('id');
        } else {
          (body['project'] as Map)['id'] = id;
        }
        final (:result, :dir, requests: _) = await call('init', {},
            reply: () => http.Response(jsonEncode(body), 200));
        expect(result.isError, isTrue);
        expect(errorOf(result)['message'], contains('no project id'));
        expect(yamlOf(dir), isNull);
      }
    });

    test('status on a backend without the route still answers', () async {
      final (:result, dir: _, requests: _) = await call('status', {},
          reply: () => http.Response('Route not found', 404));
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['initialized'], false);
      expect(result.structuredContent!['next'], 'init');
      expect(result.structuredContent, isNot(contains('project')));
    });

    test('status says initialized once there is a config', () async {
      final (:result, dir: _, requests: _) = await call('status', {},
          config: 'projectId: p1\n',
          reply: () => http.Response(jsonEncode({
                'currentVersionId': '', 'languages': [
                  {'code': 'en', 'isBase': true, 'fillMode': 'ai'},
                ]}), 200));
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(result.structuredContent!['initialized'], true);
      expect(result.structuredContent!['state'], 'never_published');
    });

    test('doctor reports the missing config as a finding naming init',
        () async {
      final (:result, :dir, :requests) = await call('doctor', {});
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      final findings = [
        for (final f in result.structuredContent!['findings'] as List)
          (f as Map).cast<String, Object?>(),
      ];
      final config = findings.singleWhere((f) => f['check'] == 'config');
      expect(config['level'], 'fail');
      expect(config['message'], contains('init'));
      expect(findings.map((f) => f['check']), contains('credential'));
      expect(result.structuredContent!['verdict'], 'failed');
      expect(result.structuredContent!['stack'], 'flutter');
      expect(requests, isEmpty);
      expect(yamlOf(dir), isNull);
    });

    test('init with no ref writes the @handle/slug the key belongs to',
        () async {
      final (:result, :dir, :requests) = await call('init', {});
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(requests.map((u) => u.path), ['/v1/credential']);
      final yaml = yamlOf(dir)!;
      expect(yaml, contains('workspace: acme\n'));
      expect(yaml, contains('project: acceptance-codex\n'));
      expect(yaml, isNot(contains('projectId:')));
      final created = [
        for (final s in result.structuredContent!['steps'] as List)
          if ((s as Map)['target'] == p.join(dir.path, 'easyi18n.yaml')) s,
      ].single;
      expect(created['verb'], 'created');
      expect(created['detail'], contains('EASYI18N_TOKEN'));
    });

    test('init with no ref writes the project id when the handle is not '
        'claimed', () async {
      final (:result, :dir, requests: _) = await call('init', {},
          reply: () => http.Response(jsonEncode(keyProject(handle: null)), 200));
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      final yaml = yamlOf(dir)!;
      expect(yaml, contains('projectId: p1\n'));
      expect(yaml, isNot(contains('workspace:')));
    });

    test('a claimed handle on a project without a slug writes the id too',
        () async {
      final (:result, :dir, requests: _) = await call('init', {},
          reply: () => http.Response(jsonEncode(keyProject(slug: null)), 200));
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(yamlOf(dir), contains('projectId: p1\n'));
    });

    test('a tree init refuses sends nothing, and doctor still answers',
        () async {
      final init = await call('init', {}, files: const {});
      expect(errorOf(init.result)['code'], 'unsupported_stack');
      expect(init.requests, isEmpty,
          reason: 'the stack is picked before the key is read');
      final doctor = await call('doctor', {}, files: const {});
      expect(doctor.result.isError, isNot(true));
      expect(doctor.result.structuredContent!['stack'], 'flutter',
          reason: 'with no config and nothing detected, the default stack');
    });

    // #2583 (duda 4): the login goes back only to the origin that approved
    // it, so a config naming another one, loopback included, finds none.
    test('a login stored for another origin is never sent', () async {
      final (:result, dir: _, :requests) = await call('status', {},
          config: 'projectId: p1\nbaseUrl: http://localhost:9001\n',
          environment: loggedInHome());
      expect(requests, isEmpty);
      expect(errorOf(result)['code'], 'no_credential');
      expect(errorOf(result)['message'],
          startsWith('No credential for http://localhost:9001.'));
    });

    // #2583 (duda 10): a login names no project, so status asks the server
    // nothing; init lists where the login works (#2584, init_login_test).
    test('with the stored login status asks nothing', () async {
      final status = await call('status', {}, environment: loggedInHome());
      expect(status.result.isError, isNot(true),
          reason: '${status.result.structuredContent}');
      expect(status.result.structuredContent, {
        'initialized': false,
        'next': 'init',
        'project_dir': p.normalize(status.dir.absolute.path),
        'base_url': Easyi18nConfig.defaultBaseUrl,
      });
      expect(status.requests, isEmpty);
    });

    test('without a token status and init say no_credential and write nothing',
        () async {
      for (final tool in ['status', 'init']) {
        final (:result, :dir, :requests) =
            await call(tool, {}, environment: const {});
        expect(result.isError, isTrue, reason: tool);
        expect(errorOf(result)['code'], 'no_credential', reason: tool);
        expect(requests, isEmpty, reason: tool);
        expect(yamlOf(dir), isNull, reason: tool);
      }
    });

    test('a revoked key fails init on the credential, not on the ref',
        () async {
      final (:result, :dir, requests: _) = await call('init', {},
          reply: () => http.Response(jsonEncode({'error': 'unauthorized',
              'message': 'invalid credential'}), 401));
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'unauthorized');
      expect(errorOf(result)['message'], isNot(contains('Missing project ref')));
      expect(yamlOf(dir), isNull);
    });

    test('a trashed project is the 404 it is, not a backend without the route',
        () async {
      final (:result, :dir, requests: _) = await call('init', {},
          reply: () => http.Response(jsonEncode({'error': 'not_found',
              'message': 'project not found'}), 404));
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'not_found');
      expect(errorOf(result)['message'], isNot(contains('Missing project ref')));
      expect(yamlOf(dir), isNull);
    });

    test('D4 refuses a foreign base_url before the token leaves', () async {
      final (:result, :dir, :requests) =
          await call('init', {'base_url': 'https://evil.example'});
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'untrusted_base_url');
      expect(requests, isEmpty);
      expect(yamlOf(dir), isNull);
    });

    test('an explicit ref or a config on disk sends nothing', () async {
      final named = await call('init', {'workspace': 'acme', 'project': 'web'});
      expect(named.result.isError, isNot(true));
      expect(named.requests, isEmpty);
      final kept = await call('init', {}, config: 'projectId: p1\n');
      expect(kept.result.isError, isNot(true));
      expect(kept.requests, isEmpty);
      expect(yamlOf(kept.dir), 'projectId: p1\n');
    });
  });

  group('pull', () {
    ({Directory dir, McpDeps deps}) pullProject({
      String config = 'projectId: proj_abc\nformat: arb\noutput: l10n\n',
      Map<String, String> served = const {'arb/app_en.arb': '{"hi":"Hi"}'},
      Map<String, Object?> extraBody = const {},
      Map<String, String> files = const {},
    }) => project(
          config: config,
          files: files,
          httpClient: MockClient((_) async => http.Response(
                jsonEncode({
                  'project': 'proj_abc',
                  'version': '2026.09.13.1',
                  'baseCode': 'en',
                  'formats': ['arb'],
                  'files': served,
                  ...extraBody,
                }),
                200,
              )),
        );

    test('writes the files and reports paths, never contents', () async {
      final fixture = pullProject();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('pull');
      expect(result.isError, isNot(true));
      final content = result.structuredContent!;
      expect(content['version'], '2026.09.13.1');
      expect(content['destination'], 'directory');
      expect(content['files_written'], [
        p.join(fixture.dir.path, 'l10n', 'app_en.arb'),
      ]);
      expect(File(p.join(fixture.dir.path, 'l10n', 'app_en.arb'))
          .readAsStringSync(), '{"hi":"Hi"}');
      expect(jsonEncode(content), isNot(contains('Hi')),
          reason: 'pull reports paths; contents stay out of the payload');
    });

    test('dry_run reports what it would write without writing it', () async {
      final fixture = pullProject();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('pull', {'dry_run': true});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['files_written'], isEmpty);
      expect(result.structuredContent!['files_planned'], isNotEmpty);
      expect(File(p.join(fixture.dir.path, 'l10n', 'app_en.arb')).existsSync(),
          isFalse);
    });

    test('key_policy travels to the merge, and union is the default', () async {
      // The two arms of D16 over the same catalog: `union` keeps the key only
      // the server has, `local_owns` reads it as locally deleted.
      const local = '{"sourceLanguage":"en","strings":{"Kept":{}}}';
      const servedCatalog = '{"sourceLanguage":"en","strings":'
          '{"Kept":{},"OnlyOnServer":{}}}';
      Future<String> pullWith(Map<String, Object?> args,
          {Map<String, String> logs = const {}, String? expectPolicy}) async {
        final fixture = pullProject(
          config: 'projectId: proj_abc\nformat: xcstrings\n'
              'catalog: Localizable.xcstrings\n',
          served: {'xcstrings/Localizable.xcstrings': servedCatalog},
          files: {'Localizable.xcstrings': local, ...logs},
        );
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call('pull', args);
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['key_policy'],
            expectPolicy ?? args['key_policy'] ?? 'union');
        return File(p.join(fixture.dir.path, 'Localizable.xcstrings'))
            .readAsStringSync();
      }

      expect(await pullWith(const {}), contains('OnlyOnServer'));
      expect(await pullWith(const {'key_policy': 'union'}),
          contains('OnlyOnServer'));
      expect(await pullWith(const {'key_policy': 'local_owns'}),
          isNot(contains('OnlyOnServer')));

      // The other half of D16: a recorded sync of this catalog makes
      // local_owns the default, a record of another catalog does not, and an
      // explicit argument still wins.
      String syncLog(String catalog) => jsonEncode({
        'operation_id': 'op_s', 'family': 'file-first', 'catalog': catalog,
        'key_policy': 'local_owns', 'requests': <Object?>[],
      });
      const recorded = {'.easyi18n/operations/op_s.json': ''};
      expect(
        await pullWith(const {}, expectPolicy: 'local_owns', logs: {
          for (final k in recorded.keys) k: syncLog('Localizable.xcstrings'),
        }),
        isNot(contains('OnlyOnServer')),
      );
      expect(
        await pullWith(const {}, logs: {
          for (final k in recorded.keys) k: syncLog('Other.xcstrings'),
        }),
        contains('OnlyOnServer'),
      );
      expect(
        await pullWith(const {'key_policy': 'union'}, logs: {
          for (final k in recorded.keys) k: syncLog('Localizable.xcstrings'),
        }),
        contains('OnlyOnServer'),
      );
    });

    test('catalogs: each key goes to its file and the unplaced one is reported (#590)',
        () async {
      const config = 'projectId: proj_abc\nformat: xcstrings\ncatalogs:\n'
          '  - A.xcstrings\n  - B.xcstrings\n';
      const servedCatalog = '{"sourceLanguage":"en","strings":'
          '{"InA":{},"InB":{},"OnlyOnServer":{}}}';
      Future<CallToolResult> pullWith(Map<String, String> logs) async {
        final fixture = pullProject(
          config: config,
          served: {'xcstrings/Localizable.xcstrings': servedCatalog},
          files: {
            'A.xcstrings': '{"sourceLanguage":"en","strings":{"InA":{}}}',
            'B.xcstrings': '{"sourceLanguage":"en","strings":{"InB":{}}}',
            ...logs,
          },
        );
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call('pull');
        expect(result.isError, isNot(true));
        for (final name in ['A', 'B']) {
          expect(File(p.join(fixture.dir.path, '$name.xcstrings')).readAsStringSync(),
              isNot(contains('OnlyOnServer')));
        }
        expect(result.structuredContent!['files_written'],
            [for (final n in ['A', 'B']) p.join(fixture.dir.path, '$n.xcstrings')]);
        return result;
      }

      final plain = await pullWith(const {});
      expect(plain.structuredContent!['unplaced_keys'], ['OnlyOnServer']);
      expect(plain.structuredContent!['key_policy'], 'union');

      String syncLog(List<String> catalogs) => jsonEncode({
        'operation_id': 'op_s', 'family': 'file-first', 'catalogs': catalogs,
        'key_policy': 'local_owns', 'requests': <Object?>[],
      });
      const log = '.easyi18n/operations/op_s.json';
      expect((await pullWith({log: syncLog(['A.xcstrings', 'B.xcstrings'])}))
          .structuredContent!['key_policy'], 'local_owns');
      expect((await pullWith({log: syncLog(['A.xcstrings'])}))
          .structuredContent!['key_policy'], 'union',
          reason: 'a record of another list is not this project\'s');
    });

    test('require_complete on a Mode B project is refused, not answered',
        () async {
      final fixture = pullProject(
        config: 'projectId: proj_abc\nformat: arb\noutput: l10n\nmode: b\n',
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('pull', {'require_complete': true});
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'require_complete_unsupported');
      expect(File(p.join(fixture.dir.path, 'l10n', 'app_en.arb')).existsSync(),
          isFalse, reason: 'the refusal lands before anything is written');
    });

    test('require_complete gates a Mode A pull on the version coverage',
        () async {
      final fixture = pullProject(
        config: 'projectId: proj_abc\nformat: arb\noutput: l10n\nmode: a\n',
        extraBody: {
          'coverageBasis': 'skip',
          'coverage': {
            'es': {'translated': 3, 'total': 5},
          },
        },
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final incomplete = await harness.call('pull', {'require_complete': true});
      expect(incomplete.isError, isTrue);
      expect(errorOf(incomplete)['message'], contains('incomplete'));
      // The actionable half of the refusal: which language, and how many keys.
      // It used to go only to stderr, which no MCP client reads.
      expect(errorOf(incomplete)['incomplete'], [
        {'lang': 'es', 'untranslated': 2, 'total': 5},
      ]);
      // The negative control: without the flag the same pull succeeds.
      final plain = await harness.call('pull');
      expect(plain.isError, isNot(true));

      // An empty `lang` is no filter on the wire, so it gates the whole
      // version rather than read as a base-language request.
      for (final blank in ['', '  ']) {
        final empty = await harness
            .call('pull', {'lang': blank, 'require_complete': true});
        expect(errorOf(empty)['incomplete'], [
          {'lang': 'es', 'untranslated': 2, 'total': 5},
        ], reason: 'lang: ${jsonEncode(blank)}');
      }
    });

    test('the incomplete detail is cut by the output budget, not dropped',
        () async {
      // 2000 languages serialize past 32 KiB, so this measures how the detail
      // leaves the budget: the list is truncated and flagged, and the
      // machine-readable half of the error survives intact.
      final coverage = {
        for (var i = 0; i < 2000; i++)
          'l${i.toString().padLeft(4, '0')}': {'translated': 3, 'total': 5},
      };
      final fixture = pullProject(
        config: 'projectId: proj_abc\nformat: arb\noutput: l10n\nmode: a\n',
        extraBody: {'coverageBasis': 'skip', 'coverage': coverage},
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('pull', {'require_complete': true});
      expect(result.isError, isTrue);
      final content = result.structuredContent!;
      expect(utf8.encode(jsonEncode(content)).length,
          lessThanOrEqualTo(32 * 1024));
      expect(content['truncated'], isTrue);
      expect(errorOf(result)['code'], 'cli_error');
      // A message under the 200-character cap is not marked as clipped: the
      // marker is a claim about the message and the reader is a model.
      expect(errorOf(result)['message'], isNot(contains('…')));
      expect(errorOf(result)['message'], endsWith('publish again.'));
      final listed = errorOf(result)['incomplete'] as List;
      expect(listed, isNotEmpty);
      expect(listed.length, lessThan(2000));
      expect(listed.first, containsPair('lang', 'l0000'));
    });

    test('D4 refuses a foreign host before the token is sent', () async {
      final fixture = pullProject(
        config: 'projectId: proj_abc\nbaseUrl: https://evil.example\n',
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('pull');
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'untrusted_base_url');
    });

    test('D4 refuses plaintext http to the production host', () async {
      final fixture = pullProject(
        config: 'projectId: proj_abc\nbaseUrl: http://api.easyi18n.com\n',
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('pull');
      expect(result.isError, isTrue);
      expect(errorOf(result)['message'], contains('plaintext'));
    });
  });

  group('apply', () {
    ({Directory dir, McpDeps deps}) applyProject({
      String config = 'projectId: proj_abc\n',
      Map<String, String> files = const {
        'lib/app.dart': "void f(c) { c.tr('Colour'); }\n",
      },
      List<Map<String, Object?>> changes = const [
        {'key': 'colour', 'oldSource': 'Colour', 'newSource': 'Color'},
      ],
    }) => project(
          config: config,
          files: files,
          httpClient: MockClient(
            (_) async => http.Response(jsonEncode({'changes': changes}), 200),
          ),
        );

    test('previews the rewrites without touching the file', () async {
      final fixture = applyProject();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('apply');
      expect(result.isError, isNot(true));
      final content = result.structuredContent!;
      expect(content['write'], isFalse);
      expect(content['files_changed'], 0);
      expect((content['edits'] as List).single, containsPair('new', 'Color'));
      expect(File(p.join(fixture.dir.path, 'lib', 'app.dart'))
          .readAsStringSync(), contains("tr('Colour')"));
    });

    test('write:true rewrites the call site', () async {
      final fixture = applyProject();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('apply', {'write': true});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['files_changed'], 1);
      expect(File(p.join(fixture.dir.path, 'lib', 'app.dart'))
          .readAsStringSync(), contains("tr('Color')"));
    });

    test('write:true never leaves the project root', () async {
      // The caller of a tool is a model, and `p.join` lets an absolute second
      // argument win: without the containment this call rewrote a file the
      // project does not own and answered `files_changed: 1`.
      final fixture = applyProject();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final outside = Directory.systemTemp.createTempSync('mcp_outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      final victim = File(p.join(outside.path, 'other.dart'))
        ..writeAsStringSync("void f(c) { c.tr('Colour'); }\n");
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final absolute = await harness
          .call('apply', {'write': true, 'source_dir': outside.path});
      expect(absolute.isError, isTrue);
      expect(errorOf(absolute)['code'], 'source_dir_outside_project');
      expect(victim.readAsStringSync(), contains("tr('Colour')"),
          reason: 'the file outside the root is untouched');
      final relative = await harness.call('apply', {
        'write': true,
        'source_dir': p.join('..', p.basename(outside.path)),
      });
      expect(errorOf(relative)['code'], 'source_dir_outside_project');
      expect(victim.readAsStringSync(), contains("tr('Colour')"));
    });

    test('the project root itself is a source_dir the guard allows', () async {
      final fixture = applyProject();
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result =
          await harness.call('apply', {'write': true, 'source_dir': '.'});
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['files_changed'], 1);
      expect(File(p.join(fixture.dir.path, 'lib', 'app.dart'))
          .readAsStringSync(), contains("tr('Color')"));
    });

    test('the containment answers before the family check', () async {
      // Graded after it, a file-first project with an escaping path answers
      // `wrong_family` and sends the agent to `pull` with the path unfixed.
      final fixture = applyProject(
        config: 'projectId: proj_abc\nformat: xcstrings\ncatalog: c.xcstrings\n',
        files: {'c.xcstrings': '{"sourceLanguage":"en","strings":{}}'},
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('apply', {'source_dir': '/etc'});
      expect(errorOf(result)['code'], 'source_dir_outside_project');
    });

    test('on a file-first project it answers wrong_family, naming pull',
        () async {
      final fixture = applyProject(
        config: 'projectId: proj_abc\nformat: xcstrings\n'
            'catalog: Localizable.xcstrings\n',
        files: {'Localizable.xcstrings': '{"sourceLanguage":"en","strings":{}}'},
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('apply');
      expect(result.isError, isTrue);
      final error = errorOf(result);
      expect(error['code'], 'wrong_family');
      expect(error['family'], 'file-first');
      expect(error['use_instead'], 'pull');
    });

    test('D4 refuses a foreign host before the token is sent', () async {
      final fixture = applyProject(
        config: 'projectId: proj_abc\nbaseUrl: https://evil.example\n',
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('apply');
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'untrusted_base_url');
    });

    test('D4 refuses plaintext http to the production host', () async {
      final fixture = applyProject(
        config: 'projectId: proj_abc\nbaseUrl: http://api.easyi18n.com\n',
      );
      addTearDown(() => fixture.dir.deleteSync(recursive: true));
      final harness = await McpHarness.start(fixture.deps);
      addTearDown(harness.shutdown);

      final result = await harness.call('apply');
      expect(result.isError, isTrue);
      expect(errorOf(result)['message'], contains('plaintext'));
    });
  });
}
