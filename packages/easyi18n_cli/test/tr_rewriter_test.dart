import 'dart:io';

import 'package:easyi18n_cli/src/apply/pending_code_change.dart';
import 'package:easyi18n_cli/src/apply/tr_rewriter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('easyi18n_rewriter'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String rel, String content) {
    final f = File(p.join(dir.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String read(String rel) => File(p.join(dir.path, rel)).readAsStringSync();

  final rewriter = TrRewriter();

  PendingCodeChange change(String oldS, String newS, {String? ctx}) =>
      PendingCodeChange(key: 'k', ctx: ctx, oldSource: oldS, newSource: newS);

  test('rewrites canonical + sugar call shapes, leaves ctx arg intact', () {
    write('lib/a.dart', '''
void f(c) {
  c.tr('Helo');
  context.tr('Helo', ctx: 'noun');
  'Helo'.tr();
}
''');
    final plan = rewriter.plan(
      Directory(p.join(dir.path, 'lib')),
      [change('Helo', 'Hello')], // no ctx → matches the two no-ctx sites
      relativeTo: dir.path,
    );
    expect(
      plan.edits,
      hasLength(2),
    ); // canonical no-ctx + sugar; the ctx one is a different key
    expect(rewriter.applyPlan(plan), 1);
    final src = read('lib/a.dart');
    expect(src, contains("c.tr('Hello');"));
    expect(src, contains("'Hello'.tr();"));
    // The ctx:'noun' site is a different identity → untouched.
    expect(src, contains("context.tr('Helo', ctx: 'noun');"));
  });

  test('matches a ctx-qualified change only at the matching ctx site', () {
    write('lib/a.dart', '''
void f(c) {
  c.tr('Bank');
  c.tr('Bank', ctx: 'finance');
}
''');
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('Bank', 'Bank account', ctx: 'finance'),
    ], relativeTo: dir.path);
    expect(plan.edits, hasLength(1));
    expect(plan.edits.single.line, 3);
    rewriter.applyPlan(plan);
    final src = read('lib/a.dart');
    expect(src, contains("c.tr('Bank');")); // no-ctx untouched
    expect(src, contains("c.tr('Bank account', ctx: 'finance');"));
  });

  test('encodes quotes, dollars, and newlines safely', () {
    write('lib/a.dart', "void f(c) => c.tr('plain');\n");
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('plain', "it's \$5\nnext"),
    ], relativeTo: dir.path);
    rewriter.applyPlan(plan);
    final src = read('lib/a.dart');
    expect(src, contains(r"c.tr('it\'s \$5\nnext');"));
  });

  test('rewrites every call site of the same source', () {
    write('lib/a.dart', "void f(c) { c.tr('Helo'); }\n");
    write('lib/b.dart', "void g(c) => c.tr('Helo');\n");
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('Helo', 'Hello'),
    ], relativeTo: dir.path);
    expect(plan.edits, hasLength(2));
    expect(rewriter.applyPlan(plan), 2);
    expect(read('lib/a.dart'), contains("'Hello'"));
    expect(read('lib/b.dart'), contains("'Hello'"));
  });

  test('reports a change with no matching literal as unmatched, no edit', () {
    write('lib/a.dart', "void f(c) => c.tr('Present');\n");
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('Absent', 'Whatever'),
      change('Present', 'Here'),
    ], relativeTo: dir.path);
    expect(plan.edits.map((e) => e.oldSource), ['Present']);
    expect(plan.unmatched.map((c) => c.oldSource), ['Absent']);
  });

  test('a no-op change (new == old) produces no edit', () {
    write('lib/a.dart', "void f(c) => c.tr('Same');\n");
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('Same', 'Same'),
    ], relativeTo: dir.path);
    expect(plan.isEmpty, isTrue);
    expect(plan.unmatched, isEmpty);
  });

  test('ignores an unrelated method named tr on a non-context receiver', () {
    write('lib/a.dart', "void f(t) => t.tr('Helo');\n"); // t is not context
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('Helo', 'Hello'),
    ], relativeTo: dir.path);
    expect(plan.edits, isEmpty);
    expect(plan.unmatched.map((c) => c.oldSource), ['Helo']);
  });

  test("edits follow path order, not the filesystem's", () {
    // Written in an order that APFS lists as `z c b q m a` (#1465): a walk
    // that trusts `listSync` would print and emit the edits z.dart first.
    for (final n in ['b', 'a', 'z', 'm', 'c', 'q']) {
      write('lib/$n.dart', "void f(c) => c.tr('Helo');\n");
    }
    write('lib/a.g.dart', "void f(c) => c.tr('Helo');\n"); // generated: skipped
    write('lib/a.freezed.dart', "void f(c) => c.tr('Helo');\n"); // same
    write('lib/a.txt', "void f(c) => c.tr('Helo');\n"); // not Dart: skipped
    final plan = rewriter.plan(Directory(p.join(dir.path, 'lib')), [
      change('Helo', 'Hello'),
    ], relativeTo: dir.path);
    expect(plan.edits.map((e) => e.file).toList(), [
      'lib/a.dart',
      'lib/b.dart',
      'lib/c.dart',
      'lib/m.dart',
      'lib/q.dart',
      'lib/z.dart',
    ]);
  });
}
