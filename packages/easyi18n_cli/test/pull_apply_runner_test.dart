import 'dart:convert';
import 'dart:io';
import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/apply/tr_rewriter.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:easyi18n_cli/src/xcstrings_merge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late CliLogger logger;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pull_apply_runner');
    logger = CliLogger(out: StringBuffer(), err: StringBuffer());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  for (final relative in [false, true]) {
  for (final dryRun in [true, false]) {
    test('pull relative=$relative dryRun=$dryRun reports actual or planned writes and prunes', () async {
      final configPath = '${dir.path}/easyi18n.yaml';
      final old = File('${dir.path}/out/old.json')..createSync(recursive: true);
      final tmp = File('${old.path}.tmp')..writeAsStringSync('stranded');
      CliState(format: 'json', output: 'out', files: ['old.json']).save(CliState.fileFor(configPath));
      final client = TranslationsApiClient(baseUrl: 'https://api.easyi18n.com', token: 'test',
        httpClient: MockClient((_) async => http.Response(jsonEncode({
          'version': '2026.09.08.3', 'files': {'json/es.json': '{}'},
        }), 200)));
      addTearDown(client.close);
      final outcome = await PullRunner(logger).pullOnceDetailed(
        client: client, config: Easyi18nConfig(ref: IdRef('id'), format: 'json', output: 'out'),
        configPath: relative ? p.relative(configPath) : configPath, projectId: 'id', version: null, lang: null, dryRun: dryRun,
      );
      expect(outcome.toJson(), {
        'version': '2026.09.08.3', 'destination': 'directory', 'key_policy': 'union',
        'dry_run': dryRun,
        'files_written': dryRun ? [] : ['${dir.path}/out/es.json'],
        'pruned': dryRun ? [] : [old.path, tmp.path],
        if (dryRun) 'files_planned': ['${dir.path}/out/es.json'],
        if (dryRun) 'prune_planned': [old.path, tmp.path],
        'coverage': null, 'coverage_basis': null,
        'project_dir': dir.path, 'base_url': 'https://api.easyi18n.com',
      });
      expect(old.existsSync(), dryRun);
      expect(tmp.existsSync(), dryRun);
      expect(File('${dir.path}/out/es.json').existsSync(), !dryRun);
    });
  }

  }

  for (final relative in [false, true]) {
  for (final dryRun in [false, true]) {
  for (final policy in XcstringsKeyPolicy.values) {
    test('catalog relative=$relative dryRun=$dryRun reports $policy', () async {
      final file = File('${dir.path}/Localizable.xcstrings');
      file.writeAsStringSync(jsonEncode({
        'sourceLanguage': 'en', 'version': '1.0', 'strings': {
          'Local': {}, 'Shared': {},
        },
      }));
      final client = TranslationsApiClient(baseUrl: 'https://api.easyi18n.com', token: 'test',
        httpClient: MockClient((_) async => http.Response(jsonEncode({
          'version': '2026.09.08.3', 'files': {'xcstrings/catalog.xcstrings': jsonEncode({
            'sourceLanguage': 'en', 'version': '1.0', 'strings': {'Shared': {}, 'Remote': {}},
          })},
        }), 200)));
      addTearDown(client.close);
      final outcome = await PullRunner(logger).pullOnceDetailed(
        client: client, config: Easyi18nConfig(ref: IdRef('id'), format: 'xcstrings',
          catalog: 'Localizable.xcstrings'),
        configPath: relative ? p.relative('${dir.path}/easyi18n.yaml') : '${dir.path}/easyi18n.yaml',
        projectId: 'id', version: null, lang: null, dryRun: dryRun, keyPolicy: policy,
      );
      expect(outcome.toJson()['destination'], 'catalog');
      expect(outcome.toJson()['key_policy'], policy == XcstringsKeyPolicy.union ? 'union' : 'local_owns');
      expect(outcome.toJson()['files_written'], dryRun ? [] : [file.path]);
      if (dryRun) expect(outcome.toJson()['files_planned'], [file.path]);
      final strings = jsonDecode(file.readAsStringSync())['strings'] as Map;
      expect(strings.keys, unorderedEquals(!dryRun && policy == XcstringsKeyPolicy.union
          ? ['Local', 'Shared', 'Remote'] : ['Local', 'Shared']));
    });
  }

  }
  }

  for (final failure in ['none', 'resolve', 'fetch', 'write', 'preview']) {
    test('apply $failure closes network before a separate local apply', () async {
      final events = <String>[];
      final client = _ClosingClient(MockClient((req) async {
        final resolve = req.url.path.endsWith('/resolve');
        events.add(resolve ? 'resolve' : 'fetch');
        return http.Response(jsonEncode(
          failure == (resolve ? 'resolve' : 'fetch') ? {'error': 'not_found'} : resolve
            ? {'projectId': 'resolved'} : {'changes': [{'key': 'hi', 'oldSource': 'Old', 'newSource': 'New'}]},
        ), failure == (resolve ? 'resolve' : 'fetch') ? 404 : 200);
      }), events);
      final file = File('${dir.path}/lib/main.dart')..createSync(recursive: true);
      file.writeAsStringSync("void f(c) => c.tr('Old');");
      final runner = ApplyRunner(rewriter: _WritingRewriter(events, failure == 'write'));
      Future<ApplyResult> execute() async {
        final plan = await runner.plan(
        config: Easyi18nConfig(ref: HandleRef('w', 'p'), baseUrl: 'https://untrusted.example'),
        configPath: '${dir.path}/easyi18n.yaml', token: 'explicit', logger: logger,
        apiClientFactory: ({required baseUrl, required token}) {
          expect(logger.err.toString(), contains('baseUrl points at untrusted.example'));
          expect(token, 'explicit');
          events.add('factory');
          return client;
        },
        );
        expect(events, ['factory', 'resolve', 'fetch', 'close']);
        expect(plan.rewrites.edits.single.oldSource, 'Old');
        expect(file.readAsStringSync(), "void f(c) => c.tr('Old');");
        return failure == 'preview' ? runner.apply(plan) : runner.apply(plan, write: true);
      }
      final result = execute();
      if (failure == 'none' || failure == 'preview') {
        final applied = await result;
        expect(applied.filesChanged, failure == 'preview' ? 0 : 1);
        expect(applied.toJson()['files_changed'], failure == 'preview' ? 0 : 1);
        expect(file.readAsStringSync(), failure == 'preview'
            ? "void f(c) => c.tr('Old');" : "void f(c) => c.tr('New');");
      } else {
        await expectLater(result, throwsA(failure == 'write'
            ? isA<StateError>() : isA<CliException>()));
      }
      expect(events, ['factory', 'resolve',
        if (failure != 'resolve') 'fetch',
        'close',
        if (failure != 'resolve' && failure != 'fetch' && failure != 'preview') 'write']);
    });
  }
}

class _ClosingClient extends TranslationsApiClient {
  _ClosingClient(http.Client client, this.events)
      : super(baseUrl: 'https://untrusted.example', token: 'test', httpClient: client);
  final List<String> events;
  @override
  void close() { events.add('close'); super.close(); }
}
class _WritingRewriter extends TrRewriter {
  _WritingRewriter(this.events, this.fail);
  final List<String> events;
  final bool fail;
  @override
  int applyPlan(RewritePlan plan) {
    events.add('write');
    if (fail) throw StateError('write failed');
    return super.applyPlan(plan);
  }
}
