import 'dart:io';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../cli_output.dart';
import '../config.dart';
import '../exceptions.dart';
import '../logger.dart';
import '../login_store.dart';
import '../security.dart';
import '../session.dart';
import 'pull_command.dart' show ApiClientFactory;

/// What `login`, `logout` and `whoami` share: the origin every other command
/// would call, and the store that keeps its login.
mixin _Origin on Command<int> {
  CliOutput get output;
  Map<String, String> get _environment;

  String get origin {
    final file = File(globalResults?['config'] as String? ?? Easyi18nConfig.fileName);
    return file.existsSync()
        ? Easyi18nConfig.load(file, logger: output.logger).baseUrl
        : Easyi18nConfig.originFrom(_environment);
  }

  LoginStore get store => LoginStore.locate(_environment) ?? (throw CliException(
      'No home directory to keep a login in: set HOME or XDG_CONFIG_HOME.'));

  /// To the person at the terminal, on stderr: with `--json` stdout is the record.
  void say(String line) => output.logger.err.writeln(CliLogger.sanitize(line));
}

TranslationsApiClient _client({required String baseUrl, required String token}) =>
    TranslationsApiClient(baseUrl: baseUrl, token: token);

/// `easyi18n login` (ci-sync §6): asks for a login, opens the approval page,
/// polls until the person answers and keeps the login for this origin.
class LoginCommand extends Command<int> with JsonPresenter, _Origin {
  LoginCommand({required this.output, ApiClientFactory? apiClientFactory,
      Map<String, String>? environment, Future<void> Function(Duration)? wait,
      Future<bool> Function(String url)? openBrowser})
      : _factory = apiClientFactory ?? _client,
        _environment = environment ?? Platform.environment,
        _wait = wait ?? Future<void>.delayed,
        _open = openBrowser ?? _openBrowser {
    argParser.addFlag('no-browser', negatable: false,
        help: 'Print the page and the code instead of opening a browser.');
  }

  @override
  final CliOutput output;
  @override
  final Map<String, String> _environment;
  final ApiClientFactory _factory;
  final Future<void> Function(Duration) _wait;
  final Future<bool> Function(String) _open;

  @override
  String get name => 'login';

  @override
  String get description =>
      'Log in from the browser; commands then work as you for 30 days.';

  @override
  Future<int> run() async {
    final base = origin;
    refuseUntrustedLogin(base, environment: _environment);
    final store = this.store..ensureWritable();
    final client = _factory(baseUrl: base, token: '');
    final StoredLogin login;
    try {
      login = await _approved(client);
    } on ApiException catch (e) {
      throw switch (e.code) {
        'denied' => CliException('The login was denied in the browser; nothing '
            'was saved.', code: e.code),
        'expired' => _expired(),
        'login_limit_reached' => CliException('Your account already has 10 '
            'active logins. Sign a device out under Account > Security, then '
            "run 'easyi18n login' again.", code: e.code),
        _ => e,
      };
    } finally {
      client.close();
    }
    final previous = store.read(base);
    store.write(base, login);
    if (previous != null && previous.token != login.token) {
      final old = _factory(baseUrl: base, token: previous.token);
      try {
        await old.logout();
      } on CliException {
        say('warning: the login this one replaces stays listed under Account > '
            'Security until it expires.');
      } finally {
        old.close();
      }
    }
    final until = login.expiresAt?.toIso8601String();
    if (output.json) {
      output.emit({'email': login.email, 'base_url': base, 'expires_at': until});
    } else {
      output.logger.info('Logged in as ${login.email ?? 'you'} to $base until $until.');
    }
    return 0;
  }

  Future<StoredLogin> _approved(TranslationsApiClient client) async {
    final asked = await client.startDeviceLogin(Platform.localHostname);
    final noBrowser = argResults!.flag('no-browser');
    if (!noBrowser) say('Opening your browser. Confirm you see the code ${asked.userCode}');
    final web = Uri.tryParse(asked.complete);
    if (noBrowser || !(web != null && (web.isScheme('http') || web.isScheme('https'))) ||
        !await _open(asked.complete)) {
      say('Open ${asked.uri} and enter the code ${asked.userCode}');
    }
    say('Waiting for the approval (Ctrl-C cancels)...');
    var interval = asked.interval, next = interval;
    // `at` is when the poll goes out, counted from the request.
    for (var at = next; at <= asked.expiresIn; at += next) {
      await _wait(Duration(seconds: next));
      final poll = await client.pollDeviceLogin(asked.deviceCode);
      if (poll.login case final login?) return login;
      // RFC 8628 §3.5: slow_down adds 5 seconds to every wait from then on.
      if (poll.code == 'slow_down') interval += 5;
      next = poll.code == 'rate_limited' ? poll.retryAfter ?? interval : interval;
    }
    throw _expired();
  }

  CliException _expired() => CliException('The login request expired before it '
      "was approved. Run 'easyi18n login' again.", code: 'expired');
}

