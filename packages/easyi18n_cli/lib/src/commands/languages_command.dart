import 'dart:io';

import 'package:args/command_runner.dart';

import '../cli_output.dart';
import '../config.dart';
import '../exceptions.dart';
import '../languages_runner.dart';
import '../session.dart';
import 'pull_command.dart' show ApiClientFactory;

class LanguagesCommand extends Command<int> {
  LanguagesCommand({
    required CliOutput output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) {
    addSubcommand(LanguagesAddCommand(output: output,
      apiClientFactory: apiClientFactory, environment: environment));
  }

  @override
  String get name => 'languages';
  @override
  String get description => 'Manage the project target languages.';
}

class LanguagesAddCommand extends Command<int> with JsonPresenter {
  LanguagesAddCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    Map<String, String>? environment,
  }) : _apiClientFactory = apiClientFactory,
       _environment = environment ?? Platform.environment {
    argParser
      ..addOption('fill-mode', allowed: ['ai', 'manual'],
        help: 'Whether AI fills the language. Omitted, a live language '
          'keeps its mode and a new one gets ai.')
      ..addOption('token', help: 'API key (eik_) with the write scope. '
        'Defaults to \$EASYI18N_TOKEN, then your easyi18n login.');
  }

  final CliOutput output;
  final ApiClientFactory? _apiClientFactory;
  final Map<String, String> _environment;

  @override
  String get name => 'add';
  @override
  String get description =>
      'Add a target language, or revive one that was removed.';
  @override
  String get invocation => 'easyi18n languages add <code>';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      throw CliException('Exactly one language code is required. '
        'Usage: $invocation');
    }
    final configPath = globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: output.logger);
    final token = requireToken(token: argResults!['token'] as String?,
      environment: _environment, scope: 'write', baseUrl: config.baseUrl);
    final result = await LanguageAddRunner().run(
      config: config, configPath: configPath, token: token,
      logger: output.logger, code: rest.single,
      fillMode: argResults!['fill-mode'] as String?,
      apiClientFactory: _apiClientFactory,
    );
    output.logger.info('Language "${result.code}" is on the project '
      '(fill mode: ${result.fillMode}).');
    output.logger.info(result.fillMode == 'manual'
      ? 'AI fills skip it; its translations come from the dashboard or your files.'
      : 'The next push or sync fills it with AI.');
    output.logger.info('Next: easyi18n status (requires the read scope).');
    if (output.json) output.emit(result.toJson());
    return 0;
  }
}
