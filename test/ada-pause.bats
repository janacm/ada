#!/usr/bin/env bats
# Tests for lib/ada-pause.sh — the global "no alerts for a while" switch behind
# the menu bar's Pause menu, and the CLI that sets and clears it.

setup() {
  load test_helper
  setup_common
  PAUSE="$REPO_ROOT/lib/ada-pause.sh"
  unset ADA_PAUSE_FILE
  PAUSE_FILE="$TMPDIR/ada-paused"
}

@test "the pause file defaults to TMPDIR/ada-paused" {
  . "$PAUSE"
  assert_equal "$(__ada_pause_file)" "$TMPDIR/ada-paused"
  ADA_PAUSE_FILE=/elsewhere/p
  assert_equal "$(__ada_pause_file)" "/elsewhere/p"
}

@test "status with no pause file says not paused" {
  run "$PAUSE" status
  assert_success
  assert_equal "$output" "not paused"
}

@test "no argument means status" {
  run "$PAUSE"
  assert_success
  assert_equal "$output" "not paused"
}

@test "a number of minutes pauses until now plus that many minutes" {
  export STUB_NOW=1790000000
  run "$PAUSE" 90
  assert_success
  assert_output_contains "paused until"
  assert_output_contains "(1h 30m left)"
  assert_equal "$(cat "$PAUSE_FILE")" "$(( 1790000000 + 90 * 60 ))"
}

@test "until takes an epoch second in the future" {
  export STUB_NOW=1790000000
  run "$PAUSE" until 1790003600
  assert_success
  assert_output_contains "(1h 0m left)"
  assert_equal "$(cat "$PAUSE_FILE")" "1790003600"
}

@test "until refuses a time that has already passed, and a non-number" {
  export STUB_NOW=1790000000
  run "$PAUSE" until 1790000000
  [ "$status" -eq 2 ]
  assert_output_contains "not in the future"
  run "$PAUSE" until soon
  [ "$status" -eq 2 ]
  assert_output_contains "needs an epoch second"
  [ ! -e "$PAUSE_FILE" ]
}

@test "forever pauses until resumed" {
  run "$PAUSE" forever
  assert_success
  assert_equal "$output" "paused until resumed"
  assert_equal "$(cat "$PAUSE_FILE")" "0"
  run "$PAUSE" status
  assert_equal "$output" "paused until resumed"
}

@test "resume removes the pause" {
  "$PAUSE" forever >/dev/null
  run "$PAUSE" resume
  assert_success
  assert_equal "$output" "alerts resumed"
  [ ! -e "$PAUSE_FILE" ]
  run "$PAUSE" resume
  assert_success
  assert_equal "$output" "alerts were not paused"
}

@test "status clears a pause that has run out" {
  printf '%s\n' 1000 > "$PAUSE_FILE"
  run "$PAUSE" status
  assert_success
  assert_equal "$output" "not paused"
  [ ! -e "$PAUSE_FILE" ]
}

@test "zero, negative, huge and non-numeric minutes are refused" {
  for arg in 0 -5 abc 1.5 525601 9999999; do
    run "$PAUSE" "$arg"
    [ "$status" -eq 2 ] || { echo "accepted $arg"; false; }
    assert_output_contains "unknown command"
  done
  [ ! -e "$PAUSE_FILE" ]
}

@test "a pause leaves no temp file behind" {
  "$PAUSE" 5 >/dev/null
  "$PAUSE" 10 >/dev/null
  run ls -A "$(dirname "$PAUSE_FILE")"
  refute_output_contains "ada-paused."
}

@test "a pause file whose directory does not exist yet is created" {
  export ADA_PAUSE_FILE="$BATS_TEST_TMPDIR/new/dir/paused"
  run "$PAUSE" forever
  assert_success
  [ -f "$ADA_PAUSE_FILE" ]
}

# ADA_PAUSE_FILE is user-configurable, so a path that already holds something
# else must never be overwritten or deleted, and never counts as a pause.
@test "a file that is not a pause file pauses nothing and is left alone" {
  printf 'my notes\n' > "$PAUSE_FILE"
  run "$PAUSE" status
  assert_success
  assert_output_contains "not paused"
  assert_output_contains "not a pause file"
  run "$PAUSE" 5
  assert_failure
  run "$PAUSE" forever
  assert_failure
  run "$PAUSE" resume
  assert_failure
  assert_equal "$(cat "$PAUSE_FILE")" "my notes"
}

@test "a symlink is not a pause file" {
  printf '0\n' > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$PAUSE_FILE"
  . "$PAUSE"
  # bats ignores a bare `! cmd` under errexit, so negate through run.
  run __ada_is_paused; assert_failure
  run "$PAUSE" resume
  assert_failure
  [ -L "$PAUSE_FILE" ]
  [ -f "$BATS_TEST_TMPDIR/target" ]
}

@test "__ada_is_paused is true before the end and false from it on" {
  printf '%s\n' 2000 > "$PAUSE_FILE"
  . "$PAUSE"
  __ada_is_paused 1999
  run __ada_is_paused 2000; assert_failure
  run __ada_is_paused 2001; assert_failure
}

@test "__ada_is_paused is true for a pause until resumed, whatever the time" {
  printf '0\n' > "$PAUSE_FILE"
  . "$PAUSE"
  __ada_is_paused 1
  __ada_is_paused 99999999999
}

@test "a value with leading zeros is read as decimal" {
  # 0000000002089 would be an invalid octal literal in bash arithmetic.
  printf '0000000002089\n' > "$PAUSE_FILE"
  . "$PAUSE"
  assert_equal "$(__ada_pause_until)" "2089"
  __ada_is_paused 2088
}

@test "a value without a trailing newline still reads" {
  printf '0' > "$PAUSE_FILE"
  . "$PAUSE"
  __ada_is_paused 5
}

@test "an empty pause file is not a pause" {
  : > "$PAUSE_FILE"
  . "$PAUSE"
  run __ada_is_paused 5; assert_failure
}

@test "status names the day for a pause that ends on another day" {
  export STUB_NOW=1790000000
  run "$PAUSE" until $(( 1790000000 + 2 * 86400 ))
  assert_success
  assert_output_contains "paused until $(/bin/date -r $(( 1790000000 + 2 * 86400 )) '+%a %H:%M')"
}

@test "help prints the usage block" {
  run "$PAUSE" help
  assert_success
  assert_output_contains "ada-pause.sh until <epoch>"
  assert_output_contains "ADA_IGNORE_PAUSE"
}
