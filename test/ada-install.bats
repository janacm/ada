#!/usr/bin/env bats
# Tests for ada-install.sh — the onboarding installer.
# Writes are sandboxed by pointing HOME at a temp dir; read-only paths
# (--list/--help) and --dry-run never write at all.

setup() {
  load test_helper
  setup_common
  INSTALL="$REPO_ROOT/ada-install.sh"
}

# Structurally assert a settings/hooks JSON file wires exactly one ada hook into
# the given event, with the expected async flag. Anchors to the consumer
# contract (event keys Claude Code / Codex actually read), not a substring count.
assert_hook_wired() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, event, want_async = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
data = json.load(open(path))                      # also asserts valid JSON
groups = data["hooks"][event]
cmds = [h for g in groups for h in g.get("hooks", [])
        if h.get("command", "").endswith("/ada-claude-hook.sh")]
assert len(cmds) == 1, f"{event}: expected exactly 1 ada hook, got {len(cmds)}"
assert "/lib/ada-claude-hook.sh" in cmds[0]["command"], f"{event}: not the lib/ path: {cmds[0]['command']}"
got = bool(cmds[0].get("async", False))
assert got == want_async, f"{event}: async={got}, want {want_async}"
print("ok")
PY
}

@test "--list shows the known integrations" {
  run "$INSTALL" --list
  assert_success
  assert_output_contains "terminal"
  assert_output_contains "claude"
  assert_output_contains "codex"
  assert_output_contains "opencode"
  assert_output_contains "paseo"
}

@test "--help prints usage" {
  run "$INSTALL" --help
  assert_success
  assert_output_contains "Usage"
  assert_output_contains "--agents"
}

@test "an unknown agent id is rejected" {
  run "$INSTALL" --agents bogus
  assert_failure
  assert_output_contains "unknown integration"
}

@test "no agents and no TTY fails rather than hanging" {
  # interactive_select requires a TTY; under bats stdin/stdout aren't TTYs.
  run "$INSTALL"
  assert_failure
  assert_output_contains "terminal"
}

@test "a named-but-unavailable agent is rejected distinctly from an unknown one" {
  # setup_common gives a clean temp HOME, so ~/.codex is absent -> codex unavailable.
  run "$INSTALL" --agents codex
  assert_failure
  assert_output_contains "not available"
}

@test "--agents all selects only available integrations" {
  # clean temp HOME: terminal (zsh) is always available; claude/codex are not.
  run "$INSTALL" --agents all --dry-run
  assert_success
  assert_output_contains "terminal"
}

@test "--dry-run --agents terminal writes nothing" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  run "$INSTALL" --dry-run --agents terminal
  assert_success
  assert_output_contains "dry-run"
  [ ! -f "$HOME/.zshrc" ]
}

# Homebrew's #{libexec} is <prefix>/Cellar/ada/<version>/libexec, which the next
# `brew upgrade` deletes. The installer bakes its own directory into ~/.zshrc and
# the agent hook config, so a Cellar path there means every integration breaks on
# upgrade. Anything durable must name the version-stable <prefix>/opt path.
@test "invoked from a Cellar path, durable config points at the stable opt path" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.claude"
  echo '{}' > "$HOME/.claude/settings.json"

  local prefix="$BATS_TEST_TMPDIR/brew"
  local keg="$prefix/Cellar/ada/9.9.9/libexec"
  mkdir -p "$keg/lib" "$prefix/opt"
  cp "$REPO_ROOT/ada-install.sh" "$REPO_ROOT/ada.sh" "$REPO_ROOT/alert.html" "$keg/"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$REPO_ROOT/lib/ada-claude-hook.sh" \
     "$REPO_ROOT/lib/ada-notify.sh" "$REPO_ROOT/lib/ada-opencode-plugin.mjs" "$keg/lib/"
  cp "$REPO_ROOT/ada-alert" "$keg/ada-alert" 2>/dev/null \
    || cp "$REPO_ROOT/.build/release/ada-alert" "$keg/ada-alert"
  ln -s "../Cellar/ada/9.9.9" "$prefix/opt/ada"

  run "$keg/ada-install.sh" --agents terminal,claude,opencode --no-test
  assert_success

  assert_file_contains "$HOME/.zshrc" "$prefix/opt/ada/libexec/ada.sh"
  refute_file_contains "$HOME/.zshrc" "Cellar"
  assert_file_contains "$HOME/.claude/settings.json" "$prefix/opt/ada/libexec/lib/ada-claude-hook.sh"
  refute_file_contains "$HOME/.claude/settings.json" "Cellar"

  # The opencode plugin shim is just as durable: it names a path that opencode
  # imports on every start, so a Cellar path there dies on the next upgrade.
  shim="$HOME/.config/opencode/plugin/ada.js"
  assert_file_contains "$shim" "$prefix/opt/ada/libexec/lib/ada-opencode-plugin.mjs"
  refute_file_contains "$shim" "Cellar"
}

