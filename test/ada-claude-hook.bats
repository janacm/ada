#!/usr/bin/env bats
# Tests for lib/ada-claude-hook.sh — the shared Claude Code / Codex hook.

setup() {
  load test_helper
  setup_common
  HOOK="$REPO_ROOT/lib/ada-claude-hook.sh"
  STATE_DIR="$TMPDIR/ada-claude"
  mkdir -p "$STATE_DIR"
  # Make the fire path deterministic: never skip on frontmost app.
  export ADA_SKIP_OWN_TERMINAL=0
  export ADA_SKIP_WHEN_ACTIVE=""
  export ADA_CLAUDE_THRESHOLD=45
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
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "Stop below threshold does not fire an alert" {
  stamp_session "sess-2" "$(( $(/bin/date +%s) - 5 ))" "quick turn"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-2","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  [ ! -f "$STATE_DIR/sess-2.start" ]   # state consumed regardless
}

@test "Stop above threshold fires an alert with the saved prompt, duration and code" {
  stamp_session "sess-3" "$(( $(/bin/date +%s) - 120 ))" "long running task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-3","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=long%20running%20task"
  assert_file_contains "$ADA_PROBE_OUT" "code=0"
  # duration is a formatted string like "2m 0s" -> "duration=2m..."
  grep -Eq 'duration=[0-9]+m' "$ADA_PROBE_OUT" || { echo "duration missing/garbled:"; cat "$ADA_PROBE_OUT"; false; }
}

# Boundary: elapsed == threshold must FIRE (proves the comparison is `<`, not
# `<=`). STUB_NOW pins the clock so elapsed is exactly threshold, no jitter.
@test "Stop at exactly the threshold fires (kills the off-by-one mutant)" {
  export STUB_NOW=1000000
  export ADA_CLAUDE_THRESHOLD=60
  stamp_session "sess-b" "$(( 1000000 - 60 ))" "boundary"   # elapsed == 60
  run_hook '{"hook_event_name":"Stop","session_id":"sess-b","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "boundary alert should fire at elapsed==threshold"; false; }
}

@test "Stop one second under the threshold does not fire" {
  export STUB_NOW=1000000
  export ADA_CLAUDE_THRESHOLD=60
  stamp_session "sess-u" "$(( 1000000 - 59 ))" "under"      # elapsed == 59
  run_hook '{"hook_event_name":"Stop","session_id":"sess-u","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

# Paired control: identical fixture/threshold, only the elapsed side differs —
# proves the negative is caused by the threshold, not a globally dead fire path.
@test "the same threshold gates firing both ways" {
  export STUB_NOW=2000000
  export ADA_CLAUDE_THRESHOLD=100
  stamp_session "sess-lo" "$(( 2000000 - 40 ))" "below"     # 40 < 100 -> no fire
  run_hook '{"hook_event_name":"Stop","session_id":"sess-lo","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"

  rm -f "$ADA_PROBE_OUT"
  stamp_session "sess-hi" "$(( 2000000 - 140 ))" "above"    # 140 >= 100 -> fire
  run_hook '{"hook_event_name":"Stop","session_id":"sess-hi","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "above-threshold should fire"; false; }
}

@test "ADA_CLAUDE_THRESHOLD raises the bar for firing" {
  export ADA_CLAUDE_THRESHOLD=600
  stamp_session "sess-6" "$(( $(/bin/date +%s) - 120 ))" "task"   # 120s < 600s
  run_hook '{"hook_event_name":"Stop","session_id":"sess-6","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "Stop skips the alert when you're watching the host terminal" {
  export ADA_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.test.term"   # frontmost == the terminal
  stamp_session "sess-4" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-4","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "Stop still fires when a different app is frontmost" {
  export ADA_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"  # not the terminal
  stamp_session "sess-5" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-5","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
}

# ADA_SKIP_WHEN_ACTIVE matches the frontmost app's display NAME by substring —
# a distinct arm from the exact bundleid match above.
@test "Stop skips when a skip-listed app name is frontmost (name substring match)" {
  export ADA_SKIP_OWN_TERMINAL=0
  export ADA_SKIP_WHEN_ACTIVE="Safari"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"
  export STUB_FRONT_NAME="Safari Technology Preview"   # contains "Safari"
  stamp_session "sess-n" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "Stop fires when the frontmost app name is NOT in the skip list" {
  export ADA_SKIP_OWN_TERMINAL=0
  export ADA_SKIP_WHEN_ACTIVE="Firefox"
  export STUB_FRONT_BUNDLEID="com.apple.Safari"
  export STUB_FRONT_NAME="Safari Technology Preview"   # does not contain "Firefox"
  stamp_session "sess-n2" "$(( $(/bin/date +%s) - 120 ))" "task"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n2","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "should fire when name not skip-listed"; false; }
}

@test "Codex parity: Stop with an unknown session id falls back to the recent stamp" {
  stamp_session "sessA" "$(( $(/bin/date +%s) - 120 ))" "fallback task"
  run_hook '{"hook_event_name":"Stop","session_id":"different-id","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "fallback alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=fallback%20task"
}

# The fallback must DROP a stamp older than ADA_CLAUDE_STALE_MAX, and must not
# consume another session's stale state.
@test "Codex parity: a stale fallback stamp is dropped, not fired" {
  export ADA_CLAUDE_STALE_MAX=60
  stamp_session "sessOld" "$(( $(/bin/date +%s) - 120 ))" "stale task"
  touch -t 202001010000 "$STATE_DIR/sessOld.start"   # mtime far in the past
  run_hook '{"hook_event_name":"Stop","session_id":"unrelated-id","cwd":"/tmp"}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  [ -f "$STATE_DIR/sessOld.start" ]   # stale state left intact, not consumed
}

@test "Codex parity: a fresh fallback stamp fires even under a low stale cutoff" {
  export ADA_CLAUDE_STALE_MAX=60
  stamp_session "sessFresh" "$(( $(/bin/date +%s) - 120 ))" "fresh task"
  # mtime is ~now (just written), so it's within the 60s cutoff
  run_hook '{"hook_event_name":"Stop","session_id":"unrelated-id","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "fresh fallback should fire"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=fresh%20task"
}

# --- claude://resume deep link (click-to-open the conversation) ---------------
# The hook builds ADA_CLICK_URL only for a genuine Claude Code session: a UUID id
# that has a transcript on disk. fake-ada-alert records the inherited value into
# ADA_PROBE_ENV_OUT, so these assert the gate without the loopback daemon.

UUID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

@test "Stop sets the resume deep link when the session has a transcript" {
  export ADA_PROBE_ENV_OUT="$BATS_TEST_TMPDIR/probe-env.txt"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  export ADA_AUTO_CLOSE=1   # the click target spawns the daemon; keep it short-lived
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/some-proj"
  : > "$CLAUDE_CONFIG_DIR/projects/some-proj/$UUID.jsonl"
  stamp_session "$UUID" "$(( $(/bin/date +%s) - 120 ))" "deep link task"
  run_hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"$UUID\",\"cwd\":\"/tmp\"}"
  assert_success
  wait_for_file "$ADA_PROBE_ENV_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_ENV_OUT" "ADA_CLICK_URL=claude://resume?session=$UUID"
}

@test "Stop sets no deep link when a UUID session has no transcript on disk" {
  export ADA_PROBE_ENV_OUT="$BATS_TEST_TMPDIR/probe-env.txt"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects"   # exists but holds no transcript
  stamp_session "$UUID" "$(( $(/bin/date +%s) - 120 ))" "no transcript"
  run_hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"$UUID\",\"cwd\":\"/tmp\"}"
  assert_success
  wait_for_file "$ADA_PROBE_ENV_OUT" || { echo "alert never fired"; false; }
  run cat "$ADA_PROBE_ENV_OUT"
  assert_equal "$output" "ADA_CLICK_URL="
}

@test "Stop sets no deep link for a non-UUID (Codex-style) session id" {
  export ADA_PROBE_ENV_OUT="$BATS_TEST_TMPDIR/probe-env.txt"
  stamp_session "codex-session-7" "$(( $(/bin/date +%s) - 120 ))" "codex turn"
  run_hook '{"hook_event_name":"Stop","session_id":"codex-session-7","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_ENV_OUT" || { echo "alert never fired"; false; }
  run cat "$ADA_PROBE_ENV_OUT"
  assert_equal "$output" "ADA_CLICK_URL="
}

# --- displayable labels for agent-injected prompts -------------------------
#
# UserPromptSubmit does NOT only carry what the user typed: the agent fires the
# same hook for messages it injects (a background task finishing, a slash
# command, a system reminder). Those arrive as raw XML-ish blocks, and rendering
# one verbatim filled the whole alert with <task-notification><task-id>… .

# The exact payload shape captured from a live Claude Code session.
@test "a background-task notification is labelled from its summary" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n1","cwd":"/tmp","prompt":"<task-notification>\n<task-id>brdunbr1u</task-id>\n<tool-use-id>toolu_01129shSAwBXkMWiPR8jhHb6</tool-use-id>\n<output-file>/private/tmp/x/tasks/brdunbr1u.output</output-file>\n<status>completed</status>\n<summary>Background command \"Run the full suite\" completed (exit code 0)</summary>\n</task-notification>"}'
  assert_success
  assert_file_contains "$STATE_DIR/sess-n1.prompt" 'Background command "Run the full suite" completed'
  # None of the machine detail may reach the alert.
  refute_file_contains "$STATE_DIR/sess-n1.prompt" "task-notification"
  refute_file_contains "$STATE_DIR/sess-n1.prompt" "toolu_"
  refute_file_contains "$STATE_DIR/sess-n1.prompt" "brdunbr1u"
}

@test "the summary label survives all the way to the alert" {
  stamp=$(( $(/bin/date +%s) - 120 ))
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n2","cwd":"/tmp","prompt":"<task-notification>\n<task-id>abc</task-id>\n<summary>Background command \"make build\" completed (exit code 0)</summary>\n</task-notification>"}'
  assert_success
  # Backdate the stamp so the turn clears the threshold.
  printf '%s' "$stamp" > "$STATE_DIR/sess-n2.start"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n2","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "make%20build"
  refute_file_contains "$ADA_PROBE_OUT" "task-notification"
}

