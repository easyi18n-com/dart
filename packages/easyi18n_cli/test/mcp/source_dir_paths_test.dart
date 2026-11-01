import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'harness.dart';
import 'server_test.dart' show project;

void main() {
  test('normalization skips link before parent segment', () async {
    final fixture = project(
      files: {'safe/app.dart': "f(c) => c.tr('Inside');"},
    );
    addTearDown(() => fixture.dir.deleteSync(recursive: true));
    final outside = Directory.systemTemp.createTempSync('normalized_outside');
    addTearDown(() => outside.deleteSync(recursive: true));
    Directory(p.join(outside.path, 'nested')).createSync();
    File(p.join(outside.path, 'safe', 'app.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("f(c) => c.tr('Outside');");
    Link(
      p.join(fixture.dir.path, 'link'),
    ).createSync(p.join(outside.path, 'nested'));
    final harness = await McpHarness.start(fixture.deps);
    addTearDown(harness.shutdown);
    final result = await harness.call('extract', {
      'source_dir': 'link/../safe',
    });
    expect(result.isError, isNot(true));
    expect(
      (result.structuredContent!['units'] as List).single,
      containsPair('source', 'Inside'),
    );
  });

  for (final alias in [false, true]) {
    for (final source in ['lib', 'lib/../lib', '.', 'ABSOLUTE']) {
      test('root alias $alias source $source extracts real source', () async {
        final fixture = project(
          files: {'lib/app.dart': "f(c) => c.tr('Inside');"},
        );
        addTearDown(() => fixture.dir.deleteSync(recursive: true));
        final aliasParent = Directory.systemTemp.createTempSync('root_alias');
        addTearDown(() => aliasParent.deleteSync(recursive: true));
        final rootLink = Link(p.join(aliasParent.path, 'project'))
          ..createSync(fixture.dir.path);
        final root = alias ? rootLink.path : fixture.dir.path;
        final harness = await McpHarness.start(fixture.deps);
        addTearDown(harness.shutdown);
        final result = await harness.call('extract', {
          'project_dir': root,
          'source_dir': source == 'ABSOLUTE' ? p.join(root, 'lib') : source,
        });
        expect(result.isError, isNot(true));
        expect(result.structuredContent!['total'], 1);
        expect(
          (result.structuredContent!['units'] as List).single,
          containsPair('source', 'Inside'),
        );
      });
    }
  }
}
