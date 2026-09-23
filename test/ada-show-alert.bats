#!/usr/bin/env bats
# Tests for lib/ada-show-alert.sh — the canonical alert launcher.

setup() {
  load test_helper
  setup_common
  LAUNCHER="$REPO_ROOT/lib/ada-show-alert.sh"
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
