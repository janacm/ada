#!/usr/bin/env bats
# Tests for ada-paseo-watch.sh — the launchd watcher front door.
# Only the side-effect-free subcommands are exercised (install/uninstall mutate
# launchd state and are out of scope here).

setup() {
  load test_helper
  setup_common
  WATCH="$REPO_ROOT/ada-paseo-watch.sh"
}

@test "unknown subcommand exits 2 with a hint" {
  run "$WATCH" frobnicate
  assert_failure
  assert_equal "$status" 2
  assert_output_contains "unknown command"
}

@test "no args prints usage" {
  run "$WATCH"
  assert_success
  assert_output_contains "ada-paseo-watch"
  assert_output_contains "install"
}

@test "test subcommand fires a sample alert" {
  run "$WATCH" test
  assert_success
  assert_output_contains "Fired a test alert"
  wait_for_file "$ADA_PROBE_OUT" || { echo "sample alert never fired"; false; }
}

@test "status reports not-loaded when launchctl has no job" {
  use_stubs
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  run "$WATCH" status
  assert_success
  assert_output_contains "not loaded"
}

@test "status reports running when launchctl returns a pid" {
  use_stubs
  export STUB_LAUNCHCTL_LOADED=1 STUB_LAUNCHCTL_PID=4242
  run "$WATCH" status
  assert_success
  assert_output_contains "running (pid 4242)"
}

# Regression: the lib/ refactor once staged the internal scripts FLAT while the
# watcher resolved them under lib/, so every Paseo alert from the installed
# LaunchAgent silently failed — invisible in a dev checkout. Pin the staged
# layout AND the path the staged python actually computes.
@test "install stages the runtime in lib/ so the staged launcher path resolves" {
  require_native_helper
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$HOME/Library/LaunchAgents"

  run "$WATCH" install
  assert_success

  # front door + assets at the top; internal scripts under lib/ (mirrors dev)
  [ -f "$ADA_PASEO_INSTALL_DIR/ada-paseo-watch.sh" ]
  [ -f "$ADA_PASEO_INSTALL_DIR/alert.html" ]
  [ -x "$ADA_PASEO_INSTALL_DIR/ada-alert" ]
  [ -f "$ADA_PASEO_INSTALL_DIR/lib/ada-show-alert.sh" ]
  [ -f "$ADA_PASEO_INSTALL_DIR/lib/ada-paseo-watch.py" ]
  [ -f "$ADA_PASEO_INSTALL_DIR/lib/ada-snooze-daemon.py" ]
  # Sourced by the staged launcher; without it the LaunchAgent's alerts would
  # silently lose muting while a dev checkout kept it.
  [ -f "$ADA_PASEO_INSTALL_DIR/lib/ada-mute.sh" ]

  # Anchor to the code, not a restatement: load the staged module and assert the
  # launcher it would exec actually exists on disk.
  run python3 - "$ADA_PASEO_INSTALL_DIR/lib/ada-paseo-watch.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("paseo_watch", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert os.path.isfile(mod.LAUNCHER), f"staged LAUNCHER missing: {mod.LAUNCHER}"
print(mod.LAUNCHER)
PY
  assert_success
  assert_output_contains "$ADA_PASEO_INSTALL_DIR/lib/ada-show-alert.sh"
}

# The staged front door (ada-paseo-watch.sh) must also resolve its internal
# scripts from the staged layout, not just in a dev checkout.
@test "staged front door can fire an alert through its staged launcher" {
  require_native_helper
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$HOME/Library/LaunchAgents"
  run "$WATCH" install
  assert_success

  # Run `test` from the STAGED front door so $dir is the staged dir.
  run "$ADA_PASEO_INSTALL_DIR/ada-paseo-watch.sh" test
  assert_success
  assert_output_contains "Fired a test alert"
  wait_for_file "$ADA_PROBE_OUT" || { echo "staged front door could not launch the alert"; false; }
}

