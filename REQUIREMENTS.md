# Requirements

This is the living requirements record for `ada`. Update it whenever a product,
integration, configuration, or operational requirement is added, changed, or
removed.

## Baseline

- `ada` must run on macOS from a zsh shell hook for terminal command alerts.
- `ada` must be distributed as open source under the MIT License.
- The user-facing documentation of record is `README.md`.
- Maintainer/debugging documentation is duplicated in `CLAUDE.md` and
  `AGENTS.md`; keep those files aligned when changing maintainer guidance.
- This file tracks durable behavior requirements. It should not duplicate every
  implementation detail, but it must capture externally visible behavior and
  cross-system contracts.

## Open Source Distribution

- The repository must include `LICENSE` with the MIT License text.
- `README.md` must link to the license, contribution guide, and security policy.
- `CONTRIBUTING.md` must document the basic development setup, validation
  commands, docs requirements, and security-sensitive contribution boundaries.
- `SECURITY.md` must explain how to report vulnerabilities privately and call
  out the security-sensitive local surfaces: shell startup, agent hooks,
  LaunchAgents, prompt or command capture, loopback control, and file staging.
- The public documentation must state that the core utility is local-first and
  does not send telemetry, prompts, command labels, repository names, or local
  paths to a remote service.
- Open-source distribution must not require publishing generated SwiftPM build
  output or local machine configuration.

## Homebrew Distribution

- The repository must double as its own Homebrew tap: `Formula/ada.rb` lives at
  the repo root so `brew tap janacm/ada https://github.com/janacm/ada` followed
  by `brew install ada` works without a separate `homebrew-ada` repository. The
  explicit tap URL is required because the repository is not named
  `homebrew-ada`.
- The formula must build the native renderer from source (`ada-alert`, plus the
  optional `ada-menubar`) and must not introduce a browser fallback.
- The formula must install the repository tree intact (into `libexec`) so each
  script keeps resolving its siblings by relative path, and must place the built
  helper where the launcher looks first so it never rebuilds into the read-only
  Cellar.
- The formula must not run the onboarding installer automatically. It must
  expose the installer as an `ada-setup` wrapper and direct users to run it via
  caveats.
- `brew install` and `brew upgrade` must write only under the Homebrew prefix;
  they must not modify user dotfiles, agent hook config, or an existing
  from-source install.
- Durable configuration written on behalf of a Homebrew install (the `~/.zshrc`
  source line, Claude/Codex hook commands, the Paseo LaunchAgent plist) must
  reference the version-stable `<prefix>/opt/ada/libexec` path, never the
  versioned Cellar directory that `brew upgrade` removes. The `ada-setup`
  wrapper must therefore exec `opt_libexec`, and scripts that write durable
  paths must map a Cellar path back to its `opt` equivalent when invoked
  directly.
- `brew upgrade ada` must be sufficient to move an existing install to the new
  version: no re-run of `ada-setup` and no re-staging may be required.
- The formula's `livecheck` must resolve versions from the repository's git tags,
  because releases are cut as tags only. A strategy that reads the GitHub
  releases API (`:github_latest`, `:github_releases`) reports no version at all.
- Releases must be produced with `release.sh`, which must refuse to run on a
  dirty tree, off the default branch, or with the default branch unpushed; then
  tag and push `vX.Y.Z`, compute the tarball `sha256`, rewrite `url`/`sha256` in
  `Formula/ada.rb`, and commit and push that bump to the default branch. The
  committed formula `url` and `sha256` must match the released GitHub tarball,
  and the formula on the default branch (the tap tip) is the version users
  install.

## Onboarding Installer

- `ada-install.sh` must provide the coworker-ready onboarding entry point for
  choosing which integrations trigger ADA.
- The installer must offer an interactive terminal selector when run from a TTY
  and a scriptable `--agents` path for non-interactive install flows.
- The selector must include Terminal commands, Claude Code, Codex, opencode, and
  Paseo as independently selectable integrations.
- The selector must move with the up/down arrow keys as well as `j`/`k` under
  macOS `/bin/bash` 3.2, which accepts only whole-second `read -t` timeouts.
- The shared alert runtime files, including the native `ada-alert` helper, must
  be treated as always included; the selector controls integration wiring, not
  whether the launcher exists.
- The installer must build or validate the native `ada-alert` helper before it
  installs integrations or fires a sample alert.
