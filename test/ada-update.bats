#!/usr/bin/env bats
# Tests for lib/ada-update.sh — the check for a newer release — and the notice
# the launcher puts on the page.
#
# Every test runs against a copy of the tree shaped like a Homebrew install
# (<prefix>/opt/ada/libexec with a VERSION file), because the repo itself has
# no VERSION and so never checks. curl is a stub first on PATH that serves a
# formula file and logs its arguments: no test reaches GitHub.

setup() {
  load test_helper
  setup_common
  unset ADA_UPDATE_CHECK
  ROOT="$BATS_TEST_TMPDIR/prefix/opt/ada/libexec"
  mkdir -p "$ROOT"
  cp -R "$REPO_ROOT/lib" "$ROOT/lib"
  cp "$REPO_ROOT/alert.html" "$ROOT/alert.html"
  echo 0.4 > "$ROOT/VERSION"
  UPDATE="$ROOT/lib/ada-update.sh"
  CACHE="$TMPDIR/ada-update"
  export ADA_UPDATE_OFF_FILE="$BATS_TEST_TMPDIR/update-check-off"
  unset ADA_ALERT_FILE

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
# curl stub: logs its arguments, one per line and a --- after each call, then
# serves $STUB_CURL_BODY, or fails like an unreachable host without one.
{ printf '%s\n' "$@"; echo ---; } >> "$STUB_CURL_LOG"
[[ -n "${STUB_CURL_BODY:-}" && -f "$STUB_CURL_BODY" ]] || exit 7
cat "$STUB_CURL_BODY"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export STUB_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export STUB_CURL_BODY="$BATS_TEST_TMPDIR/ada.rb"
  formula 0.5
}

teardown() {
  reap_processes "ada-update.sh check --background"
}

# A formula shaped like Formula/ada.rb, releasing <version>.
formula() {
  cat > "$STUB_CURL_BODY" <<RB
class Ada < Formula
  desc "Maximized-window alert"
  url "https://github.com/janacm/ada/archive/refs/tags/v$1.tar.gz"
  sha256 "feeb6ac225cb9c0cd0be6743b0ecbea431b19258268b40140b5b24274f9fcd85"
  head "https://github.com/janacm/ada.git", branch: "main"
  livecheck do
    url :stable
  end
end
RB
}

curl_calls() { [[ -f "$STUB_CURL_LOG" ]] && grep -c '^---$' "$STUB_CURL_LOG" || echo 0; }

# --- the check -------------------------------------------------------------------

@test "check reads the release from the formula's url line and caches it" {
  export STUB_NOW=1000
  run "$UPDATE" check
  assert_success
  assert_output_contains "ada 0.5 is out (you have 0.4). Update with: brew update && brew upgrade ada"
  assert_equal "$(cat "$CACHE")" "1000 0.5 ok"
}

@test "the one request is a GET of the formula on main, https only, with nothing of ours" {
  run "$UPDATE" check
  assert_success
  # Exactly these arguments: no headers, no data, no user agent of ours.
  assert_equal "$(cat "$STUB_CURL_LOG")" "$(printf '%s\n' -fsSL --proto =https --proto-redir =https --max-time 15 \
    https://raw.githubusercontent.com/janacm/ada/main/Formula/ada.rb ---)"
}

# The parser is checked against the formula release.sh actually rewrites, not
# only a fixture shaped like it.
@test "check reads the version out of the real Formula/ada.rb" {
  cp "$REPO_ROOT/Formula/ada.rb" "$STUB_CURL_BODY"
  local expected
  expected=$(sed -n 's|^  url ".*/refs/tags/v\([0-9.]*\)\.tar\.gz"$|\1|p' "$REPO_ROOT/Formula/ada.rb")
  [[ -n "$expected" ]] || { echo "no release url in Formula/ada.rb"; false; }
  echo "$expected" > "$ROOT/VERSION"
  run "$UPDATE" check
  assert_success
  assert_output_contains "ada $expected is the latest release"
  [[ "$(cat "$CACHE")" == *" $expected ok" ]]
}

@test "the same version as installed is the latest" {
  formula 0.4
  run "$UPDATE" check
  assert_success
  assert_output_contains "ada 0.4 is the latest release (checked just now)"
}

@test "versions compare number by number" {
  formula 0.10
  echo 0.9 > "$ROOT/VERSION"
  run "$UPDATE" check
  assert_output_contains "ada 0.10 is out (you have 0.9)"
}

