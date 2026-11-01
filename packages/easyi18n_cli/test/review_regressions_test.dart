import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/delivery.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class RecordingLogger extends CliLogger {
  RecordingLogger(StringSink out, StringSink err) : super(out: out, err: err);
  final messages = <String>[];
  @override
  void info(String message) {
    messages.add(message);
    super.info('custom: $message');
  }
}

void main() {
  test('output rejects mixing a logger with either sink', () {
    final logger = CliLogger();
    expect(() => CliOutput(logger: logger, out: StringBuffer()),
        throwsArgumentError);
    expect(() => CliOutput(logger: logger, err: StringBuffer()),
        throwsArgumentError);
    expect(identical(CliOutput(logger: logger).logger, logger), true);
    expect(CliOutput(out: StringBuffer(), err: StringBuffer()), isA<CliOutput>());
  });

  test('translate transport failure is typed without replaying POST', () async {
    var calls = 0;
    final client = TranslationsApiClient(
      baseUrl: 'https://api.easyi18n.com', token: 'eik_secret',
      httpClient: MockClient((_) async {
        calls++;
        throw http.ClientException('offline');
      }),
    );
    addTearDown(client.close);
    await expectLater(client.translate(projectId: 'p1', units: []),
        throwsA(isA<TransientCliException>()));
    expect(calls, 1);
  });

  test('delivery transport failure is typed', () async {
    final client = DeliveryClient(
      baseUrl: 'https://delivery.easyi18n.com',
      httpClient: MockClient((_) async {
        throw http.ClientException('offline');
      }),
    );
    addTearDown(client.close);
    await expectLater(client.fetchManifest('p1'),
        throwsA(isA<TransientCliException>()));
  });

  test('missing config is not a retryable error', () {
    final dir = Directory.systemTemp.createTempSync('1516-config-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = StringBuffer();
    final output = CliOutput(out: out, err: StringBuffer())..json = true;
    try {
      Easyi18nConfig.load(File('${dir.path}/easyi18n.yaml'));
      fail('missing config must fail');
    } on CliException catch (error) {
      output.emitError(error);
    }
    expect(jsonDecode(out.toString())['error']['retryable'], false);
  });

  test('runner retains the injected logger and its overrides', () async {
    final out = StringBuffer();
    final err = StringBuffer();
    final logger = RecordingLogger(out, err);
    final runner = Easyi18nCommandRunner(logger: logger);
    expect(identical(runner.output.logger, logger), true);
    await runner.run(['--version']);
    expect(logger.messages, ['easyi18n $packageVersion']);
    expect(out.toString(), 'custom: easyi18n $packageVersion\n');
    out.clear();
    await runner.run(['--version', '--json']);
    logger.info('shared progress');
    logger.detail('shared detail');
    logger.warn('visible');
    expect(out.toString(), '{"version":"$packageVersion"}\n');
    expect(err.toString(), 'warning: visible\n');
    out.clear();
    await runner.run(['--version']);
    expect(out.toString(), 'custom: easyi18n $packageVersion\n');
  });

  test('shared outputQuiet controls both progress channels', () {
    final out = StringBuffer();
    final err = StringBuffer();
    final logger = CliLogger(out: out, err: err);
    final output = CliOutput(logger: logger);
    logger.outputQuiet = true;
    expect(output.json, true);
    logger.info('hidden');
    logger.detail('hidden detail');
    logger.warn('visible');
    expect(out.toString(), isEmpty);
    expect(err.toString(), 'warning: visible\n');
    logger.outputQuiet = false;
    expect(output.json, false);
    logger.info('shown');
    logger.detail('shown detail');
    expect(out.toString(), 'shown\n  shown detail\n');
  });
}
