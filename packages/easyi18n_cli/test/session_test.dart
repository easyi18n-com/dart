import 'dart:convert';

import 'package:easyi18n_cli/easyi18n_cli.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/config.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/project_ref.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  for (final scope in ['read', 'publish']) {
    test('requireToken preserves the $scope message word for word', () {
      expect(() => requireToken(environment: const {}, scope: scope),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              'No credential. Set EASYI18N_TOKEN or pass --token.\n'
              'Create an API key in your project settings (needs the $scope scope).')));
      expect(requireToken(token: ' explicit ',
          environment: const {'EASYI18N_TOKEN': 'env'}, scope: scope), 'explicit');
      expect(requireToken(environment: const {'EASYI18N_TOKEN': ' env '},
          scope: scope), 'env');
      expect(() => requireToken(token: ' ',
          environment: const {'EASYI18N_TOKEN': 'env'}, scope: scope),
          throwsA(isA<CliException>()));
    });
  }

  for (final failure in ['none', 'body', 'resolve']) {
    test('withProject closes when $failure throws and warns before factory', () async {
      final events = <String>[];
      final err = StringBuffer();
      final client = _ClosingClient(MockClient((request) async {
        events.add('resolve');
        expect(request.url.path, '/v1/projects/resolve');
        return http.Response(jsonEncode(failure == 'resolve'
            ? {'error': 'not_found', 'message': 'resolve failed'}
            : {'projectId': 'resolved_id'}), failure == 'resolve' ? 404 : 200);
      }), events);
      final result = withProject<int>(
        config: Easyi18nConfig(ref: HandleRef('workspace', 'project'),
            baseUrl: 'https://untrusted.example'),
        token: 'explicit', logger: CliLogger(out: StringBuffer(), err: err),
        apiClientFactory: ({required baseUrl, required token}) {
          expect(err.toString(), contains('baseUrl points at untrusted.example'));
          expect(baseUrl, 'https://untrusted.example');
          expect(token, 'explicit');
          events.add('factory');
          return client;
        },
        body: (api, projectId) async {
          expect(api, same(client));
          expect(projectId, 'resolved_id');
          events.add('body');
          if (failure == 'body') throw StateError('body failed');
          return 42;
        },
      );
      if (failure == 'none') {
        expect(await result, 42);
      } else {
        await expectLater(result, throwsA(failure == 'body'
            ? isA<StateError>() : isA<ApiException>()));
      }
      expect(events, ['factory', 'resolve', if (failure != 'resolve') 'body', 'close']);
    });
  }
}

class _ClosingClient extends TranslationsApiClient {
  _ClosingClient(http.Client client, this.events)
      : super(baseUrl: 'https://untrusted.example', token: 'test', httpClient: client);
  final List<String> events;
  @override
  void close() {
    events.add('close');
    super.close();
  }
}