@test "terminal install adds a managed block and is idempotent" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  printf '# my existing rc\nexport FOO=bar\n' > "$HOME/.zshrc"

  run "$INSTALL" --agents terminal --no-test
  assert_success
  assert_file_contains "$HOME/.zshrc" "# >>> ada >>>"
  assert_file_contains "$HOME/.zshrc" "ada.sh"
  assert_file_contains "$HOME/.zshrc" "export FOO=bar"   # preserved

  # Re-running must not duplicate the managed block.
  run "$INSTALL" --agents terminal --no-test
  assert_success
  run grep -c '# >>> ada >>>' "$HOME/.zshrc"
  assert_equal "$output" "1"
}

@test "terminal install migrates a legacy iyf block (replaces, not duplicates)" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  # Simulate a pre-rename install: an old managed block sourcing a stale path.
  cat > "$HOME/.zshrc" <<'RC'
# my existing rc
export FOO=bar
# >>> iyf >>>
# In Your Face terminal command alerts
source "$HOME/.iyf/iyf.sh"
# <<< iyf <<<
RC

  run "$INSTALL" --agents terminal --no-test
  assert_success
  # The legacy block is gone; the new ada block is present exactly once.
  run grep -c '# >>> iyf >>>' "$HOME/.zshrc"
  assert_equal "$output" "0"
  refute_file_contains "$HOME/.zshrc" "iyf.sh"
  run grep -c '# >>> ada >>>' "$HOME/.zshrc"
  assert_equal "$output" "1"
  assert_file_contains "$HOME/.zshrc" "ada.sh"
  assert_file_contains "$HOME/.zshrc" "export FOO=bar"   # unrelated lines preserved
}

@test "claude install migrates a legacy iyf hook (replaces, not duplicates)" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  # Pre-rename install: hooks point at the old iyf-claude-hook.sh path.
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/Users/x/.iyf/iyf-claude-hook.sh", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/Users/x/.iyf/iyf-claude-hook.sh", "timeout": 10, "async": true } ] }
    ]
  }
}
JSON

  run "$INSTALL" --agents claude --no-test
  assert_success
  settings="$HOME/.claude/settings.json"
  # Exactly one ada hook per event, and zero legacy iyf hooks remain.
  run assert_hook_wired "$settings" UserPromptSubmit false
  assert_success
  run assert_hook_wired "$settings" Stop true
  assert_success
  refute_file_contains "$settings" "iyf-claude-hook.sh"
}

