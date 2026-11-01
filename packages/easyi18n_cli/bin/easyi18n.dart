import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';

Future<void> main(List<String> args) async {
  final output = CliOutput();
  try {
    final code = await Easyi18nCommandRunner(output: output).run(args) ?? 0;
    exit(code);
  } on CliException catch (e) {
    output.emitError(e);
    exit(e.exitCode);
  } on UsageException catch (e) {
    // The parser quotes the argument it refused, which can be a pasted key.
    output.logger.err.writeln(CliLogger.sanitize('$e'));
    exit(64);
  }
}
