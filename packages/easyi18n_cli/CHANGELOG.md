# Changelog

## 1.2.2

The commands and the MCP tools are those of 1.2.1. What changes is where
the public repositories live, and with it the URLs the CLI writes and
downloads from.

- The source of the CLI and its binaries live in `easyi18n-com/dart`.
  pub.dev lists it as the repository and issue tracker, `easyi18n init`
  writes `# Docs: https://github.com/easyi18n-com/dart` in the header of
  `easyi18n.yaml`, and `install.sh`, the npm package and the Claude Code
  plugin download the binary from its releases.
- The agent integrations live in `easyi18n-com/agents`: the npm package
  `@easyi18n.com/cli` and the MCP Registry entry `com.easyi18n/cli` point
  there, and Gemini CLI installs the server with
  `gemini extensions install https://github.com/easyi18n-com/agents`.
- The Claude Code marketplace is named `easyi18n.com` and is added with
  `/plugin marketplace add easyi18n-com/agents`. The plugin README no
  longer has the section on moving an install from the old marketplace.

## 1.2.1

The binary, its commands and the MCP tools are those of 1.2.0. What
changes is how the server is listed and installed.

- The npm package `@easyi18n.com/cli` declares
  `"mcpName": "com.easyi18n/cli"`, the name the official MCP Registry
  checks before it lists the server.
- Gemini CLI installs the server with
  `gemini extensions install https://github.com/liontude/easyi18n-agents`:
  the extension is `easyi18n` and its server `cli`.
- The Claude Code plugin names its pieces once: the marketplace is
  `liontude`, the command `/easyi18n:doctor`, the skills `easyi18n:setup`
  and `easyi18n:translate`, and the server `plugin:easyi18n:cli`. An
  install made before keeps the marketplace name `easyi18n`; the plugin
  README says how to move.
- The plugin runs no hook at session start. Claude Code starts the MCP
  server first, and its launcher already installs the CLI.

## 1.2.0

- The MCP `init`, with your login and no project ref or `easyi18n.yaml`,
  answers your workspaces and their projects instead of "Missing project
  ref", and writes nothing: the agent asks you which one to link or what to
  create. `init {workspace, create: {name, base_code?, target_languages?}}`
  creates the project with this tree's stack and base language, enables its
  output format and writes `easyi18n.yaml`. `create` is refused with an API
  key in `EASYI18N_TOKEN`, over an existing `easyi18n.yaml` without `force`,
  and with `dry_run`. The `setup` prompt sends you to `easyi18n login` first
  and keeps the Agent key for CI. The MCP never mints an API key.
- `easyi18n init` with your login and no project ref sets the project up
  on the server: it lists your workspaces, links a project or creates one
  (named after the directory, base language from the catalog or the source
  file, target languages), adds the languages a linked project lacks and
  enables its output format, then writes `easyi18n.yaml`. Without a
  terminal, `--workspace`, `--project`, `--create`, `--languages` and
  `--base` make the same choices. On a Free workspace that already has 3
  projects it shows the server's message, names Workspace > Billing and
  offers to link one instead, and writes nothing. `--ci` mints an API key
  for CI and prints it once with the `gh secret set EASYI18N_TOKEN` line.
  With a login, the last line no longer says to set `EASYI18N_TOKEN`.
  `--workspace` and `--project` alone, or `EASYI18N_TOKEN`, keep `init`
  offline as before.
- `easyi18n whoami` asks the server whether the login still works
  (`GET /v1/me`) and lists its workspaces, with the role in each and their
  projects. A login the server refuses ends with exit 1 and `valid: false`.
  A server it cannot reach, or one without the route yet, leaves what this
  machine stored, with a warning, exit 0 and `valid: null`. `--json` adds
  `valid` and `workspaces`. `easyi18n mcp config` prints snippets without
  `EASYI18N_TOKEN`: the server sends this machine's `easyi18n login`.
  `--agent-key` adds `mcp --require-agent-key`. The server refuses to start
  with a missing key or the example placeholder.
- The MCP server (`easyi18n mcp`) takes the login `easyi18n login` stored
  for the base URL of each call when `EASYI18N_TOKEN` is unset, blank or the
  placeholder, and reads it on every call: a login or a logout in another
  terminal needs no restart of the client. With the login, `push`, `sync`,
  `publish` and `rollback` go without an `operation_id`, and `authorize`
  mints no operation and answers which tool to call, unless the server says
  that login needs an approval. An API key in `EASYI18N_TOKEN` keeps the
  approval rules as they were. An ingest above `EASYI18N_MCP_MAX_CREDITS`
  answers `above_ceiling` before sending anything. `status` and `init`
  without `easyi18n.yaml` ask the server nothing with a login: `init` asks
  for the project ref. `doctor` names the login on its `credential` line,
  also before `init`, and its `agent_key` check passes for a login. The
  server instructions, the `setup` prompt, the `AGENTS.md` block and the
  `no_credential` error name `easyi18n login`.
- `easyi18n login` logs this machine in as you: it opens the approval page
  with the code in the URL (`--no-browser` prints the page and the code
  instead), waits for the approval and keeps the login for 30 days in
  `credentials.json`, 0600 inside a 0700 directory. `--json` prints
  `{email, base_url, expires_at}`, never the token. It uses the base URL the
  other commands call and refuses, before any request, one that is not
  production over https, a loopback address or exactly `EASYI18N_BASE_URL`.
  A second `login` on the same base URL signs the previous one out, so
  logging in again does not spend one of the account's 10 logins.
- `easyi18n logout` signs the login of this base URL out on the server and
  forgets it here, also when the server cannot be reached, and says which
  happened. `--json` prints `{base_url, removed, revoked}`. Logins for other
  base URLs stay. `easyi18n whoami` shows the stored login's email and
  expiry, and says when `EASYI18N_TOKEN` is set
  and wins over it. `--json` prints `{logged_in, email, base_url,
  expires_at, uses_env_token}`; with no login, or an expired one, it exits 1
  with `not_logged_in` or `login_expired`. The `--token` help of every
  command, and `doctor`'s checks that need the API, now name the login.
  `logout`, `whoami` and `doctor` name a `credentials.json` this CLI cannot
  read, as the error with no credential does, without printing it. A disk
  that refuses to write `credentials.json` ends `login` or `logout` with an
  error that names the file instead of a crash.
- Every command that calls the API, `doctor` included, sends the login
  stored in `credentials.json` for the base URL of the call when neither
  `--token` nor `EASYI18N_TOKEN` names a credential. The file lives in
  `$XDG_CONFIG_HOME/easyi18n/`, else `~/.config/easyi18n/`, and in
  `%APPDATA%\easyi18n\` on Windows; `easyi18n login` writes it. A blank
  `EASYI18N_TOKEN`, or the `eik_YOUR_AGENT_KEY` placeholder that
  `mcp config` prints, no longer hides the login. With no credential the
  error names the origin and `easyi18n login`. A login the server refuses as
  expired or signed out prints the server's message without the hint to
  check `EASYI18N_TOKEN`. `doctor`'s `credential` line names the login, its
  email and its expiry.
- Web: `doctor` grades the i18next ICU wiring per instance. In an app with
  a client and a server instance, such as Remix with remix-i18next, it said
  `ok` for the first file that registered `i18next-icu` while the server
  rendered ICU as raw text. Now each file that registers i18next plugins
  without `i18next-icu` gets a `warn` that names it, with no `ok`, and
  `wiring` fails only when no file registers the plugin. A `plugins: [...]`
  or `use: [...]` list counts as registering it, so next-i18next wired as its
  README shows no longer fails. The wiring `init` prints says that every
  instance, the server's included, registers ICU.
- Angular: `doctor` reads `messages.json` as Angular's format. `source`
  counts the ids under `translations`, where it counted `locale` as a key,
  and a config that says `json` or `nested_json` fails with
  `set format: angular_json`, where it told the agent to set `nested_json`,
  which the server refuses. A new `ids` check warns when a message has no
  `@@id`: its id is a digest of the text, so editing the text starts its
  translation over; a plural or select is left out, since one nested in a
  message takes no `@@id` and the file does not tell it apart from a whole
  message that does. `sync_preview` lists the `{$…}` tokens of the file in
  `protected_tokens`, and the MCP `authorize` counts the ids of the file: it
  counted none, which the server refuses. The `setup` and `translate`
  prompts, the server instructions, the `AGENTS.md` block and the plugin
  skills name the Angular branch.
- `init` without `--stack` sets up the stack `doctor` checks: the detected
  one, else the one an existing `easyi18n.yaml` declares, else `flutter`. It
  set up `flutter` every time, so in a web, Xcode, Android or Angular project
  it wrote a Flutter Mode B config without `source:`, and the bare
  `easyi18n init` that `doctor` names to rewrite `AGENTS.md` wrote the Flutter
  block, which the next `doctor` reported as stale. A config the old default
  already wrote stays until `init --force` rewrites it. A typed `--stack`,
  `auto` included, and the MCP `init` tool are unchanged.
- Angular: a new `angular` stack, also a value of the MCP `init` tool's
  `stack`. `init --stack auto` detects an app with `@angular/localize` in
  `package.json` and an `angular.json`, and writes `format: angular_json`,
  `source: src/locale/messages.json` and `output: src/locale`. Its steps
  name `ng extract-i18n --format=json --output-path=src/locale` and the
  wiring: `loadTranslations` when the package is under `dependencies`
  (runtime), `i18n` and `localize` in `angular.json` when it is under
  `devDependencies` (build time). `sync` uploads `messages.json` and leaves
  out the `messages.<locale>.json` files that `pull` writes beside it.
  Under `auto`, an app that also uses Transloco, ngx-translate or i18next
  is refused with `ambiguous_stack` until `--stack angular` or `--stack web`
  picks one, and an Ionic or Capacitor app with `@angular/localize` and
  `android/` is `angular`, where it was `android`.
- Web: `doctor` fails `source` when the sync of its config would refuse the
  input: a second base-language file under `sourceLayout: locale-files` or
  `base-tree` (`several_files_per_locale`), or a config without `sourceRoot`
  and `sourceLayout` (`catalog_scope_unknown`). The message is the refusal
  that `sync` and `sync_preview` print, and `doctor` exits with 1 where it
  exited with 0. Under MCP the finding carries the `sourceLayout` remedy in
  `details`, since a finding's message is cut at 200 characters.
- The MCP tool descriptions name both credentials. `push`, `sync`,
  `publish` and `rollback` send the agent to `authorize` first: with an API
  key in `EASYI18N_TOKEN` it passes the approved `operation_id`, and when
  `authorize` answers that none is needed, as it does for your login, the
  call goes without one. They asked for an approved `operation_id` with any
  credential. `authorize` says that with your login it creates nothing and
  answers `not_needed` unless the server requires approval.
  `add_language` takes your login as well as a key
  with the `write` scope, and `status` says that without `easyi18n.yaml` it
  names no project for your login.
- A failed TLS handshake, such as a certificate the system does not trust,
  is a connection failure, as a server that is down is: one line,
  `error: Could not reach <base URL>: HandshakeException: …`, and exit 1;
  with `--json` the `cli_error` record with `retryable: true`; over MCP the
  same record. `status`, `pull`, `push`, `sync` and `login --no-browser`
  ended in an unhandled exception with exit 255 and an empty `--json`
  stdout, and the MCP `status` and `pull` answered `internal_error`. The
  certificate is still checked.

## 1.1.0

- Flutter Mode B: `init` declares `android.permission.INTERNET` in
  `android/app/src/main/AndroidManifest.xml`. `flutter create` declares it
  for debug and profile builds only, so a release build never reached
  delivery. `doctor` reads the main and release manifests and warns when
  the permission is missing or removed with `tools:node="remove"`; exit
  code 0, since a dependency can add it when Gradle merges the manifests.
  The `### Flutter` block of `AGENTS.md` names it, so `doctor` reports that
  block as stale until `init` rewrites it.
