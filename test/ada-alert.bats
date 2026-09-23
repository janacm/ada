#!/usr/bin/env bats
# Tests for the native helpers' command lines: ada-alert (the only renderer,
# since there is no browser fallback) and ada-menubar.
#
# Only the modes that never open a window are exercised. `ada-alert <url>` and
# a bare `ada-menubar` start an AppKit app, which needs a GUI session and is
# validated by hand (see "How to validate windowed-vs-fullscreen" in CLAUDE.md).
# ADA_ALERT_UNDER_TEST / ADA_MENUBAR_UNDER_TEST point at a specific build, which
# is how `./run-tests.sh --coverage` swaps in an instrumented one.

# The first built copy of a helper, or nothing. Always returns 0: bats runs
# setup under `set -e`, where a lookup that simply finds no build must not fail.
find_helper() {
  local p
  for p in "$REPO_ROOT/$1" "$REPO_ROOT/.build/release/$1" "$REPO_ROOT/.build/debug/$1"; do
    if [[ -x "$p" ]]; then printf '%s' "$p"; return 0; fi
  done
  return 0
}

setup() {
  load test_helper
  setup_common
  ALERT=${ADA_ALERT_UNDER_TEST:-$(find_helper ada-alert)}
  MENUBAR=${ADA_MENUBAR_UNDER_TEST:-$(find_helper ada-menubar)}
}

need_alert() { [[ -n "$ALERT" ]] || skip "ada-alert not built (swift build -c release --product ada-alert)"; }
need_menubar() { [[ -n "$MENUBAR" ]] || skip "ada-menubar not built (swift build -c release --product ada-menubar)"; }

# --check is the one way to prove a built helper actually runs without opening
# a window, which is what a smoke test after a build or an install needs.
@test "ada-alert --check reports a working helper" {
  need_alert
  run "$ALERT" --check
  assert_success
  assert_equal "$output" "ada-alert native helper ok"
}

@test "ada-alert --help prints usage and succeeds" {
  need_alert
  run "$ALERT" --help
  assert_success
  assert_output_contains "ada-alert <alert-url>"
}

@test "ada-alert with no URL fails with usage (exit 2)" {
  need_alert
  run "$ALERT"
  assert_equal "$status" 2
  assert_output_contains "Usage:"
}

@test "ada-alert rejects a string that is not a URL" {
  need_alert
  run "$ALERT" not-a-url
  assert_equal "$status" 2
  assert_output_contains "Usage:"
}

@test "ada-alert rejects more than one URL" {
  need_alert
  run "$ALERT" "file:///tmp/a.html" "file:///tmp/b.html"
  assert_equal "$status" 2
}

@test "ada-menubar --check reports a working helper" {
  need_menubar
  run "$MENUBAR" --check
  assert_success
  assert_equal "$output" "ada-menubar native helper ok"
}
