#!/usr/bin/env bats
# Tests for ada-menubar.sh — the menu bar item's login item (a LaunchAgent) —
# and for the staging it shares with the Paseo watcher through lib/ada-stage.sh.

setup() {
  load test_helper
  setup_common
  MENUBAR_SH="$REPO_ROOT/ada-menubar.sh"
  PLIST="$HOME/Library/LaunchAgents/com.ada.menubar.plist"
  export ADA_MENUBAR_INSTALL_DIR="$BATS_TEST_TMPDIR/stage"
}

# A checkout with every staged script and fake built helpers, so install never
# needs a real swift build. The front door is a copy so that $dir is the
# fixture (report.py credits verbatim copies to the repo file).
make_checkout() {
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CHECKOUT/lib" "$CHECKOUT/.build/release"
  local f
  for f in ada-paseo-watch.sh ada-menubar.sh alert.html; do cp "$REPO_ROOT/$f" "$CHECKOUT/"; done
  cp "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/lib/*.py "$CHECKOUT/lib/"
  printf '#!/bin/sh\necho fake-menubar\n' > "$CHECKOUT/.build/release/ada-menubar"
  chmod +x "$CHECKOUT/.build/release/ada-menubar"
}

swift_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/swift" <<'SH'
#!/bin/bash
echo "swift $*" >> "$BATS_TEST_TMPDIR/swift.log"
[ "${STUB_SWIFT:-ok}" = fail ] && exit 1
product=""
while [ $# -gt 0 ]; do [ "$1" = --product ] && product=$2; shift; done
mkdir -p .build/release && printf '#!/bin/sh\necho built\n' > ".build/release/$product"
chmod +x ".build/release/$product"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/swift"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "no command prints usage, an unknown one fails" {
  run "$MENUBAR_SH"
  assert_success
  assert_output_contains "ada-menubar.sh install"
  run "$MENUBAR_SH" frobnicate
  [ "$status" -eq 2 ]
  assert_output_contains "unknown command: frobnicate"
}

# --- install from a checkout: stage, then load ---------------------------------------

@test "install stages the shared runtime and both helpers, then loads the plist" {
  make_checkout
  export STUB_LAUNCHCTL_LOG="$BATS_TEST_TMPDIR/launchctl.log"
  run "$CHECKOUT/ada-menubar.sh" install
  assert_success
  assert_output_contains "Installed and loaded: $PLIST"
  local stage=$ADA_MENUBAR_INSTALL_DIR f
  for f in ada-menubar.sh ada-paseo-watch.sh alert.html lib/ada-show-alert.sh lib/ada-snooze-daemon.py \
           lib/ada-mute.sh lib/ada-pause.sh lib/ada-history.sh lib/ada-notify.sh lib/ada-stage.sh \
           lib/ada-status.sh lib/ada-paseo-watch.py; do
    [ -f "$stage/$f" ] || { echo "not staged: $f"; false; }
  done
  [ -x "$stage/ada-menubar" ]
  [ -x "$stage/ada-alert" ]
  [ -x "$stage/lib/ada-pause.sh" ]
  # A staged installer would wire integrations to the stage.
  [ ! -e "$stage/ada-install.sh" ]
  [ ! -e "$stage/ada.sh" ]
  [ ! -e "$stage/lib/ada-claude-hook.sh" ]
  assert_file_contains "$stage/stage-info" "source=$CHECKOUT"
  assert_file_contains "$stage/stage-info" "by=ada-menubar"
  assert_file_contains "$BATS_TEST_TMPDIR/launchctl.log" "unload $PLIST"
  assert_file_contains "$BATS_TEST_TMPDIR/launchctl.log" "load -w $PLIST"
}

@test "the plist runs the staged binary, restarts it only after a failure, and is valid" {
  make_checkout
  run "$CHECKOUT/ada-menubar.sh" install
  assert_success
  command -v plutil >/dev/null && { run plutil -lint "$PLIST"; assert_success; }
  local program
  program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST")
  assert_equal "$program" "$ADA_MENUBAR_INSTALL_DIR/ada-menubar"
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST")" com.ada.menubar
  # Quit exits 0 and must stay quit; a crash or the relaunch exit restarts it.
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$PLIST")" false
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$PLIST")" true
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :LimitLoadToSessionType' "$PLIST")" Aqua
  # A Test Alert window must outlive the menu bar quitting.
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :AbandonProcessGroup' "$PLIST")" true
  assert_file_contains "$PLIST" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  run find "$HOME/Library/LaunchAgents" -name 'com.ada.menubar.plist.*'
  assert_equal "$output" ""
}

