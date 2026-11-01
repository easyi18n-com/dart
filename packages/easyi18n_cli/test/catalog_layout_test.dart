import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:easyi18n_cli/src/sync_runner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Several JSON files per locale (#2093): i18next namespaces and Transloco
// scopes are one catalog on the server, uploaded merged and pulled back split.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('easyi18n_layout'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String rel, Object json) => File(p.join(dir.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(json is String ? json : jsonEncode(json));
  String read(String rel) => File(p.join(dir.path, rel)).readAsStringSync();

  const common = {'save': 'Save', 'welcome': 'Welcome, {name}', 'home.title': 'Home'};
  const translation = {'title': 'Shop', 'save': 'Save'};
  const userProfile = {'pageTitle': 'Profile', 'form': {'save': 'Save'}};
  const root = {'title': 'Shop', 'save': 'Save'};
  const admin = {'title': 'Admin', 'users': 'Users'};

  String config(String layout, {String format = 'json'}) {
    final namespaces = layout == 'namespaces' || layout == 'base-tree';
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync(
      'projectId: p1\nmode: a\nformat: $format\n'
      'output: ${namespaces ? 'locales' : 'public/i18n'}\n'
      'source: ${namespaces ? 'locales/en/translation.json' : 'public/i18n/en.json'}\n'
      'sourceRoot: ${namespaces ? 'locales/en' : 'public/i18n'}\n'
      'sourceLayout: $layout\n',
    );
    return path;
  }

  void i18nextTree() {
    write('locales/en/common.json', common);
    write('locales/en/translation.json', translation);
    write('locales/en/user-profile.json', userProfile);
    write('locales/es/translation.json', '{}');
  }

  void translocoTree({Map<String, String> rootExtra = const {}}) {
    write('public/i18n/en.json', {...root, ...rootExtra});
    write('public/i18n/es.json', '{}');
    write('public/i18n/admin/en.json', admin);
    write('public/i18n/admin/es.json', '{}');
  }

  group('sync uploads the base files as one catalog', () {
    const runner = SyncRunner();

    Future<_Client> preview(String path) async {
      final client = _Client();
      addTearDown(client.close);
      final loaded = Easyi18nConfig.load(File(path));
      await runner.preview(client, 'p1', runner.scan(loaded, configPath: path),
          config: loaded, configPath: path, onConflict: 'server');
      return client;
    }

    test('namespaces: each file under its namespace, in one nested upload', () async {
      i18nextTree();
      final client = await preview(config('namespaces'));
      expect(client.calls, hasLength(1));
      final call = client.calls.single;
      expect(call.dryRun, isTrue);
      expect(call.format, 'nested_json');
      expect(jsonDecode(utf8.decode(call.bytes)), {
        'common': common,
        'translation': translation,
        'user-profile': userProfile,
      });
    });

    test('scopes: root keys bare, each scope under its directory', () async {
      translocoTree();
      final client = await preview(config('scopes'));
      final call = client.calls.single;
      expect(call.format, 'nested_json');
      expect(jsonDecode(utf8.decode(call.bytes)), {...root, 'admin': admin});
    });

    for (final (name, extra) in [
      ('a root key under the scope', {'admin.title': 'x'}),
      ('a root key named like the scope', {'admin': 'x'}),
    ]) {
      test('scopes refuse $name before any request', () async {
        translocoTree(rootExtra: extra);
        final path = config('scopes');
        expect(
          () => runner.scan(Easyi18nConfig.load(File(path)), configPath: path),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'catalog_key_collision')
              .having((e) => e.message, 'message', allOf(
                  contains('public/i18n/en.json'),
                  contains('public/i18n/admin/en.json'),
                  contains(extra.keys.single)))),
        );
      });
    }

    test('the real POST re-sends the previewed bytes under the merged format', () async {
      i18nextTree();
      final path = config('namespaces');
      final client = _Client();
      addTearDown(client.close);
      final loaded = Easyi18nConfig.load(File(path));
      final previewed = await runner.preview(client, 'p1',
          runner.scan(loaded, configPath: path),
          config: loaded, configPath: path, onConflict: 'server');
      await runner.run(client, 'p1', previewed, config: loaded,
          onConflict: 'server', progress: _Progress(), wait: (_) async {},
          random: Random(1), pollTimeout: const Duration(seconds: 1));
      expect(client.calls.map((c) => (c.dryRun, c.format)),
          [(true, 'nested_json'), (false, 'nested_json')]);
      expect(client.calls.last.bytes, client.calls.first.bytes);
    });

    test('a source alias with another name uploads every base scope', () async {
      translocoTree();
      Link(p.join(dir.path, 'public/i18n/base.json')).createSync('en.json');
      final path = config('scopes');
      File(path).writeAsStringSync(File(path).readAsStringSync().replaceFirst(
          'source: public/i18n/en.json', 'source: public/i18n/base.json'));
      final client = await preview(path);
      expect(jsonDecode(utf8.decode(client.calls.single.bytes)),
          {...root, 'admin': admin});
      expect(client.calls.single.format, 'nested_json');
    });

    test('scopes with no scope directory and no nesting upload flat json', () async {
      write('public/i18n/en.json', {...root, '@meta': {'note': 'not a nesting'}});
      final client = await preview(config('scopes'));
      expect(client.calls.single.format, 'json');
    });

    test('an empty namespace file adds nothing to the upload', () async {
      i18nextTree();
      write('locales/en/empty.json', '{}');
      final client = await preview(config('namespaces'));
      expect((jsonDecode(utf8.decode(client.calls.single.bytes)) as Map).keys,
          ['common', 'translation', 'user-profile']);
    });

    test('a key that would fall under a longer namespace is refused', () async {
      write('locales/en/translation.json', translation);
      write('locales/en/a.json', {'b': {'x': 'from a'}});
      write('locales/en/a.b.json', {'y': 'from a.b'});
      final path = config('namespaces');
      expect(
        () => runner.scan(Easyi18nConfig.load(File(path)), configPath: path),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'catalog_key_collision')
            .having((e) => e.details, 'details', {
              'key': 'a.b.x', 'files': ['locales/en/a.json', 'locales/en/a.b.json'],
            })),
      );
    });

    for (final (layout, extra) in [
      ('namespaces', 'locales/en/admin/users.json'),
      ('scopes', 'public/i18n/admin/deep/en.json'),
    ]) {
      test('$layout refuses $extra, which it has no place for', () async {
        layout == 'namespaces' ? i18nextTree() : translocoTree();
        write(extra, {'k': 'v'});
        final path = config(layout);
        expect(
          () => runner.scan(Easyi18nConfig.load(File(path)), configPath: path),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'several_files_per_locale')
              .having((e) => e.details, 'details', {
                'source': layout == 'namespaces'
                    ? 'locales/en/translation.json' : 'public/i18n/en.json',
                'files': [extra],
              })),
        );
      });
    }

    test('scopes need source: directly in sourceRoot, as the root file', () async {
      translocoTree();
      final path = config('scopes');
      File(path).writeAsStringSync(File(path).readAsStringSync()
          .replaceFirst('source: public/i18n/en.json', 'source: public/i18n/admin/en.json'));
      expect(
        () => runner.scan(Easyi18nConfig.load(File(path)), configPath: path),
        throwsA(isA<CliException>().having((e) => e.code, 'code', 'catalog_scope_unknown')),
      );
    });

    for (final (name, content) in [('not JSON', '{"save": '), ('not an object', '["save"]')]) {
      test('a base file that is $name is refused by name', () async {
        i18nextTree();
        write('locales/en/common.json', content);
        final path = config('namespaces');
        expect(
          () => runner.scan(Easyi18nConfig.load(File(path)), configPath: path),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              startsWith('locales/en/common.json is not'))),
        );
      });
    }

    test('base-tree still refuses a second namespace and names the layout that merges', () async {
      i18nextTree();
      await expectLater(
        preview(config('base-tree')),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'several_files_per_locale')
            .having((e) => e.message, 'message', contains('sourceLayout: namespaces'))),
      );
    });
  });

  group('pull writes each language back into the base files\' layout', () {
    CommandRunner<int> pullWith(Map<String, String> files,
        {StringBuffer? err, StringBuffer? out}) {
      TranslationsApiClient factory({required String baseUrl, required String token}) =>
          TranslationsApiClient(baseUrl: baseUrl, token: token,
              httpClient: MockClient((req) async => http.Response(jsonEncode({
                    'project': 'p1', 'version': '2026.10.15.1', 'baseCode': 'en',
                    'formats': ['json', 'nested_json'], 'files': files,
                  }), 200)));
      final logger = CliLogger(out: out ?? StringBuffer(), err: err ?? StringBuffer());
      return CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
        ..addCommand(PullCommand(output: CliOutput(logger: logger),
            apiClientFactory: factory, environment: const {'EASYI18N_TOKEN': 'eik_x'}));
    }

    Map<String, Object?> decoded(String rel) =>
        jsonDecode(read(rel)) as Map<String, Object?>;

    for (final format in ['json', 'nested_json']) {
      test('namespaces from a $format export: each file keeps its sibling\'s keys and shape', () async {
        i18nextTree();
        final before = {
          for (final name in ['common', 'translation', 'user-profile'])
            name: read('locales/en/$name.json'),
        };
        final es = {
          'common': {'home': {'title': 'Inicio'}, 'save': 'Guardar', 'welcome': 'Hola, {name}'},
          'translation': {'save': 'Guardar', 'title': 'Tienda'},
          'user-profile': {'form': {'save': 'Guardar'}, 'pageTitle': 'Perfil'},
        };
        final served = format == 'json'
            ? jsonEncode({
                'common.home.title': 'Inicio', 'common.save': 'Guardar',
                'common.welcome': 'Hola, {name}', 'translation.save': 'Guardar',
                'translation.title': 'Tienda', 'user-profile.form.save': 'Guardar',
                'user-profile.pageTitle': 'Perfil',
              })
            : jsonEncode(es);
        final path = config('namespaces', format: format);
        expect(await pullWith({
          '$format/en.json': '{}',
          '$format/es.json': served,
        }).run(['--config', path, 'pull']), 0);

        expect(decoded('locales/es/common.json'),
            {'save': 'Guardar', 'welcome': 'Hola, {name}', 'home.title': 'Inicio'});
        expect(decoded('locales/es/common.json').keys, ['save', 'welcome', 'home.title']);
        expect(decoded('locales/es/translation.json'), {'title': 'Tienda', 'save': 'Guardar'});
        expect(decoded('locales/es/user-profile.json'),
            {'pageTitle': 'Perfil', 'form': {'save': 'Guardar'}});
        for (final e in before.entries) {
          expect(read('locales/en/${e.key}.json'), e.value, reason: 'base ${e.key}');
        }
        expect(File(p.join(dir.path, 'locales/es.json')).existsSync(), isFalse);
        expect(File(p.join(dir.path, 'locales/en.json')).existsSync(), isFalse);
      });
    }

    test('a key goes to the longest namespace it falls under', () async {
      write('locales/en/a.json', {'y': 'Y'});
      write('locales/en/a.b.json', {'x': 'X'});
      write('locales/en/translation.json', translation);
      final path = config('namespaces');
      expect(await pullWith({
        'json/es.json': jsonEncode({'a.b.x': 'equis', 'a.y': 'i griega',
            'translation.title': 'Tienda', 'translation.save': 'Guardar'}),
      }).run(['--config', path, 'pull']), 0);
      expect(decoded('locales/es/a.b.json'), {'x': 'equis'});
      expect(decoded('locales/es/a.json'), {'y': 'i griega'});
    });

    test('keys the base files lack: kept at the end, or named when no file owns them', () async {
      i18nextTree();
      final err = StringBuffer();
      final path = config('namespaces');
      expect(await pullWith({
        'json/es.json': jsonEncode({
          'common.extra': 'Extra', 'common.save': 'Guardar', 'stray.key': 'x',
          'translation': 'leaf', 'translation.title': 'Tienda',
        }),
      }, err: err).run(['--config', path, 'pull']), 0);
      expect(decoded('locales/es/common.json').keys, ['save', 'extra']);
      expect(decoded('locales/es/translation.json'), {'title': 'Tienda'});
      expect(decoded('locales/es/user-profile.json'), isEmpty);
      expect(err.toString(), allOf(contains('es: 2 key(s)'),
          contains('stray.key'), contains('translation')));
    });

    test('a temporary target alias cannot overwrite another base file', () async {
      i18nextTree();
      final path = config('namespaces');
      final before = read('locales/en/user-profile.json');
      Link(p.join(dir.path, 'locales/es/common.json.tmp'))
          .createSync('../en/user-profile.json');
      await expectLater(pullWith({
        'json/es.json': jsonEncode({'common.save': 'Guardar'}),
      }).run(['--config', path, 'pull']),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'source_collision')));
      expect(read('locales/en/user-profile.json'), before);
    });

    test('a recorded base file the server no longer serves is not pruned', () async {
      i18nextTree();
      final path = config('namespaces');
      CliState(format: 'json', output: 'locales',
              files: ['en/common.json', 'es/common.json'])
          .save(CliState.fileFor(path));
      expect(await pullWith({
        'json/es.json': jsonEncode({'common.save': 'Guardar'}),
      }).run(['--config', path, 'pull']), 0);
      expect(read('locales/en/common.json'), jsonEncode(common));
    });

    test('an edited base file in an older record does not stop the pull', () async {
      i18nextTree();
      final path = config('namespaces');
      CliState(format: 'json', output: 'locales',
              files: ['en/common.json', 'es/common.json'],
              digests: {'en/common.json': contentDigest(read('locales/en/common.json'))})
          .save(CliState.fileFor(path));
      write('locales/en/common.json', {...common, 'extra': 'Extra'});
      expect(await pullWith({
        'json/es.json': jsonEncode({'common.save': 'Guardar'}),
      }).run(['--config', path, 'pull']), 0);
    });

    test('no hint calls a base file stale', () async {
      i18nextTree();
      final path = config('namespaces');
      final first = StringBuffer();
      expect(await pullWith({'json/es.json': '{}'}, out: first)
          .run(['--config', path, 'pull']), 0);
      CliState(format: 'json', output: 'locales/en', files: ['common.json'])
          .save(CliState.fileFor(path));
      final switched = StringBuffer();
      expect(await pullWith({'json/es.json': '{}'}, out: switched)
          .run(['--config', path, 'pull']), 0);
      expect(first.toString(),
          allOf(contains('Pulled'), isNot(contains('Not written by this pull'))));
      expect(switched.toString(),
          allOf(contains('Pulled'), isNot(contains('no longer manages'))));
    });

    test('a served file that is not an object is refused, writing nothing', () async {
      i18nextTree();
      final path = config('namespaces');
      await expectLater(
        pullWith({'json/es.json': '["x"]'}).run(['--config', path, 'pull']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('The served es file is not a JSON object'))),
      );
      expect(Directory(p.join(dir.path, 'locales/es')).listSync(), hasLength(1));
    });

    test('a source alias uses the served base language to split scopes', () async {
      translocoTree();
      Link(p.join(dir.path, 'public/i18n/base.json')).createSync('en.json');
      final path = config('scopes');
      File(path).writeAsStringSync(File(path).readAsStringSync().replaceFirst(
          'source: public/i18n/en.json', 'source: public/i18n/base.json'));
      expect(await pullWith({
        'json/es.json': jsonEncode({'title': 'Tienda', 'save': 'Guardar',
          'admin.title': 'Administración', 'admin.users': 'Usuarios'}),
      }).run(['--config', path, 'pull']), 0);
      expect(decoded('public/i18n/es.json'), {'title': 'Tienda', 'save': 'Guardar'});
      expect(decoded('public/i18n/admin/es.json'),
          {'title': 'Administración', 'users': 'Usuarios'});
      expect(decoded('public/i18n/admin/en.json'), admin);
    });

    test('scopes: the root file and each scope file, no scope prefix inside', () async {
      translocoTree();
      final rootBefore = read('public/i18n/en.json');
      final adminBefore = read('public/i18n/admin/en.json');
      final path = config('scopes');
      expect(await pullWith({
        'json/en.json': '{}',
        'json/es.json': jsonEncode({
          'admin.title': 'Administración', 'admin.users': 'Usuarios',
          'save': 'Guardar', 'title': 'Tienda',
        }),
      }).run(['--config', path, 'pull']), 0);
      expect(decoded('public/i18n/es.json'), {'title': 'Tienda', 'save': 'Guardar'});
      expect(decoded('public/i18n/admin/es.json'),
          {'title': 'Administración', 'users': 'Usuarios'});
      expect(read('public/i18n/en.json'), rootBefore);
      expect(read('public/i18n/admin/en.json'), adminBefore);
    });
  });
}

