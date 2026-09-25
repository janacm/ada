#!/usr/bin/env bats
# Tests for lib/ada-show-alert.sh — the canonical alert launcher.

setup() {
  load test_helper
  setup_common
  LAUNCHER="$REPO_ROOT/lib/ada-show-alert.sh"
}

# A snoozing daemon inherits bats' output fd, so one that a failed assertion
# left asleep would stall the whole run until it wakes. The tests that snooze
# put the test's tmpdir in the label, which lands in the daemon's argv (its
# handoff file does not: mktemp -t ignores TMPDIR on macOS).
teardown() {
  /usr/bin/pkill -f "ada-snooze-daemon.py .*$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# A test that lets the launcher spawn the loopback daemon ends it here, via the
# port and token in the recorded URL. Otherwise bats waits out the daemon's
# deadline (autoclose + 15s) before finishing the test.
dismiss_daemon() {
  local url port token
  url=$(cat "$ADA_PROBE_OUT")
  port=$(sed -n 's/.*[?&]sport=\([0-9]*\).*/\1/p' <<<"$url")
  token=$(sed -n 's/.*[?&]stoken=\([^&]*\).*/\1/p' <<<"$url")
  [[ -n "$port" && -n "$token" ]] || return 0
  curl -s -o /dev/null "http://127.0.0.1:$port/$token/${1:-dismiss}" || true
}

@test "exits non-zero when the native helper is missing" {
  export ADA_NATIVE_ALERT="$BATS_TEST_TMPDIR/does-not-exist"
  run "$LAUNCHER" "build" "1s" 0
  assert_failure
  assert_output_contains "native helper"
}

@test "launches the native helper with a file:// alert URL" {
  export ADA_REPO="myrepo"
  run "$LAUNCHER" "make test" "2m 3s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  url="$(cat "$ADA_PROBE_OUT")"
  case "$url" in
    file://*"$REPO_ROOT/alert.html"*) : ;;
    *) echo "unexpected url: $url"; false ;;
  esac
}

# Regression: the launcher used to default ADA_ALERT_FILE to ~/.ada/alert.html.
# That path only exists for a from-source install, so every Homebrew user got a
# file:// URL for a file that isn't there — a blank alert window. Invisible on a
# dev machine, where ~/.ada masks it. Resolve the page next to the script.
@test "with ADA_ALERT_FILE unset, alert.html resolves next to the install" {
  local root="$BATS_TEST_TMPDIR/prefix/opt/ada/libexec"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  printf '<html></html>' > "$root/alert.html"
  unset ADA_ALERT_FILE
  export ADA_REPO=""

  run "$root/lib/ada-show-alert.sh" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "file://$root/alert.html"
  refute_file_contains "$ADA_PROBE_OUT" "/.ada/alert.html"
}

@test "passes duration, exit code and repo through to the URL" {
  export ADA_REPO="myrepo"
  run "$LAUNCHER" "deploy" "5s" 7
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  url="$(cat "$ADA_PROBE_OUT")"
  assert_file_contains "$ADA_PROBE_OUT" "code=7"
  assert_file_contains "$ADA_PROBE_OUT" "repo=myrepo"
  assert_file_contains "$ADA_PROBE_OUT" "duration=5s"
}

@test "url-encodes the command label" {
  export ADA_REPO=""
  run "$LAUNCHER" "git commit -m hi" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  # spaces -> %20 in the cmd= param
  assert_file_contains "$ADA_PROBE_OUT" "cmd=git%20commit"
}

@test "honors ADA_AUTO_CLOSE in the URL" {
  export ADA_REPO="" ADA_AUTO_CLOSE=42
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "autoclose=42"
}

@test "with snooze and focus disabled, the URL marks them off" {
  export ADA_REPO=""
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "snooze=0"
  assert_file_contains "$ADA_PROBE_OUT" "focus=0"
}

