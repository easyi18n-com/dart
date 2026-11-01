import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:easyi18n_cli/src/xcstrings_catalogs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// `catalogs:` (#590): several String Catalogs are one project. Sync uploads the
// union of their entries with every key intact; pull hands each key back to
// the file it came from.
void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;
  final requests = <http.Request>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_catalogs');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
    requests.clear();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const localizable = ['Start call', 'Settings'];
  const shortcuts = [r'Start an escape call in ${applicationName}'];
  const infoPlist = ['NSCameraUsageDescription'];

  String catalog(List<String> keys, {String sourceLanguage = 'en'}) =>
      jsonEncode({
        'sourceLanguage': sourceLanguage,
        'version': '1.0',
        'strings': {for (final k in keys) k: <String, Object?>{}},
      });

  String served(List<String> keys) => jsonEncode({
        'sourceLanguage': 'en',
        'version': '1.0',
        'strings': {
          for (final k in keys)
            k: {
              'localizations': {
                'es': {
                  'stringUnit': {'state': 'translated', 'value': 'es:$k'},
                },
              },
            },
        },
      });

  void writeCatalog(String name, List<String> keys,
          {String sourceLanguage = 'en'}) =>
      File(p.join(dir.path, 'App', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(catalog(keys, sourceLanguage: sourceLanguage));

  String writeConfig(String body) {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync('projectId: p1\nformat: xcstrings\n$body');
    return path;
  }

  const threeFiles = 'catalogs:\n'
      '  - App/Localizable.xcstrings\n'
      '  - App/AppShortcuts.xcstrings\n'
      '  - App/InfoPlist.xcstrings\n';

  void threeCatalogs() {
    writeCatalog('Localizable.xcstrings', localizable);
    writeCatalog('AppShortcuts.xcstrings', shortcuts);
    writeCatalog('InfoPlist.xcstrings', infoPlist);
  }

  Map<String, Object?> syncBody(http.Request req) => {
        'dryRun': req.url.queryParameters['dryRun'] == 'true',
        'format': 'xcstrings',
        'baseCode': 'en',
        'targetLangs': ['es'],
        'fillableLangs': ['es'],
        'created': 4,
        'updatedSources': 0,
        'matchedSources': 0,
        'updatedTranslations': 0,
        'unchangedTranslations': 0,
        'disabledOrphans': 0,
        'reenabled': 0,
        'failedEntries': [],
        'exhausted': [],
        'conflicts': [],
        'conflictsTotal': 0,
        'onConflict': 'server',
        'diagnostics': [],
        'trackingToken': req.url.queryParameters['dryRun'] == 'true' ? null : 'job1',
        'estimatedCredits': 0,
        'balance': 500000,
        'accepted': true,
      };

  TranslationsApiClient Function({required String baseUrl, required String token})
      factoryServing(String catalogs, {Map<String, String>? files}) => ({
            required String baseUrl,
            required String token,
          }) =>
              TranslationsApiClient(
                baseUrl: baseUrl,
                token: token,
                httpClient: MockClient((req) async {
                  requests.add(req);
                  final path = req.url.path;
                  Map<String, Object?> body;
                  var status = 200;
                  if (path.endsWith('/meta')) {
                    body = {
                      'baseCode': 'en',
                      'mode': null,
                      'currentVersionId': '2026.08.11.1',
                      'languages': [],
                      'formats': ['xcstrings'],
                      'outputFormatsApiVersion': 1,
                    };
                  } else if (path.endsWith('/sync')) {
                    body = syncBody(req);
                  } else if (path.endsWith('/translations') &&
                      req.url.queryParameters.containsKey('trackingToken')) {
                    body = {
                      'status': 'done',
                      'summary': {
                        'total': 4,
                        'translated': 4,
                        'pending': 0,
                        'failed': 0,
                      },
                    };
                  } else if (path.endsWith('/publish')) {
                    body = {'versionId': '2026.08.11.1', 'keyCount': 4};
                    status = 201;
                  } else if (path.endsWith('/translations')) {
                    body = {
                      'project': 'p1',
                      'version': '2026.08.11.1',
                      'baseCode': 'en',
                      'formats': ['xcstrings'],
                      'files': files ?? {'xcstrings/Localizable.xcstrings': catalogs},
                    };
                  } else {
                    return http.Response('{"error":"not_found"}', 404);
                  }
                  return http.Response(jsonEncode(body), status,
                      headers: const {'content-type': 'application/json'});
                }),
              );

  Future<int?> sync(String config, {String servedCatalog = ''}) {
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(SyncCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factoryServing(servedCatalog.isEmpty
            ? served([...localizable, ...shortcuts, ...infoPlist])
            : servedCatalog),
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
        confirm: (_) => true,
        wait: (_) async {},
        random: Random(7),
      ));
    return runner.run(['--config', config, 'sync', '--yes']);
  }

  Future<int?> pull(String config, String servedCatalog,
      {List<String> flags = const [], Map<String, String>? files}) {
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(PullCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factoryServing(servedCatalog, files: files),
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ));
    return runner.run(['--config', config, 'pull', ...flags]);
  }

  Set<String> keysOf(String name) {
    final doc = jsonDecode(File(p.join(dir.path, 'App', name)).readAsStringSync())
        as Map<String, Object?>;
    return (doc['strings'] as Map).keys.cast<String>().toSet();
  }

  Set<String> translatedIn(String name) {
    final doc = jsonDecode(File(p.join(dir.path, 'App', name)).readAsStringSync())
        as Map<String, Object?>;
    return {
      for (final e in (doc['strings'] as Map).entries)
        if ((e.value as Map)['localizations'] != null) e.key as String,
    };
  }

  Set<String> uploadedKeys(http.Request req) {
    final body = jsonDecode(req.body) as Map<String, Object?>;
    final doc = jsonDecode(utf8.decode(base64Decode(body['contentBase64'] as String)))
        as Map<String, Object?>;
    return (doc['strings'] as Map).keys.cast<String>().toSet();
  }

  group('sync', () {
    test('A1: uploads the keys of every file once, with no table prefix', () async {
      threeCatalogs();
      expect(await sync(writeConfig(threeFiles)), 0);

      final posts = requests.where((r) => r.url.path.endsWith('/sync')).toList();
      expect(posts, hasLength(2));
      for (final post in posts) {
        expect(uploadedKeys(post),
            {...localizable, ...shortcuts, ...infoPlist});
      }
    });

    test('A5: writes each translation back into the file the key came from',
        () async {
      threeCatalogs();
      expect(await sync(writeConfig(threeFiles)), 0);

      expect(keysOf('Localizable.xcstrings'), localizable.toSet());
      expect(keysOf('AppShortcuts.xcstrings'), shortcuts.toSet());
      expect(keysOf('InfoPlist.xcstrings'), infoPlist.toSet());
      expect(File(p.join(dir.path, '.easyi18n', 'state.json')).existsSync(), isFalse,
          reason: 'sync runs in CI on every push and records no pull');
      expect(translatedIn('Localizable.xcstrings'), localizable.toSet());
      expect(translatedIn('AppShortcuts.xcstrings'), shortcuts.toSet());
      expect(translatedIn('InfoPlist.xcstrings'), infoPlist.toSet());
    });

    test('A6: the same key in two files is refused before anything is sent',
        () async {
      writeCatalog('Localizable.xcstrings', [...localizable, 'Shared']);
      writeCatalog('AppShortcuts.xcstrings', ['Shared']);
      writeCatalog('InfoPlist.xcstrings', infoPlist);

      await expectLater(
        sync(writeConfig(threeFiles)),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'catalog_key_collision')
            .having((e) => e.message, 'message', contains('Shared'))
            .having((e) => e.message, 'message', contains('Localizable.xcstrings'))
            .having((e) => e.message, 'message', contains('AppShortcuts.xcstrings'))),
      );
      expect(requests, isEmpty);
    });

    test('A6: `catalog:` next to `catalogs:` is refused naming both', () async {
      threeCatalogs();
      await expectLater(
        sync(writeConfig('catalog: App/Localizable.xcstrings\n$threeFiles')),
        throwsA(isA<CliException>()
            .having((e) => e.message, 'message', contains('`catalog:`'))
            .having((e) => e.message, 'message', contains('`catalogs:`'))),
      );
      expect(requests, isEmpty);
    });

    test('files that disagree on the base language are refused', () async {
      writeCatalog('Localizable.xcstrings', localizable);
      writeCatalog('AppShortcuts.xcstrings', shortcuts, sourceLanguage: 'es');
      writeCatalog('InfoPlist.xcstrings', infoPlist);

      await expectLater(
        sync(writeConfig(threeFiles)),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'catalog_base_language_mismatch')
            .having((e) => e.message, 'message', contains('AppShortcuts.xcstrings'))
            .having((e) => e.message, 'message', contains('base language "es"'))
            .having((e) => e.message, 'message', contains('has "en"'))),
      );
      expect(requests, isEmpty);
    });

    group('the base-language claim (#671)', () {
      Future<String?> claimWith(CliState state) async {
        threeCatalogs();
        final config = writeConfig(threeFiles);
        state.save(CliState.fileFor(config));
        expect(await sync(config), 0);
        final dry = requests.firstWhere((r) => r.url.path.endsWith('/sync'));
        return (jsonDecode(dry.body) as Map)['pulledAt'] as String?;
      }

      const listed = [
        'App/Localizable.xcstrings',
        'App/AppShortcuts.xcstrings',
        'App/InfoPlist.xcstrings',
      ];
      final at = DateTime.utc(2026, 8, 1, 9);

      test('is armed by a pull of this very list', () async {
        expect(
            await claimWith(CliState(
                format: 'xcstrings', snapshotAt: at, catalogs: listed)),
            at.toIso8601String());
      });

      test('is not armed by a pull of another list or of a single catalog', () async {
        expect(
            await claimWith(CliState(
                format: 'xcstrings', snapshotAt: at, catalogs: listed.take(2).toList())),
            isNull);
        requests.clear();
        expect(
            await claimWith(CliState(
                format: 'xcstrings', snapshotAt: at, catalog: listed.first)),
            isNull);
      });
    });

    test('a language missing from ANY file is reported, not only from the first',
        () async {
      threeCatalogs();
      // Every key has its Spanish cell except the shortcuts one.
      final partial = jsonEncode({
        'sourceLanguage': 'en',
        'version': '1.0',
        'strings': {
          for (final k in [...localizable, ...infoPlist])
            k: {
              'localizations': {
                'es': {
                  'stringUnit': {'state': 'translated', 'value': 'es:$k'},
                },
              },
            },
          for (final k in shortcuts) k: <String, Object?>{},
        },
      });

      expect(await sync(writeConfig(threeFiles), servedCatalog: partial), 0);

      expect(err.toString(), contains('missing from the catalog just written'));
      expect(err.toString(), contains('es'));
    });

    test('one catalogs entry uploads what `catalog:` of that file uploads (A4)',
        () async {
      writeCatalog('Localizable.xcstrings', localizable);
      final all = served(localizable);
      expect(
          await sync(writeConfig('catalogs:\n  - App/Localizable.xcstrings\n'),
              servedCatalog: all),
          0);
      final viaList = uploadedKeys(
          requests.firstWhere((r) => r.url.path.endsWith('/sync')));
      requests.clear();
      expect(
          await sync(writeConfig('catalog: App/Localizable.xcstrings\n'),
              servedCatalog: all),
          0);
      expect(
          uploadedKeys(requests.firstWhere((r) => r.url.path.endsWith('/sync'))),
          viaList);
    });

    test('a missing file is named, and nothing is sent', () async {
      writeCatalog('Localizable.xcstrings', localizable);
      await expectLater(
        sync(writeConfig(threeFiles)),
        throwsA(isA<CliException>()
            .having((e) => e.message, 'message', contains('AppShortcuts.xcstrings'))),
      );
      expect(requests, isEmpty);
    });
  });

  group('pull', () {
    test('A5: each key lands in its own file; a key no file has is named, not written',
        () async {
      threeCatalogs();
      final all = [...localizable, ...shortcuts, ...infoPlist, 'Only on the dashboard'];

      expect(await pull(writeConfig(threeFiles), served(all)), 0);

      expect(translatedIn('Localizable.xcstrings'), localizable.toSet());
      expect(translatedIn('AppShortcuts.xcstrings'), shortcuts.toSet());
      expect(translatedIn('InfoPlist.xcstrings'), infoPlist.toSet());
      for (final name in ['Localizable', 'AppShortcuts', 'InfoPlist']) {
        expect(keysOf('$name.xcstrings'), isNot(contains('Only on the dashboard')));
      }
      expect(err.toString(), contains('Only on the dashboard'));
    });

    test('--dry-run plans every file and writes none', () async {
      threeCatalogs();
      final before = [
        for (final n in ['Localizable', 'AppShortcuts', 'InfoPlist'])
          File(p.join(dir.path, 'App', '$n.xcstrings')).readAsStringSync(),
      ];

      expect(
          await pull(writeConfig(threeFiles),
              served([...localizable, ...shortcuts, ...infoPlist]),
              flags: ['--dry-run']),
          0);

      expect([
        for (final n in ['Localizable', 'AppShortcuts', 'InfoPlist'])
          File(p.join(dir.path, 'App', '$n.xcstrings')).readAsStringSync(),
      ], before);
      expect(out.toString(), contains('Would write the translated catalogs'));
      expect(File(p.join(dir.path, '.easyi18n', 'state.json')).existsSync(), isFalse);
    });

    test('records the list it wrote, for status', () async {
      threeCatalogs();
      final config = writeConfig(threeFiles);
      final all = served([...localizable, ...shortcuts, ...infoPlist]);

      expect(await pull(config, all), 0);
      expect(CliState.load(CliState.fileFor(config)).catalogs, [
        'App/Localizable.xcstrings',
        'App/AppShortcuts.xcstrings',
        'App/InfoPlist.xcstrings',
      ]);
      expect(CliState.load(CliState.fileFor(config)).catalog, isNull);
    });

    test('a base text the pull replaces is reported against the served base language',
        () async {
      // The file declares no sourceLanguage, so the served one is the only
      // base the replacement report has.
      File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'strings': {
            'Start call': {
              'localizations': {
                'en': {'stringUnit': {'state': 'translated', 'value': 'Edited by hand'}},
              },
            },
          },
        }));
      final servedBase = jsonEncode({
        'sourceLanguage': 'en',
        'strings': {
          'Start call': {
            'localizations': {
              'en': {'stringUnit': {'state': 'translated', 'value': 'Start call'}},
            },
          },
        },
      });

      expect(await pull(writeConfig('catalogs:\n  - App/Localizable.xcstrings\n'), servedBase), 0);

      expect(err.toString(), contains('Conflict: Start call [en]'));
    });

    test('a per-locale format cannot take catalogs, and nothing is written', () async {
      threeCatalogs();
      final config = p.join(dir.path, 'easyi18n.yaml');
      File(config).writeAsStringSync('projectId: p1\nformat: arb\n$threeFiles');
      final before = File(p.join(dir.path, 'App', 'Localizable.xcstrings')).readAsStringSync();

      await expectLater(
        pull(config, served(localizable)),
        throwsA(isA<CliException>().having((e) => e.message, 'message', contains('one file per locale'))),
      );
      expect(File(p.join(dir.path, 'App', 'Localizable.xcstrings')).readAsStringSync(), before);
    });

    test('a catalog that is also `source:` is never written', () async {
      threeCatalogs();
      final config = writeConfig('source: App/Localizable.xcstrings\n$threeFiles');
      final before = File(p.join(dir.path, 'App', 'Localizable.xcstrings')).readAsStringSync();

      await expectLater(
        pull(config, served(localizable)),
        throwsA(isA<CliException>().having((e) => e.code, 'code', 'source_collision')),
      );
      expect(File(p.join(dir.path, 'App', 'Localizable.xcstrings')).readAsStringSync(), before);
    });

    test('a backend that serves two files for a catalog is refused', () async {
      threeCatalogs();
      await expectLater(
        pull(writeConfig(threeFiles), '', files: {
          'xcstrings/Localizable.xcstrings': served(localizable),
          'xcstrings/Other.xcstrings': served(shortcuts),
        }),
        throwsA(isA<CliException>().having((e) => e.message, 'message', contains('served 2'))),
      );
    });

    test('the same key in two files is refused and nothing is written', () async {
      writeCatalog('Localizable.xcstrings', [...localizable, 'Shared']);
      writeCatalog('AppShortcuts.xcstrings', ['Shared']);
      writeCatalog('InfoPlist.xcstrings', infoPlist);
      final before = File(p.join(dir.path, 'App', 'InfoPlist.xcstrings')).readAsStringSync();

      await expectLater(
        pull(writeConfig(threeFiles), served([...localizable, 'Shared', ...infoPlist])),
        throwsA(isA<CliException>().having((e) => e.code, 'code', 'catalog_key_collision')),
      );
      expect(File(p.join(dir.path, 'App', 'InfoPlist.xcstrings')).readAsStringSync(), before);
    });
  });

  group('XcstringsCatalogs', () {
    CatalogFile file(String name, String content) {
      final path = p.join(dir.path, name);
      File(path).writeAsStringSync(content);
      return CatalogFile(name, path);
    }

    test('upload keeps the first file\'s document and every entry verbatim', () {
      final a = file('a.xcstrings',
          '{"sourceLanguage":"en","version":"1.0","strings":{"x":{"comment":"c"}}}');
      final b = file('b.xcstrings',
          '{"sourceLanguage":"en","version":"1.0","strings":{"y":{"shouldTranslate":false}}}');
      final doc = jsonDecode(utf8.decode(XcstringsCatalogs.read([a, b]).upload)) as Map;
      expect(doc['sourceLanguage'], 'en');
      expect(doc['version'], '1.0');
      expect(doc['strings'], {
        'x': {'comment': 'c'},
        'y': {'shouldTranslate': false},
      });
    });

    test('split gives each file only the entries of its keys, in served form', () {
      final a = file('a.xcstrings', catalog(['x']));
      final b = file('b.xcstrings', catalog(['y']));
      final split = XcstringsCatalogs.read([a, b]).split(jsonEncode({
        'sourceLanguage': 'en',
        'version': '1.0',
        'strings': {
          'y': {'localizations': {'es': {'stringUnit': {'value': 'Y'}}}},
          'x': {'localizations': {'es': {'stringUnit': {'value': 'X'}}}},
          'z': {},
        },
      }));
      expect(split.unplaced, ['z']);
      expect([for (final part in split.parts) (jsonDecode(part) as Map)['strings']], [
        {'x': {'localizations': {'es': {'stringUnit': {'value': 'X'}}}}},
        {'y': {'localizations': {'es': {'stringUnit': {'value': 'Y'}}}}},
      ]);
    });

    test('a file that is not a String Catalog is named', () {
      final a = file('a.xcstrings', catalog(['x']));
      final b = file('b.xcstrings', '{"sourceLanguage":"en","strings": []}');
      expect(() => XcstringsCatalogs.read([a, b]),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              allOf(contains('b.xcstrings'), contains('not a String Catalog')))));
      final c = file('c.xcstrings', 'not json');
      expect(() => XcstringsCatalogs.read([a, c]),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              allOf(contains('c.xcstrings'), contains('not valid JSON')))));
    });
  });
}