- The installer and `ada-paseo-watch.sh install` must rebuild a SwiftPM
  `.build/` helper that is older than `Package.swift` or any `Sources/**/*.swift`,
  so re-running either after a `git pull` never keeps or stages a helper that
  predates the checkout. A prebuilt `ada-alert` at the install root (Homebrew's)
  must never be rebuilt. A failed rebuild must warn and continue with the older
  helper rather than abort. `ADA_REBUILD_HELPER=0` disables the check.
- The installer must detect whether each integration target is available before
  selecting or installing it.
- The installer must be idempotent: re-running it must update existing managed
  ADA wiring without duplicating shell source blocks or hook entries.
- Shell setup must use a clearly marked managed block in `~/.zshrc`.
- Claude Code setup must merge `UserPromptSubmit` and `Stop` hooks into
  `~/.claude/settings.json` without removing unrelated hooks.
- Codex setup must merge `UserPromptSubmit` and `Stop` hooks into
  `~/.codex/hooks.json` without removing unrelated hooks.
- The installer must verify that the opencode plugin module exists before
  writing a shim that imports it, since a dangling shim fails inside opencode
  rather than in ada.
- opencode setup must write a plugin shim named `ada.js` into opencode's global
  plugin directory. It must resolve that directory by asking the opencode CLI
  (`opencode debug paths`) before falling back to the XDG default, so a
  relocated config root is honored.
- The opencode shim must re-export the plugin from the ada install directory
  rather than containing the plugin logic, so editing the plugin needs no
  re-install and only one line changes if ada moves.
- opencode setup must back up a pre-existing `ada.js` that ada did not write,
  and must be idempotent: re-running must leave exactly one shim.
- JSON hook setup must write a timestamped backup before changing an existing
  settings file.
- Paseo setup through the installer must delegate to `ada-paseo-watch.sh install`
  so the LaunchAgent staging behavior stays centralized.
- The installer must support `--list`, `--dry-run`, and `--no-test` for
  validation, documentation, and automation.
- `--status` must report, for each integration, whether it is wired and
  working (`ok`, `off`, `warn`, `unavailable`) from the markers the installer
  writes: the managed `~/.zshrc` block or a `source …/ada.sh` line, both
  Claude/Codex hooks, ada's opencode shim, and the Paseo LaunchAgent (running,
  loaded, or neither). A wired path that no longer exists must be a warning.
  The report must live in `lib/ada-status.sh`, which the installer sources for
  its finders, so the menu bar can run it from a stage that has no installer.
  With `ADA_STATUS_SKIP_PROTECTED=1` it must not check paths under `$HOME` or
  `/Volumes`, which a LaunchAgent may not be allowed to look at.

## Terminal Command Alerts

- `ada.sh` must register zsh `preexec` and `precmd` hooks.
- `preexec` must record the command label and start time before execution.
- `precmd` must measure elapsed time, capture the exit code, and trigger an
  alert only when the elapsed time exceeds `ADA_THRESHOLD`.
- Commands whose basename appears in `ADA_IGNORE_CMDS` must not trigger alerts.
- When `ADA_SKIP_OWN_TERMINAL=1`, an alert must be suppressed if the terminal
  that ran the command is the frontmost macOS app at completion.
- Entries in `ADA_SKIP_WHEN_ACTIVE` must suppress alerts when the frontmost app
  bundle id exactly matches an entry or the app name contains an entry.
- If the frontmost app cannot be determined, `ada` must err toward showing the
  alert.
- The manual `ada ...` helper must trigger the shared alert path for testing.

## Shared Alert Launcher

- `ada-show-alert.sh` is the canonical launcher used by terminal, Claude/Codex,
  opencode, and Paseo entry points.
- `ada-notify.sh` is the shared layer between an integration and the launcher: it
  owns frontmost-app suppression and duration formatting for callers that are not
  the zsh hook. A new integration must source or exec it rather than adding
  another copy of that logic.
- The alert must show the command or prompt label, formatted duration, exit
  status, auto-close countdown, and git repository badge when a repository can
  be resolved.
- Labels and badge text containing URL-reserved characters must display as
  human-readable text, not transport encoding artifacts.
- Repository display must be resolved once by the launcher and preserved across
  snoozed relaunches.
- `ADA_REPO` must override repository display, including an explicit empty
  value to hide the badge.
- `ADA_REPO_DIR` must allow callers whose current directory is not the project
  directory to tell the launcher where to resolve the repository name.
- `ADA_ALERT_FILE` must allow callers to replace `alert.html` with another HTML
  file, including diagnostic pages.
- When `ADA_ALERT_FILE` is unset, `alert.html` must be resolved relative to the
  running script, so the alert renders from any install location (a checkout,
  `~/.ada`, the Homebrew prefix, or the staged Paseo runtime). No entry point may
  depend on `~/.ada` existing; that path may only be a last-resort fallback.
- `ADA_AUTO_CLOSE` must control the alert auto-dismiss timeout, defaulting to a
  positive value when unset or invalid.
- `ADA_FOCUS_APP` and `ADA_FOCUS_APP_NAME` must allow click-anywhere dismissal
  to bring a source app forward and show a human-readable hint.
- Pressing `Esc`, clicking for a plain dismiss, or auto-close must dismiss the
  alert without requiring a snooze.
- Opening a new alert in native mode must close any previous native alert helper
  process so alert windows do not stack.
- The alert must show a corner feedback note inviting users to reach out (to
  support the project, request a different agent integration, or report a
  misfired pop-up); its link must open in the user's default browser rather than
  navigating the alert's own WebView away.

## Native Window Behavior

- The SwiftPM package must expose an `ada-alert` executable product.
- The SwiftPM package must expose an optional `ada-menubar` executable product
  that runs as a native macOS menu bar status item.
