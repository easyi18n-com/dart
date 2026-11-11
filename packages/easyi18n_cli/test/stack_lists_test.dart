@TestOn('vm')
library;

import 'dart:io';

import 'package:easyi18n_cli/src/adapters/stack_adapters.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The CLI's public texts. Their hand-written lists of stacks fell behind
/// [supportedStacks] three times (#2520, #2524, #2592). ci.yml's `cli` filter
/// and tool/analyze.sh list these paths, so an edit to one of them runs this.
const _roots = [
  'docs-site/docs/developers/cli',
  'docs-site/docs/developers/agents',
  'docs-site/static/llms.txt',
  'packages/easyi18n_cli/README.md',
  'integrations/agents',
];

/// Two stacks are an example ("a web or Xcode project"); three are a list.
const _listAt = 3;

/// A row of a table or an item of a list starts a part of its block.
final _part = RegExp(r'^\s*(?:\||[-*+] |\d+\. )');

/// Where one sentence ends and the next starts.
final _sentenceEnd = RegExp(r'(?<=[.!?])\s+(?=[A-Z`[*])');

/// A heading, paragraph, table or list. [parts] are its rows or items, or
/// else its sentences; empty when it has only one.
class _Block {
  _Block(this.file, this.line, this.text, this.parts);

  final String file;
  final int line;
  final String text;
  final List<_Block> parts;

  /// This block and every part under it.
  Iterable<_Block> get all sync* {
    yield this;
    for (final part in parts) {
      yield* part.all;
    }
  }
}

List<_Block> _sentences(String file, int line, String text) {
  final sentences = <_Block>[];
  var start = 0;
  for (final end in [..._sentenceEnd.allMatches(text), null]) {
    final at = line + '\n'.allMatches(text.substring(0, start)).length;
    final sentence = text.substring(start, end?.start ?? text.length);
    sentences.add(_Block(file, at, sentence, const []));
    if (end != null) start = end.end;
  }
  return sentences.length < 2 ? const [] : sentences;
}

List<_Block> _blocks(String file, List<String> lines) {
  _Block block(List<int> at, [List<_Block>? parts]) {
    final text = [for (final i in at) lines[i]].join('\n');
    return _Block(
      file,
      at.first + 1,
      text,
      parts ?? _sentences(file, at.first + 1, text),
    );
  }

  final blocks = <_Block>[];
  void close(List<int> chunk) {
    if (chunk.isEmpty) return;
    final parts = <List<int>>[];
    for (final i in chunk) {
      if (parts.isEmpty || _part.hasMatch(lines[i])) {
        parts.add([i]);
      } else {
        parts.last.add(i);
      }
    }
    blocks.add(
      parts.length > 1
          ? block(chunk, [for (final at in parts) block(at)])
          : block(chunk),
    );
  }

  var chunk = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isNotEmpty && !line.startsWith('#')) {
      chunk.add(i);
      continue;
    }
    close(chunk);
    chunk = [];
    if (line.startsWith('#')) close([i]);
  }
  close(chunk);
  return blocks;
}

/// The [stacks] that [text] names, each as a whole word in any case.
/// A table's Stack column names its entries; descriptions cannot supply one.
Set<String> _named(String text, List<String> stacks) {
  final rows = text.split('\n').map((line) => line.split('|')).toList();
  final column = rows.first.indexWhere((cell) => cell.trim() == 'Stack');
  if (column >= 0) {
    text = rows
        .skip(1)
        .map((row) => row.length > column ? row[column] : '')
        .join('\n');
  }
  return {
    for (final stack in stacks)
      if (RegExp(
        '\\b${RegExp.escape(stack)}\\b',
        caseSensitive: false,
      ).hasMatch(text))
        stack,
  };
}

/// The blocks that list stacks: each that names [_listAt] of them and more
/// than any one of its parts does. A sentence lists them, and so does a
/// table whose rows name one stack each; a row that only repeats its one
/// list sentence does not count twice.
List<_Block> _lists(List<_Block> blocks, List<String> stacks) => [
  for (final block in blocks) ...[
    ..._lists(block.parts, stacks),
    if (_named(block.text, stacks).length >= _listAt &&
        block.parts.every(
          (part) =>
              _named(part.text, stacks).length <
              _named(block.text, stacks).length,
        ))
      block,
  ],
];

/// A block the census finds as a list: the smallest one in [file] around
/// [anchor], or with [whole] the table, list or paragraph around it.
class _Known {
  const _Known(
    this.file,
    this.anchor, {
    this.whole = false,
    this.leftOut = const {},
    this.why = '',
  });

  /// Names stacks without listing them.
  const _Known.notAList(this.file, this.anchor, this.why, {this.whole = false})
    : leftOut = null;

  final String file;
  final String anchor;
  final bool whole;

  /// What the list leaves out on purpose, for [why]; null when it is no list.
  final Set<String>? leftOut;
  final String why;

