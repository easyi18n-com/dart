import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'cli_output.dart';
import 'commands/apply_command.dart';
import 'commands/doctor_command.dart';
import 'commands/extract_command.dart';
import 'commands/formats_command.dart';
import 'commands/init_command.dart';
import 'commands/languages_command.dart';
import 'commands/login_command.dart';
import 'commands/mcp_command.dart';
import 'commands/pull_command.dart' as pull;
import 'commands/push_command.dart';
import 'commands/rollback_command.dart';
import 'commands/status_command.dart';
import 'commands/sync_command.dart';
import 'exceptions.dart';
import 'extract/tr_extractor.dart';
import 'logger.dart';

/// The `easyi18n` CLI. Wires up the commands and the global options - a
/// `--config` the commands share for config-path resolution, and a `--version`
/// the runner itself answers.
class Easyi18nCommandRunner extends CommandRunner<int> {
  Easyi18nCommandRunner({
    CliLogger? logger,
    CliOutput? output,
    TrExtractor? extractor,
    pull.ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  })
    : this._(_resolveOutput(logger, output), extractor, apiClientFactory, environment);

  static CliOutput _resolveOutput(CliLogger? logger, CliOutput? output) {
    if (logger != null && output != null) {
      throw ArgumentError('Pass either logger or output, not both.');
    }
    return output ?? CliOutput(logger: logger);
  }

  Easyi18nCommandRunner._(this.output, TrExtractor? extractor,
      pull.ApiClientFactory? apiClientFactory, Map<String, String>? environment)
    : super(
        'easyi18n',
        'Manage easyi18n translations from your project: pull translated '
            'files (Mode A) and push tr() sources for translation.',
      ) {
    argParser.addOption(
      'config',
      help: 'Path to the config file.',
      defaultsTo: 'easyi18n.yaml',
    );
    argParser.addFlag(
      'version',
      negatable: false,
      help: 'Print the easyi18n CLI version.',
    );
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Emit structured JSON output when supported by the command.',
    );
    addCommand(InitCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(FormatsCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(LanguagesCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(DoctorCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(pull.PullCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(ExtractCommand(output: output, extractor: extractor));
    addCommand(PushCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(SyncCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(ApplyCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(RollbackCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(StatusCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(McpCommand(output: output, apiClientFactory: apiClientFactory,
      extractor: extractor, environment: environment));
    addCommand(LoginCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(LogoutCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
    addCommand(WhoamiCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
  }

  final CliOutput output;

  @override
  Future<int?> run(Iterable<String> args) async {
    final ArgResults results;
    try {
      results = parse(args);
    } on UsageException catch (error) {
      // parse() fails before runCommand can read the flag, so the raw
      // arguments are the only place left to see what the caller asked for.
      output.json = _asksForJson(args);
      if (!output.json) rethrow;
      return _usageError(error);
    }
    try {
      return await runCommand(results);
    } on UsageException catch (error) {
      if (!output.json) rethrow;
      return _usageError(error);
    }
  }

  static bool _asksForJson(Iterable<String> args) =>
      args.takeWhile((arg) => arg != '--').contains('--json');

  int _usageError(UsageException error) {
    output.emitError(
      FatalCliException(error.message, exitCode: 64),
      code: 'usage_error',
    );
    return 64;
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    output.json = topLevelResults.flag('json');
    if (topLevelResults.flag('version')) {
      final command = topLevelResults.command?.name;
      if (command != null) {
        throw UsageException(
          '--version cannot be combined with a command. Run `easyi18n '
          '--version` on its own, or drop the flag to run `$command`.',
          usage,
        );
      }
      output.emitVersion();
      return 0;
    }
    var results = topLevelResults;
    Command<int>? command;
    var help = results.flag('help');
    while (results.command != null) {
      results = results.command!;
      command = (command?.subcommands ?? commands)[results.name];
      help = help || results.flag('help');
    }
    if (help) return super.runCommand(topLevelResults);
    if (output.json && command is! JsonPresenter) {
      output.emitError(
        FatalCliException(
          'This command does not support --json yet.',
          exitCode: 64,
        ),
        code: 'json_unsupported',
      );
      return 64;
    }
    try {
      // The loop above walked to the leaf, so a McpCommand here has no
      // subcommand: it is a bare `easyi18n mcp`, which is what clients launch.
      if (command is McpCommand && results.rest.isEmpty) {
        return await command.serve(
            configPath: topLevelResults.option('config')!,
            requireAgentKey: results.flag('require-agent-key'));
      }
      return await super.runCommand(topLevelResults);
    } on CliException catch (error) {
      if (!output.json) rethrow;
      output.emitError(error);
      return error.exitCode;
    } on FileSystemException catch (error) {
      if (!output.json) rethrow;
      final record = fileSystemError(error);
      output.emitError(record);
      return record.exitCode;
    }
  }
}