@test "writes the launched PID to the configured pid file" {
  export ADA_REPO=""
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_NATIVE_PID_FILE"
  run cat "$ADA_NATIVE_PID_FILE"
  # a bare integer pid
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "fails closed when the native helper exists but is not executable" {
  helper="$BATS_TEST_TMPDIR/ada-alert-noexec"
  printf '#!/bin/bash\n' > "$helper"   # present, but never chmod +x
  export ADA_NATIVE_ALERT="$helper"
  run "$LAUNCHER" "x" "1s" 0
  assert_failure
  assert_output_contains "native helper"
  refute_file_appears "$ADA_PROBE_OUT"
}

# The native WebKit file:// path can re-escape percent-encoded query values, so
# alert.html prefers the base64url copy for the displayed text — it's the
# load-bearing channel. Assert it round-trips, not just that cmd= looks right.
@test "cmdb64 is a faithful base64url copy of the command" {
  export ADA_REPO=""
  run "$LAUNCHER" 'git commit -m "a&b=c"' "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  b64="$(sed -n 's/.*cmdb64=\([^&]*\).*/\1/p' "$ADA_PROBE_OUT")"
  [ -n "$b64" ] || { echo "no cmdb64 param in URL:"; cat "$ADA_PROBE_OUT"; false; }
  decoded="$(python3 -c "import base64,sys; s=sys.argv[1]; s+='='*(-len(s)%4); print(base64.urlsafe_b64decode(s).decode())" "$b64")"
  assert_equal "$decoded" 'git commit -m "a&b=c"'
}

# ADA_REPO unset -> auto-detect from git (the path the Claude/Codex hook relies
# on, since it only sets ADA_REPO_DIR). Distinct from explicit-empty below.
@test "auto-detects the repo name from git when ADA_REPO is unset" {
  repo="$BATS_TEST_TMPDIR/myproj"; mkdir -p "$repo"
  git -C "$repo" init -q
  export ADA_REPO_DIR="$repo"   # ADA_REPO is unset (cleared in setup_common)
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "repo=myproj"
}

@test "explicit empty ADA_REPO hides the badge (repo= stays empty)" {
  export ADA_REPO=""
  export ADA_REPO_DIR="$BATS_TEST_TMPDIR"   # would resolve if the unset branch ran
  git -C "$BATS_TEST_TMPDIR" init -q 2>/dev/null || true
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  # repo= is immediately followed by the next param -> empty value, badge hidden
  assert_file_contains "$ADA_PROBE_OUT" "repo=&"
}

# Forward-looking guard for the documented "no browser fallback" guarantee:
# the launcher must never contain code that opens a browser.
@test "launcher never launches a browser (no-fallback guarantee)" {
  run grep -nEi 'open[[:space:]]+-a[[:space:]]*"?(safari|google chrome|brave|microsoft edge|firefox|chromium)|/Applications/(Safari|Google Chrome|Brave Browser|Microsoft Edge|Firefox)\.app' "$LAUNCHER"
  assert_failure   # no match -> grep exits 1 -> guarantee holds
}

# With ADA_NATIVE_ALERT unset, the helper is looked up beside the install, in
# the same order ada-install.sh builds it: ./ada-alert, then .build/release,
# then .build/debug.
@test "with ADA_NATIVE_ALERT unset, the helper is found in the install's build dir" {
  local root="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$root/lib" "$root/.build/debug"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  cp "$STUBS/fake-ada-alert" "$root/.build/debug/ada-alert"
  unset ADA_NATIVE_ALERT
  run "$root/lib/ada-show-alert.sh" "found it" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "cmd=found%20it"
}

@test "with no alert.html beside the install, the page falls back to ~/.ada" {
  local root="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  unset ADA_ALERT_FILE
  run "$root/lib/ada-show-alert.sh" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "file://$HOME/.ada/alert.html?"
}

@test "a relaunch from snooze is marked snoozed=1" {
  export ADA_SNOOZED=1
  run "$LAUNCHER" "again" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "&snoozed=1"
}

# The terminal the command ran in is the default click target, which spawns the
# loopback daemon; the page learns its port/token and the app name to show.
@test "the hosting terminal becomes the click target, with its display name" {
  unset ADA_FOCUS_APP
  export __CFBundleIdentifier=com.mitchellh.ghostty ADA_FOCUS_APP_NAME="Ghostty" ADA_AUTO_CLOSE=1
  run "$LAUNCHER" "click me" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "&focus=1"
  assert_file_contains "$ADA_PROBE_OUT" "&focusname=Ghostty"
  assert_file_contains "$ADA_PROBE_OUT" "&focusnameb64="
  assert_file_contains "$ADA_PROBE_OUT" "&sport="
  assert_file_contains "$ADA_PROBE_OUT" "&snooze=0"
  dismiss_daemon
}

# Only one alert at a time: a new one closes the previous window, found through
# the pid file. The process is a copy of sleep named ada-alert, because the
# launcher refuses to signal anything whose command name is not ada-alert.
@test "a new alert closes the previous ada-alert window" {
  cp /bin/sleep "$BATS_TEST_TMPDIR/ada-alert"
  "$BATS_TEST_TMPDIR/ada-alert" 30 &
  local old=$!
  disown "$old"
  echo "$old" > "$ADA_NATIVE_PID_FILE"
  run "$LAUNCHER" "next" "1s" 0
  assert_success
  local tries=40
  while kill -0 "$old" 2>/dev/null && (( tries-- > 0 )); do sleep 0.05; done
  if kill -0 "$old" 2>/dev/null; then kill "$old"; echo "previous alert still running"; false; fi
}

@test "a pid file naming some other process is left alone" {
  sleep 30 &
  local other=$!
  disown "$other"
  echo "$other" > "$ADA_NATIVE_PID_FILE"
  run "$LAUNCHER" "next" "1s" 0
  assert_success
  kill -0 "$other" 2>/dev/null || { echo "launcher killed a non-ada process"; false; }
  kill "$other"
}

@test "a leftover browser-profile alert from an old ada is cleaned up" {
  export STUB_PGREP_PID=4242 STUB_PKILL_LOG="$BATS_TEST_TMPDIR/pkill.log"
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  assert_file_contains "$STUB_PKILL_LOG" "user-data-dir=$HOME/.ada-alert-profile"
}

# --- per-session mute (lib/ada-mute.sh) -------------------------------------

@test "an alert for a muted session is dropped before anything launches" {
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=claude-abc
  "$REPO_ROOT/lib/ada-mute.sh" add claude-abc >/dev/null
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "an expired mute no longer drops the alert" {
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=claude-abc ADA_MUTE_MAX_AGE=60
  "$REPO_ROOT/lib/ada-mute.sh" add claude-abc >/dev/null
  touch -t "$(/bin/date -r $(( $(/bin/date +%s) - 3600 )) +%Y%m%d%H%M.%S)" "$ADA_MUTE_DIR/claude-abc"
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  [ ! -e "$ADA_MUTE_DIR/claude-abc" ]
}

@test "another session's mute leaves this alert alone" {
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=claude-def
  "$REPO_ROOT/lib/ada-mute.sh" add claude-abc >/dev/null
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}

@test "a session key starts the daemon and offers the mute button with its kind" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_MUTE_BUTTON=1 ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=zsh-1-2 ADA_SESSION_KIND=terminal ADA_AUTO_CLOSE=1
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "&sport="
  assert_file_contains "$ADA_PROBE_OUT" "&mute=1"
  assert_file_contains "$ADA_PROBE_OUT" "&mutekindb64=dGVybWluYWw"
  # snooze and focus are still off; only mute needed the daemon
  assert_file_contains "$ADA_PROBE_OUT" "&snooze=0"
  assert_file_contains "$ADA_PROBE_OUT" "&focus=0"
  dismiss_daemon
}

@test "an invalid session key gets no mute button and no daemon" {
  export ADA_MUTE_BUTTON=1 ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY="../escape"
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  refute_file_contains "$ADA_PROBE_OUT" "mute=1"
  refute_file_contains "$ADA_PROBE_OUT" "sport="
}

@test "a launcher copied without ada-mute.sh still alerts" {
  local root="$BATS_TEST_TMPDIR/old"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  export ADA_MUTE_BUTTON=1 ADA_SESSION_KEY=claude-abc
  run "$root/lib/ada-show-alert.sh" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  refute_file_contains "$ADA_PROBE_OUT" "mute=1"
}

# The whole button path minus the window: the page's mute signal reaches the
# daemon the launcher spawned, the daemon writes the marker the launcher named,
# and the next alert for that session is dropped.
@test "the mute signal writes the marker and silences the next alert" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v curl >/dev/null 2>&1 || skip "curl required"
  export ADA_MUTE_BUTTON=1 ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=opencode-ses_1 ADA_AUTO_CLOSE=5
  run "$LAUNCHER" "first" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  dismiss_daemon mute
  wait_for_file_exists() { local t=60; while (( t-- > 0 )); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }
  wait_for_file_exists "$ADA_MUTE_DIR/opencode-ses_1" || { echo "marker never written"; false; }

  rm -f "$ADA_PROBE_OUT"
  run "$LAUNCHER" "second" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "ADA_MUTE_BUTTON=0 hides the button but a muted session stays muted" {
  export ADA_MUTE_BUTTON=0 ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted" ADA_SESSION_KEY=claude-abc
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  refute_file_contains "$ADA_PROBE_OUT" "mute=1"
  refute_file_contains "$ADA_PROBE_OUT" "sport="

  "$REPO_ROOT/lib/ada-mute.sh" add claude-abc >/dev/null
  rm -f "$ADA_PROBE_OUT"
  run "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
}

# --- session-scoped snooze hold (lib/ada-mute.sh) ------------------------------

# Write a hold marker the way the daemon does: "<wake epoch> <token>".
hold_session() {
  mkdir -p "$TMPDIR/ada-snoozed"
  printf '%s tok\n' "$(( $(/bin/date +%s) + $2 ))" > "$TMPDIR/ada-snoozed/$1"
}

@test "an alert for a session inside a snooze hold is dropped" {
  export ADA_SESSION_KEY=claude-abc
  hold_session claude-abc 600
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  [ -f "$TMPDIR/ada-snoozed/claude-abc" ]
}

@test "a hold past its wake time lets the alert through and is removed" {
  export ADA_SESSION_KEY=claude-abc
  hold_session claude-abc -5
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  [ ! -e "$TMPDIR/ada-snoozed/claude-abc" ]
}

@test "a garbled hold marker does not silence the session" {
  export ADA_SESSION_KEY=claude-abc
  mkdir -p "$TMPDIR/ada-snoozed"
  printf 'soon\n' > "$TMPDIR/ada-snoozed/claude-abc"
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  [ ! -e "$TMPDIR/ada-snoozed/claude-abc" ]
}

@test "another session's snooze hold leaves this alert alone" {
  export ADA_SESSION_KEY=claude-def
  hold_session claude-abc 600
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}

@test "an invalid session key never reads a hold outside the hold dir" {
  export ADA_SESSION_KEY="../escape"
  mkdir -p "$TMPDIR/ada-snoozed"
  printf '%s tok\n' "$(( $(/bin/date +%s) + 600 ))" > "$TMPDIR/escape"
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  [ -f "$TMPDIR/escape" ]
}

# Poll for a line in the daemon's trace log. The daemon holds bats' output fd
# until it exits, so each test below also has to see it exit.
wait_for_trace() {
  local t=150
  while (( t-- > 0 )); do grep -q "$1" "$ADA_SNOOZE_LOG" 2>/dev/null && return 0; sleep 0.1; done
  echo "trace never showed: $1"; cat "$ADA_SNOOZE_LOG" 2>/dev/null; return 1
}

# The whole path minus the window: the page's snooze signal reaches the daemon,
# the daemon writes the hold the launcher named, the same session's next alert
# is dropped while another session's still fires, and releasing the hold (what a
# typed prompt does) ends the daemon without re-showing the snoozed alert.
@test "ADA_SNOOZE_SCOPE=session: a snooze holds the session until released" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v curl >/dev/null 2>&1 || skip "curl required"
  export ADA_SNOOZE_MINUTES="30" ADA_SESSION_KEY=claude-abc ADA_SNOOZE_SCOPE=session \
         ADA_AUTO_CLOSE=5 ADA_SNOOZE_LOG="$BATS_TEST_TMPDIR/snooze.log"
  run "$LAUNCHER" "first $BATS_TEST_TMPDIR" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  local before; before=$(/bin/date +%s)
  dismiss_daemon snooze/30
  wait_for_trace "holding"
  run cat "$TMPDIR/ada-snoozed/claude-abc"
  local wake=${output%% *}
  (( wake >= before + 1800 - 1 && wake <= before + 1800 + 5 )) || { echo "wake $wake is not ~30m after $before"; false; }

  rm -f "$ADA_PROBE_OUT"
  run "$LAUNCHER" "agent turn during the snooze" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"

  ADA_SESSION_KEY=claude-other ADA_SNOOZE_MINUTES="" run "$LAUNCHER" "another conversation" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "another session was held too"; false; }

  rm -f "$ADA_PROBE_OUT"
  bash -c ". '$REPO_ROOT/lib/ada-mute.sh'; __ada_snooze_release claude-abc"
  wait_for_trace "released early"
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "without ADA_SNOOZE_SCOPE a snooze re-arms only its own alert" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v curl >/dev/null 2>&1 || skip "curl required"
  export ADA_SNOOZE_MINUTES="1" ADA_SESSION_KEY=claude-abc ADA_AUTO_CLOSE=5 \
         ADA_SNOOZE_LOG="$BATS_TEST_TMPDIR/snooze.log"
  # The label lands in the daemon's argv, which is how the end of the test finds
  # it: its handoff file is in the real temp dir, since mktemp -t ignores TMPDIR.
  local label="rearm $BATS_TEST_TMPDIR"
  run "$LAUNCHER" "$label" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  dismiss_daemon snooze/1
  wait_for_trace "relaunch after sleep"
  refute_file_contains "$ADA_SNOOZE_LOG" "holding"
  [ ! -e "$TMPDIR/ada-snoozed/claude-abc" ]

  rm -f "$ADA_PROBE_OUT"
  ADA_SNOOZE_MINUTES="" run "$LAUNCHER" "next turn" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "the next alert was held without session scope"; false; }
  # The daemon is still asleep on its 1-minute snooze and would hold bats' fd.
  /usr/bin/pkill -f "ada-snooze-daemon.py .*$label" || { echo "daemon not found"; false; }
}