- The menu bar helper must not be an alert renderer or a replacement for the
  terminal, Claude/Codex, or Paseo integrations; it may provide convenience
  actions such as firing a sample alert and opening the ADA folder.
- The menu bar helper must trigger alerts through `ada-show-alert.sh` so it
  shares the same native-only rendering path and configuration as every other
  entry point.
- The menu bar helper must find the ada install from `ADA_HOME` when it is set,
  and otherwise from its executable's resolved path, because Homebrew runs it
  through a `bin/` symlink: the folder holding an `.app` bundle, the package root
  above a SwiftPM `.build` directory, or the executable's own directory. A
  directory inside a Homebrew keg must be mapped to its version-stable `opt`
  path, because the helper keeps the path while `brew upgrade` deletes the keg.
  It must run `lib/ada-show-alert.sh` from that install.
- The native helper must act on an `adaOpen` message only when its body is a
  string that parses as an `http` or `https` URL with a host, scheme compared
  case-insensitively, so the page cannot launch any other scheme. That rule must
  live in `ADAAlertCore`, outside the AppKit delegate, where it is unit-tested.
- The launcher must use the native `ada-alert` helper when it is executable at
  `ADA_NATIVE_ALERT`, or as `ada-alert` or in the SwiftPM `.build/release` or
  `.build/debug` output of the ada install, one level above
  `lib/ada-show-alert.sh`.
- The launcher must fail closed when `ada-alert` is missing or not executable;
  it must not open Chrome, Brave, Edge, Safari, or any other browser as a
  fallback.
- The native helper must render the configured `ADA_ALERT_FILE` URL in a WebKit
  view without opening Chrome, Brave, Edge, or Safari.
- The alert must be an ordinary maximized window in the current Space, not a
  macOS native full-screen window in a new Space.
- The native alert window geometry must be based on the primary display's visible
  frame, below the menu bar and above the Dock.
- Pressing `Esc`, clicking, auto-close, and snooze must close the native helper
  process instead of relying on browser `window.close()` behavior.
- The native WebKit renderer must bridge snooze/focus requests to the existing
  loopback daemon so snooze and click-to-focus behavior remains available.

## Snooze And Focus

- `ADA_SNOOZE_MINUTES` must define the snooze button options, preserving an
  explicit empty value as "hide snooze buttons".
- The snooze options must start collapsed behind a single "Snooze" toggle that
  reveals them on click and hides them on a second click, without dismissing the
  alert.
- The revealed options must include a pin toggle. While pinned, every later
  alert (including snoozed relaunches) must open with the options already
  expanded; unpinning restores the collapsed default. The native helper must
  persist the pin in user defaults (suite `com.ada.alert`, key `snoozePinned`),
  inject it into the page before the page's script runs, and accept only a
  boolean from the page. Without the native bridge the pin may last for the
  current alert only.
- The snooze bar must offer a "Custom" option that reveals a minutes input only
  once clicked; submitting it must request a snooze for the entered duration,
  subject to the same positive/≤24h bound as the preset buttons.
- Snooze and click-to-focus must use a detached `python3` loopback daemon because
  a sandboxed `file://` page cannot reliably outlive its window or activate
  another app later.
- The daemon must bind only to `127.0.0.1`, publish a random token to the alert
  URL, and ignore requests without that token.
- A snooze request must close the current alert and relaunch the same alert after
  the chosen delay.
- Snooze delays must be positive and no longer than 24 hours.
- A focus request must use the configured bundle id to bring the originating app
  forward, or, when `ADA_CLICK_URL` is set, `open` that URL instead (which both
  activates the target app and deep-links into it). The URL must take precedence
  over the bundle id, and a snooze relaunch must preserve it.
- The daemon must self-exit after the alert decision window if the user dismisses
  normally, the beacon is blocked, or the alert auto-closes.
- If `python3` or the daemon script is unavailable, snooze and focus must degrade
  cleanly without breaking the base alert.

## Per-Session Mute

- An alert whose integration names its session (`ADA_SESSION_KEY`) must offer a
  "Mute this <kind>" button. Muting must silence every later alert for that
  session: finished turns, errors, permission prompts, and a pending snooze
  relaunch. Other sessions must keep alerting.
- Claude Code / Codex (`claude-<session id>`), opencode (`opencode-<session
  id>`), Paseo (`paseo-<agent id>`) and the zsh hook (`zsh-<pid>-<start time>`,
  one key per interactive shell) must all set a key. The terminal `ada` test
  command must not, so it keeps working in a muted shell.
- The mute check must live only in `ada-show-alert.sh`, the launcher every
  integration reaches, and must run before the helper lookup or any spawn. No
  integration may reimplement it.
