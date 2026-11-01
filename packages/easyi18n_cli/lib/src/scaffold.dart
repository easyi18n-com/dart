/// Pure text transforms for `easyi18n init` (flutter-integration §4).
///
/// Every function returns the patched content, or **null when the input
/// already satisfies the invariant** — that null is what makes `init`
/// idempotent: a re-run reports "ok" instead of stacking duplicate edits.
/// All file I/O and reporting stay in the command; these are deliberately
/// side-effect-free so they can be tested on fixture strings.
library;

import 'package:yaml/yaml.dart';

import 'project_ref.dart';

/// Version constraint written for the runtime SDK dependency.
const String kRuntimeDependency = '^0.2.0';

/// The offline-floor assets directory (trailing slash: pubspec asset dirs
/// require it to include the folder's files).
const String kAssetsFloorDir = 'assets/easyi18n/';

/// macOS sandbox entitlement the SDK needs for delivery fetches (friction F3).
const String kNetworkClientKey = 'com.apple.security.network.client';

/// Derived CLI state dir (`CliState.dirName`) — cache, never committed.
const String kStateIgnoreEntry = '.easyi18n/';

/// Adds `easyi18n: ^x.y.z` under `dependencies:`, or raises a constraint an
/// earlier init wrote that cannot resolve the SDK [localizeApp] needs. Null
/// when the package is already a dependency (any form: version, path, git,
/// override) that can.
String? addRuntimeDependency(String pubspec) {
  final stale = staleRuntimeConstraint(pubspec);
  if (stale != null) {
    // The line as init wrote it, or hand-quoted / commented since; a flow
    // mapping (`{easyi18n: ^0.1.0}`) has no such line and is left alone.
    final line = RegExp(r'^(\s+easyi18n:\s*)(["\x27]?)\^0\.1\.[^\s"\x27#]*\2',
        multiLine: true);
    if (!line.hasMatch(pubspec)) return null;
    return pubspec.replaceFirstMapped(
        line, (m) => '${m.group(1)}$kRuntimeDependency');
  }
  return _addDependency(pubspec, 'easyi18n', ['  easyi18n: $kRuntimeDependency']);
}

/// The `easyi18n:` constraint when it is a `^0.1.x` from an earlier init,
/// which excludes the 0.2.0 that `Easyi18nScope.localesOf` ships in.
String? staleRuntimeConstraint(String pubspec) {
  final deps = _tryLoadMap(pubspec)?['dependencies'];
  final constraint = deps is Map ? deps['easyi18n'] : null;
  return constraint is String && constraint.startsWith('^0.1.')
      ? constraint
      : null;
}

/// Adds the `flutter_localizations` SDK package, which
/// `GlobalMaterialLocalizations.delegates` (what [localizeApp] writes) lives
/// in. Null when already a dependency.
String? addLocalizationsDependency(String pubspec) => _addDependency(
      pubspec, 'flutter_localizations',
      ['  flutter_localizations:', '    sdk: flutter'],
    );

String? _addDependency(String pubspec, String name, List<String> entry) {
  final doc = _tryLoadMap(pubspec);
  final deps = doc?['dependencies'];
  if (deps is Map && deps.containsKey(name)) return null;

  final lines = pubspec.split('\n');
  final depsIndex = lines.indexWhere((l) => l.trimRight() == 'dependencies:');
  if (depsIndex >= 0) {
    lines.insertAll(depsIndex + 1, entry);
    return lines.join('\n');
  }
  return '${_closeBlock(pubspec)}'
      'dependencies:\n'
      '${entry.join('\n')}\n';
}

/// Registers the assets floor dir under `flutter: assets:`. Null when already
/// listed.
String? addAssetsFloor(String pubspec) {
  final doc = _tryLoadMap(pubspec);
  final flutter = doc?['flutter'];
  if (flutter is Map) {
    final assets = flutter['assets'];
    if (assets is List && assets.contains(kAssetsFloorDir)) return null;
  }

  final lines = pubspec.split('\n');
  final flutterIndex = lines.indexWhere((l) => l.trimRight() == 'flutter:');
  if (flutterIndex < 0) {
    return '${_closeBlock(pubspec)}'
        'flutter:\n'
        '  assets:\n'
        '    - $kAssetsFloorDir\n';
  }

  // Scan the flutter: block (until the next top-level key) for an assets: key.
  var end = lines.length;
  for (var i = flutterIndex + 1; i < lines.length; i++) {
    final l = lines[i];
    if (l.isNotEmpty && !l.startsWith(' ') && !l.startsWith('#')) {
      end = i;
      break;
    }
  }
  for (var i = flutterIndex + 1; i < end; i++) {
    if (lines[i].trimRight() == '  assets:') {
      lines.insert(i + 1, '    - $kAssetsFloorDir');
      return lines.join('\n');
    }
  }
  lines.insert(flutterIndex + 1, '  assets:\n    - $kAssetsFloorDir');
  return lines.join('\n');
}

