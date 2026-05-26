# In Your Face for Terminal

A full-screen alert that pops up when a long-running terminal command finishes,
so you can switch away from the terminal and get yanked back the moment your
build / test / deploy is done.

When a command runs longer than a threshold, `iyf` opens a full-screen browser
window showing the command, how long it took, and its exit status (green for
success, red for failure). Click anywhere or press `Esc` to dismiss; it also
auto-closes after a configurable timeout.

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
  ignore list, it opens `alert.html` full-screen.

The alert is a local HTML file opened as a Chrome / Brave / Edge `--app` window
(falling back to Safari if none are installed). The command, duration, exit
code, and auto-close timeout are passed as URL query params.

## Install

Clone the repo to `~/.iyf` and source it from your `~/.zshrc`:

```sh
git clone <repo-url> ~/.iyf
echo 'source ~/.iyf/iyf.sh' >> ~/.zshrc
```

Then open a new shell (or run `source ~/.zshrc`).

Requires **zsh** on **macOS**. `python3` is used to URL-encode the command when
available, and degrades gracefully without it.

## Configuration

All settings are environment variables. Set them before `iyf.sh` is sourced
(e.g. export them earlier in `~/.zshrc`):

| Variable | Default | Description |
|----------|---------|-------------|
| `IYF_THRESHOLD` | `10` | Minimum command duration, in seconds, to trigger an alert. |
| `IYF_AUTO_CLOSE` | `90` | Seconds the alert stays up before auto-dismissing. Unset or non-positive falls back to 90. |
| `IYF_IGNORE_CMDS` | interactive tools (see below) | Space-separated list of command names to never alert on. Matched against the command's basename. |
| `IYF_ALERT_FILE` | `~/.iyf/alert.html` | Path to the alert HTML page. |
| `IYF_SKIP_OWN_TERMINAL` | `1` | When `1`, suppress the alert if the terminal that ran the command is the frontmost app when it finishes. Set to `0` to always alert. |
| `IYF_SKIP_WHEN_ACTIVE` | _(empty)_ | Space-separated apps to also stay silent for when they're frontmost. Each entry matches a frontmost app's bundle id exactly, or its name as a substring. |

The default ignore list covers common interactive / long-lived foreground tools:

```
vim nvim nano emacs less more man htop top tig lazygit btm bottom glances
```

## Staying silent while you're at the terminal

The alert exists to yank you back when you've switched *away* from the terminal.
If you never left — you ran the command and watched it finish — popping a
full-screen window over the output you're already reading is just annoying.

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

## Dismissing the alert

- Click anywhere, or press `Esc`.
- It auto-dismisses after `IYF_AUTO_CLOSE` seconds — the progress bar along the
  bottom shows the time remaining.
- Opening a new alert first closes any previous alert window, so they don't
  stack up.