@test "a failed check keeps the last answer and fails" {
  export STUB_NOW=2000
  echo "1000 0.5 ok" > "$CACHE"
  rm "$STUB_CURL_BODY"
  run "$UPDATE" check
  assert_failure
  assert_output_contains "could not read https://raw.githubusercontent.com/janacm/ada/main/Formula/ada.rb"
  assert_equal "$(cat "$CACHE")" "2000 0.5 failed"
  run "$UPDATE" status
  assert_output_contains "ada 0.5 is out (you have 0.4)"
}

@test "a formula with no release url fails the check" {
  printf 'class Ada < Formula\n  url "https://example.com/ada.zip"\nend\n' > "$STUB_CURL_BODY"
  export STUB_NOW=1000
  run "$UPDATE" check
  assert_failure
  assert_equal "$(cat "$CACHE")" "1000 - failed"
  run "$UPDATE" status
  assert_output_contains "The last update check failed (just now)"
}

@test "a check that never finished says it is running" {
  echo "$(date +%s) 0.4 checking" > "$CACHE"
  run "$UPDATE" status
  assert_output_contains "ada 0.4. An update check is running."
}

@test "status reads only the cache" {
  run "$UPDATE"
  assert_success
  assert_output_contains "Not checked for updates yet"
  assert_equal "$(curl_calls)" 0
}

# --- who checks at all -----------------------------------------------------------------

@test "a checkout has no VERSION and never checks" {
  rm "$ROOT/VERSION"
  run "$UPDATE" check
  assert_success
  assert_output_contains "Update checks are for Homebrew installs. Update a checkout with: git pull"
  assert_equal "$(curl_calls)" 0
  run "$UPDATE" check --background
  assert_equal "$output" ""
  assert_equal "$(curl_calls)" 0
}

@test "a HEAD build's VERSION is no release version and never checks" {
  echo HEAD-1a2b3c4 > "$ROOT/VERSION"
  run "$UPDATE" check
  assert_success
  assert_output_contains "Update checks are for Homebrew installs"
  assert_equal "$(curl_calls)" 0
}

@test "ADA_UPDATE_CHECK=0 makes no request" {
  export ADA_UPDATE_CHECK=0
  run "$UPDATE" check
  assert_success
  assert_output_contains "Update checks are off (ADA_UPDATE_CHECK=0)."
  assert_equal "$(curl_calls)" 0
  run "$UPDATE" on
  assert_output_contains "stay off while ADA_UPDATE_CHECK=0 is set"
}

@test "off writes a switch under ~/.local/share/ada that stops the check, and on removes it" {
  unset ADA_UPDATE_OFF_FILE
  run "$UPDATE" off
  assert_success
  [ -f "$HOME/.local/share/ada/update-check-off" ]
  run "$UPDATE" check
  assert_output_contains "Update checks are off. Turn them back on with: ada-update on"
  assert_equal "$(curl_calls)" 0
  run "$UPDATE" on
  assert_success
  [ ! -e "$HOME/.local/share/ada/update-check-off" ]
  run "$UPDATE" check
  assert_success
  assert_equal "$(curl_calls)" 1
}

@test "off and on leave a switch path that isn't a plain file alone" {
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ADA_UPDATE_OFF_FILE"
  run "$UPDATE" off
  assert_failure
  assert_output_contains "is not ada's"
  run "$UPDATE" on
  assert_failure
  [ -L "$ADA_UPDATE_OFF_FILE" ]
  # A dangling symlink still counts as off, as -e || -L does.
  run "$UPDATE" check
  assert_output_contains "Update checks are off"
  rm "$ADA_UPDATE_OFF_FILE"
  mkdir "$ADA_UPDATE_OFF_FILE"
  run "$UPDATE" on
  assert_failure
  [ -d "$ADA_UPDATE_OFF_FILE" ]
}

@test "a symlinked cache is neither read nor replaced" {
  echo "1000 9.9 ok" > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$CACHE"
  run "$UPDATE" status
  assert_output_contains "Not checked for updates yet"
  run "$UPDATE" check
  [ -L "$CACHE" ]
  assert_equal "$(cat "$BATS_TEST_TMPDIR/target")" "1000 9.9 ok"
}

