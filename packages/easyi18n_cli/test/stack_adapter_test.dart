import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/adapters/stack_adapter.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/doctor_report.dart' show DoctorFindings;
import 'package:test/test.dart';

class _Adapter implements StackAdapter {
  _Adapter({this.ignoreCalls = 0});
  final int ignoreCalls;
  @override
  String get stack => 'test-stack';
  @override
  String get family => 'file-first';
  @override
  bool detect(String root) => true;
  @override
  String resolveMode(String root, String? mode, void Function(InitStep) report) => mode ?? 'a';
  @override
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report) =>
      (format: null, catalog: null, output: null, source: null,
          sourceLayout: null);
  @override
  String nextCommand(Easyi18nConfig config) => 'test-next';
  @override
  String agentsMdSection(Easyi18nConfig config) => '### Test\n\n- adapter rule\n';
  @override
  void initSteps(InitContext context, Easyi18nConfig config) {
    for (var i = 0; i < ignoreCalls; i++) { context.ignoreDerivedState(); }
    final file = File('${context.root}/catalog');
    context.write(file, 'adapter output');
    context.report('created', file.path, 'adapter action');
  }
  @override
  Future<void> doctorChecks({required String root, required String sourcePath,
    required Easyi18nConfig config, required DoctorFindings findings}) async {
    findings.ok('catalog', '$root/$sourcePath', 'adapter check');
  }
}

void main() {
  late Directory dir;
  late CliLogger logger;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('stack_adapter');
    logger = CliLogger(out: StringBuffer(), err: StringBuffer());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('both runners consume another adapter without Flutter actions', () async {
    final path = '${dir.path}/easyi18n.yaml';
    final adapter = _Adapter();
    final steps = <InitStep>[];
    final init = InitRunner().run(configPath: path, logger: logger,
        projectId: 'p1', adapter: adapter, onStep: steps.add);
    expect(init.stack, 'test-stack');
    expect(init.family, 'file-first');
    expect(init.next, 'test-next');
    expect(init.steps, orderedEquals(steps));
    expect(init.steps.map((s) => s.target), [path, '${dir.path}/catalog',
        '${dir.path}/.gitignore', '${dir.path}/AGENTS.md']);
    expect(File('${dir.path}/AGENTS.md').readAsStringSync(), contains('- adapter rule\n'));
    expect(File('${dir.path}/catalog').readAsStringSync(), 'adapter output');
    expect(Directory('${dir.path}/assets').existsSync(), isFalse);
    final findings = <DoctorFinding>[];
    final doctor = await DoctorRunner().run(configPath: path, logger: logger,
        sourceDir: 'custom', adapter: adapter, environment: {}, onFinding: findings.add);
    expect(doctor.toJson()['stack'], 'test-stack');
    expect(doctor.toJson()['family'], 'file-first');
    expect(doctor.findings, orderedEquals(findings));
    expect(doctor.findings.map((f) => f.check),
        ['config', 'credential', 'agents_md', 'catalog', 'completeness']);
    expect(doctor.findings[2].level, 'ok');
    expect(doctor.findings[3].subject, '${dir.path}/custom');
    expect(doctor.verdict, 'unverified');
    expect(doctor.unchecked, 1);
    expect(logger.out.toString(), isEmpty);
  });

  for (final calls in [0, 2]) {
    for (final dryRun in [false, true]) {
      test('core ignores derived state once, adapter calls=$calls dryRun=$dryRun', () {
        final result = InitRunner().run(configPath: '${dir.path}/easyi18n.yaml',
          logger: logger, projectId: 'p1', adapter: _Adapter(ignoreCalls: calls),
          dryRun: dryRun);
        expect(result.steps.where((step) => step.target.endsWith('/.gitignore')), hasLength(1));
        final ignore = File('${dir.path}/.gitignore');
        expect(ignore.existsSync(), !dryRun);
        if (!dryRun) expect(ignore.readAsStringSync(), contains('.easyi18n/'));
        expect(File('${dir.path}/easyi18n.yaml').existsSync(), !dryRun);
        expect(File('${dir.path}/catalog').existsSync(), !dryRun);
      });
    }
  }

  test('Mode A coverage cannot be omitted by a custom adapter', () async {
    final path = '${dir.path}/easyi18n.yaml';
    File(path).writeAsStringSync('projectId: p1\nmode: a\n');
    final report = await DoctorRunner().run(configPath: path, logger: logger,
        adapter: _Adapter(), environment: {});
    expect(report.findings.last.check, 'completeness');
    expect(report.verdict, 'unverified');
  });

  test('Mode B custom adapter does not run Mode A coverage', () async {
    final path = '${dir.path}/easyi18n.yaml';
    InitRunner().run(configPath: path, logger: logger,
        projectId: 'p1', mode: 'b', adapter: _Adapter());
    final report = await DoctorRunner().run(configPath: path, logger: logger,
      adapter: _Adapter(), environment: {}, token: 'test-token',
      apiClientFactory: ({required baseUrl, required token}) =>
        throw StateError('Mode A coverage must not run'));
    expect(report.findings.map((finding) => finding.check),
        ['config', 'credential', 'agents_md', 'catalog']);
    expect(report.verdict, 'passed');
  });

  test('runner is reusable, immutable, absolute and sanitizes only JSON', () {
    const secret = 'eik_abcdefghijklmnopqrstuvwxyz';
    final runner = InitRunner();
    final path = '${dir.path}/easyi18n.yaml';
    final first = runner.run(configPath: path, logger: logger, projectId: secret,
        adapter: _Adapter());
    expect(first.steps.first.detail, contains(secret));
    expect(jsonEncode(first.toJson()), isNot(contains(secret)));
    expect(first.toJson()['project_dir'], dir.absolute.path);
    expect(() => first.steps.clear(), throwsUnsupportedError);
    final second = runner.run(configPath: path, logger: logger, adapter: _Adapter());
    expect(second.steps.first.verb, 'ok');
    expect(first.steps.first.verb, 'created');
    expect(first.steps, hasLength(4));
    expect(second.steps, hasLength(4));
  });

  test('Flutter detection reads YAML structure, not comments or nested keys', () {
    final adapter = DartFlutterAdapter();
    final file = File('${dir.path}/pubspec.yaml');
    expect(adapter.detect(dir.path), isFalse);
    for (final source in ['# flutter:\nname: demo', 'name: demo\nextra:\n  flutter: {}', '[bad']) {
      file.writeAsStringSync(source);
      expect(adapter.detect(dir.path), isFalse, reason: source);
    }
    for (final source in ['name: demo\nflutter:\n', 'flutter: {assets: []}']) {
      file.writeAsStringSync(source);
      expect(adapter.detect(dir.path), isTrue, reason: source);
    }
  });
}
