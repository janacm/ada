# Requirements

This is the living requirements record for `iyf`. Update it whenever a product,
integration, configuration, or operational requirement is added, changed, or
removed.

## Baseline

- `iyf` must run on macOS from a zsh shell hook for terminal command alerts.
- The user-facing documentation of record is `README.md`.
- Maintainer/debugging documentation is duplicated in `CLAUDE.md` and
  `AGENTS.md`; keep those files aligned when changing maintainer guidance.
- This file tracks durable behavior requirements. It should not duplicate every
  implementation detail, but it must capture externally visible behavior and
  cross-system contracts.

## Terminal Command Alerts

- `iyf.sh` must register zsh `preexec` and `precmd` hooks.
- `preexec` must record the command label and start time before execution.
- `precmd` must measure elapsed time, capture the exit code, and trigger an
  alert only when the elapsed time exceeds `IYF_THRESHOLD`.
- Commands whose basename appears in `IYF_IGNORE_CMDS` must not trigger alerts.
- When `IYF_SKIP_OWN_TERMINAL=1`, an alert must be suppressed if the terminal
  that ran the command is the frontmost macOS app at completion.
- Entries in `IYF_SKIP_WHEN_ACTIVE` must suppress alerts when the frontmost app
  bundle id exactly matches an entry or the app name contains an entry.
- If the frontmost app cannot be determined, `iyf` must err toward showing the
  alert.
- The manual `iyf ...` helper must trigger the shared alert path for testing.

## Shared Alert Launcher

- `iyf-show-alert.sh` is the canonical launcher used by terminal, Claude/Codex,
  and Paseo entry points.
- The alert must show the command or prompt label, formatted duration, exit
  status, auto-close countdown, and git repository badge when a repository can
  be resolved.
- Repository display must be resolved once by the launcher and preserved across
  snoozed relaunches.
- `IYF_REPO` must override repository display, including an explicit empty
  value to hide the badge.
- `IYF_REPO_DIR` must allow callers whose current directory is not the project
  directory to tell the launcher where to resolve the repository name.
- `IYF_ALERT_FILE` must allow callers to replace `alert.html` with another HTML
  file, including diagnostic pages.
- `IYF_AUTO_CLOSE` must control the alert auto-dismiss timeout, defaulting to a
  positive value when unset or invalid.
- `IYF_FOCUS_APP` and `IYF_FOCUS_APP_NAME` must allow click-anywhere dismissal
  to bring a source app forward and show a human-readable hint.
- Pressing `Esc`, clicking for a plain dismiss, or auto-close must dismiss the
  alert without requiring a snooze.
- Opening a new alert must close any previous dedicated alert browser instance
  so alert windows do not stack.

## Browser Window Behavior

- Chrome, Brave, and Edge alerts must open as browser `--app` windows when one
  of those browsers is installed.
- The alert must be an ordinary maximized window in the current Space, not a
  macOS native full-screen window in a new Space.
- The launcher must use a dedicated browser profile directory
  (`IYF_BROWSER_PROFILE`, default `~/.iyf-alert-profile`) so startup geometry
  flags are honored by a fresh browser process.
- The alert window geometry must be based on the primary display's visible
  frame, below the menu bar and above the Dock.
- On Safari fallback, the alert may open as a normal browser window or tab, but
  it must not intentionally enter native full-screen mode.

## Snooze And Focus

- `IYF_SNOOZE_MINUTES` must define the snooze button options, preserving an
  explicit empty value as "hide snooze buttons".
- Snooze and click-to-focus must use a detached `python3` loopback daemon because
  a sandboxed `file://` page cannot reliably outlive its window or activate
  another app later.
- The daemon must bind only to `127.0.0.1`, publish a random token to the alert
  URL, and ignore requests without that token.
- A snooze request must close the current alert and relaunch the same alert after
  the chosen delay.
- Snooze delays must be positive and no longer than 24 hours.
- A focus request must use the configured bundle id to bring the originating app
  forward.
- The daemon must self-exit after the alert decision window if the user dismisses
  normally, the beacon is blocked, or the alert auto-closes.
- If `python3` or the daemon script is unavailable, snooze and focus must degrade
  cleanly without breaking the base alert.

## Claude Code And Codex Hooks

- `iyf-claude-hook.sh` must support the shared Claude Code and Codex hook payload
  shape from stdin.
- A `UserPromptSubmit` event must record the start timestamp and prompt text,
  keyed by `session_id`.
