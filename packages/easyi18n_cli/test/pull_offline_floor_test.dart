import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/contract.dart';
import 'package:easyi18n_cli/src/delivery.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// A Mode B app bundles assets/easyi18n/ and the SDK loads
// assets/easyi18n/<locale>.json before any network call. `init` creates the
// folder empty, so until pull fills it Flutter web logs a 404 per locale at
// start (acceptance run 5 of #1422, #1835).
void main() {
  late Directory dir;
  late CliLogger logger;
  late List<String> deliveryRequests;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pull_offline_floor');
    logger = CliLogger(out: StringBuffer(), err: StringBuffer());
    deliveryRequests = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const tokenIndex = {'tok-hello': 'hello'};
  Map<String, Object?> bundle(String locale, Map<String, String> messages) => {
    'schemaVersion': kBundleSchemaVersion,
    'locale': locale,
    'bundleHash': computeBundleHash(
      schemaVersion: kBundleSchemaVersion,
      locale: locale,
      messages: messages,
      tokenIndex: tokenIndex,
    ),
    'messages': messages,
    'tokenIndex': tokenIndex,
  };
  final served = {
    'en': bundle('en', {'hello': 'Hello'}),
    'es': bundle('es', {'hello': 'Hola'}),
  };

  // [fault]: `corrupt` serves es with content that does not hash to its
  // address; `swapped` points es at the en bundle, which does; `unpublished`
  // answers the manifest with the 404 of a project with no live version.
  MockClient delivery(String fault) => MockClient((req) async {
    deliveryRequests.add(req.url.path);
    if (req.url.path == '/v1/projects/pid/manifest') {
      if (fault == 'unpublished') {
        return http.Response(
          jsonEncode({'error': 'not_published', 'message': 'nothing live'}),
          404,
        );
      }
      if (fault == 'status') {
        return http.Response(jsonEncode({'revision': 'r1', 'locales': {}}), 503);
      }
      if (fault == 'revision') {
        return http.Response(jsonEncode({'locales': {}}), 200);
      }
      if (fault == 'traversal') {
        final escaped = bundle('../escaped', {'hello': 'Outside'});
        return http.Response(jsonEncode({
          'revision': 'r1',
          'locales': {'../escaped': {
            'url': '/escaped', 'bundleHash': escaped['bundleHash'],
          }},
        }), 200);
      }
      final pointed = {'en': 'en', 'es': fault == 'swapped' ? 'en' : 'es'};
      return http.Response(
        jsonEncode({
          'project': 'pid',
          'revision': '2026.09.28.1',
          'tokenAlgoVersions': ['m1'],
          'locales': {
            for (final e in pointed.entries)
              e.key: {
                'version': '2026.09.28.1',
                'bundleHash': served[e.value]!['bundleHash'],
                'url':
                    '/v1/projects/pid/bundles/${e.value}/'
                    '${served[e.value]!['bundleHash']}.json',
              },
          },
        }),
        200,
      );
    }
    if (req.url.path == '/escaped') {
      return http.Response(jsonEncode(bundle('../escaped', {'hello': 'Outside'})), 200);
    }
    final locale = RegExp(r'/bundles/(\w+)/').firstMatch(req.url.path)?[1];
    final body = served[locale];
    if (body == null) return http.Response('not found', 404);
    if (fault == 'corrupt' && locale == 'es') {
      return http.Response(
        jsonEncode({
          ...body,
          'messages': {'hello': 'Stale'},
        }),
        200,
      );
    }
    return http.Response(jsonEncode(body), 200);
  });

  void writePubspec({bool floor = true}) =>
      File('${dir.path}/pubspec.yaml').writeAsStringSync(
        '''
name: app
dependencies:
  flutter:
    sdk: flutter
flutter:
${floor ? '  assets:\n    - assets/easyi18n/\n' : '  uses-material-design: true\n'}''',
      );

  Future<PullOutcome> pull({
    String mode = 'b',
    String? lang,
    String? version,
    bool dryRun = false,
    String fault = 'none',
    String? source,
    void Function(PullOutcome applied)? onApplied,
  }) async {
    final api = TranslationsApiClient(
      baseUrl: 'http://localhost:8080',
      token: 'test',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': '2026.09.28.1',
            'files': {
              'arb/app_en.arb': '{"hello": "Hello"}',
              'arb/app_es.arb': '{"hello": "Hola"}',
            },
          }),
          200,
        ),
      ),
    );
    addTearDown(api.close);
    return PullRunner(
      logger,
      deliveryFactory: ({required baseUrl}) {
        expect(baseUrl, 'http://localhost:8080');
        return DeliveryClient(baseUrl: baseUrl, httpClient: delivery(fault));
      },
    ).pullOnceDetailed(
      client: api,
      config: Easyi18nConfig(
        ref: IdRef('pid'),
        mode: mode,
        source: source,
        baseUrl: 'http://localhost:8080',
      ),
      configPath: '${dir.path}/easyi18n.yaml',
      projectId: 'pid',
      version: version,
      lang: lang,
      dryRun: dryRun,
      onApplied: onApplied,
    );
  }

  File floor(String locale) => File('${dir.path}/assets/easyi18n/$locale.json');

  for (final suffix in ['', '.tmp']) {
    test('floor destination protects source suffix=$suffix before writing', () async {
      writePubspec();
      final source = File('${floor('es').path}$suffix')
        ..createSync(recursive: true)..writeAsStringSync('local source');
      await expectLater(pull(source: 'assets/easyi18n/es.json$suffix'),
          throwsA(isA<CliException>().having((e) => e.code, 'code', 'source_collision')));
      expect(source.readAsStringSync(), 'local source');
      expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isFalse);
      expect(floor('en').existsSync(), isFalse);
    });
  }

  test('Mode B bakes every published locale into assets/easyi18n', () async {
    writePubspec();
    final outcome = await pull();
    for (final locale in ['en', 'es']) {
      expect(jsonDecode(floor(locale).readAsStringSync()), served[locale]);
    }
    expect(outcome.files, containsAll([floor('en').path, floor('es').path]));
    expect(File('${dir.path}/lib/l10n/app_es.arb').existsSync(), isTrue);
    expect(logger.out.toString(), isNot(contains('gen-l10n')));
    expect(logger.out.toString(), contains('Baked the offline floor (2 locale(s))'));
  });

  // The floor is written last, after the .arb files: a locale that fails
  // leaves the ones before it on disk, and the caller is told which.
  test('a floor write that fails reports the files already written', () async {
    writePubspec();
    Directory('${floor('es').path}.tmp').createSync(recursive: true);
    PullOutcome? applied;
    await expectLater(pull(onApplied: (a) => applied = a),
        throwsA(isA<FileSystemException>()));
    expect(applied!.files, [
      '${dir.path}/lib/l10n/app_en.arb',
      '${dir.path}/lib/l10n/app_es.arb',
      floor('en').path,
    ]);
  });

  for (final (fault, reason) in [
    ('corrupt', 'content does not match its address'),
    ('swapped', 'serves "en" as es'),
    ('unpublished', 'HTTP 404'),
    ('status', 'HTTP 503'),
    ('revision', 'HTTP 200'),
  ]) {
    test('a $fault delivery fails before any write', () async {
      writePubspec();
      await expectLater(
        pull(fault: fault),
        throwsA(
          isA<CliException>().having(
            (e) => e.message,
            'message',
            contains(reason),
          ),
        ),
      );
      expect(floor('en').existsSync(), isFalse);
      expect(Directory('${dir.path}/lib/l10n').existsSync(), isFalse);
    });
  }

  test('a traversing manifest locale is refused before any write', () async {
    writePubspec();
    await expectLater(pull(fault: 'traversal'), throwsA(isA<CliException>()));
    expect(File('${dir.path}/assets/escaped.json').existsSync(), isFalse);
    expect(Directory('${dir.path}/lib/l10n').existsSync(), isFalse);
  });

  test('itemized assets must register every pulled locale', () async {
    writePubspec();
    final pubspec = File('${dir.path}/pubspec.yaml');
    pubspec.writeAsStringSync(pubspec.readAsStringSync()
        .replaceFirst('- assets/easyi18n/', '- assets/easyi18n/en.json'));
    await expectLater(pull(), throwsA(isA<CliException>()
        .having((e) => e.message, 'message', contains('es.json'))));
    expect(Directory('${dir.path}/assets').existsSync(), isFalse);
    expect(Directory('${dir.path}/lib/l10n').existsSync(), isFalse);
  });

  test('itemized assets can bake their registered locale alone', () async {
    writePubspec();
    final pubspec = File('${dir.path}/pubspec.yaml');
    pubspec.writeAsStringSync(pubspec.readAsStringSync()
        .replaceFirst('- assets/easyi18n/', '- assets/easyi18n/es.json'));
    await pull(lang: 'es');
    expect(jsonDecode(floor('es').readAsStringSync()), served['es']);
    expect(floor('en').existsSync(), isFalse);
  });

  for (final pubspec in <String?>[
    null, '[broken', '[]', 'flutter: true', 'flutter: {assets: true}',
    'flutter: {assets: [42, assets/other/]}',
  ]) {
    test('unregistered pubspec $pubspec makes no delivery request', () async {
      if (pubspec != null) File('${dir.path}/pubspec.yaml').writeAsStringSync(pubspec);
      await pull();
      expect(deliveryRequests, isEmpty);
      expect(Directory('${dir.path}/assets').existsSync(), isFalse);
    });
  }

  test('--lang bakes only that locale', () async {
    writePubspec();
    await pull(lang: 'es');
    expect(floor('es').existsSync(), isTrue);
    expect(floor('en').existsSync(), isFalse);
  });

  test('--dry-run plans the floor and writes nothing', () async {
    writePubspec();
    final outcome = await pull(dryRun: true);
    expect(outcome.toJson()['files_planned'], contains(floor('es').path));
    expect(Directory('${dir.path}/assets').existsSync(), isFalse);
  });

  for (final (name, mode, registered, version) in [
    ('Mode A', 'a', true, null),
    ('a pubspec without the floor', 'b', false, null),
    ('a pinned --version', 'b', true, '2026.09.27.1'),
  ]) {
    test('$name bakes no floor and never asks delivery', () async {
      writePubspec(floor: registered);
      await pull(mode: mode, version: version);
      expect(Directory('${dir.path}/assets').existsSync(), isFalse);
      expect(deliveryRequests, isEmpty);
    });
  }
}
