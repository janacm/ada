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

@test "a zero-padded ADA_MUTE_MAX_AGE is read as decimal, not octal" {
  export ADA_MUTE_MAX_AGE=086400
  "$MUTE" add k-1 >/dev/null
  . "$MUTE"
  assert_equal "$(__ada_mute_max_age)" "86400"
  __ada_is_muted k-1
  export ADA_MUTE_MAX_AGE=00
  assert_equal "$(__ada_mute_max_age)" "0"
}

@test "an absurdly long ADA_MUTE_MAX_AGE falls back instead of overflowing" {
  export ADA_MUTE_MAX_AGE=99999999999999999999999
  . "$MUTE"
  assert_equal "$(__ada_mute_max_age)" "86400"
}

# ADA_MUTE_DIR is user-configurable. Pointed at a directory with other content,
# prune and clear must touch only direct marker files, never nested files,
# names that fail the key rule, or symlinks.
@test "prune and clear leave anything that isn't a marker alone" {
  mkdir -p "$ADA_MUTE_DIR/nested"
  : > "$ADA_MUTE_DIR/nested/old-config"
  : > "$ADA_MUTE_DIR/.hidden"
  : > "$ADA_MUTE_DIR/has space"
  : > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$ADA_MUTE_DIR/link-1"
  "$MUTE" add old-1 >/dev/null
  for f in nested/old-config .hidden "has space" old-1; do age_marker "$f" 90000; done
  touch -h -t 200001010000 "$ADA_MUTE_DIR/link-1"

  . "$MUTE"
  __ada_mute_prune
  [ ! -e "$ADA_MUTE_DIR/old-1" ]
  [ -e "$ADA_MUTE_DIR/nested/old-config" ]
  [ -e "$ADA_MUTE_DIR/.hidden" ]
  [ -e "$ADA_MUTE_DIR/has space" ]
  [ -L "$ADA_MUTE_DIR/link-1" ]

  "$MUTE" add new-1 >/dev/null
  run "$MUTE" clear
  assert_success
  [ ! -e "$ADA_MUTE_DIR/new-1" ]
  [ -e "$ADA_MUTE_DIR/nested/old-config" ]
  [ -e "$ADA_MUTE_DIR/.hidden" ]
  [ -e "$ADA_MUTE_DIR/has space" ]
  [ -L "$ADA_MUTE_DIR/link-1" ]
  [ -e "$BATS_TEST_TMPDIR/target" ]
}

@test "clear, add and the mute check refuse a symlink named like a key" {
  mkdir -p "$ADA_MUTE_DIR"
  : > "$BATS_TEST_TMPDIR/target"
  touch -t 200001010000 "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$ADA_MUTE_DIR/link-1"

  run "$MUTE" clear link-1
  assert_failure
  assert_output_contains "not a mute marker"
  [ -L "$ADA_MUTE_DIR/link-1" ]

  run "$MUTE" add link-1
  assert_failure
  [ "$(/usr/bin/stat -f %m "$BATS_TEST_TMPDIR/target")" -lt 1000000000 ]

  . "$MUTE"
  run __ada_is_muted link-1; assert_failure
}

@test "clearing a key that was never muted succeeds quietly" {
  run "$MUTE" clear never-1
  assert_success
  assert_output_contains "unmuted never-1"
}

@test "add with a label stores it and list shows it" {
  run "$MUTE" add claude-abc $'fix the\tflaky\ntest'
  assert_success
  assert_equal "$(cat "$ADA_MUTE_DIR/claude-abc")" "fix the flaky test"
  assert_equal "$(stat -f %Lp "$ADA_MUTE_DIR/claude-abc")" 600
  run "$MUTE" list
  assert_success
  [[ "$output" == claude-abc$'\t'"muted "*" ago"$'\t'"fix the flaky test" ]] || { echo "got: $output"; false; }
}

@test "a marker without a label lists as key and age only" {
  "$MUTE" add claude-abc >/dev/null
  run "$MUTE" list
  [[ "$output" == claude-abc$'\t'"muted "*" ago" ]] || { echo "got: $output"; false; }
  refute_output_contains $'ago\t'
}

# An older daemon, or a plain `add`, left a 0644 marker. Writing a label (a
# prompt) into that same file would keep it world-readable.
@test "a label added to an existing world-readable marker is private" {
  "$MUTE" add claude-abc >/dev/null
  chmod 644 "$ADA_MUTE_DIR/claude-abc"
  run "$MUTE" add claude-abc "secret prompt"
  assert_success
  assert_equal "$(cat "$ADA_MUTE_DIR/claude-abc")" "secret prompt"
  assert_equal "$(stat -f %Lp "$ADA_MUTE_DIR/claude-abc")" 600
  run ls -A "$ADA_MUTE_DIR"
  assert_equal "$output" "claude-abc"
}

@test "adding a label to a muted key replaces the old one" {
  "$MUTE" add claude-abc "old" >/dev/null
  "$MUTE" add claude-abc "new" >/dev/null
  assert_equal "$(cat "$ADA_MUTE_DIR/claude-abc")" "new"
}
