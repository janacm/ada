#!/usr/bin/env bats
# Tests for lib/ada-history.sh — the line the launcher writes for every alert it
# decides on (shown, paused, muted or held), which the menu bar's Recent Alerts
# reads.

setup() {
  load test_helper
  setup_common
  LAUNCHER="$REPO_ROOT/lib/ada-show-alert.sh"
  HISTORY="$TMPDIR/ada-history.tsv"
}

# Field N (1-based) of history line L (1-based, default the last line).
field() {
  local n=$1 line=${2:-}
  if [[ -z "$line" ]]; then
    tail -n 1 "$HISTORY" | awk -F'\t' -v n="$n" '{print $n}'
  else
    sed -n "${line}p" "$HISTORY" | awk -F'\t' -v n="$n" '{print $n}'
  fi
}

@test "a shown alert records every field, in the documented order" {
  export ADA_SESSION_KEY=claude-abc ADA_SESSION_KIND=conversation ADA_REPO=myrepo \
         ADA_FOCUS_APP=com.example.term ADA_FOCUS_APP_NAME="Example Term" \
         ADA_CLICK_URL="claude://resume?session=abc" ADA_REPO_DIR="$BATS_TEST_TMPDIR/proj"
  run "$LAUNCHER" "make test" "2m 3s" 1
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  [ "$(wc -l < "$HISTORY")" -eq 1 ]
  assert_equal "$(tail -n 1 "$HISTORY" | awk -F'\t' '{print NF}')" 14
  assert_equal "$(field 1)" 1
  [[ "$(field 2)" =~ ^[0-9]{10}$ ]]
  assert_equal "$(field 3)" shown
  assert_equal "$(field 4)" 0
  assert_equal "$(field 5)" claude-abc
  assert_equal "$(field 6)" conversation
  assert_equal "$(field 7)" "make test"
  assert_equal "$(field 8)" "2m 3s"
  assert_equal "$(field 9)" 1
  assert_equal "$(field 10)" myrepo
  assert_equal "$(field 11)" com.example.term
  assert_equal "$(field 12)" "Example Term"
  assert_equal "$(field 13)" "claude://resume?session=abc"
  assert_equal "$(field 14)" "$BATS_TEST_TMPDIR/proj"
}

# The directory is what lets a pause summary name the repo of an alert that
# never resolved it: the launcher's own cwd when the caller names none.
@test "without ADA_REPO_DIR the dir column is the launcher's cwd" {
  mkdir -p "$BATS_TEST_TMPDIR/here"
  (cd "$BATS_TEST_TMPDIR/here" && "$LAUNCHER" "x" "1s" 0)
  wait_for_file "$ADA_PROBE_OUT"
  assert_equal "$(field 14)" "$BATS_TEST_TMPDIR/here"
}

@test "the history file is private" {
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  assert_equal "$(stat -f %Lp "$HISTORY")" 600
}

@test "tabs and line breaks in the label become spaces, and it is cut to 200" {
  local long; long=$(printf 'y%.0s' {1..300})
  run "$LAUNCHER" $'one\ttwo\nthree\r'"$long" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  [ "$(wc -l < "$HISTORY")" -eq 1 ]
  assert_equal "$(tail -n 1 "$HISTORY" | awk -F'\t' '{print NF}')" 14
  local label; label=$(field 7)
  [[ "$label" == "one two three yyy"* ]] || { echo "label: $label"; false; }
  assert_equal "${#label}" 200
}

@test "an alert held by a pause records its directory for the summary" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  ADA_REPO_DIR="$REPO_ROOT" run "$LAUNCHER" "while away" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
  assert_equal "$(field 3)" paused
  assert_equal "$(field 14)" "$REPO_ROOT"
}

@test "a paused alert is recorded as paused, with its click target but no repo lookup" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  export ADA_CLICK_URL="claude://resume?session=abc" ADA_REPO_DIR="$REPO_ROOT"
  run "$LAUNCHER" "while away" "5m 0s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  assert_equal "$(field 3)" paused
  assert_equal "$(field 7)" "while away"
  # Resolving the repo runs git, which waits until an alert is known to show.
  assert_equal "$(field 10)" ""
  assert_equal "$(field 13)" "claude://resume?session=abc"
}

@test "an alert a conversation snooze holds back is recorded as held" {
  mkdir -p "$TMPDIR/ada-snoozed"
  printf '%s tok\n' "$(( $(/bin/date +%s) + 600 ))" > "$TMPDIR/ada-snoozed/claude-abc"
  export ADA_SESSION_KEY=claude-abc ADA_CLICK_URL="claude://resume?session=abc"
  run "$LAUNCHER" "background task done" "1m 0s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  assert_equal "$(field 3)" held
  assert_equal "$(field 5)" claude-abc
  assert_equal "$(field 13)" "claude://resume?session=abc"
}

@test "a dropped alert keeps an ADA_REPO it inherited" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  ADA_REPO=inherited run "$LAUNCHER" "x" "1s" 0
  assert_equal "$(field 10)" inherited
}

@test "a muted alert is recorded as muted" {
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=opencode-s1 ADA_SESSION_KIND=session
  "$REPO_ROOT/lib/ada-mute.sh" add opencode-s1 >/dev/null
  run "$LAUNCHER" "quiet one" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
  assert_equal "$(field 3)" muted
  assert_equal "$(field 5)" opencode-s1
  assert_equal "$(field 7)" "quiet one"
}

@test "a snooze relaunch is flagged" {
  ADA_SNOOZED=1 run "$LAUNCHER" "again" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  assert_equal "$(field 3)" shown
  assert_equal "$(field 4)" 1
}

