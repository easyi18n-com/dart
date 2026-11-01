@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/delivery.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/mcp/deps.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'harness.dart';

void main() {
  for (final tool in ['doctor', 'extract', 'apply']) {
    for (final variant in ['direct', 'intermediate', 'dangling', 'internal']) {
      test('$tool refuses $variant source directory links', () async {
        final root = Directory.systemTemp.createTempSync('mcp_link_root');
        final outside = Directory.systemTemp.createTempSync('mcp_link_target');
        addTearDown(() => root.deleteSync(recursive: true));
        addTearDown(() => outside.deleteSync(recursive: true));
        File(
          p.join(root.path, 'easyi18n.yaml'),
        ).writeAsStringSync('projectId: fixture\n');
        File(
          p.join(root.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: app\n');
        final target = variant == 'internal'
            ? Directory(p.join(root.path, 'sources'))
            : outside;
        target.createSync(recursive: true);
        final nested = Directory(p.join(target.path, 'nested'))..createSync();
        final source = File(
          p.join(nested.path, 'source.dart'),
        )..writeAsStringSync("f(c) => c.tr('Original {n, plural, one{x}}');\n");
        final before = source.readAsStringSync();
        Link(p.join(root.path, 'lib')).createSync(
          variant == 'dangling' ? p.join(outside.path, 'missing') : target.path,
        );
        var clients = 0;
        final harness = await McpHarness.start(
          McpDeps(
            logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
            environment: const {'EASYI18N_TOKEN': 'eik_fixture'},
            currentDirectory: () => root.path,
            deliveryFactory: ({required baseUrl}) {
              clients++;
              return DeliveryClient(
                baseUrl: baseUrl,
                httpClient: MockClient((_) async => http.Response('{}', 404)),
              );
            },
            apiClientFactory: ({required baseUrl, required token}) {
              clients++;
              return TranslationsApiClient(
                baseUrl: baseUrl,
                token: token,
                httpClient: MockClient(
                  (_) async => http.Response(
                    jsonEncode({
                      'changes': [
                        {
                          'key': 'k',
                          'oldSource': 'Original {n, plural, one{x}}',
                          'newSource': 'Changed',
                        },
                      ],
                    }),
                    200,
                  ),
                ),
              );
            },
          ),
        );
        addTearDown(harness.shutdown);
        final result = await harness.call(tool, {
          if (variant == 'intermediate') 'source_dir': 'lib/nested',
          if (tool == 'apply') 'write': true,
        });
        expect(result.isError, isTrue);
        expect(
          (result.structuredContent!['error'] as Map)['code'],
          'source_dir_outside_project',
        );
        expect(clients, 0);
        expect(source.readAsStringSync(), before);
        expect(
          jsonEncode(result.structuredContent),
          isNot(contains('Original')),
        );
      });
    }
  }
  for (final dryRun in [false, true]) {
    test('pull refuses a locale-filtered catalog (dry_run: $dryRun)', () async {
      final root = Directory.systemTemp.createTempSync('mcp_catalog_lang');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'easyi18n.yaml')).writeAsStringSync(
        'projectId: fixture\nformat: xcstrings\ncatalog: Localizable.xcstrings\n',
      );
      final catalog = File(p.join(root.path, 'Localizable.xcstrings'))
        ..writeAsStringSync('{"sourceLanguage":"en","strings":{"Hello":{}}}');
      final before = catalog.readAsStringSync();
      var clients = 0;
      final harness = await McpHarness.start(
        McpDeps(
          logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
          environment: const {'EASYI18N_TOKEN': 'eik_fixture'},
          currentDirectory: () => root.path,
          apiClientFactory: ({required baseUrl, required token}) {
            clients++;
            return TranslationsApiClient(
              baseUrl: baseUrl,
              token: token,
              httpClient: MockClient(
                (_) async => http.Response(
                  jsonEncode({
                    'project': 'fixture',
                    'version': '2026.09.13.1',
                    'baseCode': 'en',
                    'formats': ['xcstrings'],
                    'files': {
                      'xcstrings/Localizable.xcstrings':
                          '{"sourceLanguage":"es","strings":{"Hola":{}}}',
                    },
                  }),
                  200,
                ),
              ),
            );
          },
        ),
      );
      addTearDown(harness.shutdown);
      final result = await harness.call('pull', {
        'lang': 'es',
        'dry_run': dryRun,
      });
      expect(result.isError, isTrue);
      expect(
        (result.structuredContent!['error'] as Map)['code'],
        'catalog_language_unsupported',
      );
      expect(clients, 0);
      expect(catalog.readAsStringSync(), before);
    });
  }
}
