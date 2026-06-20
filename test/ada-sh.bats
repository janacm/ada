#!/usr/bin/env bats
# Tests for ada.sh — the zsh terminal hook. ada.sh is zsh (preexec/precmd,
# zsh-only param expansions), so its pure-logic helpers are exercised under zsh.

setup() {
  load test_helper
  setup_common
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
}

# Source ada.sh in zsh, then run the given zsh snippet; capture stdout.
zsh_eval() {
  zsh -c "source '$REPO_ROOT/ada.sh' >/dev/null 2>&1; $1"
}

@test "format_duration: sub-minute prints tenths of a second" {
  run zsh_eval '__ada_format_duration 5'
  assert_success
  assert_equal "$output" "5.0s"
}

@test "format_duration: minutes and seconds" {
  run zsh_eval '__ada_format_duration 75'
  assert_success
  assert_equal "$output" "1m 15s"
}

@test "format_duration: hours and minutes" {
  run zsh_eval '__ada_format_duration 3661'
  assert_success
  assert_equal "$output" "1h 1m"
}

@test "is_ignored: editors are ignored" {
  run zsh_eval 'if __ada_is_ignored "vim notes.txt"; then echo IGNORED; else echo NO; fi'
  assert_success
  assert_equal "$output" "IGNORED"
}

@test "is_ignored: an absolute path to an editor is ignored (basename match)" {
  run zsh_eval 'if __ada_is_ignored "/usr/bin/nvim x"; then echo IGNORED; else echo NO; fi'
  assert_success
  assert_equal "$output" "IGNORED"
}

@test "is_ignored: ordinary commands are not ignored" {
  run zsh_eval 'if __ada_is_ignored "npm test"; then echo IGNORED; else echo NO; fi'
  assert_success
  assert_equal "$output" "NO"
}

# --- the precmd decision gate (elapsed AND not-ignored AND not-skip-active) ---

# Drive __ada_precmd under zsh with the alert + skip-active calls stubbed, so the
# AND-ed gate (the actual decision) is exercised, not just its sub-helpers.
run_precmd() {
  # args: cmd elapsed threshold
  run zsh -c "
    source '$REPO_ROOT/ada.sh' >/dev/null 2>&1
    ADA_THRESHOLD=$3
    __ada_should_skip_active() { return 1; }              # never skip
    __ada_show_alert() { print -r -- \"FIRED cmd=[\$1] code=[\$3]\"; }
    __ada_cmd='$1'
    __ada_start_time=\$(( EPOCHREALTIME - $2 ))
    __ada_precmd
  "
}

@test "precmd fires for a long ordinary command" {
  run_precmd "npm test" 50 10
  assert_success
  assert_output_contains "FIRED cmd=[npm test] code=[0]"
}

@test "precmd stays silent below the threshold" {
  run_precmd "npm test" 2 10
  assert_success
  assert_equal "$output" ""
}

@test "precmd stays silent for an ignored command even above threshold" {
  run_precmd "vim notes.txt" 50 10
  assert_success
  assert_equal "$output" ""
}

@test "precmd clears the stored command so it fires at most once" {
  run zsh -c "
    source '$REPO_ROOT/ada.sh' >/dev/null 2>&1
    ADA_THRESHOLD=10
    __ada_should_skip_active() { return 1; }
    __ada_show_alert() { print -r -- FIRED; }
    __ada_cmd='npm test'
    __ada_start_time=\$(( EPOCHREALTIME - 50 ))
    __ada_precmd     # fires
    __ada_precmd     # __ada_cmd cleared -> no second alert
  "
  assert_success
  assert_equal "$output" "FIRED"
}