- The MCP `authorize {operation_id}` waits for the human. While the
  operation is pending it reads it again every 5 s and answers as soon as
  the human approves or denies, or after 45 s with `next: wait`, so the
  agent goes on without the human returning to the chat. A client that
  sends a `progressToken` gets `notifications/progress` every 10 s. Ten
  minutes after the server first saw the operation, the read answers at
  once with `next: ask_human`; `EASYI18N_MCP_APPROVAL_WAIT_SECONDS` shortens
  that. A denied operation answers `next: stop` and an expired one
  `next: reauthorize`, where both used to answer `next: authorize`. The
  instructions and the translate prompt tell the agent to keep calling in
  the same turn.
- Flutter Mode B: `init` writes `easyi18n: ^1.0.0`. It wrote `^0.2.0`,
  which excludes the SDK 1.0.0. It also raises a `^0.2.x` that an earlier
  init left, as it already raised a `^0.1.x`. `doctor` still passes a
  `^0.2.x`, which resolves the SDK it checks for, and still fails a
  `^0.1.x`.

## 1.0.0

- The first stable version is 1.0.0, not 0.13.0. It follows 0.13.0-rc.6; a
  constraint such as `^0.13.0` does not resolve to it.
- The MCP `init` refusal `unsupported_stack` does not name what stack
  detection looks for: an agent asked to set easyi18n up read "web needs one
  of @jsverse/transloco, @ngx-translate/core, i18next in package.json" as the
  next step and installed i18next. On a tree no stack detects, it says
  easyi18n does not support the repository yet and tells the agent to tell
  the human so, with the supported stacks and the roadmap, without adding
  dependencies or files, or to call `init` with `project_dir` if the app is
  in a subdirectory. A named stack on a tree another stack detects names
  that stack. `code`, `supported` and `roadmap` are unchanged, and so is the
  CLI's `init` message.

- The MCP `init` holds a named `stack` to detection too. On a tree its
  adapter does not detect, `stack: web` (or `xcode`, `android`, `flutter`)
  answers `unsupported_stack` with `supported` and `roadmap`, the way `auto`
  does, and writes nothing; the message names the stack. A named stack still
  picks among the stacks the tree has: a web app that commits `android/` can
  name `android`. The CLI's `--stack` is unchanged.
- With an Agent key in `EASYI18N_TOKEN` and no `easyi18n.yaml`, the MCP
  `status`, `init` and `doctor` no longer answer `isError`, and the first
  two read the key's project from the new `GET /v1/credential` route.
  `status` answers `initialized: false`, the key's `project`
  (`@handle/slug`, or the project id while the workspace handle is
  unclaimed) and `next: init`; with a config it adds `initialized: true`.
  `init` with no `workspace`, `project` or `project_id` writes that project
  into `easyi18n.yaml`, and its step says it was read from
  `EASYI18N_TOKEN`. The stack is picked first, so a tree `init` refuses
  sends nothing, and the request passes the same base-URL check as every
  other. `doctor` reports the missing config as a failed `config` check.
  The `setup` prompt calls `status` first, sends the human to create a
  project and a key only on `no_credential`, and asks for the workspace
  handle and project slug only when `init` answers `Missing project ref`,
  which is its answer from a server without the route; there `status`
  leaves `project` out. The CLI's `init` and `doctor` are unchanged.

- `init --stack android` and `init --stack auto` set up a native Android app
  (file-first, `format: android_xml`). Detection needs a Gradle script at the
  root (`settings.gradle` or `build.gradle`, `.kts` too) or an
  `AndroidManifest.xml` beside `res/`, and a `res/values/strings.xml`;
  `source:` is that base file and `output:` its `res/`. With several modules,
  `init` takes the `src/main` source set first and names how many others it
  found. `doctor` counts the `<string>` and `<plurals>` resources without
  `translatable="false"` and lists the `values-*` locales (`values-zh-rTW` is
  `zh-TW`, `values-b+zh+Hant` is `zh-Hant`). `sync` uploads the base, then
  each `values-<lang>/strings.xml` of a project language with its `lang`, so
  the strings translated by hand are imported and the fill translates only
  the rest. A directory whose qualifier names no language is never sent, and
  a language the project lacks is named and left out. `pull` writes
  `values-<qualifier>/strings.xml` and never the base. `android` leaves the
  roadmap of `unsupported_stack` for the supported stacks.
- A Flutter app that carries `android/` still detects as Flutter, and a
  React Native or Capacitor app that commits `android/` and declares
  i18next, ngx-translate or Transloco in `package.json` detects as `web`.
  `init --stack android` is the explicit choice for such a repository, and
  `doctor` and the MCP tools honor it through `format: android_xml`.
- The MCP loop runs on an Android project. `authorize`, `sync` and
  `fill_status` count the resources of `strings.xml` instead of failing with
  `internal_error`. `sync` uploads the language files right after the base,
  as the CLI does, and `sync_preview` and `sync` report them in
  `language_files` and the ones left out in `skipped_language_files`.
  `instructions` and the `setup` and `translate` prompts carry the Android
  branch.
- When the answer to the base sync of an Android project is lost after the
  server applied it (no HTTP answer, a 5xx, a `409 request_in_progress`),
  `sync` and the MCP `sync` still upload the language files if a fresh dry
  run shows the project holds the base, so the fill does not overwrite the
  hand translations. The failure is reported as before: the MCP answers
  `request_unresolved`, now with `language_files`, and the CLI exits 1 with
  the base's error.
- `doctor` grades a `sourceLayout: namespaces` or `scopes` project by the
  files `sync` uploads and `pull` writes. `source` reads every base file of
  the layout and fails on a file the sync cannot read or on a
  `catalog_key_collision`; `targets` lists the language files one directory
  down and warns on a hand edit before `pull` stops on it; under
  `namespaces`, `languages` takes each directory of `output:` that holds
  JSON as a language. It used to count only `source:`, see no targets and
  ask to delete `translation.json`.
- `init` on a gen_l10n project (Mode A) reads `arb-dir` and
  `template-arb-file` from `l10n.yaml`: `output:` is the `arb-dir`, and a
  template that exists is `source:`, which `pull` never writes. The first
  pull `init` recommends used to replace the template with the server's
  render, dropping its local keys and their metadata. The step that names
  the template, the Flutter block of `AGENTS.md` and the MCP prompts
  `setup` and `translate` ask to import the existing `.arb` files in the
  dashboard and publish before that pull. gen_l10n refuses two files for
  one locale, so `pull` writes each served locale into the `.arb` that
  gen_l10n already reads as it, by its `@@locale` or else its name
  (`es.arb`, `messages_es.arb`). A locale without one takes the prefix of
  a template named `strings_en.arb` (`strings_es.arb`) and keeps its
  canonical name otherwise; a template without a locale suffix
  (`messages.arb`) also keeps the served base out. A config written before
  keeps its behavior.
- `catalogs:` in `easyi18n.yaml` lists several String Catalogs
  (`Localizable.xcstrings`, `AppShortcuts.xcstrings`, `InfoPlist.xcstrings`)
  that are one project; `catalog:` keeps naming a single file. `sync` and the
  MCP tools `sync_preview` and `sync` upload the union of their entries with
  every key intact (no table prefix, so a key keeps the name it has with that
  file under `catalog:`), which is why a second sync disables nothing. `pull`
  and the MCP `pull` give each served key back to the file that holds it, and
  name a key no file holds (`unplaced_keys` in `--json`) instead of writing
  it. The same key in two files stops `sync` and `pull` before any request or
  write with `catalog_key_collision`, as do files with different base
  languages (`catalog_base_language_mismatch`); `catalog:` next to `catalogs:`,
  an empty list and a file listed twice are refused by name. `status`
  records and shows the list, `doctor` grades each file and their union, and
  the MCP results report `catalogs` instead of a single `catalog`.
- `init` on a project whose `easyi18n.yaml` already exists still keeps the
  file without `--force`, and now reports each value the call names that the
  file does not hold as a `skipped` step (`keeps baseUrl: A, not B (use
  --force to rewrite)`), in the MCP result, `--json` and the text output. The
  project ref and `--mode` used to warn on stderr only; `--base-url`,
  `--format`, `--output` and `--catalog` were ignored without a word.
- `init --stack web` writes `sourceLayout: namespaces` for i18next language
  directories in `locales/` or `public/locales/` (`sourceRoot` is the
  base-language directory, `source:` its `translation.json` or first
  namespace) and `sourceLayout: scopes` for a Transloco root file with a
  scope directory beside it. Its steps name the namespace files or the
  scopes, it no longer creates an empty `locales/en.json` next to a
  directory of namespaces, and the `### Web` block of `AGENTS.md` names the
  files the layout syncs. Other trees still get `locale-files`.
