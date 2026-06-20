# Contributing

Thanks for helping improve `ada`. This project is a local-first macOS developer
utility, so changes should keep installation, rollback, and user trust boring.

## Development Setup

```sh
git clone https://github.com/janacm/ada.git
cd ada
swift build --product ada-alert
swift test
brew install bats-core   # for the shell test suite
./ada-install.sh --list
```

To preview the alert without installing hooks:

```sh
ADA_AUTO_CLOSE=5 ADA_SNOOZE_MINUTES="" ./lib/ada-show-alert.sh "contribution test" "1s" 0
```

## Shell Tests

The shell scripts (launcher, Claude/Codex hook, Paseo watcher, installer) and
the zsh helper logic are covered by [BATS](https://github.com/bats-core/bats-core)
tests under `test/`:

```sh
brew install bats-core   # one-time
./run-tests.sh                       # whole suite
./run-tests.sh test/ada-install.bats # one file
```

The suite is hermetic. `test/test_helper.bash` gives every test a private
`TMPDIR`, PID file, and `HOME`, clears any `ADA_*` knobs that could bleed in from
your shell, disables the snooze daemon and click-to-focus, and wires in
`test/stubs/fake-ada-alert` so an "alert" just records the `file://` URL it would
open instead of spawning a window. Install-path tests point `HOME` at a temp dir
so they never touch your real `~/.zshrc`, `~/.claude/settings.json`, or
`~/.codex/hooks.json`. `test/stubs/` also doubles `lsappinfo`, `launchctl`,
`pgrep`, `pkill`, and `date` (the last lets `STUB_NOW` pin the clock so
elapsed-time thresholds are deterministic) so frontmost-app, launchd, and
process checks never touch the real machine.

Two Python-heavy components are covered by component tests driven from bats:
the snooze daemon's loopback token trust boundary
(`test/ada-snooze-daemon.bats`, spawns the real daemon on a loopback port with a
short deadline) and the Paseo poll/diff loop
(`test/paseo_diff_check.py`, monkeypatches `run_json`/`fire`/the clock to assert
finish/fail/seeding/dedupe/event-subset behavior).

When adding a script behavior, add or extend a `*.bats` file. Keep tests free of
real side effects: stub anything that opens a window, a socket, or a process,
and route any state through the per-test `TMPDIR`. For "no alert fired" checks
use `refute_file_appears` (the launcher backgrounds the helper, so an immediate
`[ ! -f ]` can race the async write).

## Before Opening A PR

- Run `swift test` when touching Swift code.
- Run `./run-tests.sh` when touching any shell script or the zsh hook.
- Run `./ada-install.sh --list` after installer or integration changes.
- Use `rg`, not `grep`, for repo search unless `rg` is unavailable.
- Keep `README.md` current for user-facing behavior.
- Update `REQUIREMENTS.md` whenever product behavior, integration contracts, or
  operational requirements change.
- Keep `CLAUDE.md` and `AGENTS.md` aligned when maintainer-agent guidance
  changes.

## Contribution Boundaries

Good contributions usually improve one of these surfaces:

- safer install, uninstall, and diagnostics
- macOS alert behavior
- terminal, Claude Code, Codex, or Paseo integration reliability
- focused documentation and troubleshooting
- narrow tests around command parsing, launcher behavior, or integration
  contracts

Please avoid adding telemetry, remote services, or network dependencies to the
core alert path. `ada` should remain local-first by default.

## Security-Sensitive Changes

Changes that touch shell startup, LaunchAgents, agent hook config, prompt or
command capture, local loopback requests, or file staging need especially clear
tests and documentation. Prefer boring, auditable behavior over cleverness.
