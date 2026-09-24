#!/usr/bin/env bats
# Tests for lib/ada-status.sh — the per-integration report behind
# `ada-setup --status` and the menu bar's Integrations menu.

setup() {
  load test_helper
  setup_common
  STATUS="$REPO_ROOT/lib/ada-status.sh"
  export ADA_OPENCODE_PLUGIN_DIR="$HOME/.config/opencode/plugin"
}

# The row for one integration, fields joined by "|" for easy comparison.
row() {
  "$STATUS" | awk -F'\t' -v id="$1" '$1 == id {print $1 "|" $2 "|" $3 "|" $4}'
}

hook_settings() {  # <file> <UserPromptSubmit command or ""> <Stop command or "">
  python3 - "$@" <<'PY'
import json, sys
path, ups, stop = sys.argv[1:4]
hooks = {}
if ups:
    hooks["UserPromptSubmit"] = [{"hooks": [{"type": "command", "command": ups}]}]
if stop:
    hooks["Stop"] = [{"hooks": [{"type": "command", "command": "/usr/bin/true"}]},
                     {"hooks": [{"type": "command", "command": stop, "async": True}]}]
with open(path, "w") as fh:
    json.dump({"model": "x", "hooks": hooks}, fh)
PY
}

@test "every line has four tab-separated fields and a known state" {
  run "$STATUS"
  assert_success
  [ "${#lines[@]}" -eq 5 ]
  local line
  for line in "${lines[@]}"; do
    assert_equal "$(awk -F'\t' '{print NF}' <<<"$line")" 4
    [[ "$(cut -f2 <<<"$line")" =~ ^(ok|off|warn|unavailable)$ ]] || { echo "bad state: $line"; false; }
  done
}

# --- terminal -------------------------------------------------------------------

@test "terminal: no ~/.zshrc is off" {
  assert_equal "$(row terminal)" "terminal|off|Terminal commands|no ~/.zshrc"
}

@test "terminal: the installer's managed block is ok" {
  printf '# >>> ada >>>\n# Agent Done Alert terminal command alerts\nsource "%s/ada.sh"\n# <<< ada <<<\n' "$REPO_ROOT" > "$HOME/.zshrc"
  assert_equal "$(row terminal)" "terminal|ok|Terminal commands|~/.zshrc sources $REPO_ROOT/ada.sh"
}

@test "terminal: a hand-written source line with ~ or \$HOME counts" {
  mkdir -p "$HOME/.ada"; touch "$HOME/.ada/ada.sh"
  printf 'export FOO=1\nsource ~/.ada/ada.sh\n' > "$HOME/.zshrc"
  assert_equal "$(row terminal)" "terminal|ok|Terminal commands|~/.zshrc sources ~/.ada/ada.sh"
  printf '  . $HOME/.ada/ada.sh\n' > "$HOME/.zshrc"
  assert_equal "$(row terminal)" "terminal|ok|Terminal commands|~/.zshrc sources ~/.ada/ada.sh"
}

@test "terminal: a commented-out source line is off" {
  printf '# source "%s/ada.sh"\n' "$REPO_ROOT" > "$HOME/.zshrc"
  assert_equal "$(row terminal)" "terminal|off|Terminal commands|not in ~/.zshrc"
}

@test "terminal: sourcing a file that is gone is a warning" {
  printf 'source "/nowhere/ada/ada.sh"\n' > "$HOME/.zshrc"
  assert_equal "$(row terminal)" "terminal|warn|Terminal commands|~/.zshrc sources /nowhere/ada/ada.sh, which is missing"
}

# The menu bar runs this from a LaunchAgent, which may not look inside
# ~/Documents; anything under $HOME is reported without being checked.
@test "terminal: with ADA_STATUS_SKIP_PROTECTED a path under HOME is not checked" {
  printf 'source "%s/Documents/ada/ada.sh"\n' "$HOME" > "$HOME/.zshrc"
  ADA_STATUS_SKIP_PROTECTED=1 run row terminal
  assert_equal "$output" "terminal|ok|Terminal commands|~/.zshrc sources ~/Documents/ada/ada.sh (not checked from here)"
  # Outside HOME it is still checked.
  printf 'source "/nowhere/ada/ada.sh"\n' > "$HOME/.zshrc"
  ADA_STATUS_SKIP_PROTECTED=1 run row terminal
  assert_output_contains "which is missing"
}

# --- claude / codex ---------------------------------------------------------------

@test "claude: no ~/.claude at all is unavailable" {
  assert_equal "$(row claude)" "claude|unavailable|Claude Code|~/.claude not found"
}

@test "claude: a ~/.claude without settings is off" {
  mkdir -p "$HOME/.claude"
  assert_equal "$(row claude)" "claude|off|Claude Code|no ~/.claude/settings.json"
}

@test "claude: settings without ada's hooks are off" {
  mkdir -p "$HOME/.claude"
  hook_settings "$HOME/.claude/settings.json" "" ""
  assert_equal "$(row claude)" "claude|off|Claude Code|no ada hooks in ~/.claude/settings.json"
}

@test "claude: both hooks wired is ok" {
  mkdir -p "$HOME/.claude"
  hook_settings "$HOME/.claude/settings.json" "$REPO_ROOT/lib/ada-claude-hook.sh" "$REPO_ROOT/lib/ada-claude-hook.sh"
  assert_equal "$(row claude)" "claude|ok|Claude Code|hooks run $REPO_ROOT/lib/ada-claude-hook.sh"
}

@test "claude: only one of the two hooks is a warning" {
  mkdir -p "$HOME/.claude"
  hook_settings "$HOME/.claude/settings.json" "" "$REPO_ROOT/lib/ada-claude-hook.sh"
  assert_equal "$(row claude)" "claude|warn|Claude Code|only the Stop hook is wired in ~/.claude/settings.json"
}

