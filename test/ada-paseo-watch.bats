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

# The poll/diff loop (running->idle, running->error, seeding, permission dedupe,
# ADA_PASEO_EVENTS subsetting) lives in the .py and can't be reached via the
# front door. Driven directly by test/paseo_diff_check.py.
@test "poll/diff loop: finish/fail/seeding/dedupe/events behave correctly" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  run python3 "$BATS_TEST_DIRNAME/paseo_diff_check.py"
  assert_success
  assert_output_contains "all paseo diff-loop checks passed"
}
