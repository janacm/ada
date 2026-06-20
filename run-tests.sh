#!/bin/bash
# =============================================================
# run-tests.sh — run the ada BATS test suite
# -------------------------------------------------------------
# Unit tests for the shell scripts (launcher, hooks, watcher,
# installer) and the zsh helper logic. Hermetic: each test runs
# in a private TMPDIR with the native helper, snooze daemon and
# app-focus stubbed, so nothing opens a window or touches your
# real config.
#
# Usage:
#   ./run-tests.sh            # run everything in test/
#   ./run-tests.sh test/ada-claude-hook.bats   # a single file
# =============================================================
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found. Install it with:" >&2
  echo "  brew install bats-core" >&2
  exit 1
fi

# Self-heal the stub execute bit in case a checkout dropped it.
chmod +x "$dir"/test/stubs/* 2>/dev/null || true

if [[ $# -gt 0 ]]; then
  exec bats "$@"
fi

exec bats "$dir/test/"
