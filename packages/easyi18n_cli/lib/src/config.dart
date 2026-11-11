import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'logger.dart';
import 'project_ref.dart';

/// Project config read from `easyi18n.yaml` at the repo root. Holds everything
/// `pull` needs except the credential, which never goes in this file (it
/// comes from `--token`, `EASYI18N_TOKEN` or the login store).
class Easyi18nConfig {
  Easyi18nConfig({
    required this.ref,
    String? baseUrl,
    String? format,
    String? output,
    String? mode,
    this.catalog,
    this.catalogs = const [],
    this.source,
    this.sourceRoot,
    this.sourceLayout,
    this.sourceExclude = const [],
  }) : baseUrl = _normalizeBaseUrl(baseUrl ?? defaultBaseUrl),
       format = format ?? defaultFormat,
       output = output ?? defaultOutput,
       mode = _validateMode(mode ?? defaultMode);

  /// The project ref. [ProjectRef.parse] is the single validator — the sealed
  /// type guarantees exactly one form, so nothing downstream re-checks.
  final ProjectRef ref;

  /// Backend origin. Defaults to production; override for the local emulator.
  final String baseUrl;

  /// Output format id rendered by the backend (`arb`, `json`, `xcstrings`,
  /// `po`, ...).
  final String format;

  /// **Directory** the rendered files are written into, relative to the config
  /// file — one file per locale (`app_en.arb`, `es.json`). For Mode A this is
  /// the `arb-dir` from your `l10n.yaml`. Always has a value ([defaultOutput]
  /// when absent), so it can never signal intent: a format that renders ONE
  /// file at a path of its own says so with [catalog], which wins over this.
  final String output;

  /// The exact path of the local translation catalog (e.g.
  /// `EscapeCall/Localizable.xcstrings`), relative to the config file — for
  /// formats that hold every language in one file the project already owns.
  /// `sync` uploads this file and writes the translated one back to the SAME
  /// path, whatever name the server serves it under; `pull` writes to it too,
  /// instead of treating [output] as the destination. Null on code-first
  /// projects that pull a directory of per-locale files.
  final String? catalog;

  /// Several catalogs that are one project (`catalogs:`, #590): `sync` uploads
  /// the union of their entries and `pull` gives every key back to the file it
  /// came from. Empty unless set, and never set together with [catalog].
  final List<String> catalogs;

  /// The base-language file of a project that keeps one file per locale (e.g.
  /// `public/i18n/en.json`), relative to the config file. `sync` uploads it;
  /// the other locales are written into [output]. Unlike [catalog] it is
  /// never a destination.
  final String? source;

  /// [source] is a gen_l10n template (#2343): `source:` keeps pull off it,
  /// but `/v1/sync` takes no ARB, so `sync` cannot upload it.
  bool get sourceIsArbTemplate => source != null && format == 'arb';

  /// Required input catalog directory for source, relative to the config.
  /// Generated directories are declared separately, never inferred from output.
  final String? sourceRoot;
  final String? sourceLayout;
  final List<String> sourceExclude;

  /// Integration mode (#415): `'a'` (TMS — the app keeps `gen_l10n`, no
  /// runtime dependency, `pull` writes the files back) or `'b'` (runtime SDK —
  /// `context.tr()`, `Easyi18nScope`, OTA). Controls what `init` scaffolds
  /// and which `doctor` checks apply. Defaults to `'b'` when absent, so every
  /// config written before this field existed keeps its behavior. Local-only:
  /// independent of (and not synced with) the dashboard's own project mode
  /// setting.
  final String mode;

  /// The formats [catalog] can name: those that render ONE file holding every
  /// language. Every other format renders one file per locale, so pointing
  /// [catalog] at it would funnel a single locale's render into the project's
  /// catalog path and call it a success. Add a format here when the backend
  /// gains another single-file one — that is the only thing this gates.
  static const Set<String> catalogFormats = {'xcstrings'};

  static const String fileName = 'easyi18n.yaml';
  static const String defaultBaseUrl = 'https://api.easyi18n.com';
  static const String defaultFormat = 'arb';
  static const String defaultOutput = 'lib/l10n';
  static const String defaultMode = 'b';

  /// A human-readable label for the configured ref, for diagnostics/logs.
  String get describeRef => ref.describe;

  /// Every setting [load] reads. A key outside this set is ignored, so a typo
  /// silently falls back to a default — `ouput:` used to leave a pull writing
  /// to `lib/l10n` while reporting success (#552). [load] warns about them
  /// instead of failing: the CI action pins `cli-version`, so a config written
  /// for a newer CLI must not hard-fail the pinned one.
  static const Set<String> knownKeys = {
    'projectId',
    'workspace',
    'project',
    'baseUrl',
    'format',
    'output',
    'mode',
    'catalog',
    'catalogs',
    'source',
    'sourceRoot',
    'sourceLayout',
    'sourceExclude',
  };