# Staging exists only to dodge TCC. A Homebrew install is already outside every
# TCC-protected folder AND behind a version-stable opt symlink, so staging it
# would freeze a snapshot that `brew upgrade` can never refresh. Run in place.
@test "install from a Homebrew prefix runs in place instead of staging" {
  require_native_helper
  local prefix="$BATS_TEST_TMPDIR/brew"
  local libexec="$prefix/opt/ada/libexec"
  mkdir -p "$libexec/lib" "$HOME/Library/LaunchAgents"
  cp "$REPO_ROOT/ada-paseo-watch.sh" "$REPO_ROOT/alert.html" "$libexec/"
  cp "$REPO_ROOT/lib/ada-paseo-watch.py" "$REPO_ROOT/lib/ada-show-alert.sh" \
     "$REPO_ROOT/lib/ada-snooze-daemon.py" "$REPO_ROOT/lib/ada-mute.sh" "$libexec/lib/"
  cp "$REPO_ROOT/ada-alert" "$libexec/ada-alert" 2>/dev/null \
    || cp "$REPO_ROOT/.build/release/ada-alert" "$libexec/ada-alert"

  export HOMEBREW_PREFIX="$prefix"
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"

  run "$libexec/ada-paseo-watch.sh" install
  assert_success
  assert_output_contains "in place"

  local plist="$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist"
  assert_file_contains "$plist" "$libexec/ada-paseo-watch.sh"
  refute_file_contains "$plist" "$ADA_PASEO_INSTALL_DIR/ada-paseo-watch.sh"
  # Config must live outside the Homebrew tree, which brew replaces wholesale.
  assert_file_contains "$plist" "$ADA_PASEO_INSTALL_DIR/paseo-watch.env"
  [ ! -f "$ADA_PASEO_INSTALL_DIR/ada-paseo-watch.sh" ]
}

# Regression: the env file used to default to one next to the running script.
# Under Homebrew that is the formula's libexec — nothing writes an env file there
# and `brew upgrade` replaces it — so only the LaunchAgent honored the user's
# config (the plist passes ADA_PASEO_ENV explicitly) while a manual test/status/
# run silently ignored it. Key it off the install dir in every mode instead.
@test "a manual run reads the env file from the install dir, not its own dir" {
  local libexec="$BATS_TEST_TMPDIR/brew/opt/ada/libexec"
  mkdir -p "$libexec/lib"
  cp "$REPO_ROOT/ada-paseo-watch.sh" "$REPO_ROOT/alert.html" "$libexec/"
  cp "$REPO_ROOT/lib/ada-paseo-watch.py" "$REPO_ROOT/lib/ada-show-alert.sh" \
     "$REPO_ROOT/lib/ada-snooze-daemon.py" "$REPO_ROOT/lib/ada-mute.sh" "$libexec/lib/"

  export HOMEBREW_PREFIX="$BATS_TEST_TMPDIR/brew"
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$ADA_PASEO_INSTALL_DIR"
  printf '<html></html>' > "$ADA_PASEO_INSTALL_DIR/configured.html"
  echo "ADA_ALERT_FILE=$ADA_PASEO_INSTALL_DIR/configured.html" \
       > "$ADA_PASEO_INSTALL_DIR/paseo-watch.env"

  # Anchor on a setting that reaches the alert, not just on the file being read.
  run "$libexec/ada-paseo-watch.sh" test
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "sample alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "$ADA_PASEO_INSTALL_DIR/configured.html"
}

# The poll/diff loop (running->idle, running->error, seeding, permission dedupe,
# ADA_PASEO_EVENTS subsetting) lives in the .py and can't be reached via the
# front door. Driven directly by test/paseo_diff_check.py.
@test "poll/diff loop: finish/fail/seeding/dedupe/events behave correctly" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  run python3 "$BATS_TEST_DIRNAME/paseo_diff_check.py"
  assert_success
  assert_output_contains "all paseo diff-loop checks passed"
}

@test "-h prints the header usage" {
  run "$WATCH" -h
  assert_success
  assert_output_contains "ada-paseo-watch.sh run"
  assert_output_contains "ADA_PASEO_THRESHOLD"
}

# --- run: the handoff to the python loop ---------------------------------------
# The loop itself runs forever and is covered by paseo_diff_check.py. What the
# front door owns is finding paseo, exporting PASEO_BIN, and exec-ing the .py,
# so a python3 stub that reports what it was handed is the whole check.

@test "run fails clearly when no paseo CLI exists anywhere" {
  if [ -x /Applications/Paseo.app/Contents/Resources/bin/paseo ]; then
    skip "Paseo.app is installed; the no-CLI branch is unobservable here"
  fi
  run "$WATCH" run
  assert_failure
  assert_output_contains "'paseo' CLI not found"
}

@test "run execs the python loop with PASEO_BIN pointing at the CLI it found" {
  mkdir -p "$HOME/.local/bin" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "[]"\n' > "$HOME/.local/bin/paseo"
  printf '#!/bin/sh\necho "python3 $* PASEO_BIN=$PASEO_BIN"\n' > "$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$HOME/.local/bin/paseo" "$BATS_TEST_TMPDIR/bin/python3"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$WATCH" run
  assert_success
  assert_output_contains "python3 $REPO_ROOT/lib/ada-paseo-watch.py"
  assert_output_contains "PASEO_BIN=$HOME/.local/bin/paseo"
}

# --- uninstall ------------------------------------------------------------------

@test "uninstall removes the plist" {
  mkdir -p "$HOME/Library/LaunchAgents"
  touch "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist"
  run "$WATCH" uninstall
  assert_success
  assert_output_contains "Removed:"
  [ ! -f "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" ]
}

