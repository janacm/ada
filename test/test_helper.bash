# Shared BATS helpers for the ada test suite.
#
# Each *.bats file calls `load test_helper` then `setup_common` from its own
# setup(). This keeps every test hermetic: a private TMPDIR (so the Claude-hook
# state dir and the snooze/paseo logfiles can't touch your real ones), a private
# PID file (so a test can never kill a live alert), the snooze daemon and focus
# disabled (so nothing opens a real socket or activates an app), and the fake
# native helper wired in so an "alert" just records the URL it would open.

# Common per-test environment. Call from setup().
setup_common() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBS="$BATS_TEST_DIRNAME/stubs"

  # Clear any ADA_* / app knobs that could bleed in from the developer's shell
  # and re-enable a real side effect (e.g. an exported ADA_PASEO_ENV that points
  # at a file re-enabling the snooze daemon). The suite must depend only on what
  # setup_common sets below, not on the parent environment.
  unset ADA_PASEO_ENV ADA_PASEO_INSTALL_DIR ADA_AUTO_CLOSE \
        ADA_SKIP_OWN_TERMINAL ADA_SKIP_WHEN_ACTIVE ADA_PASEO_SKIP_WHEN_ACTIVE \
        ADA_PASEO_EVENTS ADA_PASEO_THRESHOLD ADA_PASEO_POLL \
        ADA_CLAUDE_THRESHOLD ADA_CLAUDE_STALE_MAX ADA_DEBUG_LOG \
        ADA_REPO ADA_REPO_DIR ADA_FOCUS_APP_NAME ADA_SNOOZED \
        __CFBundleIdentifier HOMEBREW_PREFIX ADA_DEBUG_LOG_FILE \
        ADA_OPENCODE_EVENTS ADA_OPENCODE_THRESHOLD ADA_OPENCODE_PLUGIN_DIR \
        ADA_OPENCODE_FALLBACK_PATHS STUB_OPENCODE_CONFIG

  # Private temp so the Claude-hook state dir ($TMPDIR/ada-claude), the paseo
  # logfile ($TMPDIR/ada-paseo-watch.log) and friends are isolated per test.
  export TMPDIR="$BATS_TEST_TMPDIR"

  # Override HOME so anything that reads ~/.zshrc, ~/.claude, ~/.codex, a real
  # paseo install, or the legacy ~/.ada-alert-profile sees an empty fixture, not
  # the developer's real config. Tests that need a populated HOME create it.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  # Never touch the real alert PID file — killing it would close a live alert.
  export ADA_NATIVE_PID_FILE="$BATS_TEST_TMPDIR/ada-alert.pid"

  # An "alert" is the fake helper; it just records the file:// URL it gets.
  export ADA_NATIVE_ALERT="$STUBS/fake-ada-alert"
  export ADA_PROBE_OUT="$BATS_TEST_TMPDIR/probe-url.txt"

  # Disable the snooze daemon and click-to-focus so no real socket is opened
  # and no app is activated during tests. (Empty, not unset — see ada-show-alert.)
  export ADA_SNOOZE_MINUTES=""
  export ADA_FOCUS_APP=""
  # Every integration now passes a session key, and a key alone would spawn the
  # daemon for the mute button. Tests that exercise the button turn it back on.
  export ADA_MUTE_BUTTON=0
  unset ADA_SESSION_KEY ADA_SESSION_KIND ADA_MUTE_DIR ADA_MUTE_MAX_AGE ADA_MUTE_FILE \
        ADA_SNOOZE_SCOPE ADA_SNOOZE_HOLD_FILE ADA_SNOOZE_LOG
  # A pause or history file from the developer's shell must not leak in either.
  unset ADA_PAUSE_FILE ADA_IGNORE_PAUSE ADA_HISTORY_FILE ADA_HISTORY_MAX \
        ADA_PAUSE_FLUSH ADA_PAUSE_BUTTON ADA_PAUSE_CLI ADA_SUMMARY_AUTO_CLOSE \
        ADA_SUMMARY_TARGETS ADA_MUTED_KEYS
  # A timed pause starts a detached timer that would outlive the test (and see
  # the next test's pause file); the tests that want one turn it back on. The
  # summary window has a pid file of its own, kept private like the alert's.
  export ADA_PAUSE_TIMER=0
  export ADA_SUMMARY_PID_FILE="$BATS_TEST_TMPDIR/ada-alert-summary.pid"

  export ADA_ALERT_FILE="$REPO_ROOT/alert.html"

  # The installers rebuild a .build/ helper older than the Swift sources. Tests
  # run them straight from the repo, so without this a suite run after a Swift
  # edit would start a real swift build in the developer's checkout. The
  # staleness tests turn it back on inside a scratch checkout.
  export ADA_REBUILD_HELPER=0

  # Always shadow the process-touching tools (pgrep/pkill) and the macOS
  # introspection tools (lsappinfo/launchctl) so no test can ever signal or
  # query a real process. Behaviour is still opt-in via STUB_* env vars.
  PATH="$STUBS:$PATH"
}

# Back-compat: stubs are already on PATH from setup_common. Kept so existing
# tests that call use_stubs still read clearly.
use_stubs() { PATH="$STUBS:$PATH"; }

# Poll for a non-empty file (the fake helper writes asynchronously because the
# launcher backgrounds it). Default ~3s (60 * 50ms).
wait_for_file() {
  local f="$1" tries="${2:-60}"
  while (( tries-- > 0 )); do
    [ -s "$f" ] && return 0
    sleep 0.05
  done
  return 1
}

