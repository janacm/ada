#!/usr/bin/env bats
# Tests for lib/ada-notify.sh — the shared "alert me now, unless I'm already
# watching" layer between an integration and the launcher.

setup() {
  load test_helper
  setup_common
  NOTIFY="$REPO_ROOT/lib/ada-notify.sh"
  export ADA_SKIP_OWN_TERMINAL=0
  export ADA_SKIP_WHEN_ACTIVE=""
}

@test "fires the launcher with the label and a formatted duration" {
  run "$NOTIFY" "a long turn" 125 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=a%20long%20turn"
  # the launcher interpolates the duration raw, spaces and all
  assert_file_contains "$ADA_PROBE_OUT" "duration=2m 5s"
  assert_file_contains "$ADA_PROBE_OUT" "code=0"
}

@test "seconds under a minute render as seconds" {
  run "$NOTIFY" "quick" 45 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "duration=45s"
}

@test "an hour or more renders as hours and minutes" {
  run "$NOTIFY" "epic" 7380 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "duration=2h 3m"
}

# A permission prompt has no meaningful duration: the turn is still running.
@test "an empty duration produces an alert with no duration value" {
  run "$NOTIFY" "needs permission" "" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "duration=&"
}

@test "passes the exit code through" {
  run "$NOTIFY" "failed thing" 60 3
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "code=3"
}

@test "stays silent when the hosting terminal is frontmost" {
  export ADA_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.test.term"
  run "$NOTIFY" "turn done" 120 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

# Paired control for the test above: same knobs, different frontmost app, so a
# silent result can't be explained by a globally dead fire path.
@test "fires when a different app is frontmost" {
  export ADA_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"
  run "$NOTIFY" "turn done" 120 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "should fire when not watching"; false; }
}

@test "stays silent for a skip-listed app name" {
  export ADA_SKIP_OWN_TERMINAL=0
  export ADA_SKIP_WHEN_ACTIVE="Paseo"
  export STUB_FRONT_BUNDLEID="sh.paseo.desktop"
  export STUB_FRONT_NAME="Paseo"
  run "$NOTIFY" "turn done" 120 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "sourcing defines the helpers without firing an alert" {
  run bash -c ". '$NOTIFY'; __ada_format_duration 3725"
  assert_success
  assert_output_contains "1h 2m"
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "the launcher resolves next to ada-notify.sh, not from a baked path" {
  # A copy in an unrelated directory must NOT find the launcher: proves the
  # resolution is relative to the script, which is what keeps Homebrew,
  # ~/.ada and dev-checkout installs all working.
  cp "$NOTIFY" "$BATS_TEST_TMPDIR/ada-notify.sh"
  run "$BATS_TEST_TMPDIR/ada-notify.sh" "orphan" 120 0
  assert_failure
  refute_file_appears "$ADA_PROBE_OUT"
}