@test "uninstall with nothing installed says so" {
  run "$WATCH" uninstall
  assert_success
  assert_output_contains "Not installed"
}

# --- status -----------------------------------------------------------------------

@test "status distinguishes a loaded job with no live loop" {
  export STUB_LAUNCHCTL_LOADED=1
  run "$WATCH" status
  assert_success
  assert_output_contains "loaded but not running yet"
  assert_output_contains "plist: (none)"
  assert_output_contains "runtime: (not installed)"
}

@test "status after install names the staged runtime and a clean log" {
  require_native_helper
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  run "$WATCH" install
  assert_success
  run "$WATCH" status
  assert_success
  assert_output_contains "plist: $HOME/Library/LaunchAgents/com.ada.paseo-watch.plist"
  assert_output_contains "runtime: $ADA_PASEO_INSTALL_DIR"
  assert_output_contains "log clean"
  refute_output_contains "differs from the staged copy"
}

# A stale stage is the failure mode that looks healthy: the LaunchAgent keeps
# running the old copy after the checkout moved on.
@test "status flags a staged runtime that no longer matches the checkout" {
  require_native_helper
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  run "$WATCH" install
  assert_success
  echo "# drift" >> "$ADA_PASEO_INSTALL_DIR/lib/ada-show-alert.sh"
  run "$WATCH" status
  assert_success
  assert_output_contains "differs from the staged copy (re-run install)"
}

@test "status falls back to pgrep for a loop launchd did not report" {
  require_native_helper
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  run "$WATCH" install
  assert_success
  export STUB_PGREP_PID=5151
  run "$WATCH" status
  assert_success
  assert_output_contains "running (pid 5151)"
}

@test "status shows the tail of a noisy log" {
  printf 'Traceback: boom\n' > "$TMPDIR/ada-paseo-watch.log"
  run "$WATCH" status
  assert_success
  assert_output_contains "log has output"
  assert_output_contains "Traceback: boom"
}

# --- install failure paths ---------------------------------------------------------

@test "install reports a launchctl load failure instead of claiming success" {
  require_native_helper
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  export STUB_LAUNCHCTL_LOAD_FAIL=1
  run "$WATCH" install
  assert_failure
  assert_output_contains "'launchctl load' failed"
  [ -f "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" ]
}

# A checkout with the scripts but no built helper. The front door is a copy so
# that $dir is the fixture (report.py credits verbatim copies to the repo file).
make_watch_checkout() {
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CHECKOUT/lib"
  cp "$REPO_ROOT/ada-paseo-watch.sh" "$REPO_ROOT/alert.html" "$CHECKOUT/"
  cp "$REPO_ROOT/lib/ada-paseo-watch.py" "$REPO_ROOT/lib/ada-show-alert.sh" \
     "$REPO_ROOT/lib/ada-snooze-daemon.py" "$REPO_ROOT/lib/ada-mute.sh" "$CHECKOUT/lib/"
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  unset ADA_NATIVE_ALERT
}

@test "install refuses to stage without a native helper to copy" {
  make_watch_checkout
  run "$CHECKOUT/ada-paseo-watch.sh" install
  assert_failure
  assert_output_contains "native helper ada-alert is required"
  [ ! -f "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" ]
}

swift_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/swift" <<'SH'
#!/bin/bash
[ "${STUB_SWIFT:-ok}" = fail ] && exit 1
mkdir -p .build/release && printf '#!/bin/sh\nexit 0\n' > .build/release/ada-alert
chmod +x .build/release/ada-alert
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/swift"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "install builds a missing helper with swift and stages it" {
  make_watch_checkout
  touch "$CHECKOUT/Package.swift"
  swift_stub
  run "$CHECKOUT/ada-paseo-watch.sh" install
  assert_success
  assert_output_contains "Building native alert helper"
  [ -x "$ADA_PASEO_INSTALL_DIR/ada-alert" ]
}

@test "install reports a failed helper build" {
  make_watch_checkout
  touch "$CHECKOUT/Package.swift"
  swift_stub
  STUB_SWIFT=fail run "$CHECKOUT/ada-paseo-watch.sh" install
  assert_failure
  assert_output_contains "native helper build failed"
}

@test "install from a Homebrew prefix refuses a keg missing runtime files" {
  local prefix="$BATS_TEST_TMPDIR/brew"
  local libexec="$prefix/opt/ada/libexec"
  mkdir -p "$libexec/lib"
  cp "$REPO_ROOT/ada-paseo-watch.sh" "$libexec/"
  export HOMEBREW_PREFIX="$prefix"
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
  unset ADA_NATIVE_ALERT
  run "$libexec/ada-paseo-watch.sh" install
  assert_failure
  assert_output_contains "missing $libexec/lib/ada-paseo-watch.py"
  assert_output_contains "native helper ada-alert is required"
}