- A key must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`, because it names a file
  under `ADA_MUTE_DIR` (default `$TMPDIR/ada-muted`). An invalid key must get no
  button and no marker, never a path outside that directory.
- A mute must expire after `ADA_MUTE_MAX_AGE` seconds (default 86400; `0` means
  until cleared), and the launcher must prune expired markers.
- The button must go through the existing loopback daemon (`GET
  /<token>/mute`), which writes the marker the launcher named in
  `ADA_MUTE_FILE` and neither relaunches nor focuses. Without `python3` the
  button must not render.
- `ADA_MUTE_BUTTON=0` must hide the button while leaving existing mutes in force.
- `lib/ada-mute.sh list|clear [key...]|add <key>` must list and undo mutes, and
  Homebrew must expose it as `ada-mute`.
- A launcher running without `ada-mute.sh` beside it must still alert, with no
  muting.

## Global Pause

- A pause must silence every alert from every integration, including a pending
  snooze relaunch that comes due while paused, until it ends or is resumed.
- The pause check must live only in `ada-show-alert.sh`, beside the mute check
  and before it. No integration may reimplement it.
- The pause state must be one file (`ADA_PAUSE_FILE`, default
  `$TMPDIR/ada-paused`) holding one decimal integer: the epoch second the pause
  ends, or `0` for until resumed. Writers must replace it atomically (temp file
  and rename).
- A file at that path that is not a pause file (not a regular file, a symlink,
  or not a number) must pause nothing and must never be overwritten or deleted.
- The launcher must only read the pause file. An expired pause lets alerts
  through; only the CLI deletes the file, so a launcher cannot race a new pause
  being renamed into place.
- Alerts the user asked for must show while paused: the terminal `ada` command,
  the installer's sample alert, `ada-paseo-watch.sh test`, and the menu bar's
  Test Alert pass `ADA_IGNORE_PAUSE=1`. zsh must pass it on the launcher's
  command line only, never into the interactive shell.
- When `TMPDIR` is unset, the launcher must use `getconf DARWIN_USER_TEMP_DIR`
  (then `/tmp`), so a stripped environment still finds the pause and the mute
  markers that terminals and launchd jobs see under the per-user temp dir.
- `lib/ada-pause.sh <minutes>|until <epoch>|forever|resume|status` must set,
  clear and describe the pause, and Homebrew must expose it as `ada-pause`.
- A launcher running without `ada-pause.sh` beside it must still alert, with no
  pausing.

## Alert History

- The launcher must append one line to the history (`ADA_HISTORY_FILE`, default
  `$TMPDIR/ada-history.tsv`) for every alert it decides on: shown, or dropped
  by a pause or a mute. A snooze relaunch must be flagged as one.
- Each line must be tab-separated, version first: `1 epoch outcome snoozed key
  kind label duration code repo focus_app focus_app_name click_url`. Tabs and
  line breaks in a field must become spaces, and a field must be cut to 200
  characters (the click URL to 500). Readers must skip lines of another version
  and ignore columns past the last one they know.
- A dropped alert must not resolve the repo (that runs git), so it records
  `ADA_REPO` only when it inherited one.
- The file must be created mode 600 and never written through a symlink or when
  another user owns it. It must be trimmed to the newest `ADA_HISTORY_MAX`
  lines (default 50; `0` keeps none) once it reaches twice that.
- A history failure must never cost the alert, and a launcher without
  `ada-history.sh` beside it must still alert.
- `lib/ada-history.sh list|clear` must print and forget the history.
- A mute marker must hold the label of the alert it was muted from, one line of
  at most 200 characters, mode 600; `ada-mute list` must show it and `ada-mute
  add <key> [label]` must accept one. The launcher must keep using only the
  marker's name and mtime.

## Claude Code And Codex Hooks

- `ada-claude-hook.sh` must support the shared Claude Code and Codex hook payload
  shape from stdin.
- A `UserPromptSubmit` event must record the start timestamp and a displayable
  label for the prompt, keyed by `session_id`.
- The alert label must be human-readable even when the agent injected the prompt
  itself. `UserPromptSubmit` also fires for agent-generated messages (a
  background task finishing, a slash command, a system reminder), which arrive as
  raw markup blocks, and none of that markup or its ids may reach the alert:
  - a block carrying a one-line `<summary>` must be labelled from that summary;
  - a slash command must be labelled with its command name and arguments;
  - any other such block must be reduced to the prose sitting directly inside
    it, with nested metadata elements removed whole rather than unwrapped, and
    must fall back to the generic agent label when no prose remains.
- A prompt only counts as agent-injected when it is wholly markup AND its outer
  tag name contains a hyphen, which distinguishes a harness block from an HTML
  or JSX element name.
- Prompt sanitizing must not alter a prompt the user actually typed, including
  one that begins with markup, one that is entirely HTML markup, and one that
  embeds a `<details><summary>` block before the user's question. Display labels
  must collapse whitespace to one line.
- A paste that the Claude desktop app wraps as `<pasted_content id="…">…
  </pasted_content id="…">` must not show its tags or id on the alert. When the
  prompt also has typed text, each paste must collapse to `[pasted text]` so the
  typed words lead the label; a prompt that is only a paste must show the pasted
  text. The closing tag repeats the id, so matching must accept attributes on
  both tags, and an unclosed paste tag must be dropped.
- A prompt that is only a paste must show the pasted text without the
  injected-block sanitizing, even when the pasted text is itself harness
  markup. Paste handling must stay linear in the prompt's length, because it
  runs inside the synchronous `UserPromptSubmit` hook.
- Whitespace collapsing must apply to display labels only. `cwd` and
  `transcript_path` must survive byte-for-byte, because a path containing a
  double space would otherwise break the repo badge and the turn-error
  detection.
- The opt-in debug breadcrumb must keep logging the raw prompt rather than the
  label, because diagnosing a newly introduced injected shape depends on it.
- A `Stop` event must compute elapsed turn time and trigger the shared launcher
  only when the elapsed time meets `ADA_CLAUDE_THRESHOLD`.
- The hook must honor the same active-app suppression rules as terminal command
  alerts.
- The hook must set `ADA_REPO_DIR` from the payload `cwd` so the launcher can
  display the project repository even when the hook's own current directory is
  different.
- On a `Stop` event, the hook must make the alert click open that turn's
  conversation in the Claude macOS app via the `claude://resume?session=<id>`
  deep link (passed through `ADA_CLICK_URL`). It must wire this only for genuine
  Claude Code sessions — the resolved session id must be a UUID and have a
  transcript at `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/<id>.jsonl` — so
  Codex turns, which share the hook but cannot be imported into Claude.app, get
  no link rather than a "couldn't open session" error.