@test "a shown alert records the repo the launcher resolved" {
  ADA_REPO_DIR="$REPO_ROOT" run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  local top; top=$(git -C "$REPO_ROOT" rev-parse --show-toplevel)
  assert_equal "$(field 10)" "${top##*/}"
}

# A pause keeps the line as its record even with the history off, so building a
# line and appending it are separate steps.
@test "__ada_history_build works with ADA_HISTORY_MAX=0, and append then writes nothing" {
  run bash -c ". '$REPO_ROOT/lib/ada-history.sh'
    ADA_HISTORY_MAX=0 __ada_history_build paused k conversation 'the label' 1s 0 repo app App url /some/dir
    ADA_HISTORY_MAX=0 __ada_history_append
    printf '%s' \"\$__ada_history_line\""
  assert_success
  [ ! -e "$HISTORY" ]
  # Every field is non-empty here: read collapses a run of tabs.
  local f; IFS=$'\t' read -r -a f <<<"$output"
  assert_equal "${#f[@]}" 14
  assert_equal "${f[0]}" 1
  [[ "${f[1]}" =~ ^[0-9]{10}$ ]]
  assert_equal "${f[2]}" paused
  assert_equal "${f[6]}" "the label"
  assert_equal "${f[13]}" /some/dir
}

@test "__ada_history_record still builds and appends the same line" {
  run bash -c ". '$REPO_ROOT/lib/ada-history.sh'
    __ada_history_record shown k kind label 2s 1 repo app App url /d"
  assert_success
  assert_equal "$(wc -l < "$HISTORY" | tr -d ' ')" 1
  assert_equal "$(field 3)" shown
  assert_equal "$(field 9)" 1
  assert_equal "$(field 14)" /d
}

@test "a record without the dir argument ends in an empty dir column" {
  run bash -c ". '$REPO_ROOT/lib/ada-history.sh'; __ada_history_record shown k kind label 2s 0 '' '' '' ''"
  assert_equal "$(tail -n 1 "$HISTORY" | awk -F'\t' '{print NF}')" 14
  assert_equal "$(field 14)" ""
}

@test "ADA_HISTORY_MAX=0 keeps no history" {
  ADA_HISTORY_MAX=0 run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  [ ! -e "$HISTORY" ]
}

@test "the history is trimmed to the newest MAX lines once it reaches twice that" {
  export ADA_HISTORY_MAX=3
  local i
  for i in 1 2 3 4 5 6; do "$LAUNCHER" "alert $i" "1s" 0; done
  [ "$(wc -l < "$HISTORY")" -eq 6 ]
  "$LAUNCHER" "alert 7" "1s" 0
  [ "$(wc -l < "$HISTORY")" -eq 3 ]
  assert_equal "$(field 7 1)" "alert 5"
  assert_equal "$(field 7 3)" "alert 7"
  run ls -A "$TMPDIR"
  refute_output_contains "ada-history.tsv."
}

@test "a junk ADA_HISTORY_MAX falls back to the default" {
  ADA_HISTORY_MAX=lots run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  [ "$(wc -l < "$HISTORY")" -eq 1 ]
}

@test "launchers running at once each write one whole line" {
  local i
  for i in $(seq 1 20); do "$LAUNCHER" "parallel $i" "1s" 0 & done
  wait
  [ "$(wc -l < "$HISTORY")" -eq 20 ]
  assert_equal "$(awk -F'\t' '{print NF}' "$HISTORY" | sort -u)" 14
  assert_equal "$(cut -f7 "$HISTORY" | sort -u | wc -l | tr -d ' ')" 20
}

@test "a symlink at the history path is never written through" {
  : > "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HISTORY"
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  [ ! -s "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "ADA_HISTORY_FILE moves the history" {
  export ADA_HISTORY_FILE="$BATS_TEST_TMPDIR/new/dir/h.tsv"
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  [ -f "$ADA_HISTORY_FILE" ]
  [ ! -e "$HISTORY" ]
}

@test "a launcher copied without ada-history.sh still alerts" {
  local root="$BATS_TEST_TMPDIR/old"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  run "$root/lib/ada-show-alert.sh" "x" "1s" 0
  assert_success
  refute_output_contains "command not found"
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  [ ! -e "$HISTORY" ]
}

@test "list prints the lines and clear forgets them" {
  run "$REPO_ROOT/lib/ada-history.sh" list
  assert_success
  assert_equal "$output" ""
  "$LAUNCHER" "one" "1s" 0
  "$LAUNCHER" "two" "1s" 0
  run "$REPO_ROOT/lib/ada-history.sh" list
  [ "${#lines[@]}" -eq 2 ]
  assert_output_contains "two"
  run "$REPO_ROOT/lib/ada-history.sh" clear
  assert_equal "$output" "history cleared"
  [ ! -e "$HISTORY" ]
  run "$REPO_ROOT/lib/ada-history.sh" clear
  assert_equal "$output" "no history"
}

@test "clear leaves a symlink at the history path alone" {
  : > "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HISTORY"
  run "$REPO_ROOT/lib/ada-history.sh" clear
  assert_failure
  [ -L "$HISTORY" ]
}

@test "an unknown command fails with a hint" {
  run "$REPO_ROOT/lib/ada-history.sh" frobnicate
  [ "$status" -eq 2 ]
  assert_output_contains "try list, clear"
  run "$REPO_ROOT/lib/ada-history.sh" help
  assert_output_contains "ada-history.sh clear"
  assert_output_contains "ADA_HISTORY_MAX"
}
