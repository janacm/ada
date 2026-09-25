#!/usr/bin/env bats
# Tests for lib/ada-pause.sh — the global "no alerts for a while" switch behind
# the menu bar's Pause menu, and the CLI that sets and clears it.

setup() {
  load test_helper
  setup_common
  PAUSE="$REPO_ROOT/lib/ada-pause.sh"
  unset ADA_PAUSE_FILE
  PAUSE_FILE="$TMPDIR/ada-paused"
  HELD="$PAUSE_FILE.held"
}

# A test that turns the pause timer on ends it here. The timer is detached from
# bats' descriptors, but it would still outlive the test by up to its poll step.
teardown() {
  reap_processes "ada-snooze-daemon.py --pause-timer .*$BATS_TEST_TMPDIR"
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
  assert_equal "$output" "alerts resumed · nothing arrived while paused"
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

# --- the timer that shows the summary ------------------------------------------

timer_running() { /usr/bin/pgrep -f "ada-snooze-daemon.py --pause-timer .*$BATS_TEST_TMPDIR" >/dev/null; }

@test "a timed pause starts a detached timer, and forever starts none" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_PAUSE_TIMER=1
  run "$PAUSE" forever
  assert_success
  sleep 0.3
  run timer_running; assert_failure
  run "$PAUSE" 30
  assert_success
  local t=40; until timer_running || (( t-- == 0 )); do sleep 0.05; done
  timer_running || { echo "no timer for a 30-minute pause"; false; }
  run "$PAUSE" resume
  assert_success
}

@test "until starts the timer too" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_PAUSE_TIMER=1
  run "$PAUSE" until $(( $(/bin/date +%s) + 3600 ))
  assert_success
  local t=40; until timer_running || (( t-- == 0 )); do sleep 0.05; done
  timer_running || { echo "no timer for until"; false; }
}

@test "ADA_PAUSE_TIMER=0 starts no timer" {
  run "$PAUSE" 30
  assert_success
  sleep 0.3
  run timer_running; assert_failure
}

# The whole timed path, minus minutes of waiting: a pause a few seconds long
# whose timer runs the launcher in flush mode once it is over. The alert is
# held under a pause until resumed first, and the timed pause replaces it:
# held records carry over, and the launcher no longer has to finish before a
# clock that leaves it as little as one second under load.
@test "when a timed pause runs out its timer shows what was held" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_PAUSE_TIMER=1 ADA_NATIVE_ALERT="$STUBS/counting-ada-alert"
  "$PAUSE" forever >/dev/null
  "$REPO_ROOT/lib/ada-show-alert.sh" "held while paused" "1s" 0
  [ -z "$(ls "$HELD")" ] && { echo "the alert was not held"; false; }
  "$PAUSE" until $(( $(/bin/date +%s) + 3 )) >/dev/null
  wait_for_file "$ADA_PROBE_OUT" 120 || { echo "no summary after the pause ended"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "mode=summary"
  assert_equal "$(summary_json | json_get 'd["why"], d["n"], d["items"][0]["l"]')" "('ended', 1, 'held while paused')"
  # The launcher never deletes the pause file, even an expired one.
  [ -f "$PAUSE_FILE" ]
}

# The timer can outlive its caller by a day, so it must not keep the caller's
# directory busy: a drive it sits on could not be ejected. lsof reads its cwd.
# pgrep can also see the parents of the double fork for a moment, so this
# waits until every match is the timer itself.
@test "the timer does not hold on to the directory it was started from" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  [ -x /usr/sbin/lsof ] || skip "lsof required"
  export ADA_PAUSE_TIMER=1
  mkdir -p "$BATS_TEST_TMPDIR/project"
  ( cd "$BATS_TEST_TMPDIR/project" && "$PAUSE" 30 >/dev/null )
  local pids cwds="" t=60
  while (( t-- > 0 )); do
    pids=$(/usr/bin/pgrep -f "ada-snooze-daemon.py --pause-timer .*$BATS_TEST_TMPDIR" | paste -sd, -)
    [ -n "$pids" ] && cwds=$(/usr/sbin/lsof -a -p "$pids" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)
    [ "$cwds" = / ] && break
    sleep 0.05
  done
  assert_equal "$cwds" /
}

