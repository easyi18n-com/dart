import 'dart:io';
import 'dart:math';

import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:easyi18n_cli/src/sync_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const runner = SyncRunner();
  late Directory dir;
  late _Progress progress;
  late List<Duration> waited;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_sync_runner');
    progress = _Progress();
    waited = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig({String catalog = 'App/Localizable.xcstrings'}) {
    final path = p.join(dir.path, 'easyi18n.yaml');
    File(path).writeAsStringSync(
      'projectId: p1\n'
      'format: xcstrings\n'
      '${catalog.isEmpty ? '' : 'catalog: $catalog\n'}',
    );
    return path;
  }

  File writeCatalog([String content = '{"version":"1.0"}']) =>
      File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  Easyi18nConfig load(String path) => Easyi18nConfig.load(File(path));

  group('scan', () {
    test('resolves the catalog against the config directory', () {
      final configPath = writeConfig();
      final file = writeCatalog();
      final scan = runner.scan(load(configPath), configPath: configPath);
      expect(scan.path, p.normalize(file.path));
      expect(scan.fileName, 'Localizable.xcstrings');
      expect(scan.file.existsSync(), isTrue);
    });

    // Both halves of the guard: a config that never named a catalog, and one
    // whose `catalog:` is present but blank — the second is what a hand-edited
    // file produces, and it resolves to the config's own directory.
    for (final (name, yaml) in [
      ('no catalog at all', ''),
      ('a blank catalog', "catalog: ''\n"),
    ]) {
      test('refuses $name', () {
        final configPath = p.join(dir.path, 'easyi18n.yaml');
        File(configPath).writeAsStringSync(
          'projectId: p1\nformat: xcstrings\n$yaml',
        );
        expect(
          () => runner.scan(load(configPath), configPath: configPath),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              allOf(contains('No `catalog:`'), contains(configPath)))),
        );
      });
    }

    test('refuses a catalog that is not on disk, naming the resolved path', () {
      final configPath = writeConfig();
      expect(
        () => runner.scan(load(configPath), configPath: configPath),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            'Catalog not found: '
                '${p.normalize(p.join(dir.path, 'App/Localizable.xcstrings'))}')),
      );
    });
  });

  group('a per-locale project (source:)', () {
    String writeWebConfig({
      String source = 'public/i18n/en.json',
      String output = 'public/i18n',
      String? sourceRoot = '.',
      String sourceLayout = 'locale-files',
      List<String> files = const [],
    }) {
      final path = p.join(dir.path, 'easyi18n.yaml');
      File(path).writeAsStringSync(
        'projectId: p1\nmode: a\nformat: json\noutput: $output\n'
        'source: $source\n${sourceRoot == null ? '' : 'sourceRoot: $sourceRoot\n'}sourceLayout: $sourceLayout\n',
      );
      for (final rel in [source, ...files]) {
        File(p.join(dir.path, rel))
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      }
      return path;
    }

    Future<SyncPreview> webPreview(String path, _Client client) async => runner.preview(
      client, 'p1', runner.scan(load(path), configPath: path),
      config: load(path), configPath: path, onConflict: 'server',
    );

    Future<SyncScan> checkedScan(String path, {String baseCode = 'en'}) async {
      final client = _Client(baseCode: baseCode);
      addTearDown(client.close);
      return (await webPreview(path, client)).scan;
    }

    Matcher refusesNaming(String source, List<String> others) => throwsA(
          isA<CliException>()
              .having((e) => e.code, 'code', 'several_files_per_locale')
              .having((e) => e.message, 'message',
                  allOf([source, ...others].map(contains).toList()))
              .having((e) => e.details, 'details',
                  {'source': source, 'files': others}),
        );

    for (final output in ['public/i18n', 'locales/en', 'locales']) {
      for (final alias in [false, true]) {
        test('input catalog is unchanged by output $output and alias $alias', () async {
          const physical = 'locales/en/common.json';
          final path = writeWebConfig(source: physical, sourceRoot: 'locales/en', sourceLayout: 'base-tree', output: output,
              files: ['locales/en/other.json']);
          final source = alias ? 'locales/source.json' : physical;
          if (alias) {
            Link(p.join(dir.path, source)).createSync(p.join(dir.path, physical));
            File(path).writeAsStringSync(File(path).readAsStringSync()
                .replaceFirst('source: $physical', 'source: $source'));
          }
          final client = _Client();
          addTearDown(client.close);
          await expectLater(webPreview(path, client),
              refusesNaming(source, ['locales/en/other.json']));
          expect(client.calls, isEmpty, reason: 'no catalog POST, including preview');
        });
      }
    }

    for (final alias in [false, true]) {
      for (final location in ['', 'locales/en', 'locales/en/group',
        'locales/en/group/deeper']) {
        for (final explicitRoot in [false, true]) {
          for (final relativeConfig in [false, true]) {
            test('moving YAML preserves declared base-tree: alias=$alias '
                'location=[$location] root=$explicitRoot relative=$relativeConfig', () async {
              final physical = alias ? 'catalogs/group/deeper' : 'locales/en/group/deeper';
              writeWebConfig(source: '$physical/source/common.json', sourceRoot: physical, sourceLayout: 'base-tree',
                  files: ['$physical/sibling/other.json']);
              if (alias) {
                Directory(p.join(dir.path, 'locales')).createSync();
                Link(p.join(dir.path, 'locales/en')).createSync(p.join(dir.path, 'catalogs'));
              }
              final configDir = p.join(dir.path, location);
              final absolutePath = p.join(configDir, 'easyi18n.yaml');
              final source = p.relative(p.join(dir.path, 'locales/en/group/deeper/source/common.json'),
                  from: configDir);
              File(absolutePath).writeAsStringSync('projectId: p1\nformat: json\n'
                  'source: $source\noutput: generated\n'
                  'sourceRoot: ${p.relative(p.join(dir.path, 'locales/en/group/deeper'), from: configDir)}${explicitRoot ? '/.' : ''}\nsourceLayout: base-tree\n');
              final path = relativeConfig ? p.relative(absolutePath) : absolutePath;
              final other = p.relative(File(p.join(dir.path, physical, 'sibling/other.json')).resolveSymbolicLinksSync(),
                  from: Directory(configDir).resolveSymbolicLinksSync());
              final client = _Client();
              addTearDown(client.close);
              await expectLater(webPreview(path, client),
                  refusesNaming(p.split(source).join('/'), [p.split(other).join('/')]));
              expect(client.calls, isEmpty, reason: 'no catalog POST, including preview');
            });
          }
        }
      }
    }

    test('relative YAML inside a locale ancestor retains namespace context', () async {
      writeWebConfig(source: 'en/group/common.json', sourceRoot: 'en', sourceLayout: 'base-tree', files: ['en/group/other.json']);
      File(p.join(dir.path, 'en/group/easyi18n.yaml')).writeAsStringSync(
          'projectId: p1\nformat: json\nsource: common.json\nsourceRoot: .\nsourceLayout: base-tree\n');
      final client = _Client();
      addTearDown(client.close);
      final path = p.relative(p.join(dir.path, 'en/group/easyi18n.yaml'));
        await expectLater(webPreview(path, client),
            refusesNaming('common.json', ['other.json']));
        expect(client.calls, isEmpty, reason: 'no catalog POST');
    });

    for (final spread in [false, true]) {
      test('an input alias cannot hide sibling namespace files: spread=$spread', () async {
        final source = spread ? 'source/common.json' : 'common.json';
        final other = spread ? 'sibling/other.json' : 'other.json';
        writeWebConfig(source: 'catalogs/group/$source', sourceRoot: 'catalogs/group', sourceLayout: 'base-tree',
            files: ['catalogs/group/$other']);
        Link(p.join(dir.path, 'en')).createSync(p.join(dir.path, 'catalogs'));
        File(p.join(dir.path, 'catalogs/group/easyi18n.yaml')).writeAsStringSync(
            'projectId: p1\nformat: json\nsource: $source\nsourceRoot: .\nsourceLayout: base-tree\n');
          final client = _Client();
        addTearDown(client.close);
        final path = p.relative(p.join(dir.path, 'en/group/easyi18n.yaml'));
          await expectLater(webPreview(path, client),
              refusesNaming(source, [other]));
          expect(client.calls, isEmpty, reason: 'no catalog POST');
          File(p.join(dir.path, 'catalogs/group', other)).deleteSync();
          await webPreview(path, client);
          expect(client.calls.single.dryRun, isTrue);
      });
    }

    for (final sourceAlias in [false, true]) {
      test('a base-locale filename through an alias stays per-locale: $sourceAlias', () async {
        final path = writeWebConfig(source: 'catalogs/${sourceAlias ? 'en' : 'base'}.json',
            files: ['catalogs/es.json']);
        final alias = 'catalogs/${sourceAlias ? 'base' : 'en'}.json';
        Link(p.join(dir.path, alias)).createSync(
            p.join(dir.path, 'catalogs/${sourceAlias ? 'en' : 'base'}.json'));
        File(path).writeAsStringSync(File(path).readAsStringSync()
            .replaceFirst(RegExp(r'source: .*'), 'source: $alias'));
        final client = _Client();
        addTearDown(client.close);
        await webPreview(path, client);
        expect(client.calls.single.dryRun, isTrue);
      });
    }

    test('a locale-named source still retains enclosing locale ancestors', () async {
      writeWebConfig(source: 'en/group/deeper/en.json', sourceRoot: 'en', sourceLayout: 'base-tree', files: ['en/group/deeper/other.json']);
      final path = p.join(dir.path, 'en/group/deeper/easyi18n.yaml');
      File(path).writeAsStringSync('projectId: p1\nformat: json\nsource: en.json\nsourceRoot: .\nsourceLayout: base-tree\n');
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client), refusesNaming('en.json', ['other.json']));
      expect(client.calls, isEmpty, reason: 'no catalog POST');
    });

    for (final physical in [false, true]) {
      test('${physical ? 'physical' : 'logical'} source context keeps other languages separate', () async {
        final target = physical ? 'locales/en/common.json' : 'catalogs/common.json';
        final path = writeWebConfig(source: target, sourceRoot: physical ? 'locales/en' : 'catalogs', sourceLayout: 'base-tree', files: ['es/common.json']);
        final source = physical ? 'source.json' : 'en/common.json';
        if (physical) {
          Link(p.join(dir.path, source)).createSync(p.join(dir.path, target));
        } else {
          Link(p.join(dir.path, 'en')).createSync(p.join(dir.path, 'catalogs'));
        }
        File(path).writeAsStringSync(File(path).readAsStringSync()
            .replaceFirst('source: $target', 'source: $source'));
        final client = _Client();
        addTearDown(client.close);
        await webPreview(path, client);
        expect(client.calls.single.dryRun, isTrue);
      });
    }

    for (final (base, name) in [('EN', 'en'), ('pt_BR', 'pt-BR'),
      ('PT-br', 'pt_br'), ('en-US', 'en_us')]) {
      test('base language normalization keeps target files separate: $base', () async {
        final path = writeWebConfig(source: 'catalogs/$name.json',
            files: ['catalogs/es.json']);
        final client = _Client(baseCode: base);
        addTearDown(client.close);
        await webPreview(path, client);
        expect(client.calls.single.dryRun, isTrue);
      });
    }

    test('a cancelled locale segment does not create namespace context', () async {
      final path = writeWebConfig(sourceRoot: null, source: 'catalogs/en.json', files: ['catalogs/es.json']);
      Directory(p.join(dir.path, 'en')).createSync();
      File(path).writeAsStringSync('sourceRoot: en/../catalogs/group/..\n', mode: FileMode.append);
      Directory(p.join(dir.path, 'catalogs/group')).createSync();
      final client = _Client();
      addTearDown(client.close);
      await webPreview(path, client);
      expect(client.calls.single.dryRun, isTrue);
    });

    test('declared inputs exclude generated files independently of output', () async {
      final path = writeWebConfig(sourceRoot: null, source: 'i18n/en.json', output: 'public/i18n',
          files: ['i18n/generated/en.json', 'unrelated/en.json']);
      File(path).writeAsStringSync('sourceRoot: i18n\n'
          'sourceExclude: [i18n/generated]\n', mode: FileMode.append);
      final client = _Client();
      addTearDown(client.close);
      await webPreview(path, client);
      expect(client.calls.single.dryRun, isTrue);
    });

    test('generated exclusion cannot hide the physical source', () async {
      final path = writeWebConfig(source: 'locales/en/common.json', sourceRoot: 'locales/en', sourceLayout: 'base-tree', output: 'public/i18n');
      Link(p.join(dir.path, 'generated')).createSync(p.join(dir.path, 'locales'));
      File(path).writeAsStringSync('sourceExclude: [generated]\n', mode: FileMode.append);
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'catalog_scope_unknown')));
      expect(client.calls, isEmpty);
    });

    test('a hardlink in the inventory cannot admit an explicitly excluded source', () async {
      final path = writeWebConfig(source: 'locales/generated/en.json', sourceRoot: 'locales');
      File(path).writeAsStringSync('sourceExclude: [locales/generated]\n', mode: FileMode.append);
      expect(Process.runSync('ln', [p.join(dir.path, 'locales/generated/en.json'),
          p.join(dir.path, 'locales/en.json')]).exitCode, 0);
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'catalog_scope_unknown')));
      expect(client.calls, isEmpty);
    });

    test('source must physically belong to the declared input root', () async {
      final path = writeWebConfig(sourceRoot: null, source: 'source.json', files: ['locales/en.json']);
      File(path).writeAsStringSync('sourceRoot: locales\n', mode: FileMode.append);
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'catalog_scope_unknown')));
      expect(client.calls, isEmpty);
    });

    test('a source alias inside the root cannot admit a physical source outside it', () async {
      final path = writeWebConfig(source: 'shared/en.json', sourceRoot: 'inputs');
      Directory(p.join(dir.path, 'inputs')).createSync();
      Link(p.join(dir.path, 'inputs/en.json')).createSync(p.join(dir.path, 'shared/en.json'));
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'catalog_scope_unknown')));
      expect(client.calls, isEmpty);
    });

    for (final root in ["''", 'missing']) {
      test('invalid declared input root $root refuses before upload', () async {
        final path = writeWebConfig(sourceRoot: null);
        File(path).writeAsStringSync('sourceRoot: $root\n', mode: FileMode.append);
        final client = _Client();
        addTearDown(client.close);
        await expectLater(webPreview(path, client), throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'catalog_scope_unknown')));
        expect(client.calls, isEmpty);
      });
    }

    for (final exclusion in ['missing', 'public/i18n/es.json']) {
      test('sourceExclude must name an existing directory: $exclusion', () async {
        final path = writeWebConfig(files: ['public/i18n/es.json']);
        File(path).writeAsStringSync('sourceExclude: [$exclusion]\n', mode: FileMode.append);
        final client = _Client();
        addTearDown(client.close);
        await expectLater(webPreview(path, client), throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'catalog_scope_unknown')));
        expect(client.calls, isEmpty);
      });
    }

    test('locale-files source must have a base-language name in the inventory', () async {
      final path = writeWebConfig(source: 'public/i18n/app.json', files: ['public/i18n/en.json']);
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'catalog_scope_unknown')));
      expect(client.calls, isEmpty);
    });

    for (final layout in ['locale-files', 'base-tree']) {
      test('$layout refuses an unresolved input link', () async {
        final path = writeWebConfig(sourceLayout: layout);
        Link(p.join(dir.path, 'public/i18n/missing.json')).createSync('absent.json');
        final client = _Client();
        addTearDown(client.close);
        await expectLater(webPreview(path, client), throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'catalog_scope_unknown')));
        expect(client.calls, isEmpty);
      });
    }

    test('input root and generated exclusions follow directory aliases', () async {
      final path = writeWebConfig(sourceRoot: null, source: 'catalogs/en.json',
          files: ['catalogs/generated/en.json']);
      Link(p.join(dir.path, 'inputs')).createSync(p.join(dir.path, 'catalogs'));
      Link(p.join(dir.path, 'generated')).createSync(p.join(dir.path, 'catalogs/generated'));
      Directory(p.join(dir.path, 'catalogs/copy')).createSync();
      Link(p.join(dir.path, 'catalogs/copy/en.json'))
          .createSync(p.join(dir.path, 'catalogs/generated/en.json'));
      File(path).writeAsStringSync('sourceRoot: inputs\nsourceExclude: [generated]\n',
          mode: FileMode.append);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    test('excluded generated directories are never read', () async {
      final path = writeWebConfig(source: 'locales/en.json',
          files: ['locales/generated/en.json']);
      File(path).writeAsStringSync('sourceExclude: [locales/generated]\n', mode: FileMode.append);
      final generated = Directory(p.join(dir.path, 'locales/generated'));
      final listed = <String>{};
      await IOOverrides.runZoned(() => checkedScan(path),
          createDirectory: (path) => p.equals(p.normalize(path), p.normalize(generated.path))
              ? generated : _WalkDirectory(dir, () => 1, listed: listed));
      expect(listed, isNot(contains(generated.resolveSymbolicLinksSync())));
    });

    test('an input root alias preserves its physical locale directory', () async {
      final path = writeWebConfig(source: 'catalogs/en/common.json', sourceRoot: null, sourceLayout: 'base-tree',
          files: ['catalogs/en/other.json']);
      Link(p.join(dir.path, 'inputs')).createSync(p.join(dir.path, 'catalogs/en'));
      File(path).writeAsStringSync('sourceRoot: inputs\n', mode: FileMode.append);
      await expectLater(checkedScan(path),
          refusesNaming('catalogs/en/common.json', ['catalogs/en/other.json']));
    });

    for (final layout in ['physical ancestor', 'logical ancestor', 'hidden source']) {
      test('input boundary preserves locale context: $layout', () async {
        final physical = layout == 'logical ancestor' ? 'catalogs/group' :
            layout == 'hidden source' ? '.catalogs/en/group' : 'catalogs/en/group';
        final path = writeWebConfig(source: '$physical/common.json', sourceRoot: layout == 'hidden source' ? physical : null, sourceLayout: 'base-tree',
            files: ['$physical/other.json']);
        if (layout == 'logical ancestor') {
          Link(p.join(dir.path, 'en')).createSync(p.join(dir.path, 'catalogs'));
          File(path).writeAsStringSync('sourceRoot: en/group\n', mode: FileMode.append);
        } else if (layout == 'physical ancestor') {
          Link(p.join(dir.path, 'inputs')).createSync(p.join(dir.path, physical));
          File(path).writeAsStringSync('sourceRoot: inputs\n', mode: FileMode.append);
        }
        final client = _Client();
        addTearDown(client.close);
        await expectLater(webPreview(path, client),
            refusesNaming('$physical/common.json', ['$physical/other.json']));
        expect(client.calls, isEmpty, reason: 'no catalog POST');
      });
    }

    for (final kind in ['directory ancestor', 'file name', 'file ancestor',
      'file extension', 'logical file name', 'physical namespace through file alias']) {
      test('input aliases retain catalog context: $kind', () async {
        final physical = switch (kind) {
          'directory ancestor' || 'file ancestor' => 'external/en/group/common.json',
          'logical file name' => 'external/base.json',
          'physical namespace through file alias' => 'shared/common.json',
          _ => 'external/en.json',
        };
        final path = writeWebConfig(sourceRoot: null, sourceLayout: ['directory ancestor', 'file ancestor', 'physical namespace through file alias'].contains(kind) ? 'base-tree' : 'locale-files', source: 'catalogs/en.json', files: [physical]);
        File(path).writeAsStringSync('sourceRoot: catalogs\n', mode: FileMode.append);
        if (kind == 'directory ancestor') {
          Link(p.join(dir.path, 'catalogs/scope'))
              .createSync(p.join(dir.path, p.dirname(physical)));
        } else if (kind == 'physical namespace through file alias') {
          Directory(p.join(dir.path, 'external/en/group')).createSync(recursive: true);
          Link(p.join(dir.path, 'external/en/group/common.json'))
              .createSync(p.join(dir.path, physical));
          Link(p.join(dir.path, 'catalogs/scope'))
              .createSync(p.join(dir.path, 'external/en/group'));
        } else {
          final alias = kind == 'logical file name' ? 'catalogs/scope/en.json' :
              kind == 'file extension' ? 'catalogs/copy.tmp' : 'catalogs/copy.json';
          Directory(p.join(dir.path, p.dirname(alias))).createSync(recursive: true);
          Link(p.join(dir.path, alias)).createSync(p.join(dir.path, physical));
        }
        final client = _Client();
        addTearDown(client.close);
        await expectLater(webPreview(path, client),
            refusesNaming('catalogs/en.json', [physical]));
        expect(client.calls, isEmpty, reason: 'no catalog POST');
      });
    }

    test('logical namespace aliases retain context in nested physical directories', () async {
      final path = writeWebConfig(sourceRoot: null, sourceLayout: 'base-tree', source: 'catalogs/en.json',
          files: ['shared/group/common.json']);
      Link(p.join(dir.path, 'catalogs/en')).createSync(p.join(dir.path, 'shared'));
      File(path).writeAsStringSync('sourceRoot: catalogs\n', mode: FileMode.append);
      await expectLater(checkedScan(path),
          refusesNaming('catalogs/en.json', ['shared/group/common.json']));
    });

    test('catalog filename extensions are case folded', () async {
      final path = writeWebConfig(source: 'catalogs/en.json',
          files: ['catalogs/admin/en.JSON']);
      await expectLater(checkedScan(path),
          refusesNaming('catalogs/en.json', ['catalogs/admin/en.JSON']));
    });

    test('a YAML inside the base tree preserves its declaration', () async {
      writeWebConfig(source: 'en/common.json', sourceRoot: 'en', sourceLayout: 'base-tree', files: ['en/other.json']);
      final path = p.join(dir.path, 'en/easyi18n.yaml');
      File(path).writeAsStringSync('projectId: p1\nformat: json\nsource: common.json\nsourceRoot: .\nsourceLayout: base-tree\n');
      await expectLater(checkedScan(path), refusesNaming('common.json', ['other.json']));
    });

    test('hardlinks preserve source identity and deduplicate other catalogs', () async {
      final path = writeWebConfig(source: 'locales/en.json');
      Directory(p.join(dir.path, 'locales/a')).createSync();
      expect(Process.runSync('ln', [p.join(dir.path, 'locales/en.json'),
          p.join(dir.path, 'locales/a/en.json')]).exitCode, 0);
      expect((await checkedScan(path)).perLocale, isTrue);
      File(p.join(dir.path, 'locales/a/en.json')).deleteSync();
      File(p.join(dir.path, 'locales/a/en.json')).writeAsStringSync('{}');
      Directory(p.join(dir.path, 'locales/b')).createSync();
      expect(Process.runSync('ln', [p.join(dir.path, 'locales/a/en.json'),
          p.join(dir.path, 'locales/b/en.json')]).exitCode, 0);
      await expectLater(checkedScan(path), throwsA(isA<CliException>()
          .having((e) => e.details['files'], 'files', hasLength(1))));
    });

    for (final hardLink in [false, true]) {
      for (final reverse in [false, true]) {
        test('locale roles precede identity dedup: hardLink=$hardLink reverse=$reverse', () async {
          final path = writeWebConfig(source: 'locales/app.json', sourceRoot: 'locales');
          final source = p.join(dir.path, 'locales/app.json');
          final alias = p.join(dir.path, 'locales/en.json');
          if (hardLink) {
            expect(Process.runSync('ln', [source, alias]).exitCode, 0);
          } else {
            Link(alias).createSync(source);
          }
          final folder = Directory(p.join(dir.path, 'locales'));
          final project = dir;
          await IOOverrides.runZoned(() async {
            expect((await checkedScan(path)).path, source);
          }, createDirectory: (value) => _WalkDirectory(
              p.equals(p.normalize(value), p.normalize(dir.path)) ? project : folder,
              () => 1, compare: (a, b) => reverse ? b.path.compareTo(a.path) : a.path.compareTo(b.path)));
        });
      }
    }

    test('an unreadable input directory cannot yield a partial catalog', () async {
      final path = writeWebConfig(sourceRoot: 'public/i18n');
      final folder = Directory(p.join(dir.path, 'public/i18n'));
      final project = dir;
      final client = _Client();
      addTearDown(client.close);
      await expectLater(IOOverrides.runZoned(() => webPreview(path, client),
          createDirectory: (value) => _WalkDirectory(
              p.equals(p.normalize(value), p.normalize(dir.path)) ? project : folder,
              () => throw FileSystemException('permission denied', folder.path))),
          throwsA(isA<CliException>().having((e) => e.code, 'code', 'catalog_scope_unknown')));
      expect(client.calls, isEmpty);
    });

    test('a hidden source directory under the declared root is inventoried', () async {
      final path = writeWebConfig(source: 'locales/.input/en.json', sourceRoot: 'locales');
      expect((await checkedScan(path)).path, p.join(dir.path, 'locales/.input/en.json'));
      File(p.join(dir.path, 'locales/.input/admin/en.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      await expectLater(checkedScan(path),
          refusesNaming('locales/.input/en.json', ['locales/.input/admin/en.json']));
    });

    test('scan marks the project per-locale, and a catalog project not', () {
      final web = writeWebConfig(files: ['public/i18n/es.json']);
      expect(runner.scan(load(web), configPath: web).perLocale, isTrue);
      final xcode = writeConfig();
      writeCatalog();
      expect(runner.scan(load(xcode), configPath: xcode).perLocale, isFalse);
    });

    // One fixture per shape: each is a layout #2093 merges into one upload.
    test('refuses a Transloco scope beside the base file, by name', () async {
      final path = writeWebConfig(files: [
        'public/i18n/es.json',
        'public/i18n/admin/en.json',
        'public/i18n/admin/es.json',
      ]);
      expect(
        () => checkedScan(path),
        refusesNaming('public/i18n/en.json', ['public/i18n/admin/en.json']),
      );
    });

    test('refuses i18next namespaces beside the base file, by name', () async {
      final path = writeWebConfig(sourceLayout: 'base-tree', source: 'locales/en.json', output: 'locales',
          files: ['locales/en/translation.json', 'locales/en/common.json']);
      expect(
        () => checkedScan(path),
        refusesNaming('locales/en.json',
            ['locales/en/common.json', 'locales/en/translation.json']),
      );
    });

    test('refuses a base file that is one namespace of its directory', () async {
      final path = writeWebConfig(source: 'locales/en/common.json', sourceRoot: 'locales/en', sourceLayout: 'base-tree',
          output: 'locales', files: ['locales/en/translation.json']);
      expect(
        () => checkedScan(path),
        refusesNaming(
            'locales/en/common.json', ['locales/en/translation.json']),
      );
    });

    test('refuses sibling scopes when source names a scoped base file', () async {
      final path = writeWebConfig(source: 'public/i18n/admin/en.json',
          files: ['public/i18n/shop/en.json']);
      expect(
        () => checkedScan(path),
        refusesNaming('public/i18n/admin/en.json', ['public/i18n/shop/en.json']),
      );
    });

    test('refuses sibling scopes for a regional base locale', () async {
      final path = writeWebConfig(source: 'public/i18n/admin/pt-BR.json',
          files: ['public/i18n/shop/pt-BR.json']);
      expect(
        () => checkedScan(path, baseCode: 'pt-BR'),
        refusesNaming(
            'public/i18n/admin/pt-BR.json', ['public/i18n/shop/pt-BR.json']),
      );
    });

    test('refuses nested scopes beside the base file', () async {
      final path = writeWebConfig(files: ['public/i18n/admin/users/en.json']);
      expect(
        () => checkedScan(path),
        refusesNaming('public/i18n/en.json', ['public/i18n/admin/users/en.json']),
      );
    });

    test('refuses namespaces nested below the base language directory', () async {
      final path = writeWebConfig(sourceLayout: 'base-tree', source: 'locales/en.json', output: 'locales',
          files: ['locales/en/group/common.json']);
      expect(
        () => checkedScan(path),
        refusesNaming('locales/en.json', ['locales/en/group/common.json']),
      );
    });

    test('another locale of one namespace is not a sibling scope', () async {
      final path = writeWebConfig(source: 'locales/en/common.json', sourceRoot: 'locales/en', sourceLayout: 'base-tree',
          output: 'locales', files: ['locales/es/common.json']);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    for (final (source, other, layout, root) in [
      ('locales/en/common.json', 'locales/en/group/other.json', 'base-tree', 'locales/en'),
      ('locales/en/group/common.json', 'locales/en/translation.json', 'base-tree', 'locales/en'),
      ('locales/EN.json', 'locales/admin/en.json', 'locale-files', 'locales'),
      ('locales/en/app.json', 'locales/en/group/other.json', 'base-tree', 'locales/en'),
    ]) {
      test('catalog scope includes $other from $source', () async {
        final path = writeWebConfig(source: source, sourceRoot: root, sourceLayout: layout, output: 'locales',
            files: [other]);
        final client = _Client();
        addTearDown(client.close);
        await expectLater(webPreview(path, client), refusesNaming(source, [other]));
        expect(client.calls, isEmpty);
      });
    }

    test('a locale directory owns short namespace names', () async {
      final path = writeWebConfig(source: 'locales/en/app.json', sourceRoot: 'locales/en', sourceLayout: 'base-tree',
          output: 'locales', files: ['locales/es/app.json']);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    test('catalog scope resolves an output directory alias', () async {
      final path = writeWebConfig(source: 'catalogs/en/group/common.json', sourceRoot: 'catalogs/en', sourceLayout: 'base-tree',
          output: 'locales', files: ['catalogs/en/translation.json']);
      Link(p.join(dir.path, 'locales')).createSync(p.join(dir.path, 'catalogs'));
      expect(() => checkedScan(path),
          refusesNaming('catalogs/en/group/common.json', ['catalogs/en/translation.json']));
    });

    test('non-JSON siblings and descendants are not catalogs (S13)', () async {
      final path = writeWebConfig(source: 'locales/en/common.json', sourceRoot: 'locales/en', sourceLayout: 'base-tree',
          output: 'locales', files: ['locales/en/README.txt',
            'locales/en/group/README.txt']);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    test('two links to one physical scope report it only once', () async {
      final path = writeWebConfig();
      final shared = Directory(p.join(dir.path, 'shared'))..createSync();
      File(p.join(shared.path, 'en.json')).writeAsStringSync('{}');
      for (final alias in ['a', 'b']) {
        Link(p.join(dir.path, 'public/i18n', alias)).createSync(shared.path);
      }
      expect(
        () => checkedScan(path),
        throwsA(isA<CliException>()
            .having((e) => e.code, 'code', 'several_files_per_locale')
            .having((e) => e.details['files'], 'files', hasLength(1))),
      );
    });

    Future<SyncScan> scanInOrder(String path, List<String> aliases) {
      final config = load(path);
      final root = Directory(p.join(dir.path, config.output));
      return IOOverrides.runZoned(
        () => checkedScan(path),
        createDirectory: (path) => _WalkDirectory(
            p.equals(p.normalize(path), p.normalize(dir.path)) ? dir : root, () => 1,
            compare: (a, b) => aliases.indexOf(p.basename(a.path))
                .compareTo(aliases.indexOf(p.basename(b.path)))),
      );
    }

    for (final aliases in [
      ['a', 'en'], ['en', 'a'], ['en', 'z'], ['z', 'en'],
    ]) {
      test('directory alias order preserves base-tree inputs for $aliases', () async {
        final path = writeWebConfig(sourceLayout: 'base-tree', source: 'locales/en.json', output: 'locales');
        final shared = Directory(p.join(dir.path, 'shared'))..createSync();
        File(p.join(shared.path, 'common.json')).writeAsStringSync('{}');
        for (final alias in aliases) {
          Link(p.join(dir.path, 'locales', alias)).createSync(shared.path);
        }
        expect(() => scanInOrder(path, aliases),
            refusesNaming('locales/en.json', ['shared/common.json']));
      });
    }

    test('an alias visited before the source directory keeps sibling context', () async {
      final path = writeWebConfig(sourceLayout: 'base-tree', source: 'locales/fr/en.json', output: 'locales',
          files: ['locales/fr/common.json']);
      Link(p.join(dir.path, 'locales/a'))
          .createSync(p.join(dir.path, 'locales/fr'));
      final client = _Client(baseCode: 'fr');
      addTearDown(client.close);
      final root = Directory(p.join(dir.path, 'locales'));
      await expectLater(IOOverrides.runZoned(() => webPreview(path, client),
          createDirectory: (path) => _WalkDirectory(
            p.equals(p.normalize(path), p.normalize(dir.path)) ? dir : root, () => 1,
              compare: (a, b) => ['a', 'fr'].indexOf(p.basename(a.path))
                  .compareTo(['a', 'fr'].indexOf(p.basename(b.path))))),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'several_files_per_locale')
              .having((e) => e.details['files'], 'files', hasLength(1))
              .having((e) => File(p.join(dir.path,
                  (e.details['files'] as List).single as String))
                  .resolveSymbolicLinksSync(), 'physical file',
                  File(p.join(dir.path, 'locales/fr/common.json'))
                      .resolveSymbolicLinksSync())));
    });

    test('physical files selected in two contexts are reported once', () async {
      final path = writeWebConfig(sourceLayout: 'base-tree', source: 'locales/en.json', output: 'locales');
      final shared = Directory(p.join(dir.path, 'shared'))..createSync();
      File(p.join(shared.path, 'en.json')).writeAsStringSync('{}');
      File(p.join(shared.path, 'common.json')).writeAsStringSync('{}');
      for (final alias in ['a', 'en']) {
        Link(p.join(dir.path, 'locales', alias)).createSync(shared.path);
      }
      expect(() => checkedScan(path),
          throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'several_files_per_locale')
              .having((e) => (e.details['files'] as List).map((f) =>
                  File(p.join(dir.path, f as String)).resolveSymbolicLinksSync())
                  .toList(), 'physical files', unorderedEquals([
                    File(p.join(shared.path, 'en.json')).resolveSymbolicLinksSync(),
                    File(p.join(shared.path, 'common.json')).resolveSymbolicLinksSync(),
                  ]))));
    });

    test('file aliases of the source are not additional catalogs', () async {
      final path = writeWebConfig(source: 'locales/en.json', output: 'locales');
      Directory(p.join(dir.path, 'locales/admin')).createSync();
      Link(p.join(dir.path, 'locales/admin/en.json'))
          .createSync(p.join(dir.path, 'locales/en.json'));
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    test('directory cycles terminate without treating source as another file', () async {
      final path = writeWebConfig(source: 'locales/en.json', output: 'locales');
      Link(p.join(dir.path, 'locales/loop')).createSync(p.join(dir.path, 'locales'));
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    test('cycles list each physical directory at most once', () async {
      final path = writeWebConfig(source: 'locales/en.json', output: 'locales');
      final root = Directory(p.join(dir.path, 'locales'));
      Link(p.join(root.path, 'loop')).createSync(root.path);
      var listings = 0;
      await IOOverrides.runZoned(() async {
        expect((await checkedScan(path)).perLocale, isTrue);
      }, createDirectory: (path) => _WalkDirectory(root, () => ++listings));
      expect(listings, 1, reason: 'same physical directory');
    });

    test('a directory cycle cannot hide a second base-tree input', () async {
      final path = writeWebConfig(sourceLayout: 'base-tree', source: 'locales/en.json', output: 'locales',
          files: ['locales/common.json']);
      Link(p.join(dir.path, 'locales/en')).createSync(p.join(dir.path, 'locales'));
      expect(() => checkedScan(path),
          refusesNaming('locales/en.json', ['locales/common.json']));
    });

    test('a flat project is not refused: the files beside the base file in '
        'output: are the other locales', () async {
      final path = writeWebConfig(
          files: ['public/i18n/es.json', 'public/i18n/pt-BR.json']);
      expect((await checkedScan(path)).path,
          p.join(dir.path, 'public', 'i18n', 'en.json'));
    });

    test('JSON beside a base file that lives outside output: is not another '
        'file of its language', () async {
      final path = writeWebConfig(source: 'src/en.json', output: 'public/i18n',
          files: ['src/manifest.json', 'src/tsconfig.json']);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    // A pull writes `<output>/en.json` when the base file lives elsewhere.
    test('output: nested under the base file is not read as a scope', () async {
      final path = writeWebConfig(source: 'i18n/en.json', output: 'i18n/dist',
          files: ['i18n/dist/en.json', 'i18n/dist/es.json']);
      File(path).writeAsStringSync('sourceExclude: [i18n/dist]\n', mode: FileMode.append);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    // A tool's cache beside the base file is not a scope of the app.
    test('a dot-directory beside the base file is not read as a scope', () async {
      final path = writeWebConfig(
          files: ['public/i18n/es.json', 'public/i18n/.cache/en.json']);
      expect((await checkedScan(path)).perLocale, isTrue);
    });

    test('a catalog project is never scanned for other files', () async {
      final path = writeConfig();
      writeCatalog();
      File(p.join(dir.path, 'App', 'Other', 'Localizable.xcstrings'))
          .createSync(recursive: true);
      expect((await checkedScan(path)).perLocale, isFalse);
    });

    for (final (source, other, base, layout) in [
      ('locales/app/en.json', 'locales/admin/en.json', 'en', 'locale-files'),
      ('locales/en/app.json', 'locales/en/other.json', 'en', 'base-tree'),
      ('locales/api/app/en.json', 'locales/admin/en.json', 'en', 'locale-files'),
      ('locales/app/PT-br.json', 'locales/admin/pt_BR.json', 'pt-BR', 'locale-files'),
    ]) {
      test('project language resolves ambiguous scope $source', () async {
        final path = writeWebConfig(source: source, sourceLayout: layout, output: 'locales', files: [other]);
        final client = _Client(baseCode: base);
        addTearDown(client.close);
        await expectLater(webPreview(path, client), refusesNaming(source, [other]));
        expect(client.calls, isEmpty, reason: 'refuse before any catalog POST');
      });
    }

    test('project language preserves one short namespace across locales', () async {
      final path = writeWebConfig(source: 'locales/en/app.json', sourceRoot: 'locales/en', sourceLayout: 'base-tree', output: 'locales',
          files: ['locales/es/app.json']);
      final client = _Client();
      addTearDown(client.close);
      await webPreview(path, client);
      expect(client.metaProjects, ['p1']);
      expect(client.calls.single.dryRun, isTrue);
    });

    test('project language resolves an ambiguous physical output alias', () async {
      final path = writeWebConfig(source: 'catalogs/app/en.json', output: 'locales',
          files: ['catalogs/admin/en.json']);
      Link(p.join(dir.path, 'locales')).createSync(p.join(dir.path, 'catalogs'));
      final client = _Client();
      addTearDown(client.close);
      await expectLater(webPreview(path, client),
          refusesNaming('catalogs/app/en.json', ['catalogs/admin/en.json']));
      expect(client.calls, isEmpty);
    });

    test('unavailable metadata never authorizes an ambiguous upload', () async {
      final path = writeWebConfig(source: 'locales/app/en.json', output: 'locales');
      final client = _Client(metaError: const SocketException('offline'));
      addTearDown(client.close);
      await expectLater(webPreview(path, client), throwsA(isA<SocketException>()));
      expect(client.calls, isEmpty);
    });

    for (final base in ['', '  ']) {
      for (final layout in ['locale-files', 'base-tree']) {
        test('unknown project language refuses ambiguous scope [$base] ($layout)', () async {
          final path = writeWebConfig(source: 'locales/app/en.json', output: 'locales', sourceLayout: layout);
          final client = _Client(baseCode: base);
          addTearDown(client.close);
          await expectLater(webPreview(path, client), throwsA(isA<CliException>()
              .having((e) => e.code, 'code', 'catalog_scope_unknown')));
          expect(client.calls, isEmpty);
        });
      }
    }

    // A target-only pull stamps the snapshot too, so the stamp says nothing
    // about the base file (#2084, fact 2).
    test('sends no pulledAt although a pull of this tree is on record',
        () async {
      final path = writeWebConfig(files: ['public/i18n/es.json']);
      CliState(
        format: 'json',
        output: 'public/i18n',
        files: const ['es.json'],
        pulledAt: DateTime.utc(2026, 10, 9),
        snapshotAt: DateTime.utc(2026, 10, 8),
      ).save(CliState.fileFor(path));
      final client = _Client();
      addTearDown(client.close);
      final preview = await runner.preview(
        client, 'p1', runner.scan(load(path), configPath: path),
        config: load(path), configPath: path, onConflict: 'server',
      );
      expect(preview.pulledAt, isNull);
      expect(client.calls.single.pulledAt, isNull);
      expect(client.metaProjects, ['p1']);
    });
  });

  group('preview', () {
    late String configPath;
    late File catalog;

    setUp(() {
      configPath = writeConfig();
      catalog = writeCatalog('{"sourceLanguage":"es","version":"1.0"}');
    });

    Future<SyncPreview> preview(_Client client) => runner.preview(
          client,
          'p1',
          runner.scan(load(configPath), configPath: configPath),
          config: load(configPath),
          configPath: configPath,
          onConflict: 'file',
        );

    test('always dry-runs, sending the file bytes under its base name', () async {
      final client = _Client();
      addTearDown(client.close);
      final result = await preview(client);
      expect(client.calls, hasLength(1));
      final call = client.calls.single;
      expect(call.dryRun, isTrue);
      expect(call.projectId, 'p1');
      expect(call.fileName, 'Localizable.xcstrings');
      expect(call.format, 'xcstrings');
      expect(call.onConflict, 'file');
      expect(call.bytes, catalog.readAsBytesSync());
      // The bytes the preview priced are the ones a real POST re-sends.
      expect(result.bytes, call.bytes);
      expect(result.result.dryRun, isTrue);
      expect(result.scan.path, p.normalize(catalog.path));
    });

    test('prefers snapshotAt over pulledAt as the claim (#898)', () async {
      final client = _Client();
      addTearDown(client.close);
      CliState(
        catalog: 'App/Localizable.xcstrings',
        format: 'xcstrings',
        pulledAt: DateTime.utc(2026, 9, 8),
        snapshotAt: DateTime.utc(2026, 8, 20),
      ).save(CliState.fileFor(configPath));
      final result = await preview(client);
      expect(result.pulledAt, DateTime.utc(2026, 8, 20));
      expect(client.calls.single.pulledAt, DateTime.utc(2026, 8, 20));
    });

    test('falls back to pulledAt for state an older CLI wrote', () async {
      final client = _Client();
      addTearDown(client.close);
      CliState(
        catalog: 'App/Localizable.xcstrings',
        format: 'xcstrings',
        pulledAt: DateTime.utc(2026, 9, 8),
      ).save(CliState.fileFor(configPath));
      expect((await preview(client)).pulledAt, DateTime.utc(2026, 9, 8));
    });

    // Each disagreement on its own: the state describes ANOTHER file, so its
    // stamp would date this catalog by that one's pull (#671).
    for (final (name, state) in [
      ('a catalog switch', CliState(
        catalog: 'Other/Localizable.xcstrings',
        format: 'xcstrings',
        snapshotAt: DateTime.utc(2026, 8, 20),
      )),
      ('a format switch', CliState(
        catalog: 'App/Localizable.xcstrings',
        format: 'arb',
        snapshotAt: DateTime.utc(2026, 8, 20),
      )),
      ('state from a plain pull', CliState(
        format: 'xcstrings',
        snapshotAt: DateTime.utc(2026, 8, 20),
      )),
    ]) {
      test('claims nothing after $name', () async {
        final client = _Client();
        addTearDown(client.close);
        state.save(CliState.fileFor(configPath));
        expect((await preview(client)).pulledAt, isNull);
        expect(client.calls.single.pulledAt, isNull);
      });
    }

    test('claims nothing when no pull was ever recorded', () async {
      final client = _Client();
      addTearDown(client.close);
      expect((await preview(client)).pulledAt, isNull);
    });

    // Two nulls are not a match. `scan` refuses a config with no `catalog:`,
    // so this shape can only be reached by handing `preview` a scan of its
    // own — which is exactly what the third conjunct is there for: without
    // it, state written by a plain `pull` (which records no catalog) would
    // date a catalog it never described.
    test('a null catalog on both sides is not a match', () async {
      final client = _Client();
      addTearDown(client.close);
      final bare = p.join(dir.path, 'bare.yaml');
      File(bare).writeAsStringSync('projectId: p1\nformat: xcstrings\n');
      CliState(
        format: 'xcstrings',
        snapshotAt: DateTime.utc(2026, 8, 20),
      ).save(CliState.fileFor(bare));
      final result = await runner.preview(
        client,
        'p1',
        SyncScan(file: catalog, path: p.normalize(catalog.path)),
        config: load(bare),
        configPath: bare,
        onConflict: 'server',
      );
      expect(result.pulledAt, isNull);
      expect(client.calls.single.pulledAt, isNull);
    });
  });

  group('an android project (#2285)', () {
    late String configPath;

    void writeRes(String dir, String content) =>
        File(p.join(p.dirname(configPath), 'app/src/main/res', dir, 'strings.xml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    setUp(() {
      configPath = p.join(dir.path, 'easyi18n.yaml');
      File(configPath).writeAsStringSync('projectId: p1\nformat: android_xml\n'
          'source: app/src/main/res/values/strings.xml\n'
          'sourceRoot: app/src/main/res/values\noutput: app/src/main/res\n');
      writeRes('values', '<resources><string name="hi">Hi</string></resources>');
      writeRes('values-es', '<resources><string name="hi">Hola</string></resources>');
      writeRes('values-b+zh+Hant', '<resources/>');
      writeRes('values-night', '<resources><string name="hi">Hi</string></resources>');
      writeRes('values-fr', '<resources/>');
    });

    Future<void> wait(Duration d) => Future<void>.delayed(Duration.zero);

    test('the base goes up alone, then each language file with its lang',
        () async {
      final client = _Client(targets: ['es', 'zh-Hant']);
      addTearDown(client.close);
      final config = load(configPath);
      final scan = runner.scan(config, configPath: configPath);
      final preview = await runner.preview(client, 'p1', scan,
          config: config, configPath: configPath, onConflict: 'server');
      expect(preview.skippedTargets, [
        'values-fr/strings.xml (fr is not a target language of the project)',
      ]);
      expect(client.calls.map((c) => (c.fileName, c.dryRun, c.lang)),
          [('strings.xml', true, null)],
          reason: 'the dry run prices the base, the one file that queues a fill');
      await runner.run(client, 'p1', preview, config: config,
          onConflict: 'file', progress: progress, wait: wait,
          random: Random(7), pollTimeout: const Duration(days: 1));
      expect(client.calls.map((c) => (c.fileName, c.dryRun, c.lang)), [
        ('strings.xml', true, null),
        ('strings.xml', false, null),
        ('values-es/strings.xml', false, 'es'),
        ('values-b+zh+Hant/strings.xml', false, 'zh-Hant'),
      ]);
      final es = client.calls[2];
      expect(String.fromCharCodes(es.bytes), contains('Hola'));
      expect(es.format, 'android_xml');
      expect(es.onConflict, 'file');
      expect(progress.events, ['response(-)', 'response(-)', 'response(-)']);
    });

    test('a target file is never posted before the base creates its keys',
        () async {
      final client = _Client(targets: ['es'], responses: () => [
        syncResult(dryRun: true),
        syncResult(failedEntries: [contended('hi', 'peer')]),
        syncResult(),
      ]);
      addTearDown(client.close);
      final config = load(configPath);
      final scan = runner.scan(config, configPath: configPath);
      final preview = await runner.preview(client, 'p1', scan,
          config: config, configPath: configPath, onConflict: 'server');
      await runner.run(client, 'p1', preview, config: config,
          onConflict: 'server', progress: progress, wait: wait,
          random: Random(7), pollTimeout: const Duration(days: 1));
      expect(client.calls.map((c) => c.lang), [null, null, null, 'es']);
    });

    // The real base POST throws [lost]; the dry run asked after it answers
    // [oracle], or throws [oracleError]. Yields what the run threw.
    Future<(Object?, _Client)> loseBase(Object lost,
        {SyncResult? oracle, Object? oracleError, Object? targetError}) async {
      var dryRuns = 0;
      final client = _Client(targets: ['es'], responses: () => [
        syncResult(dryRun: true, created: 1),
        syncResult(),
        oracle ?? syncResult(dryRun: true),
        syncResult(),
      ], fail: (c) => c.lang != null ? targetError
          : !c.dryRun ? lost
          : ++dryRuns == 2 ? oracleError : null);
      addTearDown(client.close);
      final config = load(configPath);
      final scan = runner.scan(config, configPath: configPath);
      final preview = await runner.preview(client, 'p1', scan,
          config: config, configPath: configPath, onConflict: 'server');
      try {
        await runner.run(client, 'p1', preview, config: config,
            onConflict: 'server', progress: progress, wait: wait,
            random: Random(7), pollTimeout: const Duration(days: 1));
      } on Object catch (e) {
        return (e, client);
      }
      return (null, client);
    }

    final unavailable = ApiException('Sync failed: unavailable',
        statusCode: 503, code: 'unavailable');
    final reset = TransientCliException('Could not reach http://localhost');

    // The server applied the base and queued its fill; only the answer was
    // lost. The targets go before that fill's tick, or it writes the cells
    // translated by hand, charges for them, and the next sync's import loses
    // to it (#2319). The run still fails: it has no job to wait for.
    for (final (name, lost) in [('a 503', unavailable), ('a reset', reset)]) {
      test('a base answer lost to $name after the server applied it still '
          'uploads the targets', () async {
        final (thrown, client) = await loseBase(lost);
        expect(thrown, same(lost));
        expect(client.calls.map((c) => (c.dryRun, c.lang)), [
          (true, null), (false, null), (true, null), (false, 'es'),
        ]);
        expect(progress.events, ['response(-)']);
      });
    }

    test('a refused target after a lost base keeps the base error', () async {
      final targetError = ApiException('Sync failed: invalid target',
          statusCode: 400, code: 'invalid_argument');
      final (thrown, client) = await loseBase(unavailable,
          targetError: targetError);
      expect(thrown, same(unavailable));
      expect(client.calls.map((c) => (c.dryRun, c.lang)), [
        (true, null), (false, null), (true, null), (false, 'es'),
      ]);
    });

    test('a base that never reached the server uploads no target', () async {
      final (thrown, client) = await loseBase(reset,
          oracle: syncResult(dryRun: true, created: 1));
      expect(thrown, same(reset));
      expect(client.calls.map((c) => (c.dryRun, c.lang)),
          [(true, null), (false, null), (true, null)]);
    });

    // A target imported against the old source turns stale once the base
    // lands, and its re-upload is unchanged: the fill would overwrite it.
    test('a lost base whose sources the project does not hold yet uploads '
        'no target', () async {
      final (thrown, client) = await loseBase(unavailable,
          oracle: syncResult(dryRun: true, updatedSources: 1));
      expect(thrown, same(unavailable));
      expect(client.calls.map((c) => c.lang), [null, null, null]);
    });

    test('a dry run that cannot answer either uploads no target and keeps '
        "the base's error", () async {
      final (thrown, client) = await loseBase(unavailable, oracleError: reset);
      expect(thrown, same(unavailable));
      expect(client.calls.map((c) => c.lang), [null, null, null]);
    });

    test('a refused base uploads no target and asks nothing more', () async {
      final refused = ApiException('Sync failed: bad file',
          statusCode: 400, code: 'invalid_argument');
      final (thrown, client) = await loseBase(refused);
      expect(thrown, same(refused));
      expect(client.calls.map((c) => (c.dryRun, c.lang)),
          [(true, null), (false, null)]);
    });
  });

  group('run', () {
    late String configPath;

    setUp(() {
      configPath = writeConfig();
      writeCatalog();
    });

    // A fake that yields to the event loop. A `wait` resolving by microtask
    // starves the timer queue, so a termination regression hangs the suite
    // instead of going red (#1600).
    Future<void> wait(Duration d) async {
      waited.add(d);
      await Future<void>.delayed(Duration.zero);
    }

    Future<SyncOutcome> run(
      _Client client, {
      Duration pollTimeout = const Duration(days: 1),
    }) async {
      final scan = runner.scan(load(configPath), configPath: configPath);
      final preview = await runner.preview(
        client, 'p1', scan,
        config: load(configPath), configPath: configPath,
        onConflict: 'server',
      );
      return runner.run(
        client, 'p1', preview,
        config: load(configPath),
        onConflict: 'server',
        progress: progress,
        wait: wait,
        random: Random(7),
        pollTimeout: pollTimeout,
      );
    }

    test('a clean run posts once and settles with nothing outstanding',
        () async {
      final client = _Client(responses: () => [syncResult(dryRun: true)]);
      addTearDown(client.close);
      final outcome = await run(client);
      // The preview is the first call and is NOT reported through progress.
      expect(client.calls.map((c) => c.dryRun), [true, false]);
      expect(progress.events, ['response(-)']);
      expect(outcome.stillIncomplete, isFalse);
      expect(outcome.stoppedShort, isNull);
      expect(outcome.drainedOwnJobs, isFalse);
      expect(client.polled, isEmpty);
    });

    // Only a catalog with target files has something to send after a lost
    // answer; the dry run that would ask is a retried call in an outage.
    test('a lost answer with no target file asks no second dry run',
        () async {
      final unavailable = ApiException('Sync failed: unavailable',
          statusCode: 503, code: 'unavailable');
      final client = _Client(fail: (c) => c.dryRun ? null : unavailable);
      addTearDown(client.close);
      await expectLater(run(client), throwsA(same(unavailable)));
      expect(client.calls.map((c) => c.dryRun), [true, false]);
    });

    test('the real POSTs re-send the previewed bytes and claim', () async {
      CliState(
        catalog: 'App/Localizable.xcstrings', format: 'xcstrings',
        snapshotAt: DateTime.utc(2026, 8, 20),
      ).save(CliState.fileFor(configPath));
      final client = _Client(responses: () => [syncResult(dryRun: true)]);
      addTearDown(client.close);
      await run(client);
      expect(client.calls.map((c) => c.pulledAt),
          everyElement(DateTime.utc(2026, 8, 20)));
      expect(client.calls.map((c) => c.fileName),
          everyElement('Localizable.xcstrings'));
      expect(client.calls.last.bytes, client.calls.first.bytes);
    });

    test('contended past the retries fails, naming keys and reasons', () async {
      final client = _Client(responses: () => [
            syncResult(dryRun: true),
            syncResult(failedEntries: [
              contended('Hola', 'peer sync'),
              contended('Chau', 'peer sync'),
              contended('Que', 'write throttled'),
            ]),
          ]);
      addTearDown(client.close);
      await expectLater(
        run(client),
        throwsA(isA<CliException>().having((e) => e.message, 'message', allOf(
          contains('3 entries went unwritten after 2 retries'),
          contains('Hola, Chau, Que'),
          contains('Reported as: peer sync; write throttled'),
        ))),
      );
      // Two retries, then the refusal: 1 preview + 3 real POSTs.
      expect(client.calls.where((c) => !c.dryRun), hasLength(3));
      expect(waited, hasLength(2));
    });

    test('a contended row that appears during the fill fails differently',
        () async {
      final client = _Client(
        responses: () => [
          syncResult(dryRun: true),
          syncResult(trackingToken: 'job_a'),
          syncResult(failedEntries: [contended('Hola', 'write throttled')]),
        ],
        summaries: {'job_a': [summary('done', pending: 2, total: 3)]},
      );
      addTearDown(client.close);
      await expectLater(
        run(client),
        throwsA(isA<CliException>().having((e) => e.message, 'message', allOf(
          contains('1 entry went unwritten while waiting for the fill'),
          contains('Hola'),
          contains('write throttled'),
        ))),
      );
      // The refusal must not swallow what the fill left behind: the run
      // throws before any outcome exists, so the only way the operator hears
      // the count is an event emitted first.
      expect(progress.events.last, 'shortfall(2, after 1)');
    });

    test('a job that never goes terminal times out and stays incomplete',
        () async {
      final client = _Client(
        responses: () => [syncResult(dryRun: true), syncResult(trackingToken: 'job_a')],
        summaries: {'job_a': [summary('running', pending: 1)]},
      );
      addTearDown(client.close);
      final outcome = await run(client, pollTimeout: const Duration(days: -1));
      expect(progress.events,
          ['response(job_a)', 'timedOut(abandoned: false)']);
      expect(outcome.stillIncomplete, isTrue);
      expect(progress.events, isNot(contains(startsWith('shortfall'))));
      expect(client.polled, ['job_a']);
    });

    test('a token a re-POST superseded is still drained, and says so',
        () async {
      final client = _Client(
        responses: () => [
          syncResult(dryRun: true),
          syncResult(
            trackingToken: 'job_a',
            failedEntries: [contended('Hola', 'peer sync')],
          ),
          syncResult(),
        ],
        summaries: {'job_a': [summary('running', pending: 1)]},
      );
      addTearDown(client.close);
      final outcome = await run(client, pollTimeout: const Duration(days: -1));
      expect(progress.events, [
        'response(job_a)',
        'contendedRetry(Hola, 1/2, true)',
        'response(-)',
        'timedOut(abandoned: true)',
      ]);
      expect(client.polled, ['job_a']);
      expect(outcome.drainedOwnJobs, isTrue);
      expect(outcome.stillIncomplete, isTrue);
    });

    // A drained job that ended early is `stoppedShort`, exactly like the
    // run's own last job — reading only `coveredEverything` made it silent.
    test('an abandoned job that ended early is reported as stopped short',
        () async {
      final client = _Client(
        responses: () => [
          syncResult(dryRun: true),
          syncResult(
            trackingToken: 'job_a',
            failedEntries: [contended('Hola', 'peer sync')],
          ),
          syncResult(),
        ],
        summaries: {'job_a': [summary('aborted_no_credits', pending: 4)]},
      );
      addTearDown(client.close);
      final outcome = await run(client);
      expect(outcome.stoppedShort?.status, 'aborted_no_credits');
      expect(outcome.stillIncomplete, isFalse);
      expect(progress.events, isNot(contains('timedOut(abandoned: true)')));
    });

    test('an abandoned job that ran but left pairs only marks incomplete',
        () async {
      final client = _Client(
        responses: () => [
          syncResult(dryRun: true),
          syncResult(
            trackingToken: 'job_a',
            failedEntries: [contended('Hola', 'peer sync')],
          ),
          syncResult(),
        ],
        summaries: {'job_a': [summary('done', pending: 1)]},
      );
      addTearDown(client.close);
      final outcome = await run(client);
      expect(outcome.stillIncomplete, isTrue);
      expect(outcome.stoppedShort, isNull);
    });

    test('a covered job ends the loop clean, whatever ended it', () async {
      final client = _Client(
        responses: () => [syncResult(dryRun: true), syncResult(trackingToken: 'job_a')],
        summaries: {'job_a': [summary('cancelled', total: 2, translated: 2)]},
      );
      addTearDown(client.close);
      final outcome = await run(client);
      expect(outcome.stillIncomplete, isFalse);
      expect(outcome.stoppedShort, isNull);
      expect(progress.events, isNot(contains(startsWith('shortfall'))));
    });

    test('a job that stopped short is not retried', () async {
      final client = _Client(
        responses: () => [syncResult(dryRun: true), syncResult(trackingToken: 'job_a')],
        summaries: {'job_a': [summary('cancelled', pending: 3)]},
      );
      addTearDown(client.close);
      final outcome = await run(client);
      expect(outcome.stoppedShort?.status, 'cancelled');
      expect(progress.events, isNot(contains(startsWith('shortfall'))));
      expect(client.calls.where((c) => !c.dryRun), hasLength(1));
    });

    test('an incomplete fill is re-POSTed up to the retry cap', () async {
      final client = _Client(
        responses: () => [
          syncResult(dryRun: true),
          syncResult(trackingToken: 'job_a'),
        ],
        summaries: {'job_a': [summary('done', pending: 2, failed: 1)]},
      );
      addTearDown(client.close);
      final outcome = await run(client);
      expect(progress.events, [
        'response(job_a)',
        'fillRetry(3, 1/2)',
        'response(job_a)',
        'fillRetry(3, 2/2)',
        'response(job_a)',
        'shortfall(3, after 2)',
      ]);
      expect(outcome.stillIncomplete, isTrue);
      expect(client.calls.where((c) => !c.dryRun), hasLength(3));
    });

    // The rows are per-response, not cumulative: a conflict the first POST
    // resolved is simply absent from the re-POST a contended entry forces.
    test('every attempt is kept whole, rows and total together',
        () async {
      const first = {'key': 'Hola', 'lang': 'es', 'resolution': 'overwritten'};
      const both = {'key': 'Chau', 'lang': 'en', 'resolution': 'kept'};
      const late = {'key': 'Que', 'lang': 'fr', 'resolution': 'kept'};
      const diag = {'code': 'PLURAL_BEHIND_PROJECT', 'field': 'Hola'};
      final client = _Client(responses: () => [
            syncResult(dryRun: true),
            syncResult(
              conflicts: [first, both],
              diagnostics: [diag],
              failedEntries: [contended('Hola', 'peer sync')],
            ),
            syncResult(conflicts: [both, late]),
          ]);
      addTearDown(client.close);
      final outcome = await run(client);
      // One entry per real POST, each whole: the rows that attempt reported
      // and the total the server sent with them, never mixed.
      expect(outcome.attempts.map((a) => a.conflicts), [
        [first, both],
        [both, late],
      ]);
      expect(outcome.attempts.map((a) => a.diagnostics), [
        [diag],
        <Map<String, Object?>>[],
      ]);
      // The decisions still read the LAST response, not the attempts.
      expect(outcome.result.conflicts, [both, late]);
    });

    test('the poll throttles on the largest total it has seen (#614)',
        () async {
      final client = _Client(
        responses: () => [syncResult(dryRun: true), syncResult(trackingToken: 'job_a')],
        summaries: {
          'job_a': [
            summary('running', total: 900, pending: 900),
            // The total drops once keys are retired, the per-poll cost does not.
            summary('running', total: 3, pending: 3),
            summary('done', total: 3, translated: 3),
          ],
        },
      );
      addTearDown(client.close);
      await run(client);
      expect(waited, [const Duration(seconds: 10), const Duration(seconds: 10)]);
    });

    test('a small job polls at the short interval', () async {
      final client = _Client(
        responses: () => [syncResult(dryRun: true), syncResult(trackingToken: 'job_a')],
        summaries: {
          'job_a': [summary('running', total: 3, pending: 3),
                    summary('done', total: 3, translated: 3)],
        },
      );
      addTearDown(client.close);
      await run(client);
      expect(waited, [const Duration(seconds: 5)]);
    });
  });


}

class _SyncCall {
  _SyncCall({
    required this.projectId,
    required this.fileName,
    required this.bytes,
    required this.format,
    required this.dryRun,
    required this.onConflict,
    required this.pulledAt,
    this.lang,
  });

  final String projectId;
  final String fileName;
  final List<int> bytes;
  final String? format;
  final bool dryRun;
  final String? onConflict;
  final DateTime? pulledAt;
  final String? lang;
}

class _Client extends TranslationsApiClient {
  _Client({this.responses, this.summaries, this.baseCode = 'en', this.metaError,
      this.targets = const [], this.fail})
      : super(baseUrl: 'http://localhost', token: 'test');

  /// What a POST throws instead of answering, after it is recorded.
  final Object? Function(_SyncCall call)? fail;


  /// One entry per POST, by call index. Past the end the last one repeats, so
  /// a test scripts only the responses that differ.
  final List<SyncResult> Function()? responses;

  /// Job summaries by tracking token, consumed in order per token.
  final Map<String, List<JobSummary>>? summaries;
  final String baseCode;
  final Object? metaError;
  final List<String> targets;
  final metaProjects = <String>[];

  @override
  Future<ProjectMeta> fetchMeta({required String projectId}) async {
    metaProjects.add(projectId);
    if (metaError case final error?) throw error;
    return ProjectMeta(currentVersionId: '', baseCode: baseCode, languages: [
      for (final code in [baseCode, ...targets])
        ProjectLanguage(code: code, name: code, isBase: code == baseCode,
            fillMode: 'ai'),
    ]);
  }

  final polled = <String>[];
  final calls = <_SyncCall>[];

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
    final call = _SyncCall(
      projectId: projectId, fileName: fileName, bytes: bytes, format: format,
      dryRun: dryRun, onConflict: onConflict, pulledAt: pulledAt, lang: lang,
    );
    calls.add(call);
    if (fail?.call(call) case final error?) throw error;
    final scripted = responses?.call() ?? const [];
    if (scripted.isEmpty) return syncResult(dryRun: dryRun);
    final i = calls.length - 1;
    return scripted[i < scripted.length ? i : scripted.length - 1];
  }

  @override
  Future<JobSummary> fetchJobSummary({
    required String projectId,
    required String trackingToken,
  }) async {
    polled.add(trackingToken);
    final queue = summaries![trackingToken]!;
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }
}

SyncResult syncResult({
  bool dryRun = false,
  int created = 0,
  int updatedSources = 0,
  String? trackingToken,
  List<Map<String, Object?>> failedEntries = const [],
  List<Map<String, Object?>> conflicts = const [],
  List<Map<String, Object?>> diagnostics = const [],
}) => SyncResult(
  dryRun: dryRun, created: created, updatedSources: updatedSources,
  matchedSources: 0,
  updatedTranslations: 0, unchangedTranslations: 0, disabledOrphans: 0,
  reenabled: 0, failedEntries: failedEntries, exhausted: const [],
  conflicts: conflicts, conflictsTotal: conflicts.length,
  diagnostics: diagnostics, onConflict: 'server',
  trackingToken: trackingToken, estimatedCredits: 0, balance: 0,
  availableCredits: null, accepted: true, skippedGated: 0, notInCode: 0,
  wouldExceedKeyCap: false,
);

JobSummary summary(String status, {int pending = 0, int failed = 0,
    int total = 1, int translated = 0}) => JobSummary(
  status: status, total: total, translated: translated,
  pending: pending, failed: failed,
);

Map<String, Object?> contended(String key, String reason) =>
    {'code': 'contended', 'key': key, 'reason': reason};

/// Records the run loop's events in the order they were produced.
class _Progress implements SyncRunProgress {
  final events = <String>[];

  @override
  void onResponse(SyncResult result) => events.add(
      'response(${result.trackingToken ?? '-'})');

  @override
  void onContendedRetry({required List<String> keys, required Duration delay,
      required int attempt, required int max}) => events.add(
      'contendedRetry(${keys.join('|')}, $attempt/$max, '
      '${delay.inMilliseconds >= 500})');

  @override
  void onJobTimedOut({required bool abandoned}) =>
      events.add('timedOut(abandoned: $abandoned)');

  @override
  void onFillRetry({required int pairs, required int attempt,
      required int max}) => events.add('fillRetry($pairs, $attempt/$max)');

  @override
  void onShortfall({required int pairs, required int retries}) =>
      events.add('shortfall($pairs, after $retries)');
}

// Bound a broken traversal by returning no entries after ten listings; the
// visit-count assertion catches it without a timeout or filesystem exception.
class _WalkDirectory implements Directory {
  _WalkDirectory(this.directory, this.onList, {this.compare, this.listed});
  final Directory directory;
  final int Function() onList;
  final Comparator<FileSystemEntity>? compare;
  final Set<String>? listed;
  @override
  String get path => directory.path;
  @override
  bool existsSync() => directory.existsSync();
  @override
  String resolveSymbolicLinksSync() => directory.resolveSymbolicLinksSync();
  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) {
    listed?.add(directory.resolveSymbolicLinksSync());
    if (onList() > 10) return [];
    final entries = directory.listSync(recursive: recursive, followLinks: followLinks);
    if (compare != null) entries.sort(compare);
    return entries
        .map((entry) => entry is Directory
            ? _WalkDirectory(entry, onList, compare: compare, listed: listed) : entry)
        .toList();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