@test "a cache line that doesn't parse reads as no check" {
  printf 'yesterday 0.5 ok\n' > "$CACHE"
  run "$UPDATE" status
  assert_output_contains "Not checked for updates yet"
  printf '1000 not-a-version weird\n' > "$CACHE"
  run "$UPDATE" status
  assert_output_contains "Not checked for updates yet"
}

@test "unknown commands exit 2, and help lists the commands" {
  run "$UPDATE" upgrade
  [ "$status" -eq 2 ]
  assert_output_contains "unknown command: upgrade"
  run "$UPDATE" --help
  assert_success
  assert_output_contains "ada-update.sh check"
  assert_output_contains "ada-update.sh off"
}

# --- when a check is due -----------------------------------------------------------

@test "versions: newer, older, equal, and missing numbers as 0" {
  run bash -c '. "$1"
    for pair in "0.5 0.4" "0.10 0.9" "1.0 0.99" "0.5.1 0.5" "0.4 0.5" "0.5.0 0.5" "0.5 0.5.0" "0.5 0.5"; do
      set -- $pair; if __ada_update_newer "$1" "$2"; then echo "$1>$2"; else echo "$1!>$2"; fi
    done
    for v in 0.5 1.2.3 1.2.3.4 0 1.2.3.4.5 v0.5 0.5- 0..5 1234567.0 HEAD-abc; do
      if __ada_update_version_ok "$v"; then echo "ok $v"; else echo "no $v"; fi
    done' _ "$UPDATE"
  assert_success
  assert_equal "$output" "$(printf '%s\n' '0.5>0.4' '0.10>0.9' '1.0>0.99' '0.5.1>0.5' '0.4!>0.5' '0.5.0!>0.5' \
    '0.5!>0.5.0' '0.5!>0.5' 'ok 0.5' 'ok 1.2.3' 'ok 1.2.3.4' 'no 0' 'no 1.2.3.4.5' 'no v0.5' 'no 0.5-' \
    'no 0..5' 'no 1234567.0' 'no HEAD-abc')"
}

@test "a good check lasts the interval, a failed or unfinished one an hour" {
  run bash -c '. "$1"
    due() { __ada_update_at=$1; __ada_update_state=$2; if __ada_update_due "$3"; then echo due; else echo wait; fi; }
    due 1000 ok $((1000 + 86399)); due 1000 ok $((1000 + 86400))
    due 1000 failed $((1000 + 3599)); due 1000 failed $((1000 + 3600))
    due 1000 checking $((1000 + 3600)); due 0 "" 1000
    due 5000 ok 1000
    ADA_UPDATE_INTERVAL=600; due 1000 ok 1599; due 1000 failed 1600
    ADA_UPDATE_INTERVAL=soon; due 1000 ok 2000' _ "$UPDATE"
  assert_success
  assert_equal "$output" "$(printf '%s\n' wait due wait due due due due wait due wait)"
}

@test "check --background asks only when a check is due" {
  echo "1000 0.4 ok" > "$CACHE"
  export STUB_NOW=2000
  run "$UPDATE" check --background
  assert_success
  assert_equal "$output" ""
  assert_equal "$(curl_calls)" 0
  export STUB_NOW=$((1000 + 86400))
  run "$UPDATE" check --background
  assert_success
  assert_equal "$output" ""
  assert_equal "$(curl_calls)" 1
  assert_equal "$(cat "$CACHE")" "87400 0.5 ok"
}

# --- the notice --------------------------------------------------------------------

@test "__ada_update_note offers a newer cached release and starts no check before one is due" {
  echo "1000 0.5 ok" > "$CACHE"
  run bash -c '. "$1"; __ada_update_note 1500 && echo "$__ada_update_latest $__ada_update_version"' _ "$UPDATE"
  assert_success
  assert_equal "$output" "0.5 0.4"
  sleep 0.3
  assert_equal "$(curl_calls)" 0
}

@test "__ada_update_note starts a background check when one is due, for a later alert" {
  echo "1000 0.4 ok" > "$CACHE"
  export STUB_NOW=$((1000 + 86400))
  run bash -c '. "$1"; __ada_update_note "" || echo "no notice yet"' _ "$UPDATE"
  assert_equal "$output" "no notice yet"
  wait_for_file "$STUB_CURL_LOG" || { echo "no background check"; false; }
  wait_for_lines "$CACHE" 1
  local tries=60
  until [[ "$(cat "$CACHE")" == "87400 0.5 ok" ]] || (( tries-- == 0 )); do sleep 0.05; done
  assert_equal "$(cat "$CACHE")" "87400 0.5 ok"
}

