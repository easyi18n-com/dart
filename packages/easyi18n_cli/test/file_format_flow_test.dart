import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/commands/sync_command.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late List<http.Request> requests;
  late List<String> events;
  late List<String> formats;
  late Object? capability;
  late Object? metaOverride;
  late int metaStatus;
  late int adoptStatus;
  late int publishStatus;
  late int estimate;
  late bool consent;
  late bool created;
  late bool configuredRace;
  late bool clearFormatsOnPublish;
  late String? pullError;
  late bool retryFails;
  late String format;
  late bool resetOnWatch;
  late bool invalidMetaOnWatch;
  const catalog = '{"sourceLanguage":"en","version":"1.0",'
      '"strings":{"Hello":{"localizations":{"en":{"stringUnit":'
      '{"state":"translated","value":"Hello"}}}}}}';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('file-format-flow');
    out = StringBuffer(); err = StringBuffer();
    requests = []; events = []; formats = [];
    capability = 1; metaOverride = null;
    metaStatus = 200; adoptStatus = 200; publishStatus = 201;
    estimate = 1000; consent = true; created = true;
    configuredRace = false; clearFormatsOnPublish = false; pullError = null; retryFails = false;
    format = 'arb'; resetOnWatch = false; invalidMetaOnWatch = false;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int?> run(String command, {List<String> flags = const [],
      String mode = 'a', bool empty = false, bool json = false}) async {
    format = command == 'sync' ? 'xcstrings' : 'arb';
    final config = File('${dir.path}/easyi18n.yaml')..writeAsStringSync(
      'projectId: p1\nmode: $mode\nformat: $format\noutput: out\n'
      '${command == 'sync' ? 'catalog: Localizable.xcstrings\n' : ''}');
    File('${dir.path}/Localizable.xcstrings').writeAsStringSync(catalog);
    Directory('${dir.path}/lib').createSync();
    File('${dir.path}/lib/main.dart').writeAsStringSync(empty ? '' :
        "void main() { context.tr('Hello'); }");
    var fetches = 0;
    final output = CliOutput(out: out, err: err)..json = json;
    TranslationsApiClient factory({required String baseUrl, required String token}) =>
          TranslationsApiClient(baseUrl: baseUrl, token: token,
            wait: (_) async {},
            httpClient: MockClient((r) async {
              requests.add(r);
              final route = r.url.path.split('/').last;
              final dry = r.url.queryParameters['dryRun'] == 'true' ||
                  (route == 'translate' && jsonDecode(r.body)['dryRun'] == true);
              events.add('$route${dry ? ':preview' : ''}');
              http.Response response(Object body, [int status = 200]) =>
                  http.Response(jsonEncode(body), status);
              if (route == 'meta') {
                if (metaStatus != 200) {
                  return response({'error': 'forbidden', 'message': 'metadata unavailable'}, metaStatus);
                }
                return response(metaOverride ?? {'formats': formats,
                  'outputFormatsApiVersion': capability, 'baseCode': 'en',
                  'currentVersionId': 'v1'});
              }
              if (route == 'output-formats') {
                expect(jsonDecode(r.body), {'format': format, 'mode': 'adopt'});
                if (adoptStatus != 200) {
                  return response({'error':
                    adoptStatus == 403 ? 'forbidden' : 'output_format_conflict',
                    'message': 'adoption rejected'}, adoptStatus);
                }
                formats = [format];
                return response({'formats': formats, 'created': created});
              }
              if (route == 'sync') {
                return response({'dryRun': dry,
                'baseCode': 'en', 'targetLangs': [], 'fillableLangs': [],
                'created': 1, 'estimatedCredits': estimate,
                'balance': 100000, 'accepted': true});
              }
              if (route == 'translate') {
                return response({
                'dryRun': dry, 'units': [], 'estimatedCredits': dry ? estimate : 0,
                'balance': 100000, 'accepted': true,
              });
              }
              if (route == 'publish') {
                if (configuredRace) formats = ['json'];
                if (clearFormatsOnPublish) formats = [];
                if (publishStatus != 201 || configuredRace) {
                  return response({
                  'error': 'output_config_conflict', 'message': 'publish rejected',
                }, 409);
                }
                return response({'versionId': 'v1', 'keyCount': 1}, 201);
              }
              if (route == 'translations') {
                fetches++;
                if (pullError != null && (fetches == 1 || retryFails)) {
                  return response({'error': pullError, 'message': 'original failure'},
                      pullError == 'invalid_argument' || pullError == 'no_formats'
                          ? 400 : pullError == 'export_collision' ? 409 : 404);
                }
                return response({'version': 'v1', 'baseCode': 'en',
                  'files': {format == 'xcstrings' ? 'Localizable.xcstrings' : 'en.arb':
                    format == 'xcstrings' ? catalog : '{"hello":"Hello"}'}});
              }
              throw StateError('Unexpected $route');
            }));
    bool confirm(String _) { events.add('consent'); return consent; }
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config')
      ..addCommand(command == 'sync'
        ? SyncCommand(output: output, apiClientFactory: factory,
            environment: const {'EASYI18N_TOKEN': 'eik_x'}, confirm: confirm,
            wait: (_) async {})
        : command == 'push'
        ? PushCommand(output: output, apiClientFactory: factory,
            environment: const {'EASYI18N_TOKEN': 'eik_x'}, confirm: confirm,
            wait: (_) async {})
        : PullCommand(output: output, apiClientFactory: factory,
            environment: const {'EASYI18N_TOKEN': 'eik_x'},
            watchCyclesForTest: 3, sleeper: (_) async {
              if (resetOnWatch) formats = [];
              if (invalidMetaOnWatch) metaOverride = [];
            }));
    try {
      return await runner.run(['--config', config.path, command, ...flags]);
    } on CliException catch (e) {
      output.emitError(e);
      return e.exitCode;
    }

  }

  for (final command in ['sync', 'push']) {
    List<String> flags([List<String> extra = const []]) =>
        [if (command == 'push') '--publish', ...extra];
    test('$command adopts after consent and before ingestion', () async {
      expect(await run(command, flags: flags()), 0);
      final real = command == 'sync' ? 'sync' : 'translate';
      expect(events.indexOf('meta'), lessThan(events.indexOf('$real:preview')));
      expect(events.indexOf('consent'), lessThan(events.indexOf('output-formats')));
      expect(events.indexOf('output-formats'), lessThan(events.indexOf(real)));
      expect(events.indexOf(real), lessThan(events.indexOf('publish')));
      expect(jsonDecode(requests.firstWhere((r) => r.url.path.endsWith('/publish')).body)
          ['requiredOutputFormat'], format);
      expect(formats, [format]);
      expect(out.toString(), contains('Enabled output format "$format" on this project.'));
      expect(out.toString(), isNot(contains('rollback')));
    });
    for (final failure in ['403', '503', 'shape', 'missing', 'version', 'formats']) {
      test('$command metadata $failure prevents preview and every write', () async {
        switch (failure) {
          case '403': metaStatus = 403;
          case '503': metaStatus = 503;
          case 'shape': metaOverride = [];
          case 'missing': capability = null;
          case 'version': capability = 2;
          case 'formats': metaOverride = {'outputFormatsApiVersion': 1};
        }
        expect(await run(command, flags: flags(['--yes'])), 1);
        expect(requests.every((r) => r.method == 'GET'), isTrue);
        expect(formats, isEmpty);
      });
    }
    for (final decline in [true, false]) {
      test('$command ${decline ? 'decline' : 'budget refusal'} does not adopt', () async {
        consent = !decline;
        await run(command, flags: flags(decline ? [] : ['--max-credits', '0']));
        expect(events, isNot(contains('output-formats')));
        expect(events, isNot(contains('publish')));
        expect(events.where((e) => e == 'sync' || e == 'translate'), isEmpty);
      });
    }
    test('$command failed adopt prevents real ingestion', () async {
      adoptStatus = 409;
      expect(await run(command, flags: flags(['--yes'])), 1);
      expect(events.where((e) => e == 'sync' || e == 'translate'), isEmpty);
      expect(events, isNot(contains('publish')));
      expect(formats, isEmpty);
    });
    test('$command publish race preserves confirmed effect and error', () async {
      configuredRace = true;
      expect(await run(command, flags: flags(['--yes']), json: command == 'sync'), 1);
      final message = command == 'sync' ? jsonDecode(out.toString())['error'] : null;
      if (message != null) {
        expect(message['code'], 'output_config_conflict');
        expect(message['statusCode'], 409);
        expect(message['message'], contains('configuration was updated'));
        expect(message.keys, unorderedEquals(['message', 'code', 'statusCode', 'retryable']));
      } else {
        expect(err.toString(), contains('configuration was updated'));
      }
      expect(formats, ['json']);
    });
    // The disk write comes after the adoption, which is not rolled back: the
    // record has to say so, like any other failure after it.
    test('$command disk failure after adoption keeps the adoption', () async {
      Directory(command == 'sync'
          ? '${dir.path}/Localizable.xcstrings.tmp'
          : '${dir.path}/easyi18n.lock').createSync();
      expect(await run(command, flags: flags(['--yes']), json: true), 1);
      final record = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(record['error']['code'], 'file_system');
      expect(record['error']['message'], contains('configuration was updated'));
      expect(record[command == 'sync' ? 'delivery' : 'pushed'], isNotNull);
      expect(formats, [format]);
    });
  }
  for (final initiallyConfigured in [false, true]) {
    test('sync delivery never recovers a post-publish format error '
        '(configured: $initiallyConfigured)', () async {
      formats = initiallyConfigured ? ['xcstrings'] : [];
      clearFormatsOnPublish = true;
      pullError = 'invalid_argument';
      expect(await run('sync', flags: ['--yes'], json: true), 1);
      expect(events.where((e) => e == 'meta'), hasLength(1));
      expect(events.where((e) => e == 'output-formats'),
          hasLength(initiallyConfigured ? 0 : 1));
      expect(events.last, 'translations');
      expect(formats, isEmpty);
      final error = jsonDecode(out.toString())['error'];
      expect(error['code'], 'invalid_argument');
      expect(error['statusCode'], 400);
      expect(error['message'], contains('original failure'));
      if (!initiallyConfigured) {
        expect(error['message'], contains('configuration was updated'));
      }
    });
  }
  test('sync dry-run reports conditional adoption without a write', () async {
    expect(await run('sync', flags: ['--dry-run'], json: true), 0);
    final result = jsonDecode(out.toString());
    expect(result['output_format'], {'format': 'xcstrings', 'state': 'wouldAdopt', 'created': false});
    expect(events, ['meta', 'sync:preview']);
  });
  test('sync with local Mode B still adopts for its file delivery', () async {
    expect(await run('sync', mode: 'b', flags: ['--yes']), 0);
    expect(events, contains('output-formats'));
  });
  test('sync no-publish does not consult formats', () async {
    expect(await run('sync', flags: ['--no-publish', '--yes']), 0);
    expect(events, ['sync:preview', 'sync']);
  });
  test('empty Mode A push adopts immediately before publish', () async {
    expect(await run('push', empty: true, flags: ['--publish']), 0);
    expect(events, ['meta', 'output-formats', 'publish']);
  });
  test('Mode B push retains narrow scopes and omits format requirement', () async {
    metaStatus = 403;
    expect(await run('push', mode: 'b', empty: true, flags: ['--publish']), 0);
    expect(events, ['meta', 'publish']);
    expect(jsonDecode(requests.last.body), isNot(contains('requiredOutputFormat')));
  });
  for (final failure in ['invalid_argument', 'no_formats']) {
    test('pull recovers $failure once preserving version and lang', () async {
      pullError = failure;
      expect(await run('pull', flags: ['--version', 'pinned', '--lang', 'es']), 0);
      expect(events, ['translations', 'meta', 'output-formats', 'translations']);
      expect(requests.last.url, requests.first.url);
      expect(requests.last.url.queryParameters, containsPair('version', 'pinned'));
      expect(requests.last.url.queryParameters, containsPair('lang', 'es'));
      expect(Directory('${dir.path}/out').listSync(), hasLength(1));
    });
  }
  test('watch attempts automatic adoption at most once', () async {
    pullError = 'invalid_argument'; retryFails = true; resetOnWatch = true;
    expect(await run('pull', flags: ['--watch']), 1);
    expect(events.where((e) => e == 'output-formats'), hasLength(1));
    expect(err.toString(), contains('Automatic output format adoption is unavailable'));
  });
  test('watch metadata failure retains a prior confirmed adoption', () async {
    pullError = 'invalid_argument'; invalidMetaOnWatch = true;
    expect(await run('pull', flags: ['--watch']), 1);
    expect(events.where((e) => e == 'output-formats'), hasLength(1));
    expect(err.toString(), contains('configuration was updated'));
  });
  test('watch never repeats a failed adoption', () async {
    pullError = 'invalid_argument'; retryFails = true; adoptStatus = 403;
    expect(await run('pull', flags: ['--watch']), 1);
    expect(events.where((e) => e == 'output-formats'), hasLength(1));
  });
  test('healthy pull performs one request', () async {
    expect(await run('pull'), 0);
    expect(events, ['translations']);
  });
  test('pull retry failure is final and carries adoption in JSON', () async {
    pullError = 'invalid_argument'; retryFails = true;
    expect(await run('pull', json: true), 1);
    expect(events, ['translations', 'meta', 'output-formats', 'translations']);
    final error = jsonDecode(out.toString())['error'];
    expect(error['code'], 'invalid_argument');
    expect(error['message'], contains('configuration was updated'));
  });
  // The gate refuses after the recovered pull wrote the files. The pull record
  // has no `output_format`, so the annotated message is the only trace of the
  // format this run enabled.
  test('pull --require-complete refusal keeps the adoption in JSON', () async {
    pullError = 'invalid_argument';
    expect(await run('pull', flags: ['--require-complete'], json: true), 1);
    expect(events, ['translations', 'meta', 'output-formats', 'translations']);
    final record = jsonDecode(out.toString());
    expect(record['files_written'], hasLength(1));
    expect(record['error']['message'], contains('per-language coverage'));
    expect(record['error']['message'], contains('configuration was updated'));
  });
  test('pull with enabled format preserves unrelated invalid_argument', () async {
    pullError = 'invalid_argument'; formats = ['arb'];
    expect(await run('pull', json: true), 1);
    expect(jsonDecode(out.toString())['error']['message'], contains('original failure'));
    expect(events, ['translations', 'meta']);
  });
  for (final unsupported in [null, 2, '1']) {
    for (final code in ['invalid_argument', 'no_formats']) {
      test('pull preserves $code without capability $unsupported', () async {
        capability = unsupported;
        pullError = code;
        expect(await run('pull', json: true), 1);
        final error = jsonDecode(out.toString())['error'];
        expect(error['code'], code);
        expect(error['statusCode'], 400);
        expect(error['retryable'], false);
        expect(error['message'], contains('original failure'));
        expect(events, ['translations', 'meta']);
        expect(formats, isEmpty);
      });
    }
  }
  for (final failure in ['403', '503', 'shape', 'formats']) {
    test('pull recovery rejects metadata $failure without writing', () async {
      pullError = 'invalid_argument';
      switch (failure) {
        case '403': metaStatus = 403;
        case '503': metaStatus = 503;
        case 'shape': metaOverride = [];
        case 'formats': metaOverride = {'outputFormatsApiVersion': 1};
      }
      expect(await run('pull', json: true), 1);
      final error = jsonDecode(out.toString())['error'];
      expect(error['message'], isNot(contains('original failure')));
      expect(error['code'], isNot('invalid_argument'));
      if (metaStatus != 200) expect(error['statusCode'], metaStatus);
      expect(events, ['translations', ...List.filled(metaStatus == 503 ? 3 : 1, 'meta')]);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(formats, isEmpty);
    });
  }
  test('pull configured conflict names explicit command', () async {
    pullError = 'invalid_argument'; formats = ['json'];
    expect(await run('pull'), 1);
    expect(err.toString(), contains('easyi18n formats add arb'));
    expect(err.toString(), contains('Set `format:` in `easyi18n.yaml`'));
    expect(events, ['translations', 'meta']);
  });
  test('pull dry-run neither adopts nor claims downloaded files', () async {
    pullError = 'invalid_argument';
    expect(await run('pull', flags: ['--dry-run'], json: true), 1);
    expect(events, ['translations', 'meta']);
    expect(jsonDecode(out.toString())['error']['code'], 'output_format_pending');
    expect(Directory('${dir.path}/out').existsSync(), isFalse);
  });
  test('read-only pull names write scope without pretending success', () async {
    pullError = 'invalid_argument'; adoptStatus = 403;
    expect(await run('pull', json: true), 1);
    final error = jsonDecode(out.toString())['error'];
    expect(error['statusCode'], 403);
    expect(error['message'], contains('write scope'));
    expect(formats, isEmpty);
    expect(events, ['translations', 'meta', 'output-formats']);
  });
  for (final error in ['not_published', 'version_not_found', 'lang_not_found', 'export_collision']) {
    test('pull preserves $error without consulting metadata', () async {
      pullError = error;
      expect(await run('pull', json: true), 1);
      expect(events, ['translations']);
      expect(jsonDecode(out.toString())['error']['code'], error);
    });
  }
}
