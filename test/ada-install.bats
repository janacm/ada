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