- `sourceLayout` takes two more values, `namespaces` and `scopes`, for web
  projects that keep several JSON files per locale. `namespaces` takes every
  JSON directly in `sourceRoot` (`locales/en/common.json`) as an i18next
  namespace; `scopes` takes `source:` as the Transloco root file and each
  `<sourceRoot>/<scope>/<base>.json` one directory down as a scope. `sync`
  and the MCP tools `sync_preview` and `sync` upload them as one catalog:
  each key is stored under its namespace or scope (`common.save`), and the
  root file's keys keep their names. `pull` writes every language back as
  `<output>/<lang>/<namespace>.json`, or `<output>/<lang>.json` and
  `<output>/<scope>/<lang>.json`, each in the key order and shape of its
  base file, and never writes a base file. A key that would land under
  another file's namespace or scope, such as a root key `admin.title` beside
  the scope `admin`, stops the sync before any request with
  `catalog_key_collision`. A file the layout has no place for is refused
  with `several_files_per_locale`, which under `locale-files` and
  `base-tree` now names the two new values.

## 0.13.0-rc.6

- `source:` sync requires both `sourceRoot` and `sourceLayout`.
  `locale-files` selects files named for the project's base language;
  `base-tree` selects every JSON under the declared root. Neither layout
  depends on `output`, the working directory or ancestor directory names.
  Configurations from development builds must add them; sync refuses an absent or
  invalid declaration with `catalog_scope_unknown` before uploading.
  `init` writes the detected input directory and `locale-files`. Generated
  directories inside the input tree require `sourceExclude`.

- When `sourceRoot` is absent, the `catalog_scope_unknown` refusal lists
  JSON files only in the source file's folder. It no longer scans the
  working tree, including unrelated catalogs and `node_modules`, to build
  the diagnostic.

- `pull` and `sync` stop instead of replacing a locale file that changed
  since the pull that wrote it. `pull` records a digest of each file it writes
  in `.easyi18n/state.json` (`digests`, beside `files`). The next `pull` names
  a file whose content no longer matches before it prunes or writes anything,
  `--dry-run` included, and exits 1 with `edited_targets`. A `sync` of a
  project with one file per locale does the same before it uploads. `--json`
  lists the files under `edited`, beside `error`; the MCP tools `pull`,
  `sync_preview`, `authorize`, `fill_status` and `sync` answer `isError` with
  `error.edited`. `--force`, new on both commands, replaces the file.
  Reformatting is not a change: JSON and ARB are compared decoded with their
  keys sorted, other formats with their line ends folded; the
  `@@last_modified` stamp of an ARB render is not compared. A file that already
  says what the pull serves is kept, so a change made in the dashboard and
  published needs no flag. `doctor` warns about such a file under `targets`.
  A record written by an older CLI has no digests and stops nothing; an
  older CLI reads the new record unchanged. `xcstrings` is merged as before.
  The record is per checkout: a file that arrived through Git from a pull on
  another machine reads as changed too.

- `doctor` grades a web project beyond its base file. `transpiler` fails
  when the ICU plugin of the detected library is missing from
  `package.json`, and `wiring` fails when no source file of the app provides
  it: `provideTranslocoMessageformat()` for Transloco,
  `provideTranslateCompiler(TranslateMessageFormatCompiler)` for
  ngx-translate, `i18next.use(ICU)` for i18next. `source` fails a base file
  whose shape is not the configured `format` (`json` is flat, `nested_json`
  nests), which the server would refuse at the next sync. `targets` warns
  about each locale file under `output:` that no `pull` of this checkout
  wrote, read from `.easyi18n/state.json`; on a checkout with no such record
  it lists the files and claims nothing. With a key, `languages` warns about
  each project language that has no locale file and each locale file whose
  language the project does not have; it reads `/meta`, which needs the
  `read` scope.
- The MCP tools grade the output format before an agent spends. `pull`
  enables the format of a project that has none, which takes the `write`
  scope, so an Agent key with `read, translate, publish` used to translate
  and publish and then stop at `pull` with the files unwritten. `doctor`
  reports `output_format`: `fail` when the project has no format and the key
  has neither `write` nor `admin`, or when the project has other formats and
  not the one `format:` names; the two remedies are in `details` (enable it
  under Project > Settings > Output, or `easyi18n formats add <id>` with a
  key that has `write`). `sync_preview`, and `push_preview` on a `mode: a`
  project, answer `next: output_format` with the same remedies in those two
  cases, and list what they read under `output_format` (`format`, `state`,
  `enabled`, `remedy`). A Flutter Mode B project is not graded: it never
  pulls. `doctor` in the CLI is unchanged.
- `init` sets up a web project that keeps one JSON file per locale.
  `--stack auto` detects a `package.json` that names `@jsverse/transloco`,
  `@ngx-translate/core` or `i18next`, and `--stack web` names the stack. It
  writes `format: json` (`nested_json` when the base file nests), `output:`
  as the directory of the locale files, and a new setting, `source:`, the
  base-language file `sync` uploads. One step names the ICU transpiler of
  the library and prints its wiring; `init` does not edit `package.json`.
  `doctor` checks that the file `source:` names exists and parses.
- `sync` completes on a web project. It uploads the file `source:` names,
  waits for the translation, publishes, and writes one file per target
  language into `output:`. The write-back records `.easyi18n/state.json` as
  a `pull` does. In `--json`, `delivery.languages` is `null` for such a
  project: no single catalog is read back.
- `pull` and the write-back of `sync` never write the file `source:` names.
  A plain `pull` used to replace it with the server's render of the base
  language; `pull --lang <target>` did not. The served name is matched to
  that file without case, so a `pt-br.json` is not replaced by `pt-BR.json`
  on a case-insensitive disk.
- `sync`, and the MCP tools `sync_preview`, `authorize`, `fill_status` and
  `sync`, refuse a web project whose base language is kept in several files
  (i18next namespaces, Transloco scopes) before any upload, with code
  `several_files_per_locale` and the files in `source` and `files`. One
  upload is the whole catalog of the project, so the keys of the other files
  would be disabled.
- `sync` still refuses, with code `format_not_writable` and before any
  request, a `catalog:` on a format that renders one file per locale: that
  write-back would fail after the fill was charged. The message now points
  at `source:`.
- The `setup` and `translate` prompts, the server instructions and the
  Claude Code plugin skills cover the web stack: detection by
  `package.json`, literals moved into the base file as ICU, `sync_preview`
  as the preview, and a `pull` that writes the other locales.
- The refusal of `init` on a tree it does not recognize lists `web` among
  the supported stacks and names the three libraries it looks for. In the
  roadmap list of that message and of the `setup` prompt, "web JS/TS"
  becomes "web t() extraction": the catalogs are supported, and reading the
  calls out of the source is still to come.
- The MCP `init` tool answers a tree it does not recognize with code
  `unsupported_stack`, and the error object carries two lists: `supported`,
  the stacks `init` can set up, and `roadmap`, the ones announced. It used to
  answer `cli_error`, and both lists existed only inside the sentence. The
  message is unchanged. `init --json --stack auto` reports the same code on
  such a tree; its error record carries no lists.
- `init` marks the development values it writes into `main.dart`. The
  `refreshInterval` of 10 seconds, and the `baseUrl` when `easyi18n.yaml`
  names a backend other than production, each get a `// Development value:`
  comment on the line above that says what to do before a release. The
  snippet `init` prints when it cannot patch `main.dart`, and `scope_snippet`
  under `--json`, carry the same comments. A `main.dart` an earlier `init`
  already wired is left as it is.
- `sync` no longer says a language is "translated from scratch and part of
  the estimate" when the run translates nothing for it. A language the
  project already holds in full and your catalog does not carry yet was
  priced at zero and still announced that way on every run. The preview now
  prints those languages on their own line: "Not in your catalog: de — this
  run has nothing to translate for these and they are not part of the
  estimate below." Languages with pairs to translate keep the previous line.
  The split reads `plannedPairs`, a new field on the `LANG_NOT_IN_FILE` rows
  of the `/v1/sync` dry run; `sync --json` passes it through under
  `preview.diagnostics`. Against a server without the field the output is
  unchanged.
- A usage error under `--json` is a JSON error record on stdout with code
  `usage_error`, and still exits 64. An unknown option, a value the parser
  refuses, `--version` combined with a command and `mcp config` without
  `--client` used to print the message and the usage text on stderr and leave
  stdout empty. Without `--json` the output is unchanged.
  `Easyi18nCommandRunner.run` returns 64 for these under `--json` where it
  used to throw `UsageException`.
- A usage error printed as text no longer shows an API key pasted where the
  parser refuses it. `easyi18n sync --on-conflict <key>` and
  `easyi18n <key>` quoted the key on stderr; they now print `[REDACTED]` in
  its place, as every other line of the CLI and the `--json` record already
  did. Terminal control characters in the refused argument are dropped the
  same way. Any other usage error prints the same text as before.
- The MCP `fill_status` text for `next: ingest_again` says what the next
  `push` or `sync` does to the operation's attempts. When the local log lets
  it continue the last attempt (a request closed as `lost`, or a batch the
  server refused), the text says it continues that attempt and opens no new
  one. Otherwise it says a new attempt opens and how many of the three the
  operation has left. It used to say "need a new ingest ... at most twice" in
  both cases, also with one attempt left. `next` and the fields are unchanged.
- `init` no longer writes `output: lib/l10n` into a config that has a
  `catalog:`, which is the config `init --stack xcode` writes. The line named
  a Flutter directory an Xcode project does not have, under a comment about
  `l10n.yaml`, and `pull` and `sync` do not read `output` while a catalog is
  configured. An `--output` other than `lib/l10n` is still written there,
  under a comment that says it is not used while `catalog:` is set. A config
  without a catalog is written as before, and an `easyi18n.yaml` that already
  exists is left as it is.
- The MCP tools stop a `push` or `sync` that would take the project past
  the key limit of its plan before anyone approves it. When the dry run
  reports `wouldExceedKeyCap`, `push_preview`, `sync_preview` and
  `fill_status` answer `next: plan_limit`, `authorize` refuses with code
  `plan_limit` and creates no operation, and `push` and `sync` refuse with
  the same code before the real request, so no attempt is spent. The text
  says a plan upgrade or fewer keys clears it, and that authorizing or
  retrying does not. The preview used to answer `next: authorize`, and the
  approved `push` got a 402 on every attempt. A 402 `plan_limit` that still
  arrives on the real request keeps the server's message.