@test "claude install merges hooks, preserves unrelated ones, and is idempotent" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/opt/unrelated-hook.sh" } ] }
    ]
  }
}
JSON

  run "$INSTALL" --agents claude --no-test
  assert_success

  settings="$HOME/.claude/settings.json"
  # Structural: one ada hook in each event; Claude's Stop hook must be async.
  run assert_hook_wired "$settings" UserPromptSubmit false
  assert_success
  run assert_hook_wired "$settings" Stop true
  assert_success
  # unrelated hook preserved.
  assert_file_contains "$settings" "/opt/unrelated-hook.sh"
  # a timestamped backup was written.
  run bash -c "ls $HOME/.claude/settings.json.bak.ada-* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" -ge 1 ]

  # Re-run: still exactly one per event (no duplication); unrelated hook intact.
  run "$INSTALL" --agents claude --no-test
  assert_success
  run assert_hook_wired "$settings" UserPromptSubmit false
  assert_success
  run assert_hook_wired "$settings" Stop true
  assert_success
  assert_file_contains "$settings" "/opt/unrelated-hook.sh"
}

@test "codex install merges hooks into ~/.codex/hooks.json without the async flag" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/opt/codex-unrelated.sh" } ] }
    ]
  }
}
JSON

  run "$INSTALL" --agents codex --no-test
  assert_success

  hooks="$HOME/.codex/hooks.json"
  # Codex differs from Claude: the Stop hook must NOT carry async:true.
  run assert_hook_wired "$hooks" UserPromptSubmit false
  assert_success
  run assert_hook_wired "$hooks" Stop false
  assert_success
  assert_file_contains "$hooks" "/opt/codex-unrelated.sh"

  # Idempotent: re-running keeps exactly one ada hook per event.
  run "$INSTALL" --agents codex --no-test
  assert_success
  run assert_hook_wired "$hooks" Stop false
  assert_success
}

@test "opencode install drops a plugin shim in the config dir it reports" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"

  run "$INSTALL" --agents opencode --no-test
  assert_success

  # The path comes from the stub `opencode debug paths`, proving the installer
  # asks opencode rather than assuming ~/.config.
  shim="$HOME/.config/opencode/plugin/ada.js"
  [ -f "$shim" ]
  assert_file_contains "$shim" "$REPO_ROOT/lib/ada-opencode-plugin.mjs"
  assert_file_contains "$shim" "export *"

  # Idempotent: re-running leaves exactly one shim and no backup clutter.
  run "$INSTALL" --agents opencode --no-test
  assert_success
  run bash -c "ls '$HOME/.config/opencode/plugin' | wc -l"
  assert_equal "$(echo $output)" "1"
}

@test "opencode install honors a relocated config root" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export STUB_OPENCODE_CONFIG="$BATS_TEST_TMPDIR/xdg/opencode"

  run "$INSTALL" --agents opencode --no-test
  assert_success
  [ -f "$BATS_TEST_TMPDIR/xdg/opencode/plugin/ada.js" ]
  [ ! -f "$HOME/.config/opencode/plugin/ada.js" ]
}

@test "opencode install backs up an unrelated plugin named ada.js" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/opencode/plugin"
  echo 'export const NotOurs = async () => ({})' > "$HOME/.config/opencode/plugin/ada.js"

  run "$INSTALL" --agents opencode --no-test
  assert_success
  assert_output_contains "backup:"
  run bash -c "cat '$HOME/.config/opencode/plugin/'ada.js.bak.ada-*"
  assert_output_contains "NotOurs"
}

@test "--dry-run --agents opencode writes no plugin file" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  run "$INSTALL" --dry-run --agents opencode
  assert_success
  assert_output_contains "dry-run"
  [ ! -f "$HOME/.config/opencode/plugin/ada.js" ]
}

@test "the installer refuses to run without the opencode plugin module" {
  local fake="$BATS_TEST_TMPDIR/fake-install"
  mkdir -p "$fake/lib"
  cp "$REPO_ROOT/ada-install.sh" "$fake/"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$REPO_ROOT/lib/ada-claude-hook.sh" \
     "$REPO_ROOT/lib/ada-notify.sh" "$fake/lib/"
  # Everything present EXCEPT lib/ada-opencode-plugin.mjs, which the shim the
  # installer writes will import on every opencode start.
  run "$fake/ada-install.sh" --list
  assert_success
  run "$fake/ada-install.sh" --agents terminal --no-test
  assert_failure
  assert_output_contains "ada-opencode-plugin.mjs"
}

