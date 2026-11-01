// #752 — push and sync answer "is this catalog complete?" from two different
// wire shapes (translate: `exhausted: [lang]` per unit; sync: top-level
// `[{key, lang}]` rows). The DECISION is shared code (`fill_completeness.dart`)
// so it cannot drift; the DECODE cannot be shared without changing the server,
// so this differential pins it: ONE logical state (greeting/fr exhausted),
// each command served its producer's shape, and the two commands must agree —
// same refusal under the flag, same warning without it.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The one logical state both commands are asked about.
const _key = 'greeting';
const _lang = 'fr';
const _pairText = '$_key [$_lang]';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_differential');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  // ---- push side: unit-level `exhausted`, as `public_api.dart` emits it ----

  CommandRunner<int> pushRunner() {
    File(p.join(dir.path, 'easyi18n.yaml'))
        .writeAsStringSync('projectId: p1\n');
    final src = File(p.join(dir.path, 'lib', 'a.dart'))
      ..parent.createSync(recursive: true);
    src.writeAsStringSync("void f(c) => c.tr('Hello');\n");

    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/publish')) {
          return http.Response(
            jsonEncode(const {'versionId': 'v1', 'keyCount': 1}),
            201,
          );
        }
        if (req.url.path.endsWith('/meta')) {
          return http.Response(
            jsonEncode({'baseCode': 'en', 'formats': ['arb'], 'outputFormatsApiVersion': 1, 'currentVersionId': 'v0'}),
            200,
          );
        }
        final dryRun = req.url.queryParameters['dryRun'] == 'true';
        // The producer's unitView shape (`public_api.dart`): exhausted kept
        // OUT of `pending`, and the field present only because it is
        // non-empty.
        return http.Response(
          jsonEncode({
            'dryRun': dryRun,
            'trackingToken': null,
            'estimatedCredits': 0,
            'balance': 1000,
            'accepted': true,
            'baseCode': 'en',
            'targetLangs': [_lang],
            'units': [
              {
                'key': _key,
                'token': 't',
                'outcome': 'matched',
                'translated': <String>[],
                'pending': <String>[],
                'exhausted': [_lang],
              },
            ],
          }),
          200,
        );
      }),
    );
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PushCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
        confirm: (_) => true,
        wait: (_) async {},
      ),
    );
    return runner;
  }

  Future<int?> runPush({required bool requireComplete}) => pushRunner().run([
        '--config',
        p.join(dir.path, 'easyi18n.yaml'),
        'push',
        '--publish',
        if (requireComplete) '--require-complete',
        '--yes',
      ]);

  // ---- sync side: top-level rows, as `public_sync_api.dart` emits them ----

  CommandRunner<int> syncRunner() {
    File(p.join(dir.path, 'easyi18n.yaml')).writeAsStringSync(
      'projectId: p1\n'
      'format: xcstrings\n'
      'catalog: App/Localizable.xcstrings\n',
    );
    File(p.join(dir.path, 'App', 'Localizable.xcstrings'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"sourceLanguage":"en","strings":{"Hello":{}},"version":"1.0"}',
      );

    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/meta')) {
          return http.Response(
            jsonEncode({
              'baseCode': 'en',
              'outputFormatsApiVersion': 1, 'currentVersionId': 'v0',
              'languages': const [],
              'formats': ['xcstrings'],
            }),
            200,
          );
        }
        if (path.endsWith('/sync')) {
          // The producer's shape (`public_sync_api.dart`): `[{key, lang}]`
          // rows at the top level of the response.
          return http.Response(
            jsonEncode({
              'dryRun': req.url.queryParameters['dryRun'] == 'true',
              'format': 'xcstrings',
              'baseCode': 'en',
              'targetLangs': [_lang],
              'fillableLangs': [_lang],
              'created': 0,
              'updatedSources': 0,
              'matchedSources': 1,
              'updatedTranslations': 0,
              'unchangedTranslations': 0,
              'disabledOrphans': 0,
              'reenabled': 0,
              'failedEntries': const [],
              'exhausted': [
                {'key': _key, 'lang': _lang},
              ],
              'conflicts': const [],
              'conflictsTotal': 0,
              'onConflict': 'server',
              'diagnostics': const [],
              'trackingToken': null,
              'estimatedCredits': 0,
              'balance': 1000,
              'accepted': true,
            }),
            200,
          );
        }
        if (path.endsWith('/publish')) {
          return http.Response(
            jsonEncode(const {'versionId': 'v1', 'keyCount': 1}),
            201,
          );
        }
        if (path.endsWith('/translations')) {
          return http.Response(
            jsonEncode({
              'project': 'p1',
              'version': 'v1',
              'baseCode': 'en',
              'formats': ['xcstrings'],
              'files': {
                'xcstrings/Localizable.xcstrings':
                    '{"sourceLanguage":"en","strings":{"Hello":{}}}',
              },
            }),
            200,
          );
        }
        return http.Response('{"error":"not_found"}', 404);
      }),
    );
    return CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(
        SyncCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
          wait: (_) async {},
          random: Random(7),
        ),
      );
  }

  Future<int?> runSync({required bool requireComplete}) => syncRunner().run([
        '--config',
        p.join(dir.path, 'easyi18n.yaml'),
        'sync',
        if (requireComplete) '--require-complete',
        '--yes',
      ]);

  test('under --require-complete both commands refuse, naming the same pair',
      () async {
    final messages = <String>[];
    for (final run in [runPush, runSync]) {
      try {
        await run(requireComplete: true);
        fail('expected a CliException');
      } on CliException catch (e) {
        messages.add(e.message);
      }
    }
    for (final m in messages) {
      expect(m, contains('retry budget is spent'));
      // The ABSOLUTE list: exactly this one pair, nothing after it.
      expect(m, endsWith(': $_pairText'));
    }
    // Derived from one place: the refusal is the same sentence, not two
    // texts that happen to agree today.
    expect(messages[0], messages[1]);
  });

  test('without the flag both commands warn the same line and exit 0',
      () async {
    final warns = <String>[];
    for (final run in [runPush, runSync]) {
      final code = await run(requireComplete: false);
      expect(code, 0, reason: '$out\n$err');
      warns.add(err.toString());
      err.clear();
      out.clear();
    }
    for (final w in warns) {
      expect(
        w,
        contains(
          'Skipped exhausted pair(s) — retry them from the dashboard: '
          '$_pairText',
        ),
      );
    }
  });
}