- A 403 `authorization_required` on the real request of the MCP `push` or
  `sync`, which the server sends when a pair became payable after the dry
  run, answers with the remedy of the local gate: `authorize {action:
  translate}`, the server's estimate under `estimated_credits` and the
  `attempt`. It used to forward the server's message, which names
  `POST /v1/operations`.
- `mcp config --client codex` adds `required = true` and
  `omit_tools_from = ["deferred"]` to the snippet. Codex waits for the server
  and exposes its tools at startup, so a session cannot go on without them.

## 0.13.0-rc.5

- MCP `push` and `sync` keep a resent request unresolved when the original
  is still processing (`409 request_in_progress`), so `fill_status` can
  recover its eventual result.

- MCP `push` and `sync`: a request `fill_status` closes as `lost` (the server
  holds no record of it) goes again under the same `attempt_id` and with the
  same `request_id`, from that batch on. It used to start a new attempt from
  batch 0, which spent one of the operation's three attempts and sent the
  accepted batches a second time.
- `mcp config` pins the npm snippet to the CLI that prints it:
  `npx -y @easyi18n.com/cli@<version> mcp`. Unpinned, a client installed npm's
  `latest`, which was rc.1 while rc.4 printed the snippet. The Codex snippet
  sets `startup_timeout_sec = 60`: a first `npx` download took 19.9 s and
  Codex gives a server 10 s, so the server showed `failed`.
- `init` names the stack roadmap (web JS/TS, Android, gettext) when it finds
  no supported stack or is given an unknown one. The `setup` prompt already
  did, and a client that does not load MCP prompts, such as Codex, only saw
  the refusal.
- `pull` on a mode B Flutter project whose `pubspec.yaml` bundles
  `assets/easyi18n/` bakes the offline floor: it reads the live delivery
  manifest and writes each locale's bundle to `assets/easyi18n/<locale>.json`,
  after checking it against its content address. Before this the folder `init`
  creates kept only its `.gitkeep`, and the first `flutter run -d chrome` of a
  new app logged `failed to fetch "assets/assets/easyi18n/en.json"` with a 404.
  The `.arb` files are still written. `--lang` bakes one locale; `--version`
  bakes none, because the manifest only serves the live version.
- `doctor` fails when the manifest serves a locale the offline floor lacks,
  and warns when the floor is empty before the first publish. It used to pass
  as soon as the folder existed. Itemized assets must register each locale;
  files present on disk but absent from the asset list fail the check.
- `pull` rejects manifest locales that could form a path outside the floor.
- `sync --json` that fails after its run settles (the publish, the pull, or
  a `--require-complete` refusal) puts the sync report in the error
  record, beside `error`: `preview`, `synced`, `attempts`,
  `still_incomplete` and `stopped_short`, and `delivery` once the publish
  answered. A pull that fails after the publish reports the version with
  `pulled_version: null` and `languages: null`, because the catalog was
  never read back. The record used to be `{"error": ...}` alone while the
  catalog had already been applied.
- `sync --json` that fails inside its run, after the server answered a POST
  (contended entries left after the retries, a failed job poll, a failed
  re-POST), keeps those answers in the error record: `attempts` has one
  entry per answered POST, `synced` is the last one, and `still_incomplete`
  and `stopped_short` are `null` because the run never settled. A failure
  on the first real POST is still `error` alone.
- `push --json` that fails on a later batch, or stops at `--max-credits`
  after charging one, keeps the accepted batches in the error record under
  `pushed` (their job tokens and credits), with `lockfile_written: false`.
- A disk failure under `--json` is an error record with code `file_system`
  instead of an empty stdout and an unhandled exception. `sync` keeps the
  published version under `delivery` when the write-back fails, `push`
  keeps `pushed` when the lockfile write fails, and `pull` keeps
  `files_written` and `pruned` when a later file fails. Without `--json` the
  exception is unchanged.
- `pull --json --require-complete` that refuses an incomplete version puts
  the pull report beside `error`: `files_written` and the `coverage` the gate
  refused on. The files were already written; the record used to say only
  `error`.

## 0.13.0-rc.4

- The npm package `@easyi18n.com/cli` no longer fails its install when it
  cannot get the binary (a platform with no binary, such as linux-arm64, a
  download error, a checksum mismatch). `npx -y @easyi18n.com/cli mcp`
  used to exit 1 with an empty stderr, because npx stops at a failed
  postinstall and prints none of its output. Now the install leaves no
  binary, the first run installs again, and a failure is printed on stderr
  as `easyi18n: <reason>` with exit 1.

## 0.13.0-rc.3

- `init` on a Flutter project (mode B) leaves an app that can show a
  translation. The `Easyi18nScope` it writes names the `baseUrl` of
  `easyi18n.yaml` when that is not production (the SDK default), and polls
  the manifest every 10 s, so a publish reaches the running app. It adds
  `flutter_localizations` to the pubspec and, on the single `MaterialApp(` or
  `MaterialApp.router(` of `main.dart`, inserts `localizationsDelegates:
  GlobalMaterialLocalizations.delegates` and `supportedLocales:
  Easyi18nScope.localesOf(context)` (SDK 0.2.0; the pubspec dependency is now
  `^0.2.0`), dropping a `const` in front. A `MaterialApp` built without a
  `BuildContext`, more than one, or one reached through what `init` does not
  read (a `${` interpolation, a multi-line string, a comment naming the site)
  is reported `skipped` with the full snippet, like the scope; an app that
  already names either argument is left alone. Before this the app resolved `en_US` whatever the device said and
  read production while the CLI published to the emulator, and the acceptance
  run of #1422 had to wire all of it by hand.
- `doctor` fails when the mounted `Easyi18nScope` has no `baseUrl` while
  `easyi18n.yaml` is not production, and when the app's `MaterialApp` names
  neither `localizationsDelegates` nor `supportedLocales`. A tree without a
  `MaterialApp` is reported and not failed.
- The `translate` prompt's step 6 says that the app follows the device
  language, which is where a target language is chosen.
- `pull --lang <base> --require-complete` says that `--lang` names the base
  language. It used to say the version reports no target language, which is
  false for a version that carries them. The exit code is unchanged.
- `doctor` against a backend that reports no per-language coverage says to
  upgrade the backend, as `pull --require-complete` does. It used to say to
  publish again, which against that backend changes nothing.
- `pull --lang ""` (and the MCP `pull` tool with `lang: ""`) is a full pull,
  as the server already rendered it: it prunes renamed files, records the
  full file set, and `--require-complete` grades every language. It used to
  answer "--lang  is the base language" and leave stale files behind. A
  blank `--lang "  "` is the same full pull, and a padded `--lang " es "`
  gates `es`, because the server trims the value before reading it.
- The MCP `push` and `sync` under an operation still waiting for its
  approval tell the agent to wait with `authorize {operation_id}`. They used
  to say to report what it charged and to authorize again only if the human
  agreed, a question whose answer returns the same pending operation.
- The MCP `publish` and `rollback` only tell the agent to wait for a
  `pending_approval` operation. A denied or unavailable operation asks the
  human whether to authorize again instead of assuming it is pending.
- The MCP `push` and `sync` refuse an operation whose action is not
  `translate` with `action_mismatch`, in any state and before any request,
  and the text names the action it carries. A `publish` or `rollback`
  operation used to be reported as `scope_changed`, "the strings changed
  since the human approved this operation".
- The MCP `publish` builds its `fill_incomplete` text from the counts the
  server sent: cells refused by the ICU or markup gates and pairs that used
  up their fill attempts are counted and handed to the human, pending cells
  send the agent to `fill_status` and its `next`, and under `approved_only`
  the text says a cell also needs its approval. If `fill_status` says publish
  and the refusal comes back, the agent reports the counts instead of
  publishing again. It used to say "Poll fill_status until it is complete"
  for every refusal, including an `approved_only` one whose fill was already
  complete.
- The `setup` prompt reads `init`'s "No supported stack found" as it is: the
  agent checks whether it is at the root of the app, retries with
  `project_dir` only on a directory that meets the detection of step 1, and
  otherwise stops and says it found no supported stack. It used to say the
  stack was supported and the agent was above the app, which is false on a
  Node repository. Step 1 names what the Xcode adapter detects: an
  `.xcodeproj` or `.xcworkspace` plus any `.xcstrings` catalog other than
  `InfoPlist.xcstrings`, not only `Localizable.xcstrings`.
- The MCP `fill_status` answers `next: reauthorize` instead of
  `ingest_again` when the operation already registered its three attempts
  and the local log cannot continue the last one: the server refuses a
  fourth with `attempts_exhausted`. The text says so and warns that
  `authorize` may return the same operation until the server expires it. A
  poll or a publish is unchanged, and so is an ingest that continues the
  last attempt.
- A 403 `authorization_required` (an Agent key with no approved operation)
  no longer ends with "The token is valid but lacks the required scope for
  this project": the token has the scope. The MCP `push` and `sync` that
  meet it on the real request, because a pair became payable after the dry
  run, report the server's estimate as `estimated_credits`, in credits.
- The MCP `fill_status` summary tells the agent to report every request it
  closed as `expired` (the server's 24 h response window, or a local intent
  older than that): its answer is gone and it is not re-sent. It used to
  show only in `reconciled[].state`, under "complete. Authorize and
  publish." or "Poll again".
- `push --json --publish` that fails after writing the lockfile (the fill
  wait, `--require-complete`, or the publish call) puts the push report in
  the error record, beside `error`: `preview`, `pushed` with its
  `tracking_tokens`, `published: null`, `lockfile_written: true` and
  `dry_run`, the fields of a successful record. The record used to be
  `{"error": ...}` alone while the text run had already printed `Pushed.`.
  A failure before the lockfile moves is still `error` alone.

## 0.13.0-rc.2

- `init` writes an easyi18n block into `AGENTS.md` for coding agents without
  an MCP client: the translate loop, the credit and key rules, and the
  stack's own rules (Flutter `tr()` and ICU, or the Xcode catalog). It creates
  the file, appends to one without the block, or rewrites only what is between
  `<!-- easyi18n:start -->` and `<!-- easyi18n:end -->`, reporting `created`,
  `patched`, `updated` or `ok`. `--no-agents` (MCP: `write_agents: false`)
  skips it. It never touches `CLAUDE.md` or `.cursorrules`, and suggests
  `@AGENTS.md` when a `CLAUDE.md` does not mention it. `doctor` adds the
  `agents_md` check, which warns when the block is missing, stale or edited
  by hand and never fails.
