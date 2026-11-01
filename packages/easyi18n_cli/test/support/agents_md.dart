import 'dart:io';

import 'package:easyi18n_cli/src/adapters/stack_adapter.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapters.dart';
import 'package:easyi18n_cli/src/agents_md.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:path/path.dart' as p;

/// The `AGENTS.md` that `init` leaves next to [configPath], rendered from the
/// config on disk and the adapter `doctor` would pick. Call it after the last
/// write to the config: the block names the project, so a later edit stales it.
void writeAgentsBlock(String configPath, {StackAdapter? adapter}) {
  final root = p.dirname(configPath);
  final config = Easyi18nConfig.load(File(configPath));
  File(p.join(root, kAgentsMdFile)).writeAsStringSync(
      '# AGENTS.md\n\n${renderAgentsBlock(config, adapter ?? adapterFor(root, config))}');
}