/// Whether the app bundles the offline floor: the exact dir entry
/// [addAssetsFloor] writes, or any itemized entry under it (Flutter accepts
/// both). With [locale], its exact file must be registered.
bool floorRegistered(String pubspec, {String? locale}) {
  final flutter = _tryLoadMap(pubspec)?['flutter'];
  final assets = flutter is Map ? flutter['assets'] : null;
  return assets is List &&
      assets.any((e) => e == kAssetsFloorDir ||
          (locale == null
              ? e is String && e.startsWith(kAssetsFloorDir)
              : e == '$kAssetsFloorDir$locale.json'));
}

/// Ensures `com.apple.security.network.client` is `<true/>` in a plist
/// `.entitlements` file. Null when already true; patches a `<false/>` in
/// place; otherwise inserts the pair before the closing `</dict>`.
String? patchEntitlements(String plist) {
  const key = '<key>$kNetworkClientKey</key>';
  final keyIndex = plist.indexOf(key);
  if (keyIndex >= 0) {
    // The value tag follows the key (whitespace between them).
    final after = plist.substring(keyIndex + key.length);
    final valueMatch = RegExp(r'<(true|false)\s*/>').firstMatch(after);
    if (valueMatch == null) return null; // malformed — leave it alone
    if (valueMatch.group(1) == 'true') return null;
    return plist.substring(0, keyIndex + key.length) +
        after.replaceFirst(valueMatch.group(0)!, '<true/>');
  }
  final close = plist.lastIndexOf('</dict>');
  if (close < 0) return null; // not a plist dict — leave it alone
  return '${plist.substring(0, close)}'
      '\t$key\n\t<true/>\n'
      '${plist.substring(close)}';
}

/// Appends the derived-state dir to `.gitignore`. Null when already ignored.
String? addGitignoreEntry(String gitignore) {
  final entries = gitignore.split('\n').map((l) => l.trim());
  if (entries.contains(kStateIgnoreEntry) || entries.contains('.easyi18n')) {
    return null;
  }
  return '${_closeBlock(gitignore)}'
      '# easyi18n derived CLI state (cache)\n'
      '$kStateIgnoreEntry\n';
}

/// The `Easyi18nScope` ref argument line(s) — `projectId:` for an [IdRef], or
/// the `workspace:` + `slug:` pair for a [HandleRef]. [indent] prefixes each
/// emitted line.
String scopeRefArgs(ProjectRef ref, {String indent = '    '}) => switch (ref) {
  IdRef(:final id) => "${indent}projectId: '$id',",
  HandleRef(:final workspace, :final slug) =>
    "${indent}workspace: '$workspace',\n${indent}slug: '$slug',",
};

/// Manifest poll written into the scope: a publish reaches the running app
/// without a resume. On-resume refresh stays on as well.
const String kScopeRefreshInterval = 'const Duration(seconds: 10)';

/// Opens the comment written above each scope argument that suits
/// development and not a release, so the generated code says which lines to
/// revisit.
const String kDevValueMark = '// Development value:';

/// Every `Easyi18nScope` argument `init` writes: the ref, the backend when
/// [baseUrl] names one (null = production, where the SDK default already
/// points), and the poll interval. The backend and the poll each carry a
/// [kDevValueMark] comment on the line above.
String scopeArgs(ProjectRef ref, {String? baseUrl, String indent = '    '}) =>
    [
      scopeRefArgs(ref, indent: indent),
      if (baseUrl != null) ...[
        '$indent$kDevValueMark the easyi18n.yaml backend. '
            'Remove it for production.',
        '${indent}baseUrl: Uri.parse(${_dartString(baseUrl)}),',
      ],
      '$indent$kDevValueMark a short publish poll. '
          'Raise or remove it to release.',
      '${indent}refreshInterval: $kScopeRefreshInterval,',
    ].join('\n');