@test "a slash command is labelled with the command and its arguments" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n3","cwd":"/tmp","prompt":"<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship the opencode integration</command-args>"}'
  assert_success
  assert_file_contains "$STATE_DIR/sess-n3.prompt" "/goal ship the opencode integration"
  refute_file_contains "$STATE_DIR/sess-n3.prompt" "command-name"
}

@test "a slash command with no arguments keeps just the command name" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n4","cwd":"/tmp","prompt":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}'
  assert_success
  run cat "$STATE_DIR/sess-n4.prompt"
  assert_equal "$output" "/clear"
}

@test "a fully tag-wrapped injected block is reduced to its prose" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n5","cwd":"/tmp","prompt":"<local-command-stdout>Goal set: ship the thing</local-command-stdout>"}'
  assert_success
  run cat "$STATE_DIR/sess-n5.prompt"
  assert_equal "$output" "Goal set: ship the thing"
}

# The control that keeps the sanitizer from eating real prompts: markup at the
# START of a typed prompt is not enough to call it machine-generated.
@test "a typed prompt that merely opens with markup is left verbatim" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n6","cwd":"/tmp","prompt":"<div>foo</div> is not centering"}'
  assert_success
  run cat "$STATE_DIR/sess-n6.prompt"
  assert_equal "$output" "<div>foo</div> is not centering"
}

