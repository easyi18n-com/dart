import 'dart:io';

import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('easyi18n_cli_config'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String yaml) {
    final f = File('${dir.path}/easyi18n.yaml');
    f.writeAsStringSync(yaml);
    return f;
  }

  for (final layout in ['locale-files', 'base-tree']) {
    test('$layout input boundaries survive YAML serialization and reload', () {
      final out = StringBuffer();
      final err = StringBuffer();
      final file = write('projectId: p\nsource: i18n/en.json\n'
          'sourceRoot: i18n # literal comment\nsourceLayout: $layout\n'
          'sourceExclude: ["i18n/generated #1"]\n');
      final config = Easyi18nConfig.load(file, logger: CliLogger(out: out, err: err));
      file.writeAsStringSync(config.toYaml());
      final reloaded = Easyi18nConfig.load(file);
      expect(reloaded.source, 'i18n/en.json');
      expect(reloaded.sourceRoot, 'i18n');
      expect(reloaded.sourceLayout, layout);
      expect(reloaded.sourceExclude, ['i18n/generated #1']);
      expect(err.toString(), isEmpty);
    });
  }

  test('serialization does not invent a declaration for legacy source configs', () {
    final file = write('projectId: p\nsource: i18n/en.json\n');
    file.writeAsStringSync(Easyi18nConfig.load(file).toYaml());
    final reloaded = Easyi18nConfig.load(file);
    expect(reloaded.sourceRoot, isNull);
    expect(reloaded.sourceLayout, isNull);
  });

  for (final field in ['sourceRoot', 'sourceLayout']) {
    for (final value in ['false', '42', '[locale-files]']) {
      test('non-string $field=$value is an unknown catalog scope', () {
        expect(() => Easyi18nConfig.load(write('projectId: p\n$field: $value\n')),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'catalog_scope_unknown')
                .having((e) => e.message, 'message', contains(field))));
      });
    }
  }

  for (final invalid in ['a-string', '[1]', '[null]', '[""]', '["  "]']) {
    test('invalid sourceExclude $invalid is refused', () {
      expect(() => Easyi18nConfig.load(write('projectId: p\nsourceExclude: $invalid\n')),
          throwsA(isA<CliException>()));
    });
  }

  group('unknown settings', () {
    ({String out, String err}) loadWith(String yaml) {
      final out = StringBuffer();
      final err = StringBuffer();
      Easyi18nConfig.load(
        write(yaml),
        logger: CliLogger(out: out, err: err),
      );
      return (out: out.toString(), err: err.toString());
    }

    test('a typo is reported instead of falling back in silence', () {
      // `ouput:` used to leave the pull writing to lib/l10n and reporting
      // success — the config was wrong in a way nothing could see (#552).
      final logs = loadWith('projectId: p\nouput: EscapeCall\n');
      expect(logs.err, contains('ouput'));
      expect(logs.err, contains('unknown setting'));
      // The known set is listed, so the fix is in the message.
      expect(logs.err, contains('output'));
      expect(logs.err, contains('catalog'));
    });

    test('reports every unknown key, sorted, and only those', () {
      final logs = loadWith('projectId: p\nzeta: 1\nalpha: 2\ncatalog: c\n');
      // The list ends at the period: `catalog` and `projectId` are known, so
      // naming them here would send the reader after the wrong line.
      expect(logs.err, contains('easyi18n.yaml: alpha, zeta.'));
    });

    test('a complete, correct config says nothing', () {
      final logs = loadWith('''
projectId: p
baseUrl: http://localhost:8080
format: xcstrings
output: lib/l10n
mode: a
catalog: EscapeCall/Localizable.xcstrings
''');
      expect(logs.err, isEmpty);
      expect(logs.out, isEmpty);
    });

    test('a key that is not even a string is still named', () {
      // YAML allows non-string keys; the report must not crash on one.
      final logs = loadWith('projectId: p\n1: uno\ntrue: si\n');
      expect(logs.err, contains('1'));
      expect(logs.err, contains('true'));
    });

    test('an unknown key is a warning, never a failure', () {
      // The CI action pins `cli-version`: a config written for a newer CLI
      // must not hard-fail the pinned one.
      final config = Easyi18nConfig.load(write('projectId: p\nfuture: 1\n'));
      expect(config.ref, IdRef('p'));
    });
  });

  group('load', () {
    test('reads all fields', () {
      final config = Easyi18nConfig.load(
        write('''
projectId: proj_abc
baseUrl: http://localhost:8080
format: json
output: lib/i18n
'''),
      );
      expect(config.ref, IdRef('proj_abc'));
      expect(config.baseUrl, 'http://localhost:8080');
      expect(config.format, 'json');
      expect(config.output, 'lib/i18n');
    });

    test('applies defaults for omitted fields', () {
      final config = Easyi18nConfig.load(write('projectId: proj_abc'));
      expect(config.baseUrl, Easyi18nConfig.defaultBaseUrl);
      expect(config.format, Easyi18nConfig.defaultFormat);
      expect(config.output, Easyi18nConfig.defaultOutput);
      // Every config written before the mode field existed reads as Mode B —
      // today's behavior (#415).
      expect(config.mode, 'b');
    });

    test('reads mode a (#415)', () {
      final config =
          Easyi18nConfig.load(write('projectId: proj_abc\nmode: a'));
      expect(config.mode, 'a');
    });

    test('rejects an unknown mode (#415)', () {
      expect(
        () => Easyi18nConfig.load(write('projectId: p\nmode: c')),
        throwsA(isA<CliException>()),
      );
    });

    test('strips trailing slashes from baseUrl', () {
      final config = Easyi18nConfig.load(
        write('projectId: p\nbaseUrl: https://x.com//'),
      );
      expect(config.baseUrl, 'https://x.com');
    });

    test('throws when the file is missing', () {
      expect(
        () => Easyi18nConfig.load(File('${dir.path}/nope.yaml')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws when no project ref is set', () {
      expect(
        () => Easyi18nConfig.load(write('format: arb')),
        throwsA(isA<CliException>()),
      );
    });

    test('reads the @handle/slug ref', () {
      final config = Easyi18nConfig.load(
        write('workspace: acme\nproject: dogfood'),
      );
      expect(config.ref, HandleRef('acme', 'dogfood'));
      expect(config.describeRef, '@acme/dogfood');
    });

    test('strips a leading @ from the workspace handle', () {
      final config = Easyi18nConfig.load(
        write('workspace: "@acme"\nproject: dogfood'),
      );
      expect(config.ref, HandleRef('acme', 'dogfood'));
      expect(config.describeRef, '@acme/dogfood');
      // The written config must be re-loadable (a bare @ is invalid YAML).
      expect(config.toYaml(), contains('workspace: acme'));
    });

    test('projectId form is not a handle ref', () {
      final config = Easyi18nConfig.load(write('projectId: proj_abc'));
      expect(config.ref, IdRef('proj_abc'));
      expect(config.describeRef, 'proj_abc');
    });

    test('rejects projectId combined with workspace/project', () {
      expect(
        () => Easyi18nConfig.load(
          write('projectId: p\nworkspace: acme\nproject: dogfood'),
        ),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects workspace without project', () {
      expect(
        () => Easyi18nConfig.load(write('workspace: acme')),
        throwsA(isA<CliException>()),
      );
    });

    test('rejects project without workspace', () {
      expect(
        () => Easyi18nConfig.load(write('project: dogfood')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws on invalid YAML', () {
      expect(
        () => Easyi18nConfig.load(write('projectId: [unclosed')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws when a field has the wrong type', () {
      expect(
        () => Easyi18nConfig.load(write('projectId: p\nformat: 42')),
        throwsA(isA<CliException>()),
      );
    });

    test('throws on a scheme-less baseUrl instead of crashing later', () {
      expect(
        () =>
            Easyi18nConfig.load(write('projectId: p\nbaseUrl: localhost:8080')),
        throwsA(isA<CliException>()),
      );
    });
  });

  test('toYaml round-trips the projectId form through load', () {
    final original = Easyi18nConfig(
      ref: IdRef('proj_xyz'),
      baseUrl: 'http://localhost:8080',
      format: 'po',
      output: 'assets/l10n',
    );
    final reloaded = Easyi18nConfig.load(write(original.toYaml()));
    expect(reloaded.ref, original.ref);
    expect(reloaded.baseUrl, original.baseUrl);
    expect(reloaded.format, original.format);
    expect(reloaded.output, original.output);
  });

  test('source: round-trips, is a known setting, and is absent by default',
      () {
    final original = Easyi18nConfig(
      ref: IdRef('proj_xyz'),
      format: 'json',
      output: 'public/i18n',
      mode: 'a',
      source: 'public/i18n/en.json',
    );
    final err = StringBuffer();
    final reloaded = Easyi18nConfig.load(write(original.toYaml()),
        logger: CliLogger(out: StringBuffer(), err: err));
    expect(reloaded.source, 'public/i18n/en.json');
    expect(reloaded.output, 'public/i18n');
    expect(reloaded.catalog, isNull);
    expect(err.toString(), isEmpty);
    expect(Easyi18nConfig(ref: IdRef('proj_xyz')).toYaml(),
        isNot(contains('source')));
  });

  test('toYaml round-trips the @handle/slug form through load', () {
    final original = Easyi18nConfig(
      ref: HandleRef('acme', 'dogfood'),
      baseUrl: 'http://localhost:8080',
    );
    final reloaded = Easyi18nConfig.load(write(original.toYaml()));
    expect(reloaded.ref, HandleRef('acme', 'dogfood'));
  });

  test('toYaml round-trips a catalog path the filesystem allows', () {
    // `init --stack xcode` feeds this serializer a path it DISCOVERED, so the
    // value is whatever the disk carries. A plain YAML scalar swallows
    // everything from an unquoted ` #` on and breaks outright on `: ` — the
    // first case reloaded as `App`, a path that does not exist, with init
    // reporting success; the second made the config unreadable.
    for (final catalog in const [
      'App #1/Localizable.xcstrings',
      'App: Demo/Localizable.xcstrings',
      "Bob's App/Localizable.xcstrings",
      'App\nDemo/Localizable.xcstrings', // a real LF: legal in a filename
      'App\tDemo/Localizable.xcstrings',
      'App "Demo"/Localizable.xcstrings',
      r'App\Demo/Localizable.xcstrings',
      'App/Localizable.xcstrings', // the control: still written plain
      '- weird/Localizable.xcstrings',
      'true/Localizable.xcstrings',
    ]) {
      final original = Easyi18nConfig(
          ref: IdRef('p'), format: 'xcstrings', catalog: catalog);
      expect(Easyi18nConfig.load(write(original.toYaml())).catalog, catalog,
          reason: catalog);
    }
    expect(Easyi18nConfig(ref: IdRef('p'), catalog: 'App/L.xcstrings').toYaml(),
        contains('\ncatalog: App/L.xcstrings\n'),
        reason: 'a safe path stays unquoted');
  });

  group('toYaml writes output only where it is the destination (#1858)', () {
    const unused = '# Not used while `catalog:` is set';
    const directory = '# Where the rendered files are written';

    test('a catalog config leaves the unused default out', () {
      // `init --stack xcode` used to write `output: lib/l10n` under a comment
      // about l10n.yaml: a Flutter directory `pull` never reads, because a
      // configured catalog decides the destination.
      final yaml = Easyi18nConfig(ref: IdRef('p'), format: 'xcstrings',
          mode: 'a', catalog: 'App/Localizable.xcstrings').toYaml();
      expect(yaml, isNot(contains('output:')));
      expect(yaml, isNot(contains('l10n')));
      final reloaded = Easyi18nConfig.load(write(yaml));
      expect(reloaded.catalog, 'App/Localizable.xcstrings');
      expect(reloaded.output, Easyi18nConfig.defaultOutput);
    });

    test('an output someone set survives next to a catalog, labelled', () {
      final yaml = Easyi18nConfig(ref: IdRef('p'), format: 'xcstrings',
          output: 'Resources', catalog: 'App/Localizable.xcstrings').toYaml();
      expect(yaml, contains('$unused: pull and sync write into that file.\n'
          'output: Resources\n'));
      expect(yaml, isNot(contains(directory)));
      expect(Easyi18nConfig.load(write(yaml)).output, 'Resources');
    });

    // `sync` uploads a JSON base file but takes no ARB, so the comment over a
    // gen_l10n template says what pull does with it instead (#2343).
    test('a source: says what sync and pull do with it, by format', () {
      final json = Easyi18nConfig(ref: IdRef('p'), format: 'json', mode: 'a',
          output: 'public/i18n', source: 'public/i18n/en.json').toYaml();
      expect(json, contains('`easyi18n sync` uploads'));
      final arb = Easyi18nConfig(ref: IdRef('p'), mode: 'a',
          source: 'lib/l10n/app_en.arb').toYaml();
      expect(arb, isNot(contains('`easyi18n sync` uploads')));
      expect(arb, contains('yours to edit, and\n# `pull` never writes it.'));
      expect(Easyi18nConfig.load(write(arb)).source, 'lib/l10n/app_en.arb');
    });

    test('only an ARB source: is a template', () {
      expect(Easyi18nConfig(ref: IdRef('p'), source: 'lib/l10n/app_en.arb')
          .sourceIsArbTemplate, isTrue);
      expect(Easyi18nConfig(ref: IdRef('p')).sourceIsArbTemplate, isFalse);
      expect(Easyi18nConfig(ref: IdRef('p'), format: 'json',
          source: 'public/i18n/en.json').sourceIsArbTemplate, isFalse);
    });

    test('without a catalog the block is the one every config carries', () {
      final yaml = Easyi18nConfig(ref: IdRef('p')).toYaml();
      expect(yaml, contains('$directory (your l10n.yaml arb-dir for Mode A).\n'
          'output: lib/l10n\n'));
      expect(yaml, isNot(contains(unused)));
    });

    test('an empty catalog names no file, so output is still the destination',
        () {
      final yaml = Easyi18nConfig(ref: IdRef('p'), output: 'Resources',
          catalog: '').toYaml();
      expect(yaml, contains(directory));
      expect(yaml, contains('\noutput: Resources\n'));
      expect(yaml, isNot(contains(unused)));
    });
  });

  test('toYaml round-trips every free-form scalar it writes', () {
    final original = Easyi18nConfig(
      ref: IdRef('p'),
      baseUrl: 'http://localhost:8080',
      output: 'my l10n # dir',
      format: 'xcstrings',
    );
    final reloaded = Easyi18nConfig.load(write(original.toYaml()));
    expect(reloaded.output, 'my l10n # dir');
    expect(reloaded.baseUrl, 'http://localhost:8080');
  });

  test('toYaml round-trips mode, and its headline matches (#415)', () {
    final a = Easyi18nConfig(ref: IdRef('p'), mode: 'a');
    expect(a.toYaml(), contains('Mode A'));
    expect(Easyi18nConfig.load(write(a.toYaml())).mode, 'a');

    final b = Easyi18nConfig(ref: IdRef('p'));
    expect(b.toYaml(), contains('Mode B'));
    expect(Easyi18nConfig.load(write(b.toYaml())).mode, 'b');
  });

  group('catalogs (#590)', () {
    const files = 'catalogs:\n  - App/Localizable.xcstrings\n  - App/Shortcuts.xcstrings\n';

    CliException refused(String yaml) {
      try {
        Easyi18nConfig.load(write('projectId: p\nformat: xcstrings\n$yaml'));
      } on CliException catch (e) {
        return e;
      }
      fail('The config should have been refused.');
    }

    test('is read as a list of paths and is not an unknown setting', () {
      final err = StringBuffer();
      final config = Easyi18nConfig.load(
          write('projectId: p\nformat: xcstrings\n$files'),
          logger: CliLogger(out: StringBuffer(), err: err));
      expect(config.catalogs, ['App/Localizable.xcstrings', 'App/Shortcuts.xcstrings']);
      expect(config.catalog, isNull);
      expect(err.toString(), isEmpty);
    });

    test('paths are trimmed, as every other setting is', () {
      final config = Easyi18nConfig.load(write(
          'projectId: p\nformat: xcstrings\ncatalogs:\n  - " App/L.xcstrings "\n'));
      expect(config.catalogs, ['App/L.xcstrings']);
    });

    test('next to `catalog:` it is refused naming both keys', () {
      final e = refused('catalog: App/Localizable.xcstrings\n$files');
      expect(e.message, allOf(contains('`catalog:`'), contains('`catalogs:`')));
    });

    for (final (name, yaml) in [
      ('an empty list', 'catalogs: []\n'),
      ('a scalar', 'catalogs: App/Localizable.xcstrings\n'),
      ('a blank entry', 'catalogs:\n  - App/Localizable.xcstrings\n  - " "\n'),
      ('a non-string entry', 'catalogs:\n  - 7\n'),
    ]) {
      test('$name is refused', () {
        expect(refused(yaml).message, contains('catalogs must be a list'));
      });
    }

    test('the same file twice is refused, however it is spelled', () {
      final e = refused('catalogs:\n  - App/L.xcstrings\n  - ./App/L.xcstrings\n');
      expect(e.message, contains('twice'));
    });

    test('toYaml round-trips the list and drops the unused output', () {
      final yaml = Easyi18nConfig(ref: IdRef('p'), format: 'xcstrings', mode: 'a',
          catalogs: const ['App/L.xcstrings', 'App/My Shortcuts #1.xcstrings']).toYaml();
      expect(yaml, isNot(contains('output:')));
      expect(Easyi18nConfig.load(write(yaml)).catalogs,
          ['App/L.xcstrings', 'App/My Shortcuts #1.xcstrings']);
    });
  });
}
