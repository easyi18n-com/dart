import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:easyi18n_cli/src/scaffold.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('addRuntimeDependency', () {
    const pubspec = '''
name: demo
dependencies:
  flutter:
    sdk: flutter
''';

    test('inserts under dependencies:', () {
      final out = addRuntimeDependency(pubspec)!;
      expect(out, contains('  easyi18n: $kRuntimeDependency'));
      final doc = loadYaml(out) as Map;
      expect((doc['dependencies'] as Map).containsKey('easyi18n'), isTrue);
      // The pre-existing dep survived the line surgery.
      expect((doc['dependencies'] as Map).containsKey('flutter'), isTrue);
    });

    test('is idempotent for any dependency form', () {
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: ^1.0.0\n'),
        isNull,
      );
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: ^1.4.2\n'),
        isNull,
      );
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n:\n    path: ../x\n'),
        isNull,
      );
    });

    test('appends a dependencies block when the section is missing', () {
      final out = addRuntimeDependency('name: demo\n')!;
      final doc = loadYaml(out) as Map;
      expect((doc['dependencies'] as Map)['easyi18n'], kRuntimeDependency);
    });

    test('raises a ^0.1.x or ^0.2.x from an earlier init, and only those', () {
      const old = 'dependencies:\n  easyi18n: ^0.1.0\n  http: ^1.0.0\n';
      expect(staleRuntimeConstraint(old), '^0.1.0');
      final out = addRuntimeDependency(old)!;
      expect(out, 'dependencies:\n  easyi18n: $kRuntimeDependency\n  http: ^1.0.0\n');
      expect(staleRuntimeConstraint(out), isNull);
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: ^0.2.0\n'),
        'dependencies:\n  easyi18n: ^1.0.0\n',
      );
      expect(addRuntimeDependency('dependencies:\n  easyi18n: ^0.3.0\n'), isNull);
      expect(addRuntimeDependency('dependencies:\n  easyi18n: ^0.20.0\n'), isNull);
      // The raise rewrites the first matching line, so a ^0.20.0 above the
      // dependencies one must not match.
      expect(
        addRuntimeDependency('dev_dependencies:\n  easyi18n: ^0.20.0\n'
            'dependencies:\n  easyi18n: ^0.2.0\n'),
        'dev_dependencies:\n  easyi18n: ^0.20.0\n'
        'dependencies:\n  easyi18n: $kRuntimeDependency\n',
      );
    });

    test('a ^0.2.x is not stale: it resolves the SDK doctor checks for', () {
      expect(staleRuntimeConstraint('dependencies:\n  easyi18n: ^0.2.0\n'), isNull);
    });

    test('outdated is the ^0.1.x or ^0.2.x an earlier init wrote', () {
      String? outdated(String c) =>
          outdatedRuntimeConstraint('dependencies:\n  easyi18n: $c\n');
      expect(outdated('^0.1.1'), '^0.1.1');
      expect(outdated('"^0.2.0"'), '^0.2.0');
      expect(outdated('^0.20.0'), isNull);
      expect(outdated('^0.3.0'), isNull);
      expect(outdated(kRuntimeDependency), isNull);
    });

    test('raises a quoted or commented ^0.1.x or ^0.2.x too, keeping the '
        'comment', () {
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: "^0.1.0"\n'),
        'dependencies:\n  easyi18n: $kRuntimeDependency\n',
      );
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: ^0.1.1 # pinned\n'),
        'dependencies:\n  easyi18n: $kRuntimeDependency # pinned\n',
      );
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: "^0.2.0"\n'),
        'dependencies:\n  easyi18n: $kRuntimeDependency\n',
      );
      expect(
        addRuntimeDependency('dependencies:\n  easyi18n: ^0.2.1 # pinned\n'),
        'dependencies:\n  easyi18n: $kRuntimeDependency # pinned\n',
      );
      // A flow mapping has no line to rewrite: left alone, never a crash.
      expect(
        addRuntimeDependency('dependencies: {easyi18n: ^0.1.0}\n'),
        isNull,
      );
    });
  });

  group('addAssetsFloor', () {
    test('inserts into an existing flutter.assets list', () {
      final out = addAssetsFloor('flutter:\n  assets:\n    - assets/img/\n')!;
      final assets =
          ((loadYaml(out) as Map)['flutter'] as Map)['assets'] as List;
      expect(assets, containsAll(['assets/img/', kAssetsFloorDir]));
    });

    test('adds assets: to a flutter block that lacks it', () {
      final out = addAssetsFloor('flutter:\n  uses-material-design: true\n')!;
      final flutter = (loadYaml(out) as Map)['flutter'] as Map;
      expect(flutter['assets'], [kAssetsFloorDir]);
      expect(flutter['uses-material-design'], isTrue);
    });

    test('appends a flutter block when missing entirely', () {
      final out = addAssetsFloor('name: demo\n')!;
      expect(((loadYaml(out) as Map)['flutter'] as Map)['assets'], [
        kAssetsFloorDir,
      ]);
    });

    test('is idempotent', () {
      expect(
        addAssetsFloor('flutter:\n  assets:\n    - $kAssetsFloorDir\n'),
        isNull,
      );
    });

    test('does not touch an assets: key of another top-level section', () {
      // `assets:` under a sibling section must not be mistaken for
      // flutter.assets.
      final out = addAssetsFloor(
        'other:\n  assets:\n    - x/\nflutter:\n  uses-material-design: true\n',
      )!;
      final doc = loadYaml(out) as Map;
      expect((doc['flutter'] as Map)['assets'], [kAssetsFloorDir]);
      expect((doc['other'] as Map)['assets'], ['x/']);
    });
  });

  group('patchEntitlements', () {
    const plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>com.apple.security.app-sandbox</key>
\t<true/>
</dict>
</plist>
''';

    test('inserts the key before the closing dict', () {
      final out = patchEntitlements(plist)!;
      expect(out, contains('<key>$kNetworkClientKey</key>'));
      expect(out.indexOf(kNetworkClientKey), lessThan(out.indexOf('</dict>')));
      // The existing entitlement survived.
      expect(out, contains('com.apple.security.app-sandbox'));
    });

    test('flips an explicit false to true', () {
      final withFalse = plist.replaceFirst(
        '</dict>',
        '\t<key>$kNetworkClientKey</key>\n\t<false/>\n</dict>',
      );
      final out = patchEntitlements(withFalse)!;
      expect(out, isNot(contains('<false/>')));
      expect(out, contains('<key>$kNetworkClientKey</key>'));
    });

    test('is idempotent when already true', () {
      final patched = patchEntitlements(plist)!;
      expect(patchEntitlements(patched), isNull);
    });

    test('leaves a non-plist file alone', () {
      expect(patchEntitlements('not a plist'), isNull);
    });
  });

  group('internetPermission / addInternetPermission (#2340)', () {
    const created = '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- <manifest> in a comment is not the root -->\n'
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    package="com.example.app">\n'
        '    <application android:label="app" />\n'
        '</manifest>\n';
    const line =
        '<uses-permission android:name="$kInternetPermission" />';
    const ns = 'http://schemas.android.com/apk/res/android';
    const toolsNs = 'http://schemas.android.com/tools';

    test('inserts the permission right after the <manifest> tag', () {
      final out = addInternetPermission(created)!;
      expect(out, contains('package="com.example.app">\n    $line\n'
          '    <application'));
      expect(out, startsWith(created.substring(0, created.indexOf('<manifest '))));
      expect(internetPermission(out), InternetPermission.declared);
      expect(addInternetPermission(out), isNull);
    });

    test('single quotes and other permissions read as written', () {
      expect(internetPermission('<manifest>\n'
          "<uses-permission android:name='$kInternetPermission'/>\n"
          '</manifest>'), InternetPermission.declared);
      expect(internetPermission('<manifest>\n'
          '<uses-permission android:name="android.permission.CAMERA" />\n'
          '</manifest>'), InternetPermission.missing);
    });

    test('a removal is neither a declaration nor something to patch', () {
      const removes = '<manifest>\n'
          '<uses-permission android:name="$kInternetPermission"\n'
          '    tools:node="remove" />\n</manifest>';
      expect(internetPermission(removes), InternetPermission.removed);
      expect(addInternetPermission(removes), isNull);
    });

    test('leaves a file without a <manifest> element alone', () {
      expect(addInternetPermission('<manifest android:x="y" />'), isNull);
      expect(addInternetPermission('not a manifest'), isNull);
    });

    test('a quoted > does not end the manifest opening tag', () {
      const input = '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
          'xmlns:tools="http://schemas.android.com/tools" tools:ignore="x > y">'
          '<application /></manifest>';
      expect(addInternetPermission(input), input.replaceFirst(
          '<application', '\n    $line<application'));
    });

    test('a quoted > before the permission name does not hide it', () {
      expect(internetPermission('<manifest><uses-permission '
          'tools:ignore="x > y" android:name="$kInternetPermission" />'
          '</manifest>'), InternetPermission.declared);
    });

    test('attribute-like text inside a value does not declare a permission', () {
      expect(internetPermission('<manifest><uses-permission '
          "tools:ignore='android:name=\"$kInternetPermission\"' "
          'android:name="android.permission.CAMERA" /></manifest>'),
          InternetPermission.missing);
    });

    test('attribute-like text inside a value does not remove a permission', () {
      expect(internetPermission('<manifest><uses-permission '
          "tools:ignore='tools:node=\"remove\"' "
          'android:name="$kInternetPermission" /></manifest>'),
          InternetPermission.declared);
    });

    test('tag and attribute names must match exactly', () {
      expect(addInternetPermission('<manifest-extra></manifest-extra>'), isNull);
      expect(internetPermission('<uses-permission-extra '
          'android:name="$kInternetPermission" />'), InternetPermission.missing);
      expect(internetPermission('<uses-permission '
          'notandroid:name="$kInternetPermission" />'), InternetPermission.missing);
    });

    test('single-quoted > stays inside its attribute', () {
      const input = "<manifest xmlns:android='$ns' tools:ignore='x > y'></manifest>";
      expect(addInternetPermission(input), input.replaceFirst(
          '</manifest>', '\n    $line</manifest>'));
    });

    test('spaces around = do not hide a declaration from init', () {
      const spaced = '<manifest>\n<uses-permission android:name =\n'
          '    "$kInternetPermission" />\n</manifest>';
      expect(internetPermission(spaced), InternetPermission.declared);
      expect(addInternetPermission(spaced), isNull);
    });

    test('only tools:node="remove" removes the permission', () {
      expect(internetPermission('<manifest><uses-permission '
          'android:name="$kInternetPermission" tools:ignore="remove" />'
          '</manifest>'), InternetPermission.declared);
      const merged = '<manifest><uses-permission '
          'android:name="$kInternetPermission" tools:node="merge" />'
          '</manifest>';
      expect(internetPermission(merged), InternetPermission.declared);
      expect(addInternetPermission(merged), isNull);
    });

    test('the Android prefix is the one the root binds', () {
      expect(internetPermission('<manifest xmlns:a="$ns"><uses-permission '
          'a:name="$kInternetPermission" /></manifest>'),
          InternetPermission.declared);
    });

    test('only an xmlns: attribute binds a prefix', () {
      expect(internetPermission('<manifest tools:ignore="$ns" xmlns:android='
          '"$ns"><uses-permission android:name="$kInternetPermission" />'
          '</manifest>'), InternetPermission.declared);
    });

    test('the tools prefix is the one the root binds', () {
      expect(internetPermission('<manifest xmlns:t="$toolsNs"><uses-permission '
          'android:name="$kInternetPermission" t:node="remove" /></manifest>'),
          InternetPermission.removed);
    });

    test('a <manifest> in a comment binds no prefix', () {
      expect(internetPermission('<!-- <manifest xmlns:z="$ns"> -->'
          '<manifest xmlns:android="$ns"><uses-permission '
          'android:name="$kInternetPermission" /></manifest>'),
          InternetPermission.declared);
    });

    test('the inserted line uses the prefix the root binds', () {
      const input = '<manifest xmlns:a="$ns"><application /></manifest>';
      expect(addInternetPermission(input), input.replaceFirst('<application',
          '\n    <uses-permission a:name="$kInternetPermission" /><application'));
    });

    test('a root that binds no Android prefix is left alone', () {
      expect(addInternetPermission('<manifest><application /></manifest>'),
          isNull);
    });
  });

  group('addGitignoreEntry', () {
    test('appends the state dir', () {
      final out = addGitignoreEntry('build/\n')!;
      expect(out, contains('build/'));
      expect(out.split('\n'), contains(kStateIgnoreEntry));
    });

    test('creates content for an empty file', () {
      expect(addGitignoreEntry('')!.split('\n'), contains(kStateIgnoreEntry));
    });

    test('is idempotent (with or without the slash)', () {
      expect(addGitignoreEntry('$kStateIgnoreEntry\n'), isNull);
      expect(addGitignoreEntry('.easyi18n\n'), isNull);
    });
  });

  group('wrapRunApp', () {
    const arrowMain = '''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());
''';

    test('wraps a trivial arrow main and adds the import', () {
      final out = wrapRunApp(arrowMain, const IdRef('p1'))!;
      expect(out, contains("import 'package:easyi18n/easyi18n.dart';"));
      expect(out, contains('Easyi18nScope('));
      expect(out, contains("projectId: 'p1'"));
      expect(out, contains('child: const MyApp()'));
      // Balanced: same net paren count as a valid wrap.
      expect('('.allMatches(out).length, ')'.allMatches(out).length);
    });

    test('wraps with the @handle/slug ref', () {
      final out = wrapRunApp(arrowMain, const HandleRef('acme', 'dogfood'))!;
      expect(out, contains("workspace: 'acme'"));
      expect(out, contains("slug: 'dogfood'"));
      expect(out, isNot(contains('projectId:')));
      expect('('.allMatches(out).length, ')'.allMatches(out).length);
    });

    test('wraps a block-body main', () {
      const blockMain = '''
void main() {
  runApp(const MyApp());
}
''';
      final out = wrapRunApp(blockMain, const IdRef('p1'))!;
      expect(out, contains('child: const MyApp()'));
    });

    test('is idempotent once the scope is mounted', () {
      final out = wrapRunApp(arrowMain, const IdRef('p1'))!;
      expect(wrapRunApp(out, const IdRef('p1')), isNull);
    });

    test('refuses an argument containing strings or comments', () {
      // A `)` inside a literal or comment would defeat the paren counter and
      // silently corrupt main.dart — the conservative answer is the snippet.
      expect(
        () => wrapRunApp(
          "void main() => runApp(MyApp(title: ':)'));",
          const IdRef('p1'),
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      expect(
        () => wrapRunApp(
          'void main() => runApp(MyApp(\n  // :) tricky\n));',
          const IdRef('p1'),
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
    });

    test('refuses zero or multiple runApp call sites', () {
      expect(
        () => wrapRunApp('void main() {}', const IdRef('p1')),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      expect(
        () => wrapRunApp(
          'void main() { runApp(A()); }\nvoid alt() { runApp(B()); }',
          const IdRef('p1'),
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
    });
  });

  group('addLocalizationsDependency', () {
    test('inserts the sdk package as two lines', () {
      final out = addLocalizationsDependency('dependencies:\n  flutter:\n    sdk: flutter\n')!;
      final deps = (loadYaml(out) as Map)['dependencies'] as Map;
      expect(deps['flutter_localizations'], {'sdk': 'flutter'});
      expect(deps.containsKey('flutter'), isTrue);
    });

    test('is idempotent', () {
      expect(
        addLocalizationsDependency(
            'dependencies:\n  flutter_localizations:\n    sdk: flutter\n'),
        isNull,
      );
    });
  });

  group('scopeArgs', () {
    const mark = '// Development value:';

    /// The line right above the argument [name].
    String above(String args, String name) {
      final lines = args.split('\n');
      return lines[lines.indexWhere((l) => l.trimLeft().startsWith(name)) - 1];
    }

    test('names the backend only when it is not production', () {
      final prod = scopeArgs(const IdRef('p1'));
      expect(prod, isNot(contains('baseUrl')));
      expect(prod, contains('refreshInterval: $kScopeRefreshInterval,'));
      final local = scopeArgs(const IdRef('p1'), baseUrl: 'http://localhost:8080');
      expect(local, contains("baseUrl: Uri.parse('http://localhost:8080'),"));
    });

    test('marks the poll as a development value', () {
      expect(
        above(scopeArgs(const IdRef('p1')), 'refreshInterval:'),
        '    $mark a short publish poll. Raise or remove it to release.',
      );
    });

    test('marks a non-production backend as a development value', () {
      final local = scopeArgs(const IdRef('p1'), baseUrl: 'http://localhost:8080');
      expect(
        above(local, 'baseUrl:'),
        '    $mark the easyi18n.yaml backend. Remove it for production.',
      );
      expect(above(local, 'refreshInterval:'), startsWith('    $mark'));
    });

    test('a production scope carries no backend mark', () {
      final prod = scopeArgs(const IdRef('p1'));
      expect(mark.allMatches(prod), hasLength(1));
      expect(prod, isNot(contains('backend')));
    });

    test('the marks follow the indent and stay within 80 columns', () {
      final args = scopeArgs(const IdRef('p1'),
          baseUrl: 'http://localhost:8080', indent: '      ');
      final marks = args.split('\n').where((l) => l.contains(mark)).toList();
      expect(marks, hasLength(2));
      expect(marks, everyElement(startsWith('      $mark')));
      expect(marks.map((l) => l.length), everyElement(lessThanOrEqualTo(80)));
    });

    test('the printed snippet carries both marks', () {
      final snippet =
          scopeSnippet(const IdRef('p1'), baseUrl: 'http://localhost:8080');
      expect(above(snippet, 'baseUrl:'), startsWith('    $mark'));
      expect(above(snippet, 'refreshInterval:'), startsWith('    $mark'));
    });

    test('escapes the backend as a Dart literal', () {
      expect(
        scopeArgs(const IdRef('p1'), baseUrl: r"http://h/it's$x\y"),
        contains(r"Uri.parse('http://h/it\'s\$x\\y')"),
      );
    });
  });

  group('wrapRunApp writes the backend and the poll', () {
    const main = 'void main() => runApp(const MyApp());';

    test('with a non-production backend', () {
      final out = wrapRunApp(main, const IdRef('p1'), baseUrl: 'http://localhost:8080')!;
      expect(out, contains("baseUrl: Uri.parse('http://localhost:8080'),"));
      expect(out, contains('refreshInterval: $kScopeRefreshInterval,'));
      expect('// Development value:'.allMatches(out), hasLength(2));
    });

    test('without one', () {
      final out = wrapRunApp(main, const IdRef('p1'))!;
      expect(out, isNot(contains('baseUrl')));
      expect(out, contains('refreshInterval:'));
      expect('// Development value:'.allMatches(out), hasLength(1));
    });
  });

  group('localizeApp', () {
    const template = '''
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Demo',
      home: const Home(),
    );
  }
}
''';
    const delegates =
        'localizationsDelegates: GlobalMaterialLocalizations.delegates,';
    const locales = 'supportedLocales: Easyi18nScope.localesOf(context),';

    test('inserts both arguments first, with both imports', () {
      final out = localizeApp(template)!;
      expect(out, contains('    return MaterialApp(\n      $delegates\n      $locales\n      title: '));
      expect(out, contains("import 'package:easyi18n/easyi18n.dart';"));
      expect(out, contains("import 'package:flutter_localizations/flutter_localizations.dart';"));
      expect(RegExp('^import ', multiLine: true).allMatches(out), hasLength(3));
    });

    test('drops a const and closes an empty argument list on its own line', () {
      final out = localizeApp(
        'Widget build(BuildContext context) => const MaterialApp();\n',
      )!;
      expect(out, isNot(contains('const MaterialApp')));
      expect(out, contains('=> MaterialApp(\n  $delegates\n  $locales\n);'));
    });

    test('moves inline arguments to their own line and keeps .router', () {
      final out = localizeApp(
        'Widget build(BuildContext context) => MaterialApp.router(routerConfig: r);\n',
      )!;
      expect(out, contains('MaterialApp.router(\n  $delegates\n  $locales\n  routerConfig: r);'));
    });

    test('is idempotent, and leaves a hand-wired app alone', () {
      expect(localizeApp(localizeApp(template)!), isNull);
      expect(
        localizeApp('Widget build(BuildContext context) => MaterialApp(supportedLocales: mine);'),
        isNull,
      );
    });

    test('bails without a single site or a BuildContext', () {
      expect(
        () => localizeApp('$template\nWidget other(BuildContext context) => MaterialApp();'),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      // Built inside runApp: no context to read the scope from.
      expect(
        () => localizeApp('void main() => runApp(const MaterialApp());'),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      // The only BuildContext belongs to another declaration.
      expect(
        () => localizeApp(
          'class A {\n  Widget build(BuildContext context) => X();\n}\n'
          'Widget app() => MaterialApp();\n',
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      // Another method of the same class, after a block body and after an
      // arrow body: `context` is not in scope where MaterialApp is built.
      expect(
        () => localizeApp(
          'class A {\n  Widget build(BuildContext context) {\n'
          '    return _app();\n  }\n\n'
          '  Widget _app() => MaterialApp();\n}\n',
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
      expect(
        () => localizeApp(
          'class A {\n  Widget build(BuildContext context) => _app();\n\n'
          '  Widget _app() => MaterialApp();\n}\n',
        ),
        throwsA(isA<ScaffoldUnpatchable>()),
      );
    });

    test('reads the body through a comment and a plain string', () {
      // Brackets inside them do not count: `context` is in scope here.
      expect(
        localizeApp(
          'Widget build(BuildContext context) {\n'
          '  // see runApp( and {\n'
          '  /* } */ final t = r\'{\\\' + \'it\\\'s (\' + "\$x [";\n'
          '  return MaterialApp(title: t);\n}\n',
        ),
        contains(locales),
      );
      // A raw string has no escapes: its trailing backslash ends nothing.
      expect(
        localizeApp(
          'Widget build(BuildContext context) {\n'
          "  final t = r'\\' + '(';\n"
          '  return MaterialApp(title: t);\n}\n',
        ),
        contains(locales),
      );
    });

    test('bails on a body it cannot lex', () {
      // An unmatched bracket in a string or comment of `build` would leave
      // the depth at one, and the helper below has no `context`.
      for (final line in ["    final s = '{';\n", '    // see runApp(\n']) {
        expect(
          () => localizeApp(
            'class A {\n  Widget build(BuildContext context) {\n'
            '$line    return _app();\n  }\n\n'
            '  Widget _app() => MaterialApp();\n}\n',
          ),
          throwsA(isA<ScaffoldUnpatchable>()),
          reason: line,
        );
      }
      // A `${` interpolation, a multi-line string, a site inside a comment.
      for (final (line, site) in [
        ("  final t = '\${1}';\n", 'MaterialApp()'),
        ("  final t = '''x''';\n", 'MaterialApp()'),
        ('  // MaterialApp(\n', 'X()'),
      ]) {
        expect(
          () => localizeApp(
            'Widget build(BuildContext context) {\n$line'
            '  return Scaffold(child: $site);\n}\n',
          ),
          throwsA(isA<ScaffoldUnpatchable>()),
          reason: line,
        );
      }
    });

    test('patches a block body and an arrow body that take the context', () {
      expect(
        localizeApp(
          'Widget build(BuildContext context) {\n'
          '  final t = (1, [2]);\n  return MaterialApp();\n}\n',
        ),
        contains(locales),
      );
      expect(
        localizeApp(
          'Widget build(BuildContext context) =>\n    MaterialApp();\n',
        ),
        contains(locales),
      );
    });
  });
}
