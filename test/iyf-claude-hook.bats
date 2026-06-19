#!/usr/bin/env bats
# Tests for lib/iyf-claude-hook.sh — the shared Claude Code / Codex hook.

setup() {
  load test_helper
  setup_common
  HOOK="$REPO_ROOT/lib/iyf-claude-hook.sh"
  STATE_DIR="$TMPDIR/iyf-claude"
  mkdir -p "$STATE_DIR"
  # Make the fire path deterministic: never skip on frontmost app.
  export IYF_SKIP_OWN_TERMINAL=0
  export IYF_SKIP_WHEN_ACTIVE=""
  export IYF_CLAUDE_THRESHOLD=45
}

# Stamp a session's start time (epoch) and prompt, as UserPromptSubmit would.
stamp_session() {
  local sid="$1" start="$2" prompt="$3"
  printf '%s' "$start" > "$STATE_DIR/$sid.start"
  printf '%s' "$prompt" > "$STATE_DIR/$sid.prompt"
}

run_hook() { run bash -c "printf '%s' '$1' | '$HOOK'"; }

@test "UserPromptSubmit records start time and prompt keyed by session id" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-1","prompt":"hello world","cwd":"/tmp"}'
  assert_success
  [ -f "$STATE_DIR/sess-1.start" ]
  assert_file_contains "$STATE_DIR/sess-1.prompt" "hello world"
  run cat "$STATE_DIR/sess-1.start"
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "malformed JSON is ignored (exit 0, no alert)" {
  run_hook 'not json'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
}

@test "Stop below threshold does not fire an alert" {
  stamp_session "sess-2" "$(( $(/bin/date +%s) - 5 ))" "quick turn"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-2","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
  [ ! -f "$STATE_DIR/sess-2.start" ]   # state consumed regardless
}

@test "Stop above threshold fires an alert with the saved prompt, duration and code" {
  stamp_session "sess-3" "$(( $(/bin/date +%s) - 120 ))" "long running task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-3","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$IYF_PROBE_OUT" "cmd=long%20running%20task"
  assert_file_contains "$IYF_PROBE_OUT" "code=0"
  # duration is a formatted string like "2m 0s" -> "duration=2m..."
  grep -Eq 'duration=[0-9]+m' "$IYF_PROBE_OUT" || { echo "duration missing/garbled:"; cat "$IYF_PROBE_OUT"; false; }
}

# Boundary: elapsed == threshold must FIRE (proves the comparison is `<`, not
# `<=`). STUB_NOW pins the clock so elapsed is exactly threshold, no jitter.
@test "Stop at exactly the threshold fires (kills the off-by-one mutant)" {
  export STUB_NOW=1000000
  export IYF_CLAUDE_THRESHOLD=60
  stamp_session "sess-b" "$(( 1000000 - 60 ))" "boundary"   # elapsed == 60
  run_hook '{"hook_event_name":"Stop","session_id":"sess-b","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "boundary alert should fire at elapsed==threshold"; false; }
}

@test "Stop one second under the threshold does not fire" {
  export STUB_NOW=1000000
  export IYF_CLAUDE_THRESHOLD=60
  stamp_session "sess-u" "$(( 1000000 - 59 ))" "under"      # elapsed == 59
  run_hook '{"hook_event_name":"Stop","session_id":"sess-u","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
}

# Paired control: identical fixture/threshold, only the elapsed side differs —
# proves the negative is caused by the threshold, not a globally dead fire path.
@test "the same threshold gates firing both ways" {
  export STUB_NOW=2000000
  export IYF_CLAUDE_THRESHOLD=100
  stamp_session "sess-lo" "$(( 2000000 - 40 ))" "below"     # 40 < 100 -> no fire
  run_hook '{"hook_event_name":"Stop","session_id":"sess-lo","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"

  rm -f "$IYF_PROBE_OUT"
  stamp_session "sess-hi" "$(( 2000000 - 140 ))" "above"    # 140 >= 100 -> fire
  run_hook '{"hook_event_name":"Stop","session_id":"sess-hi","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "above-threshold should fire"; false; }
}

@test "IYF_CLAUDE_THRESHOLD raises the bar for firing" {
  export IYF_CLAUDE_THRESHOLD=600
  stamp_session "sess-6" "$(( $(/bin/date +%s) - 120 ))" "task"   # 120s < 600s
  run_hook '{"hook_event_name":"Stop","session_id":"sess-6","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
}

@test "Stop skips the alert when you're watching the host terminal" {
  export IYF_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.test.term"   # frontmost == the terminal
  stamp_session "sess-4" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-4","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
}

@test "Stop still fires when a different app is frontmost" {
  export IYF_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"  # not the terminal
  stamp_session "sess-5" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-5","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "alert never fired"; false; }
}