# A row the selector is willing to install must not describe itself as missing.
@test "the opencode row never reads 'not found' once its config dir exists" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/opencode"
  export ADA_OPENCODE_PLUGIN_DIR="$HOME/.config/opencode/plugin"
  run "$INSTALL" --list
  assert_success
  # Scope the assertion to the opencode row: the paseo row legitimately reads
  # "not found" on a machine without Paseo.
  run bash -c "\"$INSTALL\" --list | grep '^opencode'"
  assert_success
  refute_output_contains "not found"
}

# The "config found, no CLI" branch. The suite's own test/stubs/opencode is on
# PATH, and find_opencode also checks absolute fallback paths, so hide both:
# a system-only PATH, and ADA_OPENCODE_FALLBACK_PATHS emptied.
@test "with a config dir but no CLI anywhere, opencode reports the config, not absence" {
  if [ -x /usr/bin/opencode ] || [ -x /bin/opencode ]; then
    skip "opencode is installed in a system directory; this branch is unobservable here"
  fi
  export PATH="/usr/bin:/bin"
  export ADA_OPENCODE_FALLBACK_PATHS=""
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/opencode"
  export ADA_OPENCODE_PLUGIN_DIR="$HOME/.config/opencode/plugin"
  run bash -c "\"$INSTALL\" --list | grep '^opencode'"
  assert_success
  assert_output_contains "config found, no CLI"
}

# A symlinked ada.js is not ours: back it up, and never write through it into
# whatever it points at.
@test "opencode install replaces a symlinked ada.js without touching its target" {
  require_native_helper
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/opencode/plugin" "$BATS_TEST_TMPDIR/target"
  cp "$REPO_ROOT/lib/ada-opencode-plugin.mjs" "$BATS_TEST_TMPDIR/target/plugin.mjs"
  ln -s "$BATS_TEST_TMPDIR/target/plugin.mjs" "$HOME/.config/opencode/plugin/ada.js"

  run "$INSTALL" --agents opencode --no-test
  assert_success
  assert_output_contains "backup:"
  cmp -s "$REPO_ROOT/lib/ada-opencode-plugin.mjs" "$BATS_TEST_TMPDIR/target/plugin.mjs"
  [ ! -L "$HOME/.config/opencode/plugin/ada.js" ]
  assert_file_contains "$HOME/.config/opencode/plugin/ada.js" "export *"
}

# --- the interactive selector, driven through a pty ---------------------------
# interactive_select refuses to run without a terminal, so these go through
# test/pty_run.py. HOME has ~/.claude and ~/.codex and the opencode stub is on
# PATH, so four rows start selected; Paseo has no CLI, so its row is locked.
# --dry-run keeps every install step to a "would ..." line, which is how each
# test reads back what the selection ended up being.
select_keys() {
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  run python3 "$BATS_TEST_DIRNAME/pty_run.py" "$@" -- "$INSTALL" --dry-run --no-test
}

@test "the selector lists every integration, locks the unavailable one, and confirms on enter" {
  select_keys '\r'
  assert_success
  assert_output_contains "[-] Paseo"
  assert_output_contains "unavailable: not found"
  assert_output_contains "Selected: Terminal commands, Claude Code, Codex, opencode"
  assert_output_contains "Installing terminal integration"
  assert_output_contains "Installing Claude Code integration"
  assert_output_contains "Installing Codex integration"
  assert_output_contains "Installing opencode integration"
}

# macOS /bin/bash 3.2 rejects a fractional `read -t`, which used to leave the
# arrow keys dead: the ESC read fine, its "[B" never did, and the space landed
# on the first row instead of the second.
@test "the down arrow moves the cursor before space toggles a row" {
  select_keys '\x1b[B' ' ' '\r'
  assert_success
  assert_output_contains "Installing terminal integration"
  refute_output_contains "Installing Claude Code integration"
}

