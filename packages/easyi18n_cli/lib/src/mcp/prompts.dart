import 'package:dart_mcp/server.dart';

import '../adapters/stack_adapters.dart' show stackRoadmap;

/// The two canonical prompts, verbatim from `docs/specs/agent-native.md`
/// sections 5.2 and 5.3.
///
/// Decision D9: this text is the single source of everything the agent is told.
/// The plugin skills are generated from it and the `AGENTS.md` block is the
/// same content for a client without MCP, so a change here is a change to the
/// spec section it came from — `test/mcp/prompts_test.dart` compares the two
/// character for character. Raw strings: the Flutter rule in `setup` quotes
/// `'Hi $name'`, which a normal literal would interpolate.

const String setupPrompt = r'''
Goal: take this repository from zero to "ready to translate".
1. Detect the stack. Flutter: pubspec.yaml with a `flutter:` section. Xcode: an
   *.xcodeproj or *.xcworkspace plus an .xcstrings catalog other than
   InfoPlist.xcstrings. Web: a package.json that depends on
   @jsverse/transloco, @ngx-translate/core or i18next, with one JSON file per
   locale. Android: a res/values/strings.xml plus a Gradle script
   (settings.gradle or build.gradle, .kts too) or an AndroidManifest.xml.
   Anything else: stop and say easyi18n does not support this stack yet
   (supported: Flutter, Xcode, web JSON catalogs, Android strings.xml;
   roadmap: ''' '$stackRoadmap' r'''). Do not improvise.
2. Call status. If it names a `project`, the key in this client's config
   already says which project this is: tell the human which one and go on.
   If it answers no_credential, two things only the human can do: (a) create
   the project at https://app.easyi18n.com (New project → base language +
   target languages); (b) create an **Agent key** (Project → Settings → API
   keys → New API key, Used by "AI agent": scopes read, translate, publish —
   add write if languages will be added from this agent; agent keys need a
   human approval in the dashboard for every spend and publish) and put it in
   this client's config as EASYI18N_TOKEN. Never ask them to paste the key in
   chat.
3. Call init {stack: "auto"}: it reads the project from the key. Only if it
   answers "Missing project ref", ask for the workspace handle and project
   slug from the URL app.easyi18n.com/@<handle>/<slug> and call init
   {workspace, project, stack: "auto"}. If it answers "No supported
   stack found", check whether you are at the root of the app: retry with
   project_dir only if you find a directory that meets a stack detection
   of step 1. If you find none, stop and say you found no
   supported stack. Read `steps`. If `scope_snippet` comes back, wire it
   yourself following it: Flutter, Easyi18nScope into main.dart; web, the ICU
   transpiler a step names, installed first with the project's package
   manager.
4. Flutter Mode B: run `flutter pub get`; convert user-facing literals to
   context.tr('…') (import package:easyi18n/easyi18n.dart). Ask first: one
   screen or the whole app. Rules: natural English, keep punctuation;
   placeholders {name}; plurals in ICU {count, plural, one{…} other{…}}; ctx:
   to disambiguate homonyms; never interpolate ('Hi $name' cannot be
   extracted); leave logs, ids, URLs and keys alone.
   Flutter Mode A (gen_l10n): the template .arb (`source:` in easyi18n.yaml)
   stays the truth and pull never writes it; add keys there as usual. Before
   the first pull, ask the human to import the existing .arb files in the
   dashboard (Keys → Import a file, the template first) and publish: pull
   writes every other .arb in `output:`.
   Xcode: confirm `catalog:` points at the right .xcstrings and that the
   project's languages match the catalog's.
   Web: move user-facing literals into the base file (`source:` in
   easyi18n.yaml) as ICU: placeholders {name}, plurals {count, plural,
   one{…} other{…}}. Keys are yours, nested by screen; read them with the
   library's pipe or t(). Ask first: one screen or the whole app. Never edit
   the other locale files: pull writes them.
   Android: the strings already live in res/values/strings.xml; add new ones
   there with Android escapes and %1$s placeholders, and mark a string that
   must not be translated with translatable="false". sync uploads each
   values-<lang>/strings.xml of a project language as its translations;
   after that, never edit those files: pull writes them.
5. Call doctor. Fix every `fail` (most are fixed by re-running init; compile
   errors go to the build tools). `credential` warning = step 2b not done.
6. Show the human what would be translated: extract (Flutter Mode B) or
   sync_preview (file-first); Flutter Mode A has nothing to preview here.
   Do not push or sync. Hand off: "run the translate prompt to translate and
   publish".
Do not: edit easyi18n.lock / .easyi18n / assets/easyi18n; add languages by
editing config (use add_language or the dashboard); push, sync or publish here.
''';