@test "an ordinary typed prompt is untouched" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n7","cwd":"/tmp","prompt":"fix the login bug in <Header /> please"}'
  assert_success
  run cat "$STATE_DIR/sess-n7.prompt"
  assert_equal "$output" "fix the login bug in <Header /> please"
}

@test "a multi-line prompt is collapsed to one line" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n8","cwd":"/tmp","prompt":"first line\n\n   second    line"}'
  assert_success
  run cat "$STATE_DIR/sess-n8.prompt"
  assert_equal "$output" "first line second line"
}

# An injected block whose only content is metadata must reach the generic
# fallback, not an alert labelled with a leftover id. The earlier version of
# this test used <ping><id>7</id></ping> and passed while the label was the
# bare string "7", because its only assertion was that "ping" was absent.
@test "an injected block of pure metadata falls back to a generic label" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n9","cwd":"/tmp","prompt":"<ada-ping><id>7</id><status>ok</status></ada-ping>"}'
  assert_success
  run cat "$STATE_DIR/sess-n9.prompt"
  assert_equal "$output" ""
  printf '%s' "$(( $(/bin/date +%s) - 120 ))" > "$STATE_DIR/sess-n9.start"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n9","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=Claude%20Code"
  refute_file_contains "$ADA_PROBE_OUT" "ada-ping"
}

# A task notification carries ids and a status but not always a summary; none of
# that metadata may become the label.
@test "a task notification with no summary falls back to a generic label" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n11","cwd":"/tmp","prompt":"<task-notification>\n<task-id>brdunbr1u</task-id>\n<tool-use-id>toolu_01129</tool-use-id>\n<status>completed</status>\n</task-notification>"}'
  assert_success
  run cat "$STATE_DIR/sess-n11.prompt"
  assert_equal "$output" ""
  printf '%s' "$(( $(/bin/date +%s) - 120 ))" > "$STATE_DIR/sess-n11.start"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n11","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=Claude%20Code"
  refute_file_contains "$ADA_PROBE_OUT" "brdunbr1u"
}

# The hyphen in the outer tag is the signal. A prompt that is WHOLLY markup but
# uses a plain HTML element name is a prompt, not an injected block: the HTML
# spec reserves the hyphen for custom elements precisely to make this
# distinction, and injected blocks all use hyphenated names.
@test "a typed prompt that is entirely HTML markup is left verbatim" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n12","cwd":"/tmp","prompt":"<div>foo</div>"}'
  assert_success
  run cat "$STATE_DIR/sess-n12.prompt"
  assert_equal "$output" "<div>foo</div>"
}

