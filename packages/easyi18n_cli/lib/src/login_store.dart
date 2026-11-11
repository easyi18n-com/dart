import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'exceptions.dart';

/// A login `easyi18n login` keeps for the backend origin that approved it.
class StoredLogin {
  StoredLogin({required this.token, this.email, this.expiresAt});

  final String token;
  final String? email;

  /// Null when the file names no date: the server decides, as with any login.
  final DateTime? expiresAt;

  bool get expired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now().toUtc());

  Map<String, Object?> toJson() => {'token': token, 'email': email,
      'expires_at': expiresAt?.toIso8601String()};
}

/// `credentials.json` (ci-sync §9 step 1): `{"version": 1, "logins": {<base
/// URL>: {token, email, expires_at}}}`, keyed by the base URL as
/// `Easyi18nConfig` normalizes it, so a login only goes back to its origin.
///
/// A disk format of a published CLI: a later version has to read version 1.
/// Another version, or a file that does not decode, reads as no login.
class LoginStore {
  LoginStore(this.file, {ProcessResult Function(String, List<String>)? chmod})
      : _chmod = chmod ?? Process.runSync;

  /// `$XDG_CONFIG_HOME/easyi18n`, else `~/.config/easyi18n`; on Windows
  /// `%APPDATA%\easyi18n`. Null when the environment names none of them.
  static LoginStore? locate(Map<String, String> environment, {bool? windows}) {
    String? named(String key) => switch (environment[key]?.trim()) {
      null || '' => null,
      final v => v,
    };
    final dir = (windows ?? Platform.isWindows)
        ? named('APPDATA')
        : named('XDG_CONFIG_HOME') ??
            switch (named('HOME')) { null => null, final h => p.join(h, '.config') };
    return dir == null
        ? null
        : LoginStore(File(p.join(dir, 'easyi18n', 'credentials.json')));
  }

  final File file;
  final ProcessResult Function(String, List<String>) _chmod;

  /// Set once [read] found a file it could not read; never its content.
  bool unreadable = false;

  /// For a message after [read]: names the file it could not read, if any.
  String get unreadableNote =>
      unreadable ? ' (${file.path} is not a login file this CLI can read)' : '';

  StoredLogin? read(String baseUrl) {
    if (!file.existsSync()) return null;
    final body = _body();
    final logins = body is Map && body['version'] == 1 ? body['logins'] : null;
    if (logins is! Map) {
      unreadable = true;
      return null;
    }
    return switch (logins[baseUrl]) {
      {'token': final String token} && final entry when token.isNotEmpty =>
        StoredLogin(
          token: token,
          email: entry['email'] is String ? entry['email'] as String : null,
          expiresAt: DateTime.tryParse('${entry['expires_at']}')?.toUtc(),
        ),
      _ => null,
    };
  }

  Object? _body() {
    try {
      return jsonDecode(file.readAsStringSync());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// The logins on disk, to write back beside a change. A file of a later
  /// version belongs to a newer CLI and is kept whole; one that does not
  /// decode is replaced.
  Map<String, Object?> _logins() {
    final body = file.existsSync() ? _body() : null;
    if (body case {'version': final int v} when v > 1) {
      throw CliException('${file.path} was written by a newer easyi18n; '
          'upgrade this one to change its logins.');
    }
    return body is Map && body['version'] == 1 && body['logins'] is Map
        ? Map.of(body['logins'] as Map<String, Object?>)
        : {};
  }

  /// Refuses before a login is minted that [write] could not keep.
  void ensureWritable() => _logins();

  void write(String baseUrl, StoredLogin login) =>
      _save({..._logins(), baseUrl: login.toJson()});

  /// False when [baseUrl] had no login, and then nothing is written.
  bool remove(String baseUrl) {
    final logins = _logins();
    if (logins.remove(baseUrl) == null) return false;
    _save(logins);
    return true;
  }

  /// A disk failure is a refusal: without --json the runner rethrows a
  /// FileSystemException and `main` has no handler for it.
  void _save(Map<String, Object?> logins) {
    try {
      _replace(logins);
    } on FileSystemException catch (e) {
      throw CliException('Could not write ${file.path} '
          '(${e.osError?.message ?? e.message}); nothing was saved.');
    }
  }

  /// Whole and private: a temporary file in the same directory, made 0700
  /// before the file is written, turns 0600 and is renamed over [file], so
  /// neither a concurrent reader (the MCP) nor another user sees it half
  /// written.
  void _replace(Map<String, Object?> logins) {
    final dir = file.parent..createSync(recursive: true);
    final temp = File('${file.path}.$pid.tmp');
    _private(dir.path, '700');
    // A name planted before the directory became private must never be opened.
    temp.createSync(exclusive: true);
    try {
      temp.writeAsStringSync(jsonEncode({'version': 1, 'logins': logins}),
          flush: true);
      _private(temp.path, '600');
      temp.renameSync(file.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  }

  /// `dart:io` sets no mode, so `chmod` does, and a stat proves that no group
  /// or other bit is left. Windows has no mode bits: the profile guards it.
  void _private(String path, String mode) {
    if (Platform.isWindows) return;
    if (_chmod('chmod', [mode, path]).exitCode != 0 ||
        FileStat.statSync(path).mode & 0x3f != 0) {
      throw CliException('Could not make $path private; nothing was saved.');
    }
  }
}
