import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer errOut;
  late CliLogger logger;
  final requests = <http.Request>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_sync');
    out = StringBuffer();
    errOut = StringBuffer();
    logger = CliLogger(out: out, err: errOut);
    requests.clear();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig() {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync(
      'projectId: p1\n'
      'format: xcstrings\n'
      'catalog: App/Localizable.xcstrings\n',
    );
    return path;
  }

  // Xcode-style local catalog (the merge preserves it as the structural
  // truth; a non-canonical local would be normalized on the first pull).
  File writeCatalog(
      [String content = '{\n'
          '  "sourceLanguage" : "es",\n'
          '  "strings" : {\n'
          '    "Hola" : {\n'
          '\n'
          '    }\n'
          '  },\n'
          '  "version" : "1.0"\n'
          '}']) {
    final f = File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return f;
  }

  Map<String, Object?> syncBody({
    bool dryRun = false,
    int created = 0,
    int updatedTranslations = 0,
    int estimatedCredits = 0,
    String? trackingToken,
    List<Map<String, Object?>> exhausted = const [],
    List<Map<String, Object?>> failedEntries = const [],
    List<Map<String, Object?>> conflicts = const [],
    int? conflictsTotal,
    String onConflict = 'server',
    bool accepted = true,
    int? notInCode,
    int? pendingSkipped,
    List<String> targetLangs = const ['en'],
    List<String>? fillableLangs,
    List<Map<String, Object?>> diagnostics = const [],
    List<Map<String, Object?>>? diagnosticsOmitted,
    String baseCode = 'es',
  }) => {
    'dryRun': dryRun,
    'format': 'xcstrings',
    'baseCode': baseCode,
    'targetLangs': targetLangs,
    'fillableLangs': fillableLangs ?? targetLangs,
    'created': created,
    'updatedSources': 0,
    'matchedSources': 0,
    'updatedTranslations': updatedTranslations,
    'unchangedTranslations': 0,
    'disabledOrphans': 0,
    'reenabled': 0,
    'notInCode': ?notInCode,
    'failedEntries': failedEntries,
    'exhausted': exhausted,
    'conflicts': conflicts,
    'conflictsTotal': conflictsTotal ?? conflicts.length,
    'onConflict': onConflict,
    'diagnostics': diagnostics,
    'diagnosticsOmitted': ?diagnosticsOmitted,
    'trackingToken': trackingToken,
    'estimatedCredits': estimatedCredits,
    'balance': 500000,
    'accepted': accepted,
    'pendingSkipped': ?pendingSkipped,
  };

  CommandRunner<int> runnerWith(
    Map<String, Object?> Function(http.Request req, int syncCalls) onSync, {
    Map<String, Object?> Function(int polls)? onSummary,
    int publishStatus = 201,
    Map<String, Object?>? publishBody,
    List<String> metaFormats = const ['xcstrings'],
    int metaStatus = 200,
    String metaBaseCode = 'es',
    String pulledCatalog =
        '{"sourceLanguage":"es","strings":{"Hola":{"localizations":{"en":'
        '{"stringUnit":{"state":"translated","value":"Hello"}}}}}}',
    // What the pull serves instead of the one catalog, for a per-locale format.
    Map<String, String>? pulledFiles,
    List<Map<String, Object?>> metaLanguages = const [],
    Duration? pollTimeout,
    List<Duration>? waits,
  }) {
    var syncCalls = 0;
    var polls = 0;
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        if (path.endsWith('/meta')) {
          return http.Response(
            jsonEncode(
              metaStatus == 200
                  ? {
                      'baseCode': metaBaseCode,
                      'mode': null,
                      'currentVersionId': '2026.08.11.1',
                      'languages': metaLanguages,
                      'formats': metaFormats,
                      'outputFormatsApiVersion': 1,
                    }
                  : {'error': 'forbidden'},
            ),
            metaStatus,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/sync')) {
          syncCalls++;
          return http.Response(
            jsonEncode(onSync(req, syncCalls)),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/translations') &&
            req.url.queryParameters.containsKey('trackingToken')) {
          polls++;
          final body = (onSummary ?? (_) => {
                'status': 'done',
                'summary': {
                  'total': 1,
                  'translated': 1,
                  'pending': 0,
                  'failed': 0,
                },
              })(polls);
          return http.Response(
            jsonEncode(body),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/publish')) {
          return http.Response(
            jsonEncode(
              publishBody ?? {'versionId': '2026.08.11.1', 'keyCount': 2},
            ),
            publishStatus,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/translations')) {
          return http.Response(
            jsonEncode({
              'project': 'p1',
              'version': '2026.08.11.1',
              'baseCode': metaBaseCode,
              'formats': metaFormats,
              'files': pulledFiles ??
                  {'xcstrings/Localizable.xcstrings': pulledCatalog},
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{"error":"not_found"}', 404);
      }),
    );
    return CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(
        SyncCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
          wait: (d) async => waits?.add(d),
          pollTimeout: pollTimeout,
          random: Random(7),
        ),
      );
  }

  test('happy path: preview, sync, poll, publish skip+identical, write back',
      () async {
    final catalog = writeCatalog();
    final code = await runnerWith((req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          created: 2,
          updatedTranslations: 1,
          estimatedCredits: 12000,
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        )).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    final paths = [for (final r in requests) r.url.path];
    expect(paths.where((x) => x.endsWith('/sync')), hasLength(2));
    // The format preflight (#530) reads /meta before anything is uploaded,
    // and the first thing sent to /sync is still the priced dry run.
    expect(paths.first, endsWith('/meta'));
    expect(
      requests
          .firstWhere((r) => r.url.path.endsWith('/sync'))
          .url
          .queryParameters['dryRun'],
      'true',
    );

    final publish = requests.firstWhere((r) => r.url.path.endsWith('/publish'));
    final publishBody = jsonDecode(publish.body) as Map<String, dynamic>;
    expect(publishBody['incompleteMode'], 'skip');
    expect(publishBody['skipIfIdentical'], true);

    // The served translation was MERGED into the local catalog (structure and
    // style stay local; only the localization lands), whatever file name the
    // server used.
    final content = catalog.readAsStringSync();
    expect(content, contains('"value" : "Hello"'));
    expect(content, contains('"sourceLanguage" : "es"'));
    expect(out.toString(), contains('Sync complete'));
  });

  test(
    'sync\'s write-back replaces a local base edit WITHOUT the pull-side '
    'conflict line: the server already reported that pair (#646)',
    () async {
      // The transition is real: the local base text differs from the served
      // one and the merge applies the served one. The report belongs to the
      // server's conflicts channel (#671), which sync already prints — a
      // second line from the merge would name every such pair twice.
      final catalog = writeCatalog(
        '{"sourceLanguage":"es","strings":{"Hola":{"localizations":{"es":'
        '{"stringUnit":{"state":"translated","value":"EDITADO en Xcode"}}}}}}',
      );
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          updatedTranslations: 1,
        ),
        pulledCatalog:
            '{"sourceLanguage":"es","strings":{"Hola":{"localizations":{"es":'
            '{"stringUnit":{"state":"translated","value":"Frase del server"}}'
            '}}}}',
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      // Applied — the fixture mounted the replacement, so the absence below
      // is an assertion about the gate, not about an empty run.
      final content = catalog.readAsStringSync();
      expect(content, contains('Frase del server'));
      expect(content, isNot(contains('EDITADO en Xcode')));
      expect(errOut.toString(), isNot(contains('replaced your catalog')));
      expect(errOut.toString(), isNot(contains('would replace')));
    },
  );

  test('--max-credits aborts before the real sync', () async {
    writeCatalog();
    // A CliException, which the executable renders as the same `error:` line
    // on stderr and the same exit 1 — and which `--json` can serve as a
    // record. A bare `return 1` left a JSON consumer with nothing to read.
    await expectLater(
      runnerWith((req, calls) =>
              syncBody(dryRun: true, created: 5, estimatedCredits: 900000))
          .run(
              ['--config', writeConfig(), 'sync', '--yes', '--max-credits', '1']),
      throwsA(isA<CliException>()
          .having((e) => e.message, 'message', contains('exceeds --max-credits'))
          .having((e) => e.exitCode, 'exitCode', 1)
          .having((e) => e.code, 'code', 'budget_exceeded')),
    );
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(1));
  });

  group('declared source layout is invariant across path representations', () {
    group('CLI cwd alias', () {
      late Directory snapshotDir;
      late String snapshot;

      // Compile once: each start from source compiles the CLI, and eight of
      // them on a loaded runner passed the 30 s budget (#2126).
      setUpAll(() async {
        snapshotDir = Directory.systemTemp.createTempSync('easyi18n_cli_sync_alias');
        snapshot = p.join(snapshotDir.path, 'easyi18n.dill');
        final compile = await Process.run(Platform.resolvedExecutable, [
          'compile', 'kernel', 'bin/easyi18n.dart', '-o', snapshot,
        ], environment: {'CI': 'true', 'DART_SUPPRESS_ANALYTICS': 'true'});
        expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
      });
      tearDownAll(() => snapshotDir.deleteSync(recursive: true));

      for (final source in ['en.json', 'app.json']) {
        for (final other in ['es.json', 'other.json']) {
          test('keeps $source and $other in base-tree', () async {
            final input = Directory(p.join(dir.path, 'catalogs/group'))..createSync(recursive: true);
            for (final name in [source, other]) {
              File(p.join(input.path, name)).writeAsStringSync('{"hello":"Hello"}');
            }
            Link(p.join(dir.path, 'en')).createSync(p.join(dir.path, 'catalogs'));
            final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            addTearDown(() => server.close(force: true));
            final posts = <String>[];
            server.listen((req) async {
              if (req.method == 'POST') posts.add(req.uri.path);
              req.response.headers.contentType = ContentType.json;
              req.response.write(jsonEncode(req.uri.path.endsWith('/meta')
                  ? {'baseCode': 'en', 'languages': [], 'formats': ['json'], 'outputFormatsApiVersion': 1}
                  : syncBody(dryRun: true)));
              await req.response.close();
            });
            final config = p.join(dir.path, 'en/group/easyi18n.yaml');
            File(config).writeAsStringSync('projectId: p1\nformat: json\nsource: $source\n'
                'sourceRoot: .\nsourceLayout: base-tree\nbaseUrl: http://127.0.0.1:${server.port}\n');
            for (final explicit in [true, false]) {
              final result = await Process.run(Platform.resolvedExecutable, [
                '--disable-dart-dev', snapshot, '--json',
                if (explicit) ...['--config', config], 'sync', '--dry-run', '--token', 'eik_test',
              ], workingDirectory: p.dirname(config));
              expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
              final error = (jsonDecode(result.stdout as String) as Map)['error'] as Map;
              expect(error['code'], 'several_files_per_locale');
              expect(error['message'], allOf(contains(source), contains(other)));
              expect(posts, isEmpty);
            }
          });
        }
      }
    });
    for (final (layout, base, sourceName, otherName, selected) in [
      ('base-tree', 'en', 'en.json', 'es.json', ['en.json', 'es.json']),
      ('base-tree', 'en', 'en.json', 'other.json', ['en.json', 'other.json']),
      ('base-tree', 'en', 'app.json', 'common.json', ['app.json', 'common.json']),
      ('base-tree', 'en', 'app.json', null, ['app.json']),
      ('locale-files', 'en', 'en.json', 'es.json', ['en.json']),
      ('locale-files', 'pt-BR', 'PT_br.JSON', 'es.json', ['PT_br.JSON']),
    ]) {
      for (final nested in [false, true]) {
        for (final rootAlias in [false, true]) {
          for (final sourceAlias in [false, true]) {
            for (final relative in [false, true]) {
              test('$layout $sourceName/$otherName nested=$nested '
                  'rootAlias=$rootAlias sourceAlias=$sourceAlias relative=$relative', () async {
                final tree = Directory(p.join(dir.path, 'catalogs/group'))
                  ..createSync(recursive: true);
                final identities = <String, File>{
                  for (final name in {sourceName, ?otherName})
                    name: File(p.join(tree.path, name))..writeAsStringSync('{"hello":"Hello"}'),
                };
                Link(p.join(dir.path, 'en')).createSync(p.join(dir.path, 'catalogs'));
                Link(p.join(tree.path, 'copy.json')).createSync(identities[sourceName]!.path);
                final input = p.join(dir.path, rootAlias ? 'en/group' : 'catalogs/group');
                final configDir = nested ? input : dir.path;
                final config = p.join(configDir, 'easyi18n.yaml');
                File(config).writeAsStringSync('projectId: p1\nformat: json\n'
                    'source: ${p.relative(p.join(input, sourceAlias ? 'copy.json' : sourceName), from: configDir)}\n'
                    'sourceRoot: ${p.relative(input, from: configDir)}\nsourceLayout: $layout\n');
                final args = ['--config', relative ? p.relative(config) : config, 'sync', '--dry-run'];
                final command = runnerWith((_, _) => syncBody(dryRun: true, baseCode: base),
                    metaFormats: ['json'], metaBaseCode: base);
                if (selected.length == 1) {
                  expect(await command.run(args), 0);
                  final post = requests.singleWhere((r) => r.method == 'POST');
                  expect(post.url.path, '/v1/projects/p1/sync');
                  expect((jsonDecode(post.body) as Map)['contentBase64'],
                      base64Encode(identities[sourceName]!.readAsBytesSync()));
                } else {
                  await expectLater(command.run(args), throwsA(isA<CliException>()
                      .having((e) => e.code, 'code', 'several_files_per_locale')
                      .having((e) => [e.details['source'], ...e.details['files'] as List]
                          .map((name) => File(p.join(configDir, name as String)).resolveSymbolicLinksSync()),
                          'physical input identities', unorderedEquals([
                            for (final name in selected) identities[name]!.resolveSymbolicLinksSync(),
                          ]))));
                  expect(requests.where((r) => r.method == 'POST'), isEmpty);
                }
              });
            }
          }
        }
      }
    }

    for (final declaration in ['', 'sourceRoot: .\n', 'sourceLayout: locale-files\n',
      'sourceRoot: .\nsourceLayout: guessed\n']) {
      test('incomplete or invalid declaration refuses [$declaration]', () async {
        File(p.join(dir.path, 'en.json')).writeAsStringSync('{}');
        File(p.join(dir.path, 'es.json')).writeAsStringSync('{}');
        final config = p.join(dir.path, 'easyi18n.yaml');
        File(config).writeAsStringSync('projectId: p1\nformat: json\nsource: en.json\n$declaration');
        await expectLater(runnerWith((_, _) => syncBody(dryRun: true),
            metaFormats: ['json'], metaBaseCode: 'en').run(['--config', config, 'sync', '--dry-run']),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'catalog_scope_unknown')
                .having((e) => e.details['files'], 'observed JSON', unorderedEquals(['en.json', 'es.json']))
                .having((e) => e.details['source'], 'source', 'en.json')));
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
      });
    }

    for (final declaration in ['', 'sourceRoot: ""\n', 'sourceLayout: locale-files\n']) {
      test('an undeclared sourceRoot lists the folder of source: and walks '
          'nothing else [$declaration]', () async {
        for (final name in ['en.json', 'es.json', 'package.json',
          'node_modules/pkg/package.json', 'node_modules/pkg/dist/en.json']) {
          File(p.join(dir.path, name))
            ..createSync(recursive: true)
            ..writeAsStringSync('{}');
        }
        final config = p.join(dir.path, 'easyi18n.yaml');
        File(config).writeAsStringSync('projectId: p1\nformat: json\nsource: en.json\n$declaration');
        await expectLater(runnerWith((_, _) => syncBody(dryRun: true),
            metaFormats: ['json'], metaBaseCode: 'en').run(['--config', config, 'sync', '--dry-run']),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'catalog_scope_unknown')
                .having((e) => e.details['fields'], 'fields', contains('sourceRoot'))
                .having((e) => e.details['files'], 'observed JSON',
                    unorderedEquals(['en.json', 'es.json', 'package.json']))));
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
      });
    }
  });

  test('an android project uploads values-es with its lang, names the '
      'language files it leaves out, and pulls into res/ (#2285)', () async {
    final config = p.join(dir.path, 'easyi18n.yaml');
    File(config).writeAsStringSync('projectId: p1\nmode: a\n'
        'format: android_xml\noutput: res\nsource: res/values/strings.xml\n');
    const base = '<resources><string name="hi">Hi</string></resources>\n';
    for (final (dir_, body) in [('values', base),
        ('values-es', '<resources><string name="hi">Hola</string></resources>'),
        ('values-fr', '<resources/>')]) {
      File(p.join(dir.path, 'res', dir_, 'strings.xml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }
    const servedEs = '<resources><string name="hi">Hola</string></resources>';
    final code = await runnerWith(
      (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          baseCode: 'en', targetLangs: const ['es']),
      metaFormats: const ['android_xml'], metaBaseCode: 'en',
      metaLanguages: const [
        {'code': 'en', 'isBase': true}, {'code': 'es', 'isBase': false},
      ],
      pulledFiles: const {
        'android_xml/values/strings.xml': '<resources>server</resources>',
        'android_xml/values-es/strings.xml': servedEs,
      },
    ).run(['--config', config, 'sync', '--yes']);
    expect(code, 0);
    final syncs = [
      for (final r in requests)
        if (r.url.path.endsWith('/sync'))
          (jsonDecode(r.body) as Map)['fileName'] as String,
    ];
    expect(syncs, ['strings.xml', 'strings.xml', 'values-es/strings.xml']);
    expect(jsonDecode(requests.lastWhere((r) => r.url.path.endsWith('/sync'))
        .body)['lang'], 'es');
    expect(errOut.toString(), contains('Not uploading values-fr/strings.xml '
        '(fr is not a target language of the project).'));
    expect(File(p.join(dir.path, 'res', 'values', 'strings.xml'))
        .readAsStringSync(), base);
    expect(File(p.join(dir.path, 'res', 'values-es', 'strings.xml'))
        .readAsStringSync(), servedEs);
  });

  group('a per-locale project (source:, one JSON file per locale)', () {
    String writeWebConfig() {
      final path = p.join(dir.path, 'easyi18n.yaml');
      File(path).writeAsStringSync('projectId: p1\nmode: a\nformat: json\n'
          'output: public/i18n\nsource: public/i18n/en.json\nsourceRoot: public/i18n\nsourceLayout: locale-files\n');
      File(p.join(dir.path, 'public', 'i18n', 'en.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"hello": "Hello"}');
      return path;
    }

    const pulledFiles = {
      'json/en.json': '{"hello":"Hello"}',
      'json/es.json': '{"hello":"Hola"}',
    };

    CommandRunner<int> webRunner({String baseCode = 'en',
            Map<String, String> files = pulledFiles}) =>
        runnerWith(
        (req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
            created: 1, estimatedCredits: 500, trackingToken: 'job_1',
            baseCode: 'en', targetLangs: const ['es', 'fr'],
            // The row the route answers for every target of a base-only
            // file, as an ephemeral stack sent it: one language with pairs
            // to fill and one with none, which are two lines for a catalog.
            diagnostics: const [
              {
                'code': 'LANG_NOT_IN_FILE', 'severity': 'info', 'field': 'es',
                'message': "the project configures 'es' but the file carries "
                    'no localization for it',
                'plannedPairs': 1,
              },
              {
                'code': 'LANG_NOT_IN_FILE', 'severity': 'info', 'field': 'fr',
                'message': "the project configures 'fr' but the file carries "
                    'no localization for it',
                'plannedPairs': 0,
              },
            ]),
        metaFormats: const ['json'],
        metaBaseCode: baseCode,
        pulledFiles: files);

    test('a real sync uploads the base file, publishes, and writes the other '
        'locales into output:', () async {
      final config = writeWebConfig();
      expect(await webRunner().run(['--config', config, 'sync', '--yes']), 0);
      expect(
        [for (final r in requests) r.url.path.split('/').last],
        ['meta', 'meta', 'sync', 'sync', 'translations', 'publish', 'translations'],
      );
      final i18n = p.join(dir.path, 'public', 'i18n');
      // The base file is the developer's: never the server's render of it.
      expect(File(p.join(i18n, 'en.json')).readAsStringSync(),
          '{"hello": "Hello"}');
      expect(File(p.join(i18n, 'es.json')).readAsStringSync(),
          pulledFiles['json/es.json']);
      // Recorded like any full pull: `doctor` and the next prune read it.
      final state = CliState.load(CliState.fileFor(config));
      expect(state.files, ['es.json']);
      expect(state.output, 'public/i18n');
      for (final sync in requests.where((r) => r.url.path.endsWith('/sync'))) {
        expect((jsonDecode(sync.body) as Map).containsKey('pulledAt'), isFalse);
      }
      expect(out.toString(), contains('Sync complete (version 2026.08.11.1).'));
      // No catalog was read back, so the run claims nothing about its gaps;
      // and a base file never carries the targets, so they are not reported
      // as missing from it on every run.
      expect(errOut.toString(), isEmpty);
      expect(out.toString(), contains('Target languages (2): es, fr'));
      expect(out.toString(), isNot(contains('Not in your catalog')));
      // Nor through the printer of the rows no dedicated line rendered.
      expect(out.toString(), isNot(contains('LANG_NOT_IN_FILE')));
    });

    test('a second sync still sends no pulledAt: the first one stamped a '
        'snapshot the base file never came from', () async {
      final config = writeWebConfig();
      await webRunner().run(['--config', config, 'sync', '--yes']);
      expect(CliState.load(CliState.fileFor(config)).snapshotAt, isNotNull);
      requests.clear();
      expect(await webRunner().run(['--config', config, 'sync', '--yes']), 0);
      final syncs = requests.where((r) => r.url.path.endsWith('/sync'));
      expect(syncs, hasLength(2));
      for (final sync in syncs) {
        expect((jsonDecode(sync.body) as Map).containsKey('pulledAt'), isFalse);
      }
    });

    test('a catalog project is not stopped by the record of a directory it '
        'no longer writes (#2095)', () async {
      // Its write-back lands on the catalog and merges: nothing under
      // `output:` is replaced, whatever an older pull recorded there.
      writeCatalog();
      final config = writeConfig();
      File(p.join(dir.path, 'lib', 'l10n', 'app_es.arb'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"hi":"Buenas"}');
      const CliState(format: 'arb', output: 'lib/l10n', files: [
        'app_es.arb',
      ], digests: {
        'app_es.arb': 'sha256:0000',
      }).save(CliState.fileFor(config));

      expect(
          await runnerWith((req, calls) => syncBody(
                  dryRun: req.url.queryParameters['dryRun'] == 'true'))
              .run(['--config', config, 'sync', '--yes']),
          0);
    });

    group('a locale file changed since the pull that wrote it (#2095)', () {
      const edited = '{"hello":"Buenas (edited by hand)"}';
      late String config;
      late File es;

      setUp(() async {
        config = writeWebConfig();
        es = File(p.join(dir.path, 'public', 'i18n', 'es.json'));
        await webRunner().run(['--config', config, 'sync', '--yes']);
        requests.clear();
      });

      for (final flags in [
        ['--yes'],
        ['--dry-run'],
        ['--yes', '--no-publish'],
      ]) {
        test('sync ${flags.join(' ')} stops before any request and names it',
            () async {
          es.writeAsStringSync(edited);
          await expectLater(
            webRunner().run(['--config', config, 'sync', ...flags]),
            throwsA(isA<CliException>()
                .having((e) => e.code, 'code', 'edited_targets')
                .having((e) => e.exitCode, 'exitCode', 1)
                .having((e) => e.details['edited'], 'edited', [
                  {'file': 'public/i18n/es.json'},
                ])
                .having((e) => e.message, 'message',
                    allOf(contains('public/i18n/es.json'),
                        contains('Nothing was uploaded')))),
          );
          expect(requests, isEmpty);
          expect(es.readAsStringSync(), edited);
        });
      }

      test('--force uploads, replaces it, and the next sync runs', () async {
        es.writeAsStringSync(edited);
        expect(
            await webRunner()
                .run(['--config', config, 'sync', '--yes', '--force']),
            0);
        expect(es.readAsStringSync(), pulledFiles['json/es.json']);
        expect(requests.where((r) => r.url.path.endsWith('/sync')),
            hasLength(2));

        expect(await webRunner().run(['--config', config, 'sync', '--yes']), 0);
      });

      test('a reformatted locale file does not stop it', () async {
        es.writeAsStringSync('{\n  "hello": "Hola"\n}\n');
        expect(await webRunner().run(['--config', config, 'sync', '--yes']), 0);
      });

      test('the base file a pull wrote before `source:` named it is the '
          'catalog, not a target', () async {
        // A project that pulled before it declared `source:` holds a digest
        // of its base file, and editing that file is how a sync starts.
        final file = CliState.fileFor(config);
        final record = CliState.load(file);
        CliState(
          format: record.format,
          output: record.output,
          files: [...?record.files, 'en.json'],
          digests: {
            ...?record.digests,
            'en.json': contentDigest('{"hello":"Hello"}'),
          },
        ).save(file);
        File(p.join(dir.path, 'public', 'i18n', 'en.json'))
            .writeAsStringSync('{"hello": "Hello", "bye": "Bye"}');

        expect(await webRunner().run(['--config', config, 'sync', '--yes']), 0);
        expect(requests.where((r) => r.url.path.endsWith('/sync')),
            hasLength(2));
      });

      group('the base file is the catalog by the rule that keeps a pull off '
          'it', () {
        late File en;

        void recordBaseFile({String? output}) {
          final file = CliState.fileFor(config);
          final record = CliState.load(file);
          CliState(
            format: record.format,
            output: output ?? record.output,
            files: [...?record.files, 'en.json'],
            digests: {
              ...?record.digests,
              'en.json': contentDigest('{"hello":"Hello"}'),
            },
          ).save(file);
          en = File(p.join(dir.path, 'public', 'i18n', 'en.json'))
            ..writeAsStringSync('{"hello": "Hello", "bye": "Bye"}');
        }

        test('when `output:` reaches it by another path than `source:`',
            () async {
          Link(p.join(dir.path, 'public', 'link'))
              .createSync(p.join(dir.path, 'public', 'i18n'));
          File(config).writeAsStringSync(File(config)
              .readAsStringSync()
              .replaceFirst('output: public/i18n', 'output: public/link'));
          recordBaseFile(output: 'public/link');

          expect(
              await webRunner().run(['--config', config, 'sync', '--yes']), 0);
          expect(requests.where((r) => r.url.path.endsWith('/sync')),
              hasLength(2));
        });

        test('when the server stopped serving it: the write-back prunes '
            'around it instead of stopping after the publish', () async {
          recordBaseFile();

          expect(
              await webRunner(files: const {'json/es.json': '{"hello":"Hola"}'})
                  .run(['--config', config, 'sync', '--yes']),
              0);
          expect(requests.where((r) => r.url.path.endsWith('/publish')),
              hasLength(1));
          expect(en.readAsStringSync(), '{"hello": "Hello", "bye": "Bye"}');
        });
      });
    });

    test('`catalog:` on a per-locale format is refused before any request: '
        'the write-back would fail after the spend', () async {
      final config = writeWebConfig();
      File(config).writeAsStringSync('projectId: p1\nmode: a\nformat: json\n'
          'output: public/i18n\ncatalog: public/i18n/en.json\n');
      await expectLater(
        webRunner().run(['--config', config, 'sync', '--yes']),
        throwsA(isA<CliException>()
            .having((e) => e.message, 'message',
                allOf(contains('one file per locale'), contains('`source:`')))
            .having((e) => e.code, 'code', 'format_not_writable')),
      );
      expect(requests, isEmpty);
    });

    for (final flags in [
      ['--yes'],
      ['--dry-run'],
    ]) {
      test('a second file of the base language is refused before any '
          'catalog POST (${flags.single})', () async {
        final config = writeWebConfig();
        File(p.join(dir.path, 'public', 'i18n', 'admin', 'en.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"users": "Users"}');
        await expectLater(
          webRunner().run(['--config', config, 'sync', ...flags]),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'several_files_per_locale')
              .having((e) => e.message, 'message',
                  contains('public/i18n/admin/en.json'))),
        );
        expect(requests, isNotEmpty);
        expect(requests.every((r) => r.method == 'GET' && r.url.path.endsWith('/meta')), isTrue);
      });
    }

    for (final flags in [<String>['--dry-run'], ['--yes']]) {
      test('CLI resolves ambiguous scope before catalog POST $flags', () async {
        final config = writeWebConfig();
        File(config).writeAsStringSync('projectId: p1\nmode: a\nformat: json\n'
            'output: locales\nsource: locales/app/es.json\nsourceRoot: locales\nsourceLayout: locale-files\n');
        for (final path in ['locales/app/es.json', 'locales/admin/es.json']) {
          File(p.join(dir.path, path))..createSync(recursive: true)..writeAsStringSync('{}');
        }
        await expectLater(webRunner(baseCode: 'es').run(['--config', config, 'sync', ...flags]),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'several_files_per_locale')
                .having((e) => e.details['files'], 'files', ['locales/admin/es.json'])));
        expect(requests, isNotEmpty);
        expect(requests.every((r) => r.method == 'GET' && r.url.path.endsWith('/meta')), isTrue);
      });
    }

    test('--dry-run still prices the base file', () async {
      final code = await runnerWith(
          (req, calls) =>
              syncBody(dryRun: true, created: 1, estimatedCredits: 500),
          metaFormats: const ['json'], metaBaseCode: 'en').run(
          ['--config', writeWebConfig(), 'sync', '--dry-run'])
          .onError((error, stack) => fail('dry-run must succeed: $error'));
      expect(code, 0);
      final sync = requests.singleWhere((r) => r.url.path.endsWith('/sync'));
      expect(sync.url.queryParameters['dryRun'], 'true');
      expect((jsonDecode(sync.body) as Map)['fileName'], 'en.json');
    });
  });

  test('--dry-run stops after the preview and never publishes', () async {
    writeCatalog();
    final code = await runnerWith((req, calls) =>
            syncBody(dryRun: true, created: 1, estimatedCredits: 500))
        .run(['--config', writeConfig(), 'sync', '--dry-run']);

    expect(code, 0);
    // The preflight GET plus the priced dry run — and nothing else.
    expect([for (final r in requests) r.url.path],
        [endsWith('/meta'), endsWith('/sync')]);
  });

  // #955: the preview carries the same `exhausted` rows the real run gates
  // on, but `--dry-run` returned before reading them — silent where `push
  // --dry-run` warns (#752), and `--require-complete` was inert on it, so a
  // CI job using the dry run as a cheap gate read 0 over the exact state the
  // real run refuses.
  group('--dry-run and exhausted pairs (#955)', () {
    Map<String, Object?> exhaustedBody(http.Request req, int calls) =>
        syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          exhausted: [
            {'key': 'hola', 'lang': 'fr'},
          ],
        );

    test('the preview warns and names the pair, exit unchanged', () async {
      writeCatalog();
      final code = await runnerWith(exhaustedBody)
          .run(['--config', writeConfig(), 'sync', '--dry-run']);

      expect(code, 0);
      expect(
        errOut.toString(),
        contains('Skipped exhausted pair(s) — retry them from the '
            'dashboard: hola [fr]'),
      );
      expect([for (final r in requests) r.url.path],
          [endsWith('/meta'), endsWith('/sync')]);
    });

    test('--require-complete refuses on the preview, no real run', () async {
      writeCatalog();
      await expectLater(
        runnerWith(exhaustedBody).run([
          '--config', writeConfig(), 'sync', '--dry-run', '--require-complete',
        ]),
        // The refusal names the pair and the dashboard action — not any
        // other CliException the dry-run path could raise.
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('retry budget is spent): hola [fr]'))),
      );
      expect(errOut.toString(), isNot(contains('Skipped exhausted')));
      expect(requests.where((r) => r.url.path.endsWith('/sync')),
          hasLength(1));
    });

    test('an unaffordable preview keeps its exit 1 next to the warning',
        () async {
      writeCatalog();
      final code = await runnerWith((req, calls) => syncBody(
            dryRun: true,
            accepted: false,
            exhausted: [
              {'key': 'hola', 'lang': 'fr'},
            ],
          )).run(['--config', writeConfig(), 'sync', '--dry-run']);

      expect(code, 1);
      expect(errOut.toString(), contains('hola [fr]'));
    });

    test('--require-complete keeps a clean preview green', () async {
      writeCatalog();
      final code =
          await runnerWith((req, calls) => syncBody(dryRun: true)).run([
        '--config', writeConfig(), 'sync', '--dry-run', '--require-complete',
      ]);

      expect(code, 0);
      expect(errOut.toString(), isNot(contains('exhausted')));
    });

    // The preview also carries `pendingSkipped` — pairs held by a fill this
    // run does not own — which the real run refuses on under the flag; a
    // gate that read only `exhausted` was the #955 lie one field over.
    test('held pairs warn on the preview; --require-complete refuses',
        () async {
      writeCatalog();
      Map<String, Object?> held(http.Request req, int calls) =>
          syncBody(dryRun: true, pendingSkipped: 2);

      final soft = await runnerWith(held)
          .run(['--config', writeConfig(), 'sync', '--dry-run']);
      expect(soft, 0);
      expect(errOut.toString(),
          contains('2 pairs are already being filled by another run'));

      requests.clear();
      errOut.clear();
      await expectLater(
        runnerWith(held).run([
          '--config', writeConfig(), 'sync', '--dry-run', '--require-complete',
        ]),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('2 pairs are held by a fill this run does not own'))),
      );
      expect(requests.where((r) => r.url.path.endsWith('/sync')),
          hasLength(1));
    });
  });

  // #609: `sync` printed the ICU rejections and dropped the markup ones. It
  // publishes with `incompleteMode: skip`, so the failure is QUIETER here,
  // not milder: the locale simply has no value for that key.
  group('publish rejection lists (#609)', () {
    Future<String> syncWith(Map<String, Object?> publish) async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) =>
            syncBody(dryRun: req.url.queryParameters['dryRun'] == 'true'),
        publishBody: {
          'versionId': '2026.08.11.1',
          'keyCount': 2,
          ...publish,
        },
      ).run(['--config', writeConfig(), 'sync', '--yes']);
      expect(code, 0, reason: out.toString() + errOut.toString());
      return out.toString() + errOut.toString();
    }

    test('a markupRejected entry is printed and names the key', () async {
      final o = await syncWith({
        'markupRejected': ['welcome.title [en]: bold span dropped'],
      });
      expect(o, contains('Markup gate: welcome.title [en]: bold span '
          'dropped'));
    });

    test('both gates print, each under its own label', () async {
      final o = await syncWith({
        'icuRejected': ['cart.count [en]: plural without other'],
        'markupRejected': ['welcome.title [en]: bold span dropped'],
      });
      expect(o, contains('ICU gate: cart.count [en]: plural without other'));
      expect(o, contains('Markup gate: welcome.title [en]: bold span '
          'dropped'));
    });

    test('past the server cap the total is reported, not the list length',
        () async {
      final o = await syncWith({
        'markupRejected': ['a [en]: x', 'b [en]: y'],
        'markupRejectedTotal': 120,
        'icuRejected': ['c [en]: z'],
        'icuRejectedTotal': 7,
      });
      expect(o, contains('118 more'));
      expect(o, contains('6 more'));
    });

    // The rows are warnings (stderr); the count rides on the success line so
    // a log that captured stdout alone cannot read the run as clean.
    test('the success line on stdout carries the refusal count', () async {
      await syncWith({
        'markupRejected': ['a [en]: x'],
        'markupRejectedTotal': 120,
        'icuRejected': ['c [en]: z'],
      });
      // The same noun push and rollback print for the same two counters
      // (#1175) — three commands reporting one pair of fields with three
      // words was the defect.
      expect(out.toString(), contains('Published version 2026.08.11.1 '
          '(2 keys) — 121 cell(s) refused by a gate, see the '
          'warnings.'));
      expect(out.toString(), isNot(contains('translation(s) refused')));
    });

    test('a clean publish stays silent about both gates', () async {
      final o = await syncWith(const {});
      expect(o, isNot(contains('gate:')));
      expect(o, isNot(contains('refused')));
      expect(o, contains('Published version 2026.08.11.1 (2 keys).'));
    });
  });

  test('a no-op run publishes skipIfIdentical, reports unchanged, exits 0',
      () async {
    final catalog = writeCatalog();
    final before = catalog.readAsStringSync();
    final code = await runnerWith(
      (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true'),
      publishStatus: 200,
      publishBody: {
        'versionId': '2026.08.10.4',
        'keyCount': 2,
        'unchanged': true,
      },
      pulledCatalog: before,
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(out.toString(), contains('Nothing changed since version'));
    expect(catalog.readAsStringSync(), before);
  });

  // The server omits `notInCode` when it is 0, so the summary has to stay
  // silent on a catalog whose every phrase is still referenced, and speak up
  // when it is not.
  test('reports the strings the extraction pass no longer finds', () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        notInCode: 3,
      ),
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(out.toString(), contains('3 no longer in your code'));
  });

  test('says nothing about the code scan when every phrase is found', () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true'),
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(out.toString(), isNot(contains('no longer in your code')));
  });

  test('failed pairs re-POST the sync up to twice, then warn', () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        trackingToken:
            req.url.queryParameters['dryRun'] == 'true' ? null : 'job$calls',
      ),
      onSummary: (_) => {
        'status': 'done',
        'summary': {'total': 1, 'translated': 0, 'pending': 0, 'failed': 1},
      },
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    // 1 dry-run + 1 real + 2 retries.
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(4));
    expect(
      errOut.toString(),
      contains('1 pair(s) are still untranslated after 2 retries'),
    );
  });

  // #602 — the axis the old check could not see. A job that STOPS is terminal
  // too, and the pairs it abandoned are reported as `pending` (recoverable, by
  // design), never `failed`. Reading only `failed` published over them and
  // wrote the uploaded catalog back as "the translated catalog", green.
  group('a run whose fill stopped short', () {
    Future<int?> runWith(String status,
        {List<String> extraArgs = const [], String? pulledCatalog}) {
      final catalog = writeCatalog();
      return runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          created: 1,
          updatedTranslations: 5,
          estimatedCredits: 23400,
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
        onSummary: (_) => {
          'status': status,
          'summary': {
            'total': 10,
            'translated': 0,
            'pending': 10,
            'failed': 0,
          },
        },
        // The server has nothing new to serve, so the write back is the file
        // that was uploaded — byte for byte, which is why git sees no diff.
        pulledCatalog: pulledCatalog ?? catalog.readAsStringSync(),
      ).run(['--config', writeConfig(), 'sync', '--yes', ...extraArgs]);
    }

    test('an exhausted balance fails the run and says so', () async {
      final code = await runWith('aborted_no_credits');

      expect(code, 1);
      expect(errOut.toString(), contains('ran out of credits'));
      expect(errOut.toString(), contains('10 pair(s)'));
      // What DID translate is still published and written back: the run is
      // reported as short, not discarded.
      expect(requests.any((r) => r.url.path.endsWith('/publish')), isTrue);
      expect(out.toString(), isNot(contains('Sync complete')));
    });

    test('a cancelled job fails the run', () async {
      expect(await runWith('cancelled'), 1);
      expect(errOut.toString(), contains('cancelled'));
    });

    test('a failed job fails the run even with no failed pairs', () async {
      expect(await runWith('failed'), 1);
      expect(errOut.toString(), contains('10 pair(s) untranslated'));
    });

    test('it never re-POSTs: the plan was abandoned, not exhausted', () async {
      await runWith('aborted_no_credits');
      // The dry run and the one real sync — no retry asking for a hold the
      // balance has already refused.
      expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(2));
    });

    // The milder shortfall below already refuses before the publish; the
    // abandoned run is the worse case, so it cannot be the one that mints a
    // version and overwrites the catalog on the way out.
    test('--require-complete refuses before publishing or writing', () async {
      final catalog = File(p.join(dir.path, 'App', 'Localizable.xcstrings'));
      final code = runWith(
        'aborted_no_credits',
        extraArgs: ['--require-complete'],
        // Different from what was uploaded: a write back would show here.
        pulledCatalog: '{"sourceLanguage":"es","strings":{"Hola":{"local'
            'izations":{"en":{"stringUnit":{"state":"translated","value":'
            '"Hello"}}}}},"version":"1.0"}',
      );

      // The reason rides in the exception, which is what the runner prints:
      // refusing here must not cost the operator the diagnosis.
      await expectLater(
        code,
        throwsA(isA<CliException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('ran out of credits'),
            contains('nothing was published'),
          ),
        )),
      );
      expect(requests.any((r) => r.url.path.endsWith('/publish')), isFalse);
      expect(catalog.readAsStringSync(), isNot(contains('Hello')));
    });

    test('--no-publish still fails, and publishes nothing', () async {
      final code = await runWith('cancelled', extraArgs: ['--no-publish']);

      expect(code, 1);
      expect(requests.any((r) => r.url.path.endsWith('/publish')), isFalse);
      expect(errOut.toString(), contains('nothing was published'));
    });

    // Whatever ended the job, a run that covered its ask is a clean run: a
    // cancel that lands after the last pair was written must not fail a
    // catalog that has everything in it.
    test('a job that stopped with nothing outstanding is not a failure',
        () async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          created: 1,
          estimatedCredits: 100,
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
        onSummary: (_) => {
          'status': 'cancelled',
          'summary': {
            'total': 4,
            'translated': 4,
            'pending': 0,
            'failed': 0,
          },
        },
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(out.toString(), contains('Sync complete'));
      expect(errOut.toString(), isEmpty);
    });
  });

  test('pairs left pending by a finished job are retried, then reported',
      () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        trackingToken:
            req.url.queryParameters['dryRun'] == 'true' ? null : 'job$calls',
      ),
      onSummary: (_) => {
        'status': 'done',
        'summary': {'total': 4, 'translated': 2, 'pending': 2, 'failed': 0},
      },
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    // A finished job that simply did not cover everything is the recoverable
    // shape the retry loop was built for — it just used to be invisible on the
    // `pending` axis.
    expect(code, 0);
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(4));
    expect(
      errOut.toString(),
      contains('2 pair(s) are still untranslated after 2 retries'),
    );
  });

  // The exit the loop takes on its own condition: the re-POST found nothing to
  // queue, so it answers without a tracking token. The shortfall is reported
  // after the loop for exactly this path — inside, it would never be reached.
  test('a retry that queues nothing still reports what is missing', () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        // Only the first real sync has a job; the retry queues nothing.
        trackingToken: calls == 2 ? 'job1' : null,
      ),
      onSummary: (_) => {
        'status': 'done',
        'summary': {'total': 4, 'translated': 1, 'pending': 3, 'failed': 0},
      },
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(3));
    expect(
      errOut.toString(),
      contains('3 pair(s) are still untranslated after 1 retry;'),
    );
    expect(errOut.toString(), contains('does not carry them'));
  });

  test('--no-publish says nothing was written, not that the catalog is short',
      () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        trackingToken: calls == 2 ? 'job1' : null,
      ),
      onSummary: (_) => {
        'status': 'done',
        'summary': {'total': 4, 'translated': 1, 'pending': 3, 'failed': 0},
      },
    ).run(['--config', writeConfig(), 'sync', '--yes', '--no-publish']);

    expect(code, 0);
    expect(errOut.toString(), contains('nothing will be published'));
    expect(errOut.toString(), isNot(contains('catalog written back')));
  });

  // The job that timed out is the outstanding one. Reporting the previous
  // iteration's shortfall next to "a later sync will pick it up" contradicts
  // it, with counts the running job may already have closed.
  test('a poll timeout does not also report the previous job as short',
      () async {
    writeCatalog();
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        trackingToken:
            req.url.queryParameters['dryRun'] == 'true' ? null : 'job$calls',
      ),
      // Poll 1: a finished job that fell short, so the run retries. Poll 2:
      // the retry is still running when the deadline passes.
      onSummary: (polls) => polls == 1
          ? {
              'status': 'done',
              'summary': {
                'total': 10,
                'translated': 5,
                'pending': 5,
                'failed': 0,
              },
            }
          : {
              'status': 'running',
              'summary': {
                'total': 10,
                'translated': 5,
                'pending': 5,
                'failed': 0,
              },
            },
      // Already past: the give-up branch is unreachable otherwise.
      pollTimeout: const Duration(seconds: -1),
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(errOut.toString(), contains('still running'));
    expect(errOut.toString(), isNot(contains('still untranslated')));
  });

  test('--require-complete fails on pairs a finished job left pending',
      () async {
    writeCatalog();
    final code = runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        trackingToken:
            req.url.queryParameters['dryRun'] == 'true' ? null : 'job$calls',
      ),
      onSummary: (_) => {
        'status': 'done',
        'summary': {'total': 4, 'translated': 2, 'pending': 2, 'failed': 0},
      },
    ).run([
      '--config',
      writeConfig(),
      'sync',
      '--yes',
      '--require-complete',
    ]);

    // The flag's own contract: fail fast, before the publish.
    await expectLater(code, throwsA(isA<CliException>()));
    expect(requests.any((r) => r.url.path.endsWith('/publish')), isFalse);
  });

  test('a contended entry re-POSTs and converges on the retry', () async {
    writeCatalog();
    // Call 1 is the preview, call 2 the real sync (loses the create race),
    // call 3 the retry — where the key exists and this catalog lands on it.
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: calls == 3 ? 0 : 1,
        updatedTranslations: calls == 3 ? 1 : 0,
        failedEntries: calls == 2
            ? [
                {
                  'key': 'hola',
                  'code': 'contended',
                  'reason': 'a concurrent sync wrote this key; retry the run',
                },
              ]
            : const [],
      ),
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(3));
    expect(out.toString(), contains('Retrying 1 entry in'));
    expect(out.toString(), contains('(1/2)'));
  });

  test('every job a contended retry supersedes is still waited for', () async {
    writeCatalog();
    // The common shape under a throttle, not the rare one: each re-post
    // re-applies what was contended, that work needs filling, so each pass
    // queues a job of ITS OWN. Only the last survives in `result` — the
    // earlier ones were charged and were never polled, so the run published
    // and pulled while they were still translating.
    final polled = <String>[];
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        trackingToken: switch (calls) { 2 => 'T1', 3 => 'T2', _ => 'T3' },
        failedEntries: calls == 2 || calls == 3
            ? [
                {
                  'key': 'hola',
                  'code': 'contended',
                  'reason': 'the datastore was throttling writes; retry the run',
                },
              ]
            : const [],
      ),
      onSummary: (polls) => {
        'status': 'done',
        'summary': {'total': 1, 'translated': 1, 'pending': 0, 'failed': 0},
      },
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    for (final r in requests) {
      final t = r.url.queryParameters['trackingToken'];
      if (t != null) polled.add(t);
    }
    expect(polled.toSet(), {'T1', 'T2', 'T3'},
        reason: 'two paid jobs went unwaited: $polled');
  });

  test('a contended row from the FILL retry still fails the run', () async {
    writeCatalog();
    // The fill-retry loop re-posts the catalog too, and nothing used to look
    // at the rows it came back with. A create race cannot realistically make
    // one there (every key exists by then), but a datastore failure can — and
    // before this it was a 500 that failed the run, not a warning that let it
    // publish.
    await expectLater(
      runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          created: 1,
          trackingToken: calls == 2 ? 'T1' : null,
          failedEntries: calls == 3
              ? [
                  {
                    'key': 'hola',
                    'code': 'contended',
                    'reason': 'the datastore was throttling writes; retry the '
                        'run',
                  },
                ]
              : const [],
        ),
        onSummary: (p) => {
          'status': 'done',
          'summary': {'total': 1, 'translated': 0, 'pending': 1, 'failed': 0},
        },
      ).run(['--config', writeConfig(), 'sync', '--yes']),
      throwsA(isA<CliException>().having((e) => e.message, 'message',
          allOf(contains('went unwritten'), contains('hola')))),
    );
    expect(requests.any((r) => r.url.path.endsWith('/publish')), isFalse,
        reason: 'it published content this run never wrote');
    // The refusal does not swallow the shortfall: the pairs the fill left
    // behind are named BEFORE the contended error propagates, or the operator
    // learns the run failed without learning what it left untranslated.
    expect(errOut.toString(),
        contains('1 pair(s) are still untranslated after 1 retry;'));
  });

  test('the contended retries back off instead of re-POSTing at once',
      () async {
    writeCatalog();
    final waits = <Duration>[];
    // The peer never yields, so both retries run: what matters is that each
    // one waited first. Re-posting instantly is worst exactly when the row
    // came from a database-wide write throttle (#591) — the retry would be
    // adding load to the saturation it is recovering from.
    Map<String, Object?> body(http.Request req, int calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          failedEntries: req.url.queryParameters['dryRun'] == 'true'
              ? const []
              : [
                  {
                    'key': 'hola',
                    'code': 'contended',
                    'reason': 'the datastore was throttling writes; retry the '
                        'run',
                  },
                ],
        );

    await expectLater(
      runnerWith(body, waits: waits)
          .run(['--config', writeConfig(), 'sync', '--yes']),
      throwsA(isA<CliException>()),
    );

    expect(waits, hasLength(2), reason: 'one wait before each re-POST');
    expect(waits.every((d) => d > Duration.zero), isTrue);
    expect(waits[1], greaterThan(waits[0]),
        reason: 'the window doubles; its lower half is not jittered');
  });

  test('an entry contended to the end fails the run instead of exiting 0',
      () async {
    writeCatalog();
    // The peer keeps winning. Every pass leaves `hola` unwritten, so the run
    // must not report success: with two branches syncing at once the peer's
    // write is not ours, and a green job drops this catalog's string.
    Map<String, Object?> body(http.Request req, int calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          failedEntries: req.url.queryParameters['dryRun'] == 'true'
              ? const []
              : [
                  {
                    'key': 'hola',
                    'code': 'contended',
                    'reason': 'a concurrent sync wrote this key; retry the run',
                  },
                ],
        );

    await expectLater(
      runnerWith(body).run(['--config', writeConfig(), 'sync', '--yes']),
      throwsA(
        // The message must carry the row's own reason: the same code covers
        // a peer sync and a datastore throttle, and only the row knows which.
        isA<CliException>().having((e) => e.message, 'message',
            allOf(contains('1 entry went unwritten'), contains('hola'),
                contains('a concurrent sync wrote this key'))),
      ),
    );
    // 1 preview + 1 real + 2 retries, and no publish on a run that lost data.
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(4));
    expect(requests.where((r) => r.url.path.endsWith('/publish')), isEmpty);
  });

  test('exhausted pairs warn without retrying; --require-complete fails',
      () async {
    writeCatalog();
    Map<String, Object?> body(http.Request req, int calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          exhausted: [
            {'key': 'hola', 'lang': 'fr'},
          ],
        );

    final soft = await runnerWith(body)
        .run(['--config', writeConfig(), 'sync', '--yes']);
    expect(soft, 0);
    expect(errOut.toString(), contains('exhausted pair'));
    expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(2));

    requests.clear();
    errOut.clear();
    await expectLater(
      runnerWith(body).run(
          ['--config', writeConfig(), 'sync', '--yes', '--require-complete']),
      throwsA(isA<CliException>()),
    );
  });

  // #608: the CI log named ONE pair out of 32 — the window that was capped
  // never reached `exhausted[]`. The test above carries a single row, which a
  // report cut to its first pair satisfies just as well.
  test('the exhausted warning names every pair with its language', () async {
    writeCatalog();
    Map<String, Object?> body(http.Request req, int calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          exhausted: [
            {'key': 'hey.siri', 'lang': 'pa'},
            {'key': 'adding', 'lang': 'pa'},
            {'key': 'call', 'lang': 'zh-hans'},
          ],
        );

    final code = await runnerWith(body)
        .run(['--config', writeConfig(), 'sync', '--yes']);
    expect(code, 0);
    final line = errOut
        .toString()
        .split('\n')
        .singleWhere((l) => l.contains('Skipped exhausted pair(s)'));
    expect(
      line,
      allOf(contains('hey.siri [pa]'), contains('adding [pa]'),
          contains('call [zh-hans]')),
    );
  });

  // #591. The route skips a pair whose marker says a fill already owns it, so
  // a run whose whole plan is in flight instant-accepts with a null token —
  // the wait loop never starts and every completeness question below it is
  // answered by silence. `--require-complete` used to PASS there, and publish
  // then minted a version without those cells.
  test('pairs held by another fill warn; --require-complete refuses', () async {
    writeCatalog();
    Map<String, Object?> body(http.Request req, int calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          pendingSkipped: 2,
        );

    final soft = await runnerWith(body)
        .run(['--config', writeConfig(), 'sync', '--yes']);
    expect(soft, 0);
    expect(errOut.toString(), contains('2 pairs are already being filled'));

    errOut.clear();
    await expectLater(
      runnerWith(body).run(
          ['--config', writeConfig(), 'sync', '--yes', '--require-complete']),
      throwsA(isA<CliException>()),
    );
  });

  // #550. A value the project produced after the catalog was pulled used to
  // come back as the file's older text, counted as "imported". The server now
  // keeps it and reports the pair; the CLI's job is to make that visible and
  // to carry the opt-out.
  group('a translation the catalog would revert', () {
    final row = {
      'key': 'instant.exit',
      'lang': 'en',
      'origin': 'machine',
      'stage': 'translated',
      'updatedAt': '2026-08-17T15:31:22.000Z',
      'resolution': 'kept',
    };

    test('is reported per pair, once, and sent as onConflict: server',
        () async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts: [row],
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(
        out.toString(),
        contains('1 conflict(s): 1 kept on the server'),
      );
      final warnings = errOut.toString();
      expect(warnings, contains('Conflict: instant.exit [en]'));
      expect(warnings, contains('AI-translated on 2026-08-17T15:31:22.000Z'));
      expect(warnings, contains('--on-conflict file'));
      // Preview + real sync both carry the row; the report prints once.
      expect('Conflict: instant.exit'.allMatches(warnings), hasLength(1));
      for (final r in requests.where((r) => r.url.path.endsWith('/sync'))) {
        expect((jsonDecode(r.body) as Map)['onConflict'], 'server');
      }
    });

    test('--dry-run shows the same report', () async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(dryRun: true, conflicts: [row]),
      ).run(['--config', writeConfig(), 'sync', '--dry-run']);
      expect(code, 0);
      expect(errOut.toString(), contains('Conflict: instant.exit [en]'));
    });

    test('--on-conflict file is sent, and the overwrite is still reported',
        () async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          updatedTranslations: 1,
          onConflict: 'file',
          conflicts: [
            {
              ...row,
              'origin': 'human',
              'stage': 'approved',
              'resolution': 'overwritten',
            },
          ],
        ),
      ).run([
        '--config', writeConfig(), 'sync', '--yes', '--on-conflict', 'file',
      ]);

      expect(code, 0);
      expect(out.toString(), contains('1 conflict(s): 1 overwritten'));
      expect(
        errOut.toString(),
        contains('the catalog overwrites the project\'s value '
            '(edited by a person, approved on 2026-08-17T15:31:22.000Z)'),
      );
      final sync = requests.firstWhere((r) => r.url.path.endsWith('/sync'));
      expect((jsonDecode(sync.body) as Map)['onConflict'], 'file');
    });

    test('an overwrite that failed mid-apply is reported as a flip',
        () async {
      // The preview prints "overwrites"; the real patch then fails its slot
      // and the server's row comes back `kept`. The verb must follow the
      // row's `resolution`, and the flip gets its own warning — otherwise the
      // user believes the overwrite happened.
      writeCatalog();
      final code = await runnerWith((req, calls) {
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        return syncBody(
          dryRun: dryRun,
          onConflict: 'file',
          conflicts: [
            {...row, 'resolution': dryRun ? 'overwritten' : 'kept'},
          ],
          failedEntries: dryRun
              ? const []
              : const [
                  {
                    'key': 'instant.exit',
                    'code': 'invalid_argument',
                    'reason': 'unbalanced brace',
                  },
                ],
        );
      }).run([
        '--config', writeConfig(), 'sync', '--yes', '--on-conflict', 'file',
      ]);

      expect(code, 0);
      final warnings = errOut.toString();
      expect(warnings, contains('the overwrite did not land'));
      expect(warnings, contains('instant.exit [en]'));
    });

    test('--no-publish warns that kept values stay server-side', () async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts: [row],
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes', '--no-publish']);

      expect(code, 0);
      expect(
        errOut.toString(),
        contains('kept value(s) stay server-side only'),
      );
      expect(requests.any((r) => r.url.path.endsWith('/publish')), isFalse);
    });

    test('a mixed outcome is summarized by resolution, not by policy',
        () async {
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          onConflict: 'file',
          conflicts: [
            {...row, 'resolution': 'overwritten'},
            {...row, 'key': 'other.key', 'resolution': 'kept'},
          ],
        ),
      ).run([
        '--config', writeConfig(), 'sync', '--yes', '--on-conflict', 'file',
      ]);
      expect(code, 0);
      expect(
        out.toString(),
        contains('2 conflict(s): 1 overwritten, 1 kept on the server'),
      );
    });

    test('one that only shows up in the real run is reported too', () async {
      // The preview and the real POST are two requests. A dashboard edit
      // landing between them (or during the retries, up to ~30 min later)
      // makes a pair conflict that the preview classified as a plain update.
      // Reporting off the preview alone refused the catalog's value and said
      // nothing — the same silence #550 exists to end.
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts:
              req.url.queryParameters['dryRun'] == 'true' ? const [] : [row],
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      final warnings = errOut.toString();
      expect(warnings, contains('Conflict: instant.exit [en]'));
      expect(warnings, contains('kept the project\'s value'));
      expect('Conflict: instant.exit'.allMatches(warnings), hasLength(1));
    });

    test('a run that dies on contended still reports its conflicts', () async {
      // The run throws before it reaches the end, so a conflict that first
      // appeared in the real POST has to be reported where it was seen.
      writeCatalog();
      await expectLater(
        runnerWith(
          (req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
            conflicts:
                req.url.queryParameters['dryRun'] == 'true' ? const [] : [row],
            failedEntries: req.url.queryParameters['dryRun'] == 'true'
                ? const []
                : const [
                    {
                      'key': 'other.key',
                      'code': 'contended',
                      'reason': 'a concurrent sync wrote this key; retry',
                    },
                  ],
          ),
        ).run(['--config', writeConfig(), 'sync', '--yes']),
        throwsA(isA<CliException>()),
      );
      expect(
        'Conflict: instant.exit'.allMatches(errOut.toString()),
        hasLength(1),
      );
    });

    test('a capped list reports the total, not the sample', () async {
      // The server caps the rows; a summary built off `conflicts.length`
      // would under-report by orders of magnitude exactly when the catalog is
      // furthest behind, and a kept/overwritten split of a sample states two
      // numbers that are wrong.
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts: [
            for (var i = 0; i < 50; i++) {...row, 'key': 'k$i'},
          ],
          conflictsTotal: 4200,
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(out.toString(), contains('4200 conflict(s) — first 50 listed'));
      expect(out.toString(), isNot(contains('50 conflict(s)')));
      expect(
        errOut.toString(),
        contains('...and 4150 more conflict(s) the server did not list'),
      );
    });

    test('an unknown --on-conflict value is refused by the parser', () async {
      writeCatalog();
      expect(
        () => runnerWith((req, calls) => syncBody()).run(
          ['--config', writeConfig(), 'sync', '--on-conflict', 'merge'],
        ),
        throwsA(isA<UsageException>()),
      );
    });
  });

  test('the poll throttle never relaxes when a running job\'s total shrinks',
      () async {
    // A large job whose `total` drops while it runs: the summary excludes
    // keys deleted or disabled after planning (#593), but the endpoint still
    // reads one doc per PLANNED key per poll (#614). The throttle keys off
    // the largest total seen, so a bulk delete mid-job cannot double the
    // read rate on exactly the job it exists to slow down.
    writeCatalog();
    final waits = <Duration>[];
    final code = await runnerWith(
      (req, calls) => syncBody(
        dryRun: req.url.queryParameters['dryRun'] == 'true',
        created: 1,
        estimatedCredits: 100,
        trackingToken:
            req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
      ),
      onSummary: (polls) => {
        'status': polls >= 3 ? 'done' : 'running',
        'summary': {
          'total': polls == 1 ? 600 : 400,
          'translated': polls >= 3 ? 400 : 0,
          'pending': polls >= 3 ? 0 : 400,
          'failed': 0,
        },
      },
      waits: waits,
    ).run(['--config', writeConfig(), 'sync', '--yes']);

    expect(code, 0);
    expect(
      waits,
      [const Duration(seconds: 10), const Duration(seconds: 10)],
    );
  });

  test('a config without catalog: fails with an actionable message', () async {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync('projectId: p1\nformat: xcstrings\n');
    await expectLater(
      runnerWith((req, calls) => syncBody()).run(['--config', path, 'sync']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('catalog:'),
        ),
      ),
    );
  });

  group('pulledAt arms the base-language guard (#671)', () {
    void writeState(Map<String, Object?> content) {
      File(p.join(dir.path, '.easyi18n', 'state.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(content));
    }

    List<Map<String, Object?>> syncBodies() => [
          for (final r in requests)
            if (r.url.path.endsWith('/sync'))
              (jsonDecode(r.body) as Map).cast<String, Object?>(),
        ];

    test('a recorded pull of THIS catalog rides every sync request', () async {
      // No `snapshotAt`: this is also the state a 0.11.0 CLI wrote, so it
      // pins the legacy fallback — an upgrade must not drop the claim for
      // anyone who has not pulled again yet.
      writeCatalog();
      writeState({
        'version': '2026.08.11.1',
        'pulledAt': '2026-08-11T09:00:00.000Z',
        'format': 'xcstrings',
        'catalog': 'App/Localizable.xcstrings',
      });
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final bodies = syncBodies();
      expect(bodies, isNotEmpty);
      for (final b in bodies) {
        expect(b['pulledAt'], '2026-08-11T09:00:00.000Z');
      }
    });

    test('the zone refusal is per field, not a veto on the whole state (#898)',
        () async {
      // Each stamp is dropped on its own. A `pulledAt` a hand wrote without a
      // zone must not take the good `snapshotAt` down with it, and a zoneless
      // `snapshotAt` must fall through to `pulledAt` rather than send nothing.
      for (final (state, expected) in <(Map<String, Object?>, String?)>[
        (
          {
            'pulledAt': '2026-09-01T14:00:00',
            'snapshotAt': '2026-08-20T09:00:00.000Z',
          },
          '2026-08-20T09:00:00.000Z'
        ),
        (
          {
            'pulledAt': '2026-09-01T14:00:00.000Z',
            'snapshotAt': '2026-08-20T09:00:00',
          },
          '2026-09-01T14:00:00.000Z'
        ),
        (
          {'pulledAt': '2026-09-01T14:00:00', 'snapshotAt': '2026-08-20'},
          null
        ),
      ]) {
        requests.clear();
        writeCatalog();
        writeState({
          ...state,
          'format': 'xcstrings',
          'catalog': 'App/Localizable.xcstrings',
        });
        await runnerWith(
          (req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
            trackingToken:
                req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
          ),
        ).run(['--config', writeConfig(), 'sync', '--yes']);

        final bodies = syncBodies();
        expect(bodies, isNotEmpty, reason: '$state');
        for (final b in bodies) {
          expect(b['pulledAt'], expected, reason: '$state');
        }
      }
    });

    test('with both stamps recorded the claim is the SNAPSHOT, not the pull '
        '(#898)', () async {
      // Both fields, twelve days apart, and the assertion is on WHICH one
      // rides: a fixture carrying only one of them passes just as happily
      // under the inverted `pulledAt ?? snapshotAt`.
      writeCatalog();
      writeState({
        'version': '2026.08.20.1',
        'pulledAt': '2026-09-01T14:00:00.000Z',
        'snapshotAt': '2026-08-20T09:00:00.000Z',
        'format': 'xcstrings',
        'catalog': 'App/Localizable.xcstrings',
      });
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final bodies = syncBodies();
      expect(bodies, isNotEmpty);
      for (final b in bodies) {
        expect(b['pulledAt'], '2026-08-20T09:00:00.000Z');
      }
    });

    test('no recorded pull, no claim: the CI flow sends nothing', () async {
      // `sync`'s own final pull deliberately records nothing (a fresh
      // state.json in CI is a diff), so a repo that only ever syncs has no
      // state — and must not invent a timestamp.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      for (final b in syncBodies()) {
        expect(b.containsKey('pulledAt'), isFalse);
      }
    });

    test('a pull recorded for another target is not a claim about this file',
        () async {
      // The state belongs to whatever the last explicit `pull` wrote. After
      // a config switch its timestamp dates ANOTHER file — arming the guard
      // with it would report conflicts against a pull this catalog never had.
      writeCatalog();
      writeState({
        'pulledAt': '2026-08-11T09:00:00.000Z',
        'format': 'xcstrings',
        'catalog': 'Other/Legacy.xcstrings',
      });
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      for (final b in syncBodies()) {
        expect(b.containsKey('pulledAt'), isFalse);
      }
    });

    test('the claim rides the run that receives the row, and the row is named '
        'a source', () async {
      // The two halves in one run: the state arms the guard, the server
      // answers with a base row, and the CLI names it a source. Nothing else
      // in this group runs both ends of the loop.
      writeCatalog();
      writeState({
        'pulledAt': '2026-08-11T09:00:00.000Z',
        'format': 'xcstrings',
        'catalog': 'App/Localizable.xcstrings',
      });
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts: const [
            {
              'key': 'hola',
              'lang': 'es',
              'origin': 'human',
              'stage': null,
              'updatedAt': '2026-08-20T10:00:00.000Z',
              'resolution': 'kept',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      for (final b in syncBodies()) {
        expect(b['pulledAt'], '2026-08-11T09:00:00.000Z');
      }
      expect(errOut.toString(), contains("kept the project's source text"));
    });

    test('an overwrite that did not land names a source a source too',
        () async {
      // The line that says what ACTUALLY stands in the datastore. It sits in
      // its own branch above the wording, so it kept saying "value" for a
      // base row while the line right before it said "source text" — two
      // lines of one run contradicting each other about one row.
      writeCatalog();
      final code = await runnerWith((req, calls) {
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        return syncBody(
          dryRun: dryRun,
          onConflict: 'file',
          conflicts: [
            {
              'key': 'hola',
              'lang': 'es',
              'origin': 'human',
              'stage': null,
              'updatedAt': '2026-08-20T10:00:00.000Z',
              'resolution': dryRun ? 'overwritten' : 'kept',
            },
          ],
          failedEntries: dryRun
              ? const []
              : const [
                  {
                    'key': 'hola',
                    'code': 'invalid_argument',
                    'reason': 'unbalanced brace',
                  },
                ],
          trackingToken: dryRun ? null : 'job1',
        );
      }).run([
        '--config', writeConfig(), 'sync', '--yes', '--on-conflict', 'file',
      ]);

      expect(code, 0);
      final warnings = errOut.toString();
      expect(
        warnings,
        contains('the overwrite did not land (its entry failed; see the '
            "warnings above); the project's source text still stands"),
      );
      expect(warnings, isNot(contains("the project's value still stands")));
    });

    test('--no-publish counts a kept source as a source', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts: const [
            {
              'key': 'hola',
              'lang': 'es',
              'origin': 'human',
              'stage': null,
              'updatedAt': '2026-08-20T10:00:00.000Z',
              'resolution': 'kept',
            },
            {
              'key': 'otra',
              'lang': 'en',
              'origin': 'machine',
              'stage': 'translated',
              'updatedAt': '2026-08-20T10:00:00.000Z',
              'resolution': 'kept',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes', '--no-publish']);

      expect(errOut.toString(),
          contains('1 kept value(s) and 1 kept source(s) stay server-side'));
    });

    test('a state.json timestamp with no zone is not a claim: the CLI would '
        'be guessing its own', () async {
      // `DateTime.parse` reads a bare timestamp as the PROCESS's local time,
      // so west of UTC it moves FORWARD — an in-app source edit inside that
      // window stops looking newer than the pull and is reverted with no
      // row. `save` always writes `Z`; a hand-edited file need not.
      writeCatalog();
      writeState({
        'pulledAt': '2026-08-11T09:00:00',
        'format': 'xcstrings',
        'catalog': 'App/Localizable.xcstrings',
      });
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      for (final b in syncBodies()) {
        expect(b.containsKey('pulledAt'), isFalse);
      }
    });

    test('a base-language row is reported as the SOURCE, kept by default',
        () async {
      // The server's row rides the same array as translation conflicts, with
      // `lang` = the base code. Calling it "the project's value" reads as a
      // translation and sends the operator to the wrong column.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          conflicts: const [
            {
              'key': 'hola',
              'lang': 'es',
              'origin': 'human',
              'stage': null,
              'updatedAt': '2026-08-20T10:00:00.000Z',
              'resolution': 'kept',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final warnings = errOut.toString();
      expect(warnings, contains('Conflict: hola [es]'));
      expect(warnings, contains("kept the project's source text"));
      expect(warnings, contains('edited by a person on 2026-08-20'));
      expect(warnings, isNot(contains("kept the project's value")));
    });
  });

  group('the output format the pull needs is checked before spending (#530)',
      () {
    test('a format the project has not enabled fails before the first /sync',
        () async {
      writeCatalog();
      await expectLater(
        runnerWith((req, calls) => syncBody(), metaFormats: const ['json'])
            .run(['--config', writeConfig(), 'sync', '--yes']),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('"xcstrings" is not enabled'),
              contains('enabled: json'),
              contains('easyi18n formats add xcstrings'),
            ),
          ),
        ),
      );
      // Nothing was uploaded, nothing was charged, nothing was published.
      expect(requests.where((r) => r.url.path.endsWith('/sync')), isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/publish')), isEmpty);
    });

    test('--dry-run fails too: it is the step that prices the run', () async {
      writeCatalog();
      await expectLater(
        runnerWith((req, calls) => syncBody(dryRun: true),
                metaFormats: const ['json'])
            .run(['--config', writeConfig(), 'sync', '--dry-run']),
        throwsA(isA<CliException>()),
      );
      expect(requests.where((r) => r.url.path.endsWith('/sync')), isEmpty);
    });

    test('--no-publish never pulls, so the format is not its problem',
        () async {
      writeCatalog();
      final code = await runnerWith((req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
          ), metaFormats: const ['json'])
              .run(['--config', writeConfig(), 'sync', '--yes', '--no-publish']);

      expect(code, 0);
      expect(requests.where((r) => r.url.path.endsWith('/sync')), hasLength(2));
      expect(requests.where((r) => r.url.path.endsWith('/publish')), isEmpty);
      // The check is skipped entirely — no round trip for an answer this run
      // does not need.
      expect(requests.where((r) => r.url.path.endsWith('/meta')), isEmpty);
    });

    test('unreadable metadata stops before preview', () async {
      writeCatalog();
      await expectLater(runnerWith((req, calls) => syncBody(), metaStatus: 403)
          .run(['--config', writeConfig(), 'sync', '--yes']),
          throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)));
      expect(requests.map((r) => r.url.path), ['/v1/projects/p1/meta']);
    });
  });

  group('language set (#592)', () {
    // The catalog the developer already owns: it carries `zh`, which the
    // project does not configure, and no `en-gb`.
    const localWithZh = '{\n'
        '  "sourceLanguage" : "es",\n'
        '  "strings" : {\n'
        '    "Hola" : {\n'
        '      "localizations" : {\n'
        '        "zh" : {\n'
        '          "stringUnit" : {\n'
        '            "state" : "translated",\n'
        '            "value" : "\\u4f60\\u597d"\n'
        '          }\n'
        '        }\n'
        '      }\n'
        '    }\n'
        '  },\n'
        '  "version" : "1.0"\n'
        '}';

    test('names every configured language missing from the catalog it wrote',
        () async {
      writeCatalog(localWithZh);
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          created: 1,
          targetLangs: const ['en', 'en-gb'],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      // 1. the configured language the written catalog does not contain
      expect(
        _codesIn(errOut.toString(), 'missing from the catalog'),
        ['en-gb'],
      );
      // 2. the locale the catalog carries that nothing here translated
      expect(_codesIn(errOut.toString(), 'configured nowhere'), ['zh']);
      // 3. `en` WAS delivered, so it appears in neither list — a line that
      //    names every language proves nothing about any of them.
    });

    test('states the set before the credit estimate, never after', () async {
      // The whole point: an estimate the operator cannot check against the
      // intent is a number they have to take on faith.
      writeCatalog(localWithZh);
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          estimatedCredits: 12000,
          targetLangs: const ['en', 'en-gb'],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final stdout = out.toString();
      expect(stdout, contains('Target languages (2): en, en-gb'));
      expect(
        stdout.indexOf('Target languages'),
        lessThan(stdout.indexOf('credits to translate')),
      );
    });

    test("names the catalog's own spelling of a language the project spells "
        'differently', () async {
      writeCatalog(localWithZh);
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'zh-hans'],
          diagnostics: const [
            {
              'code': 'LANG_NOT_IN_FILE',
              'severity': 'info',
              'field': 'zh-hans',
              'message': 'whatever the server wrote',
              'alsoSpelled': ['zh'],
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final err = errOut.toString();
      // The spelling rides ON the code it belongs to (see the case below).
      expect(err, contains('Not in your catalog: zh-hans (your catalog '
          "spells it 'zh')"));
      // The refusal to pick a side for them (#681).
      expect(err, contains('your call'));
    });

    // The last site in the CLI where a well-formed 200 still died with an
    // uncaught `TypeError` and exit 255 (#972): `api_client` hands the
    // diagnostic rows over untyped on purpose, and `alsoSpelled as List?`
    // crashed the PREVIEW — before the credit prompt, on the route the whole
    // hardening pass exists to protect.
    test('a diagnostic whose alsoSpelled is not a list still reports the row',
        () async {
      for (final also in <Object?>['zh', 5, true, {'a': 1}]) {
        writeCatalog(localWithZh);
        out.clear();
        errOut.clear();
        final code = await runnerWith(
          (req, calls) => syncBody(
            dryRun: true,
            targetLangs: const ['en', 'zh-hans'],
            diagnostics: [
              {
                'code': 'LANG_NOT_IN_FILE',
                'severity': 'info',
                'field': 'zh-hans',
                'message': 'whatever the server wrote',
                'alsoSpelled': also,
              },
            ],
          ),
        ).run(['--config', writeConfig(), 'sync', '--dry-run']);

        expect(code, 0, reason: 'alsoSpelled=$also');
        // The row is still named — the unusable spelling is dropped, not the
        // whole warning, exactly as a mixed list already behaved.
        expect(errOut.toString(), contains('Not in your catalog: zh-hans'),
            reason: 'alsoSpelled=$also');
        expect(errOut.toString(), isNot(contains('spells it')),
            reason: 'alsoSpelled=$also');
      }
    });

    test('a near spelling is never attached to a language that has none',
        () async {
      // Pooling `alsoSpelled` across rows told an operator who configured
      // `zh-hans` (near miss `zh`) and `es-ar` (none) that their catalog might
      // spell `es-ar` as `zh`. The backend keeps the association per row; the
      // rendering has to keep it too.
      writeCatalog(localWithZh);
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['zh-hans', 'es-ar'],
          diagnostics: const [
            {
              'code': 'LANG_NOT_IN_FILE',
              'severity': 'info',
              'field': 'zh-hans',
              'message': 'whatever the server wrote',
              'alsoSpelled': ['zh'],
            },
            {
              'code': 'LANG_NOT_IN_FILE',
              'severity': 'info',
              'field': 'es-ar',
              'message': 'whatever the server wrote',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final line = errOut
          .toString()
          .split('\n')
          .firstWhere((l) => l.contains('Not in your catalog'));
      expect(line, contains("zh-hans (your catalog spells it 'zh')"));
      // `es-ar` is named bare — no parenthetical of any kind after it.
      expect(line, contains('es-ar —'));
    });

    group('what the run plans for a language the catalog lacks (#744)', () {
      // The line used to say "translated from scratch and part of the
      // estimate" for every row, including a language the project already
      // holds whole, which the same preview prices at zero.
      const scratch = 'translated from scratch';
      const nothing = 'this run has nothing to translate for these and they '
          'are not part of the estimate below.';

      Map<String, Object?> row(String lang, Object? planned,
              {List<String>? also}) =>
          {
            'code': 'LANG_NOT_IN_FILE',
            'severity': 'info',
            'field': lang,
            'message': 'whatever the server wrote',
            'alsoSpelled': ?also,
            'plannedPairs': ?planned,
          };

      Future<int?> preview(List<Map<String, Object?>> rows) {
        writeCatalog(localWithZh);
        out.clear();
        errOut.clear();
        return runnerWith(
          (req, calls) => syncBody(
            dryRun: true,
            targetLangs: [for (final r in rows) r['field']! as String],
            diagnostics: rows,
          ),
        ).run(['--config', writeConfig(), 'sync', '--dry-run']);
      }

      String lineWith(StringBuffer buffer, String needle) => buffer
          .toString()
          .split('\n')
          .firstWhere((l) => l.contains(needle), orElse: () => '');

      test('a language with no planned pair is named without the claim',
          () async {
        expect(await preview([row('de', 0)]), 0);
        expect(out.toString(), contains('Not in your catalog: de — $nothing'));
        expect('$out$errOut', isNot(contains(scratch)));
        // Printed by the language line, so the generic printer must not
        // print the same row a second time under the server's wording.
        expect('$out$errOut', isNot(contains('whatever the server wrote')));
      });

      test('a language with planned pairs keeps the line it had', () async {
        expect(await preview([row('de', 3)]), 0);
        expect(
          errOut.toString(),
          contains('Not in your catalog: de — these will be $scratch and are '
              'part of the estimate below.'),
        );
        expect('$out$errOut', isNot(contains('nothing to translate')));
      });

      test('each language lands on the line that is true for it', () async {
        await preview([
          row('de', 0),
          row('ja', 2),
          row('fr-ca', 0, also: ['fr']),
        ]);
        // The whole list sits between the colon and the dash, so each
        // `contains` below pins which codes the line names and which it
        // leaves to the other one.
        final planned = lineWith(errOut, scratch);
        expect(planned, contains('Not in your catalog: ja —'));
        // No near spelling among the planned rows, so nothing to pay for by
        // mistake: the advice belongs to the other line.
        expect(planned, isNot(contains('your call')));

        final held = lineWith(out, 'nothing to translate');
        expect(
          held,
          contains('Not in your catalog: de, fr-ca (your catalog spells it '
              "'fr') — $nothing"),
        );
        expect(held, contains('your call'));
        // Nothing is being bought for these, so the line does not talk
        // about paying.
        expect(held, isNot(contains('paying')));
      });

      test('the spelling advice stays with the row that carries a spelling',
          () async {
        await preview([
          row('zh-hans', 1, also: ['zh']),
          row('de', 0),
        ]);
        expect(lineWith(errOut, scratch), contains('before paying'));
        final held = lineWith(out, 'nothing to translate');
        expect(held, contains('Not in your catalog: de —'));
        expect(held, isNot(contains('your call')));
      });

      test('a count that is not the number zero is read as planned',
          () async {
        // The rows arrive untyped (#972), and a server that predates the
        // field sends none: both keep the line every row had before.
        for (final planned in <Object?>[null, '0', false, <int>[]]) {
          expect(await preview([row('de', planned)]), 0,
              reason: 'plannedPairs=$planned');
          expect(errOut.toString(), contains('Not in your catalog: de'),
              reason: 'plannedPairs=$planned');
          expect(errOut.toString(), contains(scratch),
              reason: 'plannedPairs=$planned');
          expect(out.toString(), isNot(contains('nothing to translate')),
              reason: 'plannedPairs=$planned');
        }
      });
    });

    test('every LANG_* family the backend emits reaches a printed line',
        () async {
      // The rows below are shaped exactly as `public_sync_api.dart` builds
      // them. The grouping reads `field`, so a family the backend emits
      // without one is a diagnostic that costs a round trip and prints
      // nowhere — which is how two of the three used to behave, with the
      // hand-written fixtures agreeing with the CLI instead of with the wire.
      writeCatalog(localWithZh);
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'fr'],
          fillableLangs: const ['en'],
          diagnostics: const [
            {
              'code': 'LANG_NOT_CONFIGURED',
              'severity': 'info',
              'field': 'zh',
              'message': "the file carries 'zh' but the project does not have "
                  'that language configured; it was ignored',
            },
            {
              'code': 'LANG_NOT_FILLABLE',
              'severity': 'info',
              'field': 'fr',
              'message': "'fr' is set to manual fill; this run will not "
                  'translate it',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(_codesIn(errOut.toString(), 'does not configure'), ['zh']);
      expect(
        out.toString(),
        contains('Manual fill, not translated by this run: fr'),
      );
      // And exactly once: the merge never deletes, so `zh` is still in the
      // written catalog — repeating it after the pull would give one locale
      // two warnings on every CI run, which is the noise this report exists
      // to avoid. The two lines have deliberately distinct wording so a test
      // can tell them apart at all.
      expect(_codesIn(errOut.toString(), 'configured nowhere'), isEmpty);
    });

    test('does not accuse a manual-fill language of going missing', () async {
      // `fr` is configured, is NOT fillable, and is absent from the catalog.
      // Naming it would contradict the LANG_NOT_FILLABLE line in the same run.
      // The diagnostics are exactly what the backend sends for that project:
      // one `LANG_NOT_FILLABLE` row for `fr` and NO `LANG_NOT_IN_FILE` one,
      // because a manual language is in no estimate.
      writeCatalog(localWithZh);
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'fr'],
          fillableLangs: const ['en'],
          diagnostics: const [
            {
              'code': 'LANG_NOT_FILLABLE',
              'severity': 'info',
              'field': 'fr',
              'message': "'fr' is set to manual fill; this run will not "
                  'translate it',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(_codesIn(errOut.toString(), 'missing from the catalog'), isEmpty);
      // And `fr` is not accused from the other side either: it IS configured.
      expect(_codesIn(errOut.toString(), 'configured nowhere'), ['zh']);
      // Nor announced as something the estimate covers.
      expect(errOut.toString(), isNot(contains('Not in your catalog')));
    });

    test('a catalog whose every entry opted out is never accused of losing a '
        'language', () async {
      // A dev-only `InfoPlist.xcstrings` with every string marked
      // `shouldTranslate: false` is a legal, ordinary file (#612). No fill
      // will ever write a locale into it, so "this run did not deliver them —
      // re-run the sync" is advice that can never work, printed on every CI
      // run forever.
      const optedOut = '{"sourceLanguage":"es","strings":{'
          '"NSCameraUsageDescription":{"shouldTranslate":false},'
          '"NSMicrophoneUsageDescription":{"shouldTranslate":false}}}';
      writeCatalog(optedOut);
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'fr'],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
        pulledCatalog: optedOut,
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(errOut.toString(), isNot(contains('missing from the catalog')));
    });

    test('says nothing when the server does not name the base language',
        () async {
      // The one honest reading of "we were not told what this project is
      // configured for". `targetLangs` being empty is NOT that reading — see
      // the case below.
      writeCatalog(localWithZh);
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          baseCode: '',
          targetLangs: const [],
          fillableLangs: const [],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(out.toString(), isNot(contains('Target languages')));
      expect(errOut.toString(), isNot(contains('configured nowhere')));
      expect(errOut.toString(), isNot(contains('missing from the catalog')));
    });

    test('a project with only its base language still hears about the '
        'locales nobody configured', () async {
      // `targetLangs: []` is a real project shape — a freshly created project
      // whose catalog already carries translations — not an old server. Gating
      // the whole report on it silenced, on exactly that project, the
      // `zh`/`pt-BR` line that is #592's headline symptom.
      writeCatalog(localWithZh);
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const [],
          fillableLangs: const [],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
        // Nothing configured, so the server has nothing to deliver either.
        pulledCatalog: '{"sourceLanguage":"es","strings":{"Hola":{}}}',
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(_codesIn(errOut.toString(), 'configured nowhere'), ['zh']);
      // Nothing is configured, so nothing can be reported as undelivered.
      expect(errOut.toString(), isNot(contains('missing from the catalog')));
      // And no empty roll call.
      expect(out.toString(), isNot(contains('Target languages')));
    });

    test('an older server still gets the unconfigured-locale warning', () async {
      // A pre-#592 backend sends `targetLangs` but no `fillableLangs`. The
      // half that needs the missing field stays quiet; the half that names
      // #592's own `zh` does not — muting it here would have silenced the
      // headline symptom on exactly the deployments that still have it.
      writeCatalog(localWithZh);
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'en-gb'],
          fillableLangs: const [],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(_codesIn(errOut.toString(), 'configured nowhere'), ['zh']);
      expect(_codesIn(errOut.toString(), 'missing from the catalog'), isEmpty);
    });

    test('a catalog it cannot parse produces no claim about it', () async {
      // The merge passes an unparseable local file through untouched, so the
      // written bytes are not JSON. Reading no locales out of it must read as
      // "cannot say", never as "every configured language is missing".
      writeCatalog('not json at all');
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'en-gb'],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
        pulledCatalog: 'not json either',
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 0);
      expect(errOut.toString(), isNot(contains('missing from the catalog')));
      expect(errOut.toString(), isNot(contains('configured nowhere')));
    });

    test('the warning still fires on the run that stopped short', () async {
      // A fill that ran out of credits is the run most likely to leave a
      // configured language out — putting the check behind that `return 1`
      // would kill it exactly where it matters.
      writeCatalog(localWithZh);
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'en-gb'],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
        onSummary: (polls) => {
          'status': 'aborted_no_credits',
          'summary': {
            'total': 2,
            'translated': 1,
            'pending': 1,
            'failed': 0,
          },
        },
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(code, 1, reason: 'a stopped-short run still exits non-zero');
      expect(
        _codesIn(errOut.toString(), 'missing from the catalog'),
        ['en-gb'],
      );
    });
  });

  group('the parse diagnostics nothing else renders (#731)', () {
    test('a lost plural branch reaches a printed line', () async {
      // The row is shaped exactly as the ICU parsers build it and as
      // `public_sync_api.dart` forwards it. Before this, the CLI paid for it
      // on the wire and printed nothing: the operator's catalog lost a plural
      // branch on the way in and the only place that said so was the
      // dashboard's import report.
      writeCatalog();
      final code = await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'cart.items',
              'message': "Plural form 'one' on 'cart.items' is defined more "
                  'than once; kept the last and dropped the rest.',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final line = errOut
          .toString()
          .split('\n')
          .firstWhere((l) => l.contains('DUPLICATE_PLURAL_FORM'));
      expect(line, contains("Plural form 'one' on 'cart.items'"));
      // Warn, never fail: the entries that did parse were imported.
      expect(code, 0);
    });

    test('one line per code, however many rows the file produced', () async {
      // Per-entry diagnostics are unbounded — a catalog with a hundred
      // non-string leaves must not bury the report it belongs to.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: [
            for (var i = 0; i < 9; i++)
              {
                'code': 'SKIPPED_NON_STRING',
                'severity': 'warning',
                'field': 'k$i',
                'message': "Key 'k$i' has a non-string value; skipped.",
              },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final printed = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('SKIPPED_NON_STRING'))
          .toList();
      expect(printed, hasLength(1));
      // The first row explains, five more are named so they can be found,
      // and the tail is counted rather than dropped in silence.
      expect(printed.single, contains("Key 'k0' has a non-string value"));
      expect(printed.single, contains('also on: k1, k2, k3, k4, k5 (+3 more)'));
    });

    test('an informational classification goes to stdout, not the CI log',
        () async {
      // Every entry of a dev-only catalog opting out (#612) is an ordinary
      // state, not something to grep a build log for.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'NOT_TRANSLATABLE',
              'severity': 'info',
              'field': 'debug.title',
              'message': "'debug.title' is not translatable; skipped.",
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(out.toString(), contains('NOT_TRANSLATABLE'));
      expect(errOut.toString(), isNot(contains('NOT_TRANSLATABLE')));
    });

    test('the language report keeps its own rows to itself', () async {
      // The three `LANG_*` codes have grouped lines of their own, with the
      // remedy attached. Printing them twice per run is the noise that report
      // was built to avoid.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          targetLangs: const ['en', 'fr'],
          fillableLangs: const ['en'],
          diagnostics: const [
            {
              'code': 'LANG_NOT_CONFIGURED',
              'severity': 'info',
              'field': 'zh',
              'message': "the file carries 'zh' but the project does not have "
                  'that language configured; it was ignored',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(_codesIn(errOut.toString(), 'does not configure'), ['zh']);
      expect(errOut.toString(), isNot(contains('LANG_NOT_CONFIGURED')));
      expect(out.toString(), isNot(contains('LANG_NOT_CONFIGURED')));
    });

    test('a row of that family the language report cannot group still prints',
        () async {
      // The language report groups on `field`; a row without one is a row it
      // drops. Skipping it here on its code alone would put it back exactly
      // where this change found it — printed nowhere.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'LANG_NOT_CONFIGURED',
              'severity': 'warning',
              'message': 'the file carries a locale the project does not '
                  'configure',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(errOut.toString(), contains('LANG_NOT_CONFIGURED'));
    });

    test('a row only the real run can produce still prints, and once',
        () async {
      // `PLURAL_BEHIND_PROJECT` is not a parse row: the server derives it from
      // the STORED plural, so it can appear on the real POST after a preview
      // that could not have seen it (a dashboard edit landing while the
      // operator answers the credit prompt). Reporting off the preview alone
      // dropped it — and the parse rows, which DO ride every response, must
      // still be announced exactly once.
      writeCatalog();
      await runnerWith((req, calls) {
        final dry = req.url.queryParameters['dryRun'] == 'true';
        return syncBody(
          dryRun: dry,
          diagnostics: [
            const {
              'code': 'SKIPPED_NON_STRING',
              'severity': 'warning',
              'field': 'k1',
              'message': "Key 'k1' has a non-string value; skipped.",
            },
            if (!dry)
              const {
                'code': 'PLURAL_BEHIND_PROJECT',
                'severity': 'info',
                'field': 'items',
                'message': "the file's 'fr' plural for 'items' has fewer "
                    "forms than the project's; kept the project version. "
                    'Pull to bring your copy up to date.',
              },
          ],
          trackingToken: dry ? null : 'job1',
        );
      }).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(out.toString(), contains('PLURAL_BEHIND_PROJECT'));
      expect(
        errOut
            .toString()
            .split('\n')
            .where((l) => l.contains('SKIPPED_NON_STRING')),
        hasLength(1),
      );
    });

    test('two faults on one key are both named', () async {
      // A value that duplicates `one` AND `few` produces two rows with the
      // SAME field and DIFFERENT messages. Folding them under one head left
      // the second selector unnamed; the shapes differ, so they are two
      // lines and each says which form it lost.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'items',
              'message': "Plural form 'one' on 'items' is defined more than "
                  'once; kept the last and dropped the rest.',
            },
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'items',
              'message': "Plural form 'few' on 'items' is defined more than "
                  'once; kept the last and dropped the rest.',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('DUPLICATE_PLURAL_FORM'))
          .toList();
      expect(lines, hasLength(2));
      expect(lines.any((l) => l.contains("Plural form 'one'")), isTrue);
      expect(lines.any((l) => l.contains("Plural form 'few'")), isTrue);
      // One key, so neither line borrows the other's key.
      expect(lines.every((l) => !l.contains('also on')), isTrue);
    });

    // The defect the shape key exists for: the head message names the
    // SELECTOR, so a group speaking for every row told the operator that `b`
    // lost `one` when what `b` lost was `few`.
    test('two keys losing different forms are not conflated', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'a',
              'message': "Plural form 'one' on 'a' is defined more than "
                  'once; kept the last and dropped the rest.',
            },
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'b',
              'message': "Plural form 'few' on 'b' is defined more than "
                  'once; kept the last and dropped the rest.',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('DUPLICATE_PLURAL_FORM'))
          .toList();
      expect(lines, hasLength(2));
      // Neither line claims the other key lost ITS form.
      expect(
        lines.firstWhere((l) => l.contains("'one' on 'a'")),
        isNot(contains('b')),
      );
      expect(
        lines.firstWhere((l) => l.contains("'few' on 'b'")),
        isNot(contains("'a'")),
      );
    });

    // Since #878 one code carries TWO consequences: a plain repeat drops a
    // body, a repeat behind an ICU `offset:` drops nothing because the value
    // is stored verbatim. Folding them under one head would tell an operator
    // that a value they can still read intact lost a branch.
    test('the two consequences of one code print two lines', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'a',
              'message': "Plural form 'one' on 'a' is defined more than "
                  'once; kept the last and dropped the rest.',
            },
            {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'b',
              'message': "Plural form 'one' on 'b' is defined more than "
                  "once; the value carries an ICU 'offset:', so it is stored "
                  'as text exactly as written and nothing is dropped.',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('DUPLICATE_PLURAL_FORM'))
          .toList();
      expect(lines, hasLength(2));
      expect(lines.any((l) => l.contains('dropped the rest')), isTrue);
      expect(lines.any((l) => l.contains('nothing is dropped')), isTrue);
      // Neither line borrows the other's key.
      expect(lines.every((l) => !l.contains('also on')), isTrue);
    });

    // ...and the same is true AT THE CAP. Past `_maxNamedDiagnosticFields`
    // shapes the rows used to fold into the LAST admitted line, so a sixth
    // shape carrying the OTHER consequence reached the operator as "kept the
    // last and dropped the rest" — the exact wording this pair exists to
    // avoid — on a value that was stored intact. A capped line may omit; it
    // may not misattribute
    // (`feedback_a_grouped_line_speaks_only_for_its_group_key`). The overflow
    // line borrows no message, so it can only under-say.
    test('the offset consequence survives the shape cap', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: [
            for (final s in ['one', 'two', 'few', 'many', 'zero'])
              {
                'code': 'DUPLICATE_PLURAL_FORM',
                'severity': 'warning',
                'field': 'k_$s',
                'message': "Plural form '$s' on 'k_$s' is defined more than "
                    'once; kept the last and dropped the rest.',
              },
            const {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'offsetkey',
              'message': "Plural form 'one' on 'offsetkey' is defined more "
                  "than once; the value carries an ICU 'offset:', so it is "
                  'stored as text exactly as written and nothing is dropped.',
            },
            // A SECOND row past the cap, carrying the OTHER consequence. One
            // row past the cap is the neutral value of the property this pair
            // exists to install: a bucket of one cannot misattribute, so any
            // wording lifted off its single row is true of it and the mutant
            // that lifts it dies on the missing marker instead — passing for
            // the wrong reason
            // (`feedback_a_fixture_at_zero_hides_the_whole_defect`). Its
            // selector is `=0`, so it is a sixth SHAPE and not a member of
            // `k_few`'s group.
            const {
              'code': 'DUPLICATE_PLURAL_FORM',
              'severity': 'warning',
              'field': 'cappedtrunc',
              'message': "Plural form '=0' on 'cappedtrunc' is defined more "
                  'than once; kept the last and dropped the rest.',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('DUPLICATE_PLURAL_FORM'))
          .toList();
      // ATTRIBUTION FIRST, and line by line: a line that quotes one
      // consequence may not name a key that suffered the other. This is what
      // fails when the overflow line borrows a row's message — before, and
      // independently of, anything about the marker.
      for (final l in lines) {
        if (l.contains('dropped the rest')) {
          expect(
            l,
            isNot(contains('offsetkey')),
            reason: 'a truncation line named the key stored intact',
          );
        }
        if (l.contains('nothing is dropped')) {
          for (final k in const [
            'k_one',
            'k_two',
            'k_few',
            'k_many',
            'k_zero',
            'cappedtrunc',
          ]) {
            expect(
              l,
              isNot(contains(k)),
              reason: 'a stored-intact line named a truncated key',
            );
          }
        }
      }
      // Both are still reported, on one line that quotes nobody's message.
      final overflow =
          lines.singleWhere((l) => l.contains('further row(s)'));
      expect(overflow, contains('offsetkey'));
      expect(overflow, contains('cappedtrunc'));
      expect(overflow, isNot(contains('dropped')));
      // And the five that DO share a wording keep their own lines.
      expect(
        lines.where((l) => l.contains('dropped the rest')),
        hasLength(5),
      );
    });

    // The overflow line says how many rows it stands for ONCE. It opens with
    // that count, so the tail sentence — which exists for a line whose head is
    // a row's MESSAGE and therefore carries no count of its own — would print
    // the same number twice. The fixture is the one that discriminates: three
    // rows past the cap over TWO keys, so rows outnumber the names and the
    // tail condition is true on its arithmetic.
    test('the overflow line states its row count once', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: [
            for (final s in ['one', 'two', 'few', 'many', 'zero'])
              {
                'code': 'DUPLICATE_PLURAL_FORM',
                'severity': 'warning',
                'field': 'k_$s',
                'message': "Plural form '$s' on 'k_$s' is defined more than "
                    'once; kept the last and dropped the rest.',
              },
            for (final r in [
              ['ovf_a', '=0'],
              ['ovf_b', '=1'],
              ['ovf_a', '=2'],
            ])
              {
                'code': 'DUPLICATE_PLURAL_FORM',
                'severity': 'warning',
                'field': r[0],
                'message': "Plural form '${r[1]}' on '${r[0]}' is defined "
                    'more than once; kept the last and dropped the rest.',
              },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final overflow = errOut
          .toString()
          .split('\n')
          .singleWhere((l) => l.contains('further row(s)'));
      expect(overflow, contains('3 further row(s) under this code.'));
      expect(overflow, contains('also on: ovf_a, ovf_b'));
      // Not a second count, and not a claim about rows it declines to
      // describe: "each with its own message" was false here — `ovf_a` brings
      // two rows and one wording.
      expect(overflow, isNot(contains('This line covers')));
      expect(overflow, isNot(contains('each with its own message')));
      expect(overflow, isNot(contains('for this code in total')));
    });

    // The overflow line's tail is capped like every other line's. Nothing
    // asserted that, which is how "names every key it covers" reached the
    // CHANGELOG of a published package and the PR body: it is false at
    // exactly the population the cap exists for. Eight keys, five named.
    test('the overflow line caps the keys it names and counts the rest',
        () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: [
            for (final s in ['one', 'two', 'few', 'many', 'zero'])
              {
                'code': 'DUPLICATE_PLURAL_FORM',
                'severity': 'warning',
                'field': 'k_$s',
                'message': "Plural form '$s' on 'k_$s' is defined more than "
                    'once; kept the last and dropped the rest.',
              },
            for (var i = 0; i < 8; i++)
              {
                'code': 'DUPLICATE_PLURAL_FORM',
                'severity': 'warning',
                'field': 'ovf$i',
                'message': "Plural form '=$i' on 'ovf$i' is defined more "
                    'than once; kept the last and dropped the rest.',
              },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final overflow = errOut
          .toString()
          .split('\n')
          .singleWhere((l) => l.contains('further row(s)'));
      expect(overflow, contains('8 further row(s) under this code.'));
      expect(overflow, contains('also on: ovf0, ovf1, ovf2, ovf3, ovf4'));
      expect(overflow, contains('(+3 more)'));
      // Every row is accounted for: 5 named + 3 counted = the 8 the head says.
      for (final k in const ['ovf5', 'ovf6', 'ovf7']) {
        expect(overflow, isNot(contains(k)));
      }
    });

    // The tail count belongs to a line whose head is a row's message: that
    // head names one row and the tail names the distinct keys, so when rows
    // outnumber both, nothing else says so. It speaks for THIS LINE — one
    // (code, shape) group — and not for the code, which prints one line per
    // shape.
    test('a line whose head is a message counts the rows it covers', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: [
            for (var i = 0; i < 3; i++)
              const {
                'code': 'EMPTY_PLURAL_FORM',
                'severity': 'warning',
                'message': "Plural form 'one' is empty; skipped.",
              },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('EMPTY_PLURAL_FORM'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('This line covers 3 row(s).'));
      expect(lines.single, isNot(contains('for this code in total')));
    });

    // ...and a code whose message varies ONLY by key still folds into the one
    // line it always printed. The shape key must not undo the grouping.
    test('a code that varies only by key stays one line', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: [
            for (final k in ['k0', 'k1', 'k2'])
              {
                'code': 'SKIPPED_NON_STRING',
                'severity': 'warning',
                'field': k,
                'message': "Resource '$k' has a non-string value; skipped.",
              },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('SKIPPED_NON_STRING'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('also on: k1, k2'));
    });

    // A row that is NEW on the real run and shares (code, field) with one the
    // preview already printed: keyed without the message it was discarded and
    // printed nowhere at all — not even counted.
    test('a second row under the same key still reaches the operator',
        () async {
      writeCatalog();
      await runnerWith(
        (req, calls) {
          final dry = req.url.queryParameters['dryRun'] == 'true';
          return syncBody(
            dryRun: dry,
            diagnostics: [
              const {
                'code': 'PLURAL_BEHIND_PROJECT',
                'severity': 'info',
                'field': 'items',
                'message': "the file's 'es' plural for 'items' has fewer "
                    "forms than the project's",
              },
              // Only the real run carries it: a dashboard edit that landed
              // while the operator answered the credit prompt.
              if (!dry)
                const {
                  'code': 'PLURAL_BEHIND_PROJECT',
                  'severity': 'info',
                  'field': 'items',
                  'message': "the file's 'fr' plural for 'items' has fewer "
                      "forms than the project's",
                },
            ],
            trackingToken: dry ? null : 'job1',
          );
        },
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(out.toString(), contains("'fr' plural for 'items'"));
    });

    // Severity is the group's LOUDEST row, not its first: a warning routed to
    // stdout because an `info` row sorted ahead of it is the one direction a
    // CI log cannot recover from. No code carries two severities today — the
    // bar is on a group that cannot yet form.
    test('a warning behind an info row still reaches stderr', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            // Same SHAPE, so they really do land in one group: the field is
            // all that differs, and it is what the shape blanks out.
            {
              'code': 'X_CODE',
              'severity': 'info',
              'field': 'k1',
              'message': 'lost something on k1',
            },
            {
              'code': 'X_CODE',
              'severity': 'warning',
              'field': 'k2',
              'message': 'lost something on k2',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      // One line for the group (the shapes match), and it is on stderr
      // because one of its rows is a warning.
      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('X_CODE'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('also on: k2'));
    });

    // #726 — the server now says WHICH language pass lost the string. Two
    // languages losing the same string the same way are two facts, and a line
    // that names neither is the exact damage the issue describes.
    test('a line that covers two languages names both', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'PLURAL_SHAPE_MISMATCH',
              'severity': 'warning',
              'field': 'hola',
              'message': 'The source string is not a plural, so only one form '
                  'of this translation was imported.',
              'lang': 'en',
            },
            {
              'code': 'PLURAL_SHAPE_MISMATCH',
              'severity': 'warning',
              'field': 'hola',
              'message': 'The source string is not a plural, so only one form '
                  'of this translation was imported.',
              'lang': 'fr',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('PLURAL_SHAPE_MISMATCH'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('in: en, fr'));
    });

    test('a single target-only row names its language', () async {
      // No fold happens here at all: the field is invisible on a one-row
      // line, so without the language the row names a string and not the
      // column it was lost from.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'PLURAL_SHAPE_MISMATCH',
              'severity': 'warning',
              'field': 'hola',
              'message': 'The source string is not a plural.',
              'lang': 'fr',
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('PLURAL_SHAPE_MISMATCH'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('in: fr'));
    });

    test('a row only the real run carries is not discarded against the preview',
        () async {
      // The identity of an already-printed row carries the language for the
      // same reason it carries the message (#731): the preview and the real
      // run are two responses, and a row that agrees with a preview row on
      // code, field and message but names a DIFFERENT column is a different
      // fact. Keyed without it, it printed nowhere at all.
      writeCatalog();
      const shared = {
        'code': 'PLURAL_SHAPE_MISMATCH',
        'severity': 'warning',
        'field': 'hola',
        'message': 'The source string is not a plural.',
      };
      await runnerWith(
        (req, calls) {
          final preview = req.url.queryParameters['dryRun'] == 'true';
          return syncBody(
            dryRun: preview,
            diagnostics: [
              {...shared, 'lang': 'en'},
              if (!preview) {...shared, 'lang': 'fr'},
            ],
            trackingToken: preview ? null : 'job1',
          );
        },
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final lines = errOut
          .toString()
          .split('\n')
          .where((l) => l.contains('PLURAL_SHAPE_MISMATCH'))
          .toList();
      // Two lines: the preview's `en` and the run's `fr`, each naming its own.
      expect(lines, hasLength(2));
      expect(lines.first, contains('in: en'));
      expect(lines.last, contains('in: fr'));
    });

    // #1247 — the server lists 10 rows per (code, language) and counts the
    // rest. A line built off the listed rows alone says "covers 20 row(s)"
    // about a catalog that lost 100, so the rest is announced on its own line.
    group('rows the server did not list', () {
      const row = {
        'code': 'PLURAL_SHAPE_MISMATCH',
        'severity': 'warning',
        'field': 'hola',
        'message': 'The source string is not a plural.',
      };
      List<String> linesOf(String code) =>
          errOut.toString().split('\n').where((l) => l.contains(code)).toList();

      test('are counted once, with their languages', () async {
        // Both responses carry the same omission: the preview announces it
        // and the real run, which repeats the same bytes, must not.
        writeCatalog();
        await runnerWith(
          (req, calls) {
            final preview = req.url.queryParameters['dryRun'] == 'true';
            return syncBody(
              dryRun: preview,
              diagnostics: [
                {...row, 'lang': 'en'},
                {...row, 'lang': 'fr'},
              ],
              diagnosticsOmitted: const [
                {'code': 'PLURAL_SHAPE_MISMATCH', 'lang': 'en', 'count': 40},
                {'code': 'PLURAL_SHAPE_MISMATCH', 'lang': 'fr', 'count': 38},
              ],
              trackingToken: preview ? null : 'job1',
            );
          },
        ).run(['--config', writeConfig(), 'sync', '--yes']);

        final lines = linesOf('PLURAL_SHAPE_MISMATCH');
        expect(lines, hasLength(2));
        expect(
          lines.last,
          'warning: PLURAL_SHAPE_MISMATCH: 78 more row(s) the server did not '
          'list — in: en, fr.',
        );
      });

      test('a different count in the real run is announced again', () async {
        // The real run reads the STORED plurals, so its omission can differ
        // from the preview's; the new number is a new fact.
        writeCatalog();
        await runnerWith(
          (req, calls) {
            final preview = req.url.queryParameters['dryRun'] == 'true';
            return syncBody(
              dryRun: preview,
              diagnostics: [
                {...row, 'lang': 'en'},
              ],
              diagnosticsOmitted: [
                {
                  'code': 'PLURAL_SHAPE_MISMATCH',
                  'lang': 'en',
                  'count': preview ? 5 : 7,
                },
              ],
              trackingToken: preview ? null : 'job1',
            );
          },
        ).run(['--config', writeConfig(), 'sync', '--yes']);

        final omitted = linesOf('did not list');
        expect(omitted, hasLength(2));
        expect(omitted.first, contains('5 more row(s)'));
        expect(omitted.last, contains('7 more row(s)'));
      });

      test('names five languages and counts the rest', () async {
        writeCatalog();
        await runnerWith(
          (req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
            diagnostics: [
              {...row, 'lang': 'l0'},
            ],
            diagnosticsOmitted: [
              for (var i = 0; i < 7; i++)
                {'code': 'PLURAL_SHAPE_MISMATCH', 'lang': 'l$i', 'count': 1},
            ],
            trackingToken:
                req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
          ),
        ).run(['--config', writeConfig(), 'sync', '--yes']);

        expect(
          linesOf('did not list').single,
          contains('7 more row(s) the server did not list — '
              'in: l0, l1, l2, l3, l4 (+2 more).'),
        );
      });

      test('an error code goes to stderr', () async {
        writeCatalog();
        await runnerWith(
          (req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
            diagnostics: [
              {...row, 'code': 'X_ERROR', 'severity': 'error'},
            ],
            diagnosticsOmitted: const [
              {'code': 'X_ERROR', 'count': 2},
            ],
            trackingToken:
                req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
          ),
        ).run(['--config', writeConfig(), 'sync', '--yes']);

        expect(
          linesOf('did not list'),
          ['warning: X_ERROR: 2 more row(s) the server did not list.'],
        );
      });

      test('an informational code stays off stderr', () async {
        writeCatalog();
        await runnerWith(
          (req, calls) => syncBody(
            dryRun: req.url.queryParameters['dryRun'] == 'true',
            diagnostics: const [
              {
                'code': 'NOT_TRANSLATABLE',
                'severity': 'info',
                'field': 'k0',
                'message': 'k0 is marked do-not-translate.',
              },
              // A loud code in the same response lends it nothing.
              row,
            ],
            diagnosticsOmitted: const [
              {'code': 'NOT_TRANSLATABLE', 'count': 3},
              // Raw server data, never cast (#972): skipped, not a crash.
              {'code': 'NOT_TRANSLATABLE', 'count': 'many'},
            ],
            trackingToken:
                req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
          ),
        ).run(['--config', writeConfig(), 'sync', '--yes']);

        expect(linesOf('did not list'), isEmpty);
        expect(
          out.toString(),
          contains('NOT_TRANSLATABLE: 3 more row(s) the server did not list.'),
        );
      });
    });

    test('a row with no language prints the line it always printed', () async {
      // The base parse's rows and the membership rows carry no `lang`, and
      // nothing about them may change.
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          diagnostics: const [
            {
              'code': 'SKIPPED_NON_STRING',
              'severity': 'warning',
              'field': 'k0',
              'message': "Key 'k0' has a non-string value; skipped.",
            },
          ],
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      final line = errOut
          .toString()
          .split('\n')
          .firstWhere((l) => l.contains('SKIPPED_NON_STRING'));
      expect(line, isNot(contains('in:')));
    });

    test('a clean parse prints no diagnostic line at all', () async {
      writeCatalog();
      await runnerWith(
        (req, calls) => syncBody(
          dryRun: req.url.queryParameters['dryRun'] == 'true',
          trackingToken:
              req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        ),
      ).run(['--config', writeConfig(), 'sync', '--yes']);

      expect(errOut.toString(), isNot(contains('[')));
    });
  });


}

/// The comma-separated code list a grouped language warning carries, i.e. what
/// sits between the first `: ` after [marker] and the em dash that starts the
/// remedy sentence. Asserting on the LIST rather than on `contains` is what
/// lets a case prove a language is absent from it: `contains('en')` is true of
/// `en-gb` and of the word "written".
List<String> _codesIn(String err, String marker) {
  final line = err
      .split('\n')
      .firstWhere((l) => l.contains(marker), orElse: () => '');
  final match = RegExp(r': ([^:\u2014]+) \u2014').firstMatch(line);
  if (match == null) return const [];
  return match.group(1)!.split(', ').map((s) => s.trim()).toList();
}
