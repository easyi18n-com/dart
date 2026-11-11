@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/state.dart' show changedSincePullFinding, contentDigest;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show agentRefusal, errorOf, project;

String _package(Map<String, String> deps, {String section = 'dependencies'}) =>
    jsonEncode({'name': 'demo-shop', section: deps});

const _translocoConfig = '''
import { TranslocoGlobalConfig } from '@jsverse/transloco-utils';

const config: TranslocoGlobalConfig = {
  rootTranslationsPath: 'public/i18n/',
  langs: ['en', 'es'],
  keysManager: {},
};

export default config;
''';

/// What `ng add @jsverse/transloco --langs=en,es` leaves on an `ng new` tree.
final _translocoTree = {
  'package.json': _package({'@jsverse/transloco': '^8.4.0'}),
  'transloco.config.ts': _translocoConfig,
  'public/i18n/en.json': '{}\n',
  'public/i18n/es.json': '{}\n',
};

/// The i18next default layout (`loadPath: '/locales/{{lng}}/{{ns}}.json'`)
/// with the three namespaces of the acceptance of #2093.
final _namespacesTree = {
  'package.json': _package({'i18next': '^26.4.2', 'i18next-http-backend': '^4.0.2'}),
  'locales/en/common.json':
      '{"save": "Save", "welcome": "Welcome, {name}", "home.title": "Home"}\n',
  'locales/en/translation.json': '{"title": "Shop", "save": "Save"}\n',
  'locales/en/user-profile.json':
      '{"pageTitle": "Profile", "form": {"save": "Save"}}\n',
  'locales/es/translation.json': '{}\n',
};

/// A Transloco root file with the scope `admin` one directory down.
final _scopesTree = {
  'package.json': _package({'@jsverse/transloco': '^8.4.0'}),
  'public/i18n/en.json': '{"title": "Shop", "save": "Save"}\n',
  'public/i18n/es.json': '{}\n',
  'public/i18n/admin/en.json': '{"title": "Admin", "users": "Users"}\n',
  'public/i18n/admin/es.json': '{}\n',
};

const _ref = {'workspace': 'demo', 'project': 'demo-shop'};

/// Every file under [dir] with its bytes: what a dry run must leave equal.
Map<String, String> _snapshot(Directory dir) => {
  for (final file in dir.listSync(recursive: true).whereType<File>())
    p.relative(file.path, from: dir.path): file.readAsStringSync(),
};

