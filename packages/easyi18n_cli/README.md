# easyi18n_cli

[![pub package](https://img.shields.io/pub/v/easyi18n_cli.svg)](https://pub.dev/packages/easyi18n_cli)

Command-line tool for [easyi18n](https://easyi18n.com). **Mode A (native
`.arb`)**. It pulls the translated localization files from your project's
published version and writes them to disk, so you keep using stock Flutter
localization (`flutter_localizations` + `gen-l10n` + `AppLocalizations`). No
runtime dependency, no hot-update. _"we're your TMS"_.

> For live hot-update (Mode B), use the [`easyi18n`](https://pub.dev/packages/easyi18n)
> runtime SDK instead. The two are independent; pick per project.

## Install

**Flutter project**: add as a dev dependency (it never ships in your app):

```sh
dart pub add dev:easyi18n_cli
```

```sh
dart run easyi18n_cli:easyi18n pull
```

**Non-Flutter / CI**: activate globally:

```sh
dart pub global activate easyi18n_cli
easyi18n pull
```

## Usage

### 1. Configure

```sh
dart run easyi18n_cli:easyi18n init --project-id <your-project-id>
```

This writes `easyi18n.yaml`:

```yaml
projectId: proj_abc123
mode: a                              # a = TMS over gen_l10n, b = runtime SDK
baseUrl: https://api.easyi18n.com    # override for the local emulator
format: arb                          # arb, json, nested_json, po, ...
output: lib/l10n                     # your l10n.yaml arb-dir
source: lib/l10n/app_en.arb          # your template-arb-file: pull never writes it
sourceRoot: lib/l10n
```

On a project with an `l10n.yaml`, `init` reads its `arb-dir` and
`template-arb-file` (`lib/l10n` and `app_en.arb` when the file leaves them
out). `output:` is the `arb-dir`, and a template that exists is `source:`:
you keep adding keys there, and `pull` writes only the other `.arb` files.
Before the first pull, import your existing `.arb` files in the dashboard
(Keys, Import a file, the template first) and publish, so the server has
your keys and translations.

`mode:` is what tells the CLI which commands apply to this project — `pull
--require-complete` is the Mode A gate and refuses on anything else — so a
hand-written config that omits it reads as Mode B (`b` is the default).

`output:` is a **directory**, for the formats that render one file per locale.
A format that renders a single file holding every language — today an iOS
String Catalog — names that file instead, with `catalog:`, and it is the one
the commands read and write:

```yaml
format: xcstrings
catalog: MyApp/Localizable.xcstrings   # the file your project already has
```

An app with several catalogs (`Localizable`, `AppShortcuts`, `InfoPlist`)
lists them under `catalogs:` instead, and they are one project: `sync` uploads
the union of their keys, and `pull` writes each key back into the file it came
from. A key can live in only one file, and `catalog:` and `catalogs:` are not
combined.

```yaml
format: xcstrings
catalogs:
  - MyApp/Localizable.xcstrings
  - MyApp/AppShortcuts.xcstrings
  - MyApp/InfoPlist.xcstrings
```

`init --stack xcode` writes exactly that: it finds the catalog itself
(`Localizable.xcstrings` first, `InfoPlist.xcstrings` never), sets
`format: xcstrings` and `mode: a`, and scaffolds nothing else — the catalog is
your file. Pass `--catalog <path>` to name a different one, or `--stack auto`
to let the CLI pick among the Flutter, Xcode, web, Android and Angular
adapters. `easyi18n doctor`
then checks the catalog instead of the runtime wiring, and `sync` is the
command to run next.

A web project that keeps one JSON file per locale (Transloco, ngx-translate,
i18next) names its base-language file with `source:` and keeps `output:` as
the directory of the other locales:

```yaml
format: json
output: public/i18n
source: public/i18n/en.json            # the file you edit
sourceRoot: public/i18n
sourceLayout: locale-files
```

`init --stack web` writes that. `sync` uploads the file `source:` names and
writes one file per target language into `output:`; `sync` and `pull` never
write the base file itself. A base language split into several files syncs as
one catalog with `sourceLayout: namespaces` (i18next, `sourceRoot` set to the
base-language directory) or `sourceLayout: scopes` (Transloco, `sourceRoot`
set to the directory of the root file); `pull` writes each file back next to
its sibling, and `init` writes the layout it finds. Under the other layouts
such a split is refused before the upload, with the files named. Both
`sourceRoot` and `sourceLayout` are required; existing YAML must add them.
[Input layouts and migration](https://docs.easyi18n.com/developers/agents/web)
explain the choice and exclusions.

An unknown setting is reported rather than ignored, so a typo (`ouput:`) can't
quietly leave a run on a default.

`init` also writes an easyi18n block into the `AGENTS.md` next to
`easyi18n.yaml`, creating the file or appending to the one you have. The block
sits between `<!-- easyi18n:start ... -->` and `<!-- easyi18n:end -->` and
tells a coding agent with no MCP client the translate loop, that a real push or
sync spends credits, where the key lives, and your stack's rules. A re-run
rewrites only what is between the markers, so keep your own notes outside them.
`--no-agents` skips it. `init` never creates or edits `CLAUDE.md` or
`.cursorrules`; when a `CLAUDE.md` does not mention `AGENTS.md`, it suggests
adding a line `@AGENTS.md`.

### 2. Authenticate

The CLI never stores a credential. Provide a project API key (`eik_…`) with
the **read** scope via the environment (or `--token`):

```sh
export EASYI18N_TOKEN=eik_xxxxxxxx
```

Create an API key in your project settings.

### 3. Pull

```sh
dart run easyi18n_cli:easyi18n pull
flutter gen-l10n
```

`pull` downloads every locale's file for the configured format and writes them
into `output/`, ready for `gen-l10n`. It records what it writes (in
`.easyi18n/state.json` — add `.easyi18n/` to your VCS ignore) and, on the next
full pull of the same format and output dir, removes files the server no
longer serves (e.g. a locale renamed to its canonical filename). A `--lang`
pull never removes anything; switching `format:` or `output:` never prunes
either — the stranded files of the old target are listed instead.

The record holds a digest of each file too. A pull that would replace or
remove a file whose content changed since stops before it writes anything,
names the file and exits 1 (`edited_targets`). Reformatting the file is not a
change. Make the change in the dashboard and publish it, or discard it with
`--force`.

In Mode B, when `pubspec.yaml` lists `assets/easyi18n/`, `pull` also bakes the
offline floor the SDK loads before any network call: one
`assets/easyi18n/<locale>.json` per locale of the live delivery manifest,
checked against its content address. Commit those files. A `--version` pull
leaves the floor alone. With itemized asset entries, every pulled locale must
be registered; `init` registers the whole directory if one is missing.

**String Catalogs are merged, not replaced.** An `.xcstrings` is a file two
tools write, and Xcode owns most of it: the key order, the per-key metadata
its extraction pass produces (`extractionState`, `isCommentAutoGenerated`),
and every string you added since the last publish. `pull` injects the served
translations into your file and re-prints it in Xcode's own style, so a pull
that changed no translations is a byte-exact no-op instead of a whole-file
reformat — and nothing you wrote goes missing. The trade: a pull never deletes
a key either, so one removed from the project stays until Xcode's next
extraction drops it. `--lang` is refused for this format, since a catalog holds
every language in one file.

| Flag | Description |
|------|-------------|
| `--token` | Credential (overrides `EASYI18N_TOKEN`). |
| `--version` | Pull a specific published version (CalVer). Defaults to `latest`. |
| `--lang` | Pull only one locale (e.g. `--lang es`). |
| `--require-complete` | Fail (exit 1) when any target language of the pulled version is missing translations — the CI gate for a Mode A project, whose translations live on the server. Mode A only (`mode: a`). The version itself is what decides: a snapshot published with `incompleteMode: source` bakes the base text into untranslated cells, so its count always reads complete and the gate refuses to judge it — as it does a snapshot published before the server started stamping this, and a version with no target language. One-shot: not combinable with `--watch`, nor with `--lang` naming the base. Combinable with `--dry-run`, which keeps the gate and skips the writes. Needs a backend that reports per-language coverage; an older one fails the gate rather than reading silence as complete. |
| `--dry-run` | List the files that would be written without writing them. It does not silence `--require-complete`: combined, the gate still runs and still fails (exit 1) — see the row above. |
| `--force` | Replace a file that changed since the pull that wrote it. |
| `--config` | Path to the config file (default `easyi18n.yaml`). |

`--dry-run --require-complete` is the combination a CI job wants: it answers
"is the published version complete?" and leaves the working tree untouched. A
dry run used as a cheap gate has to go red on the state the real run refuses,
rather than exit 0 over it — the same pairing `sync` settled in #955.

## Push your source strings

If your code calls `tr()` (via the [`easyi18n`](https://pub.dev/packages/easyi18n) runtime
SDK), the CLI can register and translate those strings for you. It statically
scans your source tree for `tr()` calls (both the canonical
`context.tr('Welcome {name}')` and the `'Welcome {name}'.tr()` sugar) and
sends the **raw source strings** to the backend, which tokenizes and translates
them.

```sh
export EASYI18N_TOKEN=eik_xxxxxxxx          # needs the translate scope
dart run easyi18n_cli:easyi18n push
```

`push` is interactive by default: it previews the cost before spending any
credits.

```
Scanned 42 file(s): 18 extractable tr() string(s).
3 new since last push:
  + "Welcome {name}"
  + "Save"
  + "Open"  (ctx: verb)
3 string(s) need translation · ~30 credit(s) (balance 1000).
Translate 3 string(s) for ~30 credit(s)? [y/N]
```

| Flag | Description |
|------|-------------|
| `--dry-run` | Estimate the cost only; register and translate nothing. |
| `--yes` / `-y` | Skip the confirmation prompt (for CI). |
| `--max-credits N` | Abort if the estimate exceeds `N` credits (decimals allowed, e.g. `0.5`; a CI guard). |
| `--prune` | Drop orphaned strings from the lockfile (never deletes translations). |
| `--lang` | Restrict to these target languages (repeatable). |
| `--source-dir` | Directory to scan, relative to the config (default `lib`). |
| `--token` | Credential (overrides `EASYI18N_TOKEN`). |
| `--publish` | Wait for the fill to complete, then publish a new version (needs `publish`; Mode A also needs `read`, plus `write` when adopting a format). Strings whose fill failed are re-queued up to 2 times; whatever is still untranslated publishes serving the source text. |
| `--approved-only` | With `--publish`: treat unapproved translations as missing. |
| `--require-complete` | With `--publish`: fail instead of publishing when strings remain untranslated after the retries. |

With `--require-complete`, a scan that finds no `tr()` strings fails before any
request: `push` has no catalog snapshot with which to prove completeness. Check
`--source-dir` for code-first projects. A Mode A project can use `sync
--require-complete` only with a non-empty, supported `catalog:` (or `catalogs:`)
or the `source:` of a per-locale web project;
canonical gen_l10n/ARB configs gate on **`pull --require-complete`** instead
(the flag table above), which reads the published version's own coverage.

A `tr(variable)` or an interpolated `tr('Hi $name')` can't be read statically;
the CLI reports it so you know it relies on runtime auto-capture instead.

### `easyi18n.lock`

`push` records the strings it registered in `easyi18n.lock` (commit it). On the
next run, anything new is sent; strings that vanished from your code are
reported as **orphans** (their translations are kept; pass `--prune` to drop
them from the lockfile).

## Apply source-verify fixes

When source review (a Pro feature) corrects one of your base strings, the old
`tr('…')` literal in your code is retired. `apply` fetches that "update your
code" list and rewrites the literals for you, AST-aware:

```sh
dart run easyi18n_cli:easyi18n apply           # preview the changes
dart run easyi18n_cli:easyi18n apply --write    # apply them to disk
```

It's **local and free** (no credits) and reversible through git — review the
diff, then `push`, and the entries reconcile automatically. Only the string
literal is touched; quotes, `ctx:`, and formatting are left intact. A change
whose call site uses a variable or interpolation (or that you already updated)
is reported as unmatched, never silently changed.

| Flag | Description |
| --- | --- |
| `--write` | Apply the rewrites to disk (default is a preview only). |
| `--source-dir` | Directory to scan and rewrite, relative to the config (default `lib`). |
| `--token` | Credential with the `read` scope (overrides `EASYI18N_TOKEN`). |
| `--config` | Path to the config file (default `easyi18n.yaml`). |

### `extract`: inspect without pushing

```sh
dart run easyi18n_cli:easyi18n extract
```

`extract` runs the same scan but stays **offline and read-only**: it prints what
would be registered, what's new, what's orphaned, and which calls are dynamic.
Use `--fail-on-orphans` as a CI drift check.

### `rollback`: undo a bad publish

```sh
dart run easyi18n_cli:easyi18n rollback            # restore the previous version
dart run easyi18n_cli:easyi18n rollback 2026.07.08.2
```

Restores a prior published version as a **new** version (history is never
rewritten) and points delivery at it. Needs the `publish` scope.

## `languages add`: add a target language

```sh
dart run easyi18n_cli:easyi18n languages add fr
dart run easyi18n_cli:easyi18n --json languages add pt-BR --fill-mode manual
```

Needs an API key with the **write** scope (`EASYI18N_TOKEN` or `--token`).
It charges nothing and runs no AI. The server normalizes and validates the
code and refuses the base language. Re-adding a removed language revives it
with `--fill-mode` (default `ai`). Re-adding a live one keeps its mode unless
`--fill-mode` names another. A `manual` language is skipped by AI fills.

JSON fields: `code` (as stored), `fill_mode`, `project_dir`, `base_url`,
`next` (`easyi18n status`). A lost response is not replayed; re-running the
command is safe.

## `formats add`: enable an output format

```sh
dart run easyi18n_cli:easyi18n formats add arb
dart run easyi18n_cli:easyi18n --json formats add xcstrings
```

Uses the configured project ID or workspace/project alias. Supply an API key
with the **write** scope through `EASYI18N_TOKEN` or `--token`.
The server validates the format and limit; the CLI keeps no local catalogue.
Adding a format preserves the other enabled formats, including legacy IDs.

The response confirms the persisted list. `created: true` means configuration
changed or was materialized from legacy state; `false` means no change.
Enabling a format does not publish a version or guarantee a download.
`easyi18n status` inspects publication state and requires the **read** scope;
a write-only key can add formats but cannot run status. The confirmed
`enabled` list above is the result of the add, not a prediction of downloads.

Configuration applies to every version, including pinned versions.
Materializing a legacy configuration can expand its exports; downloads still
check format collisions. The CLI always requests `format:` from your config;
API consumers requesting all formats may encounter new export collisions.

JSON fields: `format`, `enabled`, `created`, `project_dir`, `base_url`, `next`.
`next` names `easyi18n status`, with the read-scope requirement above.
Only the `add` leaf supports JSON; `formats` alone displays group usage in text.
Server error codes and HTTP status are preserved, including scope and conflict
refusals. This command always requests an explicit add.

Writes are not automatically repeated after a timeout, lost response, invalid
body, 500 or 503 unavailable. Only the existing 503 contended response proves
that nothing landed and permits replay. Re-running the explicit add is safe;
publish and rollback retain their separate project-history recovery advice.

This command requires the output-formats backend API. Deploy and smoke-test
that backend before distributing an integrated CLI release.

`sync` with publication and local Mode A `push --publish` require
`/meta.outputFormatsApiVersion: 1` and valid format metadata before previewing
cost. This replaces the previous best-effort metadata lookup: missing `read`
scope, malformed metadata or an older backend now stop these workflows, even
when the format is already configured. Mode A `push --publish` needs
`translate,publish,read`; adopting also needs `write`. A configured different
format stops the run with advice to correct local `format:` if it mismatches
your files, or explicitly enable it with `easyi18n formats add <id>`. An empty configuration permits conditional adoption **after
budget checks and consent, before the first real ingestion/translation POST**.
Publication declares `requiredOutputFormat`. Empty Mode A pushes adopt just
before publication. Sync applies this even in Mode B because it downloads files;
`sync --no-publish`, Mode B push and push without publication keep their scope
contracts. `push --publish` still rejects `--dry-run`; under `--json` it reports the
version it minted in the record's `published` block. If the fill wait or the
publish fails after the lockfile was written, the error record keeps `pushed`
and `lockfile_written: true` beside `error`, because that push already went out.
A push that fails on a later batch, or at the `--max-credits` stop, keeps the
accepted batches under `pushed` with `lockfile_written: false`.
`sync --json` does the same once the server answered a POST: the error record
keeps `attempts` and `synced` (the last answer), `still_incomplete` and
`stopped_short` stay `null` until the run settles, and `delivery` carries
`pulled_version: null` when the publish went out and the pull failed.
`pull --json --require-complete` keeps `files_written` and `coverage` beside
the refusal. A disk failure under `--json` is an error record with code
`file_system`, carrying the same partial report (`pull` lists the files it
pruned and wrote before the failing one).

Dry-run never adopts or publishes. Sync JSON includes `output_format` with
`format`, preflight/current `state` and confirmed `created`. If adoption changed
configuration and later work fails, the error message retains that fact while
preserving its code/status/retryability. Configuration is not rolled back.
A concurrent configuration change may reject publication after work was paid
for; a later change can also affect delivery of a pinned version.

A healthy pull still makes one translation request. Only a 400
`invalid_argument` or `no_formats` opens recovery: valid metadata and capability
must confirm an empty configuration, conditional adoption must succeed, then
the same version/lang request is retried once. A configured requested format
preserves the original error; an unsupported capability also preserves it
without adoption. A different configured format names the explicit add command.
The CLI does not inspect error-message text: an unrelated eligible 400 on a
formatless project with capability can therefore enable the format before the
retried request reports its original problem.
Read-only credentials cannot adopt: a write-scope holder must enable the format.
Watch attempts automatic adoption at most once per invocation. A dry-run that
needs recovery reports `output_format_pending` without writing or claiming a
download. Other publication/version/language/collision errors retain their codes.

## Doctor: check the whole integration

```sh
dart run easyi18n_cli:easyi18n doctor
```

`doctor` is read-only and never spends credits. It checks:

- **Local wiring** — `easyi18n.yaml`, the `easyi18n` dependency, the
  `assets/easyi18n/` offline floor (one file per published locale, or the web
  build logs a 404 for each missing one), `com.apple.security.network.client` in
  BOTH macOS `.entitlements` (without it, delivery fetches fail *silently* in
  the sandbox), `android.permission.INTERNET` in the Android main or release
  manifest (a warning: without it a release build cannot reach delivery, but
  a dependency may add it when Gradle merges the manifests), that
  `Easyi18nScope` is mounted and names its `baseUrl` when the config is not
  production, and that `MaterialApp` declares
  `localizationsDelegates` and `supportedLocales` (without them `tr()`
  resolves `en` only).
- **`AGENTS.md`**: warns when the easyi18n block is missing, stale (the
  project, the stack or this CLI's text changed since `init` wrote it) or
  edited by hand between the markers. It never blocks.
- **ICU health** — lints every extracted `tr()` string (unbalanced braces,
  `plural`/`select` without `other`, …). A malformed ICU string renders raw
  to your users.
- **Delivery** — actively fetches the public manifest (the runtime swallows
  delivery errors by design, so doctor must not): reachable, CORS served for
  web, and then grades your `tr()` scan against the published bundles —
  **missing** (never pushed/published), **untranslated** per locale, and
  **unused** published keys.
- **Completeness (Mode A)** — a Mode A publish omits the cells it has no
  translation for, so an incomplete locale is just a shorter file and nothing
  local can tell. Doctor reads the published version's per-language coverage
  and fails on any language that is short. It needs a key with the read
  scope; without one — or on a version whose coverage cannot be judged, like
  one published with `incompleteMode: source` — it says it **could not
  verify**, which is not a pass. A project whose published version carries no
  target language yet has nothing to grade, and says so without blocking the
  summary — that is the one state where `pull --require-complete` disagrees
  and refuses (a health check reports a healthy project; a gate refuses a
  version it has nothing to verify), so doctor names the refusal in that
  line. This is the one check that leaves your machine with a credential: it
  sends `--token` (or `$EASYI18N_TOKEN`) to `baseUrl` (one export read, plus
  a lookup when the config uses a `@handle/slug` ref) and warns first if
  `baseUrl` is not the production origin. Every other check is local or
  unauthenticated.

Exit code 1 on blocking problems; warnings (e.g. strings pending a push)
don't block, and a check that could not run keeps the summary from reading
`All checks passed.` Most local failures are fixed by re-running
`easyi18n init`.

## MCP: let an AI agent drive it

`easyi18n mcp` runs an MCP server on stdio. `easyi18n mcp config --client
<client>` prints the snippet for `claude-code`, `claude-desktop`, `cursor`,
`vscode`, `codex`, `gemini`, `windsurf`, `zed` or `generic`; add `--runner
dart` to start it with `dart pub global run` instead of `npx`. Or register it
by hand as a stdio server with the command `easyi18n` and the argument `mcp`,
or `dart run easyi18n_cli:easyi18n mcp` from a Flutter project:

```json
{
  "mcpServers": {
    "easyi18n": {
      "command": "easyi18n",
      "args": ["mcp"],
      "env": { "EASYI18N_TOKEN": "eik_..." }
    }
  }
}
```

The server reads its settings from its own env, never from the agent:

| Variable | Effect |
|---|---|
| `EASYI18N_TOKEN` | The API key. Create it in the dashboard as an **AI agent** key: every spend, publish and rollback it makes waits for a human approval. |
| `EASYI18N_PROJECT_DIR` | The project, when the agent passes no `project_dir`. Falls back to the working directory. |
| `EASYI18N_MCP_MAX_CREDITS` | The most one approval can authorize, in credits. Default 50; `0` refuses every real ingest. |
| `EASYI18N_MCP_APPROVAL_WAIT_SECONDS` | How long the agent waits for an approval before it stops and tells the human. Default and maximum 600; a smaller value only shortens it. |
| `EASYI18N_BASE_URL` | The only origin other than the easyi18n API the key may be sent to. A `baseUrl` in `easyi18n.yaml` that is not this, HTTPS easyi18n or loopback is refused. |

The tools a project gets depend on its family. `status`, `doctor`, `init`,
`authorize`, `fill_status`, `publish`, `rollback`, `pull` and `add_language`
serve both. A Flutter project (`tr()` calls) uses `extract`, `push_preview`,
`push` and `apply`; an Xcode String Catalog, a web project with JSON
catalogs, an Android app and an Angular app use `sync_preview` and `sync`.
Calling the other family's tool answers `wrong_family` with the one to use.

The spend loop is the same for both:

1. `push_preview` or `sync_preview` estimates the credits. Nothing is spent.
2. `authorize {action: translate, max_credits}` returns an `approval_url`.
   The human opens it and approves; the agent waits with
   `authorize {operation_id}`, which holds the call up to 45 s while the
   operation is pending. The agent calls it again in the same turn until
   the human answers, for up to 10 minutes.
3. `push {operation_id}` or `sync {operation_id}` sends the strings and
   queues their translation. An ingest that costs 0 needs no operation.
4. `fill_status` polls until `complete`.
5. `authorize {action: publish}`, the human approves, then
   `publish {operation_id}`.
6. `pull` writes the published files, or the translated catalog back.

Before each real request, `push` and `sync` write its intent to
`.easyi18n/operations/`. A request that left without an answer blocks the
next ingest until `fill_status` asks the server what happened to it. The
directory is local state, like `.easyi18n/state.json`.

## CI

Pull translated files:

```sh
export EASYI18N_TOKEN=$EASYI18N_TOKEN   # CI secret
dart run easyi18n_cli:easyi18n pull
flutter gen-l10n
```

Or push on merge (register + translate, with a spend guard):

```sh
export EASYI18N_TOKEN=$EASYI18N_TOKEN   # needs the translate scope
dart run easyi18n_cli:easyi18n push --yes --max-credits 500
```
