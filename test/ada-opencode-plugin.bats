#!/usr/bin/env bats
# Tests for lib/ada-opencode-plugin.mjs — the opencode integration.
#
# These drive the REAL plugin through test/opencode_plugin_drive.mjs and let it
# call the real lib/ada-notify.sh and lib/ada-show-alert.sh, so an assertion
# failure means the chain opencode actually uses is broken, not a mock of it.
# Only the native helper (and lsappinfo) are stubbed.

setup() {
  load test_helper
  setup_common
  command -v node >/dev/null 2>&1 || skip "node is required to drive the opencode plugin"
  DRIVER="$BATS_TEST_DIRNAME/opencode_plugin_drive.mjs"
  # Make the fire path deterministic: never skip on frontmost app.
  export ADA_SKIP_OWN_TERMINAL=0
  export ADA_SKIP_WHEN_ACTIVE=""
  export ADA_OPENCODE_THRESHOLD=45
}

# Replay a JSON program against the plugin.
drive() { run bash -c "printf '%s' '$1' | node '$DRIVER'"; }

idle() { printf '{"type":"event","event":{"type":"session.idle","properties":{"sessionID":"%s"}}}' "$1"; }

@test "a finished turn over the threshold alerts with the prompt as the label" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"refactor the parser","ageSeconds":120},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=refactor%20the%20parser"
  assert_file_contains "$ADA_PROBE_OUT" "duration=2m 0s"
}

@test "a turn under the threshold stays silent" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"quick question","ageSeconds":5},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

# Boundary: elapsed == threshold must fire (proves the comparison is `<`).
@test "a turn exactly at the threshold fires" {
  export ADA_OPENCODE_THRESHOLD=60
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"boundary","ageSeconds":60},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "should fire at elapsed == threshold"; false; }
}

@test "a turn one second under the threshold does not fire" {
  export ADA_OPENCODE_THRESHOLD=60
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"under","ageSeconds":59},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "ADA_OPENCODE_THRESHOLD raises the bar" {
  export ADA_OPENCODE_THRESHOLD=600
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"two minutes","ageSeconds":120},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "idle without a recorded turn does not alert" {
  drive '{"steps":['"$(idle ghost)"']}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "a failed turn alerts below the threshold, labelled as an error" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"do a thing","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"APIError","data":{"message":"overloaded_error"}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "an error should alert regardless of duration"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "overloaded_error"
}

# session.error arrives just before session.idle, so a failed turn must produce
# ONE alert, not an error alert plus a finish alert.
@test "a failed turn produces exactly one alert" {
  export ADA_NATIVE_ALERT="$STUBS/counting-ada-alert"
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"do a thing","ageSeconds":300},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"APIError","data":{"message":"boom"}}}}},
    '"$(idle s1)"',
    {"type":"settle","ms":500}
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  run wc -l < "$ADA_PROBE_OUT"
  assert_equal "$(echo $output)" "1"
}

@test "an error with no session id alerts immediately" {
  drive '{"steps":[
    {"type":"event","event":{"type":"session.error","properties":{
      "error":{"name":"UnknownError","data":{"message":"Model not found: openai/gpt-4o"}}}}},
    {"type":"settle","ms":400}
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "a session-less error should still alert"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "Model%20not%20found"
}

# A subagent's session.idle is not your turn ending — the parent is still busy.
@test "a sub-session (parentID set) never alerts" {
  drive '{"steps":[
    {"type":"event","event":{"type":"session.created","properties":{"info":
      {"id":"child1","parentID":"s1","directory":"/tmp"}}}},
    {"type":"chat.message","sessionID":"child1","text":"subagent work","ageSeconds":300},
    '"$(idle child1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

# Paired control: same timings, no parentID -> the alert does fire.
@test "a root session with the same timings does alert" {
  drive '{"steps":[
    {"type":"event","event":{"type":"session.created","properties":{"info":
      {"id":"s1","directory":"/tmp"}}}},
    {"type":"chat.message","sessionID":"s1","text":"root work","ageSeconds":300},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "root session should alert"; false; }
}

@test "a pending permission alerts with no duration and leaves the turn running" {
  export ADA_NATIVE_ALERT="$STUBS/counting-ada-alert"
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"edit the file","ageSeconds":300},
    {"type":"event","event":{"type":"permission.asked","properties":{"id":"per_1",
      "sessionID":"s1","permission":"bash","metadata":{"command":"rm -rf build"}}}},
    {"type":"settle","ms":400},
    '"$(idle s1)"',
    {"type":"settle","ms":400}
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "permission alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "rm%20-rf%20build"
  # ...and the finish alert still fired afterwards: two alerts total.
  wait_for_lines "$ADA_PROBE_OUT" 2
  run wc -l < "$ADA_PROBE_OUT"
  assert_equal "$(echo $output)" "2"
}

