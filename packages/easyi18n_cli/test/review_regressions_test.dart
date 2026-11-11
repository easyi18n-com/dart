import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/backoff.dart';
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

  // #2646: a refused certificate is a connection failure, not a crash. The
  // text is the exception's own, on one line, so TLS reads apart from a port.
  group('a TLS failure reads as a connection failure', () {
    const refused = HandshakeException('Handshake error in client', OSError(
        '\n\tCERTIFICATE_VERIFY_FAILED: application verification failure(handshake.cc:319)'));
    const why = 'HandshakeException: Handshake error in client (OS Error: '
        'CERTIFICATE_VERIFY_FAILED: application verification failure(handshake.cc:319))';
    late int calls;
    setUp(() => calls = 0);

    TranslationsApiClient api(http.Client client) => TranslationsApiClient(
        baseUrl: 'https://api.easyi18n.com', token: 'eik_secret',
        httpClient: client, wait: (_) async {});
    MockClient throwing(Object error) => MockClient((_) async {
          calls++;
          throw error;
        });
    Matcher unreachable(String origin) => throwsA(isA<TransientCliException>()
        .having((e) => e.message, 'message', 'Could not reach $origin: $why'));

    test('a GET is replayed like a dropped connection, then gives up', () async {
      final client = api(throwing(refused));
      addTearDown(client.close);
      await expectLater(client.fetchMeta(projectId: 'p1'),
          unreachable('https://api.easyi18n.com'));
      expect(calls, kMaxApiAttempts);
    });

    test('a POST is not replayed', () async {
      final client = api(throwing(refused));
      addTearDown(client.close);
      await expectLater(client.translate(projectId: 'p1', units: []),
          unreachable('https://api.easyi18n.com'));
      expect(calls, 1);
    });

    test('delivery', () async {
      final client = DeliveryClient(baseUrl: 'https://delivery.easyi18n.com',
          httpClient: throwing(refused));
      addTearDown(client.close);
      await expectLater(client.fetchManifest('p1'), unreachable('delivery.easyi18n.com'));
    });

    test('mid-body', () async {
      final client = api(MockClient.streaming((_, _) async =>
          http.StreamedResponse(Stream.error(refused), 200)));
      addTearDown(client.close);
      await expectLater(client.translate(projectId: 'p1', units: []),
          unreachable('https://api.easyi18n.com'));
    });

    test('a bug of its own is not disguised as one', () async {
      final client = api(throwing(StateError('bug')));
      addTearDown(client.close);
      await expectLater(client.translate(projectId: 'p1', units: []),
          throwsA(isA<StateError>()));
    });
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
