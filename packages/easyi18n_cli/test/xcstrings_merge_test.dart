import 'dart:convert';
import 'dart:io';

import 'package:easyi18n_cli/src/xcstrings_merge.dart';
import 'package:test/test.dart';

/// The golden is a catalog **Xcode itself wrote** (EscapeCall's, after the
/// editor normalized our pulled file on 2026-08-12) — the only trustworthy
/// definition of "Xcode's style". If these tests fail after an Xcode update
/// changed the style, re-capture the fixture from a real Xcode save.
final String golden =
    File('test/fixtures/xcode_canonical.xcstrings').readAsStringSync();

void main() {
  test('decode → print round-trips the Xcode-written catalog byte-for-byte',
      () {
    expect(writeXcodeStyleJson(jsonDecode(golden)), golden);
  });

  test('merging identical served content is a byte-exact no-op', () {
    // The server rendering differs in style and key order; content matches.
    final doc = jsonDecode(golden) as Map<String, Object?>;
    final served = jsonEncode(doc); // dense style, same content
    expect(mergeXcstringsCatalog(local: golden, served: served).content, golden);
  });

  test('a new translation lands in its entry; order and extras survive', () {
    final local = '''
{
  "sourceLanguage" : "es",
  "strings" : {
    "" : {

    },
    "¿Cuándo suena?" : {
      "extractionState" : "manual"
    },
    "Adiós" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Bye"
          }
        }
      }
    }
  },
  "version" : "1.0"
}''';
    final served = jsonEncode({
      'sourceLanguage': 'es',
      'strings': {
        '¿Cuándo suena?': {
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': 'When does it ring?'},
            },
          },
        },
        'Adiós': {
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': 'Goodbye'},
            },
          },
        },
        'Solo en el server': {
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': 'Server only'},
            },
          },
        },
      },
      'version': '1.0',
    });

    final merged = mergeXcstringsCatalog(local: local, served: served).content;
    final doc = jsonDecode(merged) as Map<String, Object?>;
    final strings = doc['strings'] as Map<String, Object?>;

    // Local key order and Xcode-owned entries survive.
    expect(strings.keys.toList(), ['', '¿Cuándo suena?', 'Adiós']);
    expect(strings.containsKey('Solo en el server'), isFalse);
    expect(
      (strings['¿Cuándo suena?']! as Map)['extractionState'],
      'manual',
    );
    // The new translation landed; the changed one was replaced.
    String valueOf(String key) =>
        ((((strings[key]! as Map)['localizations'] as Map)['en']
            as Map)['stringUnit'] as Map)['value'] as String;
    expect(valueOf('¿Cuándo suena?'), 'When does it ring?');
    expect(valueOf('Adiós'), 'Goodbye');
    // And the whole document is still in Xcode style.
    expect(merged, contains('"sourceLanguage" : "es"'));
    expect(merged, contains('"" : {\n\n    }'));
    expect(merged.endsWith('\n'), isFalse);
  });

  test('an unparseable local catalog falls back to the served rendering', () {
    // Normalized, not verbatim: the next pull re-prints, and a fallback in
    // the server's style would make that pull a whole-file reformat.
    expect(
      mergeXcstringsCatalog(local: 'not json', served: '{"a":1}').content,
      '{\n  "a" : 1\n}',
    );
  });

  group('key policy', () {
    // A key the server serves and the local file lacks. Both answers are
    // wrong for the other caller, so the policy is explicit at both sites.
    const local = '{"sourceLanguage":"es","strings":{"Local":{}}}';
    final served = jsonEncode({
      'sourceLanguage': 'es',
      'strings': {
        'Local': <String, Object?>{},
        'Del dashboard': {
          'comment': 'nota',
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': 'From dashboard'},
            },
          },
        },
      },
    });

    Map<String, Object?> stringsOf(String merged) =>
        (jsonDecode(merged) as Map<String, Object?>)['strings']!
            as Map<String, Object?>;

    test('sync keeps the local key set: a served-only key is a deletion', () {
      final merged = mergeXcstringsCatalog(
        local: local,
        served: served,
        keyPolicy: XcstringsKeyPolicy.localOwnsKeySet,
      ).content;
      expect(stringsOf(merged).keys, ['Local']);
    });

    test('pull takes the union: a dashboard key has no other way in', () {
      final merged = mergeXcstringsCatalog(
        local: local,
        served: served,
        keyPolicy: XcstringsKeyPolicy.union,
      ).content;
      final strings = stringsOf(merged);
      expect(strings.keys, ['Local', 'Del dashboard']);
      final added = strings['Del dashboard']! as Map<String, Object?>;
      // The whole entry lands, comment included — not just its translations.
      expect(added['comment'], 'nota');
      expect(
        (((added['localizations']! as Map)['en'] as Map)['stringUnit']
            as Map)['value'],
        'From dashboard',
      );
    });

    test('union never overwrites a local entry it cannot read', () {
      final merged = mergeXcstringsCatalog(
        local: '{"strings":{"Roto":"no soy un objeto"}}',
        served: jsonEncode({
          'strings': {
            'Roto': {
              'localizations': {
                'en': {
                  'stringUnit': {'state': 'translated', 'value': 'x'},
                },
              },
            },
          },
        }),
        keyPolicy: XcstringsKeyPolicy.union,
      ).content;
      expect(stringsOf(merged)['Roto'], 'no soy un objeto');
    });
  });

  group('base replacements (#646)', () {
    // Warn-and-apply: the merge keeps applying the served base value (the
    // exemption is refuted — see the issue), and reports what it discarded.
    String catalog({
      Object? sourceLanguage = 'en',
      required Map<String, Object?> localizations,
      String key = 'NSMicrophoneUsageDescription',
    }) => jsonEncode({
      'sourceLanguage': ?sourceLanguage,
      'strings': {
        key: {'localizations': localizations},
      },
      'version': '1.0',
    });

    Map<String, Object?> unit(String value, {String state = 'translated'}) => {
      'stringUnit': {'state': state, 'value': value},
    };

    test(
      'replacing an edited base text applies the served value and reports '
      'the pair, under both key policies',
      () {
        final local = catalog(localizations: {'en': unit('EDITED in Xcode')});
        final served = catalog(localizations: {'en': unit('Server phrase')});
        for (final policy in XcstringsKeyPolicy.values) {
          final result = mergeXcstringsCatalog(
            local: local,
            served: served,
            keyPolicy: policy,
          );
          // The apply half is byte-anchored: the output is exactly the local
          // document with the served base localization injected — what the
          // merge wrote before #646. Keeping the local text instead (the
          // refuted fix) turns this red.
          expect(
            result.content,
            writeXcodeStyleJson(jsonDecode(served)),
            reason: '$policy',
          );
          final row = result.baseReplacements.single;
          expect(row.key, 'NSMicrophoneUsageDescription', reason: '$policy');
          expect(row.lang, 'en', reason: '$policy');
          expect(row.forms, {'text': 'EDITED in Xcode'}, reason: '$policy');
        }
      },
    );

    test('an identical base render is silent', () {
      final local = catalog(localizations: {'en': unit('Same phrase')});
      final result = mergeXcstringsCatalog(local: local, served: local);
      expect(result.baseReplacements, isEmpty);
    });

    test('an empty Xcode shell is silent: blank values are nobody\'s prose',
        () {
      // Xcode creates the identifier's shell; the phrase is written in the
      // dashboard. The served phrase must land without a warning about the
      // blank it replaces.
      final local = catalog(localizations: {'en': unit('  ')});
      final served = catalog(localizations: {'en': unit('The real phrase')});
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.baseReplacements, isEmpty);
      expect(result.content, contains('The real phrase'));
    });

    test('a printf conversion is reported and applied', () {
      final local = catalog(localizations: {'en': unit('Count: %1\$@')});
      final served = catalog(localizations: {'en': unit('Count: %1\$lld')});
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.content, contains('%1\$lld'));
      expect(result.baseReplacements.single.forms, {
        'text': 'Count: %1\$@',
      });
    });

    test('a plural replacement carries EVERY discarded local form', () {
      // Recoverability is the promise: each authored form must survive in
      // the row — one that differs by value AND one the served render
      // dropped outright.
      final local = catalog(
        key: 'calls.recorded',
        localizations: {
          'en': {
            'variations': {
              'plural': {
                'one': unit('EDITED: one call'),
                'other': unit('EDITED: %lld calls'),
              },
            },
          },
        },
      );
      final served = catalog(
        key: 'calls.recorded',
        localizations: {
          'en': {
            'variations': {
              'plural': {'other': unit('%lld calls recorded')},
            },
          },
        },
      );
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.baseReplacements.single.forms, {
        'plural.one': 'EDITED: one call',
        'plural.other': 'EDITED: %lld calls',
      });
    });

    test('a multi-arg plural\'s prose lives under substitutions and every '
        'form of it rides the row', () {
      // Xcode's "Vary by Plural" on an argument: the top-level stringUnit is
      // only format tokens; the authored prose sits in
      // `substitutions.<arg>.variations`. The row must carry that prose —
      // a token as the "discarded text" would let the real writing die
      // unlogged.
      final local = catalog(
        key: 'files.count',
        localizations: {
          'en': {
            'stringUnit': {'state': 'translated', 'value': '%1\$#@arg1@'},
            'substitutions': {
              'arg1': {
                'argNum': 1,
                'formatSpecifier': 'lld',
                'variations': {
                  'plural': {
                    'one': unit('EDITED: one file'),
                    'other': unit('EDITED: %arg files'),
                  },
                },
              },
            },
          },
        },
      );
      final served = catalog(
        key: 'files.count',
        localizations: {
          'en': unit('Plain server phrase'),
        },
      );
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.baseReplacements.single.forms, {
        'text': '%1\$#@arg1@',
        'subst.arg1.plural.one': 'EDITED: one file',
        'subst.arg1.plural.other': 'EDITED: %arg files',
      });
      expect(result.content, contains('Plain server phrase'));
    });

    test('a state-only difference is silent: no text is being discarded', () {
      final local = catalog(
        localizations: {
          'en': unit('Same phrase', state: 'needs_review'),
        },
      );
      final served = catalog(localizations: {'en': unit('Same phrase')});
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.baseReplacements, isEmpty);
    });

    test('a translation (non-base) replacement is silent', () {
      final local = catalog(localizations: {'fr': unit('Ancienne')});
      final served = catalog(localizations: {'fr': unit('Nouvelle')});
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.baseReplacements, isEmpty);
      expect(result.content, contains('Nouvelle'));
    });

    test('no sourceLanguage anywhere: silent, applied, never a crash', () {
      final local = catalog(
        sourceLanguage: null,
        localizations: {'en': unit('EDITED in Xcode')},
      );
      final served = catalog(
        sourceLanguage: null,
        localizations: {'en': unit('Server phrase')},
      );
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.baseReplacements, isEmpty);
      // The merge itself is untouched by the missing declaration.
      expect(result.content, writeXcodeStyleJson(jsonDecode(served)));
    });

    test('the LOCAL sourceLanguage wins over the served one', () {
      // Both languages populated on both sides, differing on both sides —
      // the fixture where the wrong precedence emits the wrong row.
      final local = jsonEncode({
        'sourceLanguage': 'en',
        'strings': {
          'k': {
            'localizations': {
              'en': unit('EDITED english'),
              'es': unit('Viejo español'),
            },
          },
        },
      });
      final served = jsonEncode({
        'sourceLanguage': 'es',
        'strings': {
          'k': {
            'localizations': {
              'en': unit('Server english'),
              'es': unit('Nuevo español'),
            },
          },
        },
      });
      final rows = mergeXcstringsCatalog(
        local: local,
        served: served,
      ).baseReplacements;
      expect(rows.single.lang, 'en');
      expect(rows.single.forms, {'text': 'EDITED english'});
    });

    test('the served sourceLanguage is the fallback when the local file has '
        'none', () {
      final local = catalog(
        sourceLanguage: null,
        localizations: {'en': unit('EDITED in Xcode')},
      );
      final served = catalog(localizations: {'en': unit('Server phrase')});
      final rows = mergeXcstringsCatalog(
        local: local,
        served: served,
      ).baseReplacements;
      expect(rows.single.forms, {'text': 'EDITED in Xcode'});
    });

    test('the tag match folds case, and reports the file\'s spelling', () {
      // BCP-47 is case-insensitive: a base kept under `EN` is still the base
      // the served `en` replaces. The local file misspells the case in BOTH
      // places (declaration and localization key) so each of the two folds —
      // served tag vs declared base, and served tag vs local localization —
      // is load-bearing on its own.
      final local = catalog(
        sourceLanguage: 'EN',
        localizations: {'EN': unit('EDITED in Xcode')},
      );
      final served = catalog(localizations: {'en': unit('Server phrase')});
      final result = mergeXcstringsCatalog(local: local, served: served);
      final rows = result.baseReplacements;
      expect(rows.single.lang, 'EN');
      expect(rows.single.forms, {'text': 'EDITED in Xcode'});
      // What the merge WRITES here is develop's behavior, untouched: it
      // upserts by the served spelling, so the local `EN` entry (edited text
      // included) survives and `en` lands beside it. The row is still right
      // to exist — the served text now shadows the local one in the same
      // file — but nothing was discarded, which is why the row/write
      // divergence is pinned here and named in the typedef's doc.
      final locs =
          (((jsonDecode(result.content) as Map)['strings']
                      as Map)['NSMicrophoneUsageDescription']!
                  as Map)['localizations']!
              as Map;
      expect(locs.keys, ['EN', 'en']);
      expect(result.content, contains('EDITED in Xcode'));
      expect(result.content, contains('Server phrase'));
    });
  });

  group('normalizeXcstringsCatalog', () {
    test('re-prints a server rendering in Xcode style', () {
      // The first pull's write must be byte-comparable with what the second
      // pull (which merges, and therefore re-prints) produces.
      final servedStyle = const JsonEncoder.withIndent('  ').convert(
        jsonDecode(golden),
      );
      expect(servedStyle, isNot(golden));
      expect(normalizeXcstringsCatalog(servedStyle), golden);
    });

    test('passes unparseable input through untouched', () {
      expect(normalizeXcstringsCatalog('not json'), 'not json');
    });
  });

  group('xcstringsLocales (#592)', () {
    test('collects every locale across every entry, in the file spelling', () {
      const doc = '{"sourceLanguage":"es","strings":{'
          '"Hola":{"localizations":{"en":{},"pt-BR":{}}},'
          '"Adios":{"localizations":{"zh-Hans":{}}}}}';
      expect(xcstringsLocales(doc), {'en', 'pt-BR', 'zh-Hans'});
    });

    test('an empty but readable catalog carries no locales', () {
      expect(xcstringsLocales('{"strings":{}}'), isEmpty);
    });

    test('an unreadable catalog answers null, never the empty set', () {
      // The distinction the caller depends on: empty means "none", and null
      // means "cannot say". Collapsing them makes `sync` announce that every
      // configured language went missing whenever the file will not parse.
      expect(xcstringsLocales('not json'), isNull);
      expect(xcstringsLocales('[]'), isNull);
      expect(xcstringsLocales('{"strings":"nope"}'), isNull);
    });
  });

  group('served entry shape (#966)', () {
    // Fixtures are in Xcode's own style, NOT compact JSON: the merge always
    // re-prints through writeXcodeStyleJson, so byte-identity against a
    // compact fixture is red even when the fix is right. Regenerate with
    // print(writeXcodeStyleJson(jsonDecode(...))) if you edit them.
    const local = '''
{
  "sourceLanguage" : "en",
  "strings" : {
    "k" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Hola"
          }
        }
      }
    }
  },
  "version" : "1.0"
}''';
    const emptyLocal = '''
{
  "sourceLanguage" : "en",
  "strings" : {

  },
  "version" : "1.0"
}''';
    const served =
        '{"sourceLanguage":"en","strings":{"k":"hello"},"version":"1.0"}';

    test('a scalar served entry is skipped, and the local entry survives '
        'untouched', () {
      final result = mergeXcstringsCatalog(local: local, served: served);
      expect(result.content, local);
      expect(result.baseReplacements, isEmpty);
    });

    test('union does not import a scalar served entry for a key the file '
        'lacks', () {
      final result = mergeXcstringsCatalog(
        local: emptyLocal,
        served: served,
        keyPolicy: XcstringsKeyPolicy.union,
      );
      expect(result.content, emptyLocal);
    });
  });
}