@test "up from the first row wraps to the last available row, skipping Paseo" {
  select_keys '\x1b[A' ' ' '\r'
  assert_success
  refute_output_contains "Installing opencode integration"
  assert_output_contains "Installing terminal integration"
}

@test "j and k move the cursor too" {
  select_keys j j k ' ' '\r'
  assert_success
  refute_output_contains "Installing Claude Code integration"
  assert_output_contains "Installing Codex integration"
}

@test "a clears a full selection, and confirming nothing is refused" {
  select_keys a '\r'
  assert_failure
  assert_output_contains "Selected: (none)"
  assert_output_contains "no integrations selected"
}

@test "a selects every available row when any is unselected" {
  select_keys ' ' a '\r'
  assert_success
  assert_output_contains "Installing terminal integration"
  assert_output_contains "Installing opencode integration"
}

@test "q cancels without installing anything" {
  select_keys q
  assert_failure
  assert_output_contains "cancelled"
  refute_output_contains "Installing"
}

# --- argument forms and preflight checks --------------------------------------

@test "--agents=LIST and --all are accepted spellings" {
  run "$INSTALL" --agents=terminal --dry-run --no-test
  assert_success
  assert_output_contains "Installing terminal integration"
  run "$INSTALL" --all --dry-run --no-test
  assert_success
  assert_output_contains "Installing terminal integration"
}

@test "--agents with no value is an error" {
  run "$INSTALL" --agents
  assert_failure
  assert_output_contains "--agents requires a value"
}

@test "an unknown argument is an error" {
  run "$INSTALL" --frobnicate
  assert_failure
  assert_output_contains "unknown argument '--frobnicate'"
}

@test "anything other than macOS is refused" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho Linux\n' > "$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$INSTALL" --agents terminal --dry-run
  assert_failure
  assert_output_contains "supports macOS only"
}

# A checkout that is missing part of the runtime. The installer is symlinked in,
# so it resolves its directory to the fixture, not to the repo.
make_partial_checkout() {
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CHECKOUT/lib"
  ln -s "$REPO_ROOT/ada-install.sh" "$CHECKOUT/ada-install.sh"
  local f
  for f in "$@"; do ln -s "$REPO_ROOT/$f" "$CHECKOUT/$f"; done
}

@test "a checkout missing the launcher is refused" {
  make_partial_checkout lib/ada-claude-hook.sh lib/ada-notify.sh lib/ada-opencode-plugin.mjs
  run "$CHECKOUT/ada-install.sh" --agents terminal --dry-run
  assert_failure
  assert_output_contains "missing executable $CHECKOUT/lib/ada-show-alert.sh"
}

@test "a checkout missing the Claude hook is refused" {
  make_partial_checkout lib/ada-show-alert.sh lib/ada-notify.sh lib/ada-opencode-plugin.mjs
  run "$CHECKOUT/ada-install.sh" --agents terminal --dry-run
  assert_failure
  assert_output_contains "missing executable $CHECKOUT/lib/ada-claude-hook.sh"
}

@test "a checkout missing ada-notify.sh is refused" {
  make_partial_checkout lib/ada-show-alert.sh lib/ada-claude-hook.sh lib/ada-opencode-plugin.mjs
  run "$CHECKOUT/ada-install.sh" --agents terminal --dry-run
  assert_failure
  assert_output_contains "missing executable $CHECKOUT/lib/ada-notify.sh"
}

# --- building the native helper -----------------------------------------------
# There is no browser fallback, so an install with no ada-alert must build one.
# A stub swift stands in for SwiftPM; STUB_SWIFT says what the "build" does.