- The MCP server drives an Xcode String Catalog end to end. `sync_preview`
  prices the upload of the configured `catalog:` without registering
  anything: keys it creates and updates, conflicts with the project,
  diagnostics and estimated credits. `sync` uploads it, applies it and queues
  the translation; like `push`, it needs the `operation_id` of an approved
  `authorize {action: translate}` when it costs credits, writes the intent of
  its request to `.easyi18n/operations/` before sending it, and never
  publishes or waits. Its record names the catalog and `key_policy:
  local_owns`, so the next `pull` keeps the catalog's own key set instead of
  adding back keys deleted from it. An entry that lost a create race is not
  re-sent by the tool: it answers `next: sync`, and the agent syncs again
  under the same operation.
- `authorize {action: translate}` and `fill_status` work on a file-first
  project, where 0.12.0 answered `wrong_family`. `authorize` takes
  `on_conflict` (`server` or `file`), which is part of what the human
  approves, and on an approved operation answers `next: sync` for a catalog.
  `langs` is refused there with `langs_unsupported`: a sync fills every
  language the catalog carries. `fill_status` on a catalog is `complete` only
  when nothing is in flight and the dry run estimates 0 credits.
- `authorize {operation_id}` reads the operation without `action`, as its
  description always said; 0.12.0 rejected that call with
  `invalid_arguments`. A call with neither is refused as `action_required`.
- The `wrong_family` message no longer claims the tool is for code-first
  projects; it names the tool to use instead, as before.
- The `setup` prompt and the `agent_key` warning of `doctor` sent the human to
  a "For an AI agent" option the dashboard does not have. They now name the
  control that creates an Agent key: API keys > New API key, Used by: AI
  agent.
- `easyi18n mcp config --client <client>` prints the snippet that registers
  the MCP server in `claude-code`, `claude-desktop`, `cursor`, `vscode`,
  `codex`, `gemini`, `windsurf`, `zed` or any other client (`generic`), and
  on stderr where it goes. `--runner npx` (default) starts the server with
  the npm package `@easyi18n.com/cli`; `--runner dart` with `dart pub global
  run`. The Cursor, VS Code and Gemini snippets go in a file inside the repo,
  so they read the key through the client's interpolation instead of holding
  it; the command never reads `EASYI18N_TOKEN`. `--json` emits `client`,
  `runner`, `format`, `target` and `snippet`.

## 0.12.0

- `easyi18n mcp` runs an MCP server on stdio for an AI agent to drive. It
  takes the key from `EASYI18N_TOKEN` in the server's env and the project from
  the `project_dir` argument, then `EASYI18N_PROJECT_DIR`, then the working
  directory. It refuses to send the key to a `baseUrl` other than the easyi18n
  API over HTTPS or a loopback host, unless `EASYI18N_BASE_URL` names that
  exact origin. Tools:
  `doctor`, `status`, `init`, `extract`, `pull`, `apply`, `push_preview`,
  `push`, `fill_status`, `authorize`, `publish`, `rollback` and `add_language`;
  prompts: `setup` and `translate`. A `push` that costs credits needs the
  `operation_id` of an approved `authorize {action: translate}`, whose
  `max_credits` is clamped to `EASYI18N_MCP_MAX_CREDITS` (default 50, `0`
  disables paid ingests); a push that costs nothing needs no approval.
  `fill_status` reports what is still pending and settles any request that
  left without an answer. Every tool result is capped at 32 KiB. `extract`,
  `apply`, `push_preview`, `push` and `fill_status` read `tr()` calls, so they
  serve Flutter projects; the tools for an Xcode catalog are not in this
  release.
- `easyi18n --version` prints `easyi18n <version>`, or `{"version": ...}`
  under `--json`.
- A global `--json` flag makes `init`, `doctor`, `status`, `extract`, `pull`,
  `apply`, `push`, `sync`, `rollback`, `languages add` and `formats add` print
  one JSON object on stdout; warnings stay on stderr and the text output is
  unchanged. A failure prints `{"error": {"message", "code", "statusCode",
  "retryable"}}`, where `retryable` is true for transport failures and for the
  HTTP statuses the CLI already retried. Under `--json` nothing prompts:
  `push` and `sync` refuse to spend credits without `--yes` and fail with
  `confirmation_required`.
- `push` and `sync` no longer read a confirmation from piped stdin. Without a
  terminal they decline and say to pass `--yes`, as before when the answer was
  not `y`.
- `init --stack flutter|xcode|auto` (default `flutter`). `xcode` finds the
  project's String Catalog (`Localizable.xcstrings` first, `InfoPlist.xcstrings`
  never), writes `catalog:`, `format: xcstrings` and `mode: a`, and scaffolds
  nothing else; `--catalog <path>` names a different one. `auto` detects the
  stack and refuses a tree it does not recognize. `doctor` reports the
  detected `stack` and `family` and checks the catalog, format, mode and Xcode
  setup of a file-first project.
- The MCP tools `publish` and `rollback` freeze and restore a version behind a
  human approval: `authorize {action: publish|rollback}` returns the
  `approval_url`, and the tool refuses without the approved `operation_id`. A
  rollback names its target as `previous` by default; the server resolves that
  alias when it mints the operation, so what the human approves is the version
  id that goes live.
- `push --json --publish` works: the record gains a `published` block with
  `version_id`, `key_count`, `unchanged` and `refused` (the ICU and markup
  rows plus the server's totals, which exceed the rows once the 50-row cap
  bites). Until now the combination was refused with `json_unsupported`, so a
  CI job that published had no way to read which version it minted.
- `easyi18n languages add <code> [--fill-mode ai|manual]` and the MCP tool
  `add_language` add a target language through
  `POST /v1/projects/{id}/languages`, with a key that has the `write` scope.
  Re-adding a removed language revives it. The command prints the code as the
  server stored it (`PT_BR` becomes `pt-br`); `--json` carries `code`,
  `fill_mode`, `project_dir`, `base_url` and `next`. Against a backend without
  the route the server answers 404 and the command fails with it.
- The MCP `doctor` tool asks the server whether the key in `EASYI18N_TOKEN`
  is an Agent key (`GET /v1/projects/{id}/credential`) and warns when it is
  not: that key spends and publishes without a human approval. Against a
  backend without the route the check reads `unverified`. `easyi18n doctor`
  does not ask, because a CI key is the other valid kind.
- A failed command on a 5xx now prints the server's correlation id (from the
  error body, else the `x-correlation-id` header) to quote in a support
  ticket, and a 500 gets its own hint instead of the bare `internal error`.
- `sync` prints one line per diagnostic code the server cut from its listing,
  with the number of rows left out and the languages they came from; `--json`
  carries them as `diagnostics_omitted`. The backend now lists 10 rows per
  (code, language).
- **Breaking file-workflow requirements:** `sync` with publication and Mode A
  `push --publish` now stop before preview if metadata is unreadable, malformed
  or lacks output-formats API version 1, even for an already configured project.
  Mode A `push --publish` now requires `read` in addition to `translate,publish`;
  adopting a format also requires `write`.
- Remove the exported `SyncRunner.fetchMeta` and `checkOutputFormat` helpers;
  file workflow preflight now belongs to `OutputFormatAdoption`.

- Adopt formats conditionally in file-delivery flows after budget/consent,
  require backend capability before preview, and publish with
  `requiredOutputFormat`. Preserve confirmed configuration changes in later
  errors and sync JSON. Mode B push and sync without publication retain their
  existing permissions. Empty Mode A pushes are covered.
- Recover formatless pulls after a real format error, retrying the same
  version/lang once. Healthy pulls add no lookup; watch adopts at most once,
  read-only keys receive write-scope advice, and dry-run never adopts.

- Add `easyi18n formats add <id>` with the write scope, project ID/alias
  resolution and text/JSON confirmation of the persisted format list.
  Repeating the command reports whether configuration changed, including
  materialization of legacy formats. It does not publish translations.
- Share typed POST transport with publish/rollback while preserving their
  success statuses, parsers and replay policy. Invalid add responses provide
  add-specific recovery advice.