- If a Codex `Stop` payload has a different or missing `session_id`, the hook
  must fall back to the most recent start stamp only while it is younger than
  `ADA_CLAUDE_STALE_MAX`.
- The hook must remove consumed start and prompt state after handling a stop.
- Debug logging must remain opt-in through `ADA_DEBUG_LOG`, `ADA_DEBUG_LOG_FILE`,
  or the `${TMPDIR}/ada-claude-debug.on` sentinel.
- Invalid, missing, or unparseable hook payloads must exit quietly without
  breaking the caller.

## opencode Plugin

- The opencode integration must be an opencode plugin, not a hook config and not
  a poller, because opencode exposes no "run a command on agent event" hook.
- The plugin must derive turn boundaries from opencode's own surfaces: the
  `chat.message` hook for the start of a turn (recording the prompt text) and the
  `session.idle` event for the end of it.
- A finished turn must alert only when elapsed time meets
  `ADA_OPENCODE_THRESHOLD`.
- A `session.error` must alert regardless of elapsed time, and a failed turn must
  produce exactly one alert even though the error event precedes the idle event.
- A user-initiated abort (`MessageAbortedError`) must not alert, and must also
  suppress the finish alert for that turn: the user was at the keyboard to cause
  it. This suppression is turn lifecycle, not part of the error category, so it
  must apply even when `error` is absent from `ADA_OPENCODE_EVENTS`.
- An error the plugin cannot describe (including an absent `error` object, which
  the SDK types permit) must leave the turn untouched rather than silence it, so
  a long turn still produces its finish alert.
- Per-session state must be released when a session is deleted, so a long-lived
  `opencode serve` does not accumulate state for the life of the process.
- Alert labels must be clipped after their prefix is composed, matching the
  guarantee `ada-claude-hook.sh` makes for its own labels.
- A permission pattern must render its first entry whether opencode sends
  `patterns` or `pattern`, and whether the value is a string or a list.
- A retryable API error must still alert. opencode retries internally and
  reports those as `session.status retry`, so an error that reaches
  `session.error` has already ended the turn.
- Error labels must stay readable when the error carries no message: an output
  length error must not surface as a bare class name, an auth error must name
  the provider, and an API error must surface its status code.
- A `session.error` with no session id must still alert, because it describes a
  failure that happened before a turn could be attributed.
- A pending permission must alert without a duration and must not consume the
  turn state, so the finished-turn alert still fires afterwards.
- Permission alerts must be deduplicated by permission id.
- Both the `permission.asked` and `permission.updated` event spellings must be
  handled: the shipped opencode SDK types and the opencode binary disagree, and
  either may change across versions.
- Sub-sessions (a session with a `parentID`, i.e. a subagent) must never alert:
  their idle event is not the user's turn ending.
- `ADA_OPENCODE_EVENTS` must allow any subset of `finish`, `error`, and
  `permission`, and an empty value must disable the integration without
  uninstalling it.
- The alert must be spawned detached, because `opencode run` exits immediately
  after a turn ends and the alert has to outlive it.
- A failure to launch the alert must never break the opencode session: a missing
  or unexecutable notifier must degrade to no alert.
- The plugin must resolve `ada-notify.sh` relative to its own file so it works
  from a checkout, `~/.ada`, or the Homebrew prefix with no baked path.
- The plugin must honor the same active-app suppression rules as the other
  integrations, which it inherits by delegating to `ada-notify.sh`.
- Alerts must show the session's own directory as the repository badge, so one
  opencode server serving several projects still labels each alert correctly.
- Debug logging must remain opt-in through `ADA_DEBUG_LOG`, `ADA_DEBUG_LOG_FILE`,
  or a `${TMPDIR}/ada-opencode-debug.on` sentinel.