@test "the menu bar and the Paseo watcher share one stage" {
  make_checkout
  export ADA_PASEO_INSTALL_DIR="$ADA_MENUBAR_INSTALL_DIR"
  run "$CHECKOUT/ada-paseo-watch.sh" install
  assert_success
  run "$CHECKOUT/ada-menubar.sh" install
  assert_success
  assert_file_contains "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" "$ADA_MENUBAR_INSTALL_DIR/ada-paseo-watch.sh"
  assert_file_contains "$PLIST" "$ADA_MENUBAR_INSTALL_DIR/ada-menubar"
  # Uninstalling one job leaves the other's runtime alone.
  run "$ADA_MENUBAR_INSTALL_DIR/ada-menubar.sh" uninstall
  assert_success
  [ -f "$ADA_MENUBAR_INSTALL_DIR/lib/ada-paseo-watch.py" ]
  [ -f "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" ]
}

@test "the staging dir falls back to the Paseo watcher's, then ~/.local/share/ada" {
  make_checkout
  unset ADA_MENUBAR_INSTALL_DIR
  export ADA_PASEO_INSTALL_DIR="$BATS_TEST_TMPDIR/paseo-stage"
  run "$CHECKOUT/ada-menubar.sh" install
  assert_success
  [ -x "$ADA_PASEO_INSTALL_DIR/ada-menubar" ]
  unset ADA_PASEO_INSTALL_DIR
  run "$CHECKOUT/ada-menubar.sh" install
  assert_success
  [ -x "$HOME/.local/share/ada/ada-menubar" ]
}

@test "install builds a missing menu bar helper with swift" {
  make_checkout
  rm "$CHECKOUT/.build/release/ada-menubar"
  touch "$CHECKOUT/Package.swift"
  swift_stub
  run "$CHECKOUT/ada-menubar.sh" install
  assert_success
  assert_output_contains "Building ada-menubar helper"
  assert_file_contains "$BATS_TEST_TMPDIR/swift.log" "build -c release --product ada-menubar"
  assert_file_contains "$ADA_MENUBAR_INSTALL_DIR/ada-menubar" "built"
}

@test "install fails, loading nothing, when the helper can't be built" {
  make_checkout
  rm "$CHECKOUT/.build/release/ada-menubar"
  touch "$CHECKOUT/Package.swift"
  swift_stub
  STUB_SWIFT=fail run "$CHECKOUT/ada-menubar.sh" install
  assert_failure
  assert_output_contains "native helper build failed"
  assert_output_contains "native helper ada-menubar is required"
  [ ! -f "$PLIST" ]
}

@test "install reports a failed load" {
  make_checkout
  STUB_LAUNCHCTL_LOAD_FAIL=1 run "$CHECKOUT/ada-menubar.sh" install
  assert_failure
  assert_output_contains "'launchctl load' failed"
}

@test "install says so when lib/ada-stage.sh is missing" {
  local root="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/ada-menubar.sh" "$root/"
  run "$root/ada-menubar.sh" install
  assert_failure
  assert_output_contains "missing $root/lib/ada-stage.sh"
  [ ! -f "$PLIST" ]
}

# --- Homebrew: run in place from opt ------------------------------------------------

brew_libexec() {
  BREW_PREFIX="$BATS_TEST_TMPDIR/brew"
  LIBEXEC="$BREW_PREFIX/opt/ada/libexec"
  mkdir -p "$LIBEXEC/lib"
  local f
  for f in ada-paseo-watch.sh ada-menubar.sh alert.html; do cp "$REPO_ROOT/$f" "$LIBEXEC/"; done
  cp "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/lib/*.py "$LIBEXEC/lib/"
  printf '#!/bin/sh\n' > "$LIBEXEC/ada-alert"
  printf '#!/bin/sh\n' > "$LIBEXEC/ada-menubar"
  chmod +x "$LIBEXEC/ada-alert" "$LIBEXEC/ada-menubar"
  export HOMEBREW_PREFIX="$BREW_PREFIX"
  unset ADA_NATIVE_ALERT
}

@test "install from a Homebrew prefix runs in place instead of staging" {
  brew_libexec
  run "$LIBEXEC/ada-menubar.sh" install
  assert_success
  assert_output_contains "running the menu bar in place from $LIBEXEC"
  assert_equal "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST")" "$LIBEXEC/ada-menubar"
  [ ! -e "$ADA_MENUBAR_INSTALL_DIR" ]
}

@test "install from a Homebrew prefix refuses a keg without the menu bar helper" {
  brew_libexec
  rm "$LIBEXEC/ada-menubar"
  run "$LIBEXEC/ada-menubar.sh" install
  assert_failure
  assert_output_contains "native helper ada-menubar is required (looked for $LIBEXEC/ada-menubar)"
  [ ! -f "$PLIST" ]
}

@test "run from a Cellar keg, the front door reports its stable opt path" {
  local prefix="$BATS_TEST_TMPDIR/brew"
  local keg="$prefix/Cellar/ada/9.9.9/libexec"
  mkdir -p "$keg/lib" "$prefix/opt"
  cp "$REPO_ROOT/ada-menubar.sh" "$keg/"
  cp "$REPO_ROOT/lib/ada-stage.sh" "$keg/lib/"
  ln -s "../Cellar/ada/9.9.9" "$prefix/opt/ada"
  run "$keg/ada-menubar.sh" status
  assert_success
  assert_output_contains "run: $prefix/opt/ada/libexec/ada-menubar.sh install"
  refute_output_contains "Cellar"
}