@test "claude: a hook that points at a deleted checkout is a warning" {
  mkdir -p "$HOME/.claude"
  hook_settings "$HOME/.claude/settings.json" /gone/lib/ada-claude-hook.sh /gone/lib/ada-claude-hook.sh
  assert_equal "$(row claude)" "claude|warn|Claude Code|hooks run /gone/lib/ada-claude-hook.sh, which is missing"
}

@test "claude: the legacy iyf hook still counts as wired" {
  mkdir -p "$HOME/.claude" "$HOME/.iyf"
  touch "$HOME/.iyf/iyf-claude-hook.sh"
  hook_settings "$HOME/.claude/settings.json" "$HOME/.iyf/iyf-claude-hook.sh" "$HOME/.iyf/iyf-claude-hook.sh"
  assert_equal "$(row claude)" "claude|ok|Claude Code|hooks run ~/.iyf/iyf-claude-hook.sh"
}

@test "claude: settings that are not JSON are a warning, not a crash" {
  mkdir -p "$HOME/.claude"
  printf '{ nope' > "$HOME/.claude/settings.json"
  assert_equal "$(row claude)" "claude|warn|Claude Code|~/.claude/settings.json is not valid JSON"
  printf '[1, 2]' > "$HOME/.claude/settings.json"
  assert_equal "$(row claude)" "claude|off|Claude Code|no ada hooks in ~/.claude/settings.json"
}

@test "codex: reads ~/.codex/hooks.json the same way" {
  mkdir -p "$HOME/.codex"
  hook_settings "$HOME/.codex/hooks.json" "$REPO_ROOT/lib/ada-claude-hook.sh" "$REPO_ROOT/lib/ada-claude-hook.sh"
  assert_equal "$(row codex)" "codex|ok|Codex|hooks run $REPO_ROOT/lib/ada-claude-hook.sh"
}

# --- opencode ---------------------------------------------------------------------

@test "opencode: ada's shim is ok and names the plugin it loads" {
  mkdir -p "$ADA_OPENCODE_PLUGIN_DIR"
  printf '// Installed by ada.\nexport * from "%s/lib/ada-opencode-plugin.mjs"\n' "$REPO_ROOT" > "$ADA_OPENCODE_PLUGIN_DIR/ada.js"
  assert_equal "$(row opencode)" "opencode|ok|opencode|plugin loads $REPO_ROOT/lib/ada-opencode-plugin.mjs"
}

@test "opencode: a shim whose plugin is gone is a warning" {
  mkdir -p "$ADA_OPENCODE_PLUGIN_DIR"
  printf 'export * from "/gone/lib/ada-opencode-plugin.mjs"\n' > "$ADA_OPENCODE_PLUGIN_DIR/ada.js"
  assert_equal "$(row opencode)" "opencode|warn|opencode|plugin loads /gone/lib/ada-opencode-plugin.mjs, which is missing"
}

@test "opencode: someone else's ada.js is a warning" {
  mkdir -p "$ADA_OPENCODE_PLUGIN_DIR"
  printf 'export const Mine = async () => ({})\n' > "$ADA_OPENCODE_PLUGIN_DIR/ada.js"
  assert_equal "$(row opencode)" "opencode|warn|opencode|~/.config/opencode/plugin/ada.js is not ada's plugin"
}

@test "opencode: installed without ada's plugin is off" {
  # test/stubs/opencode is on PATH, so the CLI counts as installed.
  assert_equal "$(row opencode)" "opencode|off|opencode|no ada plugin in ~/.config/opencode/plugin"
}

@test "opencode: no CLI and no config dir is unavailable" {
  if [ -x /usr/bin/opencode ] || [ -x /bin/opencode ]; then
    skip "opencode is installed in a system directory"
  fi
  PATH="/usr/bin:/bin" ADA_OPENCODE_FALLBACK_PATHS="" run row opencode
  assert_equal "$output" "opencode|unavailable|opencode|opencode not found"
}

# --- paseo -----------------------------------------------------------------------

paseo_plist() {
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<plist/>\n' > "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist"
}

@test "paseo: no CLI and no watcher is unavailable" {
  [ -x /Applications/Paseo.app/Contents/Resources/bin/paseo ] && skip "Paseo.app is installed here"
  PATH="/usr/bin:/bin:$STUBS" run row paseo
  assert_equal "$output" "paseo|unavailable|Paseo|Paseo not found"
}

@test "paseo: the CLI without the watcher is off" {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/paseo"; chmod +x "$HOME/.local/bin/paseo"
  assert_equal "$(row paseo)" "paseo|off|Paseo|watcher not installed"
}

@test "paseo: a running watcher is ok with its pid" {
  paseo_plist
  STUB_LAUNCHCTL_LOADED=1 STUB_LAUNCHCTL_PID=4242 run row paseo
  assert_equal "$output" "paseo|ok|Paseo|running (pid 4242)"
}

@test "paseo: loaded but not running is a warning" {
  paseo_plist
  STUB_LAUNCHCTL_LOADED=1 run row paseo
  assert_equal "$output" "paseo|warn|Paseo|loaded but not running"
}

@test "paseo: a plist launchd doesn't know about is a warning" {
  paseo_plist
  assert_equal "$(row paseo)" "paseo|warn|Paseo|installed but not loaded"
}

# --- the table ---------------------------------------------------------------------

@test "--table aligns the same rows for people" {
  run "$STATUS" --table
  assert_success
  [ "${#lines[@]}" -eq 5 ]
  assert_output_contains "terminal  Terminal commands  off          no ~/.zshrc"
}

@test "an unknown argument fails with a hint" {
  run "$STATUS" --json
  [ "$status" -eq 2 ]
  assert_output_contains "try --table"
}
