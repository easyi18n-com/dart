/// Serializing JSON the way Xcode writes `.xcstrings`.
///
/// An `.xcstrings` is a file two tools write: we produce it on export, and
/// Xcode rewrites it on every build that extracts strings. A stock JSON writer
/// disagrees with Xcode on three details, and each disagreement makes the two
/// take turns reformatting the whole file — measured on a real catalog, a sync
/// that added 156 translations landed as `+9294 −8325` instead of `+1032 −57`.
/// Nobody reviews a diff that size, so a reverted translation or a dropped key
/// rides in unseen.
///
/// This file is synced VERBATIM into `easyi18n_cli`
/// (`lib/src/xcode_json.dart`) by that package's `tool/sync_contract.dart`,
/// whose `--check` runs in CI. Edit it HERE; a hand-edit on the vendored copy
/// fails the build. It deliberately imports nothing, so the same bytes compile
/// in both packages — the CLI is published to pub.dev and cannot depend on
/// this package.
library;

/// Serializes [value] the way Xcode writes `.xcstrings`: two-space indent,
/// `" : "` key separator, insertion-ordered keys, raw UTF-8 (no `\uXXXX` for
/// printable text), an empty object rendered with a blank line inside, and
/// **no trailing newline**. Pinned byte-for-byte by the golden test against a
/// catalog Xcode itself wrote.
String writeXcodeStyleJson(Object? value) {
  final buffer = StringBuffer();
  _write(buffer, value, 0);
  return buffer.toString();
}

void _write(StringBuffer out, Object? value, int depth) {
  final indent = '  ' * depth;
  final childIndent = '  ' * (depth + 1);
  switch (value) {
    case Map<String, Object?>():
      if (value.isEmpty) {
        // Xcode's quirk: `{` + blank line + closing brace at the parent depth.
        out.write('{\n\n$indent}');
        return;
      }
      out.write('{\n');
      var first = true;
      for (final e in value.entries) {
        if (!first) out.write(',\n');
        first = false;
        out.write('$childIndent${_string(e.key)} : ');
        _write(out, e.value, depth + 1);
      }
      out.write('\n$indent}');
    case List<Object?>():
      if (value.isEmpty) {
        out.write('[\n\n$indent]');
        return;
      }
      out.write('[\n');
      var first = true;
      for (final e in value) {
        if (!first) out.write(',\n');
        first = false;
        out.write(childIndent);
        _write(out, e, depth + 1);
      }
      out.write('\n$indent]');
    case String():
      out.write(_string(value));
    case num() || bool():
      out.write(value);
    case null:
      out.write('null');
    default:
      throw ArgumentError('unserializable value: ${value.runtimeType}');
  }
}

/// JSON string escaping as Xcode emits it: quotes, backslashes and control
/// characters escaped; everything else (accents, ¿, emoji) stays raw UTF-8.
String _string(String s) {
  final out = StringBuffer('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (rune < 0x20) {
          out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  out.write('"');
  return out.toString();
}
