# In Your Face for Terminal

A maximized-window alert that pops up when a long-running terminal command
finishes, so you can switch away from the terminal and get yanked back the moment
your build / test / deploy is done.

When a command runs longer than a threshold, `iyf` opens a maximized browser
window showing the command, the git repo it ran in, how long it took, and its
exit status (green for success, red for failure). Click anywhere or press `Esc`
to dismiss; it also auto-closes after a configurable timeout. Not ready to deal
with it yet? Hit a
**Snooze** button (5/10/30/60 min by default) and it'll pop the same alert back
up later.

If you're still looking at the terminal that ran the command when it finishes,
the output is right in front of you and the alert is just noise — so by default
`iyf` stays silent in that case (see
[Staying silent while you're at the terminal](#staying-silent-while-youre-at-the-terminal)).

## How it works

`iyf.sh` registers zsh `preexec` / `precmd` hooks:

- `preexec` records the command and a start timestamp before it runs.
- `precmd` runs after the command returns, measures elapsed time, and captures
  the exit code.
- If the command took longer than `IYF_THRESHOLD` seconds and isn't in the
  ignore list, it opens `alert.html` in a maximized window.

The alert is a local HTML file opened as a Chrome / Brave / Edge `--app` window
(falling back to Safari if none are installed). The command, repo name,
duration, exit code, and auto-close timeout are passed as URL query params. The
repo name is the basename of the command's git repository (`git rev-parse
--show-toplevel`); outside a git repo it's omitted and the badge is hidden.

To make the alert a **maximized window in your current Space** — rather than a
macOS *native full-screen* window on its own Space, which animates in/out and
steals keyboard focus — it's launched in a dedicated, throwaway browser instance
with its own `--user-data-dir`. This is necessary because an already-running
browser silently ignores window-geometry flags passed to a new `--app` window,
so a separate instance is the only way to reliably size the alert. The window is
sized to the primary display's visible area (below the menu bar), and the
instance quits the moment the alert is dismissed.

## Install

Clone the repo to `~/.iyf` and source it from your `~/.zshrc`:

```sh
git clone <repo-url> ~/.iyf
echo 'source ~/.iyf/iyf.sh' >> ~/.zshrc
```

Then open a new shell (or run `source ~/.zshrc`).

Requires **zsh** on **macOS**. `python3` is used to URL-encode the command and
to power the [snooze](#snoozing-the-alert) buttons; without it the alert still
works, just minus snooze.

## Configuration

All settings are environment variables. Set them before `iyf.sh` is sourced
(e.g. export them earlier in `~/.zshrc`):

| Variable | Default | Description |
|----------|---------|-------------|
| `IYF_THRESHOLD` | `10` | Minimum command duration, in seconds, to trigger an alert. |
| `IYF_AUTO_CLOSE` | `90` | Seconds the alert stays up before auto-dismissing. Unset or non-positive falls back to 90. |
| `IYF_IGNORE_CMDS` | interactive tools (see below) | Space-separated list of command names to never alert on. Matched against the command's basename. |
| `IYF_ALERT_FILE` | `~/.iyf/alert.html` | Path to the alert HTML page. |
| `IYF_BROWSER_PROFILE` | `~/.iyf-alert-profile` | Directory for the alert's dedicated, throwaway browser profile. The alert runs in its own browser instance (see [How it works](#how-it-works)) so it opens as a maximized window instead of native full-screen; this is where that instance's profile lives. |
| `IYF_REPO` | _(auto: git repo name)_ | Repo name shown on the alert. Auto-detected as the basename of the command's git repository; set it to override the displayed name, or to empty (`IYF_REPO=""`) to hide the repo badge. A snooze re-launch reuses the value resolved on the first alert. |
| `IYF_REPO_DIR` | _(where the command ran)_ | Directory whose git repo name is shown. Defaults to the launcher's working directory, which is almost always right; the [Claude Code integration](#claude-code) sets it to the turn's project directory automatically. Ignored when `IYF_REPO` is set. |
| `IYF_FOCUS_APP` | `__CFBundleIdentifier` | Bundle id to activate when you click the alert. Set to empty to make click-anywhere only dismiss. The Paseo watcher defaults this to `sh.paseo.desktop`. |
| `IYF_FOCUS_APP_NAME` | _(empty)_ | Optional display name shown in the click hint. The Paseo watcher defaults this to `Paseo`. |
| `IYF_SKIP_OWN_TERMINAL` | `1` | When `1`, suppress the alert if the terminal that ran the command is the frontmost app when it finishes. Set to `0` to always alert. |
| `IYF_SKIP_WHEN_ACTIVE` | _(empty)_ | Space-separated apps to also stay silent for when they're frontmost. Each entry matches a frontmost app's bundle id exactly, or its name as a substring. |
| `IYF_CLAUDE_THRESHOLD` | `45` | Minimum Claude Code *turn* duration, in seconds, to trigger an alert. Only used by the [Claude Code integration](#claude-code). |
| `IYF_PASEO_THRESHOLD` | `45` | Minimum Paseo agent *turn* duration, in seconds, to trigger a finished-turn alert. Only used by the [Paseo integration](#paseo). |
| `IYF_PASEO_POLL` | `3` | How often, in seconds, the Paseo watcher polls the daemon for agent status changes. Only used by the [Paseo integration](#paseo). |
| `IYF_PASEO_EVENTS` | `finish error permission` | Which Paseo agent events fire an alert — any subset of `finish` (turn done), `error` (turn failed), `permission` (agent is blocked waiting on you). Only used by the [Paseo integration](#paseo). |
| `IYF_PASEO_SKIP_WHEN_ACTIVE` | `sh.paseo.desktop` | Like `IYF_SKIP_WHEN_ACTIVE`, but for the Paseo watcher: stay silent when the Paseo desktop app is frontmost (you're already watching). Set to empty to always alert. |
| `IYF_SNOOZE_MINUTES` | `5 10 30 60` | Space-separated snooze options, in minutes, shown as buttons on the alert. Set to empty to hide the buttons. Requires `python3` (see [Snoozing the alert](#snoozing-the-alert)). |

The default ignore list covers common interactive / long-lived foreground tools:

```
vim nvim nano emacs less more man htop top tig lazygit btm bottom glances
```

## Staying silent while you're at the terminal

The alert exists to yank you back when you've switched *away* from the terminal.
If you never left — you ran the command and watched it finish — popping a
maximized window over the output you're already reading is just annoying.

So when a command crosses the threshold, `iyf` checks the frontmost macOS app
(via `lsappinfo`, which needs no Automation permission) and stays silent if:

- **It's the terminal that ran the command** (`IYF_SKIP_OWN_TERMINAL=1`, the
  default). This is detected per-shell from the terminal's bundle id, so it
  works across ghostty, Termius, iTerm2, Terminal, etc. with no configuration.
- **It's an app you listed** in `IYF_SKIP_WHEN_ACTIVE`.

The check only runs *after* the duration threshold is met, so it never touches
the fast interactive path.

> **Terminal TUIs are not separate apps.** Agents like `opencode` run *inside*
> a terminal emulator, so macOS reports the terminal (e.g. ghostty) as
> frontmost — not `opencode`. The default own-terminal detection already covers
> this. If you want to name apps explicitly, list the *terminal*, not the TUI:
>
> ```sh
> export IYF_SKIP_WHEN_ACTIVE="ghostty Termius"
> ```

If the frontmost app can't be determined (e.g. a `tmux`/`ssh` session where the
terminal's bundle id isn't propagated), `iyf` errs toward showing the alert.

## Usage

It runs automatically once sourced. To preview the alert without waiting for a
slow command:

```sh
iyf make build      # shows the alert immediately for "make build"
```

## Claude Code

The same alert works for [Claude Code](https://claude.com/claude-code): when a
long Claude *turn* finishes — you asked it to do something big and switched away
— it yanks you back the moment it's done, showing your prompt and how long the
turn took.

It reuses the same launcher (`iyf-show-alert.sh`), the same `alert.html`, and
the same "stay silent while you're at the terminal" logic as the shell hook.
No zsh sourcing required — it's driven by two Claude Code hooks pointing at
`iyf-claude-hook.sh`:

- `UserPromptSubmit` records when the turn started (and your prompt text).
- `Stop` measures how long the turn took and fires the alert if it ran longer
  than `IYF_CLAUDE_THRESHOLD` seconds (default `45`) and you're not already
  looking at the terminal Claude is running in.

Add this to `~/.claude/settings.json` (merge into any existing `hooks`), pointing
at wherever you cloned the repo:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/path/to/iyf/iyf-claude-hook.sh", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/path/to/iyf/iyf-claude-hook.sh", "timeout": 10, "async": true } ] }
    ]
  }
}
```

Tune the trigger independently of the terminal threshold with
`IYF_CLAUDE_THRESHOLD`. The own-terminal / `IYF_SKIP_WHEN_ACTIVE` silencing
rules apply here too, so an alert only pops when you've actually walked away.

> Requires `python3` (used to parse the hook payload). Subagent turns don't
> fire it — only the main agent's `Stop`.

## Paseo

The same alert works for [Paseo](https://paseo.sh) agents: when a long-running
agent **finishes a turn** — you kicked off something big and switched away — it
yanks you back the moment it's done. It also fires when an agent is **blocked
waiting on you** (a permission request), and when a turn **fails**.

It reuses the same launcher (`iyf-show-alert.sh`), the same `alert.html`, and the
same "stay silent while you're watching" logic as the other entry points. But
unlike the Claude Code integration, it is **not** a hook. Paseo runs every agent
(`opencode`, `claude`, `codex`, …) through its own daemon runtime rather than the
provider CLIs, so `~/.claude/settings.json` hooks never fire for a Paseo-managed
agent — not even a `claude/*` one — and Paseo exposes no "run a command on agent
event" hook of its own.

So instead, a small watcher (`iyf-paseo-watch.sh` → `iyf-paseo-watch.py`) polls
the daemon through the supported CLI and synthesizes the missing event by diffing
each agent's status between snapshots:

- `paseo ls --json` — a `running → idle` transition is a finished turn;
  `running → error` is a failed one.
- `paseo permit ls --json` — a new entry is an agent waiting on a permission.

One watcher covers every agent and every provider, and survives daemon restarts.

Install it as a background **launchd LaunchAgent** so it runs across logins —
install-once, like sourcing `iyf.sh`:

```sh
~/.iyf/iyf-paseo-watch.sh install     # stage runtime + load the LaunchAgent
~/.iyf/iyf-paseo-watch.sh status      # check health: ✅ running (pid), ✅ plist, ✅ log clean
~/.iyf/iyf-paseo-watch.sh uninstall   # unload + remove it
```

`install` copies the few files it needs into `~/.local/share/iyf` and points the
LaunchAgent there. This matters: a launchd job runs **without your Full Disk
Access**, so it can't execute scripts from TCC-protected folders like
`~/Documents` — and `~/.iyf` is often a symlink into exactly that. Running from a
staged, non-TCC copy sidesteps the `Operation not permitted` failure entirely.
Override the location with `IYF_PASEO_INSTALL_DIR`.

Or run it in the foreground to try it out (Ctrl-C to stop), and fire a one-off
sample alert to confirm the visuals:

```sh
~/.iyf/iyf-paseo-watch.sh run
~/.iyf/iyf-paseo-watch.sh test        # pops one sample alert and exits
```

Tune it with `IYF_PASEO_THRESHOLD` (min finished-turn seconds, default `45`),
`IYF_PASEO_POLL` (poll interval, default `3`), and `IYF_PASEO_EVENTS` (any subset
of `finish error permission`). By default it stays silent while the Paseo desktop
app is frontmost — you're already watching — which you can change or disable with
`IYF_PASEO_SKIP_WHEN_ACTIVE`.

Because the LaunchAgent doesn't inherit your interactive shell environment, set
its knobs in an env file next to the staged runtime
(`~/.local/share/iyf/paseo-watch.env`, overridable with `IYF_PASEO_ENV`), which
the watcher sources on startup:

```sh
# ~/.local/share/iyf/paseo-watch.env
IYF_PASEO_THRESHOLD=60
IYF_PASEO_EVENTS="finish permission"
```

> Requires `python3` (the poll loop) and the `paseo` CLI on `PATH` (or the Paseo
> desktop app installed at its default location). The watcher finds both
> automatically.

## Returning from the alert

- Click anywhere to bring the originating app forward, when IYF knows its bundle
  id. Terminal and agent hooks usually inherit this from macOS as
  `__CFBundleIdentifier`; the Paseo watcher sets it to `sh.paseo.desktop`.
- Press `Esc` for a plain dismiss without changing focus.
- It auto-dismisses after `IYF_AUTO_CLOSE` seconds — the progress bar along the
  bottom shows the time remaining. Auto-dismiss is also a plain dismiss.
- Opening a new alert first closes any previous alert window, so they don't
  stack up.

## Snoozing the alert

Sometimes the build's done but you're not ready to context-switch back. The
alert shows a row of **Snooze** buttons — `5 10 30 60` minutes by default,
configurable with `IYF_SNOOZE_MINUTES`. Click one and the window closes now and
the *same* alert (same command, duration, exit code) pops back up after the
delay, labelled as a snoozed reminder. You can snooze a reminder again.

Why it needs a helper: the alert is a sandboxed `file://` page, and once its
window closes its JavaScript is gone — and browsers won't let a background page
bring itself forward or steal focus on a timer, so a pure in-page timer
couldn't yank you back the way the original alert does. So picking a snooze
re-launches a *fresh* alert from the shell side. To bridge the two,
`iyf-show-alert.sh` spawns a tiny detached `python3` daemon
(`iyf-snooze-daemon.py`) on an ephemeral **loopback-only** port; the page tells
it which delay you picked via a local request, the daemon waits, then re-runs
the launcher. The same daemon also handles click-to-focus without exposing the
target bundle id in the page URL. It self-exits when you dismiss normally or
after the alert's auto-close window, so nothing lingers.

Because the daemon is `python3`, snooze and click-to-focus are unavailable when
`python3` isn't on `PATH` — the buttons simply don't render, click-anywhere
becomes a plain dismiss, and everything else behaves as before. Setting
`IYF_SNOOZE_MINUTES=""` also hides the snooze buttons.