## Paseo Watcher

- The Paseo integration must be a poller, not a provider hook, because Paseo
  runs agents through its own daemon runtime.
- `ada-paseo-watch.py` must poll the supported CLI JSON surfaces:
  `paseo ls --json` and `paseo permit ls --json`.
- The watcher must synthesize a finished-turn alert on `running -> idle` when
  elapsed time meets `ADA_PASEO_THRESHOLD`.
- The watcher must synthesize a failed-turn alert on `running -> error`.
- The watcher must synthesize a permission alert for newly observed pending
  permission requests.
- `ADA_PASEO_EVENTS` must allow any subset of `finish`, `error`, and
  `permission`.
- The watcher must default to suppressing alerts while the Paseo desktop app is
  frontmost, and `ADA_PASEO_SKIP_WHEN_ACTIVE` must allow that default to be
  changed or disabled.
- The watcher must tolerate transient CLI or JSON failures by treating them as
  empty snapshots rather than crashing.
- The watcher must seed initial state before alerting so agents already running
  at watcher startup do not produce bogus elapsed durations.
- Permission alerts must be deduplicated while the same permission request
  remains pending.

## Paseo LaunchAgent

- `ada-paseo-watch.sh install` must stage its runtime into a non-TCC-protected
  directory (`ADA_PASEO_INSTALL_DIR`, default `~/.local/share/ada`) before
  loading launchd, except when it is already running from a Homebrew install
  (under `$(brew --prefix)/opt`), which is both outside every TCC-protected
  location and version-stable. In that case it must run in place so that
  `brew upgrade` refreshes the watcher, and must fail rather than load a
  LaunchAgent if any runtime file or the native helper is missing.
- The LaunchAgent must set `ADA_PASEO_ENV` to the env file under the per-user
  install directory in both modes, so watcher configuration survives a
  `brew upgrade` replacing the Homebrew-managed tree.
- The staged runtime must be every file in `ADA_RUNTIME_FILES`
  (`lib/ada-stage.sh`), one list shared by every LaunchAgent that stages into
  the same directory: today `ada-paseo-watch.sh`, `alert.html` and, under
  `lib/`, `ada-paseo-watch.py`, `ada-show-alert.sh`, `ada-snooze-daemon.py`,
  `ada-mute.sh`, `ada-pause.sh`, `ada-history.sh`, `ada-notify.sh` (which
  `ada-mute.sh list` and `ada-pause.sh` source) and `ada-stage.sh`. The
  installer, `ada.sh` and the hook and plugin scripts must never be staged.
- Staging must replace each file by renaming a temp copy into place, never by
  rewriting it, because a staged binary may be running and a staged script
  may be mid-read. It must write `stage-info` (`source`, `rev`, `dirty`,
  `staged_at`, `by`) beside the runtime. Staging must mirror the dev-checkout layout — the front door
  (`ada-paseo-watch.sh`) and `alert.html` at the top, the internal scripts under
  `lib/` — so every `lib/`-relative reference resolves identically whether run
  from a checkout or from the staged LaunchAgent.
- `ada-paseo-watch.sh install` must stage a native helper executable. If
  `ada-alert` is not already built, it may build it with SwiftPM when the source
  checkout contains `Package.swift`; if it cannot stage the helper, install must
  fail instead of relying on a browser fallback.
- The LaunchAgent must run from the staged path so it does not fail when the
  live checkout is under `~/Documents`, `~/Desktop`, `~/Downloads`, or a symlink
  into those TCC-protected locations.
- The LaunchAgent must include a PATH that can find common `paseo`, `python3`,
  and system tool locations without relying on the user's interactive shell.
- `ADA_PASEO_ENV` must allow watcher configuration through an env file, defaulting
  to `paseo-watch.env` in the per-user install directory regardless of where the
  invoked script lives, so a manual `test`, `status`, or foreground `run` reads
  the same configuration the LaunchAgent does.
- `ada-paseo-watch.sh status` must report whether the job is loaded, whether a
  live poll loop is running, where the plist is, which runtime the plist actually
  points at (flagging when it differs from the invoked source tree), and whether
  the watcher log is clean.
- `ada-paseo-watch.sh uninstall` must unload the LaunchAgent and remove its
  plist.
- `ada-paseo-watch.sh test` must fire one sample alert through the shared
  launcher.

## Dependencies And Degradation

- `zsh` is required for terminal command hook integration.
- `python3` is required for Claude/Codex hook JSON parsing, Paseo watcher polling,
  and snooze/focus support.
- The base terminal alert must still work without `python3`, but URL encoding,
  snooze, and click-to-focus may degrade.
- SwiftPM is required to build the native `ada-alert` helper.
- A browser is not a runtime dependency. Missing Chrome, Brave, Edge, or Safari
  must not affect `ada` when the native helper is built.
- `paseo` is required only for the Paseo watcher and may be found on `PATH`,
  under `~/.local/bin`, or in the Paseo application bundle.
