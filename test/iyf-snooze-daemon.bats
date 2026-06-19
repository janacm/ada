#!/usr/bin/env bats
# Tests for lib/iyf-snooze-daemon.py — the project's one real trust boundary.
# The daemon binds an ephemeral loopback port and only honors requests whose
# first path segment matches a per-launch random token. These tests spawn it
# with focus disabled and a short deadline, so they stay loopback-only with no
# window, no app activation, and a guaranteed self-exit.

setup() {
  load test_helper
  setup_common
  DAEMON="$REPO_ROOT/lib/iyf-snooze-daemon.py"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v curl >/dev/null 2>&1 || skip "curl required"
}

# Spawn the daemon detached; echo "PORT TOKEN" once the handoff file appears.
# Args: <deadline> [snooze_minutes]
spawn_daemon() {
  local deadline="$1" mins="${2:-5 10}"
  local handoff="$BATS_TEST_TMPDIR/handoff"
  rm -f "$handoff"
  # alert_script=/usr/bin/true so any relaunch is a harmless no-op; focus_app=""
  # disables the open -b path entirely.
  python3 "$DAEMON" "$handoff" "$deadline" /usr/bin/true \
    "cmd" "1s" 0 "$REPO_ROOT/alert.html" 90 "$mins" "" >/dev/null 2>&1 &
  wait_for_file "$handoff" 100 || return 1
  cat "$handoff"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

@test "a request with the wrong token is rejected (404)" {
  read -r port token < <(spawn_daemon 5) || { echo "daemon never came up"; false; }
  [ -n "$port" ] && [ -n "$token" ]
  run http_code "http://127.0.0.1:$port/WRONGTOKEN/dismiss"
  assert_equal "$output" "404"
}

@test "a request with the right token is accepted (200)" {
  read -r port token < <(spawn_daemon 5) || { echo "daemon never came up"; false; }
  run http_code "http://127.0.0.1:$port/$token/dismiss"
  assert_equal "$output" "200"
}

@test "the handoff publishes a numeric port and a non-empty token" {
  read -r port token < <(spawn_daemon 5) || { echo "daemon never came up"; false; }
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "port not numeric: $port"; false; }
  [ -n "$token" ]
  # token should not be trivially guessable / empty padding
  [ "${#token}" -ge 8 ]
}

# A dismiss must end the daemon WITHOUT relaunching the alert.
@test "dismiss exits without re-arming" {
  export IYF_SNOOZE_LOG="$BATS_TEST_TMPDIR/snooze.log"
  read -r port token < <(spawn_daemon 5) || { echo "daemon never came up"; false; }
  http_code "http://127.0.0.1:$port/$token/dismiss" >/dev/null
  wait_for_file "$IYF_SNOOZE_LOG" 100
  # the daemon logs its terminal decision; dismiss => "exit without snooze"
  run bash -c "grep -q 'exit without snooze' '$IYF_SNOOZE_LOG'"
  assert_success
}

# An out-of-range snooze must be rejected by the bounds check (0 < mins <= 24h),
# so the daemon does NOT re-arm — it falls through to self-exit at the deadline.
@test "an out-of-range snooze is rejected (no re-arm)" {
  export IYF_SNOOZE_LOG="$BATS_TEST_TMPDIR/snooze.log"
  read -r port token < <(spawn_daemon 2) || { echo "daemon never came up"; false; }
  http_code "http://127.0.0.1:$port/$token/snooze/99999" >/dev/null
  # wait for the daemon to hit its (short) deadline and log its exit decision
  wait_for_file "$IYF_SNOOZE_LOG" 100
  run bash -c "for _ in \$(seq 1 60); do grep -q 'exit without snooze' '$IYF_SNOOZE_LOG' && exit 0; sleep 0.1; done; exit 1"
  assert_success
  run bash -c "grep -q 'relaunch after sleep' '$IYF_SNOOZE_LOG'"
  assert_failure   # must NOT have armed a snooze
}

# A focus request with a click URL must `open` that URL (e.g. claude://resume…)
# instead of `open -b <bundle>`. An isolated `open` stub on PATH records the call
# so nothing actually launches; the stub dir is per-test so the suite is unaffected.
@test "focus with a click URL opens the URL, not a bundle id" {
  export IYF_SNOOZE_LOG="$BATS_TEST_TMPDIR/snooze.log"
  local openlog="$BATS_TEST_TMPDIR/open.log"
  local stubbin="$BATS_TEST_TMPDIR/openbin"
  mkdir -p "$stubbin"
  cat > "$stubbin/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$openlog"
exit 0
EOF
  chmod +x "$stubbin/open"
  export PATH="$stubbin:$PATH"   # the detached daemon inherits this PATH

  local url="claude://resume?session=abc12345-0000-4000-8000-000000000000"
  local handoff="$BATS_TEST_TMPDIR/handoff"; rm -f "$handoff"
  # arg10 focus_app="" (no bundle), arg11 click_url set -> focus must open the URL.
  python3 "$DAEMON" "$handoff" 5 /usr/bin/true \
    "cmd" "1s" 0 "$REPO_ROOT/alert.html" 90 "" "" "$url" >/dev/null 2>&1 &
  wait_for_file "$handoff" 100 || { echo "daemon never came up"; false; }
  read -r port token < "$handoff"
  http_code "http://127.0.0.1:$port/$token/focus" >/dev/null

  run bash -c "for _ in \$(seq 1 60); do grep -qF '$url' '$openlog' 2>/dev/null && exit 0; sleep 0.1; done; exit 1"
  assert_success
  # and it must NOT have shelled out to a bundle-id activation
  run bash -c "grep -q -- '-b' '$openlog' 2>/dev/null"
  assert_failure
}