# A relative ADA_PAUSE_FILE means a file beside the caller. The timer makes it
# absolute before it leaves for /, and hands that path to the flush it runs.
@test "a relative pause file still gets its summary from the timer" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_PAUSE_TIMER=1 ADA_NATIVE_ALERT="$STUBS/counting-ada-alert" ADA_PAUSE_FILE=paused
  local project="$BATS_TEST_TMPDIR/project"; mkdir -p "$project"
  cd "$project"
  held_record "beside the caller" 1s 0
  "$PAUSE" until $(( $(/bin/date +%s) + 3 )) >/dev/null
  [ -f "$project/paused" ]
  wait_for_file "$ADA_PROBE_OUT" 140 || { echo "no summary after the pause ended"; false; }
  assert_equal "$(summary_json | json_get 'd["why"], [i["l"] for i in d["items"]]')" "('ended', ['beside the caller'])"
  [ ! -e "$project/paused.held" ]
}

# --- held counts in the CLI's own output -----------------------------------------

@test "status and a new pause mention what is held only when something is" {
  export STUB_NOW=1790000000
  run "$PAUSE" 30
  assert_equal "$output" "paused until $(/bin/date -r $(( 1790000000 + 1800 )) +%H:%M) (30m 0s left)"
  held_record "one" 1s 0
  held_record "two" 1s 0
  run "$PAUSE" status
  assert_output_contains "(30m 0s left) · 2 alerts held"
  run "$PAUSE" 60
  assert_output_contains "(1h 0m left) · 2 alerts held so far"
  run "$PAUSE" forever
  assert_equal "$output" "paused until resumed · 2 alerts held so far"
  run "$PAUSE" until $(( 1790000000 + 60 ))
  assert_output_contains "(1m 0s left) · 2 alerts held so far"
}

@test "status after an ended pause says what is still held" {
  printf '1000\n' > "$PAUSE_FILE"
  held_record "one" 1s 0
  run "$PAUSE" status
  assert_success
  assert_equal "$output" "not paused · 1 alert held from an ended pause (resume shows them)"
}

@test "the held count includes the overflow" {
  held_record "one" 1s 0
  printf 'xxx' > "$HELD/overflow"
  run "$PAUSE" status
  assert_equal "$output" "not paused · 4 alerts held from an ended pause (resume shows them)"
}

# --- resume shows the summary ----------------------------------------------------

@test "resume with a pause and held alerts shows them in one summary" {
  "$PAUSE" forever >/dev/null
  held_record "first" 1s 0
  held_record "second" 1s 0
  run "$PAUSE" resume
  assert_success
  assert_equal "$output" "alerts resumed · showing the 2 alerts that arrived while paused"
  [ ! -e "$PAUSE_FILE" ]
  wait_for_file "$ADA_PROBE_OUT" || { echo "no summary"; false; }
  assert_equal "$(summary_json | json_get 'd["why"], d["n"], len(d["items"])')" "('resumed', 2, 2)"
  [ ! -e "$HELD" ]
}

@test "resume with one held alert says so in the singular" {
  "$PAUSE" forever >/dev/null
  held_record "only" 1s 0
  run "$PAUSE" resume
  assert_equal "$output" "alerts resumed · showing the 1 alert that arrived while paused"
}

# resume removes the pause file and only then decides whether to flush. An
# alert held just before that rm is in held/, and nothing else would show it:
# the timer takes a missing file for a resume. The rm here runs one alert, held
# by the pause that is still on, right before it deletes the file.
@test "an alert held while resume removes the pause is in its summary" {
  "$PAUSE" forever >/dev/null
  local bin="$BATS_TEST_TMPDIR/rmbin"; mkdir -p "$bin"
  cat > "$bin/rm" <<EOF
#!/bin/bash
for a in "\$@"; do
  [[ "\$a" == "$PAUSE_FILE" ]] && "$REPO_ROOT/lib/ada-show-alert.sh" "held during resume" "1s" 0
done
exec /bin/rm "\$@"
EOF
  chmod +x "$bin/rm"
  PATH="$bin:$PATH" run "$PAUSE" resume
  assert_success
  assert_equal "$output" "alerts resumed · showing the 1 alert that arrived while paused"
  wait_for_file "$ADA_PROBE_OUT" || { echo "no summary"; false; }
  assert_equal "$(summary_json | json_get '[i["l"] for i in d["items"]]')" "['held during resume']"
  [ ! -e "$HELD" ]
}