- `opencode` is required only for the opencode integration. The plugin runs
  inside opencode's own JavaScript runtime, so it adds no separate Node
  dependency; the installer uses the `opencode` CLI only to locate the config
  root.

## Documentation Requirements

- `README.md` must explain user-facing installation, configuration, integrations,
  and behavior.
- `README.md` must document Homebrew as the primary install method and keep the
  from-source installer path available as an alternative.
- `README.md` must document the installer selector as the primary onboarding
  path and keep manual hook examples available for troubleshooting.
- `CLAUDE.md` and `AGENTS.md` must explain architectural gotchas, validation
  methods, and known dead ends for maintainer agents.
- This file must be updated when a durable requirement changes, even if the
  implementation and README changes are small.
- Docs-refresh automation should accept a no-op when the repo has no relevant
  changes and the docs still match implementation.

## Test Coverage

- `./run-tests.sh --coverage` must measure line coverage for every language ada
  ships: the shell scripts, `ada.sh` (zsh), the Python components, Python
  embedded in the shell scripts, the opencode plugin, `alert.html`'s inline
  script, and the Swift sources. It must print per-file and total numbers.
- Instrumentation must stay in the test harness. Coverage must not require a
  change to how any shipped script runs outside a coverage run.
- A language whose coverage data was collected but could not be converted into
  a report must fail the run, not drop out of the total.
- Total line coverage reported by `./run-tests.sh --coverage` should stay at or
  above 80%.

## Change Log

- 2026-09-24: `ada-setup --status` reports which integrations are wired and
  whether each still works, from the markers the installer writes, including
  hooks that point at a deleted checkout. The report and the finders it shares
  with the installer moved to `lib/ada-status.sh`; the Paseo watcher's staging
  moved to `lib/ada-stage.sh`, which now replaces staged files by rename and
  records where the stage came from, so a second LaunchAgent (the menu bar) can
  share both.
- 2026-09-24: The launcher keeps an alert history for the menu bar's Recent
  Alerts: one line per alert, shown or dropped by a pause or a mute, with the
  click target so a dropped Claude turn is still one click away. Mute markers
  now hold the label of the alert they were muted from, which `ada-mute list`
  shows.
- 2026-09-24: Alerts can be paused. `ada-pause <minutes>|until <epoch>|forever`
  silences every integration until the pause ends or `ada-pause resume`, the
  switch the menu bar's Pause menu will use. The check sits in
  `ada-show-alert.sh` beside the mute check; test alerts pass
  `ADA_IGNORE_PAUSE=1`. With `TMPDIR` unset the launcher now asks `getconf
  DARWIN_USER_TEMP_DIR` instead of falling back to `/tmp`, where it could not
  see a pause, or mutes set from alerts that had `TMPDIR`. The Paseo stage gains
  `ada-pause.sh` and `ada-notify.sh`; without the latter a staged `ada-mute.sh
  list` printed errors and a blank "muted  ago" for every key.
- 2026-09-24: Alerts can mute their session. A **Mute this conversation** (or
  session, agent, terminal) button under the snooze row silences every later
  alert for that Claude Code / Codex conversation, opencode session, Paseo agent
  or zsh shell for 24 hours (`ADA_MUTE_MAX_AGE`). Each integration passes an
  `ADA_SESSION_KEY`; `ada-show-alert.sh` drops alerts for a muted key, and
  `ada-mute list|clear` undoes it.
- 2026-09-24: `ada-install.sh` and `ada-paseo-watch.sh install` rebuild a
  `.build/` helper older than the Swift sources. Both used any existing helper,
  so after a `git pull` a Paseo re-stage copied the old binary next to the new
  `alert.html`, and the snooze pin (a new `adaSnoozePin` handler) did nothing.
  The check (`__ada_helper_stale`) is duplicated in both scripts, like
  `__ada_stable_dir`, and the test suite sets `ADA_REBUILD_HELPER=0` so a run
  never starts a real build in the developer's checkout.
- 2026-09-24: The snooze delays collapse behind a **Snooze** toggle, with a
  **Pin open** option that keeps them expanded on every alert. The pin lives in
  user defaults (`com.ada.alert` / `snoozePinned`) because each alert is a fresh
  `file://` page in a fresh helper process. The native helper injects it as
  `window.adaPrefs` and saves changes from a new `adaSnoozePin` handler, and the
  boolean-only rule for that message is in `ADAAlertCore` (`SnoozePreference`).
  The snooze bar also stops rendering its label when snooze is disabled: its
  `display:flex` had been overriding `[hidden]`.
- 2026-09-23: The menu bar's **Test Alert** finds the launcher again. It looked
  for `ada-show-alert.sh` at the install root, but the launcher moved to `lib/`
  on 2026-06-18, so every documented layout showed "Missing launcher"; a SwiftPM
  build also resolved to `.build/release`, and Homebrew's `bin/` symlink to
  `bin/`. The lookup (`InstallDirectory`) now resolves symlinks and maps a
  Homebrew keg to `opt`, and it and the `adaOpen` http(s)-only rule
  (`ExternalLink`, which now also requires a host) live in `ADAAlertCore` with
  Swift Testing coverage.
