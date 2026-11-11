@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';
import 'server_test.dart' show errorOf, project;

String _package(Map<String, String> deps, [Map<String, String> dev = const {}]) =>
    jsonEncode({'name': 'demo-shop', 'dependencies': deps, 'devDependencies': dev});

/// What `ng extract-i18n --format=json --output-path=src/locale` writes for
/// the four messages of #2100, byte for byte.
const _messages = r'''{
  "locale": "en-US",
  "translations": {
    "home.title": "Welcome to {$INTERPOLATION}",
    "8639794031277085594": "Hello, {$INTERPOLATION}! You have {$ICU} in your cart.",
    "4151835343882286517": "{VAR_PLURAL, plural, =0 {no items} =1 {one item} other {{INTERPOLATION} items}}",
    "4908502151991961207": "Checkout"
  }
}''';

/// `ng new demo-shop --minimal` + `ng add @angular/localize --use-at-runtime`
/// (Angular 22.2): no `i18n` section and no `extract-i18n` target.
final _runtimeTree = {
  'package.json': _package(
      {'@angular/core': '^22.2.0', '@angular/localize': '~22.2.4'}),
  'angular.json':
      '{"projects": {"demo-shop": {"architect": {"build": {}, "serve": {}}}}}',
  'src/locale/messages.json': _messages,
};

/// The same app with `ng add @angular/localize` and no `--use-at-runtime`.
final _buildTimeTree = {
  ..._runtimeTree,
  'package.json': _package(
      {'@angular/core': '^22.2.0'}, {'@angular/localize': '^22.2.4'}),
};

final _translocoHybrid = {
  ..._runtimeTree,
  'package.json': _package({
    '@angular/core': '^22.2.0',
    '@angular/localize': '~22.2.4',
    '@jsverse/transloco': '^8.4.0',
  }),
  'public/i18n/en.json': '{"hello": "Hello"}\n',
};

/// An Ionic or Capacitor Angular app: `npx cap add android` commits the
/// template `strings.xml` with its manifest.
final _capacitorHybrid = {
  ..._runtimeTree,
  'android/settings.gradle': "include ':app'\n",
  'android/app/src/main/AndroidManifest.xml': '<manifest/>\n',
  'android/app/src/main/res/values/strings.xml':
      '<resources><string name="app_name">Shop</string></resources>\n',
};

const _config = 'projectId: proj_abc\nmode: a\nformat: angular_json\n'
    'output: src/locale\nsource: src/locale/messages.json\n'
    'sourceRoot: src/locale\nsourceLayout: locale-files\n';

const _ref = {'workspace': 'demo', 'project': 'demo-shop'};

const _extract = 'ng extract-i18n --format=json --output-path=src/locale';

Map<String, String> _snapshot(Directory dir) => {
  for (final file in dir.listSync(recursive: true).whereType<File>())
    p.relative(file.path, from: dir.path): file.readAsStringSync(),
};

