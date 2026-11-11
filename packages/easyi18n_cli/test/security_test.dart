import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/security.dart';
import 'package:test/test.dart';

void main() {
  group('warnOnUntrustedTarget', () {
    late StringBuffer err;
    late CliLogger logger;

    setUp(() {
      err = StringBuffer();
      logger = CliLogger(out: StringBuffer(), err: err);
    });

    test('is silent for the default https origin', () {
      warnOnUntrustedTarget('https://api.easyi18n.com', logger);
      expect(err.toString(), isEmpty);
    });

    test('is silent for the local emulator over http', () {
      warnOnUntrustedTarget('http://localhost:8080', logger);
      expect(err.toString(), isEmpty);
    });

    test('warns when the token would go to a non-default host', () {
      warnOnUntrustedTarget('https://evil.example.com', logger);
      expect(err.toString(), contains('evil.example.com'));
    });

    test('warns about plaintext http to a remote host', () {
      warnOnUntrustedTarget('http://evil.example.com', logger);
      expect(err.toString(), contains('plaintext'));
    });
  });

  // #2583: `login` opens the page the server names, so it accepts D4's hosts.
  group('refuseUntrustedLogin', () {
    void accepts(String url, [Map<String, String> env = const {}]) =>
        expect(() => refuseUntrustedLogin(url, environment: env), returnsNormally,
            reason: url);
    void refuses(String url, [Map<String, String> env = const {}]) =>
        expect(() => refuseUntrustedLogin(url, environment: env),
            throwsA(isA<FatalCliException>()
                .having((e) => e.code, 'code', 'untrusted_base_url')),
            reason: url);

    test('production over https and loopback over either scheme', () {
      accepts('https://api.easyi18n.com');
      for (final url in ['http://localhost:8080', 'http://127.0.0.1:9', 'https://[::1]:8443']) {
        accepts(url);
      }
    });

    test('exactly EASYI18N_BASE_URL, and nothing else, even over http', () {
      const env = {'EASYI18N_BASE_URL': 'http://staging.example:8080/'};
      accepts('http://staging.example:8080', env);
      refuses('http://staging.example:8081', env);
      refuses('https://staging.example:8080', env);
      refuses('http://staging.example:8080');
    });

    test('production over http, another host, another scheme or no host', () {
      for (final url in ['http://api.easyi18n.com', 'https://evil.example',
          'http://localhost.:8080', 'ftp://localhost/x', 'localhost:8080', '']) {
        refuses(url);
      }
    });
  });
}