# --- uninstall, start, status ------------------------------------------------------

@test "uninstall removes the plist, and says when there is none" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  run "$CHECKOUT/ada-menubar.sh" uninstall
  assert_success
  assert_output_contains "Removed: $PLIST"
  [ ! -f "$PLIST" ]
  run "$CHECKOUT/ada-menubar.sh" uninstall
  assert_output_contains "Not installed"
}

@test "start kickstarts a loaded login item" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  export STUB_LAUNCHCTL_LOG="$BATS_TEST_TMPDIR/launchctl.log" STUB_LAUNCHCTL_LOADED="com.ada.menubar"
  run "$CHECKOUT/ada-menubar.sh" start
  assert_success
  assert_output_contains "Started the ADA menu bar."
  assert_file_contains "$STUB_LAUNCHCTL_LOG" "kickstart gui/$(id -u)/com.ada.menubar"
  refute_file_contains "$STUB_LAUNCHCTL_LOG" "load -w"
}

@test "start loads an installed but unloaded login item first" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  export STUB_LAUNCHCTL_LOG="$BATS_TEST_TMPDIR/launchctl.log"
  run "$CHECKOUT/ada-menubar.sh" start
  assert_success
  assert_file_contains "$STUB_LAUNCHCTL_LOG" "load -w $PLIST"
  assert_file_contains "$STUB_LAUNCHCTL_LOG" "kickstart"
}

@test "start without a login item, or with kickstart failing, says what to do" {
  make_checkout
  run "$CHECKOUT/ada-menubar.sh" start
  assert_failure
  assert_output_contains "not installed — run: $CHECKOUT/ada-menubar.sh install"
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  STUB_LAUNCHCTL_LOADED="com.ada.menubar" STUB_LAUNCHCTL_KICKSTART_FAIL=1 run "$CHECKOUT/ada-menubar.sh" start
  assert_failure
  assert_output_contains "'launchctl kickstart' failed"
}

@test "status: not installed" {
  run "$MENUBAR_SH" status
  assert_success
  assert_output_contains "not a login item — run: $REPO_ROOT/ada-menubar.sh install"
  assert_output_contains "plist: (none)"
  assert_output_contains "runtime: (not installed)"
}

@test "status: running, with the stage and where it came from" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  STUB_LAUNCHCTL_LOADED="com.ada.menubar" STUB_LAUNCHCTL_PIDS="com.ada.menubar=4242" run "$CHECKOUT/ada-menubar.sh" status
  assert_success
  assert_output_contains "Menu bar: running (pid 4242)"
  assert_output_contains "plist: $PLIST"
  assert_output_contains "runtime: $ADA_MENUBAR_INSTALL_DIR"
  assert_output_contains "staged from: $CHECKOUT"
  refute_output_contains "differs from the staged copy"
  assert_output_contains "log clean"
}

@test "status: loaded but quit, and a stage older than the checkout" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  echo "# edited" >> "$CHECKOUT/lib/ada-pause.sh"
  STUB_LAUNCHCTL_LOADED="com.ada.menubar" run "$CHECKOUT/ada-menubar.sh" status
  assert_output_contains "loaded but not running (quit from its menu?) — start it: $CHECKOUT/ada-menubar.sh start"
  assert_output_contains "differs from the staged copy (re-run install)"
}

@test "status: a rebuilt helper counts as a stale stage" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  printf '#!/bin/sh\necho rebuilt\n' > "$CHECKOUT/.build/release/ada-menubar"
  run "$CHECKOUT/ada-menubar.sh" status
  assert_output_contains "differs from the staged copy"
}

@test "status: shows the log when the menu bar wrote to it" {
  make_checkout
  "$CHECKOUT/ada-menubar.sh" install >/dev/null
  echo "ada-menubar: another ADA menu bar is already running" > "$TMPDIR/ada-menubar.log"
  run "$CHECKOUT/ada-menubar.sh" status
  assert_output_contains "log has output"
  assert_output_contains "already running"
}

# --- the three copies of __ada_stable_dir ------------------------------------------

@test "__ada_stable_dir is identical in all three front doors" {
  body() { sed -n '/^__ada_stable_dir() {$/,/^}$/p' "$1"; }
  local installer paseo menubar
  installer=$(body "$REPO_ROOT/ada-install.sh")
  paseo=$(body "$REPO_ROOT/ada-paseo-watch.sh")
  menubar=$(body "$REPO_ROOT/ada-menubar.sh")
  [ -n "$installer" ]
  assert_equal "$paseo" "$installer"
  assert_equal "$menubar" "$installer"
}