@test "resume with no pause but alerts left from an earlier one shows them" {
  held_record "left over" 1s 0
  run "$PAUSE" resume
  assert_success
  assert_equal "$output" "not paused · showing 1 alert held from an earlier pause"
  wait_for_file "$ADA_PROBE_OUT" || { echo "no summary"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "mode=summary"
}

@test "resume with neither a pause nor held alerts changes nothing" {
  run "$PAUSE" resume
  assert_success
  assert_equal "$output" "alerts were not paused"
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "without python3 resume says the held alerts wait, and keeps them" {
  "$PAUSE" forever >/dev/null
  held_record "one" 1s 0
  held_record "two" 1s 0
  # A PATH with the tools the CLI uses but no python3 (macOS keeps one in /usr/bin).
  local bin="$BATS_TEST_TMPDIR/nopy"; mkdir -p "$bin"
  local tool
  for tool in dirname stat sed; do ln -s "/usr/bin/$tool" "$bin/$tool"; done
  PATH="$bin:$STUBS:/bin" run "$PAUSE" resume
  assert_success
  assert_equal "$output" "alerts resumed · 2 held alerts need python3 to show"
  [ "$(ls "$HELD" | wc -l | tr -d ' ')" -eq 2 ]
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "resume leaves a file that is not a pause file alone, held alerts or not" {
  printf 'notes\n' > "$PAUSE_FILE"
  held_record "one" 1s 0
  run "$PAUSE" resume
  assert_failure
  assert_equal "$(cat "$PAUSE_FILE")" "notes"
  [ -d "$HELD" ]
}

# --- the record and the gate -----------------------------------------------------

@test "a record is the history line, alone in a private directory" {
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'
    __ada_pause_hold \"1\$(printf '\\t')1790000000\$(printf '\\t')paused\"
    printf '%s' \"\$__ada_pause_rec\""
  assert_success
  [[ "$output" == "$HELD/1790000000."*".tsv" ]] || { echo "record: $output"; false; }
  assert_equal "$(stat -f %Lp "$HELD")" 700
  assert_equal "$(cat "$output")" "1	1790000000	paused"
  run ls -A "$HELD"
  refute_output_contains ".tmp"
}

# The gate writes the record, then asks again whether the pause is on. Both
# answers are forced here, and the second call also renames the directory away
# as a flush would, between the write and the recheck.
@test "the gate takes its record back and shows the alert when the pause ended meanwhile" {
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'
    __ada_is_paused() { return 1; }
    __ada_pause_gate 'line'; echo \"gate=\$?\""
  assert_output_contains "gate=1"
  [ -z "$(ls -A "$HELD")" ] || { ls -A "$HELD"; false; }
}

@test "the gate leaves the record to a flush that already claimed it" {
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'
    __ada_is_paused() { mv '$HELD' '$PAUSE_FILE.claim.x'; return 1; }
    __ada_pause_gate 'line'; echo \"gate=\$?\""
  assert_output_contains "gate=0"
  [ "$(ls "$PAUSE_FILE.claim.x" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "the gate keeps the record while the pause is still on" {
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'
    __ada_is_paused() { return 0; }
    __ada_pause_gate 'line'; echo \"gate=\$?\""
  assert_output_contains "gate=0"
  [ "$(ls "$HELD" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "past 500 records a held alert only adds to the overflow count" {
  mkdir -m 700 "$HELD"
  local i
  for i in $(seq 1 500); do : > "$HELD/$i.1.1.tsv"; done
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'
    __ada_is_paused() { return 0; }
    __ada_pause_gate 'line'; echo \"gate=\$? rec=\$__ada_pause_rec\""
  assert_output_contains "gate=0 rec="
  assert_equal "$(ls "$HELD" | grep -c '\.tsv$')" 500
  assert_equal "$(cat "$HELD/overflow")" "x"
}

@test "a held directory that is not ours is never written into" {
  printf 'x\n' > "$HELD"
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'; __ada_pause_hold 'line'"
  assert_failure
  assert_equal "$(cat "$HELD")" "x"
  rm "$HELD"
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HELD"
  run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'; __ada_pause_hold 'line'"
  assert_failure
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}

# --- the summary payload (__ada_pause_summary) --------------------------------------

summary() {
  bash -c ". '$REPO_ROOT/lib/ada-pause.sh'; __ada_pause_summary \"\$@\"" _ "$@"
}

# The launcher asks whether a pause is on before it flushes, but the claim comes
# later, after python starts and the mutes are scanned. A pause set in between
# owns what is held by then, so the summary pass asks again before renaming.
@test "the summary pass claims nothing while a pause is on, timed or until resumed" {
  held_record "held for the new pause" 1m 0
  "$PAUSE" 30 >/dev/null
  run summary ended ""
  assert_success
  assert_equal "$output" ""
  [ -n "$(ls "$TMPDIR/ada-paused.held"/*.tsv 2>/dev/null)" ]
  "$PAUSE" forever >/dev/null
  run summary ended ""
  assert_equal "$output" ""
  [ -n "$(ls "$TMPDIR/ada-paused.held"/*.tsv 2>/dev/null)" ]
  # Once it is over, the same records are claimed and shown.
  "$PAUSE" resume >/dev/null 2>&1 || true
  [ ! -e "$TMPDIR/ada-paused" ]
  held_record "held for the new pause" 1m 0
  run summary ended ""
  assert_success
  [ -n "$output" ]
}

@test "a file at the pause path that is not a pause does not stop the claim" {
  held_record "shown" 1m 0
  printf 'hello\n' > "$TMPDIR/ada-paused"
  run summary ended ""
  assert_success
  [ -n "$output" ]
}

@test "the summary lists needs-you, then failed, then finished, oldest first in each" {
  held_record "done early" 1m 0 "" "" "" 1790000001
  held_record "🔐 Needs permission: bash" "" 0 "" "" "" 1790000004
  held_record "Paseo · needs you · a" permission 0 "" "" "" 1790000003
  held_record "make test" 5s 2 "" "" "" 1790000002
  held_record "⚠️ Error: overloaded" 1s 0 "" "" "" 1790000005
  held_record "done late" 1m 0 "" "" "" 1790000006
  run summary ended 1790000100
  assert_success
  local json; json=$(summary_json -b "${lines[0]}")
  assert_equal "$(json_get '[i["l"] for i in d["items"]]' <<<"$json")" \
    "['Paseo · needs you · a', '🔐 Needs permission: bash', 'make test', '⚠️ Error: overloaded', 'done early', 'done late']"
  assert_equal "$(json_get '[i["s"] for i in d["items"]]' <<<"$json")" "['ask', 'ask', 'fail', 'fail', 'ok', 'ok']"
  assert_equal "$(json_get 'd["v"], d["n"], d["why"], d["end"]' <<<"$json")" "(1, 6, 'ended', 1790000100)"
  # Nothing in these rows can open, so there is no target line.
  [ "${#lines[@]}" -eq 1 ]
  [ ! -e "$HELD" ]
  run ls "$TMPDIR"
  refute_output_contains "claim"
}

@test "a summary row carries every field the page reads" {
  held_record "the turn" "2m 3s" 0 claude-abc "claude://resume?session=abc" "" 1790000001 1 Claude
  run summary resumed ""
  local json; json=$(summary_json -b "${lines[0]}")
  assert_equal "$(json_get 'sorted(d["items"][0].items())' <<<"$json")" \
    "[('a', 'Claude'), ('c', '0'), ('d', '2m 3s'), ('k', 'conversation'), ('l', 'the turn'), ('o', 1), ('r', 'held-repo'), ('s', 'ok'), ('t', 1790000001), ('z', 1)]"
  # No end given: the pause ended now.
  (( $(json_get 'd["end"]' <<<"$json") >= $(/bin/date +%s) - 5 ))
}

@test "the targets line is aligned with the rows, a URL before an app" {
  held_record "url row" 1s 0 "" "claude://resume?session=a" com.example.term 1790000001
  held_record "app row" 1s 0 "" "" com.mitchellh.ghostty 1790000002
  held_record "nothing" 1s 0 "" "" "" 1790000003
  held_record "bad url" 1s 0 "" "not a url" "" 1790000004
  run summary ended ""
  assert_equal "${lines[1]}" '[{"url":"claude://resume?session=a"},{"app":"com.mitchellh.ghostty"},null,null]'
  assert_equal "$(summary_json -b "${lines[0]}" | json_get '[i["o"] for i in d["items"]]')" "[1, 1, 0, 0]"
}

@test "past 30 rows the summary keeps every urgent one and the newest finished ones" {
  local i
  for i in $(seq 1 40); do held_record "done $i" 1s 0 "" "" "" $(( 1790000000 + i )); done
  held_record "failed" 1s 1 "" "" "" 1790000000
  printf 'xxxxx' > "$HELD/overflow"
  run summary ended ""
  local json; json=$(summary_json -b "${lines[0]}")
  assert_equal "$(json_get 'd["n"], len(d["items"])' <<<"$json")" "(46, 30)"
  assert_equal "$(json_get 'd["items"][0]["l"], d["items"][1]["l"], d["items"][-1]["l"]' <<<"$json")" \
    "('failed', 'done 12', 'done 40')"
}

# The rows stop at 30, so the page cannot count the failed and needs-you ones
# from them: the totals go in the payload, taken before the cap.
@test "the failed and needs-you totals count every held alert, not only the rows sent" {
  local i
  for i in $(seq 1 40); do held_record "⚠️ Error: $i" 1s 0 "" "" "" $(( 1790000000 + i )); done
  for i in $(seq 1 3); do held_record "🔐 Needs permission: $i" "" 0 "" "" "" $(( 1790000100 + i )); done
  for i in $(seq 1 5); do held_record "done $i" 1s 0 "" "" "" $(( 1790000200 + i )); done
  printf 'xx' > "$HELD/overflow"
  run summary ended ""
  local json; json=$(summary_json -b "${lines[0]}")
  assert_equal "$(json_get 'd["n"], d["ask"], d["fail"], len(d["items"])' <<<"$json")" "(50, 3, 40, 30)"
  assert_equal "$(json_get 'sum(i["s"] == "fail" for i in d["items"])' <<<"$json")" 27
}

@test "the summary payload stays within 12000 characters" {
  local label i; label=$(printf '🔔%.0s' $(seq 1 120))
  for i in $(seq 1 30); do held_record "$label" 1s 0 "" "" "" $(( 1790000000 + i )); done
  run summary ended ""
  (( ${#lines[0]} <= 12000 )) || { echo "payload is ${#lines[0]} characters"; false; }
  local json; json=$(summary_json -b "${lines[0]}")
  assert_equal "$(json_get 'd["n"]' <<<"$json")" 30
  # The oldest finished rows went first.
  assert_equal "$(json_get 'd["items"][-1]["t"]' <<<"$json")" 1790000030
  assert_equal "$(json_get 'len(d["items"][0]["l"])' <<<"$json")" 120
}

@test "a muted session's records stay out of the summary" {
  held_record "muted one" 1s 0 claude-muted
  held_record "kept" 1s 0 claude-kept
  ADA_MUTED_KEYS=$'claude-muted\nzsh-1-2\n' run summary ended ""
  assert_equal "$(summary_json -b "${lines[0]}" | json_get '[i["l"] for i in d["items"]], d["n"]')" "(['kept'], 1)"
}

@test "only muted records make no summary at all" {
  held_record "muted one" 1s 0 claude-muted
  ADA_MUTED_KEYS=claude-muted run summary ended ""
  assert_success
  assert_equal "$output" ""
  [ ! -e "$HELD" ]
}

@test "nothing held makes no summary" {
  run summary ended ""
  assert_success
  assert_equal "$output" ""
}

@test "a claim left by a flush that died is shown with the next one, a fresh one is not" {
  local old="$PAUSE_FILE.claim.$(( $(/bin/date +%s) - 1200 )).999" fresh="$PAUSE_FILE.claim.$(/bin/date +%s).998"
  held_record "stale" 1s 0
  mv "$HELD" "$old"
  held_record "in flight" 1s 0
  mv "$HELD" "$fresh"
  held_record "new" 1s 0
  run summary ended ""
  assert_equal "$(summary_json -b "${lines[0]}" | json_get 'sorted(i["l"] for i in d["items"])')" "['new', 'stale']"
  [ ! -e "$old" ]
  [ -d "$fresh" ]
}

# Two flushes that both list a stale claim: the first is held up after it has
# read its claims and before it deletes them (a python3 shim stalls its first
# rmtree), and the second runs meanwhile. The stale rows must be in one
# summary, not both.
@test "a claim left by a flush that died is shown by only one of two flushes" {
  local stale="$PAUSE_FILE.claim.$(( $(/bin/date +%s) - 1200 )).999"
  held_record "stale" 1s 0
  mv "$HELD" "$stale"
  held_record "first" 1s 0
  local bin="$BATS_TEST_TMPDIR/stallbin" gate="$BATS_TEST_TMPDIR/gate"
  mkdir -p "$bin"
  cat > "$bin/stall.py" <<'EOF'
import os, shutil, sys, time
gate = os.environ["STALL_GATE"]
real = shutil.rmtree
def stalled(*args, **kwargs):
    shutil.rmtree = real
    open(gate + ".stalled", "w").close()
    for _ in range(400):
        if os.path.exists(gate + ".go"):
            break
        time.sleep(0.025)
    return real(*args, **kwargs)
shutil.rmtree = stalled
sys.argv = sys.argv[1:]
exec(compile(sys.stdin.read(), "<summary>", "exec"), {"__name__": "__main__"})
EOF
  printf '#!/bin/bash\nexec /usr/bin/python3 "%s" "$@"\n' "$bin/stall.py" > "$bin/python3"
  chmod +x "$bin/python3"
  ( export PATH="$bin:$PATH" STALL_GATE="$gate"; summary ended "" > "$BATS_TEST_TMPDIR/first.out" ) &
  local first=$! t=200
  until [ -e "$gate.stalled" ] || (( t-- == 0 )); do sleep 0.025; done
  [ -e "$gate.stalled" ] || { kill "$first"; echo "the first flush never got that far"; false; }
  held_record "second" 1s 0
  run summary ended ""
  touch "$gate.go"
  wait "$first"
  assert_equal "$(summary_json -b "${lines[0]}" | json_get 'sorted(i["l"] for i in d["items"])')" "['second']"
  assert_equal "$(summary_json -b "$(head -n 1 "$BATS_TEST_TMPDIR/first.out")" | json_get 'sorted(i["l"] for i in d["items"])')" \
    "['first', 'stale']"
  run ls "$TMPDIR"
  refute_output_contains "claim"
}

@test "records that are not ours are skipped" {
  held_record "good" 1s 0
  printf '2\t1790000000\tpaused\n' > "$HELD/1.1.1.tsv"
  printf 'garbage\n' > "$HELD/2.1.1.tsv"
  printf '1\t1\tpaused\t0\tk\tkind\tdot\t1s\t0\tr\t\t\t\t/\n' > "$HELD/.3.1.1.tsv.tmp"
  ln -s "$HELD/1.1.1.tsv" "$HELD/4.1.1.tsv"
  mkdir "$HELD/5.1.1.tsv"
  head -c 9000 /dev/zero | tr '\0' 'y' > "$HELD/6.1.1.tsv"
  run summary ended ""
  assert_equal "$(summary_json -b "${lines[0]}" | json_get '[i["l"] for i in d["items"]], d["n"]')" "(['good'], 1)"
}

@test "a symlink at the held path is never claimed" {
  mkdir -m 700 "$BATS_TEST_TMPDIR/elsewhere"
  printf '1\t1790000000\tpaused\t0\t\tk\tlabel\t1s\t0\tr\t\t\t\t/\n' > "$BATS_TEST_TMPDIR/elsewhere/1.1.1.tsv"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HELD"
  run summary ended ""
  assert_equal "$output" ""
  [ -L "$HELD" ] && [ -f "$BATS_TEST_TMPDIR/elsewhere/1.1.1.tsv" ]
}

@test "a row without a repo gets one from its directory, looked up once" {
  local proj="$BATS_TEST_TMPDIR/myproj"
  mkdir -p "$proj/sub" && git -C "$proj" init -q
  mkdir -m 700 "$HELD"
  printf '1\t1790000001\tpaused\t0\t\tk\tone\t1s\t0\t\t\t\t\t%s\n' "$proj/sub" > "$HELD/1.1.1.tsv"
  printf '1\t1790000002\tpaused\t0\t\tk\ttwo\t1s\t0\tinherited\t\t\t\t%s\n' "$proj" > "$HELD/2.1.1.tsv"
  printf '1\t1790000003\tpaused\t0\t\tk\tthree\t1s\t0\t\t\t\t\n' > "$HELD/3.1.1.tsv"
  run summary ended ""
  assert_equal "$(summary_json -b "${lines[0]}" | json_get '[i["r"] for i in d["items"]]')" "['myproj', 'inherited', '']"
}

# The menu bar resumes from a LaunchAgent, which must not look inside the home
# folder: ~/Documents would raise a privacy prompt. The launchd case keys on
# XPC_SERVICE_NAME, which can't be faked here: with it changed, the xcrun
# python3 and git shims in /usr/bin die of SIGTRAP on this machine. So this
# drives the status report's switch, which the same check honors.
@test "with ADA_STATUS_SKIP_PROTECTED the repo lookup skips the home folder" {
  local proj="$HOME/myproj"
  mkdir -p "$proj" && git -C "$proj" init -q
  mkdir -m 700 "$HELD"
  printf '1\t1790000001\tpaused\t0\t\tk\tone\t1s\t0\t\t\t\t\t%s\n' "$proj" > "$HELD/1.1.1.tsv"
  ADA_STATUS_SKIP_PROTECTED=1 run summary ended ""
  assert_equal "$(summary_json -b "${lines[0]}" | json_get 'd["items"][0]["r"]')" ""
}

@test "without python3 the summary claims nothing" {
  held_record "waits" 1s 0
  local bin="$BATS_TEST_TMPDIR/nopy"; mkdir -p "$bin"
  PATH="$bin:/bin" run bash -c ". '$REPO_ROOT/lib/ada-pause.sh'; __ada_pause_summary ended ''"
  assert_success
  assert_equal "$output" ""
  [ -d "$HELD" ]
}

# The script path is quoted for a shell, so the expected one is built with
# printf %q as well: a checkout path with a space in it must still pass. The
# PATH leaves out any ada-pause the developer has from Homebrew.
@test "the resume command names this script, with ~ for the home folder" {
  local root="$HOME/my ada" q
  mkdir -p "$root/lib"
  cp "$PAUSE" "$root/lib/"
  PATH=$(path_without_ada_pause) run bash -c ". '$root/lib/ada-pause.sh'; __ada_pause_resume_cmd c; printf '%s' \"\$c\""
  assert_equal "$output" '~/my\ ada/lib/ada-pause.sh resume'
  PATH=$(path_without_ada_pause) run bash -c ". '$PAUSE'; __ada_pause_resume_cmd c; printf '%s' \"\$c\""
  printf -v q '%q' "$REPO_ROOT/lib/ada-pause.sh"
  assert_equal "$output" "$q resume"
  local bin="$BATS_TEST_TMPDIR/brew"; mkdir -p "$bin"
  printf '#!/bin/bash\n' > "$bin/ada-pause"; chmod +x "$bin/ada-pause"
  PATH="$bin:$PATH" run bash -c ". '$PAUSE'; __ada_pause_resume_cmd c; printf '%s' \"\$c\""
  assert_equal "$output" "ada-pause resume"
}