# Pasting a collapsed log and then asking a question is an ordinary prompt, and
# <details><summary> would otherwise hit the summary extractor and throw the
# question away.
@test "a pasted details/summary block keeps the question that follows it" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n13","cwd":"/tmp","prompt":"<details>\n<summary>build log</summary>\nlots of noise\n</details>\n\nwhy does this test fail?"}'
  assert_success
  assert_file_contains "$STATE_DIR/sess-n13.prompt" "why does this test fail?"
  refute_file_contains "$STATE_DIR/sess-n13.prompt" "⚙️"
}

# The Claude desktop app wraps a paste as <pasted_content id="c339"> ...
# </pasted_content id="c339">, id repeated on the closing tag. Before the fix the
# alert read "create a plan for <pasted_content id="c339"> hey …".
@test "a desktop-app paste after typed text collapses to a placeholder" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-p1","cwd":"/tmp","prompt":" pull latest main and then create a plan for \n\n<pasted_content id=\"c339\">\nhey can you look at the eval\nlots more\n</pasted_content id=\"c339\">\n"}'
  assert_success
  run cat "$STATE_DIR/sess-p1.prompt"
  assert_equal "$output" "pull latest main and then create a plan for [pasted text]"
}

@test "a paste followed by a typed question keeps the question" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-p2","cwd":"/tmp","prompt":"<pasted_content id=\"6255\">\nTraceback (most recent call last)\n</pasted_content id=\"6255\">\n\nwhy does this fail?"}'
  assert_success
  run cat "$STATE_DIR/sess-p2.prompt"
  assert_equal "$output" "[pasted text] why does this fail?"
}

# A lone placeholder names nothing, so a prompt that is only a paste shows it.
@test "a prompt that is only a paste shows the pasted text" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-p3","cwd":"/tmp","prompt":"<pasted_content id=\"a1\">\nhey, can you review my PR?\n</pasted_content id=\"a1\">"}'
  assert_success
  run cat "$STATE_DIR/sess-p3.prompt"
  assert_equal "$output" "hey, can you review my PR?"
}

@test "a plain closing tag and multiple pastes are both handled" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-p4","cwd":"/tmp","prompt":"compare <pasted_content>one</pasted_content> with <pasted_content id=\"b2\">two</pasted_content id=\"b2\">"}'
  assert_success
  run cat "$STATE_DIR/sess-p4.prompt"
  assert_equal "$output" "compare [pasted text] with [pasted text]"
}

@test "an unclosed paste tag is dropped rather than shown" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-p5","cwd":"/tmp","prompt":"look at <pasted_content id=\"c9\"> this log"}'
  assert_success
  run cat "$STATE_DIR/sess-p5.prompt"
  assert_equal "$output" "look at this log"
}

@test "the paste placeholder survives all the way to the alert" {
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-p6","cwd":"/tmp","prompt":"plan for <pasted_content id=\"c339\">hey</pasted_content id=\"c339\">"}'
  assert_success
  printf '%s' "$(( $(/bin/date +%s) - 120 ))" > "$STATE_DIR/sess-p6.start"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-p6","cwd":"/tmp"}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=plan%20for%20%5Bpasted%20text%5D"
  refute_file_contains "$ADA_PROBE_OUT" "c339"
}

# clean() is shared with cwd and transcript_path, so collapsing whitespace there
# would corrupt any path containing a double space: the repo badge would vanish
# (git -C on a squeezed path) and the turn-error detection would silently stop
# working (its -f test would fail).
@test "a path containing a double space survives intact" {
  mkdir -p "$BATS_TEST_TMPDIR/My  Project"
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n14","cwd":"'"$BATS_TEST_TMPDIR/My  Project"'","prompt":"work"}'
  assert_success
  printf '%s' "$(( $(/bin/date +%s) - 120 ))" > "$STATE_DIR/sess-n14.start"
  export ADA_DEBUG_LOG=1
  export ADA_DEBUG_LOG_FILE="$BATS_TEST_TMPDIR/paths.log"
  run_hook '{"hook_event_name":"Stop","session_id":"sess-n14","cwd":"'"$BATS_TEST_TMPDIR/My  Project"'"}'
  assert_success
  assert_file_contains "$ADA_DEBUG_LOG_FILE" "My  Project"
}

# The debug breadcrumb is the tool for diagnosing a NEW injected shape, so it
# must keep logging the raw prompt even though the alert shows the label.
@test "the debug log keeps the raw prompt, not the cleaned label" {
  export ADA_DEBUG_LOG=1
  export ADA_DEBUG_LOG_FILE="$BATS_TEST_TMPDIR/debug.log"
  run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"sess-n10","cwd":"/tmp","prompt":"<task-notification>\n<task-id>zzz</task-id>\n<summary>all done</summary>\n</task-notification>"}'
  assert_success
  assert_file_contains "$ADA_DEBUG_LOG_FILE" "task-notification"
}