# Poll until a file holds at least N lines. wait_for_file returns on the FIRST
# alert, so counting right after it races any later alert that is still on its
# way through the detached notify -> launcher -> helper chain.
wait_for_lines() {
  local f="$1" want="$2" tries="${3:-60}"
  while (( tries-- > 0 )); do
    [ -f "$f" ] && (( $(wc -l < "$f") >= want )) && return 0
    sleep 0.05
  done
  return 1
}

# Assert a file does NOT appear within a bounded window. Use for "no alert
# fired" checks: the launcher backgrounds the helper, so an immediate `[ ! -f ]`
# could pass simply because the async write hasn't happened yet. This waits.
refute_file_appears() {
  local f="$1" tries="${2:-12}"
  if wait_for_file "$f" "$tries"; then
    echo "expected $f to NOT appear, but it did:"; cat "$f" 2>/dev/null; return 1
  fi
  return 0
}

# --- a pause's held alerts (lib/ada-pause.sh) ---------------------------------

# Write one record the way a pause keeps an alert it held back: the alert's
# history line, alone in <pause file>.held/<epoch>.<pid>.<n>.tsv.
#   held_record <label> <duration> <code> [key] [click_url] [focus_app]
#               [epoch] [snoozed] [focus_app_name]
# The repo column is filled in, so a summary never runs git for it.
held_record() {
  local dir="${ADA_PAUSE_FILE:-$TMPDIR/ada-paused}.held" epoch=${7:-$(/bin/date +%s)}
  mkdir -p "$dir" && chmod 700 "$dir"
  printf '1\t%s\tpaused\t%s\t%s\tconversation\t%s\t%s\t%s\theld-repo\t%s\t%s\t%s\t%s\n' \
    "$epoch" "${8:-0}" "${4:-}" "$1" "$2" "$3" "${6:-}" "${9:-}" "${5:-}" "$TMPDIR" \
    > "$dir/$epoch.$$.$RANDOM$RANDOM.tsv"
}

# Decode base64url the way the page does: the summaryb64 of the last summary
# URL in a probe file (default $ADA_PROBE_OUT), or with -b any value given
# (a pauseresumeb64, a cmdb64).
summary_json() {
  local b64
  if [[ "${1:-}" == -b ]]; then
    b64=$2
  else
    b64=$(grep 'mode=summary' "${1:-$ADA_PROBE_OUT}" | tail -n 1 | sed -n 's/.*[?&]summaryb64=\([^&]*\).*/\1/p')
  fi
  python3 -c 'import base64,sys; s=sys.argv[1]; s+="="*(-len(s)%4); print(base64.urlsafe_b64decode(s).decode())' "$b64"
}

# Evaluate a python expression over JSON on stdin, bound to d.
json_get() {
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1"
}

# PATH without any directory that holds an ada-pause. A Homebrew ada puts one
# in <prefix>/bin, and __ada_pause_resume_cmd prefers it to the script path, so
# a test that expects the script path must not see the developer's. A stub
# earlier on PATH cannot hide it from `type -P`; only leaving it out does.
path_without_ada_pause() {
  local d out="" IFS=:
  for d in $PATH; do [[ -x "$d/ada-pause" ]] || out+=${out:+:}$d; done
  printf '%s' "$out"
}

# Skip a test when the native helper isn't built (install paths that aren't
# --dry-run call ensure_native_alert, which would otherwise try to swift-build).
require_native_helper() {
  [ -x "$REPO_ROOT/ada-alert" ] \
    || [ -x "$REPO_ROOT/.build/release/ada-alert" ] \
    || [ -x "$REPO_ROOT/.build/debug/ada-alert" ] \
    || skip "native ada-alert not built (swift build -c release --product ada-alert)"
}

# Kill every process whose command line matches the extended regex $1, for a
# teardown. A daemon or pause timer detaches with a double fork (behind the
# /usr/bin/python3 shim), so one pkill, or one empty pgrep, can land between
# steps and miss the process that survives. Keep killing until two checks in a
# row, 100ms apart, find nothing, for at most ~2s.
reap_processes() {
  local tries=20 clear=0
  while (( clear < 2 && tries-- > 0 )); do
    if /usr/bin/pgrep -f "$1" >/dev/null 2>&1; then
      clear=0
      /usr/bin/pkill -f "$1" 2>/dev/null
    else
      clear=$(( clear + 1 ))
    fi
    sleep 0.1
  done
  return 0
}

# --- tiny assertion helpers (we don't vendor bats-assert) --------------------

assert_success() {
  [ "$status" -eq 0 ] && return 0
  echo "expected success, got exit $status"; echo "output: $output"; return 1
}

assert_failure() {
  [ "$status" -ne 0 ] && return 0
  echo "expected failure, got exit 0"; echo "output: $output"; return 1
}

assert_equal() {
  [ "$1" = "$2" ] && return 0
  echo "expected: $2"; echo "actual:   $1"; return 1
}

assert_output_contains() {
  case "$output" in
    *"$1"*) return 0 ;;
    *) echo "expected output to contain: $1"; echo "actual output: $output"; return 1 ;;
  esac
}

refute_output_contains() {
  case "$output" in
    *"$1"*) echo "expected output NOT to contain: $1"; echo "actual output: $output"; return 1 ;;
    *) return 0 ;;
  esac
}

assert_file_contains() {
  grep -qF -- "$2" "$1" && return 0
  echo "expected file $1 to contain: $2"; echo "--- file ---"; cat "$1" 2>/dev/null; return 1
}

refute_file_contains() {
  grep -qF -- "$2" "$1" || return 0
  echo "expected file $1 to NOT contain: $2"; echo "--- file ---"; cat "$1" 2>/dev/null; return 1
}
