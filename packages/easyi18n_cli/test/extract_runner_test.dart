import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/extract/source_unit.dart';
import 'package:easyi18n_cli/src/extract/tr_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class FakeExtractor extends TrExtractor {
  String? scanned;
  String? relative;

  @override
  ExtractionResult extractFromDirectory(Directory dir, {String? relativeTo}) {
    scanned = dir.path;
    relative = relativeTo;
    return ExtractionResult(
      units: List.generate(101, (i) => ExtractedUnit(
        source: 'Source $i', ctx: 'noun', file: 'lib/a.dart', line: i + 1,
      )),
      dynamics: List.generate(101, (i) => DynamicUnit(
        file: 'lib/a.dart', line: i + 102, snippet: 'c.tr(name$i)',
      )),
      filesScanned: 1,
    );
  }
}

void main() {
  test('JSON redacts data while preserving the in-memory extraction', () async {
    final dir = Directory.systemTemp.createTempSync('extract_sanitized');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = File(p.join(dir.path, 'easyi18n.yaml'))
      ..writeAsStringSync('projectId: demo\n');
    File(p.join(dir.path, 'lib/app.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void f(c, name) {\n'
        "  c.tr('Your key eik_ABCDEFGHIJKLMNOPQR\\u001b', "
        "ctx: 'eip_ABCDEFGHIJKLMNOPQR');\n"
        "  c.tr(name, ctx: 'eik_ABCDEFGHIJKLMNOPQR');\n}\n");
    final result = ExtractRunner().run(configPath: config.path);
    expect(result.extraction.units.single.source,
        'Your key eik_ABCDEFGHIJKLMNOPQR\x1b');
    final out = StringBuffer();
    final runner = Easyi18nCommandRunner(
      output: CliOutput(out: out, err: StringBuffer()),
    );
    expect(await runner.run(['--config', config.path, 'extract', '--json']), 0);
    final json = jsonDecode(out.toString());
    expect(json['units'][0]['source'], 'Your key [REDACTED]');
    expect(json['units'][0]['ctx'], '[REDACTED]');
    expect(json['dynamics'][0]['snippet'], "c.tr(name, ctx: '[REDACTED]')");
    expect(result.extraction.units.single.source,
        'Your key eik_ABCDEFGHIJKLMNOPQR\x1b');
  });

  test('real command runner uses the injected extractor', () async {
    final dir = Directory.systemTemp.createTempSync('extract_injection');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = File(p.join(dir.path, 'easyi18n.yaml'))
      ..writeAsStringSync('projectId: demo\n');
    final extractor = FakeExtractor();
    final out = StringBuffer();
    final err = StringBuffer();
    final logger = CliLogger(out: out, err: err);
    final runner = Easyi18nCommandRunner(
      output: CliOutput(logger: logger), extractor: extractor,
    );
    expect(await runner.run(['--config', config.path, 'extract', '--json']), 0);
    expect(jsonDecode(out.toString())['total'], 101);
    expect(extractor.scanned, p.join(dir.path, 'lib'));
    expect(err.toString(), contains('101 tr() call(s)'));
    expect(out.toString().trim().split('\n'), hasLength(1));
    out.clear();
    err.clear();
    expect(await runner.run(['--config', config.path, 'extract']), 0);
    expect(out.toString(), contains('Scanned 1 file(s)'));
    expect(err.toString(), contains('101 tr() call(s)'));
  });

  test('runner resolves the project and caps lists without losing totals', () {
    final dir = Directory.systemTemp.createTempSync('extract_runner');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = File(p.join(dir.path, 'easyi18n.yaml'))
      ..writeAsStringSync('projectId: demo\nbaseUrl: http://localhost:8080\n');
    final extractor = FakeExtractor();
    final result = ExtractRunner(extractor: extractor).run(
      configPath: p.relative(config.path), sourceDir: 'src',
    );
    expect(result.projectDir, p.normalize(dir.absolute.path));
    expect(extractor.scanned, p.join(result.projectDir, 'src'));
    expect(extractor.relative, result.projectDir);
    final json = result.toJson();
    expect(json['project_dir'], result.projectDir);
    expect(json['base_url'], 'http://localhost:8080');
    expect(json['total'], 101);
    expect(json['added'], 101);
    expect(json['orphans'], 0);
    expect(json['units'], hasLength(100));
    expect((json['units'] as List).first, {
      'source': 'Source 0', 'ctx': 'noun', 'file': 'lib/a.dart', 'line': 1,
    });
    expect(json['truncated'], isTrue);
    expect(json['dynamics_count'], 101);
    expect(json['dynamics'], hasLength(100));
    expect(json['dynamics_truncated'], isTrue);
    expect(result.toJson(limit: 101)['truncated'], isFalse);
    expect(result.toJson(limit: 101)['dynamics_truncated'], isFalse);
    expect(result.toJson(limit: 0)['units'], isEmpty);
    expect(() => result.toJson(limit: -1), throwsA(
      isA<RangeError>().having((e) => e.name, 'name', 'limit'),
    ));
    expect(File(p.join(dir.path, 'easyi18n.lock')).existsSync(), isFalse);
  });
}