- A `Stop` event must compute elapsed turn time and trigger the shared launcher
  only when the elapsed time meets `IYF_CLAUDE_THRESHOLD`.
- The hook must honor the same active-app suppression rules as terminal command
  alerts.
- The hook must set `IYF_REPO_DIR` from the payload `cwd` so the launcher can
  display the project repository even when the hook's own current directory is
  different.
- If a Codex `Stop` payload has a different or missing `session_id`, the hook
  must fall back to the most recent start stamp only while it is younger than
  `IYF_CLAUDE_STALE_MAX`.
- The hook must remove consumed start and prompt state after handling a stop.
- Debug logging must remain opt-in through `IYF_DEBUG_LOG`, `IYF_DEBUG_LOG_FILE`,
  or the `${TMPDIR}/iyf-claude-debug.on` sentinel.
- Invalid, missing, or unparseable hook payloads must exit quietly without
  breaking the caller.

## Paseo Watcher

- The Paseo integration must be a poller, not a provider hook, because Paseo
  runs agents through its own daemon runtime.
- `iyf-paseo-watch.py` must poll the supported CLI JSON surfaces:
  `paseo ls --json` and `paseo permit ls --json`.
- The watcher must synthesize a finished-turn alert on `running -> idle` when
  elapsed time meets `IYF_PASEO_THRESHOLD`.
- The watcher must synthesize a failed-turn alert on `running -> error`.
- The watcher must synthesize a permission alert for newly observed pending
  permission requests.
- `IYF_PASEO_EVENTS` must allow any subset of `finish`, `error`, and
  `permission`.
- The watcher must default to suppressing alerts while the Paseo desktop app is
  frontmost, and `IYF_PASEO_SKIP_WHEN_ACTIVE` must allow that default to be
  changed or disabled.
- The watcher must tolerate transient CLI or JSON failures by treating them as
  empty snapshots rather than crashing.
- The watcher must seed initial state before alerting so agents already running
  at watcher startup do not produce bogus elapsed durations.
- Permission alerts must be deduplicated while the same permission request
  remains pending.

## Paseo LaunchAgent

- `iyf-paseo-watch.sh install` must stage its runtime into a non-TCC-protected
  directory (`IYF_PASEO_INSTALL_DIR`, default `~/.local/share/iyf`) before
  loading launchd.
- The staged runtime must include `iyf-paseo-watch.sh`,
  `iyf-paseo-watch.py`, `iyf-show-alert.sh`, `iyf-snooze-daemon.py`, and
  `alert.html`.
- The LaunchAgent must run from the staged path so it does not fail when the
  live checkout is under `~/Documents`, `~/Desktop`, `~/Downloads`, or a symlink
  into those TCC-protected locations.
- The LaunchAgent must include a PATH that can find common `paseo`, `python3`,
  and system tool locations without relying on the user's interactive shell.
- `IYF_PASEO_ENV` must allow watcher configuration through an env file, defaulting
  to `paseo-watch.env` next to the running script.
- `iyf-paseo-watch.sh status` must report whether the job is loaded, whether a
  live poll loop is running, where the plist is, where the staged runtime is, and
  whether the watcher log is clean.
- `iyf-paseo-watch.sh uninstall` must unload the LaunchAgent and remove its
  plist.
- `iyf-paseo-watch.sh test` must fire one sample alert through the shared
  launcher.

## Dependencies And Degradation

- `zsh` is required for terminal command hook integration.
- `python3` is required for Claude/Codex hook JSON parsing, Paseo watcher polling,
  and snooze/focus support.
- The base terminal alert must still work without `python3`, but URL encoding,
  snooze, and click-to-focus may degrade.
- `paseo` is required only for the Paseo watcher and may be found on `PATH`,
  under `~/.local/bin`, or in the Paseo application bundle.
- Browser preference order must remain Chrome, Brave, Edge, then Safari fallback.

## Documentation Requirements

- `README.md` must explain user-facing installation, configuration, integrations,
  and behavior.
- `CLAUDE.md` and `AGENTS.md` must explain architectural gotchas, validation
  methods, and known dead ends for maintainer agents.
- This file must be updated when a durable requirement changes, even if the
  implementation and README changes are small.
- Docs-refresh automation should accept a no-op when the repo has no relevant
  changes and the docs still match implementation.

## Change Log

- 2026-06-15: Added the initial requirements baseline. No implementation commits
  were present after the previous docs-automation boundary; this captures the
  current shipped behavior so future docs runs have a requirements record to
  maintain.
