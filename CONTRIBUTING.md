# Contributing

Thanks for helping improve `iyf`. This project is a local-first macOS developer
utility, so changes should keep installation, rollback, and user trust boring.

## Development Setup

```sh
git clone https://github.com/janacm/iyf.git
cd iyf
swift build --product iyf-alert
swift test
./iyf-install.sh --list
```

To preview the alert without installing hooks:

```sh
IYF_AUTO_CLOSE=5 IYF_SNOOZE_MINUTES="" ./iyf-show-alert.sh "contribution test" "1s" 0
```

## Before Opening A PR

- Run `swift test` when touching Swift code.
- Run `./iyf-install.sh --list` after installer or integration changes.
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
core alert path. `iyf` should remain local-first by default.

## Security-Sensitive Changes

Changes that touch shell startup, LaunchAgents, agent hook config, prompt or
command capture, local loopback requests, or file staging need especially clear
tests and documentation. Prefer boring, auditable behavior over cleverness.