void main() {
  late Directory dir;
  late McpHarness harness;

  Future<void> start(Map<String, String> files,
      {String? config, http.Client? httpClient}) async {
    final fixture = project(config: config, files: files,
        httpClient: httpClient ?? MockClient((_) async => http.Response('{}', 404)));
    dir = fixture.dir;
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
  }

  List<Map<String, Object?>> stepsOf(CallToolResult result) =>
      (result.structuredContent!['steps'] as List).cast<Map<String, Object?>>();

  String yaml() => File(p.join(dir.path, 'easyi18n.yaml')).readAsStringSync();

  group('init on an Angular tree', () {
    test('auto detects angular and a dry run names the extraction and writes '
        'nothing', () async {
      await start(_runtimeTree);
      final before = _snapshot(dir);
      final result =
          await harness.call('init', {..._ref, 'stack': 'auto', 'dry_run': true});
      final report = result.structuredContent!;
      expect(report['stack'], 'angular');
      expect(report['family'], 'file-first');
      expect(report['next'], 'sync');
      expect(stepsOf(result), contains(allOf(
          containsPair('verb', 'detected'),
          containsPair('detail',
              '@angular/localize in dependencies (translations loaded at runtime)'))));
      expect(stepsOf(result), contains(allOf(
          containsPair('target', p.join(dir.path, 'src', 'locale', 'messages.json')),
          containsPair('detail', contains(_extract)))));
      expect(report['scope_snippet'], contains('loadTranslations('));
      expect(_snapshot(dir), before);
    });

    test('writes the angular_json config and leaves messages.json as it is',
        () async {
      await start(_runtimeTree);
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(result.isError, isNot(true));
      expect(yaml(), allOf(
          contains('\nformat: angular_json\n'),
          contains('\nsource: src/locale/messages.json\n'),
          contains('\nsourceRoot: src/locale\n'),
          contains('\nsourceLayout: locale-files\n'),
          contains('\noutput: src/locale\n')));
      expect(File(p.join(dir.path, 'src/locale/messages.json')).readAsStringSync(),
          _messages);
      final agents = File(p.join(dir.path, 'AGENTS.md')).readAsStringSync();
      expect(agents, allOf(contains('### Angular'), contains(_extract)));
      // A client without MCP reads only this block (D9).
      expect(agents.replaceAll(RegExp(r'\s+'), ' '), allOf(
          contains('Give each message its own id (`i18n="@@cart.title"`): '
              'without one the id is a digest of the text'),
          contains(r'Keep every `{$…}` token as it is.')));
    });

    test('a build-time app is wired through angular.json', () async {
      await start(_buildTimeTree);
      final result =
          await harness.call('init', {..._ref, 'stack': 'auto', 'dry_run': true});
      expect(stepsOf(result), contains(containsPair('detail',
          '@angular/localize in devDependencies (translated at build time)')));
      final snippet = result.structuredContent!['scope_snippet'] as String;
      expect(snippet, allOf(contains('"i18n"'), contains('"localize": true'),
          contains('"es": "src/locale/messages.es.json"')));
      expect(snippet, isNot(contains('loadTranslations')));
    });

    for (final (tree, expected) in [
      (_runtimeTree, '"input": "translations"'),
      (_buildTimeTree, '"es": "translations/messages.es.json"'),
    ]) {
      test('wiring uses the configured output: $expected', () async {
        await start(tree, config: _config.replaceFirst(
            'output: src/locale', 'output: translations'));
        final result = await harness.call('init', {..._ref, 'stack': 'angular'});
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['scope_snippet'], contains(expected));
        expect(yaml(), contains('output: translations'));
      });
    }

    // `en-US` is also Angular's default, so only another locale shows the
    // snippet reads the extracted file.
    test('the build-time wiring names the locale the extractor wrote', () async {
      await start({
        ..._buildTimeTree,
        'src/locale/messages.json':
            _messages.replaceFirst('"locale": "en-US"', '"locale": "fr"'),
      });
      final result =
          await harness.call('init', {..._ref, 'stack': 'auto', 'dry_run': true});
      expect(result.structuredContent!['scope_snippet'],
          contains('"sourceLocale": "fr"'));
    });

    test('with nothing extracted yet, init names the extraction and creates '
        'no base file', () async {
      await start({..._runtimeTree}..remove('src/locale/messages.json'));
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(stepsOf(result), contains(allOf(
          containsPair('verb', 'skipped'),
          containsPair('detail', contains(_extract)))));
      expect(File(p.join(dir.path, 'src/locale/messages.json')).existsSync(),
          isFalse);
    });
  });

  group('optional inputs', () {
    for (final mode in ['a', 'b']) {
      test('file-first mode $mode resolves to a', () async {
        await start(_runtimeTree);
        final result = await harness.call('init',
            {..._ref, 'stack': 'angular', 'mode': mode});
        expect(yaml(), contains('mode: a'));
        final ignored = stepsOf(result).where((s) => s['target'] == 'mode');
        expect(ignored.isNotEmpty, mode != 'a');
      });
    }

    for (final source in [null, '']) {
      test('missing source $source is reported and uses default extraction', () async {
        await start(_runtimeTree, config: _config.replaceFirst(
            'source: src/locale/messages.json\n',
            source == null ? '' : 'source: ""\n'));
        final result = await harness.call('init', {..._ref, 'stack': 'angular'});
        expect(result.isError, isNot(true));
        expect(stepsOf(result), contains(allOf(
            containsPair('target', 'source'), containsPair('verb', 'skipped'))));
        expect(File(p.join(dir.path, 'AGENTS.md')).readAsStringSync(),
            allOf(contains('The extracted file'), contains(_extract)));
      });
    }

    for (final content in [null, 'not json', '{}']) {
      test('build-time fallback locale for $content', () async {
        final files = {..._buildTimeTree};
        if (content == null) {
          files.remove('src/locale/messages.json');
        } else {
          files['src/locale/messages.json'] = content;
        }
        await start(files);
        final result = await harness.call('init', {..._ref, 'stack': 'angular'});
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['scope_snippet'],
            contains('"sourceLocale": "en-US"'));
      });
    }

    test('custom source directory is named in extraction', () async {
      await start(_runtimeTree, config: _config.replaceFirst(
          'source: src/locale/messages.json', 'source: extracted/messages.json'));
      final result = await harness.call('init', {..._ref, 'stack': 'angular'});
      expect(stepsOf(result), contains(containsPair('detail',
          contains('--output-path=extracted'))));
      expect(File(p.join(dir.path, 'AGENTS.md')).readAsStringSync(),
          contains('`extracted/messages.json` is'));
    });
  });

  group('detection', () {
    for (final entry in {
      'no package.json': {..._runtimeTree}..remove('package.json'),
      'non-object package.json': {..._runtimeTree, 'package.json': '[]'},
      'no angular.json': {..._runtimeTree}..remove('angular.json'),
      'no @angular/localize': {
        ..._runtimeTree,
        'package.json': _package({'@angular/core': '^22.2.0'}),
      },
      'a package.json that is not JSON': {
        ..._runtimeTree,
        'package.json': '{"dependencies": ',
      },
    }.entries) {
      test('${entry.key} is not angular', () async {
        await start(entry.value);
        final result = await harness.call('init', {..._ref, 'stack': 'auto'});
        expect(errorOf(result)['code'], 'unsupported_stack');
      });
    }

    // A2: the template marks and the library each translate an Angular app,
    // and only the human knows which one holds the strings.
    test('Transloco beside @angular/localize asks for the stack', () async {
      await start(_translocoHybrid);
      final before = _snapshot(dir);
      final result = await harness.call('init', {..._ref, 'stack': 'auto'});
      expect(result.isError, isTrue);
      final error = errorOf(result);
      expect(error['code'], 'ambiguous_stack');
      expect(error['detected'], ['angular', 'web']);
      expect(error['message'], allOf(contains('@jsverse/transloco'),
          contains('call init again with stack angular or stack web')));
      expect(_snapshot(dir), before);
      for (final named in ['angular', 'web']) {
        final result = await harness.call('init',
            {..._ref, 'stack': named, 'dry_run': true});
        expect(result.isError, isNot(true), reason: named);
        expect(result.structuredContent!['stack'], named);
      }
    });

    test('the CLI asks for --stack on the same tree', () async {
      await start(_translocoHybrid);
      expect(
          () => InitRunner().run(configPath: p.join(dir.path, 'easyi18n.yaml'),
              logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
              projectId: 'p1', stack: 'auto'),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'ambiguous_stack')
              .having((e) => e.message, 'message',
                  contains('run init again with --stack angular or --stack web'))));
    });

    // The order of #2311: Angular claims a tree only through package.json and
    // angular.json, and a Capacitor app commits android/ besides.
    test('a Capacitor app with @angular/localize is angular, and android can '
        'still be named', () async {
      await start(_capacitorHybrid);
      for (final (named, expected) in [
        ('auto', 'angular'), ('angular', 'angular'), ('android', 'android'),
      ]) {
        final result = await harness.call('init',
            {..._ref, 'stack': named, 'dry_run': true});
        expect(result.structuredContent!['stack'], expected, reason: named);
      }
    });

    test('a Flutter or Xcode tree with an Angular app beside stays itself',
        () async {
      for (final (files, expected) in [
        ({'pubspec.yaml': 'name: demo\nflutter:\n'}, 'flutter'),
        ({
          'Demo.xcodeproj/project.pbxproj': '',
          'Demo/Localizable.xcstrings':
              '{"sourceLanguage":"en","version":"1.0","strings":{}}',
        }, 'xcode'),
      ]) {
        await start({..._runtimeTree, ...files});
        final result = await harness.call('init',
            {..._ref, 'stack': 'auto', 'dry_run': true});
        expect(result.structuredContent!['stack'], expected);
      }
    });
  });

  group('after init', () {
    test('sync_preview uploads messages.json and not a translation beside it',
        () async {
      final requests = <http.Request>[];
      await start({
        ..._runtimeTree,
        'src/locale/messages.es.json':
            '{"locale": "es", "translations": {"4908502151991961207": "Pagar"}}',
      }, config: _config, httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(jsonEncode({
          'dryRun': true, 'batchSha256': 'd' * 64, 'format': 'angular_json',
          'baseCode': 'en', 'targetLangs': ['es'], 'fillableLangs': ['es'],
          'created': 4, 'updatedSources': 0, 'matchedSources': 0,
          'updatedTranslations': 0, 'unchangedTranslations': 0,
          'disabledOrphans': 0, 'reenabled': 0, 'failedEntries': [],
          'exhausted': [], 'budgetExhausted': [], 'onConflict': 'server',
          'conflicts': [], 'conflictsTotal': 0, 'diagnostics': [],
          'trackingToken': null, 'estimatedCredits': 2000, 'balance': 900000,
          'availableCredits': 900000, 'accepted': true,
        }), 200);
      }));
      final result = await harness.call('sync_preview');
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      final sync = requests.singleWhere((r) => r.url.path.endsWith('/sync'));
      final body = jsonDecode(sync.body) as Map;
      expect(body['fileName'], 'messages.json');
      expect(body['format'], 'angular_json');
      expect(utf8.decode(base64Decode(body['contentBase64'] as String)), _messages);
    });

    test('pull writes messages.es.json and leaves messages.json as it is',
        () async {
      await start(_runtimeTree, config: _config,
          httpClient: MockClient((req) async => http.Response(jsonEncode({
            'project': 'proj_abc', 'version': '2026.11.02.1', 'baseCode': 'en',
            'formats': ['angular_json'],
            'files': {
              'angular_json/messages.json': _messages,
              'angular_json/messages.es.json':
                  '{\n  "locale": "es",\n  "translations": {\n'
                  '    "4908502151991961207": "Pagar"\n  }\n}',
            },
          }), 200)));
      final result = await harness.call('pull');
      expect(result.isError, isNot(true));
      final locale = p.join(dir.path, 'src', 'locale');
      expect(result.structuredContent!['files_written'],
          [p.normalize(p.absolute(p.join(locale, 'messages.es.json')))]);
      expect(File(p.join(locale, 'messages.json')).readAsStringSync(), _messages);
    });

    List<String> checksOf(Map<String, Object?> report) => [
      for (final f in (report['findings'] as List).cast<Map>()) '${f['check']}',
    ];

    test('doctor grades the tree as angular with the checks of its files',
        () async {
      await start(_runtimeTree, config: _config);
      final report = (await harness.call('doctor')).structuredContent!;
      expect(report['stack'], 'angular');
      final checks = checksOf(report);
      expect(checks, containsAll(['source', 'targets']));
      // Those read a web library and `<locale>.json` names.
      expect(checks, isNot(anyOf(contains('transpiler'), contains('wiring'),
          contains('languages'))));
    });

    test('a Transloco hybrid is graded as angular only once its format says so',
        () async {
      for (final (format, expected) in [('json', 'web'), ('angular_json', 'angular')]) {
        await start(_translocoHybrid,
            config: _config.replaceFirst('angular_json', format));
        final report = (await harness.call('doctor')).structuredContent!;
        expect(report['stack'], expected, reason: format);
      }
    });

    // The mirror of #2316: a hybrid that chose `--stack android` keeps the
    // Android checks.
    test('a Capacitor hybrid configured as android is graded as android',
        () async {
      await start(_capacitorHybrid,
          config: 'projectId: proj_abc\nmode: a\nformat: android_xml\n'
              'output: android/app/src/main/res\n'
              'source: android/app/src/main/res/values/strings.xml\n');
      final report = (await harness.call('doctor')).structuredContent!;
      expect(report['stack'], 'android');
    });
  });

  group('what the agent reads (#2101)', () {
    Map<String, Object?> finding(Map<String, Object?> report, String check) =>
        (report['findings'] as List).cast<Map<String, Object?>>()
            .singleWhere((f) => f['check'] == check);

    Future<Map<String, Object?>> doctor(Map<String, String> files,
            {String format = 'angular_json'}) async {
      await start(files, config: _config.replaceFirst('angular_json', format));
      return (await harness.call('doctor')).structuredContent!;
    }

    test('doctor counts the ids under translations, not locale', () async {
      final source = finding(await doctor(_runtimeTree), 'source');
      expect(source['level'], 'ok');
      expect(source['message'], '4 key(s)');
    });

    // The server reads the file as angular_json and refuses either JSON
    // format with format_mismatch, so nested_json is never the remedy.
    for (final format in ['json', 'nested_json']) {
      test('doctor names angular_json where the config says $format', () async {
        final source = finding(await doctor(_runtimeTree, format: format), 'source');
        expect(source['level'], 'fail');
        expect(source['message'], contains('set `format: angular_json`'));
        expect(source['message'], isNot(contains('set `format: nested_json`')));
      });
    }

    test('the web adapter of a Transloco hybrid names angular_json too',
        () async {
      final report = await doctor(_translocoHybrid, format: 'json');
      expect(report['stack'], 'web');
      expect(finding(report, 'source')['message'],
          contains('set `format: angular_json`'));
    });

    test('doctor refuses angular_json on a file that is not Angular\'s',
        () async {
      final source = finding(await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': '{"hello": "Hello"}',
      }), 'source');
      expect(source['level'], 'fail');
      expect(source['message'], contains('set `format: json`'));
    });

    // The server's rule: exactly a string `locale` and an object
    // `translations`. Anything else that holds them is a catalog of keys.
    for (final (label, file) in [
      ('a third key', '{"locale": "en", "translations": {"a": "A"}, "title": "T"}'),
      ('a locale that is not a string', '{"locale": 1, "translations": {"a": "A"}}'),
    ]) {
      test('a root with $label stays nested_json', () async {
        final source = finding(await doctor({
          ..._runtimeTree,
          'src/locale/messages.json': file,
        }, format: 'nested_json'), 'source');
        expect(source['level'], 'ok', reason: '${source['message']}');
      });
    }

    test('doctor warns about digest ids with the @@id remedy', () async {
      final ids = finding(await doctor(_runtimeTree), 'ids');
      expect(ids['level'], 'warn');
      expect(ids['message'], startsWith('2 of 4 id(s) are digests'));
      expect(ids['message'], contains('@@'));
      expect(ids['details'], ['8639794031277085594', '4908502151991961207']);
    });

    // Angular gives a plural nested in a message an id of its own, derived
    // from its text, and takes no @@id for it: a warning would ask for what
    // the template cannot say (measured with Claude Code on the fixture).
    test('a nested plural keeps its digest without a warning', () async {
      final ids = finding(await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode({
          'locale': 'en-US',
          'translations': {
            'cart.summary': r'You have {$ICU} in your cart.',
            '4151835343882286517':
                '{VAR_PLURAL, plural, =0 {no items} other {{INTERPOLATION} items}}',
          },
        }),
      }), 'ids');
      expect(ids['level'], 'ok');
      expect(ids['message'], '1 custom id(s), no digest; 1 plural or select '
          'message(s) keep the id Angular derives from their text');
    });

    test('a standalone ICU with an explicit id counts as custom', () async {
      final ids = finding(await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode({
          'locale': 'en-US',
          'translations': {
            'pure.count': '{VAR_PLURAL, plural, =0 {none} other {many}}',
          },
        }),
      }), 'ids');
      expect(ids['level'], 'ok');
      expect(ids['message'], '1 custom id(s), no digest');
    });

    for (final source in ['not json', '[]', '{"hello":"Hello"}',
        '{"locale":"en","translations":"Hello"}']) {
      test('unusable source $source reports failure without an ids finding',
          () async {
        await start({..._runtimeTree, 'src/locale/messages.json': source},
            config: _config);
        final result = await harness.call('doctor');
        expect(result.isError, isNot(true));
        final report = result.structuredContent!;
        expect(finding(report, 'source')['level'], 'fail');
        expect((report['findings'] as List).where((f) =>
            (f as Map)['check'] == 'ids'), isEmpty);
      });
    }

    test('a missing source reports failure without an ids finding', () async {
      final files = {..._runtimeTree}..remove('src/locale/messages.json');
      await start(files, config: _config);
      final result = await harness.call('doctor');
      expect(result.isError, isNot(true));
      final report = result.structuredContent!;
      expect(finding(report, 'source')['level'], 'fail');
      expect((report['findings'] as List).where((f) =>
          (f as Map)['check'] == 'ids'), isEmpty);
    });

    test('non-string values are not messages or digest ids', () async {
      final report = await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode({
          'locale': 'en-US',
          'translations': {
            'home.title': 'Welcome',
            '123456789012345678': 42,
            '234567890123456789': {'text': 'Not a message'},
          },
        }),
      });
      expect(finding(report, 'source')['message'], '1 key(s)');
      expect(finding(report, 'ids')['message'], '1 custom id(s), no digest');
      expect(finding(report, 'ids')['level'], 'ok');
    });

    test('doctor is quiet once every message has its own id', () async {
      final ids = finding(await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode({
          'locale': 'en-US',
          'translations': {'home.title': 'Welcome', 'cart.checkout': 'Checkout'},
        }),
      }), 'ids');
      expect(ids['level'], 'ok');
      expect(ids['message'], '2 custom id(s), no digest');
    });

    // A digest is a 63-bit number in decimal, so about one in nine has fewer
    // than 19 digits; a short number is someone's own id.
    test('an 18-digit digest is one, a numeric @@id is not', () async {
      final ids = finding(await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode({
          'locale': 'en-US',
          'translations': {
            'home.title': 'Welcome', '404': 'Not found',
            '123456789012345678': 'Hi',
          },
        }),
      }), 'ids');
      expect(ids['message'], startsWith('1 of 3 id(s) are digests'));
      expect(ids['details'], ['123456789012345678']);
    });

    test('doctor names ten digests and counts the rest', () async {
      final ids = finding(await doctor({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode({
          'locale': 'en-US',
          'translations': {
            for (var i = 0; i < 12; i++) '${1000000000000000000 + i}': 'Text $i',
          },
        }),
      }), 'ids');
      expect(ids['message'], startsWith('12 of 12 id(s) are digests'));
      expect(ids['details'], hasLength(11));
      expect((ids['details'] as List).last, 'and 2 more');
    });

    Map<String, Object?> syncReply() => {
      'dryRun': true, 'batchSha256': 'd' * 64, 'format': 'angular_json',
      'baseCode': 'en', 'targetLangs': ['es'], 'fillableLangs': ['es'],
      'created': 4, 'updatedSources': 0, 'matchedSources': 0,
      'updatedTranslations': 0, 'unchangedTranslations': 0,
      'disabledOrphans': 0, 'reenabled': 0, 'failedEntries': [],
      'exhausted': [], 'budgetExhausted': [], 'onConflict': 'server',
      'conflicts': [], 'conflictsTotal': 0, 'diagnostics': [],
      'trackingToken': null, 'estimatedCredits': 600, 'balance': 900000,
      'availableCredits': 900000, 'accepted': true,
    };

    test('sync_preview lists the {\$…} tokens a translation keeps', () async {
      await start(_runtimeTree, config: _config, httpClient: MockClient(
          (req) async => http.Response(jsonEncode(syncReply()), 200)));
      final result = await harness.call('sync_preview');
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(result.structuredContent!['protected_tokens'],
          [r'{$ICU}', r'{$INTERPOLATION}']);
      expect((result.content.single as TextContent).text,
          contains(r'protected tokens: {$ICU} {$INTERPOLATION}'));
    });

    test('a json catalog answers without protected tokens', () async {
      await start({
        ..._translocoHybrid,
        'public/i18n/en.json': r'{"hello": "Hello {$INTERPOLATION}"}',
      }, config: 'projectId: proj_abc\nmode: a\nformat: json\n'
          'output: public/i18n\nsource: public/i18n/en.json\n'
          'sourceRoot: public/i18n\nsourceLayout: locale-files\n',
          httpClient: MockClient((req) async => http.Response(
              jsonEncode({...syncReply(), 'format': 'json'}), 200)));
      final result = await harness.call('sync_preview');
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(result.structuredContent!.containsKey('protected_tokens'), isFalse);
      expect((result.content.single as TextContent).text,
          isNot(contains('protected tokens')));
    });

    // The human approves the count the manifest carries, and the server
    // refuses an operation that counts none.
    test('authorize counts the ids of messages.json', () async {
      Map<String, Object?>? scope;
      // The parser drops a blank message, so the server counts four.
      final messages = jsonDecode(_messages) as Map;
      (messages['translations'] as Map)['blank.id'] = '  ';
      await start({
        ..._runtimeTree,
        'src/locale/messages.json': jsonEncode(messages),
      }, config: _config,
          httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/sync')) {
          return http.Response(jsonEncode(syncReply()), 200);
        }
        if (req.url.path.endsWith('/meta')) {
          return http.Response(jsonEncode({
            'baseCode': 'en', 'formats': ['angular_json'],
            'outputFormatsApiVersion': 1,
            'languages': [
              {'code': 'en', 'isBase': true}, {'code': 'es', 'isBase': false},
            ],
          }), 200);
        }
        if (req.url.path == '/v1/operations') {
          scope = ((jsonDecode(req.body) as Map)['scope'] as Map).cast();
          return http.Response(jsonEncode({
            'operation_id': 'op_1', 'action': 'translate',
            'state': 'pending_approval',
            'approval_url': 'https://app.easyi18n.com/approve/op_1',
          }), 201);
        }
        return http.Response('{"error":"not_found"}', 404);
      }));
      final result = await harness
          .call('authorize', {'action': 'translate', 'max_credits': 1});
      expect(result.isError, isNot(true), reason: '${result.structuredContent}');
      expect(scope!['unit_count'], 4);
    });
  });
}