@test "a symlink at a session's hold path neither silences it nor gets deleted" {
  export ADA_SESSION_KEY=claude-abc
  mkdir -p "$TMPDIR/ada-snoozed"
  printf '%s tok\n' "$(( $(/bin/date +%s) + 600 ))" > "$TMPDIR/elsewhere"
  ln -s "$TMPDIR/elsewhere" "$TMPDIR/ada-snoozed/claude-abc"
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "a symlinked hold silenced the session"; false; }
  [ -L "$TMPDIR/ada-snoozed/claude-abc" ]
  bash -c ". '$REPO_ROOT/lib/ada-mute.sh'; __ada_snooze_release claude-abc"
  [ -L "$TMPDIR/ada-snoozed/claude-abc" ] && [ -f "$TMPDIR/elsewhere" ]
}

# The page labels the snooze from these two params, so the launcher must send
# snoozescope=session exactly when it named a hold, plus the session's noun.
@test "a session-scoped snooze tells the page its scope and noun, mute button or not" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_SNOOZE_MINUTES="5 30" ADA_SESSION_KEY=claude-abc ADA_SESSION_KIND=conversation \
         ADA_SNOOZE_SCOPE=session ADA_MUTE_BUTTON=0 ADA_AUTO_CLOSE=1
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "&snoozescope=session"
  assert_file_contains "$ADA_PROBE_OUT" "&mutekindb64=Y29udmVyc2F0aW9u"
  refute_file_contains "$ADA_PROBE_OUT" "mute=1"
  dismiss_daemon
}