  _Block? find(List<_Block> blocks) {
    final around = [
      for (final block in blocks)
        for (final part in block.all)
          if (part.file == file && part.text.contains(anchor)) part,
    ]..sort((a, b) => a.text.length.compareTo(b.text.length));
    if (around.isEmpty) return null;
    return whole ? around.last : around.first;
  }
}

/// Every list of stacks in [_roots] today, and the blocks that look like one.
/// Whoever adds the next stack to the CLI names it in each list, or here in
/// what that list leaves out.
const _known = [
  _Known('docs-site/docs/developers/cli/commands.md', '| `--stack <name>` |'),
  _Known(
    'docs-site/docs/developers/cli/commands.md',
    'stacks pick their own',
    leftOut: {'flutter'},
    why: 'a Flutter config defaults to arb',
  ),
  _Known(
    'docs-site/docs/developers/cli/commands.md',
    'See [Sync an Xcode String Catalog]',
    leftOut: {'flutter'},
    why: 'Flutter pushes from its code, not by sync',
  ),
  _Known(
    'docs-site/docs/developers/cli/overview.md',
    '`--stack xcode`, `--stack web`',
  ),
  _Known(
    'docs-site/docs/developers/agents/mcp-server.md',
    '`stack` (`flutter`',
  ),
  _Known(
    'docs-site/docs/developers/agents/mcp-server.md',
    '### File-first tools',
    leftOut: {'flutter'},
    why: 'Flutter is code-first',
  ),
  _Known(
    'docs-site/docs/developers/agents/overview.md',
    '| Family | Stack |',
    whole: true,
  ),
  _Known(
    'docs-site/docs/developers/agents/overview.md',
    'In a web, Android or Angular project',
    leftOut: {'flutter', 'xcode'},
    why: 'an Xcode pull writes into the catalog, a Flutter one by its mode',
  ),
  _Known(
    'docs-site/docs/developers/agents/agents-md.md',
    '| Stack | Rules |',
    whole: true,
  ),
  _Known.notAList(
    'docs-site/docs/developers/agents/agents-md.md',
    '| Flutter, Mode B |',
    'the Android permission and web CORS a Flutter app needs',
  ),
  _Known(
    'docs-site/docs/developers/agents/android.md',
    'Other apps that carry an `android/` folder',
    whole: true,
    leftOut: {'xcode'},
    why: 'an Xcode project has no android/ folder',
  ),
  _Known('docs-site/static/llms.txt', 'adapters today:'),
  _Known(
    'docs-site/static/llms.txt',
    '- [Web apps with JSON catalogs]',
    whole: true,
    leftOut: {'flutter', 'xcode'},
    why: 'the agents section has a page for web, Android and Angular only',
  ),
  _Known.notAList(
    'docs-site/static/llms.txt',
    '- [Flutter SDK]',
    'pages; the formats item names Angular JSON and Android XML',
    whole: true,
  ),
  _Known(
    'integrations/agents/claude-code/skills/setup/SKILL.md',
    'If `scope_snippet` comes back',
    leftOut: {'xcode', 'android'},
    why: 'an Xcode or Android app needs no wiring',
  ),
  _Known('packages/easyi18n_cli/README.md', 'to let the CLI pick'),
  _Known('packages/easyi18n_cli/README.md', 'A Flutter project (`tr()` calls)'),
];

/// The stacks each list in [blocks] leaves out that [known] does not
/// excuse, and the entries of [known] the text no longer matches.
({List<String> missing, List<String> stale}) _census(
  List<_Block> blocks,
  List<String> stacks, [
  List<_Known> known = _known,
]) {
  final lists = _lists(blocks, stacks);
  final excused = <_Block, Set<String>?>{};
  final stale = <String>[];
  for (final entry in known) {
    final block = entry.find(blocks);
    if (block == null || !lists.contains(block)) {
      stale.add('${entry.file}: "${entry.anchor}" finds no list of stacks');
      continue;
    }
    if (excused.containsKey(block)) {
      stale.add(
        '${entry.file}:${block.line}: another entry of _known names this '
        'list',
      );
      continue;
    }
    if (entry.leftOut == null &&
        _named(block.text, stacks).length == stacks.length) {
      stale.add(
        '${entry.file}:${block.line}: names every stack, so it is a '
        'list',
      );
      continue;
    }
    final named = entry.leftOut?.intersection(_named(block.text, stacks));
    if (named != null && named.isNotEmpty) {
      stale.add(
        '${entry.file}:${block.line}: names ${named.join(', ')}, '
        'which _known says it leaves out',
      );
      continue;
    }
    excused[block] = entry.leftOut;
  }
  final missing = <String>[];
  for (final list in lists) {
    if (excused.containsKey(list) && excused[list] == null) continue;
    final absent = stacks.toSet()
      ..removeAll(_named(list.text, stacks))
      ..removeAll(excused[list] ?? const {});
    if (absent.isNotEmpty) {
      missing.add('${list.file}:${list.line}: ${absent.join(', ')}');
    }
  }
  return (missing: missing, stale: stale);
}

