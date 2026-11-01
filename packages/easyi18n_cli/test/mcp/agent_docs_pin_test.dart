@TestOn('vm')
library;

import 'dart:io';

import 'package:easyi18n_cli/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Every page that tells a client how to launch the server through npm pins
/// the CLI to [packageVersion], as `mcp config` does: an unpinned `npx` got
/// npm's `latest`, rc.1, while rc.4 was current (#1930). ci.yml's `cli` filter
/// and tool/analyze.sh list these paths, so an edit to one of them runs this.
const _roots = [
  '../../docs-site/docs/developers/agents',
  '../../integrations/agents',
];

/// A launch, not a mention of the package name: after `npx` on the same line,
/// or as a quoted argument of a JSON or TOML `args` array. `npm install -g`
/// installs once and writes no client config, so it matches neither.
final _launch = RegExp(r'''(?:npx[^\n`]*?|")@easyi18n\.com/cli(@[^\s"'`]*)?''');

/// The pages that carry a launch today. A regex that stopped matching would
/// otherwise pass on zero launches.
const _carriers = [
  'docs-site/docs/developers/agents/claude-code-plugin.md',
  'docs-site/docs/developers/agents/connect-your-ai.md',
  'docs-site/docs/developers/agents/install.md',
  'integrations/agents/README.md',
  'integrations/agents/clients/README.md',
  'integrations/agents/npm/README.md',
];

/// The launches in [lines] of page [name], each with whether it is stale.
Iterable<(String, bool)> _launches(String name, List<String> lines) sync* {
  for (var i = 0; i < lines.length; i++) {
    for (final m in _launch.allMatches(lines[i])) {
      yield ('$name:${i + 1}: ${m[0]}', m[1] != '@$packageVersion');
    }
  }
}

void main() {
  // `@next` and `@latest` move under a snippet already pasted: only the exact
  // version reproduces what printed it.
  test('a launch pinned to anything but the CLI version is stale', () {
    final found = _launches('x.md', [
      'npx -y @easyi18n.com/cli@$packageVersion mcp',
      '"args": ["-y", "@easyi18n.com/cli@next", "mcp"],',
      'npx -y @easyi18n.com/cli mcp',
      '# @easyi18n.com/cli',
      'npm install -g @easyi18n.com/cli',
    ]).toList();
    expect(found.map((l) => l.$2), [false, true, true]);
  });

  test('every npm launch in the agent docs pins the CLI version', () {
    final pages = [
      for (final root in _roots)
        ...Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.md')),
    ];
    final seen = <String>{};
    final stale = <String>[];
    for (final page in pages) {
      final name = p.posix.joinAll(
        p.split(p.relative(page.path, from: '../..')),
      );
      for (final (line, isStale) in _launches(name, page.readAsLinesSync())) {
        seen.add(name);
        if (isStale) stale.add(line);
      }
    }
    expect(seen, containsAll(_carriers));
    expect(
      stale,
      isEmpty,
      reason:
          'pin each to @easyi18n.com/cli@$packageVersion; the release bump '
          'moves these with version.dart (docs/guides/sdk-release.md)',
    );
  });
}
