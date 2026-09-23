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

The Swift tests use Swift Testing, which the Command Line Tools include (XCTest
needs a full Xcode). Under the Command Line Tools alone, SwiftPM's default build
system does not find Swift Testing's macro plugin, so name it explicitly:

```sh
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
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

The Python components are covered by component tests driven from bats: the
snooze daemon's loopback token trust boundary (`test/ada-snooze-daemon.bats`,
spawns the real daemon on a loopback port with a short deadline), everything
past that boundary in-process (`test/snooze_daemon_check.py`: snooze relaunch,
focus, preflight, failure paths), the Paseo poll/diff loop
(`test/paseo_diff_check.py`, monkeypatches `run_json`/`fire`/the clock to assert
finish/fail/seeding/dedupe/event-subset behavior), and the helpers that file
fakes (`test/paseo_helpers_check.py`, against stub `paseo`/`lsappinfo`). The
installer's interactive selector only runs on a terminal, so its tests type keys
into it through a pseudo-terminal (`test/pty_run.py`).

## Page Tests

`alert.html`'s in-page behavior (query-string decoding, success/failure states,
dismissal, the snooze bar, the feedback link) is covered by Playwright specs in
`test/*.spec.js`, which load the page off disk with the native bridge stubbed:

```sh
npm install && npx playwright install chromium   # one-time
npx playwright test
```

## Coverage

```sh
./run-tests.sh --coverage          # every suite, instrumented
ADA_COV_MISSING=1 ./run-tests.sh --coverage   # plus the uncovered lines per file
```

This runs the bats suite, `swift test`, and the Playwright specs against
instrumented code and prints per-file line coverage for the shell scripts, the
Python (including Python embedded in the shell scripts), the opencode plugin,
`alert.html`'s script, and the Swift sources, plus a total. Results go to `.cov/`
(gitignored); coverage.py is installed into `.cov/venv` and c8 comes from `npx`,
so neither becomes a dependency of ada. Swift and the page are skipped with a
note when their toolchain is missing. See `test/coverage/run.sh` for how each
language is instrumented, and keep the total at or above 80%.

When adding a script behavior, add or extend a `*.bats` file. Keep tests free of
real side effects: stub anything that opens a window, a socket, or a process,
and route any state through the per-test `TMPDIR`. For "no alert fired" checks
use `refute_file_appears` (the launcher backgrounds the helper, so an immediate
`[ ! -f ]` can race the async write).

## Before Opening A PR

- Run `swift test` when touching Swift code.
- Run `./run-tests.sh` when touching any shell script or the zsh hook.
- Run `npx playwright test` when touching `alert.html`.
- Run `./run-tests.sh --coverage` when adding behavior, and cover it.
- Run `./ada-install.sh --list` after installer or integration changes.
- Use `rg`, not `grep`, for repo search unless `rg` is unavailable.
- Keep `README.md` current for user-facing behavior.
- Update `REQUIREMENTS.md` whenever product behavior, integration contracts, or
  operational requirements change.
- Keep `CLAUDE.md` and `AGENTS.md` aligned when maintainer-agent guidance
  changes.

## Releasing (Homebrew)

`ada` ships through Homebrew, and the repo doubles as its own tap — the formula
lives at [`Formula/ada.rb`](Formula/ada.rb) and users install with
`brew tap janacm/ada https://github.com/janacm/ada && brew install ada`. Because
the tap tip (the default branch) is what users install, the released formula
must be committed to `main`.

To cut a release:

```sh
./release.sh vX.Y.Z          # tags, pushes the tag, and prints url + sha256
```

Then paste the printed `url` and `sha256` into `Formula/ada.rb`, commit, and push
`main`. Verify before announcing:

```sh
brew style Formula/ada.rb                                   # lint the formula
brew tap janacm/ada https://github.com/janacm/ada
brew install janacm/ada/ada && brew test janacm/ada/ada     # build + smoke test
```

The formula builds the native helpers from source and installs the repo tree into
`libexec`, so it never touches dotfiles; `ada-setup` (the installed wrapper around
`ada-install.sh`) does the integration wiring on demand.

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
