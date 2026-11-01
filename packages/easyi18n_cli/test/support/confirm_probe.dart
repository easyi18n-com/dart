// Entry point for the piped-stdin confirmation test: a real process whose
// stdin is a pipe, so `stdin.hasTerminal` is false the way it is in CI.
// Usage: `<snapshot> <push|sync> <config> [--yes]`.
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main(List<String> args) async {
  final name = args[0];
  var spends = 0;
  TranslationsApiClient factory({
    required String baseUrl,
    required String token,
  }) => TranslationsApiClient(
    baseUrl: baseUrl,
    token: token,
    httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/meta')) {
        return http.Response('{}', 403);
      }
      final dryRun = request.url.queryParameters['dryRun'] == 'true';
      if (!dryRun) spends++;
      if (request.url.path.endsWith('/sync')) {
        return http.Response(jsonEncode({
          'dryRun': dryRun, 'format': 'xcstrings', 'baseCode': 'es',
          'targetLangs': ['en'], 'fillableLangs': ['en'], 'created': 1,
          'updatedSources': 0, 'matchedSources': 0, 'updatedTranslations': 0,
          'unchangedTranslations': 0, 'disabledOrphans': 0, 'reenabled': 0,
          'failedEntries': [], 'exhausted': [], 'conflicts': [],
          'conflictsTotal': 0, 'onConflict': 'server', 'diagnostics': [],
          'trackingToken': null, 'estimatedCredits': 10, 'balance': 100,
          'accepted': true,
        }), 200);
      }
      return http.Response(jsonEncode({
        'dryRun': dryRun, 'estimatedCredits': 10, 'balance': 100,
        'accepted': true, 'baseCode': 'en', 'targetLangs': ['fr'],
        'units': [{'key': 'hello', 'token': 't', 'outcome': 'created',
          'translated': <String>[], 'pending': ['fr']}],
      }), 200);
    }),
  );
  const environment = {'EASYI18N_TOKEN': 'eik_test'};
  final command = switch (name) {
    'push' => PushCommand(output: CliOutput(),
      environment: environment, apiClientFactory: factory) as Command<int>,
    'sync' => SyncCommand(output: CliOutput(),
      environment: environment, apiClientFactory: factory),
    _ => throw ArgumentError.value(name, 'command'),
  };
  final runner = CommandRunner<int>('easyi18n', '')
    ..argParser.addOption('config')
    ..addCommand(command);
  final code = await runner.run(['--config', args[1], name, ...args.skip(2)]);
  stdout.writeln('real spends: $spends');
  exitCode = code ?? 0;
}
