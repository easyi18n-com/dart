import 'dart:io';

import 'package:easyi18n_cli/src/state.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_state');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('CliState', () {
    test('round-trips version + pulledAt', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      final at = DateTime.utc(2026, 7, 4, 12, 30);
      CliState(version: '2026.07.04.2', pulledAt: at).save(file);

      final loaded = CliState.load(file);
      expect(loaded.version, '2026.07.04.2');
      expect(loaded.pulledAt, at);
      expect(file.path, contains('.easyi18n'));
    });

    test('round-trips format + output + files', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      CliState(
        version: '2026.07.10.1',
        pulledAt: DateTime.utc(2026, 7, 10),
        format: 'arb',
        output: 'lib/l10n',
        files: const ['app_en.arb', 'app_zh_Hant.arb'],
      ).save(file);

      final loaded = CliState.load(file);
      expect(loaded.format, 'arb');
      expect(loaded.output, 'lib/l10n');
      expect(loaded.files, ['app_en.arb', 'app_zh_Hant.arb']);
    });

    test('round-trips snapshotAt separately from pulledAt (#898)', () {
      // Two answers to two questions, days apart: `pull --version` writes
      // two-week-old content NOW. Recycling one field for both would make
      // `status` print "pulled 13 days ago" right after a pull.
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      CliState(
        version: '2026.08.20.1',
        pulledAt: DateTime.utc(2026, 9, 2, 14),
        snapshotAt: DateTime.utc(2026, 8, 20, 9),
      ).save(file);

      final loaded = CliState.load(file);
      expect(loaded.pulledAt, DateTime.utc(2026, 9, 2, 14));
      expect(loaded.snapshotAt, DateTime.utc(2026, 8, 20, 9));
    });

    test('state written by a pre-0.12.0 CLI has no snapshotAt', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '{"version":"2026.08.11.1","pulledAt":"2026-08-11T09:00:00.000Z"}',
      );

      final loaded = CliState.load(file);
      expect(loaded.pulledAt, DateTime.utc(2026, 8, 11, 9));
      expect(loaded.snapshotAt, isNull);
    });

    test('a snapshotAt naming no zone is dropped, like pulledAt', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '{"pulledAt":"2026-09-02T14:00:00.000Z",'
        '"snapshotAt":"2026-08-20T09:00:00"}',
      );

      final loaded = CliState.load(file);
      expect(loaded.pulledAt, DateTime.utc(2026, 9, 2, 14));
      expect(loaded.snapshotAt, isNull);
    });

    test('a zoned stamp is normalized to UTC on load', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"snapshotAt":"2026-08-20T11:00:00+02:00"}');

      expect(CliState.load(file).snapshotAt, DateTime.utc(2026, 8, 20, 9));
    });

    test('state written by an older CLI loads with null files', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"version": "2026.07.01"}');

      final loaded = CliState.load(file);
      expect(loaded.version, '2026.07.01');
      expect(loaded.format, isNull);
      expect(loaded.output, isNull);
      expect(loaded.files, isNull);
    });

    test('missing or corrupt file loads as empty state', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      expect(CliState.load(file).version, isNull);

      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json');
      expect(CliState.load(file).version, isNull);
    });
  });

  group('digests of what a pull wrote (#2095)', () {
    const hola = 'sha256:'
        '4a59a5bb7785af3f6d9aa3856fb3cfcb1d0ad69f1701a57a35b4a64b2ef02eb9';

    test('JSON is digested decoded, with its keys sorted at every depth', () {
      // SHA-256 of the UTF-8 bytes of `{"hello":"Hola"}`.
      expect(contentDigest('{"hello":"Hola"}'), hola);
      expect(contentDigest('{\r\n  "hello" : "Hola"\r\n}\r\n'), hola);
      // The mark some editors on Windows put first is layout too.
      expect(contentDigest('\uFEFF{"hello":"Hola"}'), hola);
      expect(contentDigest('{"hello":"Hola "}'), isNot(hola));
      // SHA-256 of `{"a":"Adiós","b":{"x":[2,1],"y":1}}`.
      const nested = 'sha256:'
          '10ac813c66a155287af295dd85319f7d03ff7aaec1568b248405f9e8abc79cea';
      expect(contentDigest('{"b":{"y":1,"x":[2,1]},"a":"Adi\\u00f3s"}'), nested);
      // A list is an order, not a set.
      expect(contentDigest('{"b":{"y":1,"x":[1,2]},"a":"Adiós"}'),
          isNot(nested));
      // The objects inside one are sorted like any other.
      expect(contentDigest('{"a":[{"y":1,"x":2}]}'),
          contentDigest('{"a":[{"x":2,"y":1}]}'));
    });

    test('the stamp an ARB render carries is left out, at the top level only',
        () {
      expect(
          contentDigest('{"@@last_modified":"2026-10-11T23:12:05Z","hello":"Hola"}'),
          hola);
      expect(
          contentDigest('{"hello":"Hola","meta":{"@@last_modified":"x"}}'),
          isNot(contentDigest('{"hello":"Hola","meta":{}}')));
      expect(contentDigest('{"@@locale":"es","hello":"Hola"}'), isNot(hola));
    });

    test('a file that is not JSON only has its line ends folded', () {
      // SHA-256 of `"hi" = "Hola";` and one LF.
      const strings = 'sha256:'
          'cf1670cf556ae079aa8655a3de7c8fcbcc974a785ff12e4e8fd577c30e069cbd';
      expect(contentDigest('"hi" = "Hola";\n'), strings);
      expect(contentDigest('"hi" = "Hola";\r\n'), strings);
      expect(contentDigest('"hi"  = "Hola";\n'), isNot(strings));
    });

    test('the record keeps them by path and reads back only strings', () {
      final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
      CliState(
        format: 'json',
        output: 'public/i18n',
        files: const ['es.json'],
        digests: const {'es.json': hola},
      ).save(file);
      expect(CliState.load(file).digests, {'es.json': hola});

      file.writeAsStringSync(
          '{"files":["es.json"],"digests":{"es.json":7,"fr.json":"$hola"}}');
      expect(CliState.load(file).digests, {'fr.json': hola});
      file.writeAsStringSync('{"files":["es.json"],"digests":["es.json"]}');
      expect(CliState.load(file).digests, isNull);
    });

    test('changed files come back sorted, relative to the project', () {
      for (final name in ['fr.json', 'es.json', 'sub/de.json']) {
        File('${dir.path}/public/i18n/$name')
          ..createSync(recursive: true)
          ..writeAsStringSync('{"hello":"Buenas"}');
      }
      const state = CliState(output: './public/i18n/', digests: {
        'fr.json': hola, 'es.json': hola, 'sub/de.json': hola, 'gone.json': hola,
      });
      expect(state.changedSincePull(dir.path, 'public/i18n'), [
        'public/i18n/es.json', 'public/i18n/fr.json', 'public/i18n/sub/de.json',
      ]);
      expect(state.changedSincePull(dir.path, 'public/i18n', among: ['fr.json']),
          ['public/i18n/fr.json']);
      expect(
          state.changedSincePull(dir.path, 'public/i18n',
              incoming: {'fr.json': '{ "hello": "Buenas" }'}),
          ['public/i18n/es.json', 'public/i18n/sub/de.json']);
      expect(state.changedSincePull(dir.path, 'public'), isEmpty);
    });
  });

  group('parsePublishVersion / comparePublishVersions', () {
    test('parses both forms; legacy is an implicit .1', () {
      expect(parsePublishVersion('2026.07.04.3'), (date: 20260704, n: 3));
      expect(parsePublishVersion('2026.07.04'), (date: 20260704, n: 1));
      expect(parsePublishVersion('garbage'), isNull);
    });

    test('orders numerically within a day (.10 after .9)', () {
      expect(
        comparePublishVersions('2026.07.04.9', '2026.07.04.10'),
        lessThan(0),
      );
      expect(comparePublishVersions('2026.07.04', '2026.07.04.1'), 0);
      expect(
        comparePublishVersions('2026.07.03.99', '2026.07.04.1'),
        lessThan(0),
      );
    });
  });

  test('round-trips the catalogs a pull wrote (#590)', () {
    final file = CliState.fileFor('${dir.path}/easyi18n.yaml');
    CliState(version: '2026.07.04.2', catalogs: const ['A.xcstrings', 'B.xcstrings'])
        .save(file);
    expect(CliState.load(file).catalogs, ['A.xcstrings', 'B.xcstrings']);
    CliState(version: '2026.07.04.2').save(file);
    expect(CliState.load(file).catalogs, isEmpty);
  });
}
