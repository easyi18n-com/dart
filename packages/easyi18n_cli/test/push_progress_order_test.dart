@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/push_command.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/transcript.dart';

/// What `push --publish` prints BETWEEN polls of the fill, and in what order.
///
/// The transcript goldens pin the whole run; this pins the loop on its own,
/// so a refactor that keeps every line but re-runs the announcement, drops a
/// per-poll line, or hoists the progress line above the announcement is red
/// here even if the surrounding output moved for an unrelated reason.
///
/// The fake records the length of the sink at the moment each request
/// arrives, which is what turns "these lines exist" into "these lines were
/// emitted in this cycle". Measured 2026-09-06: the per-poll line
/// `N string(s) pending...` had ZERO assertions of any kind in the suite.
void main() {
  late Directory dir;
  late Transcript transcript;

  setUp(
    () => dir = Directory.systemTemp.createTempSync('easyi18n_cli_progress'),
  );
  tearDown(() => dir.deleteSync(recursive: true));

  test('one progress line per poll, announced exactly once, first', () async {
    transcript = Transcript();
    final configPath = p.join(dir.path, 'easyi18n.yaml');
    File(configPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('projectId: proj_abc\n');
    File(p.join(dir.path, 'lib', 'app.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("void f(c) => c.tr('Hello');\n");

    /// Sink length at the moment each poll arrived. THREE polls, because one
    /// sample cannot pin an order and two cannot tell "once" from "every
    /// time".
    const pollsUntilDone = 3;
    final pollMarks = <int>[];
    var pushed = false;
    var polls = 0;

    final mock = MockClient((req) async {
      if (req.url.path.endsWith('/publish')) {
        return http.Response(
          jsonEncode({'versionId': '2026.07.09.9', 'keyCount': 1}),
          201,
        );
      }
      if (req.url.path.endsWith('/meta')) {
        return http.Response(
          jsonEncode({
            'baseCode': 'en',
            'mode': null,
            'currentVersionId': '2026.01.01',
            'languages': const [
              {'code': 'en', 'name': 'English', 'isBase': true,
                'fillMode': 'ai'},
              {'code': 'fr', 'name': 'French', 'isBase': false,
                'fillMode': 'ai'},
            ],
          }),
          200,
        );
      }
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final units = (body['units'] as List).cast<Map<String, dynamic>>();
      final dryRun = req.url.queryParameters['dryRun'] == 'true';
      var pending = <String>['fr'];
      final priced = !pushed;
      if (dryRun && pushed) {
        polls++;
        pollMarks.add(transcript.length);
        if (polls >= pollsUntilDone) pending = [];
      }
      if (!dryRun) pushed = true;
      return http.Response(
        jsonEncode({
          'dryRun': dryRun,
          'trackingToken': dryRun ? null : 'job_1',
          'estimatedCredits': priced ? units.length * 10 : 0,
          'balance': 1000,
          'accepted': true,
          'baseCode': 'en',
          'targetLangs': ['fr'],
          'units': [
            for (final u in units)
              {
                'key': 'k_${u['source']}',
                'token': 't',
                'outcome': 'created',
                'translated': <String>[],
                'pending': pending,
              },
          ],
        }),
        200,
      );
    });

    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml')
      ..addCommand(
        PushCommand(
          output: CliOutput(
            logger: CliLogger(out: transcript.out, err: transcript.err),
          ),
          apiClientFactory:
              ({required String baseUrl, required String token}) =>
                  TranslationsApiClient(
                    baseUrl: baseUrl,
                    token: token,
                    httpClient: mock,
                  ),
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          confirm: (_) => true,
          wait: (_) async {},
        ),
      );

    final code = await runner.run([
      '--config',
      configPath,
      'push',
      '--publish',
      '--yes',
    ]);

    final lines = [for (final r in transcript.records) r.line];
    expect(code, 0, reason: lines.join('\n'));
    expect(
      pollMarks,
      hasLength(pollsUntilDone),
      reason: 'the fill loop did not poll three times: ${lines.join('\n')}',
    );

    /// The lines emitted between the arrival of poll [k] and the arrival of
    /// the next poll (or the end of the run for the last one).
    List<String> between(int k) => lines.sublist(
      pollMarks[k],
      k + 1 < pollMarks.length ? pollMarks[k + 1] : lines.length,
    );

    // Nothing at all has been said about the fill when the first poll goes
    // out: the announcement is a consequence of the poll, not a preamble.
    expect(
      lines.sublist(0, pollMarks.first),
      isNot(contains('Waiting for the AI fill to complete...')),
    );

    // The announcement comes FIRST, then that poll's progress line.
    expect(between(0), [
      'Waiting for the AI fill to complete...',
      '  1 string(s) pending...',
    ]);

    // The second poll adds exactly one line, and does not re-announce.
    expect(between(1), ['  1 string(s) pending...']);

    // The third poll finds the fill done: no progress line, just the close.
    expect(between(2), contains('Fill complete.'));
    expect(between(2), isNot(contains('  1 string(s) pending...')));

    // Every progress line went to stdout, and the whole loop printed on one
    // channel - a line that moved to stderr would still be in `lines`.
    expect(
      transcript.records
          .where((r) => r.line.endsWith('string(s) pending...'))
          .map((r) => r.channel),
      everyElement('out'),
    );
  });
}