@test "the same permission id does not alert twice" {
  export ADA_NATIVE_ALERT="$STUBS/counting-ada-alert"
  drive '{"steps":[
    {"type":"event","event":{"type":"permission.asked","properties":{"id":"per_1",
      "sessionID":"s1","permission":"bash","metadata":{"command":"ls"}}}},
    {"type":"settle","ms":300},
    {"type":"event","event":{"type":"permission.asked","properties":{"id":"per_1",
      "sessionID":"s1","permission":"bash","metadata":{"command":"ls"}}}},
    {"type":"settle","ms":400}
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  run wc -l < "$ADA_PROBE_OUT"
  assert_equal "$(echo $output)" "1"
}

# The 1.18.20 sdk types call this event permission.updated; the 1.18.30 binary
# emits permission.asked. Both spellings have to work.
@test "the permission.updated spelling is handled too" {
  drive '{"steps":[
    {"type":"event","event":{"type":"permission.updated","properties":{"id":"per_2",
      "sessionID":"s1","type":"edit","title":"Edit src/main.ts"}}},
    {"type":"settle","ms":400}
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "permission.updated should alert"; false; }
  # the launcher url-encodes spaces but leaves path separators alone
  assert_file_contains "$ADA_PROBE_OUT" "Edit%20src/main.ts"
}

@test "ADA_OPENCODE_EVENTS can drop the permission alerts" {
  export ADA_OPENCODE_EVENTS="finish error"
  drive '{"steps":[
    {"type":"event","event":{"type":"permission.asked","properties":{"id":"per_1",
      "sessionID":"s1","permission":"bash","metadata":{"command":"ls"}}}},
    {"type":"settle","ms":400}
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "ADA_OPENCODE_EVENTS can drop the finish alerts" {
  export ADA_OPENCODE_EVENTS="error permission"
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long task","ageSeconds":300},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "an empty ADA_OPENCODE_EVENTS disables the integration" {
  export ADA_OPENCODE_EVENTS=""
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long task","ageSeconds":300},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "stays silent when you are watching the terminal hosting opencode" {
  export ADA_SKIP_OWN_TERMINAL=1
  export __CFBundleIdentifier="com.test.term"
  export STUB_FRONT_BUNDLEID="com.test.term"
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long task","ageSeconds":300},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "the session directory drives the repo badge" {
  drive '{"steps":[
    {"type":"event","event":{"type":"session.created","properties":{"info":
      {"id":"s1","directory":"'"$REPO_ROOT"'"}}}},
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":300},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "repo=ada"
}

@test "a multi-part prompt uses only its text parts" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","ageSeconds":300,
     "parts":[{"type":"file","filename":"a.png"},{"type":"text","text":"describe this"}]},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "cmd=describe%20this"
  refute_file_contains "$ADA_PROBE_OUT" "a.png"
}

@test "a prompt with no text falls back to a generic label" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","ageSeconds":300,"parts":[]},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "cmd=opencode"
}

@test "a long prompt is clipped, not passed through whole" {
  long=$(printf 'x%.0s' {1..400})
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"'"$long"'","ageSeconds":300},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "%E2%80%A6"   # the ellipsis
  run bash -c "grep -o 'cmd=[^&]*' '$ADA_PROBE_OUT' | head -1 | wc -c"
  [ "$(echo $output)" -lt 400 ]
}

# --- which errors are worth interrupting for -------------------------------

# You pressed Esc: you were at the keyboard to stop the turn, so neither an
# error alert nor a finish alert should fire — even for a long turn.
@test "an aborted turn alerts neither as an error nor as a finish" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long task","ageSeconds":300},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"MessageAbortedError","data":{"message":"aborted"}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

# Paired control: same long turn, a real error instead of an abort -> alerts.
@test "the same long turn with a real error does alert" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long task","ageSeconds":300},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"UnknownError","data":{"message":"something broke"}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "a real error should alert"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "something%20broke"
}

# MessageOutputLengthError is the one error with no data.message at all, so a
# naive `data.message || name` would show the bare class name.
@test "an output-length error alerts with readable text despite carrying no message" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"write a novel","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"MessageOutputLengthError","data":{}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "output-length error should alert"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "output%20length%20limit"
  refute_file_contains "$ADA_PROBE_OUT" "MessageOutputLengthError"
}