@test "__ada_update_note offers nothing when checks are off, for a checkout, or when up to date" {
  echo "1000 0.5 ok" > "$CACHE"
  note() { bash -c '. "$1"; __ada_update_note 1500 && echo notice || echo none' _ "$UPDATE"; }
  ADA_UPDATE_CHECK=0 run note;  assert_equal "$output" none
  : > "$ADA_UPDATE_OFF_FILE"; run note; assert_equal "$output" none
  rm "$ADA_UPDATE_OFF_FILE"
  echo 0.5 > "$ROOT/VERSION";   run note; assert_equal "$output" none
  rm "$ROOT/VERSION";           run note; assert_equal "$output" none
}

# --- through the launcher -----------------------------------------------------------

@test "the launcher puts the cached release and this install's version on the page" {
  export STUB_NOW=1000 ADA_REPO=""
  echo "1000 0.5 ok" > "$CACHE"
  run "$ROOT/lib/ada-show-alert.sh" "make test" "1s" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "&update=0.5&installed=0.4"
  # The history line's epoch stood in for `date`, and it said no check is due.
  sleep 0.3
  assert_equal "$(curl_calls)" 0
}

@test "the launcher puts no notice on the page when up to date or checks are off" {
  export STUB_NOW=1000 ADA_REPO=""
  echo "1000 0.4 ok" > "$CACHE"
  run "$ROOT/lib/ada-show-alert.sh" "make test" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  refute_file_contains "$ADA_PROBE_OUT" "update="
  rm "$ADA_PROBE_OUT"
  echo "1000 0.5 ok" > "$CACHE"
  ADA_UPDATE_CHECK=0 run "$ROOT/lib/ada-show-alert.sh" "make test" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  refute_file_contains "$ADA_PROBE_OUT" "update="
}

@test "an alert that shows starts the day's check, and the next alert has the notice" {
  export ADA_REPO=""
  run "$ROOT/lib/ada-show-alert.sh" "first" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  refute_file_contains "$ADA_PROBE_OUT" "update="
  local tries=60
  until [[ "$(cat "$CACHE" 2>/dev/null)" == *" 0.5 ok" ]] || (( tries-- == 0 )); do sleep 0.05; done
  [[ "$(cat "$CACHE")" == *" 0.5 ok" ]] || { cat "$CACHE"; false; }
  rm "$ADA_PROBE_OUT"
  run "$ROOT/lib/ada-show-alert.sh" "second" "1s" 0
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "&update=0.5&installed=0.4"
  assert_equal "$(curl_calls)" 1
}

@test "an alert a pause holds back starts no check" {
  export ADA_REPO="" ADA_PAUSE_FILE="$TMPDIR/ada-paused"
  echo 0 > "$ADA_PAUSE_FILE"
  run "$ROOT/lib/ada-show-alert.sh" "held" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  assert_equal "$(curl_calls)" 0
  [ ! -e "$CACHE" ]
}

@test "the summary of a pause carries the notice too" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export STUB_NOW=1000 ADA_PAUSE_FILE="$TMPDIR/ada-paused"
  echo "1000 0.5 ok" > "$CACHE"
  held_record "npm test" "2m" 0 "" "" "" 990
  ADA_PAUSE_FLUSH=resumed run "$ROOT/lib/ada-show-alert.sh" "" "" 0
  assert_success
  wait_for_file "$ADA_PROBE_OUT"
  assert_file_contains "$ADA_PROBE_OUT" "mode=summary"
  assert_file_contains "$ADA_PROBE_OUT" "&update=0.5&installed=0.4"
}

# --- in the status report ------------------------------------------------------------

@test "--status adds the update line for a release install only" {
  echo "1000 0.5 ok" > "$CACHE"
  run "$ROOT/lib/ada-status.sh" --table
  assert_success
  assert_output_contains "ada 0.5 is out (you have 0.4). Update with: brew update && brew upgrade ada"
  rm "$ROOT/VERSION"
  run "$ROOT/lib/ada-status.sh" --table
  refute_output_contains "Update"
  run "$ROOT/lib/ada-status.sh"
  refute_output_contains "Update"
}