- **One noun for the refusal counts (#1175).** `push`, `sync` and `rollback`
  report the same two counters (`icuRejected` / `markupRejected`) and printed
  three different words for them — `translation(s)`, `value(s)` and
  `cell(s)`. Since #1000 a refused row can name the base language, where the
  refused value is the stored source and not a translation, so two of the
  three were wrong for part of what they counted. All three now print
  `cell(s)`, the one noun true of both natures. The number itself has not
  changed.

- **`pull --require-complete --dry-run` gates without writing (#1178).** The
  gate runs before the writes and does not read `--dry-run`, so the pair is
  the combination a CI job wants: it answers "is the published version
  complete?" and leaves the working tree untouched. Behaviour is unchanged —
  this pins it, because a dry run used as a cheap gate that exits 0 over the
  state the real run refuses is the defect `sync` settled in #955. The
  `--require-complete` and `--dry-run` rows of the README say so.

- **A parse finding now names the language column it was lost from (#726).**
  `/v1/sync` raises the parsers' findings per language pass and forwards the
  pass on each row; the CLI grouped them by code and message shape, and the
  messages of `PLURAL_SHAPE_MISMATCH` and `DEVICE_VARIATION_FALLBACK` name
  nothing (the key is in `field`, which the shape blanks out), so two
  languages losing the same string printed as one line naming neither. The
  line now carries `— in: en, fr`, capped and counted like `also on:`, and the
  language joins the identity of an already-printed row so a row only the real
  run carries is no longer discarded against the preview's. A row with no
  language — the base parse's and the `LANG_*` family — prints exactly the
  line it always printed.

- **`pull --require-complete` — the completeness gate a Mode A CI job can
  fail on (#1052).** A Mode A project's translations live on the server and
  its publish skips the cells it has no translation for, so an incomplete
  locale rendered as a shorter file that no command could turn red: `sync
  --require-complete` needs a `catalog:` a gen_l10n project does not have,
  `push` has no `tr()` units to gate, `pull` and `status` never looked at
  per-locale coverage, and `doctor` skipped its grading on Mode A and printed
  `All checks passed.` over half-translated locales. The export now reports
  per-language coverage off the published snapshot, and `pull
  --require-complete` fails, naming each incomplete language and its missing
  count, when any target language is short. `doctor` grades the same thing on
  a Mode A project instead of skipping it (#1176): a short language is a
  FAIL, and a version it cannot judge — or a missing credential — reports
  "could not verify", which keeps the run from printing `All checks
  passed.` Back on the gate: `pull --require-complete` refuses a backend
  that does not report coverage ("cannot verify"), never passes it — and so
  refuses a version the count cannot judge: one published with `incompleteMode:
  source` (the base text is baked into every untranslated cell, so it always
  reads complete), one published before the server started stamping how it
  treated those cells, and one with no target language at all. Only a cell
  that renders as non-empty text counts as translated. The flag refuses
  outright, before any request, on a `mode:` other than `a` (a config with no
  `mode:` line at all reads as `b` — the refusal names adding `mode: a` as
  the fix), on `--lang` naming the base language, and with `--watch` (the
  gate is one-shot) — nine refusals in all, so a CI step gets a verdict or
  an error, never a green it did not earn. The ninth is a basis the version
  states and this client does not recognize, which is separate from a version
  that states none. `doctor` reads the same set the gate does — one symbol,
  not a copied predicate (#1248): only `skip` is judgeable, so `source`, a
  basis this client cannot read, and an unstamped version are all reported as
  unverified rather than graded, and each is reported with its OWN message and
  its own remedy, the same three the gate refuses on. A version whose basis
  this client does not recognize is told to upgrade the CLI, not to republish
  — republishing stamps the same basis again. A version with no target
  language at all is reported as nothing to grade rather than as a check that
  could not run (#1176). That last state is the one where the two commands
  answer the same version differently, on purpose: a base-only project is
  healthy for a health check and has nothing to gate on for a gate, so
  `doctor` passes it while `pull
  --require-complete` refuses it. `doctor` names the sibling's refusal in
  that line, so the disagreement is not something a red CI job has to be
  reverse-engineered from.

**`doctor` can now exit 1 where it exited 0 — read this before upgrading.** A
Mode A project with a short target language used to print `All checks
passed.`; it is now a FAIL naming each language and its missing count. Every
"could not verify" arm — no credential, a 403, a version the basis cannot
judge, a backend that reports no coverage, an unreachable API — still exits
0, so a job only turns red on a state that is actually incomplete. On a Mode
A project `doctor` also makes its first authenticated request: it sends
`EASYI18N_TOKEN` to `baseUrl` to read the published coverage, and warns
first when that `baseUrl` is not the production origin, like the other
commands that send the token.

**A green CI job can start writing something different — read this before
upgrading.** `sync` used to tell the server that its catalog was current as of
the moment it ran `pull`. It now sends the instant the *content* it pulled was
published, which is earlier — often by a day, and by weeks under `pull
--version`. That is the point: the pull renders the last **published**
snapshot, never the live keys, so a correction made in the dashboard since
that publish was never in the file. Claiming the pull moment told the server
the file already carried it, and the server silently reverted the correction
with no conflict row and no trace (#898).

With the correct claim, those keys now come back as base-language conflict
rows. Under the default `onConflict: server` the project's source is kept and
**your file's base text is no longer imported for them**; `--on-conflict file`
keeps today's outcome and still reports the row. A plain `pull` refuses
nothing new and adds no exit path: a conflict row is a warning, never a
failure (the two new refusals in this version are both opt-in flags:
`sync --dry-run --require-complete` and `pull --require-complete`, both in
this section). What
it can change is what the run has left to do — `--require-complete` still
decides by what the server reports as unfilled — and it can write less than it
did and print warning lines it did not. This affects a plain
`pull` too, not only `--version`, and it closes the `rollback → pull → sync`
sequence, which reproduced the same silent revert with no flag at all. A caret
constraint over `0.x` pins the minor, so this does not install itself into an
existing job.

- **`pull` records what its files are not behind, and `sync` claims that.**
  The server now reports `snapshotAt` on the pull response, and the CLI stores
  it in `.easyi18n/state.json` next to `pulledAt`. The two are separate on
  purpose: `snapshotAt` is the claim, `pulledAt` is what `easyi18n status`
  displays, and a `pull --version` from two weeks ago must not make `status`
  say "pulled 13 days ago" a second after it ran. (#898)
- **Nothing new can fail because of it.** A server that does not report the
  field, a value that names no timezone, and a value of the wrong type all
  fall back to dating the pull by the local clock — the previous behaviour —
  instead of failing the pull. State written by an older CLI keeps arming the
  guard through its `pulledAt`, so upgrading never drops the claim. (#898)
- **Known residual — a version restored before the server side of this
  shipped.** Its stored instant is the restore's, not its content's, so a pull
  of it still over-claims until the project publishes or restores again. That
  is today's behaviour, unchanged, not a new failure.
- **Known residual.** `sync`'s own final pull deliberately records no state,
  so after a `sync` that publishes, the stored claim still names the previous
  version. The next `sync` can therefore report one conflict row too many for
  a key the dashboard moved and that publish already carried. The direction is
  safe — a row, never a silent revert — and an explicit `pull` resets it.
- **`sync --dry-run` now reports exhausted and held pairs, and
  `--require-complete` gates it.** The preview always carried the `exhausted`
  rows and the `pendingSkipped` count the real run refuses on, but the dry
  run returned before reading them: it said nothing where `push --dry-run`
  warns, and `sync --dry-run --require-complete` exited 0 in silence. It now
  warns naming each exhausted pair and counting the held ones and, under
  `--require-complete`, fails (exit ≠ 0): a CI job using the dry run as a
  cheap gate can go red on upgrade, on exactly the state the real run would
  have refused. What only a fill decides (a job stopping short) is still the
  real run's call. (#955)

## 0.11.0

**Two new refusals — read before upgrading a CI job.** `push --publish
--require-complete` now fails (exit ≠ 0, nothing published) when the AI retry
budget is spent, exactly as `sync --require-complete` already did, or when the
scan finds no extractable units. A previously-green CI job may go red on
upgrade: #752 means untranslated pairs would have shipped as source text;
#952 means `push` scanned no units and could not verify the remote catalog at
all. Everything else below is new output printed permanently, a new option
whose default preserves today's behaviour, or a crash that becomes a success.
A caret constraint over `0.x` pins the minor, so none of this installs itself
into an existing job.

- **A malformed baked email bundle now blocks deploy with an attributed error
  instead of a stack trace.** Invalid UTF-8, invalid JSON, a non-object root,
  or a non-object `tokenIndex` names the exact bundle to replace or regenerate
  and exits 2. Filesystem and extractor failures keep their original types,
  while `tokenIndex` values remain intentionally unvalidated because this gate
  consumes only its keys. (#1018)
- **A 200 whose body is JSON of the wrong shape now fails with a sentence
  instead of a stack trace.** A response that parsed as JSON but carried an
  array, a string, or a field of the wrong type left the CLI with an uncaught
  `TypeError` and exit 255 — from a proxy that answers with its own envelope,
  a `baseUrl` aimed at the wrong service, or a schema regression. Every
  success body is now read field by field: the failure names the endpoint and
  the field, and exits 1. This covers every HTTP response reader in the CLI,
  not just the API client — `sync` no longer dies on a diagnostic row whose
  `alsoSpelled` is not a list, and `doctor` no longer dies on a delivery
  manifest whose `tokenAlgoVersions` is not one (it reports the manifest as
  unreadable instead).
  **No response that succeeds today starts failing** —
  the readers accept exactly what the casts they replace accepted (a field
  that is absent or null still falls back to its default), and the lists the
  CLI never iterates stay tolerant of a stray non-string element, as they are
  today. Two observable changes that are not refusals: the exit code of an
  already-crashing response moves from 255 to 1, and a `pending` list holding
  no usable language no longer counts its unit as needing a fill. A **real**
  `push` or `sync` that fails this way adds one line: the server may already
  have reserved credits and queued a fill, so the line names that re-running
  is safe and does not pay twice. A `--dry-run` (and the cost preview every
  `sync` opens with) does not print it — that request is answered before the
  hold and before the enqueue, so there is nothing to re-run into. (#972)
- **A non-string `project` in the local `easyi18n.lock` is now treated as
  absent.** The field is inert when the lockfile is read; `extract` and `push`
  consume its units, while a push writes the resolved project id. Any value
  that is not a string — a number, a boolean, an array, an object — now falls
  back to the config seed without losing units. This is a crash-to-success
  tolerance fix, not another refusal. (#989)
- **`push` and `sync` can no longer disagree about an exhausted pair.** The
  server reports a pair whose AI retry budget is spent in both commands'
  responses, deliberately outside `pending` (the fill will never retry it on
  its own), and `push` read only `pending` — so it printed "Everything is
  already translated.", exited 0, and published the pair as source text,
  under the very flag whose job is to refuse that. `sync` refused correctly.
  Both commands now share one decision: under `--require-complete` the run
  fails listing every `key [lang]` before anything is published; without the
  flag every push surface — the real push, the zero-estimate path, and
  `--dry-run` — names the pairs on stderr instead of counting them as
  translated, and the completion claim is never printed over them. Retry the
  pairs from the dashboard; a source edit or a model change also re-arms the
  fill. (#752)
- **An empty `push --publish --require-complete` now fails before any request.**
  With no extracted units, `push` has no pending/exhausted snapshot and cannot
  prove that the remote catalog is complete; it previously published that
  state and returned 0. Code-first projects are told to check `--source-dir`.
  Mode A recommends `sync --require-complete` only for a non-empty, supported
  single-file `catalog:`; canonical gen_l10n/ARB configs instead name the
  dashboard because `sync` cannot evaluate them. Removing the flag preserves
  deliberate publication of the current remote state. (#952)
- **`pull` now reports every replacement of your catalog's local source text,
  with the text it discarded.** A pull run between an Xcode edit of the base
  language and the next `sync` used to revert that edit silently — in an
  identifier-keyed catalog (`InfoPlist.xcstrings`, #612) the English is prose
  the developer wrote, so the loss was authorship, not a derived render. The
  pull still applies the served value (exempting the base language is refuted
  in the issue: it breaks converted printf values, base plural forms, and the
  empty shells Xcode creates), but each pair is named on stderr as
  `Conflict: <key> [<lang>]` with one line per discarded form, so the text
  survives in the log and in the pull action's PR diff. Remedy: re-apply the
  edit in the dashboard, or in the file followed by `easyi18n sync`.
  `pull --dry-run` prints the same rows in the conditional, before anything is
  written. `sync`'s own write-back stays quiet — the server already reports
  that pair on the conflicts channel. (#646)
- **`sync` now tells the server when this catalog was pulled, and
  `--on-conflict` decides who wins.** With a dated pull the server can see that
  the project's text changed *after* your file was written, and reports the row
  instead of letting the upload bury it. The new option chooses the outcome:
  `server` (the default, and what every earlier version did) keeps the
  project's text and names the row; `file` imports the catalog's over it —
  **including over a source correction made in the dashboard**, which is the
  one case worth reading twice before switching. The claim is only sent when
  the recorded pull describes *this* file (`catalog` and `format` both match
  the config), so a config switch cannot arm the guard with a timestamp that
  dates another file, and a repo that only ever runs `sync` — the CI flow —
  sends nothing and is served exactly as before. A row on the base language is
  about the key's **source**, and every line that describes one now says so
  rather than calling it a translation; under `--no-publish` those rows are
  counted apart instead of folded into "N kept value(s)". A `pulledAt` in
  `.easyi18n/state.json` written without a zone is dropped rather than guessed
  — reading it as process-local time moves the instant west of UTC and would
  silently revert an in-app source edit made inside that window. Known
  residual: `pull --version <old>` dates the state with now (#898). (#671)
- **A malformed served entry no longer crashes the xcstrings merge.** If the
  server delivered a key whose value was a bare string instead of an object,
  `pull` and `sync`'s write-back died on a `TypeError` mid-merge (present since
  0.8.1) and the catalog was left unwritten. Such an entry is now skipped and
  the local entry is kept verbatim, under both key policies — there are no
  translations inside a scalar to apply, and a payload the CLI cannot read is
  never a reason to overwrite the developer's file. (#966)
- **`sync` states which languages it is about to translate, before the credit
  estimate.** The estimate has always covered the project's configured,
  non-manual languages and nothing else; it just never said which those were,
  so there was no moment at which the number could be checked against the
  intent. `Target languages (N): …` now precedes it (#592).
- **The two ways your catalog and your project can disagree are named, with
  the remedy.** A language the project configures that your catalog has no
  entry for is translated from scratch and paid for — and when your catalog
  spells the same language differently (project `cs-cz`, file `cs`), both
  spellings are named and neither is changed for you: which one is meant is
  yours to decide. A locale your catalog carries that the project does not
  configure is reported too; it was always ignored, it just said so nowhere.
  One grouped line per kind, never one per locale — and never the same locale
  twice across the two moments.
- **After the pull, `sync` reads the catalog it just wrote and warns by name
  for any configured language missing from it**, and for any locale in it that
  the project configures nowhere. This is the check that could not be fooled:
  a language with nothing to deliver produces no entry at all, and the pull
  merges into your file rather than replacing it, so a locale you already had
  survives untouched and used to read as one we produced. `manual`-fill
  languages are excluded — nothing was going to translate them, so naming
  them would contradict the line above that just excused them. A catalog whose
  every entry is `shouldTranslate: false` is excluded too: no fill will ever
  put a locale in one, so "re-run the sync" would be advice that can never
  work. Warnings only; `--require-complete` is still the flag that makes CI
  red.
- A backend that does not say what the project is configured for gets none of
  this rather than a guess. An empty target list is not that case — it is a
  project whose only language is its base, and it still hears about the
  locales its catalog carries that nobody configured.
- **A grouped parse-diagnostic line no longer speaks for a row it does not
  describe.** One code can print several lines — one per message shape — and
  past a cap of five shapes the extra rows folded into the LAST line printed,
  taking that line's wording with them. Since the server now emits two
  different consequences under `DUPLICATE_PLURAL_FORM` (#878), a sixth shape
  could tell an operator that a value was truncated when it was in fact stored
  intact. Rows past the cap now get their own line, which quotes no row's
  message and names the keys it covers up to the same cap every other line
  uses, counting the rest. That line says how many rows it stands for and
  nothing else about them, and the count a line prints is now the rows on
  **that line** — it used to be labelled "for this code in total" while
  counting one message shape. Output-only; no run changes result.

## 0.10.0

**Behaviour changes — read before upgrading a CI job.** Five of the fixes below
change what a run that passes today does. `sync` now keeps a newer server-side
translation instead of overwriting it with the file's (`--on-conflict file`
restores the old default, #550), and it fails where it used to exit 0: a key
lost to a concurrent sync (#564), a fill that stopped short (#602), and pairs
already held by another fill under `--require-complete` (#591). An output
format the project has not enabled is now caught before the run spends anything
rather than after (#530). Hence the minor bump — a `^0.9.0` constraint will not
pick this up on its own.

- **A busy backend no longer kills the run on the first try.** Firestore's
  write-bandwidth throttle is quota-wide — it is a property of the database,
  shared by every client of it, not of your catalog — and a large first-time
  sync is exactly the run that meets it. It used to arrive as an opaque
  `500` and end the job, with the project half-applied; the server now reports
  it per entry, so the keys that landed keep their work and `sync` retries just
  those entries with exponential backoff and jitter instead of re-posting
  instantly. A run that meets the throttle leaves the translation for that
  retry rather than queuing one it might not be able to take back. GET
  requests
  (the fill poll, the pull) replay a transient failure as well — the poll runs
  after the credits were spent, so dying there used to lose a paid job, and the
  cost preview retries too — losing a whole run to a busy moment before a
  single write had been attempted was the cheapest failure to avoid. What is
  never repeated automatically is a request that may have changed something:
  with no answer from the server, "it failed" and "it is still being applied"
  are indistinguishable, and a run that failed after reserving credits can
  still be holding them — an automatic retry would then report a balance
  problem you do not have. In that case the run says the service was busy and
  re-running picks up exactly what is left. (#591)

- **A run whose pairs are held by another fill no longer passes for complete.**
  When every pair the catalog needs is already marked as being filled, the
  server has nothing to queue and accepts instantly with no tracking token —
  so the wait loop never started, `--require-complete` passed, and the publish
  minted a version without those cells. The response now reports how many
  pairs it skipped for that reason; `sync` warns on every run and refuses to
  publish under `--require-complete`. (#591)

- **A translation the markup gate refused is now named in the output.** The
  publish response carries two rejection lists and the CLI read one: a
  markdown or html translation that lost the source's structure (a dropped
  `**` span, a mangled `<a>`) was refused at publish and reported in
  `markupRejected`, which nothing printed. `push` showed a successful publish
  and `sync` a clean run, while the string you wrote never reached users —
  under `push` the base language shipped in its place, under `sync` the locale
  simply had no value for that key. Both commands now print the markup
  rejections under their own heading, next to the ICU ones: same consequence,
  different fix. Neither list changes the exit code — a version that is
  missing some cells is still a version, and `--require-complete` governs
  untranslated pairs, not a gate refusal. Both counts are now the server's
  own: the arrays are capped at 50, so the CLI reported "50" on exactly the
  publishes with the most damage. (#609)

- **`sync` checks the output format before it spends anything.** A project
  that has not enabled the format in `format:` still translated, charged and
  published, and only then failed on the pull with `format "xcstrings" not
  configured for this project` — credits gone, a version cut, and no catalog
  written. The format is now checked against the project's configuration up
  front, so the run stops before the first upload and says what to enable.
  `--max-credits` answered "is this run too expensive?" but never "can this
  run deliver anything at all?". Skipped by `--no-publish`, which never pulls.
  (#530)

- **`sync` no longer reverts a translation the project produced after your
  catalog was pulled.** The per-string decision was "the file differs, so the
  file wins", and a dashboard edit, an AI fill or a reviewer's sign-off made
  between your last pull and your next sync went back to the file's older
  text — counted as "imported", with nothing in the log. It is now kept on
  the server and reported, one warning per `key [lang]` naming who wrote it
  and when (also under `--dry-run`); the pull at the end of the run brings
  the kept value into your catalog, so the PR diff is where you review it
  (under `--no-publish` that pull is skipped and the CLI says so — the kept
  value stays server-side and the conflict reports again on the next run).
  Pass `--on-conflict file` to make the catalog win anyway — the pair is
  still reported, including the human sign-off it wipes. A value that came
  from a file in the first place is still yours to change from the file,
  silently, as before. Conflicts are reported off every request, not just the
  cost preview, so one that only appears once the run starts is named too, and
  the summary counts the server's total rather than the rows it listed. (#550)

- **`push` now tells you when a string was skipped because its key is switched
  off.** A key switched off in the app is excluded from published output, so
  the backend never translates it — but the push looked clean while those
  strings silently stayed untranslated. It now warns, and says what to do
  (re-enable the key). Unlike the source-verification gate this is not a
  deferral: nothing will translate them until someone switches the key back
  on. The same push also stopped being billed for those keys. (#563)

- **`sync` no longer exits 0 after losing a key to a concurrent sync.** When
  two CI jobs sync at the same time, the one that loses a key's create gets
  that entry back as `contended` instead of a 500. `sync` now re-POSTs the
  catalog (up to twice) so the entry lands on the key the other run created,
  and fails the run if it is still unwritten — the two jobs may carry
  different catalogs, in which case the peer's write is not yours and a green
  job would drop this branch's strings until someone pushed again. (#564)

- **`sync` now reports the strings your code no longer references.** A String
  Catalog carries Xcode's own verdict per phrase (`extractionState: "stale"`
  — its compiler pass over your sources could not find the string), and
  nothing read it, so there was no way to see which of your keys were
  leftovers from a reworked screen. The summary now ends with `N no longer in
  your code`, and the dashboard flags those keys with a "Not in code" badge
  and a filter to review them in bulk. It is a **signal, not an action**:
  nothing is disabled or deleted, and nothing stops publishing, because
  `stale` is a conjecture — a string reached through a computed key is marked
  stale while still on screen, so the call is yours. (#558)

## 0.9.0

- **`pull` now writes to the `catalog:` you configured.** It resolved its
  destination from `output:` alone, so a project whose catalog lives at
  `EscapeCall/Localizable.xcstrings` got a stray `lib/l10n/` tree instead —
  in an Xcode project with no `lib/` at all — while the run reported success
  and recorded the wrong path as fact. `catalog:` names one file and now
  decides where `pull` writes it; `output:` stays what it always was, the
  directory for formats that render one file per locale.
- **`pull` merges into a String Catalog instead of replacing it.** A
  `.xcstrings` is written by two tools, and only one of them is us: Xcode
  owns the file's structure, key order, per-key metadata
  (`extractionState`, `isCommentAutoGenerated`) and every key added since the
  last publish. Overwriting it deleted them, and only an Xcode rebuild
  brought them back. The pull now injects the served translations into the
  local file and re-prints it in Xcode's exact style — the same merge `sync`
  has done since 0.8.1, with one difference: a key that exists only on the
  server is *added* here, since a pull is the only way a key created in the
  dashboard reaches your file. A pull that changes no translations is now a
  byte-exact no-op, including the first one on a fresh checkout. The trade is
  that a pull no longer removes anything: a key deleted from the project stays
  in your catalog until Xcode's own extraction pass drops it, which is the
  right owner for that decision but worth knowing.
- **Unknown settings in `easyi18n.yaml` are reported.** `ouput:` used to be
  read past in silence, leaving the run on a default. It is now a warning
  naming the key and listing the ones the CLI reads — a warning and not an
  error, so a config written for a newer CLI keeps working on a pinned one.
- **`catalog:` is refused with a per-locale format.** It names one file holding
  every language, so pairing it with a format that renders one file per locale
  is a contradiction — and a silent one when the project has a single language,
  because then exactly one file is served and that locale's render would land
  inside the catalog reporting success. The run now stops before the request,
  naming both settings.
- **`--lang` is refused with `format: xcstrings`.** A String Catalog holds
  every language in one file, and a single-locale render drops the base
  values its keys are addressed by — it would have merged nothing while
  reporting success.
- `easyi18n status` now sees a catalog pull (it recorded nothing before).

- **`push` now checks `--lang` against the project before spending a request.**
  The server does not reject an unknown code — it intersects the list with
  the project's targets, so a typo is dropped silently and the run reports
  success having translated nothing for it. That silence is what this
  catches: an unknown code now fails locally with the configured targets
  listed. Naming only the base language fails too (the base is never a fill
  target, so the server answers `no_target_langs`), and a language set to
  manual translation is refused when named explicitly — the server's one
  real rejection here — or reported when it is merely part of the default
  set. Codes are matched the way the backend stores them, so `pt_BR` and
  `pt-br` are the same language.
- **`push --publish` says what will happen to strings that are still
  untranslated**, instead of describing both outcomes and committing to
  neither: `/meta` now carries the project's integration mode.
- **`push --publish` warns when the local `mode:` and the dashboard's project
  mode disagree.** They are set independently and never synced, and until now
  nothing could see both halves at once.
- All three degrade quietly: `push` needs the `translate` scope and `/meta`
  needs `read`, so a narrower key keeps working exactly as before.

- **`push --publish` on a Mode A config (`mode: a`) now publishes with
  `incompleteMode: skip` explicitly.** Baking source text into the pulled
  files marks untranslated keys as done forever — a TMS workflow's own
  untranslated report is the signal that matters. Other configs keep omitting
  the field; the server now resolves an omitted value from the project's
  declared integration mode (skip for TMS, source otherwise).

## 0.8.1

- **`sync` now merges translations into your catalog instead of replacing
  it.** Opening a catalog in Xcode rewrites the file — its own `" : "`
  spacing, a localized key ordering, entries re-synced from code, and
  `extractionState` metadata. Replacing the file with the server's rendering
  reverted all of that, so Xcode and the sync PR would reformat each other's
  work forever. The local file now owns structure, order and metadata; the
  sync only injects the translated `localizations` per key, serialized in
  Xcode's exact style (pinned byte-for-byte by a golden captured from a real
  Xcode save). A converged catalog round-trips byte-identical.

## 0.8.0

- **New `easyi18n sync` — continuous i18n for file-first projects** (iOS
  String Catalogs first). Point `catalog:` in `easyi18n.yaml` at your
  `Localizable.xcstrings` and one command does the whole loop: upload the
  catalog, translate only what changed (translations the file already carries
  are imported verbatim, never re-charged), publish, and write the translated
  catalog back onto the same path. Built for CI: `--yes`, `--dry-run`,
  `--max-credits`, `--no-publish`, `--require-complete`. Re-running on an
  unchanged catalog is a byte-exact no-op, so a workflow can run it on every
  push and only open a PR when git sees a diff. Keys removed from the catalog
  are disabled server-side (and re-enabled if the phrase returns) — nothing is
  ever deleted. Pairs whose AI retry budget is spent are reported separately
  with a dashboard pointer instead of spinning the retry loop.
- `publish` (used by push and sync) understands the backend's new
  `skipIfIdentical` answer: identical content returns the current version as
  `unchanged` instead of minting a new one.
- The `Run 'flutter gen-l10n'` hint after a pull now only prints for `arb`
  pulls — it made no sense after pulling an `.xcstrings` or `.po`.

## 0.7.1

- **Installable in a Flutter project again.** The `analyzer` floor was
  `^13.3.0`, but analyzer `>=13.1.0` requires `meta ^1.18.3` while the Flutter
  SDK pins `meta 1.18.0` — so `dart pub add dev:easyi18n_cli`, the documented
  install path, failed version solving in every Flutter app. The floor is now
  `>=13.0.0 <14.0.0`; nothing in the CLI used an API newer than 13.0.0. This hit
  Mode A users hardest: they only run `pull`, and the analyzer is used solely by
  `push`/`apply`. Global activation (`dart pub global activate easyi18n_cli`)
  was, and remains, unaffected.

## 0.7.0

- **`push --publish` is no longer all-or-nothing.** A string whose AI fill
  failed (e.g. a transient backend error dropped its chunk) used to abort the
  whole publish, holding every completed translation hostage. The CLI now
  re-queues failed strings up to 2 times (a failed fill releases its hold, so
  the retry only charges work that was never paid for) and, if stragglers
  remain after the retries or the 10-minute wait, publishes anyway with a
  warning — the missing cells serve the source text until a later
  `push --publish` fills them. Pass the new `--require-complete` flag to
  restore the previous fail-instead-of-publishing behaviour.

## 0.6.0

- **Fix `--max-credits` units.** The API reports estimates and balances in
  millicredits (1 credit = 1000 mc), and `easyi18n push` compared the raw mc
  value against `--max-credits` — so a documented-as-credits ceiling was
  enforced 1000× too strictly (`--max-credits 500` really meant 0.5 credits).
  The flag is now read in credits (decimals allowed, e.g. `--max-credits 0.5`)
  and converted at the edge. Cost previews, confirmation prompts, and abort
  messages now print credits (`~107.3 credit(s)`) instead of raw millicredits.
  If you were compensating by passing mc-scale ceilings, divide them by 1000.

## 0.5.0

- `easyi18n pull` now records what it writes (`.easyi18n/state.json`) and, on
  the next full pull of the same format and output dir, removes recorded files
  the server no longer serves — e.g. a locale renamed to its platform-canonical
  filename (`app_zh-hant.arb` → `app_zh_Hant.arb`), sweeping stranded `.tmp`
  files and emptied dirs along. A `--lang` pull never prunes; a `format:` or
  `output:` switch lists the old target's stranded files instead of deleting
  across targets; `--dry-run` previews removals. The first pull that records
  its list warns about files it cannot attribute instead of deleting them.

## 0.4.0

- `easyi18n push --publish`: after the push, waits for the AI fill to
  complete (polling the dry-run estimate) and publishes a new version via
  the public publish endpoint — no dashboard needed. `--approved-only`
  treats unapproved translations as missing when publishing. Needs an API
  key with the `publish` scope.
- New `easyi18n rollback [version]`: restores a prior published version as
  a NEW version (history is never rewritten). With no argument it restores
  the version just before the current one.

- New `easyi18n doctor`: read-only health check of the whole integration.
  Verifies the local wiring (config, `easyi18n` dependency, `assets/easyi18n/`
  floor, `com.apple.security.network.client` in both macOS entitlements,
  `Easyi18nScope` mounted), lints your `tr()` source strings as ICU (malformed
  ICU renders raw to users), and **actively probes delivery** — manifest
  reachable, CORS served, then your tr() scan graded against the published
  bundles: missing (never pushed/published), untranslated per locale, and
  unused keys. Bundles are integrity-checked against their content address
  (a stale CDN object fails doctor the same way the runtime rejects it), a
  200 that isn't a manifest is a failure (SPA catch-all / captive portal),
  and a CORS header locked to one origin is surfaced instead of passing as
  "present". Exit 1 on blocking problems; warnings don't block.
- `push` / `extract`: a `tr()` call whose `ctx:` is not a string literal is
  now reported as dynamic instead of being registered as the (wrong) no-ctx
  unit.

## 0.3.0

- `easyi18n init` is now one-command project setup: besides `easyi18n.yaml`
  it adds the `easyi18n:` dependency and the `assets/easyi18n/` offline floor
  to `pubspec.yaml` (creating the dir), ignores the derived `.easyi18n/` state
  in `.gitignore`, grants `com.apple.security.network.client` in BOTH macOS
  `.entitlements` (delivery fetches fail silently in the sandbox without it),
  and wires `Easyi18nScope` around a trivial `runApp(...)` (printed as a
  snippet when `main.dart` is not trivially patchable). Idempotent; new
  `--dry-run` flag reports without writing. An existing `easyi18n.yaml` is now
  kept (re-run friendly) instead of an error — `--force` still rewrites it.

## 0.2.0

- `easyi18n push`: statically extracts `tr()` source strings from your source
  tree (canonical `context.tr('…')` and the `'…'.tr()` sugar), diffs them
  against a committed `easyi18n.lock`, previews the credit cost, and registers +
  translates them via the backend. Flags: `--dry-run`, `--yes`, `--max-credits`,
  `--prune`, `--lang`, `--source-dir`.
- `easyi18n extract`: the same scan, offline and read-only: reports extractable
  strings, new/orphaned vs the lockfile, and dynamic (non-literal) calls.
  `--fail-on-orphans` for CI drift checks.

## 0.1.0

- Initial CLI (`easyi18n`) for Mode A (native `.arb`).
- `easyi18n init` writes an `easyi18n.yaml` config.
- `easyi18n pull` downloads translated files from the authenticated backend
  (`GET /v1/projects/{id}/translations`) and writes them to disk so you can run
  `flutter gen-l10n`. Supports `--version`, `--lang`, and `--dry-run`.