# IYF_SKIP_WHEN_ACTIVE matches the frontmost app's display NAME by substring —
# a distinct arm from the exact bundleid match above.
@test "Stop skips when a skip-listed app name is frontmost (name substring match)" {
  export IYF_SKIP_OWN_TERMINAL=0
  export IYF_SKIP_WHEN_ACTIVE="Safari"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"
  export STUB_FRONT_NAME="Safari Technology Preview"   # contains "Safari"
  stamp_session "sess-n" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
}

@test "Stop fires when the frontmost app name is NOT in the skip list" {
  export IYF_SKIP_OWN_TERMINAL=0
  export IYF_SKIP_WHEN_ACTIVE="Firefox"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"
  export STUB_FRONT_NAME="Safari Technology Preview"   # does not contain "Firefox"
  stamp_session "sess-n2" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n2","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "should fire when name not skip-listed"; false; }
}

@test "Codex parity: Stop with an unknown session id falls back to the recent stamp" {
  stamp_session "sessA" "$(( $(/bin/date +%s) - 120 ))" "fallback task"
  run_hook '{"hook_event_name":"Stop","session_id":"different-id","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "fallback alert never fired"; false; }
  assert_file_contains "$IYF_PROBE_OUT" "cmd=fallback%20task"
}

# The fallback must DROP a stamp older than IYF_CLAUDE_STALE_MAX, and must not
# consume another session's stale state.
@test "Codex parity: a stale fallback stamp is dropped, not fired" {
  export IYF_CLAUDE_STALE_MAX=60
  stamp_session "sessOld" "$(( $(/bin/date +%s) - 120 ))" "stale task"
  touch -t 202001010000 "$STATE_DIR/sessOld.start"   # mtime far in the past
  run_hook '{"hook_event_name":"Stop","session_id":"unrelated-id","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$IYF_PROBE_OUT"
  [ -f "$STATE_DIR/sessOld.start" ]   # stale state left intact, not consumed
}

@test "Codex parity: a fresh fallback stamp fires even under a low stale cutoff" {
  export IYF_CLAUDE_STALE_MAX=60
  stamp_session "sessFresh" "$(( $(/bin/date +%s) - 120 ))" "fresh task"
  # mtime is ~now (just written), so it's within the 60s cutoff
  run_hook '{"hook_event_name":"Stop","session_id":"unrelated-id","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_OUT" || { echo "fresh fallback should fire"; false; }
  assert_file_contains "$IYF_PROBE_OUT" "cmd=fresh%20task"
}

# --- claude://resume deep link (click-to-open the conversation) ---------------
# The hook builds IYF_CLICK_URL only for a genuine Claude Code session: a UUID id
# that has a transcript on disk. fake-iyf-alert records the inherited value into
# IYF_PROBE_ENV_OUT, so these assert the gate without the loopback daemon.

UUID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

@test "Stop sets the resume deep link when the session has a transcript" {
  export IYF_PROBE_ENV_OUT="$BATS_TEST_TMPDIR/probe-env.txt"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  export IYF_AUTO_CLOSE=1   # the click target spawns the daemon; keep it short-lived
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/some-proj"
  : > "$CLAUDE_CONFIG_DIR/projects/some-proj/$UUID.jsonl"
  stamp_session "$UUID" "$(( $(/bin/date +%s) - 120 ))" "deep link task"
  run_hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"$UUID\",\"cwd\":\"/tmp\"}"
  assert_success
  wait_for_file "$IYF_PROBE_ENV_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$IYF_PROBE_ENV_OUT" "IYF_CLICK_URL=claude://resume?session=$UUID"
}

@test "Stop sets no deep link when a UUID session has no transcript on disk" {
  export IYF_PROBE_ENV_OUT="$BATS_TEST_TMPDIR/probe-env.txt"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects"   # exists but holds no transcript
  stamp_session "$UUID" "$(( $(/bin/date +%s) - 120 ))" "no transcript"
  run_hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"$UUID\",\"cwd\":\"/tmp\"}"
  assert_success
  wait_for_file "$IYF_PROBE_ENV_OUT" || { echo "alert never fired"; false; }
  run cat "$IYF_PROBE_ENV_OUT"
  assert_equal "$output" "IYF_CLICK_URL="
}

@test "Stop sets no deep link for a non-UUID (Codex-style) session id" {
  export IYF_PROBE_ENV_OUT="$BATS_TEST_TMPDIR/probe-env.txt"
  stamp_session "codex-session-7" "$(( $(/bin/date +%s) - 120 ))" "codex turn"
  run_hook '{"hook_event_name":"Stop","session_id":"codex-session-7","cwd":"/tmp"}'
  assert_success
  wait_for_file "$IYF_PROBE_ENV_OUT" || { echo "alert never fired"; false; }
  run cat "$IYF_PROBE_ENV_OUT"
  assert_equal "$output" "IYF_CLICK_URL="
}
