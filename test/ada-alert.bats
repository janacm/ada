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

# A build from before --print-menu treats every argument but --check as "run
# the app", which would put a real status item on the screen. Look for the flag
# in the binary instead of asking it.
need_print_menu() {
  need_menubar
  grep -qa -- '--print-menu' "$MENUBAR" || skip "ada-menubar predates --print-menu (rebuild it)"
}

# The menu as it would open, from real state the scripts wrote into this test's
# TMPDIR and HOME. ADA_HOME points it at the repo's scripts.
print_menu() {
  ADA_HOME="$REPO_ROOT" run "$MENUBAR" --print-menu
}

@test "ada-menubar --help and unknown arguments never start the app" {
  need_print_menu
  run "$MENUBAR" --help
  assert_success
  assert_output_contains "--print-menu"
  run "$MENUBAR" --frobnicate
  assert_equal "$status" 2
  assert_output_contains "unknown arguments: --frobnicate"
}

@test "--print-menu with nothing going on" {
  need_print_menu
  print_menu
  assert_success
  assert_equal "${lines[0]}" "  Alerts On [bell]"
  assert_output_contains "> Pause Alerts [pause.circle]"
  assert_output_contains "    - For 1 Hour"
  assert_output_contains "      No Alerts Yet"
  assert_output_contains "      Nothing Muted"
  assert_output_contains "      Terminal commands: no ~/.zshrc [circle]"
  assert_output_contains "- Quit ADA Menu Bar"
  refute_output_contains "Resume Alerts"
}

# The pause file is read by the Swift side and written only by the script, so
# the two have to agree on what it says.
@test "--print-menu agrees with ada-pause.sh about a pause" {
  need_print_menu
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  print_menu
  assert_equal "${lines[0]}" "  Paused Until Resumed [bell.slash]"
  assert_output_contains "- Resume Alerts [bell]"
  assert_output_contains "> Change Pause"

  local until=$(( $(/bin/date +%s) + 600 )) when
  "$REPO_ROOT/lib/ada-pause.sh" until "$until" >/dev/null
  when=$(/bin/date -r "$until" +%H:%M)
  [[ "$(/bin/date -r "$until" +%Y%m%d)" == "$(/bin/date +%Y%m%d)" ]] || when="Tomorrow $when"
  print_menu
  assert_equal "${lines[0]}" "  Paused Until $when [bell.slash]"
  run "$REPO_ROOT/lib/ada-pause.sh" status
  assert_output_contains "paused until $(/bin/date -r "$until" +%H:%M)"
}

# History written by the real launcher, read back by the menu.
@test "--print-menu lists the alerts the launcher recorded, newest first" {
  need_print_menu
  ADA_SESSION_KEY=claude-abc ADA_CLICK_URL="claude://resume?session=abc" ADA_REPO=myrepo \
    "$REPO_ROOT/lib/ada-show-alert.sh" "make test" "2m 3s" 0
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  ADA_FOCUS_APP=com.example.term "$REPO_ROOT/lib/ada-show-alert.sh" "npm run build" "5m 0s" 1
  print_menu
  assert_success
  local recent
  recent=$(printf '%s\n' "${lines[@]}" | sed -n '/^> Recent Alerts/,/^> Muted/p')
  [[ "$(sed -n 2p <<<"$recent")" == "    - npm run build · 5m 0s · "*" (while paused) [pause.circle]" ]] || { echo "$recent"; false; }
  [[ "$(sed -n 3p <<<"$recent")" == "    - make test · myrepo · 2m 3s · "*" [checkmark.circle]" ]] || { echo "$recent"; false; }
  assert_output_contains "    - Clear History"
}

@test "--print-menu names muted sessions by the label ada-mute.sh stored" {
  need_print_menu
  "$REPO_ROOT/lib/ada-mute.sh" add claude-abc "fix the flaky test" >/dev/null
  "$REPO_ROOT/lib/ada-mute.sh" add zsh-4242-1790000000 >/dev/null
  print_menu
  assert_output_contains "> Muted Sessions (2) [bell.slash]"
  assert_output_contains "    - fix the flaky test · Claude Code conversation · just now [bell.slash]"
  assert_output_contains "    - terminal 4242-179 · just now [bell.slash]"
  # Both readers see the same two keys.
  run "$REPO_ROOT/lib/ada-mute.sh" list
  [ "${#lines[@]}" -eq 2 ]
}

@test "--print-menu drops a mute the shell considers expired" {
  need_print_menu
  export ADA_MUTE_MAX_AGE=60
  "$REPO_ROOT/lib/ada-mute.sh" add claude-old "old one" >/dev/null
  touch -t "$(/bin/date -r $(( $(/bin/date +%s) - 3600 )) +%Y%m%d%H%M.%S)" "$TMPDIR/ada-muted/claude-old"
  print_menu
  assert_output_contains "      Nothing Muted"
  run "$REPO_ROOT/lib/ada-mute.sh" list
  assert_equal "$output" "no muted sessions"
}
