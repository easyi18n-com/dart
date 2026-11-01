import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/extract/source_unit.dart';
import 'package:easyi18n_cli/src/lockfile.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ExtractedUnit u(String source, {String? ctx}) =>
    ExtractedUnit(source: source, ctx: ctx, file: 'lib/a.dart', line: 1);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ei18n_lock'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File lockAt() => File(p.join(tmp.path, Lockfile.fileName));

  test('loadOrEmpty returns an empty lockfile when the file is absent', () {
    final lock = Lockfile.loadOrEmpty(lockAt(), project: 'p1');
    expect(lock.project, 'p1');
    expect(lock.units, isEmpty);
  });

  test('round-trips through JSON, sorted and stable', () {
    final lock = Lockfile.fromExtraction('p1', [
      u('Zebra'),
      u('Apple', ctx: 'fruit'),
      u('Apple'),
    ]);
    lock.write(lockAt());

    final reloaded = Lockfile.loadOrEmpty(lockAt(), project: 'x');
    expect(reloaded.project, 'p1');
    expect(reloaded.units.map((e) => '${e.source}|${e.ctx ?? ''}'), [
      'Apple|',
      'Apple|fruit',
      'Zebra|',
    ]);
    // ctx omitted when empty.
    expect(lockAt().readAsStringSync(), isNot(contains('"ctx": ""')));
  });

  test('diff reports added and removed (orphans)', () {
    final lock = Lockfile.fromExtraction('p1', [u('Keep'), u('Gone')]);
    final diff = lock.diff([u('Keep'), u('New')]);
    expect(diff.added.map((e) => e.source), ['New']);
    expect(diff.removed.map((e) => e.source), ['Gone']);
    expect(diff.isEmpty, isFalse);
  });

  test('diff treats same source with different ctx as distinct', () {
    final lock = Lockfile.fromExtraction('p1', [u('Post', ctx: 'noun')]);
    final diff = lock.diff([u('Post', ctx: 'verb')]);
    expect(diff.added.single.ctx, 'verb');
    expect(diff.removed.single.ctx, 'noun');
  });

  test('an identical scan diffs empty', () {
    final lock = Lockfile.fromExtraction('p1', [u('A'), u('B', ctx: 'c')]);
    expect(lock.diff([u('B', ctx: 'c'), u('A')]).isEmpty, isTrue);
  });

  test('malformed JSON throws a CliException', () {
    lockAt().writeAsStringSync('{ not json');
    expect(
      () => Lockfile.loadOrEmpty(lockAt(), project: 'p1'),
      throwsA(isA<CliException>()),
    );
  });

  test('non-string project values use the seed and preserve units', () {
    final cases = <({String name, Object? value, bool include})>[
      (name: 'absent', value: null, include: false),
      (name: 'null', value: null, include: true),
      (name: 'int', value: 123, include: true),
      (name: 'bool', value: true, include: true),
      (name: 'object', value: {'id': 'p1'}, include: true),
      (name: 'array', value: ['p1'], include: true),
      (name: 'double', value: 1.5, include: true),
    ];

    for (final c in cases) {
      lockAt().writeAsStringSync(jsonEncode({
        'version': 1,
        if (c.include) 'project': c.value,
        'units': [
          {'source': 'Hello', 'ctx': 'button'},
        ],
      }));
      final lock = Lockfile.loadOrEmpty(lockAt(), project: 'seed');

      expect(lock.project, 'seed', reason: c.name);
      expect(lock.units.single.source, 'Hello', reason: c.name);
      expect(lock.units.single.ctx, 'button', reason: c.name);
    }
  });

  group('renamePairs', () {
    LockUnit lu(String source, {String? ctx}) =>
        LockUnit(source: source, ctx: ctx);

    test('pairs an unambiguous 1:1 copy-edit within a ctx bucket', () {
      final diff = LockfileDiff(
        added: [u('New text', ctx: 'noun')],
        removed: [lu('Old text', ctx: 'noun')],
      );
      final pairs = diff.renamePairs();
      expect(pairs[u('New text', ctx: 'noun').identity]?.source, 'Old text');
      expect(pairs[u('New text', ctx: 'noun').identity]?.ctx, 'noun');
    });

    test('does NOT pair when a ctx bucket has multiple adds/removes', () {
      final diff = LockfileDiff(
        added: [u('A2'), u('B2')],
        removed: [lu('A1'), lu('B1')],
      );
      expect(diff.renamePairs(), isEmpty); // empty-ctx bucket → ambiguous
    });

    test('does NOT pair across different ctx buckets', () {
      final diff = LockfileDiff(
        added: [u('New', ctx: 'verb')],
        removed: [lu('Old', ctx: 'noun')],
      );
      expect(diff.renamePairs(), isEmpty);
    });

    test(
      'pairs only the unambiguous bucket, leaving the ambiguous one alone',
      () {
        final diff = LockfileDiff(
          added: [
            u('New', ctx: 'verb'),
            u('X2'),
            u('Y2'),
          ],
          removed: [
            lu('Old', ctx: 'verb'),
            lu('X1'),
            lu('Y1'),
          ],
        );
        final pairs = diff.renamePairs();
        expect(pairs.length, 1);
        expect(pairs[u('New', ctx: 'verb').identity]?.source, 'Old');
      },
    );
  });
}
