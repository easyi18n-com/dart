import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easyi18n_cli/src/api_client.dart';
import 'package:easyi18n_cli/src/cli_output.dart';
import 'package:easyi18n_cli/src/commands/init_command.dart';
import 'package:easyi18n_cli/src/commands/pull_command.dart';
import 'package:easyi18n_cli/src/exceptions.dart';
import 'package:easyi18n_cli/src/logger.dart';
import 'package:easyi18n_cli/src/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer out;
  late StringBuffer err;
  late CliLogger logger;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('easyi18n_cli_pull');
    out = StringBuffer();
    err = StringBuffer();
    logger = CliLogger(out: out, err: err);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String writeConfig({
    String output = 'lib/l10n',
    String format = 'arb',
    String? catalog,
    String extra = '',
  }) {
    final path = '${dir.path}/easyi18n.yaml';
    File(path).writeAsStringSync(
      'projectId: proj_abc\nformat: $format\noutput: $output\n'
      '${catalog == null ? '' : 'catalog: $catalog\n'}$extra',
    );
    return path;
  }

  /// Builds a runner whose pull command serves [files] (or a backend error)
  /// through a MockClient, with the given environment.
  CommandRunner<int> runnerWith({
    Map<String, String> files = const {'arb/app_en.arb': '{"hi":"Hi"}'},
    http.Response? errorResponse,
    Map<String, String> environment = const {'EASYI18N_TOKEN': 'eik_x'},
    void Function(http.Request)? onRequest,
    // Merged into the served envelope, so a test can add a field this
    // backend version reports (or serve it in a shape it should not).
    Map<String, Object?> extraBody = const {},
  }) {
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        onRequest?.call(req);
        final body = <String, Object?>{
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb'],
          'files': files,
          ...extraBody,
        };
        // `_coverageOf` in `public_api.dart` reports the requested language
        // alone, and never the base: `--lang en` gets `{}`, not the full map.
        final lang = req.url.queryParameters['lang']?.trim();
        if (lang != null && lang.isNotEmpty && body['coverage'] is Map) {
          body['coverage'] = {
            for (final e in (body['coverage'] as Map).entries)
              if (e.key == lang) e.key: e.value,
          };
        }
        return errorResponse ?? http.Response(jsonEncode(body), 200);
      }),
    );
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PullCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factory,
        environment: environment,
      ),
    );
    return runner;
  }

  group('--require-complete (#1052)', () {
    // The Mode A gate: the translations live on the server, so the answer is
    // the pulled version's per-language coverage, not anything in the code.
    Future<int?> pull(CommandRunner<int> runner, List<String> extra) async {
      final path = '${dir.path}/easyi18n.yaml';
      File(path).writeAsStringSync('projectId: proj_abc\nmode: a\n');
      return runner.run(['pull', '--config', path, ...extra]);
    }

    test('an incomplete language fails, named with its missing count',
        () async {
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 3, 'total': 5},
          'fr': {'translated': 5, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('1 language(s) are incomplete'))),
      );
      expect(err.toString(), contains('es: 2 of 5 key(s) untranslated'));
      expect(err.toString(), isNot(contains('fr:')));
      // The files were still written: the gate is a verdict, not a refusal
      // to pull — CI keeps the artefacts of the run it is failing.
      expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isTrue);
    });

    // #1178 — the third combination of the trio. `--watch` + the gate and
    // `--watch` + `--dry-run` were both pinned as REFUSALS; this one is the
    // only one whose behaviour has to be asserted, and it had no test at
    // all: the gate could be moved inside the `if (!dryRun)` branch and both
    // suites stayed green, turning a cheap CI gate into an exit 0 over the
    // state the real run refuses. That is #955, in the sibling command.
    test('--dry-run still gates, and writes nothing', () async {
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 3, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete', '--dry-run']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('1 language(s) are incomplete'))),
      );
      expect(err.toString(), contains('es: 2 of 5 key(s) untranslated'));
      expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isFalse,
          reason: 'the dry run is what keeps the disk clean, not the gate');
    });

    test('--dry-run without the flag is unaffected by coverage', () async {
      // The discriminating half: the same incomplete coverage, and nothing
      // to gate on. Without it, a gate that fired for any dry run would read
      // as correct above.
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 0, 'total': 5},
        },
      });
      expect(await pull(runner, ['--dry-run']), 0);
      expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isFalse);
    });

    test('every language complete exits 0 and says so', () async {
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 5, 'total': 5},
        },
      });
      expect(await pull(runner, ['--require-complete']), 0);
      expect(out.toString(), contains('Complete: every target language'));
    });

    // The server narrows the response itself (`?lang=` reports that language
    // only, because a sharded version is assembled from one shard), so the
    // fixture is the response the real backend sends — a two-language map
    // under `--lang fr` is a state that route cannot produce.
    test('--lang fr passes on the complete language the server reports',
        () async {
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'fr': {'translated': 5, 'total': 5},
        },
      });
      expect(await pull(runner, ['--require-complete', '--lang', 'fr']), 0);
    });

    test('--lang es fails on the incomplete one', () async {
      // The symmetric case, and the one that proves the flag does not pass
      // by narrowing to nothing.
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 3, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete', '--lang', 'es']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('1 language(s) are incomplete'))),
      );
      expect(err.toString(), contains('es: 2 of 5 key(s) untranslated'));
    });

    test('a config with no mode line is told to add it', () async {
      // `b` is the default, so a hand-written gen_l10n config reads Mode B —
      // and the two commands the refusal used to name are the ones #1052
      // documents as unusable for exactly that project. The remedy has to be
      // the config line.
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 5, 'total': 5},
        },
      });
      final path = '${dir.path}/easyi18n.yaml';
      File(path).writeAsStringSync('projectId: proj_abc\n');
      await expectLater(
        runner.run(['pull', '--config', path, '--require-complete']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            allOf(contains('add `mode: a`'), contains('mode: b')))),
      );
    });

    test('a version published with the source fallback is refused, not passed',
        () async {
      // `incompleteMode: source` bakes the base text into every untranslated
      // cell, so the count reads 100% over a half-translated project. The
      // local `mode: a` says who publishes, never how THIS version was
      // published.
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'source',
        'coverage': {
          'es': {'translated': 5, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            allOf(contains('incompleteMode: source'),
                contains('cannot verify')))),
      );
    });

    test('a basis the export cannot send is refused, not trusted', () async {
      // `hold` used to pass this gate. No publish can stamp it (it degrades
      // to `skip`), so the branch was reachable only by a server that does
      // not exist — and a value nobody defined `coverage` semantics for
      // reading as judgeable is the shape #1052 exists to prevent (#1179).
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'hold',
        'coverage': {
          'es': {'translated': 5, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete']),
        // Asserted against the basis it names AND against the message for the
        // ABSENT case, which is the other state this arm answers: a substring
        // both of them satisfy pins the refusal without pinning its cause,
        // and the advice differs (republishing fixes an absent stamp and
        // returns this one unchanged).
        throwsA(isA<CliException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('treated untranslated cells as `hold`'),
              contains('Upgrade easyi18n_cli'),
              isNot(contains('does not say how it treated')),
            ))),
      );
    });

    test('a version that does not say how it treated cells is refused',
        () async {
      // A snapshot minted before the field: absent is unknown, and a gate
      // that assumes on unknown is the green this whole flag exists to stop.
      final runner = runnerWith(extraBody: {
        'coverage': {
          'es': {'translated': 5, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete']),
        // The other half of the discrimination above: absent must not read as
        // the message for a basis this CLI merely does not recognize.
        throwsA(isA<CliException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('does not say how it treated'),
              contains('Publish again to stamp the version'),
              isNot(contains('Upgrade easyi18n_cli')),
            ))),
      );
    });

    test('no target language is nothing to verify, not a green', () async {
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': <String, Object?>{},
      });
      await expectLater(
        pull(runner, ['--require-complete']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('no target language'))),
      );
    });

    test('a backend that reports no coverage cannot pass the gate', () async {
      // Silence is not completeness: an older backend, or an odd shape.
      for (final body in <Map<String, Object?>>[
        // A backend older than `1e69bfdf` sends neither key (#1263); the
        // basis check must not answer first and ask for a republish.
        const {},
        const {'coverageBasis': 'skip'},
        const {'coverageBasis': 'skip', 'coverage': 'nope'},
        const {
          'coverageBasis': 'skip',
          'coverage': {
            'es': {'translated': 'three', 'total': 5},
          },
        },
      ]) {
        final runner = runnerWith(extraBody: body);
        await expectLater(
          pull(runner, ['--require-complete']),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              contains('did not report per-language coverage'))),
          reason: '$body',
        );
      }
    });

    test('without the flag coverage changes nothing', () async {
      final runner = runnerWith(extraBody: {
        'coverage': {
          'es': {'translated': 0, 'total': 5},
        },
      });
      expect(await pull(runner, const []), 0);
    });

    test('refused outside Mode A: a source-mode publish always reads complete',
        () async {
      final runner = runnerWith(extraBody: {
        'coverage': {
          'es': {'translated': 0, 'total': 5},
        },
      });
      final path = '${dir.path}/easyi18n.yaml';
      File(path).writeAsStringSync('projectId: proj_abc\nmode: b\n');
      await expectLater(
        runner.run(['pull', '--config', path, '--require-complete']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('is the Mode A gate'))),
      );
    });

    test('--lang naming the base has nothing to verify and says so',
        () async {
      // The version carries `es`, so the route answers `--lang en` with `{}`
      // (#1261): that is the base, not a version without target languages.
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 0, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete', '--lang', 'en']),
        throwsA(isA<CliException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('--lang en is the base language'),
              isNot(contains('reports no target language')),
            ))),
      );
    });

    for (final blank in ['', '  ']) {
      test('--lang ${jsonEncode(blank)} is the whole catalogue, as it is on '
          'the wire', () async {
        // The route trims `lang` and reads an empty one as no filter, so the
        // gate must too: `--lang "$UNSET"` in a CI matrix.
        final runner = runnerWith(extraBody: {
          'coverageBasis': 'skip',
          'coverage': {
            'es': {'translated': 0, 'total': 5},
          },
        });
        await expectLater(
          pull(runner, ['--require-complete', '--lang', blank]),
          throwsA(isA<CliException>().having((e) => e.message, 'message',
              contains('1 language(s) are incomplete'))),
        );
      });
    }

    test('a padded --lang gates the locale the route renders for it',
        () async {
      // The route renders `es` for `?lang= es `; reading the padded value
      // here named `es` the base language.
      final runner = runnerWith(extraBody: {
        'coverageBasis': 'skip',
        'coverage': {
          'es': {'translated': 0, 'total': 5},
        },
      });
      await expectLater(
        pull(runner, ['--require-complete', '--lang', ' es ']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('1 language(s) are incomplete'))),
      );
    });

    test('is one-shot: refused with --watch', () async {
      final runner = runnerWith();
      await expectLater(
        pull(runner, ['--require-complete', '--watch']),
        throwsA(isA<CliException>().having((e) => e.message, 'message',
            contains('cannot be combined with --watch'))),
      );
    });
  });

  test('resolves a @handle/slug config once, then pulls by the id', () async {
    final path = '${dir.path}/easyi18n.yaml';
    File(path).writeAsStringSync('workspace: acme\nproject: dogfood\n');

    final paths = <String>[];
    TranslationsApiClient factory({
      required String baseUrl,
      required String token,
    }) => TranslationsApiClient(
      baseUrl: baseUrl,
      token: token,
      httpClient: MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/v1/projects/resolve') {
          expect(req.url.queryParameters['workspace'], 'acme');
          expect(req.url.queryParameters['project'], 'dogfood');
          return http.Response(
            jsonEncode({'projectId': 'proj_abc', 'workspaceId': 'ws_1'}),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'project': 'proj_abc',
            'version': '2026.06.26',
            'baseCode': 'en',
            'formats': ['arb'],
            'files': {'arb/app_en.arb': '{"hi":"Hi"}'},
          }),
          200,
        );
      }),
    );
    final runner = CommandRunner<int>('easyi18n', '')
      ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
    runner.addCommand(
      PullCommand(
        output: CliOutput(logger: logger),
        apiClientFactory: factory,
        environment: const {'EASYI18N_TOKEN': 'eik_x'},
      ),
    );

    final code = await runner.run(['--config', path, 'pull']);
    expect(code, 0);
    expect(paths, [
      '/v1/projects/resolve',
      '/v1/projects/proj_abc/translations',
    ]);
    expect(
      File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
      '{"hi":"Hi"}',
    );
  });

  test('writes files, stripping the format prefix', () async {
    final code = await runnerWith(
      files: {
        'arb/app_en.arb': '{"hi":"Hi"}',
        'arb/app_es.arb': '{"hi":"Hola"}',
      },
    ).run(['--config', writeConfig(), 'pull']);

    expect(code, 0);
    expect(
      File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
      '{"hi":"Hi"}',
    );
    expect(
      File('${dir.path}/lib/l10n/app_es.arb').readAsStringSync(),
      '{"hi":"Hola"}',
    );
  });

  test('pulls a String Catalog as one file at the output root', () async {
    // The whole point of the format for an iOS repo: the catalog lands where
    // Xcode already looks, with every language inside it.
    const catalog = '{"sourceLanguage":"es","strings":{"Ajustes":{}}}';

    final code = await runnerWith(
      files: {'xcstrings/Localizable.xcstrings': catalog},
    ).run(['--config', writeConfig(format: 'xcstrings'), 'pull']);

    expect(code, 0);
    // Written in Xcode's style, not the server's: this file is Xcode's to
    // rewrite, and a first write in a foreign style makes the next pull —
    // which merges, and therefore re-prints — reformat the whole file.
    expect(
      File('${dir.path}/lib/l10n/Localizable.xcstrings').readAsStringSync(),
      '{\n'
      '  "sourceLanguage" : "es",\n'
      '  "strings" : {\n'
      '    "Ajustes" : {\n\n'
      '    }\n'
      '  }\n'
      '}',
    );
  });

  test('a String Catalog under output: is merged too, not replaced', () async {
    // Which config key names the file does not change whose file it is: an
    // .xcstrings is Xcode's either way, so `output:` gets the same treatment.
    final config = writeConfig(format: 'xcstrings');
    File('${dir.path}/lib/l10n/Localizable.xcstrings')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '{"sourceLanguage":"es","strings":{"Solo local":{}},"version":"1.1"}',
      );

    await runnerWith(
      files: {
        'xcstrings/Localizable.xcstrings':
            '{"sourceLanguage":"es","strings":{"Del server":{}},'
                '"version":"1.0"}',
      },
    ).run(['--config', config, 'pull']);

    final doc =
        jsonDecode(
              File(
                '${dir.path}/lib/l10n/Localizable.xcstrings',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect((doc['strings']! as Map).keys, ['Solo local', 'Del server']);
    // The local file's declared format version is the local file's business.
    expect(doc['version'], '1.1');
  });

  test('warns about a mistyped setting, and still pulls', () async {
    // The typo that started #552: an unreadable key falls back to a default,
    // so the pull "succeeds" into a directory nobody configured.
    final code = await runnerWith().run([
      '--config',
      writeConfig(extra: 'ouput: EscapeCall\n'),
      'pull',
    ]);

    expect(code, 0);
    expect(err.toString(), contains('ouput'));
    expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isTrue);
  });

  test('creates nested parent directories', () async {
    await runnerWith(
      files: {'arb/sub/app_en.arb': 'x'},
    ).run(['--config', writeConfig(), 'pull']);

    expect(File('${dir.path}/lib/l10n/sub/app_en.arb').existsSync(), isTrue);
  });

  test('dry-run does not write files', () async {
    await runnerWith().run(['--config', writeConfig(), 'pull', '--dry-run']);

    expect(Directory('${dir.path}/lib/l10n').existsSync(), isFalse);
    expect(out.toString(), contains('Would pull'));
  });

  test(
    'a real pull records the pulled version in .easyi18n/state.json',
    () async {
      final config = writeConfig();
      await runnerWith().run(['--config', config, 'pull']);

      final state = CliState.load(CliState.fileFor(config));
      expect(state.version, '2026.06.26'); // the mock backend's version
      expect(state.pulledAt, isNotNull);
    },
  );

  test('dry-run does not touch the state file', () async {
    final config = writeConfig();
    await runnerWith().run(['--config', config, 'pull', '--dry-run']);

    expect(CliState.fileFor(config).existsSync(), isFalse);
  });

  group('snapshotAt (#898)', () {
    // Publish and pull are separated by 13 DAYS on purpose. The window this
    // closes is never milliseconds — a pull renders the published snapshot,
    // not the live keys — and a fixture whose `snapshotAt` sits at `now`
    // measures the same in both branches and certifies nothing.
    const servedSnapshot = '2026-08-20T09:00:00.000Z';
    final publishedInstant = DateTime.utc(2026, 8, 20, 9);

    void expectDatedByLocalClock(DateTime? at) {
      expect(at, isNotNull);
      expect(
        DateTime.now().toUtc().difference(at!).inMinutes.abs(),
        lessThan(5),
      );
    }

    test(
      'output: pull --version <old> records when that version was PUBLISHED, '
      'not when the pull ran',
      () async {
        final config = writeConfig();
        await runnerWith(
          extraBody: const {'snapshotAt': servedSnapshot},
        ).run(['--config', config, 'pull', '--version', '2026.08.20.1']);

        final state = CliState.load(CliState.fileFor(config));
        expect(state.snapshotAt, publishedInstant);
        // The field is ADDED, not recycled: `status` prints `pulled <ago>`
        // off `pulledAt`, so it has to keep saying "just now" right after a
        // pull that served two-week-old content.
        expectDatedByLocalClock(state.pulledAt);
      },
    );

    test(
      'catalog: the same, and this is the site `sync` actually claims from',
      () async {
        final config = writeConfig(
          format: 'xcstrings',
          catalog: 'EscapeCall/Localizable.xcstrings',
        );
        await runnerWith(
          files: {
            'xcstrings/Localizable.xcstrings': jsonEncode({
              'sourceLanguage': 'en',
              'strings': <String, Object?>{},
              'version': '1.0',
            }),
          },
          extraBody: const {'snapshotAt': servedSnapshot},
        ).run(['--config', config, 'pull', '--version', '2026.08.20.1']);

        final state = CliState.load(CliState.fileFor(config));
        expect(state.catalog, 'EscapeCall/Localizable.xcstrings');
        expect(state.snapshotAt, publishedInstant);
        expectDatedByLocalClock(state.pulledAt);
      },
    );

    test('a backend that reports no snapshot dates the pull by the local '
        'clock — the claim is never LOST', () async {
      final config = writeConfig();
      await runnerWith().run(['--config', config, 'pull']);

      final state = CliState.load(CliState.fileFor(config));
      expectDatedByLocalClock(state.snapshotAt);
    });

    test('a snapshot AHEAD of the local clock is recorded, not clamped',
        () async {
      // Deliberate. After this change the guard compares the server's own
      // stamps against each other; clamping to the client's clock would
      // reinject the one clock the comparison just stopped depending on, and
      // make the same repo against the same server answer differently on two
      // machines. Pinned so nobody "fixes" the missing clamp.
      final config = writeConfig();
      await runnerWith(
        extraBody: const {'snapshotAt': '2099-01-01T00:00:00.000Z'},
      ).run(['--config', config, 'pull']);

      final state = CliState.load(CliState.fileFor(config));
      expect(state.snapshotAt, DateTime.utc(2099));
      expect(state.snapshotAt!.isAfter(state.pulledAt!), isTrue);
    });

    test('a snapshot that names no zone is dropped, not guessed', () async {
      // West of UTC a bare stamp moves FORWARD, which disarms the server's
      // guard silently. Degrading to the local clock is the pre-#898
      // behavior; guessing is worse than it.
      final config = writeConfig();
      await runnerWith(
        extraBody: const {'snapshotAt': '2026-08-20T09:00:00'},
      ).run(['--config', config, 'pull']);

      final state = CliState.load(CliState.fileFor(config));
      expectDatedByLocalClock(state.snapshotAt);
    });
  });

  group('prune', () {
    /// Seeds the state of a previous pull plus its files on disk.
    void seedPreviousPull(
      String config, {
      required List<String> files,
      String format = 'arb',
      String output = 'lib/l10n',
    }) {
      CliState(
        version: '2026.06.01',
        pulledAt: DateTime.utc(2026, 6),
        format: format,
        output: output,
        files: files,
      ).save(CliState.fileFor(config));
      for (final rel in files) {
        File('${dir.path}/$output/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('old');
      }
    }

    test('a full pull removes recorded files the server renamed', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_en.arb', 'app_zh-hant.arb']);

      await runnerWith(
        files: {
          'arb/app_en.arb': '{"hi":"Hi"}',
          'arb/app_zh_Hant.arb': '{"hi":"zh"}',
        },
      ).run(['--config', config, 'pull']);

      expect(
        File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(),
        isFalse,
      );
      expect(File('${dir.path}/lib/l10n/app_zh_Hant.arb').existsSync(), isTrue);
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"hi":"Hi"}',
      );
      expect(out.toString(), contains('Removed 1 stale file(s)'));
      final state = CliState.load(CliState.fileFor(config));
      expect(state.files, ['app_en.arb', 'app_zh_Hant.arb']);
      expect(state.format, 'arb');
    });

    test('pruning a nested file drops its emptied directory', () async {
      final config = writeConfig(format: 'ios_strings');
      seedPreviousPull(
        config,
        format: 'ios_strings',
        files: ['zh-hant.lproj/Localizable.strings'],
      );

      await runnerWith(
        files: {'ios_strings/zh-Hant.lproj/Localizable.strings': 'x'},
      ).run(['--config', config, 'pull']);

      // Compare literal entry names: on a case-insensitive filesystem
      // (APFS) Directory('zh-hant.lproj').existsSync() would match the
      // fresh zh-Hant.lproj and hide whether the stale dir was removed.
      final names = Directory('${dir.path}/lib/l10n')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, contains('zh-Hant.lproj'));
      expect(names, isNot(contains('zh-hant.lproj')));
      expect(
        File(
          '${dir.path}/lib/l10n/zh-Hant.lproj/Localizable.strings',
        ).existsSync(),
        isTrue,
      );
    });

    for (final blank in ['', '  ']) {
      test('--lang ${jsonEncode(blank)} is a full pull, and prunes like one',
          () async {
        // The server renders every file for a blank `lang` (trimmed, it is
        // no filter on the wire), so reading it as a one-locale pull kept
        // the renamed file and recorded the union.
        final config = writeConfig();
        seedPreviousPull(config, files: ['app_en.arb', 'app_zh-hant.arb']);

        await runnerWith(
          files: {
            'arb/app_en.arb': '{"hi":"Hi"}',
            'arb/app_zh_Hant.arb': '{"hi":"zh"}',
          },
        ).run(['--config', config, 'pull', '--lang', blank]);

        expect(
          File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(),
          isFalse,
        );
        final state = CliState.load(CliState.fileFor(config));
        expect(state.files, ['app_en.arb', 'app_zh_Hant.arb']);
      });
    }

    test('a --lang pull never prunes and merges the recorded files', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_en.arb', 'app_es.arb']);

      await runnerWith(
        files: {'arb/app_es.arb': '{"hi":"Hola"}'},
      ).run(['--config', config, 'pull', '--lang', 'es']);

      expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isTrue);
      final state = CliState.load(CliState.fileFor(config));
      expect(state.files, ['app_en.arb', 'app_es.arb']);
    });

    test(
      'a format switch never prunes but surfaces the stranded files',
      () async {
        final config = writeConfig(format: 'json');
        seedPreviousPull(config, format: 'arb', files: ['app_en.arb']);

        await runnerWith(
          files: {'json/en.json': '{}'},
        ).run(['--config', config, 'pull']);

        expect(File('${dir.path}/lib/l10n/app_en.arb').existsSync(), isTrue);
        expect(out.toString(), contains('no longer manages'));
        expect(out.toString(), contains('app_en.arb'));
        final state = CliState.load(CliState.fileFor(config));
        expect(state.format, 'json');
        expect(state.files, ['en.json']);
      },
    );

    test(
      'an output switch never prunes in the new dir and lists the old',
      () async {
        // The V1 hazard: recorded rel paths must not be resolved against a NEW
        // output dir — a pre-existing user file there would be deleted.
        final config = writeConfig(output: 'lib/i18n');
        seedPreviousPull(
          config,
          output: 'lib/l10n',
          files: ['app_en.arb', 'app_es.arb'],
        );
        File('${dir.path}/lib/i18n/app_es.arb')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('handwritten');

        await runnerWith(
          files: {'arb/app_en.arb': '{"hi":"Hi"}'},
        ).run(['--config', config, 'pull']);

        // The user's file in the new dir survives; the old dir is untouched.
        expect(
          File('${dir.path}/lib/i18n/app_es.arb').readAsStringSync(),
          'handwritten',
        );
        expect(File('${dir.path}/lib/l10n/app_es.arb').existsSync(), isTrue);
        expect(out.toString(), contains('no longer manages'));
        expect(out.toString(), contains('app_es.arb'));
        final state = CliState.load(CliState.fileFor(config));
        expect(state.output, 'lib/i18n');
        expect(state.files, ['app_en.arb']);
      },
    );

    test('prune sweeps a stranded .tmp from a crashed write', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_zz.arb']);
      File('${dir.path}/lib/l10n/app_zz.arb.tmp').writeAsStringSync('half');

      await runnerWith(
        files: {'arb/app_en.arb': '{"hi":"Hi"}'},
      ).run(['--config', config, 'pull']);

      expect(File('${dir.path}/lib/l10n/app_zz.arb').existsSync(), isFalse);
      expect(File('${dir.path}/lib/l10n/app_zz.arb.tmp').existsSync(), isFalse);
    });

    test('a .DS_Store does not keep an emptied dir alive', () async {
      final config = writeConfig(format: 'ios_strings');
      seedPreviousPull(
        config,
        format: 'ios_strings',
        files: ['zh-hant.lproj/Localizable.strings'],
      );
      File(
        '${dir.path}/lib/l10n/zh-hant.lproj/.DS_Store',
      ).writeAsStringSync('finder');

      await runnerWith(
        files: {'ios_strings/zh-Hant.lproj/Localizable.strings': 'x'},
      ).run(['--config', config, 'pull']);

      final names = Directory('${dir.path}/lib/l10n')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, contains('zh-Hant.lproj'));
      expect(names, isNot(contains('zh-hant.lproj')));
    });

    test('dry-run previews the prune without deleting', () async {
      final config = writeConfig();
      seedPreviousPull(config, files: ['app_zh-hant.arb']);

      await runnerWith(
        files: {'arb/app_zh_Hant.arb': 'x'},
      ).run(['--config', config, 'pull', '--dry-run']);

      expect(File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(), isTrue);
      expect(out.toString(), contains('Would remove 1 stale file(s)'));
      // State untouched: still the seeded pull.
      expect(CliState.load(CliState.fileFor(config)).version, '2026.06.01');
    });

    test('first recording pull hints at files it cannot attribute', () async {
      final config = writeConfig();
      // Pre-upgrade pull: state exists but has no file list.
      CliState(
        version: '2026.06.01',
        pulledAt: DateTime.utc(2026, 6),
      ).save(CliState.fileFor(config));
      File('${dir.path}/lib/l10n/app_zh-hant.arb')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('old');

      await runnerWith(
        files: {'arb/app_zh_Hant.arb': 'x'},
      ).run(['--config', config, 'pull']);

      // Not deleted — only surfaced.
      expect(File('${dir.path}/lib/l10n/app_zh-hant.arb').existsSync(), isTrue);
      expect(out.toString(), contains('app_zh-hant.arb'));
      expect(out.toString(), contains('Not written by this pull'));
    });
  });

  group('a file changed since the pull that wrote it (#2095)', () {
    const v1 = {
      'json/de.json': '{"bye":"Tschüss","hello":"Hallo"}',
      'json/es.json': '{"bye":"Adiós","hello":"Hola"}',
    };
    const v2 = {
      'json/de.json': '{"bye":"Tschüss","hello":"Guten Tag"}',
      'json/es.json': '{"bye":"Adiós","hello":"Buenos días"}',
    };
    const edited = '{"bye":"Adiós","hello":"Buenas (edited by hand)"}';
    late String config;

    File target(String name) => File('${dir.path}/public/i18n/$name');

    Future<int?> pull(Map<String, String> files,
            [List<String> flags = const []]) =>
        runnerWith(files: files)
            .run(['--config', config, 'pull', ...flags]);

    Matcher refuses(List<String> files) => throwsA(isA<CliException>()
        .having((e) => e.code, 'code', 'edited_targets')
        .having((e) => e.exitCode, 'exitCode', 1)
        .having((e) => e.details['edited'], 'edited',
            [for (final f in files) {'file': 'public/i18n/$f'}])
        .having((e) => e.message, 'message',
            allOf([for (final f in files) contains('public/i18n/$f')]))
        .having((e) => e.message, 'message',
            contains('easyi18n pull --force')));

    setUp(() async {
      config = writeConfig(format: 'json', output: 'public/i18n');
      await pull(v1);
    });

    test('is refused before anything is written, and named', () async {
      target('es.json').writeAsStringSync(edited);
      out.clear();

      await expectLater(pull(v2), refuses(['es.json']));

      // Not even the line that announces the files: nothing was pulled.
      expect(out.toString(), isNot(contains('Pulled')));

      expect(target('es.json').readAsStringSync(), edited);
      // `de.json` sorts first: a refusal that came after its write would
      // leave half a pull on disk.
      expect(target('de.json').readAsStringSync(), v1['json/de.json']);
      final record =
          jsonDecode(CliState.fileFor(config).readAsStringSync()) as Map;
      expect((record['digests'] as Map).keys, ['de.json', 'es.json']);
    });

    test('--dry-run names it too', () async {
      target('es.json').writeAsStringSync(edited);
      await expectLater(pull(v2, ['--dry-run']), refuses(['es.json']));
    });

    test('--force replaces it, and the next pull has nothing to refuse',
        () async {
      target('es.json').writeAsStringSync(edited);

      expect(await pull(v2, ['--force']), 0);
      expect(target('es.json').readAsStringSync(), v2['json/es.json']);

      expect(await pull(v1), 0);
      expect(target('es.json').readAsStringSync(), v1['json/es.json']);
    });

    for (final entry in {
      'indented': '{\n    "bye": "Adiós",\n    "hello": "Hola"\n}\n',
      'with its keys in another order': '{"hello":"Hola","bye":"Adiós"}',
      'with CRLF line ends': '{\r\n  "bye": "Adiós",\r\n  "hello": "Hola"\r\n}\r\n',
      'with its text escaped': r'{"bye":"Adiós","hello":"Hola"}',
    }.entries) {
      test('a file rewritten ${entry.key} says the same and is replaced',
          () async {
        target('es.json').writeAsStringSync(entry.value);
        expect(await pull(v2), 0);
        expect(target('es.json').readAsStringSync(), v2['json/es.json']);
      });
    }

    test('a file that already says what this pull serves is not refused',
        () async {
      target('es.json').writeAsStringSync(
          '{\n  "hello": "Buenos días",\n  "bye": "Adiós"\n}');
      expect(await pull(v2), 0);
      expect(target('es.json').readAsStringSync(), v2['json/es.json']);
    });

    test('a file that is no longer JSON is a changed file', () async {
      target('es.json').writeAsStringSync('{"hello": ');
      await expectLater(pull(v2), refuses(['es.json']));
    });

    test('a file that was deleted is written again', () async {
      target('es.json').deleteSync();
      expect(await pull(v2), 0);
      expect(target('es.json').readAsStringSync(), v2['json/es.json']);
    });

    test('a --lang pull reads only the file it writes, and keeps the digest '
        'of the others', () async {
      target('de.json').writeAsStringSync(edited);

      expect(await pull({'json/es.json': v2['json/es.json']!}, ['--lang', 'es']),
          0);
      expect(target('es.json').readAsStringSync(), v2['json/es.json']);
      expect(target('de.json').readAsStringSync(), edited);

      await expectLater(pull(v2), refuses(['de.json']));
    });

    test('a changed file the server stopped serving is not pruned', () async {
      target('de.json').writeAsStringSync(edited);

      await expectLater(
          pull({'json/es.json': v2['json/es.json']!}), refuses(['de.json']));

      expect(target('de.json').readAsStringSync(), edited);
      expect(target('es.json').readAsStringSync(), v1['json/es.json']);
    });

    test('a full pull forgets the digest of a file it no longer writes',
        () async {
      expect(await pull({'json/es.json': v2['json/es.json']!}), 0);
      expect(target('de.json').existsSync(), isFalse);
      expect(CliState.load(CliState.fileFor(config)).digests!.keys,
          ['es.json']);
      // Made by hand afterwards: no pull of this record wrote it.
      target('de.json').writeAsStringSync(edited);
      expect(await pull({'json/es.json': v1['json/es.json']!}), 0);
      expect(target('de.json').readAsStringSync(), edited);
    });

    test('a record written without digests refuses nothing', () async {
      final file = CliState.fileFor(config);
      final record = jsonDecode(file.readAsStringSync()) as Map
        ..remove('digests');
      file.writeAsStringSync(jsonEncode(record));
      target('es.json').writeAsStringSync(edited);

      expect(await pull(v2), 0);
      expect(target('es.json').readAsStringSync(), v2['json/es.json']);
    });

    test('the record of another output directory vouches for nothing',
        () async {
      config = writeConfig(format: 'json', output: 'src/assets/i18n');
      File('${dir.path}/src/assets/i18n/es.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(edited);

      expect(await pull(v2), 0);
      expect(File('${dir.path}/src/assets/i18n/es.json').readAsStringSync(),
          v2['json/es.json']);
    });

    test('a format switch prunes nothing, so a changed file it strands is '
        'not named', () async {
      config = writeConfig(format: 'nested_json', output: 'public/i18n');
      target('de.json').writeAsStringSync(edited);

      expect(await pull({'nested_json/es.json': '{"home":{"hello":"Hola"}}'}),
          0);
      expect(target('de.json').readAsStringSync(), edited);
    });

    test('a String Catalog under output: gets no digest: it is merged, and '
        'an edit in Xcode never stops a pull', () async {
      config = writeConfig(format: 'xcstrings', output: 'catalogs');
      const served = '{"sourceLanguage":"en","strings":{"Hi":{"localizations":'
          '{"es":{"stringUnit":{"state":"translated","value":"Hola"}}}}},'
          '"version":"1.0"}';
      final catalog = File('${dir.path}/catalogs/Localizable.xcstrings');
      expect(await pull({'xcstrings/Localizable.xcstrings': served}), 0);
      expect(CliState.load(CliState.fileFor(config)).digests, isEmpty);

      catalog.writeAsStringSync(
          catalog.readAsStringSync().replaceFirst('"Hola"', '"Buenas"'));
      expect(await pull({'xcstrings/Localizable.xcstrings': served}), 0);
    });

    test('a format that keeps the file name keeps its digest', () async {
      config = writeConfig(format: 'nested_json', output: 'public/i18n');
      target('es.json').writeAsStringSync(edited);
      await expectLater(
          pull({'nested_json/es.json': '{"home":{"hello":"Hola"}}'}),
          refuses(['es.json']));
    });
  });

  group('a changed file in a format that is not JSON (#2095)', () {
    for (final (format, name, first, changed, second) in [
      ('arb', 'app_es.arb', '{"hi":"Hola"}', '{"hi":"Buenas"}', '{"hi":"Qué tal"}'),
      (
        'ios_strings',
        'es.lproj/Localizable.strings',
        '"hi" = "Hola";\n"bye" = "Adiós";\n',
        '"hi" = "Buenas";\n"bye" = "Adiós";\n',
        '"hi" = "Qué tal";\n"bye" = "Adiós";\n',
      ),
    ]) {
      test('$format: refused, and replaced under --force', () async {
        final config = writeConfig(format: format);
        final file = File('${dir.path}/lib/l10n/$name');
        Future<int?> pull(String content, [List<String> flags = const []]) =>
            runnerWith(files: {'$format/$name': content})
                .run(['--config', config, 'pull', ...flags]);
        await pull(first);
        file.writeAsStringSync(changed);

        await expectLater(
            pull(second),
            throwsA(isA<CliException>()
                .having((e) => e.code, 'code', 'edited_targets')
                .having((e) => e.details['edited'], 'edited', [
              {'file': 'lib/l10n/$name'},
            ])));
        expect(file.readAsStringSync(), changed);

        expect(await pull(second, ['--force']), 0);
        expect(file.readAsStringSync(), second);
      });
    }

    test('arb: the stamp of the render is not content', () async {
      final config = writeConfig();
      final file = File('${dir.path}/lib/l10n/app_es.arb');
      String arb(String stamp, String hi) =>
          '{"@@locale":"es","@@last_modified":"$stamp","hi":"$hi"}';
      Future<int?> pull(String content) =>
          runnerWith(files: {'arb/app_es.arb': content})
              .run(['--config', config, 'pull']);
      await pull(arb('2026-10-11T23:12:05Z', 'Hola'));

      // The change is in the dashboard too: the next render says the same
      // under a newer stamp, and replaces the file with no flag.
      file.writeAsStringSync(arb('2026-10-11T23:12:05Z', 'Buenas'));
      expect(await pull(arb('2026-10-12T08:00:00Z', 'Buenas')), 0);
      expect(file.readAsStringSync(), arb('2026-10-12T08:00:00Z', 'Buenas'));

      // A tool that only re-stamps the file changed nothing.
      file.writeAsStringSync(arb('2026-10-13T00:00:00Z', 'Buenas'));
      expect(await pull(arb('2026-10-14T00:00:00Z', 'Qué tal')), 0);
    });

    test('ios_strings: CRLF line ends alone are not a change', () async {
      final config = writeConfig(format: 'ios_strings');
      const name = 'es.lproj/Localizable.strings';
      final file = File('${dir.path}/lib/l10n/$name');
      await runnerWith(files: {'ios_strings/$name': '"hi" = "Hola";\n'})
          .run(['--config', config, 'pull']);
      file.writeAsStringSync('"hi" = "Hola";\r\n');

      expect(
          await runnerWith(files: {'ios_strings/$name': '"hi" = "Qué tal";\n'})
              .run(['--config', config, 'pull']),
          0);
      expect(file.readAsStringSync(), '"hi" = "Qué tal";\n');
    });
  });

  test('uses --token over the environment', () async {
    String? sentAuth;
    await runnerWith(
      environment: const {},
      onRequest: (req) => sentAuth = req.headers['authorization'],
    ).run(['--config', writeConfig(), 'pull', '--token', 'eik_flag']);

    expect(sentAuth, 'Bearer eik_flag');
  });

  test('forwards --version and --lang', () async {
    Uri? sentUri;
    await runnerWith(onRequest: (req) => sentUri = req.url).run([
      '--config',
      writeConfig(),
      'pull',
      '--version',
      '2026.01.01',
      '--lang',
      'es',
    ]);

    expect(sentUri!.queryParameters['version'], '2026.01.01');
    expect(sentUri!.queryParameters['lang'], 'es');
    expect(sentUri!.queryParameters['format'], 'arb');
  });

  test('fails when no token is available', () async {
    expect(
      () => runnerWith(
        environment: const {},
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('EASYI18N_TOKEN'),
        ),
      ),
    );
  });

  test('fails when the backend returns no files', () async {
    expect(
      () =>
          runnerWith(files: const {}).run(['--config', writeConfig(), 'pull']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('no files'),
        ),
      ),
    );
  });

  test('propagates backend errors', () async {
    expect(
      () => runnerWith(
        errorResponse: http.Response(
          jsonEncode({'error': 'not_published', 'message': 'not published'}),
          404,
        ),
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(isA<CliException>()),
    );
  });

  test('refuses a traversing file key (path traversal guard)', () async {
    await expectLater(
      runnerWith(
        files: {'arb/../../../pwned.txt': 'x'},
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(
        isA<CliException>().having(
          (e) => e.message,
          'message',
          contains('outside'),
        ),
      ),
    );
    expect(File('${dir.path}/../../../pwned.txt').existsSync(), isFalse);
  });

  test('refuses an absolute file key that escapes the output dir', () async {
    // An absolute key makes p.join ignore outputDir; the guard must reject it.
    final escaped = '${dir.path}/escaped.txt';
    await expectLater(
      runnerWith(
        files: {escaped: 'x'},
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(isA<CliException>()),
    );
    expect(File(escaped).existsSync(), isFalse);
  });

  test('a pull whose `formats` holds a non-string still writes the files',
      () async {
    // Measured on develop before the #972 fix: exit 0, file written. `formats`
    // has no consumer in this package, so the lazy cast never fired — which is
    // exactly why the reader for it stayed tolerant. A strict one here would
    // turn a working pull into a failing one in a published CLI.
    final code = await runnerWith(
      errorResponse: http.Response(
        jsonEncode({
          'project': 'proj_abc',
          'version': '2026.06.26',
          'baseCode': 'en',
          'formats': ['arb', 1],
          'files': {'arb/app_en.arb': '{"hi":"Hi"}'},
        }),
        200,
      ),
    ).run(['--config', writeConfig(), 'pull']);
    expect(code, 0, reason: err.toString());
    expect(
      File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
      '{"hi":"Hi"}',
    );
  });

  test('a pull whose body is JSON of the wrong shape fails the run', () async {
    await expectLater(
      runnerWith(
        errorResponse: http.Response('[]', 200),
      ).run(['--config', writeConfig(), 'pull']),
      throwsA(isA<CliException>()),
    );
  });

  group('--watch', () {
    /// A runner whose backend serves [metaVersions] from `/meta` (one per
    /// CALL, clamping on the last) and version-stamped files from
    /// `/translations`. The sleeper is a no-op so cycles run instantly — and
    /// so is the client's retry backoff, since one call is no longer one
    /// cycle: a transient status is replayed [kMaxApiAttempts] times inside
    /// the same cycle before the watcher ever sees it (#591).
    CommandRunner<int> watchRunnerWith({
      required List<Object> metaVersions, // String version | int (HTTP error)
      required int cycles,
    }) {
      var metaCalls = 0;
      var served = '';
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        wait: (_) async {},
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/meta')) {
            final step =
                metaVersions[metaCalls.clamp(0, metaVersions.length - 1)];
            metaCalls++;
            if (step is int) return http.Response('boom', step);
            served = step as String;
            return http.Response(
              jsonEncode({'currentVersionId': step, 'baseCode': 'en'}),
              200,
            );
          }
          final version = served.isEmpty ? 'v1' : served;
          return http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': version,
              'baseCode': 'en',
              'formats': ['arb'],
              'files': {'arb/app_en.arb': '{"v":"$version"}'},
            }),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: cycles,
        ),
      );
      return runner;
    }

    group('over a file changed since the pull that wrote it (#2095)', () {
      late String config;
      late File file;

      setUp(() async {
        config = writeConfig();
        file = File('${dir.path}/lib/l10n/app_en.arb');
        await watchRunnerWith(metaVersions: ['v1'], cycles: 1)
            .run(['--config', config, 'pull', '--watch']);
        file.writeAsStringSync('{"v":"edited by hand"}');
        err.clear();
      });

      test('leaves it alone and names it on every cycle', () async {
        final code = await watchRunnerWith(metaVersions: ['v2'], cycles: 2)
            .run(['--config', config, 'pull', '--watch']);
        expect(code, 0);
        expect(file.readAsStringSync(), '{"v":"edited by hand"}');
        expect(
            'lib/l10n/app_en.arb: changed since'.allMatches('$err'), hasLength(3));
      });

      test('--force replaces it', () async {
        await watchRunnerWith(metaVersions: ['v2'], cycles: 1)
            .run(['--config', config, 'pull', '--watch', '--force']);
        expect(file.readAsStringSync(), '{"v":"v2"}');
        expect('$err', isNot(contains('changed since')));
      });
    });

    test('re-pulls when meta reports a new version', () async {
      final code = await watchRunnerWith(
        metaVersions: ['v1', 'v2', 'v2'],
        cycles: 3,
      ).run(['--config', writeConfig(), 'pull', '--watch', '--interval', '5']);
      expect(code, 0);
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"v":"v2"}',
      );
      expect(out.toString(), contains('New version v2'));
      // Initial pull + one re-pull; the unchanged cycle does not pull again.
      expect('Pulled 1 file(s)'.allMatches(out.toString()).length, 2);
    });

    test('a meta error the retries cannot absorb warns and keeps watching',
        () async {
      // Three 500s, not one: the client now replays a transient status within
      // the cycle, so a single blip never reaches the watcher at all. What the
      // watcher must still survive is the failure that outlives the retries.
      final code = await watchRunnerWith(
        metaVersions: [500, 500, 500, 'v3'],
        cycles: 2,
      ).run(['--config', writeConfig(), 'pull', '--watch']);
      expect(code, 0);
      expect(err.toString(), contains('retrying next cycle'));
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"v":"v3"}',
      );
    });

    test('rejects --version and --dry-run combinations', () async {
      await expectLater(
        runnerWith().run([
          '--config',
          writeConfig(),
          'pull',
          '--watch',
          '--version',
          'x',
        ]),
        throwsA(isA<CliException>()),
      );
      await expectLater(
        runnerWith().run([
          '--config',
          writeConfig(),
          'pull',
          '--watch',
          '--dry-run',
        ]),
        throwsA(isA<CliException>()),
      );
    });

    test('started before the first publish, it idles and pulls v1 when it '
        'lands', () async {
      // The bootstrap pull 404s (not_published); the watcher must warn and
      // keep watching, then pull once meta reports the first version.
      var translationsCalls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/meta')) {
            return http.Response(
              jsonEncode({'currentVersionId': 'v1', 'baseCode': 'en'}),
              200,
            );
          }
          translationsCalls++;
          if (translationsCalls == 1) {
            return http.Response(
              jsonEncode({
                'error': 'not_published',
                'message': 'project has no published version',
              }),
              404,
            );
          }
          return http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': 'v1',
              'baseCode': 'en',
              'formats': ['arb'],
              'files': {'arb/app_en.arb': '{"v":"v1"}'},
            }),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: 1,
        ),
      );

      final code = await runner.run([
        '--config',
        writeConfig(),
        'pull',
        '--watch',
      ]);
      expect(code, 0);
      expect(err.toString(), contains('watching for the first publish'));
      expect(
        File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(),
        '{"v":"v1"}',
      );
    });

    test('rejects an interval under 5 seconds', () async {
      await expectLater(
        runnerWith().run([
          '--config',
          writeConfig(),
          'pull',
          '--watch',
          '--interval',
          '1',
        ]),
        throwsA(isA<CliException>()),
      );
    });
  });

  group('catalog:', () {
    // A catalog as Xcode writes it: `" : "` separators, no trailing newline,
    // the empty key it re-adds from code, a `stale` marker the compiler's
    // extraction pass produced, and "Audio" — a string added since the last
    // publish, so the server has never heard of it (#554).
    const local = '''
{
  "sourceLanguage" : "es",
  "strings" : {
    "" : {

    },
    "Audio" : {
      "extractionState" : "manual"
    },
    "Ajustes" : {
      "comment" : "Settings screen title",
      "extractionState" : "stale",
      "isCommentAutoGenerated" : true
    }
  },
  "version" : "1.0"
}''';

    final served = jsonEncode({
      'sourceLanguage': 'es',
      'strings': {
        'Ajustes': {
          'comment': 'Settings screen title',
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': 'Settings'},
            },
          },
        },
        'Del dashboard': {
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': 'From dashboard'},
            },
          },
        },
      },
      'version': '1.0',
    });

    late String configPath;
    late File catalogFile;

    setUp(() {
      configPath = writeConfig(
        format: 'xcstrings',
        catalog: 'EscapeCall/Localizable.xcstrings',
      );
      catalogFile = File('${dir.path}/EscapeCall/Localizable.xcstrings')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(local);
    });

    /// A pull whose backend serves [served] under a filename that has nothing
    /// to do with the configured path.
    Future<int?> pull([List<String> args = const []]) => runnerWith(
      files: {'xcstrings/Localizable.xcstrings': served},
    ).run(['--config', configPath, 'pull', ...args]);

    Map<String, Object?> stringsOf(String raw) =>
        (jsonDecode(raw) as Map<String, Object?>)['strings']!
            as Map<String, Object?>;

    test('writes to the configured catalog, not the output dir', () async {
      expect(await pull(), 0);

      expect(catalogFile.readAsStringSync(), contains('"Settings"'));
      // The bug: a configured catalog landing in Flutter's default arb-dir,
      // in an Xcode project that has no lib/ at all (#552).
      expect(Directory('${dir.path}/lib').existsSync(), isFalse);
      expect(out.toString(), contains('EscapeCall/Localizable.xcstrings'));
    });

    test('keeps keys the server has not been told about yet', () async {
      await pull();

      final strings = stringsOf(catalogFile.readAsStringSync());
      // "Audio" and the empty key are only in the local file. A plain
      // overwrite deletes them, and only an Xcode rebuild brings them back.
      expect(strings.keys, containsAll(<String>['', 'Audio', 'Ajustes']));
    });

    test('keeps the per-key metadata only Xcode can produce', () async {
      await pull();

      final ajustes =
          stringsOf(catalogFile.readAsStringSync())['Ajustes']!
              as Map<String, Object?>;
      // `extractionState` comes from the compiler's pass over the sources,
      // which the backend never sees — dropping it is unrecoverable (#553).
      expect(ajustes['extractionState'], 'stale');
      expect(ajustes['isCommentAutoGenerated'], true);
      expect(
        (((ajustes['localizations']! as Map)['en'] as Map)['stringUnit']
            as Map)['value'],
        'Settings',
      );
    });

    test('delivers a key created in the dashboard', () async {
      await pull();

      // Nothing was uploaded, so the pull is the only path into the file.
      expect(
        stringsOf(catalogFile.readAsStringSync()).containsKey('Del dashboard'),
        isTrue,
      );
    });

    test('a second pull changes nothing, byte for byte', () async {
      await pull();
      final first = catalogFile.readAsStringSync();
      await pull();

      expect(catalogFile.readAsStringSync(), first);
    });

    test('converges from an empty checkout in one pull', () async {
      // No local catalog: the first write must already be in Xcode's style,
      // or the second pull reformats the whole file.
      catalogFile.deleteSync();
      await pull();
      final first = catalogFile.readAsStringSync();
      await pull();

      expect(catalogFile.readAsStringSync(), first);
      expect(first.endsWith('\n'), isFalse);
      expect(first, contains('"sourceLanguage" : "es"'));
    });

    test('records the catalog destination, and nothing prunable', () async {
      await pull();

      final state = CliState.load(CliState.fileFor(configPath));
      expect(state.version, '2026.06.26');
      expect(state.pulledAt, isNotNull);
      expect(state.catalog, 'EscapeCall/Localizable.xcstrings');
      // `output`/`files` scope pruning to a dir this pull never wrote into.
      expect(state.output, isNull);
      expect(state.files, isNull);
    });

    test('dry-run touches neither the catalog nor the state', () async {
      await pull(['--dry-run']);

      expect(catalogFile.readAsStringSync(), local);
      expect(CliState.fileFor(configPath).existsSync(), isFalse);
      expect(out.toString(), contains('Would write'));
    });

    test('rejects --lang: a String Catalog holds every language', () async {
      // The single-locale render drops the base values the keys are
      // addressed by, so it would merge nothing while reporting success.
      await expectLater(pull(['--lang', 'en']), throwsA(isA<CliException>()));
      expect(catalogFile.readAsStringSync(), local);
    });

    test('--watch rejects --lang up front, instead of warning forever',
        () async {
      // The watch loop treats a CliException as a hiccup and retries. A
      // permanent config fault must never enter it: it would warn once per
      // cycle for as long as the process lives, write nothing, and exit 0.
      await expectLater(
        pull(['--watch', '--lang', 'en']),
        throwsA(isA<CliException>()),
      );
    });

    test('--watch exits on a fault that appears mid-run', () async {
      // The bootstrap pull succeeds; the fault shows up on a later cycle (a
      // second catalog added to the project). The loop has its own escape.
      var calls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/meta')) {
            return http.Response(
              jsonEncode({'currentVersionId': 'v2', 'baseCode': 'es'}),
              200,
            );
          }
          calls++;
          return http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': calls == 1 ? 'v1' : 'v2',
              'baseCode': 'es',
              'formats': ['xcstrings'],
              'files': calls == 1
                  ? {'xcstrings/Localizable.xcstrings': served}
                  : {
                      'xcstrings/Localizable.xcstrings': served,
                      'xcstrings/InfoPlist.xcstrings': served,
                    },
            }),
            200,
          );
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: 3,
        ),
      );

      await expectLater(
        runner.run(['--config', configPath, 'pull', '--watch']),
        throwsA(isA<FatalCliException>()),
      );
      // It got as far as the good pull before giving up.
      expect(catalogFile.readAsStringSync(), contains('"Settings"'));
    });

    test('--watch exits on a fault retrying cannot fix', () async {
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient(
          (req) async => http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': '2026.06.26',
              'baseCode': 'es',
              'formats': ['xcstrings'],
              // Two catalogs for one `catalog:` — the server will answer the
              // same next cycle, so there is nothing to wait for.
              'files': {
                'xcstrings/Localizable.xcstrings': served,
                'xcstrings/InfoPlist.xcstrings': served,
              },
            }),
            200,
          ),
        ),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: 3,
        ),
      );

      await expectLater(
        runner.run(['--config', configPath, 'pull', '--watch']),
        throwsA(isA<FatalCliException>()),
      );
    });

    test('--watch EXITS on a body of the wrong shape, it does not warn on it',
        () async {
      // The whole point of the exception class chosen in #972. A wrong-shaped
      // 200 killed the watcher before the fix (uncaught TypeError); a plain
      // CliException would have turned that into a warn-and-retry forever —
      // never writing a file, never failing. The question the loop asks is
      // "can retrying fix this?", and for a schema regression the answer is
      // no. Asserting on the message alone would pass either way.
      var calls = 0;
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient((req) async {
          calls++;
          return http.Response('[]', 200);
        }),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: 3,
        ),
      );

      await expectLater(
        runner.run(['--config', configPath, 'pull', '--watch']),
        throwsA(isA<FatalCliException>()),
      );
      // It gave up on the bootstrap pull instead of spinning through cycles.
      expect(calls, 1);
    });

    test('--watch pulls into the catalog too', () async {
      TranslationsApiClient factory({
        required String baseUrl,
        required String token,
      }) => TranslationsApiClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: MockClient(
          (req) async => http.Response(
            jsonEncode({
              'project': 'proj_abc',
              'version': '2026.06.26',
              'baseCode': 'es',
              'formats': ['xcstrings'],
              'files': {'xcstrings/Localizable.xcstrings': served},
            }),
            200,
          ),
        ),
      );
      final runner = CommandRunner<int>('easyi18n', '')
        ..argParser.addOption('config', defaultsTo: 'easyi18n.yaml');
      runner.addCommand(
        PullCommand(
          output: CliOutput(logger: logger),
          apiClientFactory: factory,
          environment: const {'EASYI18N_TOKEN': 'eik_x'},
          sleeper: (_) async {},
          watchCyclesForTest: 0,
        ),
      );

      await runner.run(['--config', configPath, 'pull', '--watch']);

      expect(catalogFile.readAsStringSync(), contains('"Settings"'));
      expect(Directory('${dir.path}/lib').existsSync(), isFalse);
    });

    test('an empty catalog: falls back to the output dir', () async {
      configPath = writeConfig(format: 'xcstrings', extra: 'catalog:\n');

      expect(await pull(), 0);

      expect(
        File('${dir.path}/lib/l10n/Localizable.xcstrings').existsSync(),
        isTrue,
      );
    });

    test('refuses to guess when the backend serves more than one file',
        () async {
      final code = runnerWith(
        files: {
          'xcstrings/Localizable.xcstrings': served,
          'xcstrings/InfoPlist.xcstrings': served,
        },
      ).run(['--config', configPath, 'pull']);

      await expectLater(code, throwsA(isA<CliException>()));
      expect(catalogFile.readAsStringSync(), local);
    });

    test('refuses a per-locale format, whatever the server happens to serve',
        () async {
      // The dangerous shape is ONE served file: a per-locale format serves
      // exactly one when the project has a single language, so counting files
      // would pass and a locale's render would land inside the catalog,
      // reported as a success — #552's bug from the other side.
      configPath = writeConfig(format: 'arb', catalog: 'App/Catalog.xcstrings');

      await expectLater(
        runnerWith(files: {'arb/app_en.arb': '{"hi":"Hi"}'}).run(
          ['--config', configPath, 'pull'],
        ),
        throwsA(isA<FatalCliException>()),
      );
      expect(File('${dir.path}/App/Catalog.xcstrings').existsSync(), isFalse);
    });

    test('a per-locale format is refused before the request goes out',
        () async {
      configPath = writeConfig(format: 'json', catalog: 'i18n/all.json');
      var called = false;

      await expectLater(
        runnerWith(
          files: {'json/en.json': '{"hi":"Hi"}'},
          onRequest: (_) => called = true,
        ).run(['--config', configPath, 'pull']),
        throwsA(isA<CliException>()),
      );
      // The project ref resolves, but no translations are fetched: the config
      // is knowably wrong without asking the backend anything.
      expect(File('${dir.path}/i18n/all.json').existsSync(), isFalse);
      expect(called, isFalse);
    });

    test('an unwritable state file never fails the pull', () async {
      // `.easyi18n` as a FILE: the state write throws where it creates the
      // directory. The catalog is what matters; the state is a cache.
      File('${dir.path}/.easyi18n').writeAsStringSync('not a directory');

      expect(await pull(), 0);
      expect(catalogFile.readAsStringSync(), contains('"Settings"'));
      expect(out.toString(), contains('Could not update'));
    });

    test('an UNREADABLE state file never fails the pull either', () async {
      // The read is as best-effort as the write: by this point the catalog is
      // already on disk, so failing here reports finished work as a failure.
      // (A `sudo easyi18n pull` leaving the file root-owned does this.)
      final state = File('${dir.path}/.easyi18n/state.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{}');
      Process.runSync('chmod', ['000', state.path]);
      addTearDown(() => Process.runSync('chmod', ['644', state.path]));

      expect(await pull(), 0);
      expect(catalogFile.readAsStringSync(), contains('"Settings"'));
    });

    test('surfaces the stray tree a pre-fix pull left, once', () async {
      // Recovery from #552: the config was always right, but the old CLI
      // wrote into `lib/l10n` and the state recorded it as fact.
      CliState(
        version: '2026.06.01',
        pulledAt: DateTime.utc(2026, 6),
        format: 'xcstrings',
        output: 'lib/l10n',
        files: ['Localizable.xcstrings'],
      ).save(CliState.fileFor(configPath));
      File('${dir.path}/lib/l10n/Localizable.xcstrings')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('stray');

      await pull();
      expect(out.toString(), contains('no longer manages'));
      expect(out.toString(), contains('Localizable.xcstrings'));

      out.clear();
      await pull();
      // One-shot: the record it reported on is gone from the state.
      expect(out.toString(), isNot(contains('no longer manages')));
    });
  });

  group('base source edits (#646)', () {
    // An identifier-keyed catalog (InfoPlist-style, #612): the English is
    // prose the developer wrote in Xcode, not a derived render. The developer
    // edited it after the last sync; the server still serves the old phrase.
    // The merge applies the served value (warn-and-apply, never exempt — the
    // exemption is refuted in the issue) and the warning is the only place
    // the developer's text survives.
    const editedText = 'EDITED IN XCODE: mic access for calls.';
    const editedOne = 'EDITED: one call recorded';
    const editedOther = 'EDITED: %lld calls recorded';
    const servedText = 'OLD SERVER PHRASE: so you can speak during a call.';

    final local = jsonEncode({
      'sourceLanguage': 'en',
      'strings': {
        'NSMicrophoneUsageDescription': {
          'extractionState': 'manual',
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': editedText},
            },
            'es': {
              'stringUnit': {'state': 'translated', 'value': 'Viejo español'},
            },
          },
        },
        'calls.recorded': {
          'localizations': {
            'en': {
              'variations': {
                'plural': {
                  'one': {
                    'stringUnit': {'state': 'translated', 'value': editedOne},
                  },
                  'other': {
                    'stringUnit': {
                      'state': 'translated',
                      'value': editedOther,
                    },
                  },
                },
              },
            },
          },
        },
      },
      'version': '1.0',
    });

    final served = jsonEncode({
      'sourceLanguage': 'en',
      'strings': {
        'NSMicrophoneUsageDescription': {
          'localizations': {
            'en': {
              'stringUnit': {'state': 'translated', 'value': servedText},
            },
            'es': {
              'stringUnit': {'state': 'translated', 'value': 'Nuevo español'},
            },
          },
        },
        'calls.recorded': {
          'localizations': {
            'en': {
              'variations': {
                'plural': {
                  'one': {
                    'stringUnit': {
                      'state': 'translated',
                      'value': 'One call recorded',
                    },
                  },
                  'other': {
                    'stringUnit': {
                      'state': 'translated',
                      'value': '%lld calls recorded',
                    },
                  },
                },
              },
            },
          },
        },
      },
      'version': '1.0',
    });

    late String configPath;
    late File catalogFile;

    setUp(() {
      configPath = writeConfig(
        format: 'xcstrings',
        catalog: 'App/InfoPlist.xcstrings',
      );
      catalogFile = File('${dir.path}/App/InfoPlist.xcstrings')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(local);
    });

    Future<int?> pull([List<String> args = const []]) => runnerWith(
      files: {'xcstrings/InfoPlist.xcstrings': served},
    ).run(['--config', configPath, 'pull', ...args]);

    test(
      'pull warns before overwriting a local source edit, naming every '
      'discarded form',
      () async {
        expect(await pull(), 0);

        // Warn-AND-apply: the served source text stands in the file.
        final raw = catalogFile.readAsStringSync();
        expect(raw, contains(servedText));
        expect(raw, isNot(contains(editedText)));

        final warnings = err.toString();
        expect(
          warnings,
          contains('Conflict: NSMicrophoneUsageDescription [en]'),
        );
        expect(warnings, contains('source text'));
        // The discarded texts survive in the log — that is the promise.
        expect(warnings, contains(editedText));
        expect(warnings, contains('Conflict: calls.recorded [en]'));
        expect(warnings, contains(editedOne));
        expect(warnings, contains(editedOther));
        // `es` changed too, but it is a translation, not the source: the
        // sync-side conflict channel owns that report, not the pull merge.
        expect(warnings, isNot(contains('[es]')));
      },
    );

    test('the output-dir path (xcstrings without `catalog:`) warns too',
        () async {
      // Same merge, other destination: format xcstrings pulled into
      // `output:` goes through the per-file loop, not the catalog branch.
      final outConfig = writeConfig(format: 'xcstrings');
      final outFile = File('${dir.path}/lib/l10n/InfoPlist.xcstrings')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(local);

      // Its --dry-run branch warns before the loop's `continue`, too.
      expect(
        await runnerWith(
          files: {'xcstrings/InfoPlist.xcstrings': served},
        ).run(['--config', outConfig, 'pull', '--dry-run']),
        0,
      );
      expect(outFile.readAsStringSync(), local);
      expect(err.toString(), contains('would replace'));
      expect(err.toString(), contains(editedText));
      err.clear();

      final code = await runnerWith(
        files: {'xcstrings/InfoPlist.xcstrings': served},
      ).run(['--config', outConfig, 'pull']);

      expect(code, 0);
      expect(outFile.readAsStringSync(), contains(servedText));
      final warnings = err.toString();
      expect(warnings, contains('Conflict: NSMicrophoneUsageDescription [en]'));
      expect(warnings, contains(editedText));
    });

    test('--dry-run warns without writing, in the conditional (#646 C2)',
        () async {
      expect(await pull(['--dry-run']), 0);

      expect(catalogFile.readAsStringSync(), local);
      final warnings = err.toString();
      expect(warnings, contains('Conflict: NSMicrophoneUsageDescription [en]'));
      expect(warnings, contains('would replace'));
      expect(warnings, contains(editedText));
    });
  });

  group('source: (the base file of a per-locale project)', () {
    // Spaced as a person writes it, so the server's render never equals it.
    const base = '{\n  "hello": "Hello"\n}\n';
    const served = {
      'json/en.json': '{"hello":"Hello"}',
      'json/es.json': '{"hello":"Hola"}',
    };

    String webConfig({
      String source = 'public/i18n/en.json',
      String output = 'public/i18n',
    }) {
      File('${dir.path}/$source')
        ..createSync(recursive: true)
        ..writeAsStringSync(base);
      return writeConfig(
          output: output, format: 'json', extra: 'mode: a\nsource: $source\n');
    }

    String read(String rel) => File('${dir.path}/$rel').readAsStringSync();

    test('a missing source under an alias is still excluded from destinations', () async {
      final config = webConfig(source: 'catalogs/EN.json', output: 'public');
      File('${dir.path}/catalogs/EN.json').deleteSync();
      Link('${dir.path}/public').createSync('${dir.path}/catalogs');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
      expect(File('${dir.path}/catalogs/en.json').existsSync(), isFalse);
      expect(read('catalogs/es.json'), served['json/es.json']);
    });

    for (final source in ['catalog.json', 'catalog.json.tmp', '.easyi18n/state.json']) {
      test('catalog auxiliary destination protects source $source', () async {
        File('${dir.path}/$source')
          ..createSync(recursive: true)..writeAsStringSync(base);
        final config = writeConfig(format: 'xcstrings', catalog: 'catalog.json',
            extra: 'mode: a\nsource: $source\n');
        await expectLater(runnerWith(files: const {'xcstrings/all.xcstrings': '{}'})
            .run(['--config', config, 'pull']),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'source_collision')));
        expect(read(source), base);
      });
    }

    for (final source in ['en.json', 'Source.json']) {
      for (final dryRun in [false, true]) {
        test('physical output alias protects $source dryRun=$dryRun', () async {
          final config = webConfig(source: 'catalogs/$source', output: 'public');
          Link('${dir.path}/public').createSync('${dir.path}/catalogs');
          File('${dir.path}/catalogs/fr.json').writeAsStringSync('{}');
          CliState(format: 'json', output: 'public', files: [source, 'fr.json'])
              .save(CliState.fileFor(config));
          expect(await runnerWith(files: served).run([
            '--config', config, 'pull', if (dryRun) '--dry-run',
          ]), 0);
          expect(File('${dir.path}/catalogs/$source').existsSync(), isTrue);
          expect(read('catalogs/$source'), base);
          expect(File('${dir.path}/catalogs/fr.json').existsSync(), dryRun);
          expect(out.toString(), isNot(contains('stale $source')));
        });
      }
    }

    for (final source in ['public/i18n/es.json.tmp', '.easyi18n/state.json']) {
      test('auxiliary destination $source refuses before any file changes', () async {
        final config = webConfig(source: source);
        final target = File('${dir.path}/public/i18n/en.json')
          ..createSync(recursive: true)..writeAsStringSync('old target');
        await expectLater(runnerWith(files: served).run(['--config', config, 'pull']),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'source_collision')));
        expect(read(source), base);
        expect(target.readAsStringSync(), 'old target');
        expect(File('${dir.path}/public/i18n/es.json').existsSync(), isFalse);
      });
    }

    test('prune protects a source occupying a stale temporary', () async {
      final config = webConfig(source: 'public/i18n/fr.json.tmp');
      const CliState(format: 'json', output: 'public/i18n', files: ['fr.json'])
          .save(CliState.fileFor(config));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
      expect(File('${dir.path}/public/i18n/fr.json.tmp').existsSync(), isTrue);
      expect(read('public/i18n/fr.json.tmp'), base);
    });

    for (final aliasSource in [false, true]) {
      test('file alias protects source aliasSource=$aliasSource', () async {
        final config = webConfig(source: 'catalogs/en.json');
        Directory('${dir.path}/public/i18n').createSync(recursive: true);
        final source = '${dir.path}/catalogs/en.json';
        final target = '${dir.path}/public/i18n/en.json';
        if (aliasSource) {
          File(source).renameSync(target);
          Link(source).createSync(target);
        } else {
          Link(target).createSync(source);
        }
        expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
        expect(read('catalogs/en.json'), base);
        expect(read('public/i18n/en.json'), base);
        expect(read('public/i18n/es.json'), served['json/es.json']);
      });
    }

    for (final hardLink in [false, true]) {
      test('temporary file alias refuses before prune hardLink=$hardLink', () async {
        final config = webConfig(source: 'catalogs/source.json');
        Directory('${dir.path}/public/i18n').createSync(recursive: true);
        final source = '${dir.path}/catalogs/source.json';
        final tmp = '${dir.path}/public/i18n/es.json.tmp';
        if (hardLink) {
          expect(Process.runSync('ln', [source, tmp]).exitCode, 0);
        } else {
          Link(tmp).createSync(source);
        }
        File('${dir.path}/public/i18n/fr.json').writeAsStringSync('stale');
        const CliState(format: 'json', output: 'public/i18n', files: ['fr.json'])
            .save(CliState.fileFor(config));
        final before = CliState.fileFor(config).readAsStringSync();
        await expectLater(runnerWith(files: served).run(['--config', config, 'pull']),
            throwsA(isA<CliException>().having((e) => e.code, 'code', 'source_collision')));
        expect(read('catalogs/source.json'), base);
        expect(read('public/i18n/fr.json'), 'stale');
        expect(CliState.fileFor(config).readAsStringSync(), before);
      });
    }

    test('empty-directory cleanup keeps a source named .DS_Store', () async {
      final config = webConfig(source: 'public/i18n/old/.DS_Store');
      File('${dir.path}/public/i18n/old/fr.json').writeAsStringSync('{}');
      const CliState(format: 'json', output: 'public/i18n', files: ['old/fr.json'])
          .save(CliState.fileFor(config));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
      expect(File('${dir.path}/public/i18n/old/.DS_Store').existsSync(), isTrue);
      expect(read('public/i18n/old/.DS_Store'), base);
      expect(File('${dir.path}/public/i18n/old/fr.json').existsSync(), isFalse);
    });

    test('a plain pull writes the other locales and leaves the base file '
        'byte-identical', () async {
      final config = webConfig();
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(read('public/i18n/en.json'), base);
      expect(read('public/i18n/es.json'), served['json/es.json']);
      expect(CliState.load(CliState.fileFor(config)).files, ['es.json']);
      expect(out.toString(), contains('Pulled 1 file(s)'));
      expect(out.toString(), contains('en.json left as it is'));
    });

    test('--lang leaves it byte-identical too', () async {
      // The route serves the requested language alone under `?lang=`.
      expect(
        await runnerWith(files: {'json/es.json': served['json/es.json']!})
            .run(['--config', webConfig(), 'pull', '--lang', 'es']),
        0,
      );
      expect(read('public/i18n/en.json'), base);
      expect(read('public/i18n/es.json'), served['json/es.json']);
    });

    // A pull of a CLI without this rule recorded the base file as its own.
    test('a state file that lists the base file does not get it pruned',
        () async {
      final config = webConfig();
      File('${dir.path}/public/i18n/fr.json').writeAsStringSync('{}');
      const CliState(
        format: 'json',
        output: 'public/i18n',
        files: ['en.json', 'es.json', 'fr.json'],
      ).save(CliState.fileFor(config));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      // The prune ran: the language the server no longer serves is gone.
      expect(File('${dir.path}/public/i18n/fr.json').existsSync(), isFalse);
      expect(read('public/i18n/en.json'), base);
    });

    test('a source absent from the render is never pruned', () async {
      final config = webConfig(source: 'public/i18n/source.json');
      File('${dir.path}/public/i18n/fr.json').writeAsStringSync('{}');
      const CliState(
        format: 'json',
        output: 'public/i18n',
        files: ['source.json', 'fr.json'],
      ).save(CliState.fileFor(config));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(File('${dir.path}/public/i18n/source.json').existsSync(), isTrue);
      expect(read('public/i18n/source.json'), base);
      expect(File('${dir.path}/public/i18n/fr.json').existsSync(), isFalse);
    });

    for (final source in ['Source.json', 'SOURCE.JSON', 'source.json']) {
      for (final recorded in ['Source.json', 'SOURCE.JSON', 'source.json']) {
        for (final dryRun in [false, true]) {
          test('source identity protects $source recorded as $recorded '
              'dryRun=$dryRun', () async {
            final config = webConfig(source: 'public/i18n/$source');
            final file = File('${dir.path}/public/i18n/$source');
            final bytes = file.readAsBytesSync();
            final stale = File('${dir.path}/public/i18n/fr.json')
              ..writeAsStringSync('{}');
            CliState(format: 'json', output: 'public/i18n',
                files: [recorded, 'fr.json']).save(CliState.fileFor(config));
            expect(await runnerWith(files: served).run([
              '--config', config, 'pull', if (dryRun) '--dry-run',
            ]), 0);
            expect(file.existsSync(), isTrue);
            expect(file.readAsBytesSync(), bytes);
            expect(stale.existsSync(), dryRun);
            expect(out.toString(), isNot(contains('stale $recorded')));
          });
        }
      }
    }

    test('source identity normalizes recorded path segments before pruning', () async {
      final config = webConfig(source: 'public/i18n/Source.json');
      const CliState(format: 'json', output: 'public/i18n',
          files: ['./Source.json']).save(CliState.fileFor(config));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
      expect(File('${dir.path}/public/i18n/Source.json').existsSync(), isTrue);
      expect(read('public/i18n/Source.json'), base);
    });

    test('a mixed-case source absent from the render is not a leftover', () async {
      final config = webConfig(source: 'public/i18n/Source.json');
      File('${dir.path}/public/i18n/fr.json').writeAsStringSync('{}');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
      expect(out.toString(), contains('Not written by this pull: fr.json.'));
      expect(read('public/i18n/Source.json'), base);
    });

    test('a source in the previous output is not called stranded', () async {
      final config = webConfig(source: 'old/Source.json');
      File('${dir.path}/old/fr.json').writeAsStringSync('{}');
      const CliState(format: 'json', output: 'old',
          files: ['Source.json', 'fr.json']).save(CliState.fileFor(config));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']), 0);
      expect(out.toString(), contains('manages: fr.json.'));
      expect(read('old/Source.json'), base);
    });

    test('a source absent from the render is not called a leftover', () async {
      final config = webConfig(source: 'public/i18n/source.json');
      File('${dir.path}/public/i18n/fr.json').writeAsStringSync('{}');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(out.toString(), contains('Not written by this pull: fr.json.'));
    });

    test('the first recorded pull does not call the base file a leftover',
        () async {
      final config = webConfig();
      File('${dir.path}/public/i18n/fr.json').writeAsStringSync('{}');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(out.toString(), contains('Not written by this pull: fr.json.'));
    });

    // The server names a file `pt-BR.json`; on a case-insensitive disk that
    // is the directory entry of a base file spelled `pt-br.json`.
    test('the served name matches the base file without case', () async {
      final config = webConfig(source: 'public/i18n/pt-br.json');
      expect(
        await runnerWith(files: {
          'json/pt-BR.json': '{"hello":"Olá"}',
          'json/es.json': served['json/es.json']!,
        }).run(['--config', config, 'pull']),
        0,
      );
      expect(read('public/i18n/pt-br.json'), base);
      expect(
        Directory('${dir.path}/public/i18n')
            .listSync()
            .map((e) => e.uri.pathSegments.last)
            .toSet(),
        {'pt-br.json', 'es.json'},
      );
    });

    // `source:` names a file, not a language: an app that serves `output:`
    // still needs the base language there.
    test('a base file outside output: does not stop the base render', () async {
      final config =
          webConfig(source: 'src/i18n/en.json', output: 'public/i18n');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(read('src/i18n/en.json'), base);
      expect(read('public/i18n/en.json'), served['json/en.json']);
    });

    test('--dry-run plans the other locales only', () async {
      final config = webConfig();
      expect(
        await runnerWith(files: served)
            .run(['--config', config, 'pull', '--dry-run']),
        0,
      );
      expect(out.toString(), contains('Would pull 1 file(s)'));
      expect(out.toString(), contains('\n  es.json\n'));
      expect(out.toString(), isNot(contains('\n  en.json\n')));
      expect(File('${dir.path}/public/i18n/es.json').existsSync(), isFalse);
    });

    test('without source: the base file is rendered like any other', () async {
      final config = writeConfig(output: 'public/i18n', format: 'json');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(read('public/i18n/en.json'), served['json/en.json']);
    });
  });

  // The first pull `init` recommends on a gen_l10n project used to replace
  // the template with the server's render, dropping its local keys.
  test('init on a gen_l10n project, then pull, keeps the template (#2343)',
      () async {
    const template = '{"@@locale":"en","welcome":"Welcome {name}",'
        '"@welcome":{"placeholders":{"name":{"type":"String"}}}}\n';
    File('${dir.path}/pubspec.yaml')
        .writeAsStringSync('name: app\nflutter:\n  generate: true\n');
    File('${dir.path}/l10n.yaml').writeAsStringSync(
        'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n');
    File('${dir.path}/lib/l10n/app_en.arb')
      ..createSync(recursive: true)
      ..writeAsStringSync(template);
    final config = '${dir.path}/easyi18n.yaml';
    final runner = runnerWith(files: const {
      'arb/app_en.arb': '{"@@locale":"en","welcomeName":"Welcome {name}"}',
      'arb/app_es.arb': '{"@@locale":"es","welcomeName":"Bienvenido {name}"}',
    })..addCommand(InitCommand(
        output: CliOutput(logger: logger), prompt: (_) => null));
    expect(await runner.run(['--config', config, 'init', '--project-id',
        'proj_abc', '--no-agents']), 0);
    expect(await runner.run(['--config', config, 'pull']), 0);
    expect(File('${dir.path}/lib/l10n/app_en.arb').readAsStringSync(), template);
    expect(File('${dir.path}/lib/l10n/app_es.arb').readAsStringSync(),
        contains('Bienvenido {name}'));
    expect(out.toString(), contains('app_en.arb left as it is'));
  });

  // gen_l10n reads every .arb of its arb-dir: the served `app_en.arb` beside
  // a template named `strings_en.arb` is a second `en` file it refuses.
  group('an ARB template named otherwise gives the served files its prefix '
      '(#2343)', () {
    const template = '{"@@locale":"en","welcome":"Welcome"}\n';
    const served = {
      'arb/app_en.arb': '{"@@locale":"en","welcomeName":"Welcome {name}"}',
      'arb/app_es.arb': '{"@@locale":"es","welcomeName":"Bienvenido {name}"}',
    };
    String templateConfig(String name) {
      File('${dir.path}/lib/i18n/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync(template);
      return writeConfig(output: 'lib/i18n',
          extra: 'mode: a\nsource: lib/i18n/$name\n');
    }
    List<String> arbs() => [
          for (final f in Directory('${dir.path}/lib/i18n').listSync())
            p.basename(f.path),
        ]..sort();

    test('a full pull, then a second one over its record', () async {
      final config = templateConfig('strings_en.arb');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(arbs(), ['strings_en.arb', 'strings_es.arb']);
      expect(File('${dir.path}/lib/i18n/strings_en.arb').readAsStringSync(),
          template);
      expect(File('${dir.path}/lib/i18n/strings_es.arb').readAsStringSync(),
          served['arb/app_es.arb']);
      expect(out.toString(), contains('strings_en.arb left as it is'));
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(arbs(), ['strings_en.arb', 'strings_es.arb']);
    });

    for (final name in ['messages.arb', 'en.arb']) {
      test('a template named $name does not need a locale suffix', () async {
        final config = templateConfig(name);
        expect(await runnerWith(files: served).run(['--config', config, 'pull']),
            0);
        expect(arbs(), ['app_es.arb', name]..sort());
        expect(File('${dir.path}/lib/i18n/$name').readAsStringSync(), template);
        expect(out.toString(), contains('$name left as it is'));
        expect(await runnerWith(files: served).run(['--config', config, 'pull']),
            0);
        expect(arbs(), ['app_es.arb', name]..sort());
      });
    }

    test('--lang, which serves no base file', () async {
      final config = templateConfig('my_strings_en.arb');
      expect(await runnerWith(files: {'arb/app_es.arb': served['arb/app_es.arb']!})
          .run(['--config', config, 'pull', '--lang', 'es']), 0);
      expect(arbs(), ['my_strings_en.arb', 'my_strings_es.arb']);
    });

    test('a suffix-free template keeps a regional base file too', () async {
      final config = templateConfig('messages.arb');
      final regionalTemplate = template.replaceFirst('"en"', '"pt_BR"');
      File('${dir.path}/lib/i18n/messages.arb').writeAsStringSync(regionalTemplate);
      final runner = runnerWith(files: {
        'arb/app_pt_BR.arb': '{"@@locale":"pt_BR","a":"A"}',
        'arb/app_es.arb': served['arb/app_es.arb']!,
      }, extraBody: {'baseCode': 'pt-br'});
      expect(await runner.run(['--config', config, 'pull']), 0);
      expect(arbs(), ['app_es.arb', 'messages.arb']);
      expect(File('${dir.path}/lib/i18n/messages.arb').readAsStringSync(),
          regionalTemplate);
    });

    test('a region in the base language', () async {
      final config = templateConfig('strings_pt_BR.arb');
      final runner = runnerWith(
        files: {
          'arb/app_pt_BR.arb': '{"@@locale":"pt_BR","a":"A"}',
          'arb/app_es.arb': served['arb/app_es.arb']!,
        },
        extraBody: {'baseCode': 'pt-br'},
      );
      expect(await runner.run(['--config', config, 'pull']), 0);
      expect(arbs(), ['strings_es.arb', 'strings_pt_BR.arb']);
      expect(File('${dir.path}/lib/i18n/strings_pt_BR.arb').readAsStringSync(),
          template);
    });

    // Only ARB is served as `app_<locale>`: a JSON base file with an
    // underscore keeps the served names.
    test('a JSON source with the same shape renames nothing', () async {
      File('${dir.path}/public/i18n/strings_en.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}\n');
      final config = writeConfig(output: 'public/i18n', format: 'json',
          extra: 'mode: a\nsource: public/i18n/strings_en.json\n');
      expect(await runnerWith(files: const {
        'json/en.json': '{"hello":"Hello"}',
        'json/es.json': '{"hello":"Hola"}',
      }).run(['--config', config, 'pull']), 0);
      expect(File('${dir.path}/public/i18n/es.json').existsSync(), isTrue);
      expect(File('${dir.path}/public/i18n/en.json').existsSync(), isTrue);
    });

    test('a template that already says app_ keeps the served names', () async {
      final config = templateConfig('app_en.arb');
      expect(await runnerWith(files: served).run(['--config', config, 'pull']),
          0);
      expect(arbs(), ['app_en.arb', 'app_es.arb']);
      expect(File('${dir.path}/lib/i18n/app_en.arb').readAsStringSync(),
          template);
    });
  });

  // gen_l10n reads each .arb of its arb-dir as the locale of its @@locale or,
  // without one, of its name, and refuses two files of one locale: a served
  // `app_es.arb` beside the project's own `es.arb` broke the build.
  group('a served locale goes to the .arb gen_l10n reads as it (#2436)', () {
    const template = '{"@@locale":"en","welcome":"Welcome"}\n';
    const own = '{"@@locale":"es","welcome":"Hola"}\n';
    const bare = '{"welcome":"Hola"}\n';
    const served = {
      'arb/app_en.arb': '{"@@locale":"en","welcome":"Welcome"}',
      'arb/app_es.arb': '{"@@locale":"es","welcome":"Bienvenido"}',
    };
    String tree(String name, Map<String, String> others) {
      for (final e in {name: template, ...others}.entries) {
        File('${dir.path}/lib/i18n/${e.key}')
          ..createSync(recursive: true)
          ..writeAsStringSync(e.value);
      }
      return writeConfig(output: 'lib/i18n',
          extra: 'mode: a\nsource: lib/i18n/$name\n');
    }
    List<String> arbs() => [
          for (final f in Directory('${dir.path}/lib/i18n').listSync())
            p.basename(f.path),
        ]..sort();
    String read(String name) =>
        File('${dir.path}/lib/i18n/$name').readAsStringSync();
    Future<int?> pull(String config, [Map<String, String> files = served,
            List<String> flags = const []]) =>
        runnerWith(files: files).run(['--config', config, 'pull', ...flags]);

    for (final (name, mine, body) in [
      ('en.arb', 'es.arb', own),
      ('messages.arb', 'messages_es.arb', own),
      ('messages.arb', 'es.arb', bare),
      ('en.arb', 'intl_es.arb', bare),
      // gen_l10n reads `ui` as no language, so this file is `es` to it.
      ('en.arb', 'ui_es.arb', bare),
      ('en.arb', 'extra.arb', own),
      // Empty, gen_l10n reads it as `{}`: `es` by its name.
      ('en.arb', 'messages_es.arb', ''),
    ]) {
      test('$mine beside the template $name', () async {
        final config = tree(name, {mine: body});
        expect(await pull(config), 0);
        expect(arbs(), [mine, name]..sort());
        expect(read(mine), served['arb/app_es.arb']);
        expect(read(name), template);
        expect(out.toString(), isNot(contains('Not written by this pull')));
      });
    }

    test('under a template whose suffix is not the base language', () async {
      final config = tree('strings_en.arb', {'strings_es.arb': own});
      expect(await runnerWith(files: {
        'arb/app_en_US.arb': '{"@@locale":"en_US","welcome":"Welcome"}',
        'arb/app_es.arb': served['arb/app_es.arb']!,
      }, extraBody: {'baseCode': 'en-us'}).run(['--config', config, 'pull']),
          0);
      expect(arbs(), ['strings_en.arb', 'strings_es.arb']);
      expect(read('strings_es.arb'), served['arb/app_es.arb']);
      expect(read('strings_en.arb'), template);
    });

    test('under a prefixed template, an own file named otherwise', () async {
      final config = tree('strings_en.arb', {'es.arb': own});
      expect(await pull(config), 0);
      expect(arbs(), ['es.arb', 'strings_en.arb']);
      expect(read('es.arb'), served['arb/app_es.arb']);
    });

    // Served names carry `pt_BR`; gen_l10n reads `pt_br.arb` as `pt_BR` too.
    test('a region and a script, in any case', () async {
      final config = tree('en.arb', {
        'pt_br.arb': bare,
        'messages_zh_Hant.arb': bare,
        'latin.arb': '{"@@locale":"sr_Latn","welcome":"Zdravo"}',
      });
      expect(await pull(config, {
        'arb/app_pt_BR.arb': '{"@@locale":"pt_BR","welcome":"Bem-vindo"}',
        'arb/app_zh_Hant.arb': '{"@@locale":"zh_Hant","welcome":"Huanying"}',
        'arb/app_sr_Latn.arb': '{"@@locale":"sr_Latn","welcome":"Dobrodosli"}',
      }), 0);
      expect(arbs(),
          ['en.arb', 'latin.arb', 'messages_zh_Hant.arb', 'pt_br.arb']);
      expect(read('pt_br.arb'), contains('Bem-vindo'));
      expect(read('messages_zh_Hant.arb'), contains('Huanying'));
      expect(read('latin.arb'), contains('Dobrodosli'));
    });

    for (final (name, locale) in [
      ('es-MX.arb', 'es_MX'),
      ('messages_zh-Hant.arb', 'zh_Hant'),
      ('iw.arb', 'he'),
      ('messages_in.arb', 'id'),
      ('de_DD.arb', 'de_DE'),
    ]) {
      test('gen_l10n canonicalizes $name as $locale', () async {
        final config = tree('en.arb', {name: bare});
        final remote = '{"@@locale":"$locale","welcome":"Remote"}';
        expect(await pull(config, {'arb/app_$locale.arb': remote}), 0);
        expect(arbs(), ['en.arb', name]..sort());
        expect(read(name), remote);
      });
    }

    test('a second pull, --lang and a hand edit keep to the own file',
        () async {
      final config = tree('en.arb', {'es.arb': own});
      expect(await pull(config), 0);
      expect(await pull(config), 0);
      expect(arbs(), ['en.arb', 'es.arb']);
      expect(await pull(config, {'arb/app_es.arb': served['arb/app_es.arb']!},
          ['--lang', 'es']), 0);
      expect(arbs(), ['en.arb', 'es.arb']);
      expect(read('es.arb'), served['arb/app_es.arb']);

      const edited = '{"@@locale":"es","welcome":"Hola (a mano)"}';
      File('${dir.path}/lib/i18n/es.arb').writeAsStringSync(edited);
      await expectLater(pull(config), throwsA(isA<CliException>()
          .having((e) => e.code, 'code', 'edited_targets')
          .having((e) => e.details['edited'], 'edited',
              [{'file': 'lib/i18n/es.arb'}])));
      expect(read('es.arb'), edited);
    });

    // Each of these is another locale, or none, to gen_l10n, or a file it
    // does not read.
    for (final (mine, body) in [
      ('fr.arb', bare),
      ('notes.arb', bare),
      ('es.arb', '{"@@locale":"fr","welcome":"Bonjour"}'),
      // The whole name comes first: `pt_ES`, not `es`.
      ('pt_es.arb', bare),
      ('es.arb', 'not json'),
      ('es.arb', '[]'),
      ('messages-.arb', own),
      ('es.json', bare),
      ('old/es.arb', own),
    ]) {
      test('$mine holding ${body.trim()} is not the es file', () async {
        final config = tree('en.arb', {mine: body});
        expect(await pull(config), 0);
        expect(arbs(), ['app_es.arb', 'en.arb', p.split(mine).first]..sort());
        expect(read(mine), body);
      });
    }

    test('an es.arb that is not UTF-8 is not the es file either', () async {
      final config = tree('en.arb', {});
      File('${dir.path}/lib/i18n/es.arb').writeAsBytesSync([0xff, 0xfe, 0x7b]);
      expect(await pull(config), 0);
      expect(arbs(), ['app_es.arb', 'en.arb', 'es.arb']);
    });

    // gen_l10n already refuses that tree; the served name changes nothing.
    test('a locale two files claim keeps the served name', () async {
      final config = tree('en.arb', {'es.arb': own, 'messages_es.arb': bare});
      expect(await pull(config), 0);
      expect(arbs(),
          ['app_es.arb', 'en.arb', 'es.arb', 'messages_es.arb']);
      expect(read('es.arb'), own);
    });

    test('without source: the served names stay', () async {
      File('${dir.path}/lib/l10n/es.arb')
        ..createSync(recursive: true)
        ..writeAsStringSync(own);
      final config = writeConfig(extra: 'mode: a\n');
      expect(await pull(config), 0);
      expect(
          [
            for (final f in Directory('${dir.path}/lib/l10n').listSync())
              p.basename(f.path),
          ]..sort(),
          ['app_en.arb', 'app_es.arb', 'es.arb']);
    });
  });
}