@test "without session scope the page is told nothing about a session snooze" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_SNOOZE_MINUTES="5" ADA_SESSION_KEY=claude-abc ADA_SESSION_KIND=conversation ADA_AUTO_CLOSE=1
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "&snooze=1"
  refute_file_contains "$ADA_PROBE_OUT" "snoozescope"
  refute_file_contains "$ADA_PROBE_OUT" "mutekindb64"
  dismiss_daemon
}

@test "session scope with snooze switched off sends no scope" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_FOCUS_APP=com.example.app ADA_SESSION_KEY=claude-abc ADA_SNOOZE_SCOPE=session ADA_AUTO_CLOSE=1
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "&snooze=0"
  refute_file_contains "$ADA_PROBE_OUT" "snoozescope"
  dismiss_daemon
}

@test "session scope with an invalid key sends no scope" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_SNOOZE_MINUTES="5" ADA_SESSION_KEY="../escape" ADA_SNOOZE_SCOPE=session ADA_AUTO_CLOSE=1
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  refute_file_contains "$ADA_PROBE_OUT" "snoozescope"
  dismiss_daemon
}

# --- global pause (lib/ada-pause.sh) ----------------------------------------

@test "a pause drops the alert before anything launches" {
  "$REPO_ROOT/lib/ada-pause.sh" 30 >/dev/null
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "a pause until resumed drops the alert" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "a pause drops alerts from every session, muted or not" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  export ADA_SESSION_KEY=claude-abc
  run "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "an expired pause lets the alert through and the launcher leaves the file" {
  printf '1000\n' > "$TMPDIR/ada-paused"
  run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  # Only the CLI deletes it: a launcher rm could race a new pause's rename.
  [ -f "$TMPDIR/ada-paused" ]
}

