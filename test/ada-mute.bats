#!/usr/bin/env bats
# Tests for lib/ada-mute.sh — the per-session mute markers behind the alert's
# "Mute this …" button, and the CLI that lists and clears them.

setup() {
  load test_helper
  setup_common
  MUTE="$REPO_ROOT/lib/ada-mute.sh"
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted"
  unset ADA_MUTE_MAX_AGE
}

# Back-date a marker by N seconds.
age_marker() {
  local file="$ADA_MUTE_DIR/$1" secs="$2"
  touch -t "$(/bin/date -r $(( $(/bin/date +%s) - secs )) +%Y%m%d%H%M.%S)" "$file"
}

@test "add then list shows the key" {
  run "$MUTE" add claude-abc
  assert_success
  assert_output_contains "muted claude-abc for 86400s"
  run "$MUTE" list
  assert_success
  assert_output_contains "claude-abc"
  assert_output_contains "ago"
}

@test "list with nothing muted says so" {
  run "$MUTE" list
  assert_success
  assert_equal "$output" "no muted sessions"
}

@test "clear with a key unmutes only that key" {
  "$MUTE" add a-1 >/dev/null
  "$MUTE" add b-2 >/dev/null
  run "$MUTE" clear a-1
  assert_success
  [ ! -e "$ADA_MUTE_DIR/a-1" ]
  [ -e "$ADA_MUTE_DIR/b-2" ]
}

@test "clear with no key unmutes everything" {
  "$MUTE" add a-1 >/dev/null
  "$MUTE" add b-2 >/dev/null
  run "$MUTE" clear
  assert_success
  run "$MUTE" list
  assert_equal "$output" "no muted sessions"
}

@test "a key that could escape the directory is refused" {
  for key in ../evil a/b .hidden -flag "" "has space"; do
    run "$MUTE" add "$key"
    assert_failure
    assert_output_contains "invalid key"
  done
  [ ! -e "$BATS_TEST_TMPDIR/evil" ]
  run "$MUTE" clear ../evil
  assert_failure
}

@test "an unknown command fails with a hint" {
  run "$MUTE" frobnicate
  [ "$status" -eq 2 ]
  assert_output_contains "try list, clear, add"
}

@test "help prints the usage block" {
  run "$MUTE" help
  assert_success
  assert_output_contains "ada-mute.sh clear [key...]"
  assert_output_contains "ADA_MUTE_MAX_AGE"
}

@test "__ada_is_muted is true within the max age and false after it" {
  "$MUTE" add k-1 >/dev/null
  . "$MUTE"
  __ada_is_muted k-1
  age_marker k-1 90000
  # bats ignores a bare `! cmd` under errexit, so negate through run.
  run __ada_is_muted k-1;       assert_failure
  run __ada_is_muted never-muted; assert_failure
  run __ada_is_muted "../k-1";  assert_failure
}

@test "ADA_MUTE_MAX_AGE=0 never expires" {
  export ADA_MUTE_MAX_AGE=0
  run "$MUTE" add k-1
  assert_output_contains "until cleared"
  age_marker k-1 999999
  . "$MUTE"
  __ada_is_muted k-1
  __ada_mute_prune
  [ -e "$ADA_MUTE_DIR/k-1" ]
}

@test "a junk ADA_MUTE_MAX_AGE falls back to the default" {
  export ADA_MUTE_MAX_AGE=soon
  . "$MUTE"
  assert_equal "$(__ada_mute_max_age)" "86400"
}

@test "prune removes expired markers and keeps live ones" {
  "$MUTE" add old-1 >/dev/null
  "$MUTE" add new-1 >/dev/null
  age_marker old-1 90000
  . "$MUTE"
  __ada_mute_prune
  [ ! -e "$ADA_MUTE_DIR/old-1" ]
  [ -e "$ADA_MUTE_DIR/new-1" ]
}

@test "list hides and prunes an expired marker" {
  "$MUTE" add old-1 >/dev/null
  age_marker old-1 90000
  run "$MUTE" list
  assert_equal "$output" "no muted sessions"
  [ ! -e "$ADA_MUTE_DIR/old-1" ]
}

@test "the mute dir defaults under TMPDIR" {
  unset ADA_MUTE_DIR
  . "$MUTE"
  assert_equal "$(__ada_mute_dir)" "$TMPDIR/ada-muted"
}
