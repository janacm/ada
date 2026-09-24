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

@test "preexec records the command and a start time" {
  run zsh_eval '__ada_preexec "make build"; print -r -- "[$__ada_cmd]"; (( __ada_start_time > 0 )) && print started'
  assert_success
  assert_output_contains "[make build]"
  assert_output_contains "started"
}

@test "the ada manual trigger fires the alert through the sibling launcher" {
  run zsh_eval 'ada hello world'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "manual trigger never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=hello%20world"
  assert_file_contains "$ADA_PROBE_OUT" "code=0"
}

@test "the ada manual trigger with no words labels the alert 'manual'" {
  run zsh_eval 'ada'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "manual trigger never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=manual"
}

# --- __ada_should_skip_active, against the lsappinfo stub ----------------------

skip_active() {
  run zsh -c "
    source '$REPO_ROOT/ada.sh' >/dev/null 2>&1
    if __ada_should_skip_active; then print SKIP; else print ALERT; fi
  "
}

@test "skip_active: the terminal that ran the command is frontmost" {
  export __CFBundleIdentifier=com.mitchellh.ghostty STUB_FRONT_BUNDLEID=com.mitchellh.ghostty
  skip_active
  assert_equal "$output" "SKIP"
}

@test "skip_active: another app is frontmost" {
  export __CFBundleIdentifier=com.mitchellh.ghostty STUB_FRONT_BUNDLEID=com.apple.Safari
  skip_active
  assert_equal "$output" "ALERT"
}

@test "skip_active: own-terminal suppression can be switched off" {
  export ADA_SKIP_OWN_TERMINAL=0
  export __CFBundleIdentifier=com.mitchellh.ghostty STUB_FRONT_BUNDLEID=com.mitchellh.ghostty
  skip_active
  assert_equal "$output" "ALERT"
}

@test "skip_active: a skip-list entry matches the frontmost bundle id" {
  export ADA_SKIP_WHEN_ACTIVE="com.apple.Safari" STUB_FRONT_BUNDLEID=com.apple.Safari
  skip_active
  assert_equal "$output" "SKIP"
}

@test "skip_active: a skip-list entry matches part of the frontmost app name" {
  export ADA_SKIP_WHEN_ACTIVE="Termius" STUB_FRONT_NAME="Termius Beta"
  skip_active
  assert_equal "$output" "SKIP"
}

# Homebrew's keg is a real copy, not a symlink, so :A leaves it in the Cellar
# and only the explicit Cellar -> opt mapping can make the path survive upgrade.
@test "sourced from a Cellar keg, ada.sh resolves its siblings via the opt path" {
  local prefix="$BATS_TEST_TMPDIR/brew"
  local keg="$prefix/Cellar/ada/9.9.9/libexec"
  mkdir -p "$keg" "$prefix/opt"
  cp "$REPO_ROOT/ada.sh" "$keg/ada.sh"
  ln -s "../Cellar/ada/9.9.9" "$prefix/opt/ada"
  local real_prefix; real_prefix=$(cd "$prefix" && pwd -P)
  unset ADA_ALERT_FILE
  run zsh -c "source '$keg/ada.sh' >/dev/null 2>&1; print -r -- \"\$_ADA_DIR|\$ADA_ALERT_FILE\""
  assert_success
  assert_equal "$output" "$real_prefix/opt/ada/libexec|$real_prefix/opt/ada/libexec/alert.html"
}

# --- per-session mute: one key per interactive shell -------------------------

@test "a precmd alert carries this shell's session key" {
  export ADA_PROBE_SESSION_OUT="$BATS_TEST_TMPDIR/probe-session.txt"
  run zsh -c "
    source '$REPO_ROOT/ada.sh' >/dev/null 2>&1
    __ada_should_skip_active() { return 1; }
    ADA_THRESHOLD=1 __ada_cmd='make' __ada_start_time=\$(( EPOCHREALTIME - 5 ))
    __ada_precmd
    print -r -- \"\$_ADA_SESSION_KEY\"
  "
  assert_success
  [[ "$output" =~ ^zsh-[0-9]+-[0-9]+$ ]] || { echo "unexpected key: $output"; false; }
  wait_for_file "$ADA_PROBE_SESSION_OUT" || { echo "alert never fired"; false; }
  assert_equal "$(cat "$ADA_PROBE_SESSION_OUT")" "$output terminal"
}

@test "two shells get different session keys" {
  a=$(zsh_eval 'print -r -- $_ADA_SESSION_KEY')
  b=$(zsh_eval 'print -r -- $_ADA_SESSION_KEY')
  [ -n "$a" ] && [ "$a" != "$b" ]
}

@test "a muted terminal stays quiet, but the manual ada trigger still fires" {
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted"
  run zsh -c "
    source '$REPO_ROOT/ada.sh' >/dev/null 2>&1
    __ada_should_skip_active() { return 1; }
    '$REPO_ROOT/lib/ada-mute.sh' add \"\$_ADA_SESSION_KEY\" >/dev/null
    ADA_THRESHOLD=1 __ada_cmd='make' __ada_start_time=\$(( EPOCHREALTIME - 5 ))
    __ada_precmd
    sleep 0.5
    [[ -e '$ADA_PROBE_OUT' ]] && print -r -- LEAKED
    ada still here
  "
  assert_success
  refute_output_contains "LEAKED"
  wait_for_file "$ADA_PROBE_OUT" || { echo "manual trigger never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=still%20here"
}
