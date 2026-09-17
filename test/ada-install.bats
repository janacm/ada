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
