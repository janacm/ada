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
        __CFBundleIdentifier

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

  export ADA_ALERT_FILE="$REPO_ROOT/alert.html"

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

# Skip a test when the native helper isn't built (install paths that aren't
# --dry-run call ensure_native_alert, which would otherwise try to swift-build).
require_native_helper() {
  [ -x "$REPO_ROOT/ada-alert" ] \
    || [ -x "$REPO_ROOT/.build/release/ada-alert" ] \
    || [ -x "$REPO_ROOT/.build/debug/ada-alert" ] \
    || skip "native ada-alert not built (swift build -c release --product ada-alert)"
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
