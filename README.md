# ada

Developer alerts for long-running terminal commands and coding-agent turns.

A maximized-window alert that pops up when a long-running terminal command
finishes, so you can switch away from the terminal and get yanked back the moment
your build / test / deploy is done.

When a terminal command, Claude Code turn, Codex turn, opencode turn, or Paseo
agent turn runs longer than a threshold, `ada` opens a maximized alert window showing the
command or prompt, the git repo it ran in, how long it took, and its exit status
(green for success, red for failure). Click anywhere or press `Esc` to dismiss;
it also auto-closes after a configurable timeout. Not ready to deal with it yet?
Click
**Snooze**, pick a delay (5/10/30/60 min by default) and it'll pop the same
alert back up later.

If you're still looking at the terminal that ran the command when it finishes,
the output is right in front of you and the alert is just noise — so by default
`ada` stays silent in that case (see
[Staying silent while you're at the terminal](#staying-silent-while-youre-at-the-terminal)).

Durable product and integration requirements are tracked in
[REQUIREMENTS.md](REQUIREMENTS.md). Update that file whenever behavior or
cross-system contracts change.

## Open Source

`ada` is open source under the [MIT License](LICENSE). The core utility is
local-first: it does not send telemetry, prompts, command labels, repository
names, or local paths to a remote service.

The installer can modify shell startup files, Claude Code hooks, Codex hooks,
the opencode plugin directory, and LaunchAgent state when you opt into those
integrations. It preserves
unrelated hook config, writes timestamped backups before JSON edits, and exposes
`--dry-run` / `--list` paths so changes are auditable before install.

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report
security issues privately; see [SECURITY.md](SECURITY.md).

## How it works

`ada.sh` registers zsh `preexec` / `precmd` hooks:

- `preexec` records the command and a start timestamp before it runs.
- `precmd` runs after the command returns, measures elapsed time, and captures
  the exit code.
- If the command took longer than `ADA_THRESHOLD` seconds and isn't in the
  ignore list, it opens the shared alert in a maximized window.

The renderer is the native SwiftPM helper, `ada-alert`, which opens `alert.html`
in a small AppKit / WebKit window. The command, repo name, duration, exit code,
and auto-close timeout are passed as URL query params. The repo name is the
basename of the command's git repository (`git rev-parse --show-toplevel`);
outside a git repo it's omitted and the badge is hidden.

The native helper sizes the alert to the primary display's visible area (below
the menu bar and above the Dock), activates it in the current Space, and exits
when the alert is dismissed. It is used automatically when `ada-alert` is built
beside the scripts or via SwiftPM's `.build` output.

There is no browser fallback. If `ada-alert` is missing or not executable, the
launcher exits with an error instead of opening Chrome, Brave, Edge, or Safari.

## Install

### Homebrew

```sh
brew tap janacm/ada https://github.com/janacm/ada
brew install ada
ada-setup
```

`brew install` builds the native renderer and drops everything into the
Homebrew prefix; it never touches your dotfiles. `ada-setup` then runs the same
interactive integration selector described below (and accepts the same
`--agents` / `--list` / `--dry-run` flags). Re-run `ada-setup` any time to change
which integrations are active.

> The explicit repo URL is required on `brew tap` because this repo isn't named
> `homebrew-ada`; the formula lives in [`Formula/ada.rb`](Formula/ada.rb).
>
> On Homebrew 6.0+ the first `brew tap` of a third-party tap may show a
> trust prompt. Confirm it (or set `HOMEBREW_NO_REQUIRE_TAP_TRUST=1`) to proceed.

#### Updating

```sh
brew update && brew upgrade ada
```

That's the whole update. Nothing needs re-wiring: the shell hook, the
Claude/Codex hooks, and the Paseo watcher all point at Homebrew's
version-stable `opt/ada/libexec` path rather than a versioned Cellar directory,
so an upgrade takes effect on your next shell and next agent turn.

> Upgrading **from v0.2** is the one exception. That release wired itself to a
> versioned Cellar path that `brew upgrade` removes, so run `ada-setup` once
> after upgrading to repoint it.

### From source

Clone the repo and run the installer:

```sh
git clone https://github.com/janacm/ada.git ~/.ada
~/.ada/ada-install.sh
```

The installer builds the native renderer when needed, and rebuilds it when the
Swift sources are newer than your last build (so re-running it after a
`git pull` picks up helper changes), then shows an interactive selector for the
integrations you want:

- **Terminal commands** — adds a managed `ada` block to `~/.zshrc`.
- **Claude Code** — merges `UserPromptSubmit` and `Stop` hooks into
  `~/.claude/settings.json`.
- **Codex** — merges `UserPromptSubmit` and `Stop` hooks into
  `~/.codex/hooks.json`.
- **opencode** — drops a plugin shim into opencode's plugin directory
  (`~/.config/opencode/plugin/ada.js`).
- **Paseo** — stages and loads the LaunchAgent watcher.

It detects which targets exist, preserves existing hook config, writes timestamped
backups before JSON edits, and can be re-run to change the selected integrations.
Then open a new shell (or run `source ~/.zshrc`).

For a scriptable install, pass a comma-separated list:

```sh
~/.ada/ada-install.sh --agents terminal,claude,codex,opencode
~/.ada/ada-install.sh --agents all --no-test
~/.ada/ada-install.sh --list
```

Manual setup still works if you only want the shell hook:

```sh
cd ~/.ada
swift build -c release --product ada-alert
echo 'source ~/.ada/ada.sh' >> ~/.zshrc
```

Optional menu bar helper:

```sh
cd ~/.ada
swift build -c release --product ada-menubar
.build/release/ada-menubar &
```

`ada-menubar` is a lightweight native macOS status item. It does not replace the
terminal, Claude/Codex, or Paseo integrations; it gives you a persistent **ADA**
menu with **Test Alert**, **Open ADA Folder**, and **Quit ADA Menu Bar**. The
helper works out which ada folder it belongs to (a checkout, its `.build`
output, an `.app` bundle, or a Homebrew install) and runs
`lib/ada-show-alert.sh` from there. Set `ADA_HOME=/path/to/ada` before launching
it to point it at a different folder.

Requires **zsh** on **macOS**. SwiftPM is used only to build the native helper;
without a built helper the alert launcher fails closed. `python3` is used to
encode alert text and to power the [snooze](#snoozing-the-alert) buttons;
without it the alert still works, just minus snooze.

## Configuration

All settings are environment variables. Set them before `ada.sh` is sourced
(e.g. export them earlier in `~/.zshrc`):

| Variable | Default | Description |
|----------|---------|-------------|
| `ADA_THRESHOLD` | `10` | Minimum command duration, in seconds, to trigger an alert. |
| `ADA_AUTO_CLOSE` | `90` | Seconds the alert stays up before auto-dismissing. Unset or non-positive falls back to 90. |
| `ADA_IGNORE_CMDS` | interactive tools (see below) | Space-separated list of command names to never alert on. Matched against the command's basename. |
| `ADA_ALERT_FILE` | `alert.html` in the ada install | Path to the alert HTML page. Defaults to the page shipped with the scripts, wherever ada is installed. |
| `ADA_NATIVE_ALERT` | _(auto)_ | Path to a specific `ada-alert` executable. Defaults to `ada-alert`, `.build/release/ada-alert`, or `.build/debug/ada-alert` in the ada install, one level above `lib/ada-show-alert.sh`. |
| `ADA_REPO` | _(auto: git repo name)_ | Repo name shown on the alert. Auto-detected as the basename of the command's git repository; set it to override the displayed name, or to empty (`ADA_REPO=""`) to hide the repo badge. A snooze re-launch reuses the value resolved on the first alert. |
| `ADA_REPO_DIR` | _(where the command ran)_ | Directory whose git repo name is shown. Defaults to the launcher's working directory, which is almost always right; the [Claude/Codex hook integration](#claude-code-and-codex) sets it to the turn's project directory automatically. Ignored when `ADA_REPO` is set. |
| `ADA_FOCUS_APP` | `__CFBundleIdentifier` | Bundle id to activate when you click the alert. Set to empty to make click-anywhere only dismiss. The Paseo watcher defaults this to `sh.paseo.desktop`. |
| `ADA_FOCUS_APP_NAME` | _(empty)_ | Optional display name shown in the click hint. The Paseo watcher defaults this to `Paseo`. |
| `ADA_CLICK_URL` | _(empty)_ | URL to `open` when you click the alert, instead of just activating `ADA_FOCUS_APP`. Takes precedence over the bundle id and is preserved across a snooze. The [Claude Code hook](#claude-code-and-codex) sets it to `claude://resume?session=<id>` so a click opens that turn's conversation in the Claude macOS app. Requires `python3` (the click daemon). |
| `ADA_SKIP_OWN_TERMINAL` | `1` | When `1`, suppress the alert if the terminal that ran the command is the frontmost app when it finishes. Set to `0` to always alert. |
| `ADA_SKIP_WHEN_ACTIVE` | _(empty)_ | Space-separated apps to also stay silent for when they're frontmost. Each entry matches a frontmost app's bundle id exactly, or its name as a substring. |
| `ADA_CLAUDE_THRESHOLD` | `45` | Minimum Claude Code / Codex *turn* duration, in seconds, to trigger an alert. Only used by the [Claude/Codex hook integration](#claude-code-and-codex). |
| `ADA_CLAUDE_STALE_MAX` | `21600` | Max age, in seconds, of a fallback start stamp when a Codex `Stop` payload does not match the original `UserPromptSubmit` session id. |
| `ADA_DEBUG_LOG` | _(empty)_ | When set, log Claude/Codex hook payload summaries to `${TMPDIR}/ada-claude-debug.log` (or `ADA_DEBUG_LOG_FILE`) for debugging. A `${TMPDIR}/ada-claude-debug.on` sentinel enables the same logging when an agent strips hook env vars. The opencode plugin logs the same way to `${TMPDIR}/ada-opencode-debug.log`, with its own `${TMPDIR}/ada-opencode-debug.on` sentinel. |
| `ADA_OPENCODE_THRESHOLD` | `45` | Minimum opencode *turn* duration, in seconds, to trigger a finished-turn alert. Only used by the [opencode integration](#opencode). |
| `ADA_OPENCODE_EVENTS` | `finish error permission` | Which opencode events fire an alert — any subset of `finish` (turn done), `error` (turn failed), `permission` (the agent is blocked waiting on you). Empty disables the integration without uninstalling it. Only used by the [opencode integration](#opencode). |
| `ADA_PASEO_THRESHOLD` | `45` | Minimum Paseo agent *turn* duration, in seconds, to trigger a finished-turn alert. Only used by the [Paseo integration](#paseo). |
| `ADA_PASEO_POLL` | `3` | How often, in seconds, the Paseo watcher polls the daemon for agent status changes. Only used by the [Paseo integration](#paseo). |
| `ADA_PASEO_EVENTS` | `finish error permission` | Which Paseo agent events fire an alert — any subset of `finish` (turn done), `error` (turn failed), `permission` (agent is blocked waiting on you). Only used by the [Paseo integration](#paseo). |
| `ADA_PASEO_SKIP_WHEN_ACTIVE` | `sh.paseo.desktop` | Like `ADA_SKIP_WHEN_ACTIVE`, but for the Paseo watcher: stay silent when the Paseo desktop app is frontmost (you're already watching). Set to empty to always alert. |
| `ADA_SNOOZE_MINUTES` | `5 10 30 60` | Space-separated snooze options, in minutes, shown as buttons on the alert. Set to empty to hide the buttons. Requires `python3` (see [Snoozing the alert](#snoozing-the-alert)). |
| `ADA_MUTE_BUTTON` | `1` | Set to `0` to hide the **Mute this …** button. Sessions you already muted stay muted. See [Muting a session](#muting-a-session). |
| `ADA_MUTE_MAX_AGE` | `86400` | Seconds a mute lasts before that session alerts again. `0` keeps it until you clear it. |
| `ADA_MUTE_DIR` | `${TMPDIR}/ada-muted` | Where the mute markers live, one empty file per muted session. |
| `ADA_SESSION_KEY` | _(set by each integration)_ | Which session an alert belongs to; the integrations set it for you. Only letters, digits, `.`, `_` and `-` are accepted, and an alert without a valid key has no mute button. |

The default ignore list covers common interactive / long-lived foreground tools:

```
vim nvim nano emacs less more man htop top tig lazygit btm bottom glances
```

## Staying silent while you're at the terminal

The alert exists to yank you back when you've switched *away* from the terminal.
If you never left — you ran the command and watched it finish — popping a
maximized window over the output you're already reading is just annoying.

So when a command crosses the threshold, `ada` checks the frontmost macOS app
(via `lsappinfo`, which needs no Automation permission) and stays silent if:

- **It's the terminal that ran the command** (`ADA_SKIP_OWN_TERMINAL=1`, the
  default). This is detected per-shell from the terminal's bundle id, so it
  works across ghostty, Termius, iTerm2, Terminal, etc. with no configuration.
- **It's an app you listed** in `ADA_SKIP_WHEN_ACTIVE`.

The check only runs *after* the duration threshold is met, so it never touches
the fast interactive path.

> **Terminal TUIs are not separate apps.** Agents like `opencode` run *inside*
> a terminal emulator, so macOS reports the terminal (e.g. ghostty) as
> frontmost — not `opencode`. The default own-terminal detection already covers
> this. If you want to name apps explicitly, list the *terminal*, not the TUI:
>
> ```sh
> export ADA_SKIP_WHEN_ACTIVE="ghostty Termius"
> ```

If the frontmost app can't be determined (e.g. a `tmux`/`ssh` session where the
terminal's bundle id isn't propagated), `ada` errs toward showing the alert.

## Usage

It runs automatically once sourced. To preview the alert without waiting for a
slow command:

```sh
ada make build      # shows the alert immediately for "make build"
```

## Claude Code and Codex

The same alert works for direct agent hooks in
[Claude Code](https://claude.com/claude-code) and Codex: when a long agent
*turn* finishes — you asked it to do something big and switched away — it yanks
you back the moment it's done, showing your prompt and how long the turn took.

It reuses the same launcher (`ada-show-alert.sh`), the same `alert.html`, and
the same "stay silent while you're at the terminal" logic as the shell hook.
No zsh sourcing required — it's driven by two agent hooks pointing at
`ada-claude-hook.sh`:

- `UserPromptSubmit` records when the turn started (and your prompt text).
- `Stop` measures how long the turn took and fires the alert if it ran longer
  than `ADA_CLAUDE_THRESHOLD` seconds (default `45`) and you're not already
  looking at the terminal the agent is running in.

The installer can wire this for you:

```sh
~/.ada/ada-install.sh --agents claude,codex
```

For manual Claude Code setup, add this to `~/.claude/settings.json` (merge into
any existing `hooks`), pointing at wherever you cloned the repo:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/path/to/ada/ada-claude-hook.sh", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/path/to/ada/ada-claude-hook.sh", "timeout": 10, "async": true } ] }
    ]
  }
}
```

For manual Codex setup, wire the same script to the equivalent
`UserPromptSubmit` and `Stop` hook events in `~/.codex/hooks.json`. The script
accepts the same JSON payload shape; if Codex sends a `Stop` event with a
different or missing `session_id`, it falls back to the most recent start stamp
that is still younger than `ADA_CLAUDE_STALE_MAX`.

Not every turn starts with something you typed. The agent fires the same
`UserPromptSubmit` hook for messages it injects — a background task finishing, a
slash command, a system reminder — and those arrive as raw markup. The alert
label is derived rather than printed verbatim, so such a turn shows
`⚙️ Background command "make build" completed (exit code 0)` instead of a window
full of `<task-notification><task-id>…`. A prompt you typed is never altered —
including one that is itself markup, since the detection keys on the hyphenated
tag names the harness uses (`task-notification`, `system-reminder`) rather than
on markup alone. Text you paste into the Claude desktop app shows as
`[pasted text]` next to what you typed, or as the pasted text itself when the
paste is the whole prompt.

Tune the trigger independently of the terminal threshold with
`ADA_CLAUDE_THRESHOLD`. The own-terminal / `ADA_SKIP_WHEN_ACTIVE` silencing
rules apply here too, so an alert only pops when you've actually walked away.

**Click to open the conversation.** For a Claude Code turn, clicking the alert
jumps straight to *that* conversation in the [Claude macOS app](https://claude.ai/download)
— it uses the app's `claude://resume?session=<id>` deep link to import and focus
the session. This is wired automatically and only for real Claude Code sessions
(the hook checks the session id is a UUID with a transcript on disk), so Codex
turns — which share the hook but can't be resumed in Claude.app — just dismiss on
click as before. Requires the desktop app installed and signed in.

> Requires `python3` (used to parse the hook payload, and to run the
> click-to-open / snooze daemon). Subagent turns don't fire it — only the main
> agent's `Stop`.

## opencode

The same alert works for [opencode](https://opencode.ai): when a long turn
finishes it yanks you back showing your prompt and how long it took. It also
fires when a turn **fails**, and when the agent is **blocked waiting on you**
for a permission.

opencode has no `UserPromptSubmit`/`Stop` hook config like Claude Code and
Codex. What it has is a **plugin** API, so this integration is a small plugin
(`lib/ada-opencode-plugin.mjs`) that watches opencode's own events and calls the
same launcher as every other entry point:

- `chat.message` records when your turn started, and your prompt text.
- `session.idle` means that turn finished — it fires once, after the last tool
  call — and alerts if the turn ran longer than `ADA_OPENCODE_THRESHOLD`
  seconds (default `45`) and you're not already looking at the terminal
  opencode is running in.
- `session.error` alerts **regardless of duration**, because a turn that fails
  in two seconds is exactly what a duration threshold would swallow. It arrives
  just before `session.idle`, so a failed turn produces one alert, not two.
  Interrupting a turn yourself (`Esc`) is the exception — that's an abort, not a
  failure, and it stays silent along with the finish alert for that turn, since
  you were at the keyboard to cause it. Auth failures name the provider, API
  errors append the HTTP status, and a retryable error still alerts (opencode's
  own retries happen earlier, so an error that reaches this point ended the
  turn).
- `permission.asked` alerts as soon as the agent is blocked waiting for your
  approval, and leaves the turn running so you still get the finish alert.

Sub-agent sessions never alert on their own: their `session.idle` is not your
turn ending, the parent session is still working.

The installer wires it for you:

```sh
~/.ada/ada-install.sh --agents opencode
```

That writes a one-line shim to `~/.config/opencode/plugin/ada.js` (asking
`opencode debug paths` where its config root actually is, so a relocated
`XDG_CONFIG_HOME` is honored):

```js
export * from "/path/to/ada/lib/ada-opencode-plugin.mjs"
```

opencode auto-loads every `.js` file in that directory, so there's nothing to
merge and no config file to edit. **Deleting that file is how you uninstall
this integration.** The shim only carries the path — the logic stays in the ada
install directory, so editing the plugin takes effect on the next opencode
start. To scope it to a single project instead, drop the same one-liner in
`<project>/.opencode/plugin/ada.js`.

Tune it with `ADA_OPENCODE_THRESHOLD` and `ADA_OPENCODE_EVENTS`; the
own-terminal / `ADA_SKIP_WHEN_ACTIVE` silencing rules apply here too. An
opencode started from a shell that sources `ada.sh` inherits all of them
already.

Two things worth knowing:

- **The terminal integration also sees `opencode`.** `opencode` (TUI) and
  `opencode run ...` are shell commands, so if one runs past
  `ADA_THRESHOLD` and you're away from the terminal when it exits, the zsh hook
  fires its own alert for the command. Add `opencode` to `ADA_IGNORE_CMDS` if
  you'd rather only the per-turn alerts fire.
- **Paseo-managed opencode agents don't load this plugin.** Paseo runs agents
  through its own daemon runtime; use the [Paseo](#paseo) integration for those.

> Requires opencode's plugin loader (any recent opencode) and `python3` for the
> snooze daemon. Verified against opencode 1.18.30.

## Paseo

The same alert works for [Paseo](https://paseo.sh) agents: when a long-running
agent **finishes a turn** — you kicked off something big and switched away — it
yanks you back the moment it's done. It also fires when an agent is **blocked
waiting on you** (a permission request), and when a turn **fails**.

It reuses the same launcher (`ada-show-alert.sh`), the same `alert.html`, and the
same "stay silent while you're watching" logic as the other entry points. But
unlike the direct Claude/Codex hook integration, it is **not** a hook. Paseo runs
every agent (`opencode`, `claude`, `codex`, …) through its own daemon runtime
rather than the provider CLIs, so provider-level hook config never fires for a
Paseo-managed agent — not even a `claude/*` or `codex/*` one — and Paseo exposes
no "run a command on agent event" hook of its own.

So instead, a small watcher (`ada-paseo-watch.sh` → `ada-paseo-watch.py`) polls
the daemon through the supported CLI and synthesizes the missing event by diffing
each agent's status between snapshots:

- `paseo ls --json` — a `running → idle` transition is a finished turn;
  `running → error` is a failed one.
- `paseo permit ls --json` — a new entry is an agent waiting on a permission.

One watcher covers every agent and every provider, and survives daemon restarts.

Install it as a background **launchd LaunchAgent** so it runs across logins —
install-once, like sourcing `ada.sh`:

```sh
~/.ada/ada-paseo-watch.sh install     # stage runtime + load the LaunchAgent
~/.ada/ada-paseo-watch.sh status      # check health: ✅ running (pid), ✅ plist, ✅ log clean
~/.ada/ada-paseo-watch.sh uninstall   # unload + remove it
```

For a **from-source install**, `install` copies the few files it needs into
`~/.local/share/ada`, builds and stages the required `ada-alert` helper when
needed, and points the LaunchAgent there. If it cannot stage `ada-alert`,
installation fails. This matters: a launchd job runs **without your Full Disk
Access**, so it can't execute scripts from TCC-protected folders like
`~/Documents` — and `~/.ada` is often a symlink into exactly that. Running from
a staged, non-TCC copy sidesteps the `Operation not permitted` failure entirely.
Override the location with `ADA_PASEO_INSTALL_DIR`.

For a **Homebrew install** there is nothing to stage: the Homebrew prefix is
already outside every TCC-protected folder, so the LaunchAgent runs the watcher
in place from `$(brew --prefix)/opt/ada/libexec` — which also means
`brew upgrade ada` updates the watcher without re-running `install`. Either way
`status` prints the runtime it's actually using.

Or run it in the foreground to try it out (Ctrl-C to stop), and fire a one-off
sample alert to confirm the visuals:

```sh
~/.ada/ada-paseo-watch.sh run
~/.ada/ada-paseo-watch.sh test        # pops one sample alert and exits
```

Tune it with `ADA_PASEO_THRESHOLD` (min finished-turn seconds, default `45`),
`ADA_PASEO_POLL` (poll interval, default `3`), and `ADA_PASEO_EVENTS` (any subset
of `finish error permission`). By default it stays silent while the Paseo desktop
app is frontmost — you're already watching — which you can change or disable with
`ADA_PASEO_SKIP_WHEN_ACTIVE`.

Because the LaunchAgent doesn't inherit your interactive shell environment, set
its knobs in an env file at `~/.local/share/ada/paseo-watch.env` (overridable
with `ADA_PASEO_ENV`), which the watcher sources on startup:

```sh
# ~/.local/share/ada/paseo-watch.env
ADA_PASEO_THRESHOLD=60
ADA_PASEO_EVENTS="finish permission"
```

> Requires `python3` (the poll loop) and the `paseo` CLI on `PATH` (or the Paseo
> desktop app installed at its default location). The watcher finds both
> automatically.

## Returning from the alert

- Click anywhere to bring the originating app forward, when ADA knows its bundle
  id. Terminal and agent hooks usually inherit this from macOS as
  `__CFBundleIdentifier`; the Paseo watcher sets it to `sh.paseo.desktop`.
- For a Claude Code turn, clicking instead deep-links to that exact conversation
  in the Claude macOS app (see [Claude Code and Codex](#claude-code-and-codex)).
  Set `ADA_CLICK_URL` yourself to make the click `open` any URL — it takes
  precedence over `ADA_FOCUS_APP`.
- Press `Esc` for a plain dismiss without changing focus.
- It auto-dismisses after `ADA_AUTO_CLOSE` seconds — the progress bar along the
  bottom shows the time remaining. Auto-dismiss is also a plain dismiss.
- Opening a new alert first closes any previous alert window, so they don't
  stack up.

## Snoozing the alert

Sometimes the build's done but you're not ready to context-switch back. The
alert has a **Snooze** button under the dismiss hint; click it to reveal the
delays, `5 10 30 60` minutes by default, configurable with `ADA_SNOOZE_MINUTES`.
Click one and the window closes now and the *same* alert (same command,
duration, exit code) pops back up after the delay, labelled as a snoozed
reminder. You can snooze a reminder again.

If you snooze often, click **Pin open** at the end of that row and every later
alert shows the delays already expanded. Click it again (it reads **Pinned
open** while on) to go back to the collapsed button. The native helper stores
the choice in user defaults (`defaults read com.ada.alert snoozePinned`), so it
survives reboots and upgrades; `defaults delete com.ada.alert` resets it.

Need a duration that isn't on the list? Click **Custom** to reveal a minutes
input, type any value (1–1440), and press Enter or **Set**. `Esc` while it's
open just cancels the field instead of dismissing the alert.

Why it needs a helper: the alert is a sandboxed `file://` page, and once its
window closes its JavaScript is gone. A pure in-page timer cannot relaunch the
alert later or bring another app forward, so picking a snooze re-launches a
*fresh* alert from the shell side. To bridge the page and launcher,
`ada-show-alert.sh` spawns a tiny detached `python3` daemon
(`ada-snooze-daemon.py`) on an ephemeral **loopback-only** port; the page tells
it which delay you picked via a local request, the daemon waits, then re-runs
the launcher. The same daemon also handles click-to-focus without exposing the
target bundle id in the page URL. It self-exits when you dismiss normally or
after the alert's auto-close window, so nothing lingers.

Because the daemon is `python3`, snooze and click-to-focus are unavailable when
`python3` isn't on `PATH` — the buttons simply don't render, click-anywhere
becomes a plain dismiss, and everything else behaves as before. Setting
`ADA_SNOOZE_MINUTES=""` also hides the snooze buttons.

## Muting a session

When one conversation keeps finishing turns you don't need to hear about, click
**🔕 Mute this conversation** under the snooze buttons. The alert closes and
that session stops alerting: finished turns, errors and permission prompts all
stay silent. Other sessions alert as usual. The button's wording follows the
integration:

| Integration | What gets muted | Key |
| --- | --- | --- |
| Claude Code / Codex | this conversation | `claude-<session id>` |
| opencode | this session | `opencode-<session id>` |
| Paseo | this agent | `paseo-<agent id>` |
| Terminal (zsh hook) | this terminal tab, until the shell exits | `zsh-<pid>-<start time>` |

A mute lasts 24 hours (`ADA_MUTE_MAX_AGE`), then the session alerts again. To
look at or undo mutes before then:

```sh
ada-mute list              # Homebrew (releases after v0.4); from a checkout: lib/ada-mute.sh list
ada-mute clear claude-…    # unmute one session
ada-mute clear             # unmute everything
```

The `ada` test command in the terminal is never muted, so it still works as a
check. Muting uses the same `python3` daemon as snoozing, so without `python3`
the button isn't shown.

## Feedback

Every alert carries a small **Feedback** note in the corner — for when you want
to support the project, want ADA to support a different agent, or the pop-up
didn't fire the way you expected. Its link opens the project's
[GitHub issues](https://github.com/janacm/ada/issues) in your default browser
(the native helper hands the URL to macOS, so it opens externally instead of
taking over the alert window). Clicking the note doesn't dismiss the alert —
click elsewhere or press `Esc` for that.
