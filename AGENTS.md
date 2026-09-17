# AGENTS.md — ada (Agent Done Alert)

A maximized-window alert that pops when a long terminal command / Claude Code
or Codex turn / opencode turn / Paseo agent turn finishes. The alert is an HTML
page (`alert.html`) rendered only by the native SwiftPM helper `ada-alert`.
Entry points all reach the shared launcher `ada-show-alert.sh`: `ada.sh` (zsh
hook), `ada-claude-hook.sh` (shared Claude Code / Codex hook),
`ada-opencode-plugin.mjs` (an opencode plugin; see
[opencode is a plugin](#opencode-is-a-plugin-not-a-hook)), and
`ada-paseo-watch.sh` -> `ada-paseo-watch.py` (a launchd watcher that polls the
Paseo daemon; see [The Paseo watcher](#the-paseo-watcher-launchd-cant-run-from-tcc-protected-paths)).

Everything except `ada.sh` goes through `lib/ada-notify.sh` first, which owns
frontmost-app suppression and duration formatting. There are three
implementations of that suppression check (this bash one, the zsh one inside
`ada.sh` because it is sourced into your interactive shell, and the python one
in `ada-paseo-watch.py` because a LaunchAgent can't source zsh). **Do not add a
fourth** — a new integration sources or execs `ada-notify.sh`.

Docs of record are `README.md` for user-facing behavior, `REQUIREMENTS.md` for
durable product/integration requirements, and this file plus `CLAUDE.md` for
maintainer-agent guidance. Update `REQUIREMENTS.md` whenever a requirement
changes, even if the implementation diff is small.

## Onboarding installer

`ada-install.sh` is the coworker-facing onboarding entry point. It presents a
terminal selector for the integrations that should trigger ADA: Terminal
commands, Claude Code, Codex, and Paseo. Keep it idempotent: shell setup uses a
managed block in `~/.zshrc`; Claude/Codex setup must merge JSON hooks without
removing unrelated hooks; Paseo setup must delegate to `ada-paseo-watch.sh
install` so LaunchAgent staging stays centralized. The installer must build or
validate `ada-alert` because there is no browser fallback. Preserve the
scriptable `--agents`, `--list`, `--dry-run`, and `--no-test` paths because
those are the scriptable surface that Homebrew's `ada-setup` wrapper and future
curl automation build on.

## Homebrew distribution: the repo is its own tap

`ada` ships through Homebrew and **the repo doubles as its own tap** — the
formula lives at `Formula/ada.rb` at the repo root, so `brew tap janacm/ada
https://github.com/janacm/ada && brew install ada` works with no separate
`homebrew-ada` repo. The explicit tap URL is **required** because the repo isn't
named `homebrew-ada`. A self-tap reads the formula from the **tip of the default
branch**, so the released `url`/`sha256` must be committed to `main` — nothing
reads the formula from inside the tagged tarball.

The formula builds `ada-alert`/`ada-menubar` with SwiftPM, installs the repo
tree intact into `libexec` (so every script's relative-path resolution keeps
working — `ada.sh` -> `lib/ada-show-alert.sh` -> `../ada-alert`), and drops the
built helper where `__ada_find_native_alert` looks first so it never rebuilds
into the read-only Cellar. It exposes `ada-setup` (a thin wrapper around
`ada-install.sh`) and points users at it via caveats; `brew install` itself
never touches dotfiles.

**Never bake a Cellar path into anything durable.** `#{libexec}` is
`<prefix>/Cellar/ada/<version>/libexec`, which the next `brew upgrade` deletes —
and `ada-install.sh` writes its own directory into the user's `~/.zshrc`, the
Claude/Codex hook commands, and the Paseo plist. So the `ada-setup` wrapper execs
`#{opt_libexec}` (`<prefix>/opt/ada/libexec`, a version-stable symlink), and both
`ada-install.sh` and `ada-paseo-watch.sh` additionally map a Cellar path back to
its `opt` equivalent (`__ada_stable_dir`) in case they're invoked directly. `ada.sh`
uses zsh `:a` (absolutize) rather than `:A` (realpath) for the same reason —
`:A` would resolve the opt symlink straight back into the versioned Cellar dir.

**Nothing may default to `~/.ada`.** That path only exists for a from-source
install; a Homebrew install has no such directory. `alert.html` is therefore
resolved relative to the running script (`ada.sh` -> `$_ADA_DIR/alert.html`,
`lib/ada-show-alert.sh` -> `$selfdir/../alert.html`), with `~/.ada` kept only as
a last-resort fallback. Getting this wrong is invisible on a dev machine — the
symlink masks it — and renders a **blank alert window** for every Homebrew user,
because the `file://` target simply doesn't exist.

**Releasing:** `./release.sh vX.Y.Z` does the whole thing — refuses to run on a
dirty tree, off `main`, or with `main` unpushed; tags and pushes; computes the
tarball `sha256`; rewrites `url`/`sha256` in `Formula/ada.rb`; commits and pushes
that bump to `main`. There's an inherent chicken-and-egg — a tag's own tarball
can't contain its own sha256 — so the authoritative formula is always that
follow-up commit on `main`. `--no-formula` prints the fields instead of
committing; `--no-push` tags locally only. Validate with `brew style
Formula/ada.rb`, then `brew install` / `brew test janacm/ada/ada`.

## Native helper is the only renderer

`ada-alert` is a SwiftPM executable that opens `alert.html` in an AppKit/WebKit
window sized to the primary display's `visibleFrame`. The launcher looks for
`ADA_NATIVE_ALERT`, then `ada-alert`, `.build/release/ada-alert`, and
`.build/debug/ada-alert` beside `ada-show-alert.sh`.

There is intentionally **no browser fallback**. If the native helper is missing
or not executable, `ada-show-alert.sh` exits with an error rather than opening
Chrome, Brave, Edge, Safari, or any other browser. Do not reintroduce browser
fallbacks when working on alert rendering.

## opencode is a plugin, not a hook

opencode exposes **no** "run a command on agent event" hook config, so there is
no `~/.config/opencode/hooks.json` analogue to Claude Code's settings. What it
has is a server-side **plugin** API: a module whose named exports are async
factories returning a hooks object. `lib/ada-opencode-plugin.mjs` is that
plugin, and `ada-install.sh` installs it as a one-line shim
(`export * from "<install dir>/lib/ada-opencode-plugin.mjs"`) at
`<config>/plugin/ada.js`.

**Facts verified against opencode 1.18.30 on this machine** (not from docs):

- **The plugin-directory scanner only picks up `.js`.** A plain `.mjs` dropped
  in `~/.config/opencode/plugin/` is silently ignored — no error, no load. A
  `.js` file loads, and so does a `.js` **symlink**. That is why the drop-in is
  `.js` while the plugin it re-exports is `.mjs` (an explicit import bypasses
  the extension filter, and the extension makes the ESM-ness unambiguous).
- **Why a shim and not a symlink.** A symlink resolves to its realpath, and
  under Homebrew `<prefix>/opt/ada/libexec` realpaths straight into
  `<prefix>/Cellar/ada/<version>/libexec` — the same `:A`-vs-`:a` trap
  documented below for `ada.sh`. The shim keeps the version-stable `opt` path.
- **Plugins load lazily, at the first session — not at server boot.** Starting
  `opencode serve` and grepping the log proves nothing; you have to create a
  session (`curl -X POST localhost:<port>/session -d '{}'`) before the plugin
  is even imported.
- **Event order for a turn:** `chat.message` (hook, carries the prompt parts)
  -> `session.status busy` (repeatedly) -> `session.error` (only on failure)
  -> `session.status idle` -> `session.idle`. `session.idle` fires **once**, at
  the end of the whole turn, *after* the last tool call — confirmed with a
  bash-tool turn, not just a trivial one. `session.error` lands ~1ms before
  `session.idle`, which is why the plugin stashes the error on the turn and lets
  the idle handler render it: one alert per failed turn, not two.
- **The bundled SDK types lie about permissions.** `@opencode-ai/sdk` 1.18.20
  (what `~/.config/opencode/node_modules` had) declares
  `permission.updated` with `{permissionID, response}`; the 1.18.30 binary emits
  **`permission.asked`** with `{id, sessionID, permission, patterns, metadata,
  always, tool}` and `permission.replied` with `{requestID, reply}`. The plugin
  accepts both spellings and reads fields defensively. Re-derive with the probe
  recipe below rather than trusting `types.gen.d.ts`.
- **The `permission.ask` *hook* did not fire at all** in 1.18.30, even with a
  permission genuinely pending. Use the event.
- **`__CFBundleIdentifier` and `TERM_PROGRAM` are inherited** by the plugin
  process from the terminal hosting opencode. So frontmost-app suppression and
  click-to-focus work with no extra plumbing: the click target is already the
  right terminal app.

Two implementation constraints that are easy to get wrong:

- **The spawn must be detached** (`detached: true`, `stdio: "ignore"`,
  `unref()`): `opencode run` exits moments after `session.idle`, and a
  non-detached alert would die with it.
- **The child needs an `error` listener.** A missing `ada-notify.sh` surfaces as
  an asynchronous `error` event on the child, and an unhandled `error` event
  throws — inside opencode's own process. Every failure path here must degrade
  to "no alert", never to a broken session.

The **error policy** lives in `errorLabel()` in the plugin, and two of its calls
are deliberate rather than obvious:

- `MessageAbortedError` returns `null`, and an ignored error marks the turn
  `silenced` so the *finish* alert is dropped too. Otherwise pressing `Esc` on a
  ten-minute turn would pop a "turn finished" window a second later.
- `data.isRetryable` does **not** silence an `APIError`. opencode's own retries
  are announced as `session.status retry` and happen before this point; an error
  that reaches `session.error` is immediately followed by `session.idle`, so the
  turn is over regardless. Filtering on `isRetryable` would drop real failures.

`MessageOutputLengthError` is the only variant with no `data.message` at all, so
a plain `data.message || name` fallback surfaces the bare class name to the user.

Three review findings worth not re-introducing:

- **`session.error` may carry no `error` object at all** (the SDK marks it
  optional). Treating an undescribable error like an abort silences the turn, so
  an empty error event swallowed the finish alert for a turn that had genuinely
  run for ten minutes. Only `MessageAbortedError` silences; anything else either
  alerts or leaves the turn alone.
- **The abort check runs before the `ADA_OPENCODE_EVENTS` gate.** With
  `ADA_OPENCODE_EVENTS="finish permission"`, an early `return` on the events gate
  skipped the silencing and the following `session.idle` fired a cheerful finish
  alert for a turn the user had just cancelled with Esc.
- **`ada-notify.sh` must not `exec`.** Its own header invites sourcing, and the
  Claude hook only survived an `exec` because it happens to background the call;
  any foreground caller would have had its process replaced mid-script.

### Probing opencode's events

To re-derive the event surface after an opencode upgrade, drop a probe plugin in
the project you are testing (`<project>/.opencode/plugin/probe.js`) and log
every event:

```js
import fs from "node:fs"
export const Probe = async () => ({
  event: async ({ event }) =>
    fs.appendFileSync("/tmp/oc-probe.log", `${event.type} ${JSON.stringify(event.properties).slice(0, 300)}\n`),
})
```

Then run a real turn: `opencode run --model anthropic/claude-haiku-4-5 "say ok"`.
Do **not** filter the event types while probing — that is how the
`permission.asked` rename hid for a whole round of testing.

**Reproducing a pending permission is the awkward one.** In non-interactive
`opencode run`, a permission is **auto-rejected** (`permission.replied` with
`reply: "reject"`) and no ask event ever fires, because there is no UI to ask.
To get the interactive path without driving the TUI: put
`{"permission": {"bash": "ask"}}` in the project's `opencode.json`, start
`opencode serve --port N`, create a session over HTTP, POST a message that needs
bash, and leave the server with no attached client — it blocks exactly where a
real client would prompt.

### Testing the plugin

`test/ada-opencode-plugin.bats` replays JSON programs against the real plugin
through `test/opencode_plugin_drive.mjs`, and lets it call the real
`ada-notify.sh` and `ada-show-alert.sh` with only the native helper stubbed. So
a failure means the chain opencode actually uses is broken. The driver shifts
`Date.now` for the `chat.message` call instead of sleeping, which is what makes
the threshold-boundary tests exact.

Note `test/stubs/opencode` shadows the real CLI for the whole suite, so the
installer tests exercise the `opencode debug paths` parsing without touching a
developer's real `~/.config/opencode`.

## The Paseo watcher: launchd can't run from TCC-protected paths

Paseo runs every agent (`opencode`, `claude`, `codex`, …) through **its own
daemon runtime, not the provider CLIs**, so provider-level hooks never fire for a
Paseo-managed agent — not even a `claude/*` or `codex/*` one — and Paseo exposes
no "run a command on agent event" hook. So instead of a hook, `ada-paseo-watch.py`
**polls** the daemon via the supported CLI and synthesizes the event by diffing
status between snapshots:

- `paseo ls --json` — `running → idle` = finished turn; `running → error` =
  failed turn.
- `paseo permit ls --json` — a new entry = an agent blocked on a permission.

The loop is **Python, not bash**, because it needs per-agent state keyed by id
(associative arrays) and macOS still ships **bash 3.2**, which has none. The
`.sh` is just the front door (config, launchd, `test`). It skips alerts while the
Paseo app (bundle id `sh.paseo.desktop`) is frontmost — you're already watching.

**The gotcha:** a **LaunchAgent runs without your Full Disk Access**, so it
**cannot exec a script under a TCC-protected folder** — `~/Documents`,
`~/Desktop`, `~/Downloads`, *or a symlink into one*. Note **`~/.ada` is a symlink
to `~/Documents/GitHub/ada`**, so pointing the plist at `~/.ada/ada-paseo-watch.sh`
fails. Symptom: the job log shows `/bin/bash: <path>: Operation not permitted`
and `last exit code = 126`, **even though the exact same script runs fine from
your terminal** (Terminal/ghostty/etc. have been granted TCC access; launchd has
not). This asymmetry is the tell.

**The fix (current design):** it depends on where you're running from.
`ada-paseo-watch.sh install` checks whether it lives under `$(brew --prefix)/opt`
(`__ada_from_brew_prefix`). A **Homebrew install runs in place** — that path is
outside every TCC root *and* version-stable, so the plist points straight at
`<prefix>/opt/ada/libexec/ada-paseo-watch.sh` and `brew upgrade` refreshes the
watcher with no re-install. Staging a Homebrew install would do the opposite:
freeze a snapshot brew could never update.

Everything else (a dev checkout, `~/.ada`) **stages** the runtime it needs
(`ada-paseo-watch.sh`, `ada-paseo-watch.py`, `ada-show-alert.sh`,
`ada-snooze-daemon.py`, `alert.html`, and `ada-alert`) into a non-TCC dir —
`~/.local/share/ada` (override `ADA_PASEO_INSTALL_DIR`) — and points the plist
there. **Staging mirrors the dev-checkout layout**: the front door
(`ada-paseo-watch.sh`), `alert.html`, and `ada-alert` sit at the top, while the
internal scripts (`ada-paseo-watch.py`, `ada-show-alert.sh`,
`ada-snooze-daemon.py`) go under `~/.local/share/ada/lib/`. Keeping the two
layouts identical is load-bearing: the watcher resolves `ada-show-alert.sh` via
`$dir/lib/…` / a sibling of the `.py`, so a flat stage would break every Paseo
alert from the LaunchAgent while still working in a dev checkout (the classic
masking failure). The installer builds `ada-alert` with SwiftPM when needed and
fails if it cannot stage the helper. Re-run `install` after editing any of those
scripts or rebuilding the helper to re-stage (`status` prints both `runtime:` and,
when they differ, `source:` — that mismatch is how you spot a stale stage). The
env file lives at `~/.local/share/ada/paseo-watch.env` in **both** modes: the
plist sets `ADA_PASEO_ENV` explicitly so config survives a `brew upgrade`, which
replaces `libexec` wholesale.

**Debugging:**
```bash
launchctl print gui/$(id -u)/com.ada.paseo-watch | grep -iE 'state =|pid =|last exit'
tail -f "$TMPDIR/ada-paseo-watch.log"     # clean = running fine; the loop is silent
pgrep -fl ada-paseo-watch.py              # shows the staged ~/.local/share/ada path
```
A healthy job is `state = running` with a live `python …/.local/share/ada/ada-paseo-watch.py`.

`ada-paseo-watch.sh status` now prints an emoji health line:
- `✅ Paseo watcher: running (pid N)` — live poll loop
- `⚠️  loaded but not running yet` — job registered, pid not up
- `❌ not loaded — run: ... install` — off
Plus `✅/❌ plist` and `✅ log clean` / `⚠️ log has output`.

## How to validate windowed-vs-fullscreen

First verify that `swift build --product ada-alert` succeeds and that a test
launch uses `ada-alert`, not Chrome:
```bash
ADA_AUTO_CLOSE=5 ADA_SNOOZE_MINUTES="" ~/.ada/ada-show-alert.sh "validate native" "1s" 0
pgrep -fl ada-alert
pgrep -fl "Google Chrome.*ada"  # should be empty
```

For visual geometry, the discriminator is: a normal macOS window cannot sit
under the menu bar, so the alert covering the menu bar is fullscreen; sitting
below it is windowed.

Ask the user to look: "Run `ada test`: is there a *'press and hold esc to exit
full screen'* banner, and is the menu bar visible?" Banner present / menu bar
hidden = fullscreen. Menu bar visible = windowed.

## Dead-ends — don't waste time here

- **`screencapture` CLI** and **System Events `AXFullScreen`** need permissions
  the terminal usually lacks (Screen Recording / Accessibility) and fail with
  *"could not create image from display"* / *"not allowed assistive access"*.

## Testing the launcher safely

- Run it directly, bypassing the shell hook:
  `ADA_AUTO_CLOSE=20 ADA_SNOOZE_MINUTES="" ~/.ada/ada-show-alert.sh "cmd" "1s" 0`
- `ADA_SNOOZE_MINUTES=""` skips spawning the snooze daemon during tests.
- `ADA_ALERT_FILE=/path/diag.html` swaps in a probe page.
- The shell hook execs `~/.ada/ada-show-alert.sh` **fresh each time**, so edits to
  the launcher take effect on the next alert **without re-sourcing**. Re-sourcing
  `ada.sh` only matters for changes to the hook logic in `ada.sh` itself.
- `~/.ada` is the installed clone the live hooks run from; it's separate from any
  dev checkout. After changing the launcher, `git -C ~/.ada pull` to go live.

## UserPromptSubmit is not only what the user typed

The agent fires `UserPromptSubmit` for messages **it** injects into the
conversation, not just ones you type. Captured live from Claude Code, the
`prompt` field arrives as a raw block:

```
<task-notification> <task-id>brdunbr1u</task-id> <tool-use-id>toolu_01129…</tool-use-id>
<output-file>/private/tmp/…/brdunbr1u.output</output-file> <status>completed</status>
<summary>Background command "Run the full suite" completed (exit code 0)</summary>
</task-notification>
```

Stamping that as "the prompt" produced an alert whose entire label was
`<task-notification><task-id>…`, which tells you nothing. `label_for()` in the
python payload pass recovers the human part: `<summary>` when present (task
notifications, CI events), command name plus arguments for a slash command, and
tag-stripped prose for any other wholly tag-wrapped block.

**The signal is a hyphen in the outer tag name.** `task-notification`,
`system-reminder`, `local-command-stdout`, `ci-monitor-event`, `command-name` —
every injected block uses a hyphenated name, and HTML/JSX element names never
do. That is not luck: the HTML spec reserves the hyphen to distinguish a custom
element from a standard one. A prompt only enters the sanitizer if it opens with
a hyphenated tag *and* ends on a tag, i.e. it is wholly markup.

Three weaker rules were tried and are wrong:

- "starts with `<`" mangles `<div>foo</div> is not centering` into
  `foo is not centering`.
- the same shortcut lets a pasted `<details><summary>build log</summary>…
  </details>` reach the `<summary>` extractor, which replaces the user's actual
  question with `⚙️ build log`. Pasting a collapsed log and then asking about it
  is an ordinary prompt.
- "wholly tag-wrapped" (`^<tag>…</tag>$`) still eats a typed `<div>foo</div>`,
  and it does not even match the slash-command shape, which opens on
  `<command-name>` and closes on `</command-args>`.

**Metadata lives in nested elements, prose does not.** For a block with no
`<summary>`, stripping tags alone leaves the values behind — `<ada-ping><id>7
</id></ada-ping>` became an alert labelled `7`, and a summary-less task
notification would have shown a bare task id. So nested elements are removed
whole, and only text sitting directly inside the outer block survives. Nothing
left means the generic `Claude Code` label.

Known injected shapes so far: `task-notification`, `command-name` /
`command-message` / `command-args`, `local-command-stdout`, `system-reminder`,
`ci-monitor-event`. Treat that list as incomplete — it grows with the harness.

**To capture a new shape**, the opt-in breadcrumb deliberately logs the RAW
prompt, not the label:

```bash
touch "$TMPDIR/ada-claude-debug.on"     # survives an env-stripped hook
# ...trigger the thing, then:
tail "$TMPDIR/ada-claude-debug.log"
cat "$TMPDIR"/ada-claude/*.prompt        # what the alert WOULD show
```

A background task finishing in Claude Code is the easiest reproduction: run
anything with `run_in_background`, and the completion notification opens a new
turn whose prompt is the synthetic block.

## Click-to-open the Claude conversation (deep link)

Clicking a Claude Code alert opens that turn's conversation in the Claude macOS
app. The mechanism reuses the **existing click-to-focus path**: the click signals
the snooze daemon, which `open`s a URL instead of `open -b <bundle>`. The new
plumbing is one env var threaded end to end — `ada-claude-hook.sh` sets
`ADA_CLICK_URL`, `ada-show-alert.sh` enables `focus=1` and passes it to the
daemon, and `ada-snooze-daemon.py` prefers the URL over the bundle id on `focus`.

The URL is **`claude://resume?session=<session_id>`**. `<session_id>` is the
Claude Code `session_id` from the hook payload, which is also the basename of the
transcript at `~/.claude/projects/*/<id>.jsonl`. The app's `open-url` handler
imports that CLI transcript and navigates to it. The hook gates the link on
*UUID-shaped id AND transcript-exists*, so Codex turns (same hook, not
importable) get no link instead of a "couldn't open session" dialog.

This scheme is **undocumented and reverse-engineered** from `Claude.app`'s
minified `app.asar` (`open-url` → `claudeURLHandler`; hosts `resume`, `code`,
`cowork`, …), so it can change across app versions. Keep it best-effort: a dead
link just no-ops. To re-derive or validate it: `npx @electron/asar extract
/Applications/Claude.app/Contents/Resources/app.asar <dir>` then grep the main
`index.js` for `claude://`, `importCliSession`, and the `.Resume=`/`.Code=` enum
values. To confirm a deep link lands live, fire `open "claude://resume?session=
<real-id>"` and watch `~/Library/Logs/Claude/main.log` for
`Resume deep link: importing CLI session <id>` → `Imported CLI session … as
Desktop session local_<id>`.

## The feedback note opens links via the adaOpen bridge

The alert carries a small feedback note in its corner (`#feedbackBox` in
`alert.html`). Its link must open in the user's **default browser**, not navigate
the alert's own WebView away — a plain `<a href>` in this `file://` page would
either be swallowed (no UI delegate) or replace the alert page.

So the link routes through a dedicated native bridge: `alert.html` posts the URL
to `window.webkit.messageHandlers.adaOpen`, and the helper opens it with
`NSWorkspace.shared.open`, restricted to `http`/`https` schemes. This is separate
from the click-to-focus deep-link path above (which signals the snooze daemon to
`open` a URL/bundle on a plain alert click): `adaOpen` opens directly from the
helper, needs no daemon, and fires only for the feedback link — clicks inside the
note are kept off the dismiss handler with `stopPropagation`. The link currently
points at the project's GitHub issues.

## Window geometry

Size = the **primary** display's `visibleFrame` (below the menu bar, above the
Dock), read in the native helper with `NSScreen.main ?? NSScreen.screens.first`.
Do not use Finder's `bounds of window of desktop`, which returns the **union of
all displays** on a multi-monitor setup and would span every monitor.