@test "a file that is not a pause file does not pause anything" {
  printf 'hello\n' > "$TMPDIR/ada-paused"
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
  assert_equal "$(cat "$TMPDIR/ada-paused")" "hello"
}

@test "ADA_IGNORE_PAUSE=1 shows the alert while paused" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  ADA_IGNORE_PAUSE=1 run "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}

@test "ADA_PAUSE_FILE moves the pause file" {
  export ADA_PAUSE_FILE="$BATS_TEST_TMPDIR/elsewhere/paused"
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  [ ! -e "$TMPDIR/ada-paused" ]
  run "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "a snoozed alert that wakes during a pause is dropped" {
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  ADA_SNOOZED=1 run "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
}

@test "a launcher copied without ada-pause.sh still alerts while a pause is set" {
  local root="$BATS_TEST_TMPDIR/old"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  run "$root/lib/ada-show-alert.sh" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}

# The opencode plugin can hand the launcher a stripped environment. Without
# TMPDIR it must still find the pause and the mutes the menu bar and the alert
# wrote, which live in the per-user Darwin temp dir, not /tmp.
@test "with TMPDIR unset the launcher uses the per-user temp dir for pause and mute" {
  local darwin="$BATS_TEST_TMPDIR/darwin-tmp"
  mkdir -p "$darwin"
  export STUB_GETCONF_TMPDIR="$darwin"
  TMPDIR="$darwin" "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  run env -u TMPDIR "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"

  TMPDIR="$darwin" "$REPO_ROOT/lib/ada-pause.sh" resume >/dev/null
  TMPDIR="$darwin" "$REPO_ROOT/lib/ada-mute.sh" add claude-abc >/dev/null
  ADA_SESSION_KEY=claude-abc run env -u TMPDIR "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"

  ADA_SESSION_KEY=claude-def run env -u TMPDIR "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}

@test "with TMPDIR unset and no Darwin temp dir the launcher still alerts" {
  export STUB_GETCONF_TMPDIR=fail ADA_PAUSE_FILE="$BATS_TEST_TMPDIR/p" ADA_MUTE_DIR="$BATS_TEST_TMPDIR/m"
  run env -u TMPDIR "$LAUNCHER" "x" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}