Future<bool> _openBrowser(String url) async {
  final (exe, args) = Platform.isMacOS
      ? ('open', [url])
      // Not `cmd /c start`: the URL would go through cmd's parser.
      : Platform.isWindows
          ? ('rundll32', ['url.dll,FileProtocolHandler', url])
          : ('xdg-open', [url]);
  try {
    return (await Process.run(exe, args)).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// `easyi18n logout`: signs the login of this origin out on the server and
/// forgets it here, also when the server cannot be reached.
class LogoutCommand extends Command<int> with JsonPresenter, _Origin {
  LogoutCommand({required this.output, ApiClientFactory? apiClientFactory,
      Map<String, String>? environment})
      : _factory = apiClientFactory ?? _client,
        _environment = environment ?? Platform.environment;

  @override
  final CliOutput output;
  @override
  final Map<String, String> _environment;
  final ApiClientFactory _factory;

  @override
  String get name => 'logout';

  @override
  String get description => 'Sign this machine out and forget its login.';

  @override
  Future<int> run() async {
    final base = origin;
    final store = this.store;
    final login = store.read(base);
    bool? revoked;
    if (login != null) {
      final client = _factory(baseUrl: base, token: login.token);
      try {
        revoked = await client.logout();
      } on CliException {
        revoked = null;
      } finally {
        client.close();
      }
      store.remove(base);
    }
    if (output.json) {
      output.emit({'base_url': base, 'removed': login != null, 'revoked': revoked});
    } else {
      output.logger.info(switch (revoked) {
        _ when login == null => 'Not logged in to $base${store.unreadableNote}.',
        true => 'Logged out of $base.',
        false => 'Logged out of $base; the server no longer knew this login.',
        null => 'Forgot the login for $base, but could not reach the server to '
            'sign it out: it stays listed under Account > Security until it expires.',
      });
    }
    return 0;
  }
}

/// `easyi18n whoami`: the login this origin would send, as the server sees it
/// (`GET /v1/me`), with where it works. Only the server refusing the login
/// makes it invalid: a server that is down, or predates the route, leaves
/// what the store says.
class WhoamiCommand extends Command<int> with JsonPresenter, _Origin {
  WhoamiCommand({required this.output, ApiClientFactory? apiClientFactory,
      Map<String, String>? environment})
      : _factory = apiClientFactory ?? _client,
        _environment = environment ?? Platform.environment;

  @override
  final CliOutput output;
  @override
  final Map<String, String> _environment;
  final ApiClientFactory _factory;

  @override
  String get name => 'whoami';

  @override
  String get description =>
      'Show who this machine is logged in as, until when, and its workspaces.';

  @override
  Future<int> run() async {
    final base = origin;
    final store = this.store;
    final login = store.read(base);
    final live = login != null && !login.expired;
    ({String? email, DateTime? expiresAt})? me;
    List<AccountWorkspace>? workspaces;
    CliException? refusal, unconfirmed;
    if (live) {
      final client = _factory(baseUrl: base, token: login.token);
      try {
        me = await client.fetchMe();
        workspaces = await client.fetchWorkspaces();
      } on ApiException catch (e) {
        if (e.statusCode == 401 || const {'account_deleted', 'account_disabled'}
            .contains(e.code)) {
          refusal = e;
        } else {
          final route = me == null ? '/v1/me' : '/v1/me/workspaces';
          unconfirmed = e.statusCode == 404 && e.code == null
              ? CliException('the server does not answer GET $route yet') : e;
        }
      } on CliException catch (e) {
        unconfirmed = e;
      } finally {
        client.close();
      }
    }
    final valid = login == null ? null : !live || refusal != null ? false
        : unconfirmed != null ? null : true;
    final until = (me?.expiresAt ?? login?.expiresAt)?.toIso8601String();
    final record = {
      'logged_in': live && valid != false, 'email': me?.email ?? login?.email,
      'base_url': base, 'expires_at': until,
      'uses_env_token': findCredential(environment: _environment, baseUrl: null) != null,
      'valid': valid,
      'workspaces': workspaces == null ? null : [for (final w in workspaces) w.toJson()],
    };
    if (!live || refusal != null) {
      output.emitError(refusal ?? (login == null
          ? CliException('Not logged in to $base${store.unreadableNote}. Run '
              "'easyi18n login'.",
              code: 'not_logged_in')
          : CliException('The login for $base expired on $until. Run '
              "'easyi18n login'.", code: 'login_expired')), report: record);
    } else {
      if (unconfirmed != null) {
        output.logger.warn('could not confirm this login with $base: ${unconfirmed.message}');
      }
      if (output.json) {
        output.emit(record);
      } else {
        output.logger.info('Logged in to $base as ${record['email'] ?? 'an unnamed account'} '
            'until ${until ?? 'an unstated date'}.');
        for (final w in workspaces ?? const <AccountWorkspace>[]) {
          output.logger.info('${w.describe}  ${w.name ?? ''} (${w.role}, ${w.plan})');
          for (final p in w.projects) {
            output.logger.info('  ${p.describe}  ${p.name ?? ''} (${p.role})');
          }
        }
      }
    }
    if (record['uses_env_token'] == true) {
      output.logger.info('EASYI18N_TOKEN is set: commands send it, not the login.');
    }
    return record['logged_in'] == true ? 0 : 1;
  }
}