# The provider id tells you which `opencode auth login` to run.
@test "a provider auth error names the provider" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"ProviderAuthError","data":{"providerID":"anthropic",
        "message":"credentials expired"}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "auth error should alert"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "anthropic%20auth%20failed"
  assert_file_contains "$ADA_PROBE_OUT" "credentials%20expired"
}

@test "an api error appends the http status" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"APIError","data":{"message":"overloaded_error",
        "statusCode":529,"isRetryable":true}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "api error should alert"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "overloaded_error%20%28HTTP%20529%29"
}

# A retryable error reaching session.error is terminal — opencode's own retries
# are announced as session.status retry and happen before this point — so
# isRetryable must NOT silence the alert.
@test "a retryable api error still alerts" {
  export ADA_OPENCODE_THRESHOLD=600
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":3},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"APIError","data":{"message":"rate limited","isRetryable":true}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "retryable error should still alert"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "rate%20limited"
}

@test "an api error with no message falls back to the status" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"APIError","data":{"statusCode":500}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "should alert with the status alone"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "API%20error%20500"
}

@test "an error event with no error object at all is ignored" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1"}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

# ...but "ignored" must mean "left alone", not "silenced". The sdk declares
# EventSessionError.properties.error OPTIONAL, so an empty error event is a
# valid payload, and treating it like an abort swallowed the finish alert for a
# turn that really did run for ten minutes. ageSeconds is over the threshold
# here precisely so a silenced turn is visible.
@test "an unrecognisable error does not swallow the finish alert" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long real turn","ageSeconds":600},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1"}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "the finish alert should still fire"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=long%20real%20turn"
}

@test "an error with an unknown name does not swallow the finish alert either" {
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long real turn","ageSeconds":600},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"SomeFutureError","data":{}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "an undescribable error must not silence the turn"; false; }
}

# The abort suppression is turn lifecycle, not a feature of the error category,
# so dropping "error" from ADA_OPENCODE_EVENTS must not resurrect the spurious
# finish alert for a turn the user cancelled.
@test "an aborted turn stays silent even with error alerts switched off" {
  export ADA_OPENCODE_EVENTS="finish permission"
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"long task I pressed Esc on","ageSeconds":600},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"MessageAbortedError","data":{"message":"aborted"}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "a composed error label is clipped, prefix included" {
  long=$(printf 'e%.0s' {1..400})
  drive '{"steps":[
    {"type":"chat.message","sessionID":"s1","text":"work","ageSeconds":2},
    {"type":"event","event":{"type":"session.error","properties":{"sessionID":"s1",
      "error":{"name":"UnknownError","data":{"message":"'"$long"'"}}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  # The label carries the prefix AND is bounded: decode cmdb64 and measure it.
  # A heredoc keeps the python readable instead of fighting three quoting layers.
  run python3 - "$ADA_PROBE_OUT" <<'PY'
import base64, re, sys
url = open(sys.argv[1]).read()
blob = re.search(r"cmdb64=([^&\s]+)", url).group(1)
blob += "=" * (-len(blob) % 4)
text = base64.urlsafe_b64decode(blob).decode()
assert text.startswith("\u26a0\ufe0f Error: "), text[:40]
print(len(text))
PY
  assert_success
  # 121 = MAX_LABEL + the ellipsis that replaces what was cut, which is exactly
  # what ada-claude-hook.sh produces for its own composed label.
  [ "$output" -le 121 ] || { echo "composed label was $output chars, expected <= 121"; false; }
}

# 1.18.30 sends `patterns: []`; the 1.18.20 sdk types say `pattern` may itself
# be an array. Neither may reach the label as "a,b" via String().
@test "an array permission pattern shows its first entry, not a joined list" {
  drive '{"steps":[
    {"type":"event","event":{"type":"permission.updated","properties":{"id":"per_9",
      "sessionID":"s1","type":"bash","pattern":["git push *","git commit *"]}}},
    {"type":"settle","ms":400}
  ]}'
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "git%20push%20%2A"
  refute_file_contains "$ADA_PROBE_OUT" "git%20commit"
}

# Per-session state has to be released, or a long-lived `opencode serve`
# accumulates an entry per session for the life of the process.
@test "a deleted session releases its tracked state" {
  drive '{"steps":[
    {"type":"event","event":{"type":"session.created","properties":{"info":
      {"id":"s1","directory":"/tmp"}}}},
    {"type":"chat.message","sessionID":"s1","text":"long task","ageSeconds":600},
    {"type":"event","event":{"type":"session.deleted","properties":{"info":{"id":"s1"}}}},
    '"$(idle s1)"'
  ]}'
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}
