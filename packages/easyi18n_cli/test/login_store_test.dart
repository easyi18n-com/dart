import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/login_store.dart';
import 'package:easyi18n_cli/src/mcp/deps.dart';
import 'package:easyi18n_cli/src/session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// #2583: where `easyi18n login` keeps its login, how the CLI reads it back,
// and how `login` and `logout` write it: whole, renamed into place, private.
void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('login_store'));
  tearDown(() => home.deleteSync(recursive: true));

  File storeFile() => File(p.join(home.path, '.config', 'easyi18n', 'credentials.json'));
  void write(Object? body) => (storeFile()..createSync(recursive: true))
      .writeAsStringSync(body is String ? body : jsonEncode(body));
  Map<String, Object?> v1(Map<String, Object?> logins) => {'version': 1, 'logins': logins};
  const origin = 'http://localhost:8080';

  group('locate', () {
    String? pathOf(Map<String, String> environment, {bool windows = false}) =>
        LoginStore.locate(environment, windows: windows)?.file.path;

    test('XDG_CONFIG_HOME wins over HOME', () {
      expect(pathOf({'XDG_CONFIG_HOME': '/xdg', 'HOME': '/home/dev'}),
          p.join('/xdg', 'easyi18n', 'credentials.json'));
    });
    test('HOME/.config without XDG_CONFIG_HOME, or with it blank', () {
      for (final xdg in [null, '', '  ']) {
        expect(pathOf({'XDG_CONFIG_HOME': ?xdg, 'HOME': '/home/dev'}),
            p.join('/home/dev', '.config', 'easyi18n', 'credentials.json'));
      }
    });
    test('APPDATA on Windows, never HOME', () {
      expect(pathOf({'APPDATA': r'C:\Users\dev\AppData\Roaming', 'HOME': '/h'},
              windows: true),
          p.join(r'C:\Users\dev\AppData\Roaming', 'easyi18n', 'credentials.json'));
      expect(pathOf({'HOME': '/h'}, windows: true), isNull);
    });
    test('no store without a home to put it in', () {
      expect(pathOf(const {}), isNull);
      expect(pathOf({'HOME': ' '}), isNull);
    });
  });

  group('read', () {
    LoginStore store() => LoginStore(storeFile());

    test('the version 1 entry of the origin, with email and expiry', () {
      write(v1({origin: {'token': 'eip_a', 'email': 'dev@acme.test',
          'expires_at': '2026-12-03T21:44:13.324762Z'}}));
      final login = store().read(origin)!;
      expect(login.token, 'eip_a');
      expect(login.email, 'dev@acme.test');
      expect(login.expiresAt, DateTime.utc(2026, 12, 3, 21, 44, 13, 324, 762));
    });

    test('another origin has no login, and a trailing slash is another key', () {
      write(v1({'https://api.easyi18n.com': {'token': 'eip_prod'},
          '$origin/': {'token': 'eip_slash'}}));
      final s = store();
      expect(s.read(origin), isNull);
      expect(s.unreadable, isFalse);
    });

    test('no file, no login, nothing unreadable', () {
      final s = store();
      expect(s.read(origin), isNull);
      expect(s.unreadable, isFalse);
    });

    for (final (name, body) in [
      ('a newer version', {'version': 2, 'logins': {origin: {'token': 'eip_v2'}}}),
      ('no version', {'logins': {origin: {'token': 'eip_v0'}}}),
      ('the flat shape of the first repro', {origin: {'access_token': 'eip_flat'}}),
      ('logins that are not an object', {'version': 1, 'logins': ['eip_list']}),
      ('a JSON that does not decode', '{"version": 1, "logins": {'),
      ('a JSON array', '[1]'),
    ]) {
      test('$name reads as no login and is flagged unreadable', () {
        write(body);
        final s = store();
        expect(s.read(origin), isNull);
        expect(s.unreadable, isTrue);
      });
    }

    test('bytes that are not UTF-8 read as no login instead of throwing', () {
      (storeFile()..createSync(recursive: true)).writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]);
      final s = store();
      expect(s.read(origin), isNull);
      expect(s.unreadable, isTrue);
    });

    for (final (name, entry) in [
      ('no token', {'email': 'dev@acme.test'}),
      ('an empty token', {'token': ''}),
      ('a token that is not a string', {'token': 42}),
      ('an entry that is not an object', 'eip_bare'),
    ]) {
      test('an entry with $name is no login', () {
        write(v1({origin: entry}));
        expect(store().read(origin), isNull);
      });
    }

    test('a missing or malformed email and expiry read as null', () {
      write(v1({origin: {'token': 'eip_a', 'email': 7, 'expires_at': 'soon'}}));
      final login = store().read(origin)!;
      expect(login.email, isNull);
      expect(login.expiresAt, isNull);
      expect(login.expired, isFalse, reason: 'the server decides an unknown date');
    });

    test('expired is a date in the past', () {
      expect(StoredLogin(token: 't', expiresAt: DateTime.utc(2000)).expired, isTrue);
      expect(StoredLogin(token: 't', expiresAt: DateTime.utc(2100)).expired, isFalse);
    });
  });

  group('the refusal without a credential', () {
    Map<String, String> env() => {'HOME': home.path};

    test('names the origin and easyi18n login, then the API key a CI uses', () {
      expect(() => requireToken(environment: env(), baseUrl: origin, scope: 'publish'),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              "No credential for $origin. Run 'easyi18n login', set "
              'EASYI18N_TOKEN or pass --token.\n'
              'Create an API key in your project settings (needs the publish scope).')));
    });

    test('names an unreadable store by its path, never its content', () {
      write('{"version": 1, "logins": {"$origin": {"token": "eip_secret_value_123456789"');
      expect(() => requireToken(environment: env(), baseUrl: origin),
          throwsA(isA<CliException>().having((e) => e.message, 'message', allOf(
              contains('No credential for $origin (${storeFile().path} is not a '
                  'login file this CLI can read)'),
              isNot(contains('eip_secret'))))));
    });

    test('an explicit empty --token does not fall back to the store', () {
      write(v1({origin: {'token': 'eip_stored'}}));
      expect(() => requireToken(token: ' ', environment: env(), baseUrl: origin),
          throwsA(isA<CliException>()));
    });
  });

  // Decision 1 of #2579: the MCP inherits the login. It reads the store on
  // every call, so a login or a logout in another terminal needs no restart.
  group('the MCP server', () {
    McpDeps deps([Map<String, String> also = const {}]) => McpDeps(
        logger: CliLogger(out: StringBuffer(), err: StringBuffer()),
        environment: {'HOME': home.path, ...also});

    test('reads the stored login of the call origin on every call', () {
      final mcp = deps();
      expect(() => mcp.requireToken(origin), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'no_credential')
          .having((e) => e.message, 'message', contains("'easyi18n login'"))));
      write(v1({origin: {'token': 'eip_stored'}}));
      expect(mcp.requireToken(origin), 'eip_stored');
      expect(mcp.usesLogin(origin), isTrue);
      expect(() => mcp.requireToken('https://api.easyi18n.com'),
          throwsA(isA<CliException>()), reason: 'a login only goes to its origin');
      storeFile().deleteSync();
      expect(() => mcp.requireToken(origin), throwsA(isA<CliException>()));
    });

    test('EASYI18N_TOKEN wins, and a blank one or the placeholder is unset', () {
      write(v1({origin: {'token': 'eip_stored'}}));
      expect(deps({'EASYI18N_TOKEN': 'eik_env'}).requireToken(origin), 'eik_env');
      expect(deps({'EASYI18N_TOKEN': 'eik_env'}).usesLogin(origin), isFalse);
      for (final unset in ['', '  ', 'eik_YOUR_AGENT_KEY']) {
        expect(deps({'EASYI18N_TOKEN': unset}).requireToken(origin), 'eip_stored');
      }
    });

    test('a login file it cannot read is named, never printed', () {
      write('{"logins": "eip_secret"');
      expect(() => deps().requireToken(origin), throwsA(isA<CliException>()
          .having((e) => e.message, 'message', allOf(
              contains('${storeFile().path} is not a login file'),
              isNot(contains('eip_secret'))))));
    });
  });

  group('write and remove', () {
    int modeOf(String path) => FileStat.statSync(path).mode & 0x1ff;
    Object? onDisk() => jsonDecode(storeFile().readAsStringSync());
    final login = StoredLogin(token: 'eip_new', email: 'dev@acme.test',
        expiresAt: DateTime.utc(2026, 12, 3, 12));
    const other = 'https://api.easyi18n.com';

    test('a login lands as version 1, 0600 in a 0700 directory', () {
      LoginStore(storeFile()).write(origin, login);
      expect(onDisk(), v1({origin: {'token': 'eip_new', 'email': 'dev@acme.test',
          'expires_at': '2026-12-03T12:00:00.000Z'}}));
      expect(modeOf(storeFile().path), 0x180);
      expect(modeOf(storeFile().parent.path), 0x1c0);
      expect(LoginStore(storeFile()).read(origin)!.expiresAt, login.expiresAt);
      expect(storeFile().parent.listSync().map((e) => p.basename(e.path)),
          ['credentials.json']);
    }, testOn: '!windows');

    test('a world-readable directory and file come back private', () {
      write(v1({other: {'token': 'eip_kept'}}));
      Process.runSync('chmod', ['755', storeFile().parent.path]);
      Process.runSync('chmod', ['644', storeFile().path]);
      LoginStore(storeFile()).write(origin, login);
      expect(modeOf(storeFile().path), 0x180);
      expect(modeOf(storeFile().parent.path), 0x1c0);
    }, testOn: '!windows');

    test('a pre-existing temporary symlink never receives credentials', () {
      final file = storeFile();
      file.parent.createSync(recursive: true);
      final target = File(p.join(home.path, 'outside'))..writeAsStringSync('untouched');
      final planted = Link('${file.path}.$pid.tmp');
      // Planted as late as another user can: while the directory is not private yet.
      final store = LoginStore(file, chmod: (exe, args) {
        if (args.last == file.parent.path) {
          if (File(planted.path).existsSync()) File(planted.path).deleteSync();
          planted.createSync(target.path);
        }
        return Process.runSync(exe, args);
      });
      expect(() => store.write(origin, login), throwsA(isA<CliException>()));
      expect(target.readAsStringSync(), 'untouched');
      expect(planted.existsSync(), isTrue);
    }, testOn: '!windows');

    test('the other origins stay, and remove drops only its own', () {
      write(v1({other: {'token': 'eip_kept'}, origin: {'token': 'eip_old'}}));
      final store = LoginStore(storeFile());
      store.write(origin, login);
      expect((onDisk() as Map)['logins'], {
        other: {'token': 'eip_kept'},
        origin: {'token': 'eip_new', 'email': 'dev@acme.test',
            'expires_at': '2026-12-03T12:00:00.000Z'},
      });
      expect(store.remove(origin), isTrue);
      expect(onDisk(), v1({other: {'token': 'eip_kept'}}));
      expect(store.remove(origin), isFalse);
      expect(LoginStore(File(p.join(home.path, 'none.json'))).remove(origin), isFalse);
      expect(File(p.join(home.path, 'none.json')).existsSync(), isFalse);
    });

    // Without --json the runner rethrows a FileSystemException and main has
    // no handler for it: logout and login would end in a stack trace.
    test('a write the disk refuses is a refusal that names the file', () {
      write(v1({origin: {'token': 'eip_old'}}));
      File('${storeFile().path}.$pid.tmp').createSync();
      final refusal = throwsA(isA<CliException>().having((e) => e.message, 'message',
          allOf(startsWith('Could not write ${storeFile().path}'), endsWith('nothing was saved.'))));
      expect(() => LoginStore(storeFile()).remove(origin), refusal);
      expect(() => LoginStore(storeFile()).write(other, login), refusal);
      expect(onDisk(), v1({origin: {'token': 'eip_old'}}));
    }, testOn: '!windows');

    test('a file that does not decode is replaced', () {
      write('{"version": 1, "logins": ');
      LoginStore(storeFile()).write(origin, login);
      expect((onDisk() as Map)['logins'], contains(origin));
    });

    test('a later version is kept whole and nothing is written', () {
      final newer = {'version': 2, 'logins': {other: {'token': 'eip_kept'}}};
      write(newer);
      final store = LoginStore(storeFile());
      final refusal = throwsA(isA<CliException>().having((e) => e.message, 'message',
          contains('${storeFile().path} was written by a newer easyi18n')));
      expect(store.ensureWritable, refusal);
      expect(() => store.write(origin, login), refusal);
      expect(() => store.remove(other), refusal);
      expect(onDisk(), newer);
    });

    test('a temporary file that cannot be made private is deleted, not kept', () {
      final store = LoginStore(storeFile(), chmod: (exe, args) {
        Process.runSync(exe, args);
        return ProcessResult(0, args.last.endsWith('.tmp') ? 1 : 0, '', '');
      });
      expect(() => store.write(origin, login), throwsA(isA<CliException>()));
      expect(storeFile().parent.listSync(), isEmpty);
    }, testOn: '!windows');

    // One applies the mode and still exits 1; the other exits 0 and applies none.
    for (final (name, applies, exitCode) in [
      ('a chmod that fails', true, 1), ('a chmod that does not take', false, 0)]) {
      test('$name saves nothing and leaves no temporary file', () {
        final store = LoginStore(storeFile(), chmod: (exe, args) {
          if (applies) Process.runSync(exe, args);
          return ProcessResult(0, exitCode, '', '');
        });
        expect(() => store.write(origin, login), throwsA(isA<CliException>()
            .having((e) => e.message, 'message', contains('nothing was saved'))));
        expect(storeFile().existsSync(), isFalse);
        expect(storeFile().parent.listSync(), isEmpty);
      }, testOn: '!windows');
    }
  });
}