  /// Loads and validates the config from [file], throwing [CliException] with
  /// an actionable message on any problem. Pass [logger] to surface settings
  /// the CLI does not know (see [knownKeys]).
  static Easyi18nConfig load(File file, {CliLogger? logger}) {
    if (!file.existsSync()) {
      throw CliException(
        'No ${Easyi18nConfig.fileName} found at ${file.path}.\n'
        "Run 'easyi18n init' to create one.",
      );
    }

    final dynamic parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw CliException('Invalid YAML in ${file.path}: ${e.message}');
    }
    if (parsed is! Map) {
      throw CliException('${file.path} must be a YAML map of settings.');
    }
    if (logger != null) _warnUnknownKeys(parsed, file, logger);

    return Easyi18nConfig(
      ref: ProjectRef.parse(
        projectId: _readString(parsed, 'projectId')?.trim(),
        workspace: _readString(parsed, 'workspace')?.trim(),
        project: _readString(parsed, 'project')?.trim(),
        source: file.path,
      ),
      baseUrl: _readString(parsed, 'baseUrl')?.trim(),
      format: _readString(parsed, 'format')?.trim(),
      output: _readString(parsed, 'output')?.trim(),
      mode: _readString(parsed, 'mode')?.trim(),
      catalog: _readString(parsed, 'catalog')?.trim(),
      catalogs: _readCatalogs(parsed),
      source: _readString(parsed, 'source')?.trim(),
      sourceRoot: _readString(parsed, 'sourceRoot')?.trim(),
      sourceLayout: _readString(parsed, 'sourceLayout')?.trim(),
      sourceExclude: _readSourceExclude(parsed),
    );
  }

  /// Serializes to YAML with explanatory comments. Deliberately hand-written
  /// (no token, stable key order) so generated configs stay reviewable.
  String toYaml() {
    final catalogPath = catalog;
    // `output` is the destination only when no catalog is (`PullRunner`): a
    // catalog config drops the unused default and labels a value someone set.
    final outputLines = (catalogPath == null || catalogPath.isEmpty) && catalogs.isEmpty
        ? '\n# Where the rendered files are written (your l10n.yaml arb-dir '
              'for Mode A).\noutput: ${_scalar(output)}\n'
        : output == defaultOutput
        ? ''
        : '\n# Not used while `catalog:` is set: pull and sync write into '
              'that file.\noutput: ${_scalar(output)}\n';
    final catalogsLines = catalogs.isEmpty
        ? ''
        : '\n# File-first sync of several String Catalogs as one project: the '
              'union of their\n# keys is uploaded, and each key is written back '
              'to the file it came from.\ncatalogs:\n'
              '${catalogs.map((c) => '  - ${_scalar(c)}\n').join()}';
    final catalogLines = catalogPath == null
        ? ''
        : '\n# File-first sync: the local translation catalog `easyi18n sync` '
              'uploads and\n# writes back (relative to this file).\n'
              'catalog: ${_scalar(catalogPath)}\n';
    final sourcePath = source;
    final sourceLines = sourcePath == null
        ? ''
        : sourceIsArbTemplate
        ? '\n# The base-language file (relative to this file): yours to edit, '
              'and\n# `pull` never writes it. The other locales are written '
              'into `output:`.\nsource: ${_scalar(sourcePath)}\n'
        : '\n# File-first sync: the base-language file `easyi18n sync` uploads '
              '(relative to\n# this file). The other locales are written into '
              '`output:`.\nsource: ${_scalar(sourcePath)}\n';
    final inputLines = '${sourceRoot == null ? '' : 'sourceRoot: ${_scalar(sourceRoot!)}\n'}'
        '${sourceLayout == null ? '' : 'sourceLayout: ${_scalar(sourceLayout!)}\n'}'
        '${sourceExclude.isEmpty ? '' : 'sourceExclude: ${jsonEncode(sourceExclude)}\n'}';
    final refLines = switch (ref) {
      IdRef(:final id) => 'projectId: ${_scalar(id)}',
      HandleRef(:final workspace, :final slug) =>
        'workspace: ${_scalar(workspace)}\nproject: ${_scalar(slug)}',
    };
    // Stack-neutral on purpose: this same writer serves a Flutter project and
    // an Xcode one, and naming gen_l10n here made the file-first config lie.
    final headline = mode == 'a'
        ? '# easyi18n CLI config (Mode A: TMS over the files your project owns).'
        : '# easyi18n CLI config (Mode B: runtime SDK, context.tr()).';
    return '''
$headline
# Docs: https://github.com/easyi18n-com/dart

# The project to pull translations for: the @handle/slug pair from your
# dashboard URL (workspace + project), or an opaque projectId.
$refLines

# Integration mode: 'a' is TMS - your project keeps its own translation files
# and `easyi18n pull` / `sync` write them back; 'b' is the runtime SDK.
mode: $mode

# Backend origin. Override with http://localhost:8080 for the local emulator.
baseUrl: ${_scalar(baseUrl)}

# Output format rendered by the backend (arb, json, nested_json, xcstrings,
# ios_strings, android_xml, po).
format: ${_scalar(format)}
$outputLines$catalogLines$catalogsLines$sourceLines$inputLines''';
  }

  /// A scalar [load] reads back byte for byte, quoted only when it has to be.
  ///
  /// `init --stack xcode` writes a path it DISCOVERED on disk, so the value is
  /// whatever the filesystem allows. A plain YAML scalar drops everything from
  /// an unquoted ` #` on and breaks outright on `: `, and both failures are
  /// silent at write time: `App #1/Localizable.xcstrings` reloaded as `App` —
  /// a path that does not exist — with `init` reporting success.
  ///
  /// Quoting only what needs it keeps every config written so far unchanged.
  ///
  /// The quoted arm is DOUBLE quoted, via [jsonEncode]: a YAML 1.2
  /// double-quoted scalar is a JSON string, so the encoder already emits
  /// exactly the escapes the parser reads back. Single quotes were not enough
  /// — they preserve `#` and `: ` but **fold a real line feed into a space**,
  /// and a directory name may carry one, so `App\nDemo/Localizable.xcstrings`
  /// still reloaded as a path that does not exist, with `init` reporting
  /// success.
  static String _scalar(String value) =>
      _plainSafe.hasMatch(value) ? value : jsonEncode(value);

  /// Deliberately narrower than YAML's plain-scalar grammar: the characters a
  /// path, a slug or a URL needs, never leading with an indicator. Anything
  /// else is quoted, which is always legal — the cost of being wrong here is
  /// a pair of quotes, and the cost of being wrong the other way is a config
  /// that reads back as a different path.
  static final RegExp _plainSafe = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./@:+-]*$');

  static void _warnUnknownKeys(Map parsed, File file, CliLogger logger) {
    final unknown = parsed.keys
        .map((k) => '$k')
        .where((k) => !knownKeys.contains(k))
        .toList();
    if (unknown.isEmpty) return;
    unknown.sort();
    logger.warn(
      'Ignoring unknown setting(s) in ${file.path}: ${unknown.join(', ')}. '
      'Check for a typo — the settings this CLI reads are: '
      '${(knownKeys.toList()..sort()).join(', ')}.',
    );
  }

  static String _validateMode(String raw) {
    // An explicitly empty `mode:` line reads as unset, same as absent.
    if (raw.isEmpty) return defaultMode;
    if (raw != 'a' && raw != 'b') {
      throw CliException(
        "mode must be 'a' (TMS/gen_l10n) or 'b' (runtime SDK) in "
        '${Easyi18nConfig.fileName}; got "$raw".',
      );
    }
    return raw;
  }

  /// `catalogs:` as a list of distinct paths, refused by name when it is empty,
  /// repeats a file or sits next to `catalog:`: the CLI must not pick one.
  static List<String> _readCatalogs(Map map) {
    final value = map['catalogs'];
    if (value == null) return const [];
    if (value is! List || value.isEmpty ||
        value.any((v) => v is! String || v.trim().isEmpty)) {
      throw CliException('catalogs must be a list of nonempty file paths.');
    }
    if (map['catalog'] != null) {
      throw CliException(
        'Both `catalog:` and `catalogs:` are set in ${Easyi18nConfig.fileName}. '
        'Keep `catalogs:` and list the file `catalog:` names in it.',
      );
    }
    final paths = [for (final v in value.cast<String>()) v.trim()];
    for (final (i, path) in paths.indexed) {
      if (paths.take(i).any((o) => p.equals(o, path))) {
        throw CliException('`catalogs:` lists $path twice.');
      }
    }
    return List<String>.unmodifiable(paths);
  }

  static List<String> _readSourceExclude(Map map) {
    final value = map['sourceExclude'];
    if (value == null) return const [];
    if (value is! List || value.any((v) => v is! String || v.trim().isEmpty)) {
      throw CliException('sourceExclude must be a list of nonempty directory paths.');
    }
    return List<String>.unmodifiable(value.cast<String>());
  }

  static String? _readString(Map map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String) return value;
    throw CliException(
      "'$key' must be a string in ${Easyi18nConfig.fileName}.",
      code: {'sourceRoot', 'sourceLayout'}.contains(key) ? 'catalog_scope_unknown' : null,
    );
  }

  /// The origin when no config names one: `EASYI18N_BASE_URL` from the
  /// process env (the operator's, never the repo's), else the default.
  static String originFrom(Map<String, String> environment) {
    final named = environment['EASYI18N_BASE_URL']?.trim();
    return named == null || named.isEmpty ? defaultBaseUrl : trimBaseUrl(named);
  }

  /// [raw] without trailing slashes, the form [baseUrl] is stored in.
  static String trimBaseUrl(String raw) => raw.replaceAll(RegExp(r'/+$'), '');

  static String _normalizeBaseUrl(String raw) {
    final trimmed = trimBaseUrl(raw);
    final uri = Uri.tryParse(trimmed);
    // Reject a scheme-less value like `localhost:8080` up front: it would
    // otherwise crash later with a raw `ArgumentError: No host` instead of an
    // actionable message (the config comment invites dropping the scheme).
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw CliException(
        'baseUrl must be an absolute http(s) URL '
        '(e.g. https://api.easyi18n.com); got "$raw".',
      );
    }
    return trimmed;
  }
}
