import 'dart:io';

import 'package:easyi18n_cli/src/extract/tr_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ei18n_extract'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relPath, String content) {
    final f = File(p.join(tmp.path, relPath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  test('extracts both call shapes with context', () {
    write('lib/a.dart', '''
import 'package:easyi18n/easyi18n.dart';
Widget build(BuildContext context) {
  context.tr('Welcome {name}', {'name': name});
  final s = 'Save'.tr();
  context.tr('Open', ctx: 'verb');
  return Text(s);
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.dynamics, isEmpty);
    expect(result.units.map((u) => '${u.source}|${u.ctx ?? ''}').toSet(), {
      'Welcome {name}|',
      'Save|',
      'Open|verb',
    });
  });

  test('adjacent string literals concatenate; interpolation is dynamic', () {
    write('lib/b.dart', '''
void f(BuildContext c, String name) {
  c.tr('Hello ' 'world');
  c.tr('Hi \$name');
  c.tr(someVar);
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), contains('Hello world'));
    expect(result.units.length, 1);
    expect(result.dynamics.length, 2);
    expect(result.dynamics.first.file, 'lib/b.dart');
  });

  test('an explicit ctx: null is the no-ctx unit, not a dynamic', () {
    // `ctx: null` produces the same runtime token as omitting ctx — demoting
    // it to dynamics would silently drop the string from registration.
    write('lib/b.dart', '''
void f(BuildContext c) {
  c.tr('Delete', ctx: null);
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.dynamics, isEmpty);
    expect(result.units.single.source, 'Delete');
    expect(result.units.single.ctx, isNull);
  });

  test('dedups identical (source, ctx) across files, keeps first location', () {
    write('lib/a.dart', "void f(c) => c.tr('Same');\n");
    write('lib/b.dart', "void g(c) => c.tr('Same');\n");
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.length, 1);
    expect(result.units.single.source, 'Same');
  });

  test('same source with different ctx are distinct units', () {
    write('lib/a.dart', '''
void f(c) {
  c.tr('Post', ctx: 'noun');
  c.tr('Post', ctx: 'verb');
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.length, 2);
  });

  test('ignores tr() on non-context receivers (no false-positive billing)', () {
    write('lib/a.dart', '''
void f(BuildContext context, dynamic table, List items) {
  table.tr('<td>html</td>');
  items.tr('not i18n');
  someService.tr('also not i18n');
  context.tr('Real');
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), ['Real']);
    expect(result.dynamics, isEmpty);
  });

  test('skips generated and non-Dart files', () {
    write('lib/x.g.dart', "void f(c) => c.tr('Generated');\n");
    write('lib/x.freezed.dart', "void f(c) => c.tr('Frozen');\n");
    write('lib/x.txt', "void f(c) => c.tr('Text');\n");
    write('lib/x.dart', "void f(c) => c.tr('Real');\n");
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), ['Real']);
  });

  test('an unparseable file is skipped, not fatal', () {
    write('lib/broken.dart', 'this is not valid dart <<<');
    write('lib/ok.dart', "void f(c) => c.tr('Ok');\n");
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => u.source), ['Ok']);
  });

  test('a non-literal ctx is dynamic, not a wrong no-ctx unit', () {
    write('lib/ctx.dart', '''
const kVerb = 'verb';
void f(BuildContext context) {
  context.tr('Save', ctx: kVerb);
  context.tr('Open', ctx: 'verb');
}
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.units.map((u) => '${u.source}|${u.ctx}'), ['Open|verb']);
    expect(result.dynamics, hasLength(1));
    expect(result.dynamics.single.snippet, contains('Save'));
  });

  test('detects a mounted Easyi18nScope at the AST level', () {
    write('lib/main.dart', '''
// A comment mentioning Easyi18nScope does not count.
void main() => runApp(const MyApp());
''');
    expect(TrExtractor().extractFromDirectory(tmp).scopeFile, isNull);

    write('lib/app.dart', '''
Widget build() => Easyi18nScope(projectId: 'p', child: const MyApp());
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.scopeFile, 'lib/app.dart');
  });

  test('reads whether the scope names baseUrl and the app its locales', () {
    write('lib/main.dart', '''
void main() => runApp(Easyi18nScope(projectId: 'p', child: const MyApp()));
Widget build(BuildContext context) => MaterialApp(home: const X());
''');
    var result = TrExtractor().extractFromDirectory(tmp);
    expect(result.scopeNamesBaseUrl, isFalse);
    expect(result.appFile, 'lib/main.dart');
    expect(result.appLocalized, isFalse);

    write('lib/main.dart', '''
void main() => runApp(Easyi18nScope(
  projectId: 'p', baseUrl: kBase, child: const MyApp()));
Widget build(BuildContext context) => const MaterialApp.router(
  localizationsDelegates: kDelegates,
  supportedLocales: kLocales,
  routerConfig: router);
''');
    result = TrExtractor().extractFromDirectory(tmp);
    expect(result.scopeNamesBaseUrl, isTrue);
    expect(result.appLocalized, isTrue);
  });

  test('one locale argument is not localized, and no app is no app', () {
    write('lib/main.dart', '''
Widget build(BuildContext context) => MaterialApp(supportedLocales: kLocales);
''');
    expect(TrExtractor().extractFromDirectory(tmp).appLocalized, isFalse);
    write('lib/main.dart', 'Widget build() => CupertinoApp();\n');
    expect(TrExtractor().extractFromDirectory(tmp).appFile, isNull);
  });

  test('a plain MaterialApp.router counts, and the first app in a file wins',
      () {
    write('lib/main.dart', '''
Widget build(BuildContext context) => MaterialApp.router(
  localizationsDelegates: d, supportedLocales: l, routerConfig: r);
Widget preview(BuildContext context) => MaterialApp(home: const X());
''');
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.appFile, 'lib/main.dart');
    expect(result.appLocalized, isTrue);
  });

  test('reads the wiring through an import prefix', () {
    write('lib/main.dart', '''
import 'package:easyi18n/easyi18n.dart' as ei;
import 'package:flutter/material.dart' as m;
void main() => runApp(const ei.Easyi18nScope(projectId: 'p', child: X()));
Widget build(m.BuildContext context) => const m.MaterialApp(home: X());
''');
    var result = TrExtractor().extractFromDirectory(tmp);
    expect(result.scopeFile, 'lib/main.dart');
    expect(result.appFile, 'lib/main.dart');

    write('lib/main.dart', '''
import 'package:easyi18n/easyi18n.dart' as ei;
import 'package:flutter/material.dart' as m;
void main() => runApp(ei.Easyi18nScope(projectId: 'p', child: X()));
Widget build(m.BuildContext context) => m.MaterialApp.router(routerConfig: r);
''');
    result = TrExtractor().extractFromDirectory(tmp);
    expect(result.scopeFile, 'lib/main.dart');
    expect(result.appFile, 'lib/main.dart');
    expect(result.appLocalized, isFalse);
  });

  test('detects a const/new Easyi18nScope construction', () {
    write('lib/main.dart', '''
Widget build() => const Easyi18nScope(projectId: 'p', child: MyApp());
''');
    expect(TrExtractor().extractFromDirectory(tmp).scopeFile, 'lib/main.dart');
  });

  test("extraction follows path order, not the filesystem's", () {
    // Written in an order that APFS lists as `z c b q m a` (#1465), so a walk
    // that trusts `listSync` names z.dart first in all four outputs.
    for (final n in ['b', 'a', 'z', 'm', 'c', 'q']) {
      write('lib/$n.dart', '''
void f(c, v) {
  c.tr(v);
  c.tr('Dup');
  Easyi18nScope();
  MaterialApp();
}
''');
    }
    final result = TrExtractor().extractFromDirectory(tmp);
    expect(result.dynamics.map((d) => d.file).toList(), [
      'lib/a.dart',
      'lib/b.dart',
      'lib/c.dart',
      'lib/m.dart',
      'lib/q.dart',
      'lib/z.dart',
    ]);
    expect(result.scopeFile, 'lib/a.dart');
    expect(result.appFile, 'lib/a.dart');
    expect(result.units.single.file, 'lib/a.dart');
  });
}
