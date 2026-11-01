import 'dart:io';

import 'package:args/command_runner.dart';

import '../cli_output.dart';
import '../config.dart';
import '../exceptions.dart';
import '../output_format.dart';
import '../session.dart';
import 'pull_command.dart' show ApiClientFactory;

class FormatsCommand extends Command<int> {
  FormatsCommand({
    required CliOutput output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) {
    addSubcommand(FormatsAddCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
  }

  @override
  String get name => 'formats';
  @override
  String get description => 'Manage the project output formats.';
}

class FormatsAddCommand extends Command<int> with JsonPresenter {
  FormatsAddCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _apiClientFactory = apiClientFactory,
       _environment = environment ?? Platform.environment {
    argParser.addOption('token', help: 'API key (eik_) with the write scope. '
      'Defaults to \$EASYI18N_TOKEN.');
  }

  final CliOutput output;
  final ApiClientFactory? _apiClientFactory;
  final Map<String, String> _environment;

  @override
  String get name => 'add';
  @override
  String get description => 'Enable an output format without removing others.';
  @override
  String get invocation => 'easyi18n formats add <id>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      throw CliException('Exactly one format id is required. Usage: $invocation');
    }
    final configPath = globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: output.logger);
    final token = requireToken(token: argResults!['token'] as String?,
      environment: _environment, scope: 'write');
    final result = await OutputFormatRunner().run(
      config: config, configPath: configPath, token: token, logger: output.logger,
      format: rest.single, apiClientFactory: _apiClientFactory,
    );
    output.logger.info(result.created
      ? 'Output formats updated (configuration changed or materialized).'
      : 'Output format already enabled; configuration unchanged.');
    output.logger.info('Enabled: ${result.enabled.join(', ')}');
    if (result.created) {
      output.logger.info('The enabled formats apply to every version, including '
        'pinned versions. Export collisions are checked when downloading.');
    }
    output.logger.info('Next: easyi18n status (requires the read scope).');
    if (output.json) output.emit(result.toJson());
    return 0;
  }
}