full_checkout_without_helper() {
  make_partial_checkout lib/ada-show-alert.sh lib/ada-claude-hook.sh \
    lib/ada-notify.sh lib/ada-opencode-plugin.mjs ada.sh alert.html
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/swift" <<'SH'
#!/bin/bash
echo "swift $*" >> "$BATS_TEST_TMPDIR/swift.log"
case "${STUB_SWIFT:-ok}" in
  ok) mkdir -p .build/release && printf '#!/bin/sh\nexit 0\n' > .build/release/ada-alert \
        && chmod +x .build/release/ada-alert ;;
  fail) exit 1 ;;
  empty) exit 0 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/swift"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "with no helper and no Package.swift, the installer cannot build one" {
  full_checkout_without_helper
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_failure
  assert_output_contains "missing Package.swift"
}

@test "--dry-run reports the helper build instead of running it" {
  full_checkout_without_helper
  ln -s "$REPO_ROOT/Package.swift" "$CHECKOUT/Package.swift"
  run "$CHECKOUT/ada-install.sh" --agents terminal --dry-run --no-test
  assert_success
  assert_output_contains "dry-run: would run swift build -c release --product ada-alert"
  [ ! -e "$BATS_TEST_TMPDIR/swift.log" ]
}

@test "a missing helper is built with swift, then used" {
  full_checkout_without_helper
  ln -s "$REPO_ROOT/Package.swift" "$CHECKOUT/Package.swift"
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  assert_output_contains "Building native alert helper"
  assert_output_contains "Native alert helper -> $CHECKOUT/.build/release/ada-alert"
  assert_file_contains "$BATS_TEST_TMPDIR/swift.log" "build -c release --product ada-alert"
}

@test "a failed helper build stops the install" {
  full_checkout_without_helper
  ln -s "$REPO_ROOT/Package.swift" "$CHECKOUT/Package.swift"
  STUB_SWIFT=fail run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_failure
  assert_output_contains "failed to build native ada-alert"
  [ ! -f "$HOME/.zshrc" ]
}

@test "a build that produces no helper stops the install" {
  full_checkout_without_helper
  ln -s "$REPO_ROOT/Package.swift" "$CHECKOUT/Package.swift"
  STUB_SWIFT=empty run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_failure
  assert_output_contains "did not produce an executable ada-alert"
}

# --- rebuilding a stale helper ---------------------------------------------
# A .build/ helper older than the Swift sources predates a `git pull` and is
# rebuilt. Dates are pinned with touch -t so "older" never depends on timing.

stale_helper_checkout() {
  full_checkout_without_helper
  export ADA_REBUILD_HELPER=1
  mkdir -p "$CHECKOUT/.build/release" "$CHECKOUT/Sources/ADAAlert"
  printf '#!/bin/sh\nexit 7\n' > "$CHECKOUT/.build/release/ada-alert"
  chmod +x "$CHECKOUT/.build/release/ada-alert"
  touch -t 202001010000 "$CHECKOUT/Package.swift" "$CHECKOUT/.build/release/ada-alert"
  touch -t 202101010000 "$CHECKOUT/Sources/ADAAlert/main.swift"
}

@test "a helper older than the Swift sources is rebuilt" {
  stale_helper_checkout
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  assert_output_contains "Swift sources changed since $CHECKOUT/.build/release/ada-alert was built; rebuilding"
  assert_file_contains "$BATS_TEST_TMPDIR/swift.log" "build -c release --product ada-alert"
  assert_file_contains "$CHECKOUT/.build/release/ada-alert" "exit 0"
}

@test "a newer Package.swift alone marks the helper stale" {
  stale_helper_checkout
  touch -t 201901010000 "$CHECKOUT/Sources/ADAAlert/main.swift"
  touch -t 202101010000 "$CHECKOUT/Package.swift"
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  assert_file_contains "$BATS_TEST_TMPDIR/swift.log" "build -c release"
}