void main() {
  late Directory dir;
  late McpHarness harness;

  Future<void> start(Map<String, String> files,
      {String? config,
      http.Client? httpClient,
      Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_test'}}) async {
    final fixture = project(
        config: config,
        files: files,
        environment: environment,
        // Never the real client: `doctor` asks the API whenever it holds a
        // key, and the default `baseUrl` is production.
        httpClient:
            httpClient ?? MockClient((_) async => http.Response('{}', 404)));
    dir = fixture.dir;
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
  }

  List<Map<String, Object?>> stepsOf(CallToolResult result) =>
      (result.structuredContent!['steps'] as List).cast<Map<String, Object?>>();

  String yaml() {
    final file = File(p.join(dir.path, 'easyi18n.yaml'));
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  test('init over MCP detects an Android tree and plans android_xml (#2285)',
      () async {
    await start({
      'settings.gradle': "include ':app'\n",
      'app/src/main/res/values/strings.xml':
          '<resources><string name="hi">Hi</string></resources>',
    });
    final result = await harness.call('init', {..._ref, 'stack': 'auto'});
    expect(result.structuredContent!['stack'], 'android');
    expect(yaml(), allOf(contains('\nformat: android_xml\n'),
        contains('\nsource: app/src/main/res/values/strings.xml\n'),
        contains('\noutput: app/src/main/res\n')));
  });

  group('init on a Transloco tree', () {
    test('auto detects web and a dry run names every step and writes nothing',
        () async {
      await start(_translocoTree);
      final before = _snapshot(dir);

      final result =
          await harness.call('init', {..._ref, 'stack': 'auto', 'dry_run': true});
      final report = result.structuredContent!;
      expect(report['stack'], 'web');
      expect(report['family'], 'file-first');
      expect(report['next'], 'sync');
      final targets = [for (final s in stepsOf(result)) s['target']];
      expect(targets, contains(p.join(dir.path, 'easyi18n.yaml')));
      expect(targets, contains(p.join(dir.path, 'public', 'i18n', 'en.json')));
      final details = stepsOf(result).map((s) => s['detail']).join('\n');
      expect(details, contains('@jsverse/transloco-messageformat'));
      expect(stepsOf(result), contains(containsPair('detail',
          'install @jsverse/transloco-messageformat with your package manager so '
          '@jsverse/transloco reads ICU, then wire it:')));
      expect(report['scope_snippet'], contains('provideTranslocoMessageformat()'));
      expect(_snapshot(dir), before);
    });

    test('writes a per-locale config and a second run keeps it', () async {
      await start(_translocoTree);
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\nformat: json\n'));
      expect(yaml(), contains('\noutput: public/i18n\n'));
      expect(yaml(), contains('\nsource: public/i18n/en.json\nsourceRoot: public/i18n\nsourceLayout: locale-files\n'));
      final loaded = Easyi18nConfig.load(File(p.join(dir.path, 'easyi18n.yaml')));
      expect(loaded.sourceRoot, 'public/i18n');
      expect(loaded.sourceLayout, 'locale-files');
      expect(yaml(), isNot(contains('catalog:')));
      expect(yaml(), contains('\nmode: a\n'));

      final written = _snapshot(dir);
      final again = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(stepsOf(again).first['detail'], 'kept existing config');
      expect(_snapshot(dir), written);
    });

    // What a config that escapes would create, were it followed: removed
    // either way, so a red run leaves nothing behind in the temp directory.
    final escape = p.join(Directory.systemTemp.path, 'web_adapter_escape');
    for (final entry in {
      'a rootTranslationsPath that leaves the project': _translocoConfig
          .replaceFirst('public/i18n/', '../web_adapter_escape/i18n/'),
      'an absolute rootTranslationsPath':
          _translocoConfig.replaceFirst('public/i18n/', '$escape/i18n/'),
      'a language that is a path': _translocoConfig.replaceFirst(
          "['en', 'es']", "['../../outside', 'es']"),
    }.entries) {
      test('${entry.key} is not followed', () async {
        addTearDown(() {
          final created = Directory(escape);
          if (created.existsSync()) created.deleteSync(recursive: true);
        });
        await start({..._translocoTree, 'transloco.config.ts': entry.value});
        await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(yaml(), contains('\noutput: public/i18n\n'));
        expect(yaml(), contains('\nsource: public/i18n/en.json\nsourceRoot: public/i18n\nsourceLayout: locale-files\n'));
        expect(Directory(escape).existsSync(), isFalse);
        expect(File(p.join(dir.path, 'outside.json')).existsSync(), isFalse);
      });
    }

    test('a nested base file is nested_json, and init leaves its bytes alone',
        () async {
      const base = '{"home": {"title": "Hello"}}';
      await start({..._translocoTree, 'public/i18n/en.json': base});
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\nformat: nested_json\n'));
      expect(File(p.join(dir.path, 'public', 'i18n', 'en.json')).readAsStringSync(),
          base);
    });

    test('the base language is the first of langs, not en by habit', () async {
      await start({
        ..._translocoTree,
        'transloco.config.ts': _translocoConfig
            .replaceFirst("['en', 'es']", "['es', 'en']")
            .replaceFirst('public/i18n/', 'src/assets/i18n'),
        'src/assets/i18n/es.json': '{}',
        'src/assets/i18n/en.json': '{}',
      });
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\noutput: src/assets/i18n\n'));
      expect(yaml(), contains('\nsource: src/assets/i18n/es.json\n'));
    });
  });

  group('init on the other libraries', () {
    test('i18next with no catalog creates the base file and names i18next-icu',
        () async {
      await start({'package.json': _package({'i18next': '^26.0.0'})});
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(result.structuredContent!['stack'], 'web');
      final base = File(p.join(dir.path, 'locales', 'en.json'));
      expect(base.existsSync(), isTrue);
      expect(base.readAsStringSync(), '{}\n');
      final created = stepsOf(result).singleWhere((s) => s['target'] == base.path);
      expect(created['verb'], 'created');
      expect(yaml(), contains('\nsource: locales/en.json\nsourceRoot: locales\nsourceLayout: locale-files\n'));
      final details = stepsOf(result).map((s) => s['detail']).join('\n');
      expect(details, contains('i18next-icu'));
      expect(details, contains('intl-messageformat'));
      final snippet = result.structuredContent!['scope_snippet'];
      expect(snippet, contains('i18next.use(ICU)'));
      // A server instance of its own needs the plugin too (#2574).
      expect(snippet, contains('Every instance registers it'));
      expect(snippet, contains('createInstance().use(ICU)'));
      expect(snippet, contains('plugins: [ICU]'));
    });

    test('ngx-translate under devDependencies names its compiler', () async {
      await start({
        'package.json': _package({'@ngx-translate/core': '^18.0.0'},
            section: 'devDependencies'),
        'public/i18n/fr.json': '{"hello": "Bonjour"}',
      });
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(result.structuredContent!['stack'], 'web');
      // The only file in the directory is the base, whatever its language.
      expect(yaml(), contains('\nsource: public/i18n/fr.json\n'));
      final details = stepsOf(result).map((s) => s['detail']).join('\n');
      expect(details, contains('ngx-translate-messageformat-compiler'));
      expect(details, contains('@messageformat/core'));
      expect(result.structuredContent!['scope_snippet'],
          contains('provideTranslateCompiler(TranslateMessageFormatCompiler)'));
    });

    test('a transpiler already installed is reported as present', () async {
      await start({
        ..._translocoTree,
        'package.json': _package({
          '@jsverse/transloco': '^8.4.0',
          '@jsverse/transloco-messageformat': '^8.4.0',
        }),
      });
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(stepsOf(result), contains(containsPair('detail',
          '@jsverse/transloco-messageformat present - it reads ICU once wired:')));
      final step = stepsOf(result).singleWhere(
          (s) => '${s['detail']}'.contains('@jsverse/transloco-messageformat'));
      expect(step['verb'], 'ok');
      expect(result.structuredContent!['scope_snippet'],
          contains('provideTranslocoMessageformat()'));
    });

    for (final entry in {
      'en.json is the base among several files': (['de', 'en', 'fr'], 'en'),
      'with no English file the first by name is the base': (['fr', 'de'], 'de'),
    }.entries) {
      test(entry.key, () async {
        final (langs, base) = entry.value;
        await start({
          'package.json': _package({'@ngx-translate/core': '^18.0.0'}),
          for (final lang in langs) 'src/assets/i18n/$lang.json': '{}',
          'src/assets/i18n/000-readme.txt': 'Not a catalog',
          'src/assets/i18n/000-folder.json/child.txt': 'Not a catalog',
        });
        await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(yaml(), contains('\noutput: src/assets/i18n\n'));
        expect(yaml(), contains('\nsource: src/assets/i18n/$base.json\n'));
      });
    }

    test('mode b is ignored with a step: file-first is Mode A', () async {
      await start(_translocoTree);
      final result =
          await harness.call('init', {..._ref, 'stack': 'auto', 'mode': 'b'});
      expect(yaml(), contains('\nmode: a\n'));
      expect(stepsOf(result), contains(containsPair('target', 'mode')));
      final skipped = stepsOf(result).singleWhere((s) => s['target'] == 'mode');
      expect(skipped['verb'], 'skipped');
    });

    test('an explicit output wins over the detected directory', () async {
      await start(_translocoTree);
      await harness.call('init', {..._ref, 'stack': 'auto', 'output': 'dist/i18n'});
      expect(yaml(), contains('\noutput: dist/i18n\n'));
      expect(yaml(), contains('\nsource: public/i18n/en.json\nsourceRoot: public/i18n\nsourceLayout: locale-files\n'));
      final loaded = Easyi18nConfig.load(File(p.join(dir.path, 'easyi18n.yaml')));
      expect(loaded.sourceRoot, 'public/i18n');
      expect(loaded.sourceLayout, 'locale-files');
    });
  });

  group('init on several files per locale (#2093)', () {
    String agentsWeb() {
      final agents = File(p.join(dir.path, 'AGENTS.md')).readAsStringSync();
      return agents.substring(agents.indexOf('### Web'));
    }

    test('i18next namespaces: the base-language directory is the source root, '
        'and no file is created', () async {
      await start(_namespacesTree);
      final before = _snapshot(dir);
      final dry =
          await harness.call('init', {..._ref, 'stack': 'auto', 'dry_run': true});
      expect(_snapshot(dir), before);

      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\nformat: json\n'));
      expect(yaml(), contains('\noutput: locales\n'));
      expect(yaml(), contains('\nsource: locales/en/translation.json\n'
          'sourceRoot: locales/en\nsourceLayout: namespaces\n'));
      final locales = _snapshot(dir)
        ..removeWhere((path, _) => !p.isWithin('locales', path));
      expect(locales, {
        for (final e in before.entries)
          if (p.isWithin('locales', e.key)) e.key: e.value,
      });
      for (final steps in [stepsOf(dry), stepsOf(result)]) {
        expect(steps, contains(containsPair('detail',
            'i18next (one JSON file per namespace and locale)')));
        final namespaces = steps.singleWhere(
            (s) => s['target'] == p.join(dir.path, 'locales', 'en'));
        expect(namespaces['verb'], 'ok');
        expect(namespaces['detail'], contains(
            '3 i18next namespace file(s): common.json, translation.json, '
            'user-profile.json'));
        expect(steps.where((s) => s['verb'] == 'created'),
            everyElement(isNot(containsPair('target',
                startsWith(p.join(dir.path, 'locales'))))));
      }

      final again = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(stepsOf(again).first['detail'], 'kept existing config');
      expect(stepsOf(again), contains(containsPair('target',
          p.join(dir.path, 'locales', 'en'))));
    });

    test('Transloco scopes: the root file is the source and a step names each '
        'scope', () async {
      await start(_scopesTree);
      final before = _snapshot(dir);
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\nformat: json\n'));
      expect(yaml(), contains('\noutput: public/i18n\n'));
      expect(yaml(), contains('\nsource: public/i18n/en.json\n'
          'sourceRoot: public/i18n\nsourceLayout: scopes\n'));
      expect(stepsOf(result), contains(containsPair('detail',
          '@jsverse/transloco (one JSON file per locale and scope)')));
      final root = stepsOf(result).singleWhere(
          (s) => s['target'] == p.join(dir.path, 'public', 'i18n', 'en.json'));
      expect(root['verb'], 'ok');
      expect(root['detail'], contains('1 Transloco scope(s): admin'));
      final public = _snapshot(dir)
        ..removeWhere((path, _) => !p.isWithin('public', path));
      expect(public, {
        for (final e in before.entries)
          if (p.isWithin('public', e.key)) e.key: e.value,
      });
    });

    // The scope file is named after the base `langs` declares, not `en.json`.
    test('a scope is found by the declared base language', () async {
      await start({
        'package.json': _package({'@jsverse/transloco': '^8.4.0'}),
        'transloco.config.ts': _translocoConfig
            .replaceFirst("['en', 'es']", "['de', 'en']")
            .replaceFirst('public/i18n/', 'src/assets/i18n'),
        'src/assets/i18n/de.json': '{"title": "Laden"}',
        'src/assets/i18n/en.json': '{"title": "Shop"}',
        'src/assets/i18n/admin/de.json': '{"users": "Benutzer"}',
      });
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\nsource: src/assets/i18n/de.json\n'
          'sourceRoot: src/assets/i18n\nsourceLayout: scopes\n'));
      final root = stepsOf(result).singleWhere((s) =>
          s['target'] == p.join(dir.path, 'src', 'assets', 'i18n', 'de.json'));
      expect(root['detail'], contains('1 Transloco scope(s): admin'));
    });

    test('a kept config is described by its own layout, not by detection',
        () async {
      await start(_translocoTree, config: 'projectId: proj_abc\nmode: a\n'
          'format: json\noutput: public/i18n\nsource: public/i18n/en.json\n'
          'sourceRoot: public/i18n\nsourceLayout: scopes\n');
      final result = await harness.call('init', {'stack': 'auto'});
      expect(stepsOf(result).first['detail'], 'kept existing config');
      final root = stepsOf(result).singleWhere(
          (s) => s['target'] == p.join(dir.path, 'public', 'i18n', 'en.json'));
      expect(root['detail'], 'base catalog to sync, with no Transloco scope '
          'yet (edit `source:` if another file is the base)');
    });

    // `doctor` compares the block's sha, so a one-file project keeps its text.
    test('the AGENTS.md block names the files the layout syncs', () async {
      await start(_namespacesTree);
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(agentsWeb(), contains(
          '- The base-language files in `locales/en/`, one per namespace, are '
          'the truth:'));
      expect(agentsWeb(), isNot(contains('translation.json')));

      await start(_scopesTree);
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(agentsWeb(), contains(
          '- The base-language file `public/i18n/en.json` and the `en.json` of '
          'each scope directory beside it are the truth:'));

      await start(_translocoTree);
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(agentsWeb(), startsWith('''### Web

- The base-language file `public/i18n/en.json` is the truth: add and edit user-facing strings there as ICU
  (`{name}`, `{count, plural, one {...} other {...}}`) and read them through
  your i18n library.
- The other locale files in `public/i18n/` are written by
  easyi18n: do not hand-edit them.
- Never edit .easyi18n/: it is generated.
'''));
    });

    for (final entry in {
      'en among several languages is the base': (['de', 'en', 'fr'], 'en'),
      // `.cache`, `_shared` and `ar` sort before `de`.
      'with no en the first language by name is the base': (['fr', 'de'], 'de'),
    }.entries) {
      test(entry.key, () async {
        final (langs, base) = entry.value;
        await start({
          'package.json': _package({'i18next': '^26.4.2'}),
          for (final lang in langs) 'locales/$lang/common.json': '{"a": "A"}',
          'locales/.cache/common.json': '{}',
          'locales/_shared/common.json': '{}',
          // A language with no namespace file yet is not the base either.
          'locales/ar/notes.txt': 'Not a catalog',
        });
        await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(yaml(), contains('\nsource: locales/$base/common.json\n'
            'sourceRoot: locales/$base\nsourceLayout: namespaces\n'));
      });
    }

    test('with no translation.json the source is the first namespace by name',
        () async {
      await start({
        'package.json': _package({'i18next': '^26.4.2'}),
        'locales/en/zeta.json': '{"a": "A"}',
        'locales/en/common.json': '{"b": {"c": "C"}}',
      });
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\nsource: locales/en/common.json\n'));
      // The upload declares the merged format; `format:` only picks the
      // export, and the flat one drops no child of a key that is a leaf.
      expect(yaml(), contains('\nformat: json\n'));
    });

    test('namespaces under public/locales, where a React app serves the '
        'default loadPath', () async {
      await start({
        'package.json': _package({'i18next': '^26.4.2', 'react-i18next': '^16.0.0'}),
        'public/locales/en/translation.json': '{"title": "Shop"}',
        'public/locales/es/translation.json': '{}',
      });
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\noutput: public/locales\n'));
      expect(yaml(), contains('\nsource: public/locales/en/translation.json\n'
          'sourceRoot: public/locales/en\nsourceLayout: namespaces\n'));
      expect(File(p.join(dir.path, 'locales', 'en.json')).existsSync(), isFalse);
    });

    // Each layout is its library's default. Anywhere else a second file stays
    // a refusal at sync time instead of an upload nobody chose.
    for (final entry in {
      'ngx-translate loads one file per language': {
        'package.json': _package({'@ngx-translate/core': '^18.0.0'}),
        'public/i18n/en.json': '{}',
        'public/i18n/admin/en.json': '{}',
      },
      'Transloco does not read language directories': {
        'package.json': _package({'@jsverse/transloco': '^8.4.0'}),
        'public/i18n/en/common.json': '{}',
      },
      'a hidden directory is no scope': {
        ..._translocoTree,
        'public/i18n/.cache/en.json': '{}',
      },
      'a directory without the base file is no scope': {
        ..._translocoTree,
        'public/i18n/admin/es.json': '{}',
      },
      'i18next with a file per locale keeps it': {
        'package.json': _package({'i18next': '^26.4.2'}),
        'locales/en.json': '{}',
        'locales/en/extra.json': '{}',
      },
    }.entries) {
      test('${entry.key}: init writes locale-files', () async {
        await start(entry.value);
        final result = await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(yaml(), contains('\nsourceLayout: locale-files\n'));
        expect(stepsOf(result).map((s) => s['detail']).join('\n'),
            allOf(contains('(one JSON file per locale)'),
                isNot(contains('scope(s)')), isNot(contains('namespace'))));
      });
    }

    test('language directories in locales/ do not move a Transloco catalog',
        () async {
      await start({
        'package.json': _package({'@jsverse/transloco': '^8.4.0'}),
        'locales/en/common.json': '{}',
      });
      await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(yaml(), contains('\noutput: public/i18n\n'));
    });

    test('the config init writes for namespaces is the one sync_preview '
        'uploads as one catalog', () async {
      final requests = <http.Request>[];
      await start(_namespacesTree, httpClient: MockClient((req) async {
        requests.add(req);
        if (req.url.path.endsWith('/meta')) {
          return http.Response('{"baseCode":"en"}', 200);
        }
        return http.Response(jsonEncode({
          'dryRun': true, 'batchSha256': 'd' * 64, 'format': 'nested_json',
          'baseCode': 'en', 'targetLangs': ['es'], 'fillableLangs': ['es'],
          'created': 7, 'updatedSources': 0, 'matchedSources': 0,
          'updatedTranslations': 0, 'unchangedTranslations': 0,
          'disabledOrphans': 0, 'reenabled': 0, 'failedEntries': [],
          'exhausted': [], 'budgetExhausted': [], 'onConflict': 'server',
          'conflicts': [], 'conflictsTotal': 0, 'diagnostics': [],
          'trackingToken': null, 'estimatedCredits': 2000, 'balance': 900000,
          'availableCredits': 900000, 'accepted': true,
        }), 200);
      }));
      final init = await harness
          .call('init', {'project_id': 'proj_abc', 'stack': 'auto'});
      expect(init.isError, isNot(true));
      final result = await harness.call('sync_preview');
      expect(result.isError, isNot(true));
      final sync = requests.singleWhere((r) => r.url.path.endsWith('/sync'));
      final body = jsonDecode(sync.body) as Map;
      expect(body['format'], 'nested_json');
      final uploaded =
          jsonDecode(utf8.decode(base64Decode(body['contentBase64'] as String)));
      expect((uploaded as Map).keys,
          unorderedEquals(['common', 'translation', 'user-profile']));
    });
  });

  group('detection', () {
    for (final entry in {
      'no i18n library': _package({'@angular/core': '^22.2.0'}),
      'a package.json that is not JSON': '{"dependencies": ',
      'a package.json that is not an object': '[]',
      'a library named only in scripts':
          '{"scripts": {"i18next": "echo"}, "dependencies": []}',
    }.entries) {
      // An agent asked to set easyi18n up read the libraries web looks for as
      // the next step and installed one (#2470): the refusal names none.
      test('${entry.key} is refused without naming what web looks for',
          () async {
        await start({'package.json': entry.value});
        final result = await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(result.isError, isTrue);
        final error = errorOf(result);
        expect(error['code'], 'unsupported_stack');
        expect(error['supported'], ['flutter', 'xcode', 'web', 'android', 'angular']);
        // Web is supported through its catalogs; reading `t()` calls out of the
        // source is still to come, and the list says so.
        expect(error['roadmap'], ['web t() extraction', 'gettext']);
        expect(error['message'],
            agentRefusal('No supported stack found at ${dir.path}'));
        expect(File(p.join(dir.path, 'easyi18n.yaml')).existsSync(), isFalse);
      });
    }

    test('a Flutter tree that names i18next stays Flutter', () async {
      await start({
        'pubspec.yaml': 'name: demo\nflutter:\n',
        'package.json': _package({'i18next': '^26.0.0'}),
      });
      final result = await harness.call('init',
          {..._ref, 'stack': 'auto', 'dry_run': true});
      expect(result.structuredContent!['stack'], 'flutter');
    });

    test('an Xcode tree that names i18next stays Xcode', () async {
      await start({
        'Demo.xcodeproj/project.pbxproj': '',
        'Demo/Localizable.xcstrings':
            '{"sourceLanguage":"en","version":"1.0","strings":{}}',
        'package.json': _package({'i18next': '^26.0.0'}),
      });
      final result = await harness.call('init',
          {..._ref, 'stack': 'auto', 'dry_run': true});
      expect(result.structuredContent!['stack'], 'xcode');
    });

    // In corrida 8 an agent named `web` on such a tree and got a web config
    // written as success, where `auto` refuses it (#2444).
    test('stack web on a tree with no library is refused like auto', () async {
      await start({'package.json': '{}'});
      final result = await harness.call('init', {..._ref, 'stack': 'web'});
      expect(result.isError, isTrue);
      final error = errorOf(result);
      expect(error['code'], 'unsupported_stack');
      expect(error['supported'], ['flutter', 'xcode', 'web', 'android', 'angular']);
      expect(error['roadmap'], ['web t() extraction', 'gettext']);
      expect(error['message'],
          agentRefusal('No web project found at ${dir.path}'));
      expect(_snapshot(dir), {'package.json': '{}'});
    });

    // What naming a stack is still for (#2311): a web app that commits its
    // android/ project is both, and the name picks one.
    test('a named stack picks among the stacks the tree has', () async {
      final hybrid = {
        'package.json': _package({'i18next': '^26.0.0'}),
        'public/locales/en/translation.json': '{"hello": "Hello"}\n',
        'android/settings.gradle': "include ':app'\n",
        'android/app/src/main/AndroidManifest.xml': '<manifest/>\n',
        'android/app/src/main/res/values/strings.xml':
            '<resources><string name="app_name">App</string></resources>\n',
      };
      await start(hybrid);
      for (final (named, expected) in [
        ('auto', 'web'), ('web', 'web'), ('android', 'android'),
      ]) {
        final result = await harness.call('init',
            {..._ref, 'stack': named, 'dry_run': true});
        expect(result.isError, isNot(true), reason: named);
        expect(result.structuredContent!['stack'], expected, reason: named);
      }

      // Without the manifest, and with no Gradle script at the root, that
      // android/ is no Android project to choose.
      await start({...hybrid}..remove('android/app/src/main/AndroidManifest.xml'));
      final result = await harness.call('init',
          {..._ref, 'stack': 'android', 'dry_run': true});
      expect(result.isError, isTrue);
      expect(errorOf(result)['code'], 'unsupported_stack');
      // Web still detects there, so that is the stack to name, not a reason
      // to tell the human the repository is unsupported (#2470).
      expect(errorOf(result)['message'],
          startsWith('No android project found at ${dir.path} '
              '(detected there: web). '));
    });
  });

  group('after init', () {
    const config = 'projectId: proj_abc\nmode: a\nformat: json\n'
        'output: public/i18n\nsource: public/i18n/en.json\nsourceRoot: public/i18n\nsourceLayout: locale-files\n';
    final tree = {
      ..._translocoTree,
      'public/i18n/en.json': '{"hello": "Hello", "bye": "Bye {name}"}',
    };

    for (final entry in {
      'extract': 'sync_preview',
      'push_preview': 'sync_preview',
      'push': 'sync',
      // The write-back of a file-first project is `pull`, as it is for Xcode.
      'apply': 'pull',
    }.entries) {
      test('${entry.key} answers wrong_family naming ${entry.value}', () async {
        await start(tree, config: config);
        final error = errorOf(await harness.call(entry.key));
        expect(error['code'], 'wrong_family');
        expect(error['stack'], 'web');
        expect(error['family'], 'file-first');
        expect(error['use_instead'], entry.value);
      });
    }

    test('sync_preview uploads the file source: names', () async {
      final requests = <http.Request>[];
      await start(tree, config: config, httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(jsonEncode({
          'dryRun': true, 'batchSha256': 'd' * 64, 'format': 'json',
          'baseCode': 'en', 'targetLangs': ['es'], 'fillableLangs': ['es'],
          'created': 2, 'updatedSources': 0, 'matchedSources': 0,
          'updatedTranslations': 0, 'unchangedTranslations': 0,
          'disabledOrphans': 0, 'reenabled': 0, 'failedEntries': [],
          'exhausted': [], 'budgetExhausted': [], 'onConflict': 'server',
          'conflicts': [], 'conflictsTotal': 0, 'diagnostics': [],
          'trackingToken': null, 'estimatedCredits': 2000, 'balance': 900000,
          'availableCredits': 900000, 'accepted': true,
        }), 200);
      }));
      final result = await harness.call('sync_preview');
      expect(result.isError, isNot(true));
      expect(result.structuredContent!['catalog'],
          p.join('public', 'i18n', 'en.json'));
      final sync = requests.singleWhere((r) => r.url.path.endsWith('/sync'));
      final body = jsonDecode(sync.body) as Map;
      expect(body['fileName'], 'en.json');
      expect(body['format'], 'json');
      expect(utf8.decode(base64Decode(body['contentBase64'] as String)),
          tree['public/i18n/en.json']);
      // A target-only pull stamps the snapshot, so a per-locale project has
      // no stamp that describes its base file (#2084, fact 2).
      expect(body.containsKey('pulledAt'), isFalse);
    });

    test('sync_preview names a source: that is not on disk', () async {
      await start({'package.json': tree['package.json']!}, config: config);
      final error = errorOf(await harness.call('sync_preview'));
      expect(error['message'],
          contains(p.join('public', 'i18n', 'en.json')));
    });

    // A sync is the project's whole catalog: the keys of a file it does not
    // upload are disabled. Every tool that prices or sends one refuses first.
    for (final entry in <String, Map<String, Object?>>{
      'sync_preview': {},
      'authorize': {'action': 'translate', 'max_credits': 10},
      'fill_status': {},
      'sync': {},
    }.entries) {
      for (final declaration in ['', 'sourceRoot: public/i18n\n',
        'sourceLayout: locale-files\n', 'sourceRoot: public/i18n\nsourceLayout: guessed\n']) {
        test('${entry.key} refuses an undeclared input catalog [$declaration]', () async {
          final requests = <http.Request>[];
          await start({...tree, 'public/i18n/admin/en.json': '{}'},
              config: 'projectId: proj_abc\nformat: json\n'
              'source: public/i18n/en.json\n$declaration', httpClient: MockClient((req) async {
            requests.add(req);
            return http.Response('{"baseCode":"en"}', 200);
          }));
          final error = errorOf(await harness.call(entry.key, entry.value));
          expect(error['code'], 'catalog_scope_unknown');
          expect(error['source'], 'public/i18n/en.json');
          // A declared root is walked. Without one nothing is inferred: the
          // list is the folder of `source:`, not the project (#2121).
          expect(error['files'], unorderedEquals([
            'public/i18n/en.json', 'public/i18n/es.json',
            if (declaration.contains('sourceRoot:')) 'public/i18n/admin/en.json',
          ]));
          expect(error['fields'], isNotEmpty);
          expect(requests.map((r) => '${r.method} ${r.url.path}'),
              ['GET /v1/projects/proj_abc/meta']);
        });
      }

      for (final meta in [
        {'baseCode': 'en'}, <String, String>{},
      ]) {
        test('${entry.key} resolves ambiguous scope before catalog POST $meta', () async {
          final requests = <http.Request>[];
          await start({
            'locales/app/en.json': '{"hello": "Hello"}',
            'locales/admin/en.json': '{"users": "Users"}',
          }, config: 'projectId: proj_abc\nmode: a\nformat: json\n'
              'output: locales\nsource: locales/app/en.json\nsourceRoot: locales\nsourceLayout: locale-files\n',
              httpClient: MockClient((req) async {
            requests.add(req);
            return http.Response(jsonEncode(meta), 200);
          }));
          final result = await harness.call(entry.key, entry.value);
          expect(result.isError, isTrue);
          final error = errorOf(result);
          expect(error['code'], meta.isEmpty ? 'catalog_scope_unknown' : 'several_files_per_locale');
          if (meta.isNotEmpty) {
            expect(error['source'], 'locales/app/en.json');
            expect(error['files'], ['locales/admin/en.json']);
          }
          expect(requests.map((r) => '${r.method} ${r.url.path}'),
              ['GET /v1/projects/proj_abc/meta']);
        });
      }

      test('${entry.key} refuses a second file of the base language before '
          'any catalog POST, naming both', () async {
        final requests = <http.Request>[];
        await start({
          ...tree,
          'public/i18n/es.json': '{}',
          'public/i18n/admin/en.json': '{"users": "Users"}',
          'public/i18n/admin/es.json': '{}',
        }, config: config, httpClient: MockClient((req) async {
          requests.add(req);
          return http.Response('{"baseCode":"en"}', 200);
        }));
        final result = await harness.call(entry.key, entry.value);
        expect(result.isError, isTrue);
        final error = errorOf(result);
        expect(error['code'], 'several_files_per_locale');
        expect(error['source'], 'public/i18n/en.json');
        expect(error['files'], ['public/i18n/admin/en.json']);
        expect(error['message'], allOf(contains('public/i18n/en.json'),
            contains('public/i18n/admin/en.json')));
        expect(requests.map((r) => '${r.method} ${r.url.path}'),
            ['GET /v1/projects/proj_abc/meta']);
      });
    }

    // The approval screen shows this count, and the server refuses an
    // operation that counts none. It is the server's parse of each format:
    // `json` reads the top-level strings, `nested_json` the leaves, and
    // neither keeps a blank one.
    for (final (format, file, count) in [
      (
        'json',
        '{"hello": "Hello", "bye": "Bye {name}", "blank": " ", "n": 3, '
            '"skipped": {"deep": "x"}}',
        2,
      ),
      (
        'nested_json',
        '{"hello": "Hello", "home": {"title": "Home", "cta": {"buy": "Buy"}}, '
            '"blank": ""}',
        3,
      ),
    ]) {
      test('authorize counts the strings of a $format base file', () async {
        final requests = <http.Request>[];
        await start({...tree, 'public/i18n/en.json': file},
            config: config.replaceFirst('format: json', 'format: $format'),
            httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path.endsWith('/meta')) return http.Response('{"baseCode":"en"}', 200);
          if (req.url.path.endsWith('/sync')) {
            return http.Response(jsonEncode({
              'dryRun': true, 'batchSha256': 'd' * 64, 'format': format,
              'baseCode': 'en', 'targetLangs': ['es'], 'fillableLangs': ['es'],
              'created': count, 'updatedSources': 0, 'matchedSources': 0,
              'updatedTranslations': 0, 'unchangedTranslations': 0,
              'disabledOrphans': 0, 'reenabled': 0, 'failedEntries': [],
              'exhausted': [], 'budgetExhausted': [], 'onConflict': 'server',
              'conflicts': [], 'conflictsTotal': 0, 'diagnostics': [],
              'trackingToken': null, 'estimatedCredits': 2000,
              'balance': 900000, 'availableCredits': 900000, 'accepted': true,
            }), 200);
          }
          return http.Response(jsonEncode({
            'operation_id': 'op_1', 'action': 'translate',
            'state': 'pending_approval', 'authorized_mc': 3000,
            'reserved_mc': 0, 'charged_mc': 0,
            'approval_url': 'https://app.easyi18n.com/approve/op_1',
          }), 201);
        }));
        final result = await harness
            .call('authorize', {'action': 'translate', 'max_credits': 3});
        expect(result.isError, isNot(true));
        final post =
            requests.singleWhere((r) => r.url.path == '/v1/operations');
        final scope = (jsonDecode(post.body) as Map)['scope'] as Map;
        expect(scope['unit_count'], count);
        expect(((scope['batches'] as List).single as Map)['unit_count'], count);
      });
    }

    test('pull writes the other locales and leaves the base file as it is',
        () async {
      await start(tree, config: config, httpClient: MockClient((req) async {
        return http.Response(jsonEncode({
          'project': 'proj_abc', 'version': '2026.10.09.1', 'baseCode': 'en',
          'formats': ['json'],
          'files': {
            'json/en.json': '{"bye":"Bye {name}","hello":"Hello"}',
            'json/es.json': '{"bye":"Adiós {name}","hello":"Hola"}',
          },
        }), 200);
      }));
      final result = await harness.call('pull');
      expect(result.isError, isNot(true));
      final i18n = p.join(dir.path, 'public', 'i18n');
      expect(result.structuredContent!['files_written'],
          [p.normalize(p.absolute(p.join(i18n, 'es.json')))]);
      expect(File(p.join(i18n, 'en.json')).readAsStringSync(),
          tree['public/i18n/en.json']);
      expect(File(p.join(i18n, 'es.json')).readAsStringSync(),
          contains('Adiós'));
    });

    group('a locale file changed since the pull that wrote it (#2095)', () {
      const edited = '{"bye":"Adiós {name}","hello":"Buenas"}';
      late List<http.Request> requests;
      File es() => File(p.join(dir.path, 'public', 'i18n', 'es.json'));

      setUp(() async {
        requests = [];
        await start(tree, config: config, httpClient: MockClient((req) async {
          requests.add(req);
          return http.Response(jsonEncode({
            'project': 'proj_abc', 'version': '2026.10.09.1', 'baseCode': 'en',
            'formats': ['json'],
            'files': {'json/es.json': '{"bye":"Adiós {name}","hello":"Hola"}'},
          }), 200);
        }));
        expect((await harness.call('pull')).isError, isNot(true));
        es().writeAsStringSync(edited);
        requests.clear();
      });

      // Every tool that prices or sends a sync, before it holds a client.
      for (final entry in <String, Map<String, Object?>>{
        'sync_preview': {},
        'authorize': {'action': 'translate', 'max_credits': 10},
        'fill_status': {},
        'sync': {},
      }.entries) {
        test('${entry.key} answers with the file and sends nothing', () async {
          final result = await harness.call(entry.key, entry.value);
          expect(result.isError, isTrue);
          final error = errorOf(result);
          expect(error['code'], 'edited_targets');
          expect(error['edited'], [
            {'file': 'public/i18n/es.json'},
          ]);
          expect(error['retryable'], isFalse);
          expect(requests, isEmpty);
        });
      }

      test('pull answers with the file and leaves it as it is', () async {
        final result = await harness.call('pull');
        expect(result.isError, isTrue);
        final error = errorOf(result);
        expect(error['code'], 'edited_targets');
        expect(error['edited'], [
          {'file': 'public/i18n/es.json'},
        ]);
        expect(es().readAsStringSync(), edited);
      });
    });

    test('doctor grades the tree as web and counts nested keys as keys',
        () async {
      await start({
        ...tree,
        'public/i18n/en.json':
            '{"hello": "Hello", "home": {"title": "Home", "cta": {"buy": "Buy"}}}',
      }, config: config.replaceFirst('format: json', 'format: nested_json'));
      final report = (await harness.call('doctor')).structuredContent!;
      expect(report['stack'], 'web');
      final source = (report['findings'] as List)
          .cast<Map>()
          .singleWhere((f) => f['check'] == 'source');
      expect(source['level'], 'ok');
      expect(source['message'], '3 key(s)');
    });

    test('doctor fails a source: that is not on disk', () async {
      await start({'package.json': tree['package.json']!}, config: config);
      final report = (await harness.call('doctor')).structuredContent!;
      final source = (report['findings'] as List)
          .cast<Map>()
          .singleWhere((f) => f['check'] == 'source');
      expect(source['level'], 'fail');
      expect(source['message'], contains('not found'));
    });

    test('catalog: wins over source: when a config holds both', () async {
      final requests = <http.Request>[];
      await start({
        ...tree,
        'Localizable.xcstrings':
            '{"sourceLanguage":"en","version":"1.0","strings":{}}',
      }, config: '${config}catalog: Localizable.xcstrings\n',
          httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response('{}', 500);
      }));
      await harness.call('sync_preview');
      final sync = requests.singleWhere((r) => r.url.path.endsWith('/sync'));
      expect((jsonDecode(sync.body) as Map)['fileName'], 'Localizable.xcstrings');
    });

    for (final entry in {
      'that is not JSON': '{"hello": ',
      'that is not an object': '["hello"]',
    }.entries) {
      test('doctor fails a base file ${entry.key}', () async {
        await start({...tree, 'public/i18n/en.json': entry.value},
            config: config);
        final report = (await harness.call('doctor')).structuredContent!;
        final source = (report['findings'] as List)
            .cast<Map>()
            .singleWhere((f) => f['check'] == 'source');
        expect(source['level'], 'fail');
      });
    }

    test('a web project that only pulls is not failed for having no source:',
        () async {
      // The plugin is installed and provided, so a failure here could only
      // come from the missing `source:`.
      await start({
        ...tree,
        'package.json': _package({
          '@jsverse/transloco': '^8.4.0',
          '@jsverse/transloco-messageformat': '^8.4.0',
        }),
        'src/main.ts': 'providers: [provideTranslocoMessageformat()]\n',
      }, config: 'projectId: proj_abc\nmode: a\nformat: json\n'
          'output: public/i18n\n');
      final report = (await harness.call('doctor')).structuredContent!;
      expect(report['stack'], 'web');
      final source = (report['findings'] as List)
          .cast<Map>()
          .singleWhere((f) => f['check'] == 'source');
      expect(source['level'], 'skip');
      expect((report['counts'] as Map)['failures'], 0);
    });

    test('a source: config with no package.json is still graded as web',
        () async {
      await start({'public/i18n/en.json': '{}'}, config: config);
      final report = (await harness.call('doctor')).structuredContent!;
      expect(report['stack'], 'web');
    });
  });

  group('doctor', () {
    const config = 'projectId: proj_abc\nmode: a\nformat: json\n'
        'output: public/i18n\nsource: public/i18n/en.json\nsourceRoot: public/i18n\nsourceLayout: locale-files\n';
    const messageformat = '@jsverse/transloco-messageformat';
    const appConfig = '''
import { provideTransloco } from '@jsverse/transloco';
import { provideTranslocoMessageformat } from '@jsverse/transloco-messageformat';

export const appConfig = {
  providers: [
    provideTransloco({ config: { availableLangs: ['en', 'es'] } }),
    provideTranslocoMessageformat(),
  ],
};
''';
    const provider = '    provideTranslocoMessageformat(),\n';
    final wired = {
      ..._translocoTree,
      'package.json':
          _package({'@jsverse/transloco': '^8.4.0', messageformat: '^8.4.0'}),
      'src/app/app.config.ts': appConfig,
      'public/i18n/en.json': '{"hello": "Hello"}',
    };

    /// Offline unless a test passes a key: the checks under test read the
    /// tree, and the one that asks the server has its own group.
    Future<Map<String, Object?>> doctor(Map<String, String> files,
        {String config = config,
        Map<String, String> environment = const {},
        http.Client? httpClient}) async {
      await start(files, config: config, environment: environment,
          httpClient: httpClient);
      return (await harness.call('doctor')).structuredContent!;
    }

    List<Map<Object?, Object?>> findings(
            Map<String, Object?> report, String check) =>
        [
          for (final finding in (report['findings'] as List).cast<Map>())
            if (finding['check'] == check) finding,
        ];
    Map<Object?, Object?> finding(Map<String, Object?> report, String check) {
      final found = findings(report, check);
      expect(found, hasLength(1), reason: 'findings of `$check`');
      return found.single;
    }
    int failures(Map<String, Object?> report) =>
        (report['counts'] as Map)['failures'] as int;

    group('transpiler and wiring', () {
      test('a Transloco tree with the plugin installed and provided passes',
          () async {
        final report = await doctor(wired);
        expect(report['stack'], 'web');
        expect(finding(report, 'transpiler')['level'], 'ok');
        expect(finding(report, 'wiring')['level'], 'ok');
        expect(finding(report, 'wiring')['subject'],
            p.join(dir.path, 'src', 'app', 'app.config.ts'));
        expect(failures(report), 0);
      });

      for (final entry in {
        'removed, its import left behind': appConfig.replaceFirst(provider, ''),
        'commented out on its line':
            appConfig.replaceFirst(provider, '    // $provider'),
        'inside a block comment': appConfig.replaceFirst(
            provider, '    /* provideTranslocoMessageformat(),\n    */\n'),
      }.entries) {
        test('a provider ${entry.key} fails and is named', () async {
          final report =
              await doctor({...wired, 'src/app/app.config.ts': entry.value});
          final wiring = finding(report, 'wiring');
          expect(wiring['level'], 'fail');
          expect(wiring['message'], contains('provideTranslocoMessageformat()'));
          expect((wiring['details'] as List).join('\n'),
              contains('provideTranslocoMessageformat(),'));
          expect(finding(report, 'transpiler')['level'], 'ok');
          expect(failures(report), 1);
        });
      }

      for (final prefix in [
        "const cdn = '//cdn.example/i18n';",
        'const cdn = "//cdn.example/i18n";',
        'const cdn = `//cdn.example/i18n`;',
        "const help = '/* example */';",
      ]) {
        test('a quoted comment marker preserves the provider: $prefix', () async {
          final report = await doctor({
            ...wired,
            'src/app/app.config.ts':
                '$prefix const providers = [provideTranslocoMessageformat()];',
          });
          expect(finding(report, 'wiring')['level'], 'ok');
        });
      }

      for (final example in [
        "const help = 'provideTranslocoMessageformat()';",
        'const help = "provideTranslocoMessageformat()";',
        'const help = `provideTranslocoMessageformat()`;',
      ]) {
        test('a quoted example does not wire Transloco: $example', () async {
          final report = await doctor({
            ...wired,
            'src/app/app.config.ts': example,
          });
          expect(finding(report, 'wiring')['level'], 'fail');
        });
      }

      test('a URL on the provider line is not read as a comment', () async {
        final report = await doctor({
          ...wired,
          'src/app/app.config.ts': 'export const appConfig = { cdn: '
              "'https://cdn.example/i18n', providers: "
              '[provideTranslocoMessageformat()] };\n',
        });
        expect(finding(report, 'wiring')['level'], 'ok');
      });

      test('an NgModule that provides MessageFormatTranspiler is wired',
          () async {
        final report = await doctor({
          ...wired,
          'src/app/app.config.ts': 'export const appConfig = {};\n',
          'src/app/transloco-root.module.ts': 'providers: [{ provide: '
              'TRANSLOCO_TRANSPILER, useClass: MessageFormatTranspiler }]\n',
        });
        final wiring = finding(report, 'wiring');
        expect(wiring['level'], 'ok');
        expect(wiring['subject'],
            p.join(dir.path, 'src', 'app', 'transloco-root.module.ts'));
      });

      // One place per test: a tree that held them all would stay red with
      // any single exclusion gone.
      for (final elsewhere in [
        'node_modules/some-lib/app.config.ts',
        'dist/main.js',
        'build/main.js',
        'out/main.js',
        'coverage/lcov-report/app.config.ts',
        '.angular/cache/app.config.ts',
        'src/app/notes.md',
      ]) {
        test('a provider in $elsewhere does not wire the app', () async {
          final report = await doctor({
            ...wired,
            'src/app/app.config.ts': appConfig.replaceFirst(provider, ''),
            elsewhere: appConfig,
          });
          expect(finding(report, 'wiring')['level'], 'fail');
        });
      }

      for (final extension in [
        'ts', 'tsx', 'mts', 'cts', 'js', 'jsx', 'mjs', 'cjs', 'vue', 'svelte',
      ]) {
        test('a provider in a .$extension file wires the app', () async {
          final report = await doctor({
            ...wired,
            'src/app/app.config.ts': appConfig.replaceFirst(provider, ''),
            'src/setup.$extension': appConfig,
          });
          final wiring = finding(report, 'wiring');
          expect(wiring['level'], 'ok');
          expect(wiring['subject'],
              p.join(dir.path, 'src', 'setup.$extension'));
        });
      }

      test('with two files that wire it, the first by path is the one named',
          () async {
        final report = await doctor({
          ...wired,
          'src/app/app.config.ts': appConfig.replaceFirst(provider, ''),
          'src/z-late.ts': appConfig,
          'src/m-middle.ts': appConfig,
          'src/a-early.ts': appConfig,
        });
        expect(finding(report, 'wiring')['subject'],
            p.join(dir.path, 'src', 'a-early.ts'));
      });

      // `z.ts` sorts after both, so the search has to get past each one.
      test('a source file that is not text is skipped, not fatal', () async {
        await start({
          ...wired,
          'src/app/app.config.ts': appConfig.replaceFirst(provider, ''),
          'src/z.ts': appConfig,
        }, config: config, environment: const {});
        File(p.join(dir.path, 'src', 'blob.js'))
            .writeAsBytesSync([0xff, 0xfe, 0x00]);
        final result = await harness.call('doctor');
        expect(result.isError, isNot(true));
        expect(finding(result.structuredContent!, 'wiring')['level'], 'ok');
      });

      test('a directory that cannot be listed is skipped, not fatal', () async {
        await start({
          ...wired,
          'src/app/app.config.ts': appConfig.replaceFirst(provider, ''),
          'src/locked/secret.ts': '',
          'src/z.ts': appConfig,
        }, config: config, environment: const {});
        final locked = p.join(dir.path, 'src', 'locked');
        Process.runSync('chmod', ['000', locked]);
        addTearDown(() => Process.runSync('chmod', ['755', locked]));
        expect(() => Directory(locked).listSync(),
            throwsA(isA<FileSystemException>()),
            reason: 'the fixture must be unlistable for this run to mean anything');
        final result = await harness.call('doctor');
        expect(result.isError, isNot(true));
        expect(finding(result.structuredContent!, 'wiring')['level'], 'ok');
      }, skip: Platform.isWindows || Process.runSync('id', ['-u']).stdout
              .toString().trim() == '0'
          ? 'needs a directory this user cannot list'
          : null);

      test('a linked directory is not followed', () async {
        final outside = Directory.systemTemp.createTempSync('web_linked');
        addTearDown(() => outside.deleteSync(recursive: true));
        File(p.join(outside.path, 'app.config.ts')).writeAsStringSync(appConfig);
        await start({
          ...wired,
          'src/app/app.config.ts': appConfig.replaceFirst(provider, ''),
        }, config: config, environment: const {});
        Link(p.join(dir.path, 'src', 'vendor')).createSync(outside.path);
        final report = (await harness.call('doctor')).structuredContent!;
        expect(finding(report, 'wiring')['level'], 'fail');
      }, skip: Platform.isWindows ? 'creating a link needs a privilege' : null);

      test('the plugin under devDependencies is installed', () async {
        final report = await doctor({
          ...wired,
          'package.json': jsonEncode({
            'dependencies': {'@jsverse/transloco': '^8.4.0'},
            'devDependencies': {messageformat: '^8.4.0'},
          }),
        });
        expect(finding(report, 'transpiler')['level'], 'ok');
      });

      test('a plugin missing from package.json fails by name, wiring apart',
          () async {
        final report = await doctor(
            {...wired, 'package.json': _translocoTree['package.json']!});
        final transpiler = finding(report, 'transpiler');
        expect(transpiler['level'], 'fail');
        expect(transpiler['message'], contains(messageformat));
        expect(transpiler['subject'], p.join(dir.path, 'package.json'));
        expect(finding(report, 'wiring')['level'], 'ok');
        expect(failures(report), 1);
      });

      const ngx = {
        '@ngx-translate/core': '^18.0.0',
        'ngx-translate-messageformat-compiler': '^7.3.0',
        '@messageformat/core': '^3.4.0',
      };
      for (final entry in {
        'provideTranslateCompiler(TranslateMessageFormatCompiler)': 'ok',
        'provideTranslateCompiler(TranslateMessageFormatDebugCompiler)': 'ok',
        '{ provide: TranslateCompiler, useClass: TranslateMessageFormatCompiler }':
            'ok',
        'provideTranslateCompiler(TranslateFakeCompiler)': 'fail',
        'undefined': 'fail',
      }.entries) {
        test('ngx-translate compiled by ${entry.key} is ${entry.value}',
            () async {
          final report = await doctor({
            'package.json': _package(ngx),
            'public/i18n/en.json': '{}',
            'src/app/app.config.ts': 'import { TranslateMessageFormatCompiler } '
                "from 'ngx-translate-messageformat-compiler';\n"
                'providers: [provideTranslateService({ compiler: ${entry.key} })]\n',
          });
          final wiring = finding(report, 'wiring');
          expect(wiring['level'], entry.value);
          if (entry.value == 'fail') {
            expect(wiring['message'], contains(
                'provideTranslateCompiler(TranslateMessageFormatCompiler)'));
          }
          expect(finding(report, 'transpiler')['level'], 'ok');
        });
      }

      const i18nextConfig = 'projectId: proj_abc\nmode: a\nformat: json\n'
          'output: locales\nsource: locales/en.json\nsourceRoot: locales\nsourceLayout: locale-files\n';
      for (final entry in {
        "import ICU from 'i18next-icu';\ni18next.use(ICU).init({});": 'ok',
        'import Icu from "i18next-icu";\ni18n.use(Backend).use(Icu).init({});':
            'ok',
        "const ICU = require('i18next-icu');\ni18next.use(new ICU()).init({});":
            'ok',
        "import ICU from 'i18next-icu';\ni18next.init({});": 'fail',
        "import ICU from './icu';\ni18next.use(ICU).init({});": 'fail',
        "import ICU from 'i18next-icu';\ni18next.use(ICUish).init({});": 'fail',
      }.entries) {
        test('i18next wired as ${jsonEncode(entry.key)} is ${entry.value}',
            () async {
          final report = await doctor({
            'package.json': _package({
              'i18next': '^26.4.2',
              'i18next-icu': '^2.5.0',
              'intl-messageformat': '^10.7.0',
            }),
            'locales/en.json': '{}',
            'src/i18n.js': "import i18next from 'i18next';\n${entry.key}\n",
          }, config: i18nextConfig);
          final wiring = finding(report, 'wiring');
          expect(wiring['level'], entry.value);
          if (entry.value == 'fail') {
            expect(wiring['message'], contains('i18next.use(ICU)'));
          }
        });
      }

      // Without a word boundary the search retries from every character of
      // a long identifier. It is synchronous, so a test timeout cannot
      // interrupt it; the elapsed-time assertion detects the slowdown.
      test('a 60,000-character word in a source file does not stall doctor',
          () async {
        final watch = Stopwatch()..start();
        final report = await doctor({
          'package.json': _package({'i18next': '^26.4.2'}),
          'locales/en.json': '{}',
          'src/vendor.js': 'const ${'A' * 60000} = 1;\n',
        }, config: i18nextConfig);
        expect(finding(report, 'wiring')['level'], 'fail');
        expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      });

      test('a quoted i18next example does not wire the plugin', () async {
        final report = await doctor({
          'package.json': _package({'i18next': '^26.4.2',
            'i18next-icu': '^2.5.0', 'intl-messageformat': '^10.7.0'}),
          'locales/en.json': '{}',
          'src/i18n.js':
              'const help = "import ICU from \'i18next-icu\'; i18next.use(ICU)";',
        }, config: i18nextConfig);
        expect(finding(report, 'wiring')['level'], 'fail');
      });

      // The three instances of Remix 2 with remix-i18next 6 (#2574): each
      // formats with the plugins it registered.
      group('i18next graded per instance', () {
        final package = _package({
          'i18next': '^23.16.8',
          'i18next-icu': '^2.6.1',
          'intl-messageformat': '^12.1.4',
        });
        const client = '''
import i18next from "i18next";
import ICU from "i18next-icu";
import Backend from "i18next-http-backend";
import { initReactI18next } from "react-i18next";

await i18next
  .use(initReactI18next)
  .use(ICU)
  .use(Backend)
  .init({ backend: { loadPath: "/locales/{{lng}}/{{ns}}.json" } });
''';
        const entryServer = '''
import { createInstance } from "i18next";
import Backend from "i18next-fs-backend";
import ICU from "i18next-icu";
import { initReactI18next } from "react-i18next";
import i18next from "./i18next.server";

export default async function handleRequest(request: Request) {
  const instance = createInstance();
  const lng = await i18next.getLocale(request);
  await instance
    .use(initReactI18next)
    .use(ICU)
    .use(Backend)
    .init({ lng, backend: { loadPath: resolve("./locales/{{lng}}.json") } });
}
''';
        const remixServer = '''
import Backend from "i18next-fs-backend";
import ICU from "i18next-icu";
import { RemixI18Next } from "remix-i18next/server";

const i18next = new RemixI18Next({
  detection: { supportedLanguages: ["en", "es"], fallbackLanguage: "en" },
  plugins: [Backend, ICU],
});
export default i18next;
''';
        String unwired(String file) => file
            .replaceFirst('import ICU from "i18next-icu";\n', '')
            .replaceFirst('  .use(ICU)\n', '')
            .replaceFirst('[Backend, ICU]', '[Backend]');
        final remix = {
          'package.json': package,
          'locales/en.json': '{}',
          'app/entry.client.tsx': client,
          'app/entry.server.tsx': entryServer,
          'app/i18next.server.ts': remixServer,
          // Neither is an instance: a Vite plugin list, and an instance
          // imported from the module that builds it.
          'vite.config.ts': 'import { vitePlugin as remix } from '
              '"@remix-run/dev";\nexport default defineConfig({ plugins: '
              '[remix(), tsconfigPaths()] });\n',
          'app/root.tsx': 'import i18next from "~/i18next.server";\n'
              'export const loader = ({ request }) => i18next.getLocale(request);\n',
        };
        Future<List<Map<Object?, Object?>>> wiringOf(
                Map<String, String> files) async =>
            findings(await doctor(files, config: i18nextConfig), 'wiring');
        String at(String path) => p.joinAll([dir.path, ...path.split('/')]);

        test('a server without the plugin is a warning per instance, no ok',
            () async {
          final report = await doctor({
            ...remix,
            'app/entry.server.tsx': unwired(entryServer),
            'app/i18next.server.ts': unwired(remixServer),
          }, config: i18nextConfig);
          final wiring = findings(report, 'wiring');
          expect([for (final f in wiring) (f['level'], f['subject'])], [
            ('warn', at('app/entry.server.tsx')),
            ('warn', at('app/i18next.server.ts')),
          ]);
          for (final f in wiring) {
            expect(f['message'], contains('i18next-icu'));
            expect(f['message'], contains('raw text'));
            expect((f['message'] as String).length, lessThan(200),
                reason: 'MCP cuts a finding message at 200 characters');
          }
          expect(failures(report), 0);
        });

        for (final entry in {
          'app/entry.client.tsx': client,
          'app/entry.server.tsx': entryServer,
          'app/i18next.server.ts': remixServer,
        }.entries) {
          test('${entry.key} alone without the plugin is the one warned',
              () async {
            final wiring =
                await wiringOf({...remix, entry.key: unwired(entry.value)});
            expect([for (final f in wiring) (f['level'], f['subject'])],
                [('warn', at(entry.key))]);
          });
        }

        test('every instance wired is one ok that lists the files', () async {
          final wiring = await wiringOf(remix);
          expect(wiring, hasLength(1));
          expect(wiring.single['level'], 'ok');
          expect(wiring.single['subject'], dir.path);
          expect(wiring.single['message'], 'i18next.use(ICU) wired in 3 files');
          expect(wiring.single['details'], [
            'app/entry.client.tsx', 'app/entry.server.tsx',
            'app/i18next.server.ts',
          ]);
        });

        const middleware = '''
import { initReactI18next } from "react-i18next";
import { createI18nextMiddleware } from "remix-i18next/middleware";

export const [i18nextMiddleware, getLocale] = createI18nextMiddleware({
  detection: { supportedLanguages: ["es", "en"], fallbackLanguage: "en" },
  plugins: [initReactI18next],
});
''';
        for (final entry in {
          'a remix-i18next 8 middleware': middleware,
          'a next-i18next config with use:':
              "import Backend from 'i18next-http-backend'\n"
                  'export default { use: [Backend] }\n',
          'a CommonJS chain': "const i18next = require('i18next');\n"
              "const Backend = require('i18next-fs-backend');\n"
              'i18next.use(Backend).init({});\n',
          'a CommonJS plugin list':
              "const Backend = require('i18next-fs-backend');\n"
                  'module.exports = new RemixI18Next({ plugins: [Backend] });\n',
        }.entries) {
          test('${entry.key} without the plugin is warned', () async {
            final wiring = await wiringOf({
              'package.json': package,
              'locales/en.json': '{}',
              'app/entry.client.tsx': client,
              'app/middleware/i18next.ts': entry.value,
            });
            expect([for (final f in wiring) (f['level'], f['subject'])],
                [('warn', at('app/middleware/i18next.ts'))]);
          });
        }

        // Without semicolons, a blanked specifier would let the first import
        // read on into the i18next one and lend it `react`.
        test('an import does not read into the next one', () async {
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'app/entry.client.tsx': client,
            'vite.config.ts': "import react from '@vitejs/plugin-react'\n"
                "import ICU from 'i18next-icu'\n"
                'export default defineConfig({ plugins: [react()] })\n',
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('ok', at('app/entry.client.tsx'))]);
        });

        test('ICU in a use: list wires next-i18next as its README does',
            () async {
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'i18n.config.ts': "import ICU from 'i18next-icu'\n"
                "const i18nConfig = { supportedLngs: ['en', 'es'], use: [ICU] }\n"
                'export default i18nConfig\n',
            'app/[lng]/layout.tsx':
                "import { initServerI18next } from 'next-i18next/server'\n"
                "import i18nConfig from '../../i18n.config'\n"
                'initServerI18next(i18nConfig)\n',
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('ok', at('i18n.config.ts'))]);
        });

        for (final entry in {
          'a .use() that never reaches init':
              "import i18next from 'i18next';\n"
                  "import Backend from 'i18next-http-backend';\n"
                  'i18next.use(Backend);\n',
          'a chain on an instance another module exports':
              "import i18n from './i18n';\n"
                  "import { initReactI18next } from 'react-i18next';\n"
                  'i18n.use(initReactI18next).init({});\n',
          'an instance without plugins': "import i18next from 'i18next';\n"
              'i18next.init({});\n',
          'an imported helper beside an unrelated chain':
              "import { t } from 'i18next';\n"
                  'tool\n  .use(plugin).init({});\n',
          'an unclosed factory':
              "import { createInstance } from 'i18next';\ncreateInstance(\n",
          'an unrelated property named like the import':
              "import i18next from 'i18next';\n"
                  'tool.i18next.use(plugin).init({});\n',
          'a .use( left open': "import i18next from 'i18next';\n"
              'i18next.use(Backend\n',
          'a ) no ( opened': "import i18next from 'i18next';\n"
              r'const close = /\)/;' '\ni18next.use(Backend);\n',
        }.entries) {
          test('${entry.key} is not an instance', () async {
            final wiring = await wiringOf({
              'package.json': package,
              'locales/en.json': '{}',
              'src/i18n.ts': client,
              'src/setup.ts': entry.value,
            });
            expect([for (final f in wiring) (f['level'], f['subject'])],
                [('ok', at('src/i18n.ts'))]);
          });
        }

        // A regex literal is code, so its `(` is never closed: scanning for
        // the closing parenthesis from each `.use(` took 7 seconds over
        // 390 KB. Synchronous, so the elapsed time is the assertion.
        test('an unclosed parenthesis before many .use( does not stall doctor',
            () async {
          final watch = Stopwatch()..start();
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'src/i18n.ts': client,
            'src/vendor.js':
                "import i18next from 'i18next';\n${r'i18next.use(/\(/);' '\n' * 12000}",
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('ok', at('src/i18n.ts'))]);
          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        });

        test('an unrelated chain beside an i18next import is not an instance',
            () async {
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'src/i18n.ts': client,
            'src/tool.ts': "import i18next from 'i18next';\n"
                "import tool from './toolkit';\n"
                'tool.use(plugin).init({});\n'
                'export const language = i18next.language;\n',
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('ok', at('src/i18n.ts'))]);
        });

        test('a long closed use chain without init stays linear', () async {
          final watch = Stopwatch()..start();
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'src/i18n.ts': client,
            'src/vendor.js': "import i18next from 'i18next';\n"
                "i18next${'.use(Backend)' * 16000};\n",
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('ok', at('src/i18n.ts'))]);
          expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        });

        // JSX text is code: reading each import clause on to the end of the
        // words that follow it took 84 seconds over 20,000 of them.
        test('a page of import words stays linear', () async {
          final watch = Stopwatch()..start();
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'src/i18n.ts': client,
            'src/page.tsx': "import i18next from 'i18next';\n"
                "export const Page = () => <p>${'import x, ' * 10000}</p>;\n",
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('ok', at('src/i18n.ts'))]);
          expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        });

        for (final declaration in [
          "import renamed from 'i18next';\nrenamed",
          "import { default as renamed } from 'i18next';\nrenamed",
          "const { default: renamed } = require('i18next');\nrenamed",
          "import { createInstance } from 'i18next';\nconst \$server = createInstance();\n\$server",
          "import * as ns from 'i18next';\nns",
          "import { createInstance as make } from 'i18next';\nmake()",
          "import { createInstance } from 'i18next';\ncreateInstance({ lng: getLanguage() })",
          "import { createInstance as make } from 'i18next';\nconst server = make();\nserver",
          "const { createInstance: make } = require('i18next');\nmake()",
          "import i18next from 'i18next';\nconst server = i18next.createInstance();\nserver",
          "import { createInstance, type i18n } from 'i18next';\nconst server: i18n = createInstance();\nserver",
          "import i18next, { type i18n } from 'i18next';\nexport const server: i18n | null = i18next.createInstance();\nserver",
          // The annotation of the line above is not the declaration's.
          "import { createInstance } from 'i18next'\nlet fallback: string\nconst server = createInstance()\nserver",
        ]) {
          test('an imported instance is recognized: $declaration', () async {
            final wiring = await wiringOf({
              'package.json': package,
              'locales/en.json': '{}',
              'src/i18n.ts': client,
              'src/server.ts': '$declaration.use(Backend).init({});\n',
            });
            expect([for (final f in wiring) (f['level'], f['subject'])],
                [('warn', at('src/server.ts'))]);
          });
        }

        test('nested parentheses in a link do not end the chain', () async {
          final wiring = await wiringOf({
            'package.json': package,
            'locales/en.json': '{}',
            'src/i18n.ts': client,
            'src/server.ts': "import i18next from 'i18next';\n"
                "import resourcesToBackend from 'i18next-resources-to-backend';\n"
                'i18next.use(resourcesToBackend((lng, ns) => '
                'import(`./locales/\${lng}/\${ns}.json`))).init({});\n',
          });
          expect([for (final f in wiring) (f['level'], f['subject'])],
              [('warn', at('src/server.ts'))]);
        });
      });

      group('a peer of the plugin', () {
        const tree = {
          'locales/en.json': '{}',
          'src/i18n.js':
              "import ICU from 'i18next-icu';\ni18next.use(ICU).init({});\n",
        };
        final unlisted =
            _package({'i18next': '^26.4.2', 'i18next-icu': '^2.5.0'});

        test('npm installed without listing it is present', () async {
          final report = await doctor({
            ...tree,
            'package.json': unlisted,
            'node_modules/intl-messageformat/package.json': '{}',
          }, config: i18nextConfig);
          expect(finding(report, 'transpiler')['level'], 'ok');
        });

        test('that is nowhere is a warning that names it, not a failure',
            () async {
          final report = await doctor({...tree, 'package.json': unlisted},
              config: i18nextConfig);
          final transpiler = finding(report, 'transpiler');
          expect(transpiler['level'], 'warn');
          expect(transpiler['message'], contains('intl-messageformat'));
          expect(failures(report), 0);
        });
      });

      test('a tree with no recognized library skips both, with no failure',
          () async {
        final report = await doctor({
          'package.json': _package({'vue-i18n': '^11.0.0'}),
          'public/i18n/en.json': '{}',
        });
        expect(report['stack'], 'web');
        expect(finding(report, 'transpiler')['level'], 'skip');
        expect(findings(report, 'wiring'), isEmpty);
        expect(failures(report), 0);
      });

      test('a project that only pulls is still graded on its plugin', () async {
        final report = await doctor(
            {...wired, 'package.json': _translocoTree['package.json']!},
            config: 'projectId: proj_abc\nmode: a\nformat: json\n'
                'output: public/i18n\n');
        expect(finding(report, 'source')['level'], 'skip');
        expect(finding(report, 'transpiler')['level'], 'fail');
      });
    });

    group('the base file against the configured format', () {
      const nested = '{"hello": "Hello", "home": {"title": "Home"}}';
      const flat = '{"hello": "Hello"}';
      final asNested =
          config.replaceFirst('format: json', 'format: nested_json');

      test('format json over a file that nests fails and names nested_json',
          () async {
        final report = await doctor({...wired, 'public/i18n/en.json': nested});
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'], contains('`format: nested_json`'));
        expect(source['message'], contains('`home`'));
      });

      test('format nested_json over a flat file fails and names json',
          () async {
        final report = await doctor({...wired, 'public/i18n/en.json': flat},
            config: asNested);
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'], contains('`format: json`'));
      });

      test('each format over its own shape passes', () async {
        expect(
            finding(await doctor({...wired, 'public/i18n/en.json': flat}),
                'source')['level'],
            'ok');
        expect(
            finding(
                await doctor({...wired, 'public/i18n/en.json': nested},
                    config: asNested),
                'source')['level'],
            'ok');
      });

      // `/v1/sync` takes neither, so its shape rule has nothing to say: an
      // ARB file is flat JSON and would otherwise be told to become `json`.
      test('a format that is not JSON is not judged by the shape of the file',
          () async {
        final report = await doctor({
          'package.json': wired['package.json']!,
          'src/app/app.config.ts': appConfig,
          'lib/l10n/app_en.arb': '{"hello": "Hello"}',
        }, config: 'projectId: proj_abc\nmode: a\nformat: arb\n'
            'output: lib/l10n\nsource: lib/l10n/app_en.arb\n');
        // What fails is the selection sync makes first (#2456).
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'], allOf(startsWith('Declare sourceRoot'),
            isNot(contains('`format: json`'))));
      });

      // The server's rule (`parser_registry.dart`): an object under an
      // `@key` is metadata and does not make the file nested.
      test('an object under an @key leaves the file flat, for doctor and init',
          () async {
        const annotated = '{"hello": "Hello", "@hello": {"description": "x"}}';
        final report =
            await doctor({...wired, 'public/i18n/en.json': annotated});
        expect(finding(report, 'source')['level'], 'ok');

        await start({..._translocoTree, 'public/i18n/en.json': annotated});
        await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(yaml(), contains('\nformat: json\n'));
      });
    });

    group('target files against the pull record', () {
      String record(List<String> files, {String output = 'public/i18n'}) =>
          jsonEncode({'format': 'json', 'output': output, 'files': files});
      final baseOnly = {
        'package.json': wired['package.json']!,
        'src/app/app.config.ts': appConfig,
        'public/i18n/en.json': '{}',
      };

      test('with no record the targets are named and nothing is claimed',
          () async {
        final report = await doctor(wired);
        final targets = finding(report, 'targets');
        expect(targets['level'], 'skip');
        expect(targets['message'], contains('es.json'));
        expect(targets['message'], isNot(contains('en.json')));
      });

      test('a target the record lists passes', () async {
        final report = await doctor(
            {...wired, '.easyi18n/state.json': record(['en.json', 'es.json'])});
        expect(finding(report, 'targets')['level'], 'ok');
      });

      test('a target no pull wrote is a warning that names only that file',
          () async {
        final report = await doctor({
          ...wired,
          'public/i18n/fr.json': '{}',
          'public/i18n/notes.txt': '',
          'public/i18n/admin/de.json': '{}',
          '.easyi18n/state.json': record(['es.json']),
        });
        final targets = finding(report, 'targets');
        expect(targets['level'], 'warn');
        expect(targets['message'], startsWith('fr.json: '));
        expect(failures(report), 0);
      });

      for (final entry in {
        'another directory': record(['es.json'], output: 'src/assets/i18n'),
        'another format': jsonEncode(
            {'format': 'arb', 'output': 'public/i18n', 'files': ['es.json']}),
        'no directory': jsonEncode({'format': 'json', 'files': ['es.json']}),
        // What a CLI older than the file list wrote: nothing to compare to.
        'no file list': jsonEncode({'format': 'json', 'output': 'public/i18n'}),
      }.entries) {
        test('a record of ${entry.key} vouches for nothing', () async {
          final report =
              await doctor({...wired, '.easyi18n/state.json': entry.value});
          expect(finding(report, 'targets')['level'], 'skip');
        });
      }

      for (final entry in {
        'zh-hant.json': 'zh-Hant.json',
        'zh-Hant.json': 'zh-hant.json',
      }.entries) {
        test('${entry.key} on disk, recorded as ${entry.value}, passes',
            () async {
          final report = await doctor({
            ...baseOnly,
            'public/i18n/${entry.key}': '{}',
            '.easyi18n/state.json': record([entry.value]),
          });
          expect(finding(report, 'targets')['level'], 'ok');
        });
      }

      test('a directory that holds only the base file has nothing to check',
          () async {
        final report = await doctor(
            {...baseOnly, '.easyi18n/state.json': record(['es.json'])});
        final targets = finding(report, 'targets');
        expect(targets['level'], 'skip');
        expect(targets['message'], isNot(contains('en.json')));
      });

      group('a pulled file against its recorded digest (#2095)', () {
        // SHA-256 of the UTF-8 bytes of `{"hello":"Hola"}`: what the file
        // says with its keys sorted and no layout.
        const hola = 'sha256:'
            '4a59a5bb7785af3f6d9aa3856fb3cfcb1d0ad69f1701a57a35b4a64b2ef02eb9';
        String digested(Map<String, String> digests,
                {List<String>? files}) =>
            jsonEncode({
              'format': 'json', 'output': 'public/i18n',
              'files': files ?? digests.keys.toList(), 'digests': digests,
            });

        test('a file that says what the pull wrote passes, however it is '
            'laid out', () async {
          final report = await doctor({
            ...wired,
            'public/i18n/es.json': '{\r\n  "hello": "Hola"\r\n}\r\n',
            '.easyi18n/state.json': digested({'es.json': hola}),
          });
          final targets = finding(report, 'targets');
          expect(targets['level'], 'ok');
          expect(targets['message'],
              '1 locale file(s), each written by `pull`');
        });

        test('a file changed since is a warning that names it and where the '
            'fix lives', () async {
          final report = await doctor({
            ...wired,
            'public/i18n/es.json': '{"hello": "Buenas"}',
            'public/i18n/de.json': '{"hello": "Hola"}',
            '.easyi18n/state.json':
                digested({'de.json': hola, 'es.json': hola}),
          });
          final targets = finding(report, 'targets');
          expect(targets['level'], 'warn');
          expect(targets['message'], startsWith('es.json: changed since '));
          expect(targets['message'], isNot(contains('de.json')));
          expect(targets['message'],
              allOf(contains('dashboard'), contains('easyi18n pull --force')));
          expect(failures(report), 0);
        });

        test('a changed file and one no pull wrote are both named', () async {
          final report = await doctor({
            ...wired,
            'public/i18n/es.json': '{"hello": "Buenas"}',
            'public/i18n/fr.json': '{}',
            '.easyi18n/state.json': digested({'es.json': hola}),
          });
          final targets = finding(report, 'targets');
          expect(targets['level'], 'warn');
          expect(targets['message'],
              allOf(contains('fr.json: not written by a `pull`'),
                  contains('es.json: changed since ')));
        });

        test('a recorded file that has no digest is not judged', () async {
          final report = await doctor({
            ...wired,
            'public/i18n/es.json': '{"hello": "Buenas"}',
            '.easyi18n/state.json': digested({}, files: ['es.json']),
          });
          expect(finding(report, 'targets')['level'], 'ok');
        });

        for (final entry in {
          'zh-hant.json': 'zh-Hant.json',
          'zh-Hant.json': 'zh-hant.json',
        }.entries) {
          test('${entry.key} on disk reads the digest recorded as '
              '${entry.value}', () async {
            final report = await doctor({
              ...baseOnly,
              'public/i18n/${entry.key}': '{"hello": "Buenas"}',
              '.easyi18n/state.json': digested({entry.value: hola}),
            });
            final targets = finding(report, 'targets');
            expect(targets['level'], 'warn');
            expect(targets['message'], startsWith('${entry.key}: changed'));
          });
        }
      });
    });

    group('project languages against the locale files', () {
      const key = {'EASYI18N_TOKEN': 'eik_test'};

      /// `/meta` for a project with [codes], the base first; every other
      /// route answers 404.
      MockClient api(List<String> codes, {List<http.Request>? seen}) =>
          MockClient((request) async {
            seen?.add(request);
            if (!request.url.path.endsWith('/meta')) {
              return http.Response('{}', 404);
            }
            return http.Response(
                jsonEncode({
                  'baseCode': codes.isEmpty ? 'en' : codes.first,
                  'languages': [
                    for (final (index, code) in codes.indexed)
                      {'code': code, 'isBase': index == 0},
                  ],
                  'formats': ['json'],
                }),
                200);
          });

      test('each code missing on one side is named, and a match is not',
          () async {
        final report = await doctor({
          ...wired,
          'public/i18n/pt-BR.json': '{}',
          'public/i18n/fr.json': '{}',
        }, environment: key, httpClient: api(['en', 'es', 'pt-br', 'de']));
        final languages = findings(report, 'languages');
        expect([for (final f in languages) f['level']], ['warn', 'warn']);
        final messages = [for (final f in languages) '${f['message']}'];
        // The whole list of each side leads its message, so a matched code
        // (`pt-br` against `pt-BR.json`) would show here.
        expect(messages.where((m) => m.startsWith('de: ')), hasLength(1));
        expect(messages.where((m) => m.startsWith('fr.json: ')), hasLength(1));
        expect(failures(report), 0);
      });

      test('a file with no language is the only finding when no code lacks '
          'a file', () async {
        final report = await doctor({...wired, 'public/i18n/fr.json': '{}'},
            environment: key, httpClient: api(['en', 'es']));
        final languages = findings(report, 'languages');
        expect([for (final f in languages) f['level']], ['warn']);
        expect(languages.single['message'], startsWith('fr.json: '));
      });

      test('a code with no file is the only finding when no file lacks a '
          'language', () async {
        final report = await doctor(wired,
            environment: key, httpClient: api(['en', 'es', 'de']));
        final languages = findings(report, 'languages');
        expect([for (final f in languages) f['level']], ['warn']);
        expect(languages.single['message'], startsWith('de: '));
      });

      test('a code the server sends in another casing matches its file',
          () async {
        final report = await doctor({...wired, 'public/i18n/pt-BR.json': '{}'},
            environment: key, httpClient: api(['en', 'es', 'pt-BR']));
        expect(finding(report, 'languages')['level'], 'ok');
      });

      test('files that match the project pass and name its languages',
          () async {
        final report = await doctor(wired,
            environment: key, httpClient: api(['en', 'es']));
        final languages = finding(report, 'languages');
        expect(languages['level'], 'ok');
        expect(languages['message'], contains('en, es'));
      });

      test('the base file counts for its language outside output:', () async {
        final report = await doctor({
          'package.json': wired['package.json']!,
          'src/app/app.config.ts': appConfig,
          'src/i18n/en.json': '{}',
          'public/i18n/es.json': '{}',
        },
            config: config.replaceFirst(
                'source: public/i18n/en.json', 'source: src/i18n/en.json'),
            environment: key,
            httpClient: api(['en', 'es']));
        expect(finding(report, 'languages')['level'], 'ok');
      });

      test('a missing configured base file does not count as a locale', () async {
        final report = await doctor({
          ...wired,
        }..remove('public/i18n/en.json'), environment: key,
            httpClient: api(['en', 'es']));
        expect(finding(report, 'source')['level'], 'fail');
        final languages = finding(report, 'languages');
        expect(languages['level'], 'warn');
        expect(languages['message'], startsWith('en: '));
      });

      test('without a key it is unverified and asks nothing', () async {
        final seen = <http.Request>[];
        final report = await doctor(wired, httpClient: api(['en'], seen: seen));
        expect(finding(report, 'languages')['level'], 'unverified');
        expect(seen, isEmpty);
      });

      test('a server that reports no languages is unverified, not a mismatch',
          () async {
        final report =
            await doctor(wired, environment: key, httpClient: api([]));
        expect(finding(report, 'languages')['level'], 'unverified');
      });

      test('a refused read is unverified and carries the status', () async {
        final report = await doctor(wired,
            environment: key,
            httpClient: MockClient((_) async => http.Response('{}', 403)));
        final languages = finding(report, 'languages');
        expect(languages['level'], 'unverified');
        expect(languages['message'], 'the API answered 403');
      });

      test('a read that never answers is unverified, not a crash', () async {
        final report = await doctor(wired,
            environment: key,
            httpClient: MockClient(
                (_) async => throw http.ClientException('offline')));
        final languages = finding(report, 'languages');
        expect(languages['level'], 'unverified');
        expect(languages['message'], contains('offline'));
      });

      test('a Flutter project is not asked for its languages', () async {
        final seen = <http.Request>[];
        final report = await doctor({
          'pubspec.yaml':
              'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n',
        },
            // Mode B: a Mode A project ends in `pull`, so its doctor reads
            // `/meta` for the output format (#2133).
            config: 'projectId: proj_abc\nmode: b\n',
            environment: key,
            httpClient: api(['en'], seen: seen));
        expect(report['stack'], 'flutter');
        expect(findings(report, 'languages'), isEmpty);
        expect(seen.where((r) => r.url.path.endsWith('/meta')), isEmpty);
        expect(seen, isNotEmpty, reason: 'the fake must have been reachable');
      });

      test('D4 refuses a foreign host before the key is sent', () async {
        final seen = <http.Request>[];
        await start(wired,
            config: '${config}baseUrl: https://evil.example\n',
            httpClient: api(['en'], seen: seen));
        final result = await harness.call('doctor');
        expect(result.isError, isTrue);
        expect(errorOf(result)['code'], 'untrusted_base_url');
        expect(seen, isEmpty);
      });
    });

    group('a merged sourceLayout read as the files sync and pull use (#2230)',
        () {
      const key = {'EASYI18N_TOKEN': 'eik_test'};
      final meta = MockClient((request) async => request.url.path
              .endsWith('/meta')
          ? http.Response(
              jsonEncode({
                'baseCode': 'en',
                'languages': [
                  {'code': 'en', 'isBase': true},
                  {'code': 'es', 'isBase': false},
                ],
                'formats': ['json'],
              }),
              200)
          : http.Response('{}', 404));
      String record(String output, Map<String, String> pulled) => jsonEncode({
            'format': 'json', 'output': output,
            'files': pulled.keys.toList(),
            'digests': {
              for (final e in pulled.entries) e.key: contentDigest(e.value),
            },
          });

      const namespacesConfig = 'projectId: proj_abc\nmode: a\nformat: json\n'
          'output: locales\nsource: locales/en/translation.json\n'
          'sourceRoot: locales/en\nsourceLayout: namespaces\n';
      final namespacesPulled = {
        'es/common.json': '{"save": "Guardar"}\n',
        'es/translation.json': '{"title": "Tienda"}\n',
        'es/user-profile.json': '{"pageTitle": "Perfil"}\n',
      };
      final namespaces = {
        ..._namespacesTree,
        for (final e in namespacesPulled.entries) 'locales/${e.key}': e.value,
        '.easyi18n/state.json': record('locales', namespacesPulled),
      };

      const scopesConfig = 'projectId: proj_abc\nmode: a\nformat: json\n'
          'output: public/i18n\nsource: public/i18n/en.json\n'
          'sourceRoot: public/i18n\nsourceLayout: scopes\n';
      final scopesPulled = {
        'es.json': '{"title": "Tienda"}\n',
        'admin/es.json': '{"title": "Administración"}\n',
      };
      final scopes = {
        ..._scopesTree,
        for (final e in scopesPulled.entries) 'public/i18n/${e.key}': e.value,
        '.easyi18n/state.json': record('public/i18n', scopesPulled),
      };

      test('namespaces: every namespace counts, each pulled file is a target '
          'and each directory a language', () async {
        final report = await doctor({
          ...namespaces,
          // Neither is written by pull nor names a language.
          'locales/.cache/es.json': '{}',
          'locales/notes/README.md': '',
        }, config: namespacesConfig, environment: key, httpClient: meta);
        final source = finding(report, 'source');
        expect(source['level'], 'ok');
        expect(source['subject'], endsWith(p.join('locales', 'en')));
        expect(source['message'], startsWith('7 key(s)'));
        expect(source['details'], [
          'locales/en/common.json: 3 key(s)',
          'locales/en/translation.json: 2 key(s)',
          'locales/en/user-profile.json: 2 key(s)',
        ]);
        final targets = finding(report, 'targets');
        expect(targets['level'], 'ok');
        expect(targets['message'], '3 locale file(s), each written by `pull`');
        final languages = finding(report, 'languages');
        expect(languages['level'], 'ok');
        expect(languages['message'], contains('en, es'));
      });

      test('scopes: the root file and each scope count, and a scope file is a '
          'target', () async {
        final report = await doctor(scopes,
            config: scopesConfig, environment: key, httpClient: meta);
        final source = finding(report, 'source');
        expect(source['level'], 'ok');
        expect(source['message'], startsWith('4 key(s)'));
        expect(source['details'], [
          'public/i18n/admin/en.json: 2 key(s)',
          'public/i18n/en.json: 2 key(s)',
        ]);
        final targets = finding(report, 'targets');
        expect(targets['level'], 'ok');
        expect(targets['message'], '2 locale file(s), each written by `pull`');
        expect(finding(report, 'languages')['level'], 'ok');
      });

      for (final (name, files, config, output, edited) in [
        ('namespaces', namespaces, namespacesConfig, 'locales',
            'es/common.json'),
        ('scopes', scopes, scopesConfig, 'public/i18n', 'admin/es.json'),
      ]) {
        test('$name: a target one directory down that changed since its pull '
            'is the warning pull would refuse on', () async {
          final report = await doctor(
              {...files, '$output/$edited': '{"zz": "a mano"}\n'},
              config: config);
          final targets = finding(report, 'targets');
          expect(targets['level'], 'warn');
          // The MCP result cuts a message at 200 characters.
          expect(targets['message'],
              startsWith('$edited: ${changedSincePullFinding.substring(0, 60)}'));
        });
      }

      test('namespaces: a file no pull wrote is named by its directory',
          () async {
        final report = await doctor(
            {...namespaces, 'locales/fr/common.json': '{}'},
            config: namespacesConfig);
        final targets = finding(report, 'targets');
        expect(targets['level'], 'warn');
        expect(targets['message'], startsWith('fr/common.json: not written'));
      });

      test('namespaces: a namespace that nests is not judged against format:',
          () async {
        final report = await doctor(namespaces,
            config: namespacesConfig.replaceFirst(
                'locales/en/translation.json', 'locales/en/user-profile.json'));
        final source = finding(report, 'source');
        expect(source['level'], 'ok');
        expect(source['message'], isNot(contains('format')));
      });

      test('scopes: a root key that collides with a scope fails with the '
          'refusal of the sync', () async {
        final report = await doctor({
          ...scopes,
          'public/i18n/en.json': '{"title": "Shop", "admin": "Admin"}\n',
        }, config: scopesConfig);
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'],
            allOf(startsWith('`admin` is a key of public/i18n/en.json'),
                contains('Rename the key')));
      });

      test('namespaces: a namespace that is not a JSON object fails by its '
          'path', () async {
        final report = await doctor(
            {...namespaces, 'locales/en/common.json': '["save"]\n'},
            config: namespacesConfig);
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['subject'],
            endsWith(p.join('locales', 'en', 'common.json')));
        expect(finding(report, 'targets')['level'], 'skip');
      });

      test('namespaces: a collision is named by the file that holds the key',
          () async {
        final report = await doctor(
            {...namespaces, 'locales/en/common.home.json': '{"title": "H"}\n'},
            config: namespacesConfig);
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'], startsWith('`common.home.title` is a key '));
        expect(source['subject'],
            endsWith(p.join('locales', 'en', 'common.json')));
      });

      test('namespaces: without sourceRoot the source fails as sync refuses',
          () async {
        final report = await doctor(namespaces,
            config: namespacesConfig.replaceFirst('sourceRoot: locales/en\n', ''));
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'], startsWith('Declare sourceRoot'));
      });

      test('namespaces: the base directory is its language outside output:',
          () async {
        final report = await doctor({
          'package.json': _namespacesTree['package.json']!,
          'src/locales/en/translation.json': '{"title": "Shop"}\n',
          'public/locales/es/translation.json': '{"title": "Tienda"}\n',
        },
            config: namespacesConfig
                .replaceFirst('output: locales', 'output: public/locales')
                .replaceAll('locales/en', 'src/locales/en'),
            environment: key,
            httpClient: meta);
        expect(finding(report, 'source')['level'], 'ok');
        expect(finding(report, 'languages')['level'], 'ok');
      });

      test('namespaces: a directory that is no project language is named as '
          'one', () async {
        final report = await doctor(
            {...namespaces, 'locales/old/common.json': '{}'},
            config: namespacesConfig, environment: key, httpClient: meta);
        final languages = finding(report, 'languages');
        expect(languages['level'], 'warn');
        expect(languages['message'], startsWith('old/: the project has no '));
        expect(languages['message'], endsWith('delete the directory'));
      });
    });

    group('a one-file sourceLayout read as the selection sync refuses (#2456)',
        () {
      final meta = MockClient((request) async => request.url.path
              .endsWith('/meta')
          ? http.Response(
              jsonEncode({
                'baseCode': 'en',
                'languages': [
                  {'code': 'en', 'isBase': true},
                  {'code': 'es', 'isBase': false},
                ],
                'formats': ['json'],
              }),
              200)
          : http.Response('{}', 404));
      const localeFiles = 'projectId: proj_abc\nmode: a\nformat: json\n'
          'output: public/i18n\nsource: public/i18n/en.json\n'
          'sourceRoot: public/i18n\nsourceLayout: locale-files\n';
      // A Transloco scope added after init wrote `locale-files`.
      final tree = {
        ..._scopesTree,
        'package.json': wired['package.json']!,
        'src/app/app.config.ts': appConfig,
      };

      /// The doctor report and the sync_preview refusal of one tree.
      Future<(Map<String, Object?>, Map<String, Object?>)> both(String config,
          {Map<String, String> files = const {}}) async {
        await start({...tree, ...files}, config: config, httpClient: meta);
        final report = (await harness.call('doctor')).structuredContent!;
        final preview = await harness.call('sync_preview');
        expect(preview.isError, isTrue);
        return (report, errorOf(preview));
      }

      test('locale-files: a second base-language file fails with the refusal '
          'of the sync, its remedy within the MCP cap', () async {
        final (report, error) = await both(localeFiles);
        expect(error['code'], 'several_files_per_locale');
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['subject'], endsWith(p.join('public', 'i18n', 'en.json')));
        // MCP clips each string of a list at 200 characters (§4.4).
        final refusal = error['message'] as String;
        expect(source['message'], '${refusal.substring(0, 200)}…');
        expect(source['message'], contains('public/i18n/admin/en.json'));
        final details = source['details'] as List;
        expect(details, hasLength(1));
        final remedy = details.single as String;
        expect(refusal, contains(remedy));
        expect(remedy, allOf(contains('`sourceLayout: namespaces`'),
            contains('`sourceLayout: scopes`')));
        expect(remedy.length, lessThanOrEqualTo(200));
        expect(failures(report), 1);
      });

      test('base-tree: the other files under sourceRoot fail as sync refuses '
          'them', () async {
        final (report, error) =
            await both(localeFiles.replaceFirst('locale-files', 'base-tree'));
        expect(error['code'], 'several_files_per_locale');
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'],
            '${(error['message'] as String).substring(0, 200)}…');
      });

      test('the selection is refused before the shape of the base file, as '
          'sync refuses it', () async {
        final (report, error) = await both(localeFiles,
            files: {'public/i18n/en.json': '{"home": {"title": "Shop"}}\n'});
        expect(error['code'], 'several_files_per_locale');
        expect(finding(report, 'source')['message'],
            '${(error['message'] as String).substring(0, 200)}…');
      });

      test('without sourceRoot and sourceLayout the source fails as sync '
          'refuses', () async {
        final (report, error) = await both(localeFiles.replaceFirst(
            'sourceRoot: public/i18n\nsourceLayout: locale-files\n', ''));
        expect(error['code'], 'catalog_scope_unknown');
        final source = finding(report, 'source');
        expect(source['level'], 'fail');
        expect(source['message'], error['message']);
        expect(source['details'], isEmpty);
      });
    });
  });
}
