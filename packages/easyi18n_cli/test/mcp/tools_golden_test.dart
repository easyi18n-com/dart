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

  // #2648: the login spends and publishes without an operation, a key in
  // EASYI18N_TOKEN does not, and an agent may read only the description. Each
  // one routes through authorize's answer, as rule 1 does, so a login the
  // server puts back under D17 still gets its approval_url.
  test('the descriptions name both credentials', () {
    final byName = {for (final tool in mcpTools) tool.name: tool.tool};
    String flat(String? text) => (text ?? '').replaceAll(RegExp(r'\s+'), ' ');
    for (final name in ['push', 'sync', 'publish', 'rollback', 'authorize',
        'add_language', 'status']) {
      final description = flat(byName[name]!.description);
      expect(description, contains('easyi18n login'), reason: name);
      expect(description, contains('EASYI18N_TOKEN'), reason: name);
    }
    for (final name in ['push', 'sync', 'publish', 'rollback']) {
      expect(flat(byName[name]!.description),
          contains('when it answers that none is needed'), reason: name);
      final operationId = byName[name]!.inputSchema.properties!['operation_id'];
      expect(flat(operationId!.description),
          contains('unless authorize answered that none is needed'),
          reason: '$name operation_id');
    }
  });

  test('every tool closes its input schema', () {
    for (final tool in mcpTools) {
      expect(tool.tool.inputSchema.additionalProperties, isFalse,
          reason: '${tool.name} would silently accept a `token` argument');
    }
  });

  // #2583: the login spends without an approval, so rule 1 stops promising
  // one for every spend and rule 4 sends the human to `easyi18n login`. Both
  // sit before the byte a truncating client cuts at.
  test('the safety rules name the login', () {
    final safety = mcpInstructions
        .substring(0, mcpInstructions.indexOf('Mental model'))
        .replaceAll(RegExp(r'\s+'), ' ');
    expect(safety, contains('`easyi18n login` in a terminal'));
    expect(safety, contains('Logged in, authorize says none is needed'));
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
        contains('Xcode .xcstrings, web and Angular JSON per locale, Android '
            'strings.xml (file-first)'));
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