# Same Cellar -> opt rule as the installer: whatever the watcher prints for you
# to run later must survive `brew upgrade`.
@test "run from a Cellar keg, the watcher reports its stable opt path" {
  local prefix="$BATS_TEST_TMPDIR/brew"
  local keg="$prefix/Cellar/ada/9.9.9/libexec"
  mkdir -p "$keg/lib" "$prefix/opt"
  cp "$REPO_ROOT/ada-paseo-watch.sh" "$keg/"
  ln -s "../Cellar/ada/9.9.9" "$prefix/opt/ada"
  run "$keg/ada-paseo-watch.sh" status
  assert_success
  assert_output_contains "run: $prefix/opt/ada/libexec/ada-paseo-watch.sh install"
  refute_output_contains "Cellar"
}

@test "helpers: paseo CLI parsing, frontmost-app skip, label clipping, cleanup" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  run python3 "$BATS_TEST_DIRNAME/paseo_helpers_check.py"
  assert_success
  assert_output_contains "all paseo helper checks passed"
}

# The whole chain the LaunchAgent runs, minus launchd: the real loop polls a
# stub paseo that reports one agent running and then idle, and the finish alert
# must come out of the real launcher. Ctrl-C must end the loop cleanly, not with
# a traceback. SIGINT is re-armed because a background job starts with it ignored.
@test "the watcher loop turns a finished Paseo turn into an alert, and exits on Ctrl-C" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/paseo" <<'SH'
#!/bin/bash
state="$BATS_TEST_TMPDIR/paseo-polls"
case "$1" in
  ls)
    n=$(cat "$state" 2>/dev/null || echo 0); echo $((n + 1)) > "$state"
    if (( n == 0 )); then s=running; else s=idle; fi
    printf '[{"id":"a1","name":"fixer","provider":"claude/opus","status":"%s"}]\n' "$s" ;;
  permit) echo '[]' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/paseo"
  export PASEO_BIN="$BATS_TEST_TMPDIR/bin/paseo" ADA_PASEO_POLL=1 ADA_PASEO_THRESHOLD=0
  python3 - "$REPO_ROOT/lib/ada-paseo-watch.py" > "$BATS_TEST_TMPDIR/loop.out" 2>&1 <<'PY' &
import runpy, signal, sys
signal.signal(signal.SIGINT, signal.default_int_handler)
runpy.run_path(sys.argv[1], run_name="__main__")
PY
  local pid=$!
  if ! wait_for_file "$ADA_PROBE_OUT" 100; then
    kill "$pid"; cat "$BATS_TEST_TMPDIR/loop.out"; echo "the loop never fired"; false
  fi
  kill -INT "$pid"
  wait "$pid"
  assert_file_contains "$ADA_PROBE_OUT" "Paseo%20%C2%B7%20claude%20%C2%B7%20fixer"
  refute_file_contains "$BATS_TEST_TMPDIR/loop.out" "Traceback"
}

# A muted agent stays quiet through the same real chain, while another agent
# polled alongside it still alerts.
@test "the watcher loop drops alerts for a muted agent and keeps the others" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export ADA_NATIVE_ALERT="$STUBS/counting-ada-alert"
  export ADA_MUTE_DIR="$BATS_TEST_TMPDIR/muted"
  "$REPO_ROOT/lib/ada-mute.sh" add paseo-a1 >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/paseo" <<'SH'
#!/bin/bash
state="$BATS_TEST_TMPDIR/paseo-polls"
case "$1" in
  ls)
    n=$(cat "$state" 2>/dev/null || echo 0); echo $((n + 1)) > "$state"
    if (( n == 0 )); then s=running; else s=idle; fi
    printf '[{"id":"a1","name":"muted","status":"%s"},{"id":"a2","name":"loud","status":"%s"}]\n' "$s" "$s" ;;
  permit) echo '[]' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/paseo"
  export PASEO_BIN="$BATS_TEST_TMPDIR/bin/paseo" ADA_PASEO_POLL=1 ADA_PASEO_THRESHOLD=0
  python3 "$REPO_ROOT/lib/ada-paseo-watch.py" > "$BATS_TEST_TMPDIR/loop.out" 2>&1 &
  local pid=$!
  if ! wait_for_file "$ADA_PROBE_OUT" 100; then
    kill "$pid"; cat "$BATS_TEST_TMPDIR/loop.out"; echo "the loop never fired"; false
  fi
  sleep 1.5   # another poll, so a muted alert would have had time to land too
  kill "$pid"
  run wc -l < "$ADA_PROBE_OUT"
  assert_equal "$(echo $output)" "1"
  assert_file_contains "$ADA_PROBE_OUT" "loud"
  refute_file_contains "$ADA_PROBE_OUT" "muted"
}