const String translatePrompt = r'''
0. status — confirm project, family, languages, published state. If apply
   (preview) lists pending code changes (Flutter), apply {write:true}, show the
   diff, continue.
1. Preview: extract + push_preview (code-first) or sync_preview (file-first).
   Show: N strings × languages, ~C credits, available credits, skipped /
   exhausted / conflicts. If would_exceed_key_cap or not affordable, stop and
   explain. Flutter Mode A pushes nothing: its keys reach the server through
   the dashboard import (setup step 4), so go to step 4.
2. If C is 0 there is nothing to approve: push or sync without operation_id
   (the server accepts only if nothing turns out billable; a 403 with an
   estimate means it did — continue below with that C). Otherwise authorize
   {action: translate, max_credits: ceil(C × 1.2)}. The server and the local
   ceiling settle M; if the tool aborts with ceiling_below_estimate, tell the
   human how to raise EASYI18N_MCP_MAX_CREDITS and stop. Show the human:
   "Translate N strings for ~C credits, charged at most M. Approve here:
   <approval_url>". Wait, polling authorize {operation_id} — never a new
   authorize without operation_id — until state is approved (it expires in
   30 min). Then push {operation_id} or sync {operation_id}.
3. Poll fill_status every ~10 s (say you are waiting; do not spam).
   failed_needs_requeue → ingest again with the same operation_id, at most
   twice (the server enforces M across attempts). budget_exhausted or
   request_unresolved → do not ingest; report charged_mc; reauthorize only if
   the human says so. exhausted non-empty → tell the human. Over 10 minutes →
   stop and report.
4. When complete: authorize {action: publish} → give the human the
   approval_url → publish {operation_id} (require_complete stays true).
   Report version_id, key_count and any refused cells with their reasons.
5. pull — file-first: this writes the translations back; show the diff.
   Xcode: into the catalog (key_policy local_owns, set by the sync). Web: one
   file per target language into `output:`; the base file is never
   rewritten. Android: values-<lang>/strings.xml per target language into
   `output:`, the res/ folder; values/strings.xml is never rewritten. Mode A
   Flutter: every .arb in `output:` but the template (`source:`), which is
   never rewritten.
6. doctor must be green (or warnings only). Flutter runtime delivery (mode B):
   a running app hot-swaps within seconds, no rebuild; it follows the device
   language, so a target language shows once the device (or, on macOS, the
   app under Language & Region) is set to it. Mode A (.arb), Xcode and
   Android: rebuild to see the translations. Web: reload the app.
7. If the human reports the publish broke something: authorize {action:
   rollback} → approval_url → rollback {operation_id}.
Adding a language: add_language {code} (or the dashboard), then steps 1-6.
Do not: translate strings yourself; publish with require_complete:false unless
the human said so; call push/sync/publish/rollback without an approved
operation_id from step 2 or 4; raise max_credits without asking.
''';

/// A prompt as a client sees it, paired with the text it gets back.
typedef McpPrompt = ({Prompt prompt, String text});

/// Registered in this order, which is the order a client lists them in:
/// `setup` brings a repository to ready-to-translate, `translate` is the loop
/// that runs afterwards.
final List<McpPrompt> mcpPrompts = List.unmodifiable([
  (
    prompt: Prompt(
      name: 'setup',
      description:
          'Take a repository from zero to ready-to-translate: detect '
          'the stack, wire up easyi18n, convert the literals and show what '
          'would be translated.',
    ),
    text: setupPrompt,
  ),
  (
    prompt: Prompt(
      name: 'translate',
      description:
          'Translate and publish: preview the spend, get it approved '
          'by the human, wait for the fill, publish and write the result back.',
    ),
    text: translatePrompt,
  ),
]);