/// The two `MaterialApp` arguments that let `context.tr` resolve a published
/// locale: without them the app resolves `en_US` whatever the device says.
String appArgs({String indent = '    '}) =>
    '${indent}localizationsDelegates: GlobalMaterialLocalizations.delegates,\n'
    '${indent}supportedLocales: Easyi18nScope.localesOf(context),';

const String _sdkImport = "import 'package:easyi18n/easyi18n.dart';";
const String _localizationsImport =
    "import 'package:flutter_localizations/flutter_localizations.dart';";

/// The full wiring printed when `main.dart` can't be patched mechanically:
/// the scope around `runApp` and the locale arguments of `MaterialApp`.
String scopeSnippet(ProjectRef ref, {String? baseUrl}) =>
    '''
$_sdkImport
$_localizationsImport

runApp(
  Easyi18nScope(
${scopeArgs(ref, baseUrl: baseUrl)}
    child: const MyApp(),
  ),
);

// In the widget that builds it:
MaterialApp(
${appArgs(indent: '  ')}
  ...
)''';

/// Wraps the app's single trivial `runApp(<expr>)` in an `Easyi18nScope` and
/// adds the SDK import. Returns:
/// - null when the scope is already mounted (idempotent), or
/// - the patched source, or
/// - throws [ScaffoldUnpatchable] when the shape isn't trivial (zero or
///   multiple `runApp(` call sites, or unbalanced parens) — the caller prints
///   [scopeSnippet] instead. Never blindly rewrites a non-trivial `main`.
String? wrapRunApp(String source, ProjectRef ref, {String? baseUrl}) {
  if (source.contains('Easyi18nScope')) return null;

  const marker = 'runApp(';
  final first = source.indexOf(marker);
  if (first < 0 || source.indexOf(marker, first + 1) >= 0) {
    throw const ScaffoldUnpatchable('no single runApp(...) call site');
  }

  final argStart = first + marker.length;
  var depth = 1;
  var i = argStart;
  while (i < source.length && depth > 0) {
    final c = source[i];
    // Conservative: a string literal or comment inside the argument can hide
    // parens, and counting through one silently corrupts main.dart. This is
    // not a Dart lexer — bail to the printed snippet instead.
    if (c == "'" ||
        c == '"' ||
        (c == '/' &&
            i + 1 < source.length &&
            (source[i + 1] == '/' || source[i + 1] == '*'))) {
      throw const ScaffoldUnpatchable(
        'runApp argument contains a string or comment',
      );
    }
    if (c == '(') depth++;
    if (c == ')') depth--;
    i++;
  }
  if (depth != 0) {
    throw const ScaffoldUnpatchable('unbalanced parentheses after runApp(');
  }
  final argEnd = i - 1; // the matching ')'
  final arg = source.substring(argStart, argEnd).trim();
  if (arg.isEmpty) {
    throw const ScaffoldUnpatchable('empty runApp() argument');
  }

  final args = scopeArgs(ref, baseUrl: baseUrl, indent: '      ');
  final wrapped =
      '${source.substring(0, argStart)}\n'
      '    Easyi18nScope(\n'
      '$args\n'
      '      child: $arg,\n'
      '    ),\n'
      '  ${source.substring(argEnd)}';
  return _ensureImport(wrapped, _sdkImport);
}

