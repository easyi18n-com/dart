@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/mcp/instructions.dart';
import 'package:easyi18n_cli/src/mcp/server.dart';
import 'package:test/test.dart';

import '../support/transcript.dart' show regrabbingGoldens;

/// The tool surface an MCP client sees, pinned. Names, order, descriptions,
/// schemas and annotations are the contract: a client caches them, an agent
/// is prompted with them, and the plugin's skills are generated from them, so
/// a rename or a reordering has to be a reviewed diff and not a side effect.
void main() {
  final file = File('test/mcp/tools.golden.json');

  test('the registered tools match the golden', () {
    final actual = '${const JsonEncoder.withIndent('  ').convert([
      for (final tool in mcpTools) tool.tool,
    ])}\n';

    // Liveness: an empty or half-built list would otherwise compare clean
    // against a golden regrabbed from the same emptiness.
    expect(mcpTools, hasLength(greaterThanOrEqualTo(6)));
    expect(actual, contains('"inputSchema"'));

    if (regrabbingGoldens) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(actual);
      fail('Regrabbed ${file.path}. Review the diff and re-run without '
          'EASYI18N_REGRAB_GOLDENS.');
    }
    expect(file.existsSync(), isTrue,
        reason: 'missing ${file.path}; regrab with EASYI18N_REGRAB_GOLDENS=1');
    expect(actual, file.readAsStringSync());
  });

  test('every tool closes its input schema', () {
    for (final tool in mcpTools) {
      expect(tool.tool.inputSchema.additionalProperties, isFalse,
          reason: '${tool.name} would silently accept a `token` argument');
    }
  });

  test('instructions fit the budget and name every registered tool', () {
    expect(utf8.encode(mcpInstructions).length,
        lessThanOrEqualTo(kMcpInstructionsMaxBytes));
    expect(mcpInstructions.indexOf('Safety rules'),
        lessThan(mcpInstructions.indexOf('Mental model')),
        reason: 'safety must survive a client that truncates');
    // Every file-first adapter is named where a client reads before any
    // prompt.
    expect(mcpInstructions.replaceAll(RegExp(r'\s+'), ' '),
        contains('Xcode .xcstrings, web JSON per locale, Android strings.xml '
            '(file-first)'));
    // The `Tools:` sentence, split into whole words — not `contains` over the
    // whole text. The prose already says `pull` (3 times), `apply` (2) and
    // `status` (6), so a substring check stays green for exactly the names a
    // new tool has to add (feedback_substring_assertions_pass_by_accident).
    final from = mcpInstructions.indexOf('Tools:') + 'Tools:'.length;
    final listed = mcpInstructions
        .substring(from, mcpInstructions.indexOf('.', from))
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toSet();
    expect(listed, hasLength(greaterThanOrEqualTo(mcpTools.length)),
        reason: 'the Tools: sentence has to be there to be read');
    for (final tool in mcpTools) {
      expect(listed, contains(tool.name));
    }
  });
}