- 2026-09-23: Line coverage is measured. `./run-tests.sh --coverage` instruments
  every suite (bats, `swift test`, Playwright) and reports 87.1% of 1751
  statements: shell 96.1% (Python embedded in the scripts included), Python
  98.9%, the opencode plugin 95.7%, `alert.html`'s script 100%, Swift 22.6%.
  Nearly all of what remains is the AppKit window and menu code in the two Swift
  `main.swift` files. New tests cover `release.sh`, the installer's selector and
  preflight checks, Paseo install/uninstall/status and the real poll loop, the
  snooze relaunch, the frontmost-app checks, the page's decoding and dismissal
  paths, and the turn-ending API-error alert, which had no test at all.
- 2026-09-23: The installer's up/down arrow keys work. The selector read the rest
  of an arrow sequence with `read -t 0.05`, which macOS `/bin/bash` 3.2 rejects,
  so only `j`/`k` ever moved the cursor.
- 2026-09-23: The Swift tests moved from XCTest to Swift Testing, so `swift test`
  runs under the Command Line Tools alone, where XCTest does not exist.
- 2026-09-23: Pastes from the Claude desktop app no longer leak into alert
  labels. The app wraps a paste as `<pasted_content id="c339">…</pasted_content
  id="c339">`, which the injected-block sanitizer skips (underscore, not hyphen,
  and it sits mid-prompt), so an alert read `create a plan for <pasted_content
  id="c339"> hey …`. Each paste now collapses to `[pasted text]` beside typed
  text, and a paste-only prompt shows the pasted text without the injected-block
  rules. Tags are paired in one linear pass, so unclosed tags can't stall the hook.
- 2026-09-17: Claude Code / Codex alert labels are now derived from the prompt
  rather than printing it verbatim. `UserPromptSubmit` also fires for messages
  the agent injects, so a turn that began with a background-task notification
  rendered an alert reading `<task-notification><task-id>…<tool-use-id>…` with no
  human-readable content. Those blocks are now labelled from their `<summary>`,
  slash commands from their name and arguments, and typed prompts are untouched.

- 2026-09-17: Added the opencode integration. opencode has no hook config, so it
  ships as an opencode plugin (`lib/ada-opencode-plugin.mjs`) installed as a
  one-line `.js` shim in opencode's plugin directory; it alerts on
  `session.idle`, `session.error` and `permission.asked`, and ignores subagent
  sessions. Frontmost-app suppression and duration formatting moved out of
  `ada-claude-hook.sh` into a new shared `lib/ada-notify.sh` so the hook and the
  plugin cannot drift.

- 2026-08-20: Fixed Homebrew installs. `alert.html` is now resolved relative to
  the running script instead of a hardcoded `~/.ada`, which does not exist under
  Homebrew and rendered a blank alert window. Durable wiring (zshrc line, agent
  hooks, Paseo plist) now points at the version-stable `opt/ada/libexec` rather
  than the versioned Cellar path that `brew upgrade` deletes. The Paseo watcher
  runs in place for Homebrew installs (no stale stage) and pins its env file to
  `~/.local/share/ada` for manual invocations as well as the LaunchAgent, so
  `test` can no longer disagree with the running watcher. `release.sh` now
  rewrites and pushes the formula bump itself instead of printing fields to
  paste. The formula reads versions from git tags, since no GitHub releases are
  published.
- 2026-06-19: Added Homebrew as the primary distribution method and cut the
  first formula release (`v0.2`). The repository doubles as its own tap
  (`Formula/ada.rb` at root, installed via `brew tap janacm/ada <url>`); the
  formula builds the native helpers into `libexec`, exposes the onboarding
  installer as `ada-setup`, and writes only under the Homebrew prefix. Releases
  are cut with `release.sh` (tag, push, sha256).
- 2026-06-19: Clicking a Claude Code alert now opens that turn's conversation in
  the Claude macOS app via the `claude://resume?session=<id>` deep link. Added a
  generic `ADA_CLICK_URL` click target (precedence over `ADA_FOCUS_APP`) wired
  through the launcher and snooze/focus daemon; the hook sets it only for real
  Claude Code sessions (UUID id with an on-disk transcript).
- 2026-06-17: Added open-source distribution requirements: MIT license,
  contribution guide, security policy, and local-first public documentation.
- 2026-06-17: Added an optional native SwiftPM `ada-menubar` status item for
  convenience actions without changing the canonical alert launcher.
- 2026-06-15: Added the onboarding installer requirement: users can select
  Terminal, Claude Code, Codex, and Paseo integrations through
  `ada-install.sh`, with scriptable and dry-run modes.
- 2026-06-15: Made native SwiftPM `ada-alert` the only alert renderer; removed
  all browser fallback requirements.
- 2026-06-15: Added the initial requirements baseline. No implementation commits
  were present after the previous docs-automation boundary; this captures the
  current shipped behavior so future docs runs have a requirements record to
  maintain.