/// Adds [appArgs] to the app's single `MaterialApp(` / `MaterialApp.router(`
/// site, with both imports, dropping a `const` in front (the locales are
/// read from the scope at build time). Returns:
/// - null when the source already names `localizationsDelegates` or
///   `supportedLocales` (idempotent, and a hand-wired app is left alone), or
/// - the patched source, or
/// - throws [ScaffoldUnpatchable] when the site is not unique, or has no
///   `BuildContext context` to read the scope from (built inside `runApp(`,
///   or in a body other than the one that takes the parameter) — the caller
///   prints [scopeSnippet].
String? localizeApp(String source) {
  if (source.contains('localizationsDelegates') ||
      source.contains('supportedLocales')) {
    return null;
  }
  final sites = RegExp(r'\b(const\s+)?MaterialApp(\.router)?\(')
      .allMatches(source)
      .toList();
  if (sites.length != 1) {
    throw const ScaffoldUnpatchable('no single MaterialApp(...) call site');
  }
  final site = sites.single;
  final context = source.lastIndexOf('BuildContext context', site.start);
  if (context < 0 || !_sameBody(source, context, site.start)) {
    throw const ScaffoldUnpatchable(
      'MaterialApp is built without a BuildContext',
    );
  }

  final lineStart = source.lastIndexOf('\n', site.start) + 1;
  final baseIndent = RegExp(r'^[ \t]*').firstMatch(source.substring(lineStart))!
      .group(0)!;
  final indent = '$baseIndent  ';
  final after = source.substring(site.end);
  final rest = after.startsWith('\n')
      ? after
      : after.startsWith(')')
          ? '\n$baseIndent$after'
          : '\n$indent$after';
  final patched =
      '${source.substring(0, site.start)}'
      'MaterialApp${site.group(2) ?? ''}(\n'
      '${appArgs(indent: indent)}'
      '$rest';
  return _ensureImport(_ensureImport(patched, _sdkImport), _localizationsImport);
}

/// Whether [site] sits inside the body of the declaration whose parameter
/// list holds [param]: the `{...}` or `=> ...;` after the parameters' closing
/// paren. A `}` back at depth zero, or the `;` that ends an arrow body,
/// closes that body before the site (the site is then in another method of
/// the same class, where `context` is not in scope). Comments and one-line
/// string literals are skipped, not counted; what this is not a lexer for
/// (a `${` interpolation, a `'''` string, a site inside a comment) is not
/// patched.
bool _sameBody(String source, int param, int site) {
  var i = source.indexOf(')', param);
  if (i < 0 || i > site) return false;
  i++;
  while (i < site && ' \t\r\n'.contains(source[i])) {
    i++;
  }
  final arrow = source.startsWith('=>', i);
  if (!arrow && (i >= site || source[i] != '{')) return false;
  var depth = 0;
  for (; i < site; i++) {
    final c = source[i];
    if (c == '/' &&
        (source.startsWith('/', i + 1) || source.startsWith('*', i + 1))) {
      final close = source[i + 1] == '/' ? '\n' : '*/';
      final at = source.indexOf(close, i + 2);
      if (at < 0 || at > site) return false;
      i = at + close.length - 1;
      continue;
    }
    if (c == "'" || c == '"') {
      i = _stringEnd(source, i, site);
      if (i < 0) return false;
      continue;
    }
    switch (c) {
      case '{' || '(' || '[':
        depth++;
      case '}' || ')' || ']':
        depth--;
        if (depth == 0 && !arrow) return false;
      case ';':
        if (depth == 0 && arrow) return false;
    }
  }
  return true;
}

/// Index of the quote closing the string literal that opens at [open], or -1
/// when it is not a plain one-line literal: a `${` interpolation, a `'''`
/// string, or no closing quote before [limit].
int _stringEnd(String source, int open, int limit) {
  final quote = source[open];
  if (source.startsWith(quote * 2, open + 1)) return -1;
  final raw = open > 0 && source[open - 1] == 'r';
  for (var i = open + 1; i < limit; i++) {
    final c = source[i];
    if (c == quote) return i;
    if (raw) continue;
    if (c == r'\') {
      i++;
    } else if (c == r'$' && source.startsWith('{', i + 1)) {
      return -1;
    }
  }
  return -1;
}

String _ensureImport(String source, String import) {
  if (source.contains(import)) return source;
  final lines = source.split('\n');
  final lastImport = lines.lastIndexWhere(
    (l) => l.trimLeft().startsWith('import '),
  );
  lines.insert(lastImport + 1, import);
  return lines.join('\n');
}

/// [value] as a single-quoted Dart string literal.
String _dartString(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

/// A `main.dart` whose `runApp` shape is too risky to rewrite mechanically.
class ScaffoldUnpatchable implements Exception {
  const ScaffoldUnpatchable(this.reason);
  final String reason;
}

Map<Object?, Object?>? _tryLoadMap(String yaml) {
  try {
    final doc = loadYaml(yaml);
    return doc is Map ? doc : null;
  } on YamlException {
    return null;
  }
}

/// Existing content trimmed and closed with a blank separator line, ready to
/// have a new top-level block appended ('' when there was no content).
String _closeBlock(String s) {
  final t = s.trimRight();
  return t.isEmpty ? '' : '$t\n\n';
}
