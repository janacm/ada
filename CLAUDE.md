# CLAUDE.md — iyf (In Your Face)

A maximized-window alert that pops when a long terminal command / Claude Code
or Codex turn / Paseo agent turn finishes. The alert is an HTML page
(`alert.html`) rendered only by the native SwiftPM helper `iyf-alert`. Entry
points all call the shared launcher `iyf-show-alert.sh`: `iyf.sh` (zsh hook),
`iyf-claude-hook.sh` (shared Claude Code / Codex hook), and
`iyf-paseo-watch.sh` -> `iyf-paseo-watch.py` (a launchd watcher that polls the
Paseo daemon; see [The Paseo watcher](#the-paseo-watcher-launchd-cant-run-from-tcc-protected-paths)).

Docs of record are `README.md` for user-facing behavior, `REQUIREMENTS.md` for
durable product/integration requirements, and this file plus `AGENTS.md` for
maintainer-agent guidance. Update `REQUIREMENTS.md` whenever a requirement
changes, even if the implementation diff is small.

## Onboarding installer

`iyf-install.sh` is the coworker-facing onboarding entry point. It presents a
terminal selector for the integrations that should trigger IYF: Terminal
commands, Claude Code, Codex, and Paseo. Keep it idempotent: shell setup uses a
managed block in `~/.zshrc`; Claude/Codex setup must merge JSON hooks without
removing unrelated hooks; Paseo setup must delegate to `iyf-paseo-watch.sh
install` so LaunchAgent staging stays centralized. The installer must build or
validate `iyf-alert` because there is no browser fallback. Preserve the
scriptable `--agents`, `--list`, `--dry-run`, and `--no-test` paths because
those are the future curl/Homebrew automation surface.

## Native helper is the only renderer

`iyf-alert` is a SwiftPM executable that opens `alert.html` in an AppKit/WebKit
window sized to the primary display's `visibleFrame`. The launcher looks for
`IYF_NATIVE_ALERT`, then `iyf-alert`, `.build/release/iyf-alert`, and
`.build/debug/iyf-alert` beside `iyf-show-alert.sh`.

There is intentionally **no browser fallback**. If the native helper is missing
or not executable, `iyf-show-alert.sh` exits with an error rather than opening
Chrome, Brave, Edge, Safari, or any other browser. Do not reintroduce browser
fallbacks when working on alert rendering.

## The Paseo watcher: launchd can't run from TCC-protected paths

Paseo runs every agent (`opencode`, `claude`, `codex`, …) through **its own
daemon runtime, not the provider CLIs**, so provider-level hooks never fire for a
Paseo-managed agent — not even a `claude/*` or `codex/*` one — and Paseo exposes
no "run a command on agent event" hook. So instead of a hook, `iyf-paseo-watch.py`
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
`~/Desktop`, `~/Downloads`, *or a symlink into one*. Note **`~/.iyf` is a symlink
to `~/Documents/GitHub/iyf`**, so pointing the plist at `~/.iyf/iyf-paseo-watch.sh`
fails. Symptom: the job log shows `/bin/bash: <path>: Operation not permitted`
and `last exit code = 126`, **even though the exact same script runs fine from
your terminal** (Terminal/ghostty/etc. have been granted TCC access; launchd has
not). This asymmetry is the tell.

**The fix (current design):** `iyf-paseo-watch.sh install` **stages** the runtime
it needs (`iyf-paseo-watch.sh`, `iyf-paseo-watch.py`, `iyf-show-alert.sh`,
`iyf-snooze-daemon.py`, `alert.html`, and `iyf-alert`) into a non-TCC dir —
`~/.local/share/iyf` (override `IYF_PASEO_INSTALL_DIR`) — and points the plist
there. **Staging mirrors the dev-checkout layout**: the front door
(`iyf-paseo-watch.sh`), `alert.html`, and `iyf-alert` sit at the top, while the
internal scripts (`iyf-paseo-watch.py`, `iyf-show-alert.sh`,
`iyf-snooze-daemon.py`) go under `~/.local/share/iyf/lib/`. Keeping the two
layouts identical is load-bearing: the watcher resolves `iyf-show-alert.sh` via
`$dir/lib/…` / a sibling of the `.py`, so a flat stage would break every Paseo
alert from the LaunchAgent while still working in a dev checkout (the classic
masking failure). The installer builds `iyf-alert` with SwiftPM when needed and
fails if it cannot stage the helper. Re-run `install` after editing any of those
scripts or rebuilding the helper to re-stage. The env file lives at the top:
`~/.local/share/iyf/paseo-watch.env`.

**Debugging:**
```bash
launchctl print gui/$(id -u)/com.iyf.paseo-watch | grep -iE 'state =|pid =|last exit'
tail -f "$TMPDIR/iyf-paseo-watch.log"     # clean = running fine; the loop is silent
pgrep -fl iyf-paseo-watch.py              # shows the staged ~/.local/share/iyf path
```
A healthy job is `state = running` with a live `python …/.local/share/iyf/iyf-paseo-watch.py`.

`iyf-paseo-watch.sh status` now prints an emoji health line:
- `✅ Paseo watcher: running (pid N)` — live poll loop
- `⚠️  loaded but not running yet` — job registered, pid not up
- `❌ not loaded — run: ... install` — off
Plus `✅/❌ plist` and `✅ log clean` / `⚠️ log has output`.

## How to validate windowed-vs-fullscreen

First verify that `swift build --product iyf-alert` succeeds and that a test
launch uses `iyf-alert`, not Chrome:
```bash
IYF_AUTO_CLOSE=5 IYF_SNOOZE_MINUTES="" ~/.iyf/iyf-show-alert.sh "validate native" "1s" 0
pgrep -fl iyf-alert
pgrep -fl "Google Chrome.*iyf"  # should be empty
```

For visual geometry, the discriminator is: a normal macOS window cannot sit
under the menu bar, so the alert covering the menu bar is fullscreen; sitting
below it is windowed.

Ask the user to look: "Run `iyf test`: is there a *'press and hold esc to exit
full screen'* banner, and is the menu bar visible?" Banner present / menu bar
hidden = fullscreen. Menu bar visible = windowed.

## Dead-ends — don't waste time here

- **`screencapture` CLI** and **System Events `AXFullScreen`** need permissions
  the terminal usually lacks (Screen Recording / Accessibility) and fail with
  *"could not create image from display"* / *"not allowed assistive access"*.

## Testing the launcher safely

- Run it directly, bypassing the shell hook:
  `IYF_AUTO_CLOSE=20 IYF_SNOOZE_MINUTES="" ~/.iyf/iyf-show-alert.sh "cmd" "1s" 0`
- `IYF_SNOOZE_MINUTES=""` skips spawning the snooze daemon during tests.
- `IYF_ALERT_FILE=/path/diag.html` swaps in a probe page.
- The shell hook execs `~/.iyf/iyf-show-alert.sh` **fresh each time**, so edits to
  the launcher take effect on the next alert **without re-sourcing**. Re-sourcing
  `iyf.sh` only matters for changes to the hook logic in `iyf.sh` itself.
- `~/.iyf` is the installed clone the live hooks run from; it's separate from any
  dev checkout. After changing the launcher, `git -C ~/.iyf pull` to go live.

## Click-to-open the Claude conversation (deep link)

Clicking a Claude Code alert opens that turn's conversation in the Claude macOS
app. The mechanism reuses the **existing click-to-focus path**: the click signals
the snooze daemon, which `open`s a URL instead of `open -b <bundle>`. The new
plumbing is one env var threaded end to end — `iyf-claude-hook.sh` sets
`IYF_CLICK_URL`, `iyf-show-alert.sh` enables `focus=1` and passes it to the
daemon, and `iyf-snooze-daemon.py` prefers the URL over the bundle id on `focus`.

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

## Window geometry

Size = the **primary** display's `visibleFrame` (below the menu bar, above the
Dock), read in the native helper with `NSScreen.main ?? NSScreen.screens.first`.
Do not use Finder's `bounds of window of desktop`, which returns the **union of
all displays** on a multi-monitor setup and would span every monitor.