class _Progress implements SyncRunProgress {
  @override
  void onResponse(SyncResult result) {}
  @override
  void onContendedRetry({required List<String> keys, required Duration delay,
      required int attempt, required int max}) {}
  @override
  void onJobTimedOut({required bool abandoned}) {}
  @override
  void onFillRetry({required int pairs, required int attempt, required int max}) {}
  @override
  void onShortfall({required int pairs, required int retries}) {}
}

class _SyncCall {
  _SyncCall(this.bytes, this.format, this.dryRun);
  final List<int> bytes;
  final String? format;
  final bool dryRun;
}

class _Client extends TranslationsApiClient {
  _Client() : super(baseUrl: 'http://localhost', token: 'test');

  final calls = <_SyncCall>[];

  @override
  Future<ProjectMeta> fetchMeta({required String projectId}) async =>
      ProjectMeta(currentVersionId: '', baseCode: 'en');

  @override
  Future<SyncResult> sync({
    required String projectId,
    required String fileName,
    required List<int> bytes,
    String? format,
    bool dryRun = false,
    String? onConflict,
    DateTime? pulledAt,
    String? lang,
    Map<String, Object?> identity = const {},
  }) async {
    calls.add(_SyncCall(bytes, format, dryRun));
    return SyncResult(
      dryRun: dryRun, created: 0, updatedSources: 0, matchedSources: 0,
      updatedTranslations: 0, unchangedTranslations: 0, disabledOrphans: 0,
      reenabled: 0, failedEntries: const [], exhausted: const [],
      conflicts: const [], conflictsTotal: 0, diagnostics: const [],
      onConflict: 'server', trackingToken: null, estimatedCredits: 0,
      balance: 0, availableCredits: null, accepted: true, skippedGated: 0,
      notInCode: 0, wouldExceedKeyCap: false,
    );
  }
}