@test "a helper newer than every Swift source is used without a build" {
  stale_helper_checkout
  touch -t 202201010000 "$CHECKOUT/.build/release/ada-alert"
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  assert_output_contains "Native alert helper -> $CHECKOUT/.build/release/ada-alert"
  [ ! -e "$BATS_TEST_TMPDIR/swift.log" ]
}

@test "the rebuild stamps the helper, so the next install does not build again" {
  stale_helper_checkout
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  rm "$BATS_TEST_TMPDIR/swift.log"
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/swift.log" ]
}

@test "a failed rebuild keeps the older helper and finishes the install" {
  stale_helper_checkout
  STUB_SWIFT=fail run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  assert_output_contains "could not rebuild ada-alert; keeping the older $CHECKOUT/.build/release/ada-alert"
  assert_file_contains "$HOME/.zshrc" "# >>> ada >>>"
}

@test "--dry-run reports a stale rebuild instead of running it" {
  stale_helper_checkout
  run "$CHECKOUT/ada-install.sh" --agents terminal --dry-run --no-test
  assert_success
  assert_output_contains "dry-run: would rebuild $CHECKOUT/.build/release/ada-alert"
  [ ! -e "$BATS_TEST_TMPDIR/swift.log" ]
}

@test "a prebuilt ada-alert at the install root is never rebuilt" {
  # Homebrew's layout: the helper sits beside the scripts in a read-only keg.
  stale_helper_checkout
  rm -r "$CHECKOUT/.build"
  printf '#!/bin/sh\nexit 0\n' > "$CHECKOUT/ada-alert"
  chmod +x "$CHECKOUT/ada-alert"
  touch -t 202001010000 "$CHECKOUT/ada-alert"
  run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  assert_output_contains "Native alert helper -> $CHECKOUT/ada-alert"
  [ ! -e "$BATS_TEST_TMPDIR/swift.log" ]
}

@test "ADA_REBUILD_HELPER=0 skips the staleness check" {
  stale_helper_checkout
  ADA_REBUILD_HELPER=0 run "$CHECKOUT/ada-install.sh" --agents terminal --no-test
  assert_success
  [ ! -e "$BATS_TEST_TMPDIR/swift.log" ]
}

# --- the sample alert and Paseo delegation ------------------------------------

@test "without --no-test the installer fires a sample alert" {
  require_native_helper
  run "$INSTALL" --agents terminal
  assert_success
  assert_output_contains "Firing a sample alert"
  wait_for_file "$ADA_PROBE_OUT" || { echo "sample alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "ada%20install%20test"
}

@test "the sample alert fires even while alerts are paused" {
  require_native_helper
  "$REPO_ROOT/lib/ada-pause.sh" forever >/dev/null
  run "$INSTALL" --agents terminal
  assert_success
  wait_for_file "$ADA_PROBE_OUT" || { echo "sample alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "ada%20install%20test"
}

@test "--dry-run describes the sample alert instead of firing it" {
  run "$INSTALL" --agents terminal --dry-run
  assert_success
  assert_output_contains "dry-run: would run $REPO_ROOT/lib/ada-show-alert.sh"
  refute_file_appears "$ADA_PROBE_OUT"
}

# Paseo setup is delegated wholesale so LaunchAgent staging lives in one place.
paseo_on_path() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "[]"\n' > "$BATS_TEST_TMPDIR/bin/paseo"
  chmod +x "$BATS_TEST_TMPDIR/bin/paseo"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "--dry-run --agents paseo names the watcher install it would run" {
  paseo_on_path
  run "$INSTALL" --agents paseo --dry-run --no-test
  assert_success
  assert_output_contains "dry-run: would run $REPO_ROOT/ada-paseo-watch.sh install"
}

@test "--agents paseo delegates to ada-paseo-watch.sh install" {
  require_native_helper
  paseo_on_path
  run "$INSTALL" --agents paseo --no-test
  assert_success
  assert_output_contains "Installing Paseo integration -> LaunchAgent"
  [ -f "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" ]
}