/// Every block of the files under [_roots].
List<_Block> _docs() => [
  for (final root in _roots)
    for (final file
        in FileSystemEntity.isFileSync(p.join('../..', root))
            ? [File(p.join('../..', root))]
            : Directory(p.join('../..', root))
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.md')))
      ..._blocks(
        p.posix.joinAll(p.split(p.relative(file.path, from: '../..'))),
        file.readAsLinesSync(),
      ),
];

void main() {
  for (final marker in ['-', '*', '+', '1.']) {
    test('a $marker list item cannot borrow stacks from the next item', () {
      // Lowercase, so "1." ends no sentence and only the item split parts them.
      final lines = ['$marker flutter, xcode, web', '$marker android, angular'];
      final lists = _lists(_blocks('x.md', lines), supportedStacks);
      expect([for (final list in lists) _named(list.text, supportedStacks)], [
        {'flutter', 'xcode', 'web'},
        supportedStacks.toSet(),
      ]);
    });
  }

  test('a Stack column can follow another column and have incomplete rows', () {
    expect(
      _named(
        '| Family | Stack | Rules |\n'
        '| code-first | Flutter | Android and web |\n'
        '| web\n'
        '| file-first | Xcode | Angular |',
        supportedStacks,
      ),
      {'flutter', 'xcode'},
    );
  });

  for (final stack in ['web', 'android']) {
    test('a table cannot borrow $stack from another row description', () {
      const file = 'docs-site/docs/developers/agents/agents-md.md';
      final lines = File('../../$file').readAsLinesSync();
      final blocks = _blocks(
        file,
        lines
            .where((line) => !line.toLowerCase().startsWith('| $stack |'))
            .toList(),
      );
      final census = _census(blocks, supportedStacks, const [
        _Known(file, '| Stack | Rules |', whole: true),
        _Known.notAList(
          file,
          '| Flutter, Mode B |',
          'the Android permission and web CORS a Flutter app needs',
        ),
      ]);
      expect(census.stale, isEmpty);
      expect(census.missing, [endsWith(': $stack')]);
    });
  }

  test('a sentence that names three stacks lists them, and so does a table '
      'whose rows name more together', () {
    final blocks = _blocks('x.md', [
      'Flutter and Xcode are examples.',
      '',
      '# Flutter, Xcode and web',
      '| Stack | Rules |',
      '| Flutter | the Android and web builds |',
      '| Xcode | an android webhook |',
      '',
      '- Flutter',
      '- Android, angular',
      '',
      'Flutter, xcode or web. Android needs CLI 1.0.0.',
      '',
      '| `--stack` | flutter, xcode or web |',
      '| `--mode` | flutter only |',
    ]);
    expect(
      [
        for (final list in _lists(blocks, [
          'flutter',
          'xcode',
          'web',
          'android',
          'angular',
        ]))
          '${list.line}: ${list.text.split('\n').first}',
      ],
      [
        '3: # Flutter, Xcode and web',
        '5: | Flutter | the Android and web builds |',
        '8: - Flutter',
        '11: Flutter, xcode or web.',
        '11: Flutter, xcode or web. Android needs CLI 1.0.0.',
        '13: | `--stack` | flutter, xcode or web |',
      ],
    );
  });

  test('an entry of _known that no longer matches its text is stale', () {
    final blocks = _blocks('x.md', [
      'flutter, xcode and web',
      '',
      'flutter, xcode, web, android and angular',
      '',
      'flutter and xcode only',
    ]);
    final census = _census(
      blocks,
      ['flutter', 'xcode', 'web', 'android', 'angular'],
      const [
        _Known('x.md', 'gone'),
        _Known('x.md', 'xcode only'),
        _Known('x.md', 'xcode and web', leftOut: {'web', 'android'}),
        _Known.notAList('x.md', 'and angular', 'a list after all'),
        _Known('x.md', 'android and angular'),
        _Known('x.md', 'web, android'),
      ],
    );
    expect(census.stale, [
      'x.md: "gone" finds no list of stacks',
      'x.md: "xcode only" finds no list of stacks',
      'x.md:1: names web, which _known says it leaves out',
      'x.md:3: names every stack, so it is a list',
      'x.md:3: another entry of _known names this list',
    ]);
    expect(census.missing, ['x.md:1: android, angular']);
  });

  test('every list of stacks in the CLI docs names each supported stack', () {
    final census = _census(_docs(), supportedStacks);
    expect(
      [...census.missing, ...census.stale],
      isEmpty,
      reason:
          'name each missing stack in its list, or add the list to _known '
          'with what it leaves out and why; an entry of _known that finds no '
          'list needs its anchor updated, or dropping',
    );
  });

  test(
    'a stack the CLI gains is missing from every list until it is named',
    () {
      final blocks = _docs();
      final missing = _census(blocks, [...supportedStacks, 'unity']).missing;
      for (final known in _known) {
        if (known.leftOut == null) continue;
        final list = known.find(blocks)!;
        expect(missing, contains('${list.file}:${list.line}: unity'));
      }
    },
  );
}
