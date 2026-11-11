import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// An environment whose HOME holds the login `easyi18n login` would have
/// stored for [origin] (#2583), deleted after the test. A test passes it
/// instead of the real environment, so the developer's own login is never
/// read. [also] adds variables, such as an EASYI18N_TOKEN that wins over it.
Map<String, String> loggedInHome({
  String token = 'eip_login',
  String origin = Easyi18nConfig.defaultBaseUrl,
  String expiresAt = '2099-01-01T00:00:00.000Z',
  Map<String, String> also = const {},
}) {
  final home = Directory.systemTemp.createTempSync('stored_login');
  addTearDown(() => home.deleteSync(recursive: true));
  File(p.join(home.path, '.config', 'easyi18n', 'credentials.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode({'version': 1, 'logins': {
      origin: {'token': token, 'email': 'dev@acme.test', 'expires_at': expiresAt},
    }}));
  return {'HOME': home.path, ...also};
}
