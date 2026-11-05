#!/usr/bin/env bats
# Tests for lib/ada-sources.sh — the switches that decide which agents,
# harnesses and projects may raise an alert — and for the launcher and the
# integrations that apply them.

setup() {
  load test_helper
  setup_common
  SOURCES="$REPO_ROOT/lib/ada-sources.sh"
  LAUNCHER="$REPO_ROOT/lib/ada-show-alert.sh"
  RULES="$HOME/.config/ada/sources"
  HISTORY="$TMPDIR/ada-history.tsv"
  export ADA_PROBE_SOURCE_OUT="$BATS_TEST_TMPDIR/probe-source.txt"
}

# The rule lines of the rules file, without the header comments.
rules() { grep -v '^#' "$RULES" | grep -v '^$' || true; }

# --- the CLI ----------------------------------------------------------------------

@test "with no rules file every source is on except headless Claude runs" {
  run "$SOURCES" list
  assert_success
  assert_output_contains "(none yet)"
  assert_output_contains "on   terminal"
  assert_output_contains "on   claude               Claude Code, any surface"
  assert_output_contains "on   claude/desktop"
  assert_output_contains "off  claude/headless      claude -p and Agent SDK runs (default)"
  assert_output_contains "on   paseo"
  assert_output_contains "every project, except any turned off below"
  [ ! -e "$RULES" ]
}

@test "off writes a rule under a header and the source checks off" {
  run "$SOURCES" off paseo
  assert_success
  assert_equal "$output" "source paseo: off"
  assert_equal "$(rules)" "off source paseo"
  grep -q '^# ada alert switches' "$RULES"
  assert_equal "$(stat -f %Lp "$RULES")" 644
  run "$SOURCES" check paseo/codex
  assert_failure
  assert_equal "$output" off
  run "$SOURCES" check terminal
  assert_success
}

@test "the most specific rule wins" {
  "$SOURCES" off paseo
  "$SOURCES" on paseo/claude
  run "$SOURCES" check paseo/claude
  assert_success
  run "$SOURCES" check paseo/codex
  assert_failure
  run "$SOURCES" check paseo
  assert_failure
  run "$SOURCES" list
  assert_output_contains "off  paseo                Paseo agents (set)"
  assert_output_contains "on   paseo/claude         Paseo claude agents (set)"
}

@test "setting a source drops the rules for the sources under it" {
  "$SOURCES" on paseo/claude
  "$SOURCES" off paseo/codex
  "$SOURCES" off claude/cli
  run "$SOURCES" off paseo
  assert_success
  assert_equal "$(rules)" "off source claude/cli
off source paseo"
  run "$SOURCES" check paseo/claude
  assert_failure
}

@test "the headless default stays off under a broader rule and yields to its own" {
  "$SOURCES" on claude
  run "$SOURCES" check claude/headless
  assert_failure
  "$SOURCES" on "*"
  run "$SOURCES" check claude/headless
  assert_failure
  run "$SOURCES" on claude/headless
  assert_equal "$output" "source claude/headless: on"
  run "$SOURCES" check claude/headless
  assert_success
  run "$SOURCES" unset claude/headless
  assert_equal "$output" "source claude/headless: off"
}

@test "turning Claude off silences every Claude source, headless included" {
  "$SOURCES" off claude
  for s in claude claude/desktop claude/cli claude/ide claude/headless; do
    run "$SOURCES" check "$s"
    assert_failure
  done
  run "$SOURCES" list
  assert_output_contains "off  claude               Claude Code, any surface (set)"
  assert_output_contains "off  claude/desktop       Claude desktop app (from claude)"
  assert_output_contains "off  claude/headless      claude -p and Agent SDK runs (default)"
}

@test "off * makes every source opt-in" {
  "$SOURCES" off "*"
  "$SOURCES" on claude/desktop
  run "$SOURCES" check terminal
  assert_failure
  run "$SOURCES" check paseo/claude
  assert_failure
  run "$SOURCES" check claude/desktop
  assert_success
  # A rule for * is not a parent of every rule: it leaves them alone.
  assert_equal "$(rules)" "off source *
on source claude/desktop"
}

@test "project rules: one project off, then only some projects on" {
  "$SOURCES" off repo sandbox
  run "$SOURCES" check terminal sandbox
  assert_failure
  run "$SOURCES" check terminal ada
  assert_success
  run "$SOURCES" check terminal ""
  assert_success
  run "$SOURCES" only repo ada "My Project"
  assert_success
  assert_equal "$(rules)" "off repo *
on repo ada
on repo My Project"
  run "$SOURCES" check claude/cli "My Project"
  assert_success
  run "$SOURCES" check claude/cli ada
  assert_success
  run "$SOURCES" check claude/cli sandbox
  assert_failure
  # Outside any repo counts as `repo *`; no project at all judges the source.
  run "$SOURCES" check claude/cli ""
  assert_failure
  run "$SOURCES" check claude/cli
  assert_success
  run "$SOURCES" list
  assert_output_contains "only the projects turned on below"
  assert_output_contains "on   My Project"
}

@test "a project must be on and so must its source" {
  "$SOURCES" only repo ada
  "$SOURCES" off codex
  run "$SOURCES" check codex ada
  assert_failure
  run "$SOURCES" check opencode ada
  assert_success
}

@test "a bad source name is refused and the file is left alone" {
  "$SOURCES" off paseo
  local before; before=$(cat "$RULES")
  run "$SOURCES" off "bad name"
  assert_failure
  assert_output_contains "not a source"
  run "$SOURCES" on "paseo//x"
  assert_failure
  assert_equal "$(cat "$RULES")" "$before"
}

@test "a source no integration sends is kept, with a note" {
  run "$SOURCES" off cluade
  assert_success
  assert_output_contains 'no integration sends "cluade"'
  assert_equal "$(rules)" "off source cluade"
  run "$SOURCES" off paseo/newprovider
  refute_output_contains "no integration"
}

@test "hand edits survive: comments, unknown lines, CRLF, and the last duplicate wins" {
  mkdir -p "$(dirname "$RULES")"
  printf '# mine\n  off   source   codex  \r\nnonsense here\non source codex\noff source codex\n' > "$RULES"
  run "$SOURCES" check codex
  assert_failure
  "$SOURCES" off opencode
  grep -qx '# mine' "$RULES"
  grep -qx 'nonsense here' "$RULES"
  run "$SOURCES" check codex
  assert_failure
  run "$SOURCES" on codex
  assert_equal "$(rules)" "nonsense here
off source opencode
on source codex"
}

@test "a symlinked rules file is written through, and stays a link" {
  mkdir -p "$BATS_TEST_TMPDIR/dotfiles" "$(dirname "$RULES")"
  : > "$BATS_TEST_TMPDIR/dotfiles/ada-sources"
  ln -s "$BATS_TEST_TMPDIR/dotfiles/ada-sources" "$RULES"
  "$SOURCES" off paseo
  [ -L "$RULES" ]
  grep -qx 'off source paseo' "$BATS_TEST_TMPDIR/dotfiles/ada-sources"
}

@test "reset forgets every rule and keeps the comments" {
  "$SOURCES" off paseo
  "$SOURCES" only repo ada
  run "$SOURCES" reset
  assert_success
  assert_equal "$(rules)" ""
  grep -q '^# ada alert switches' "$RULES"
  run "$SOURCES" check paseo
  assert_success
}

@test "list adds the Paseo providers seen in the history" {
  printf '1\t1\tshown\t0\tk\tagent\tl\t1s\t0\tr\t\t\t\t/d\tpaseo/cursor\n' > "$HISTORY"
  printf '1\t1\tshown\t0\tk\tagent\tl\t1s\t0\tr\t\t\t\t/d\n' >> "$HISTORY"
  printf '1\t1\tshown\t0\tk\tagent\tl\t1s\t0\tr\t\t\t\t/d\tbad key!\n' >> "$HISTORY"
  run "$SOURCES" list
  assert_output_contains "on   paseo/cursor         Paseo cursor agents"
  refute_output_contains "bad key"
}

@test "ADA_SOURCES_FILE moves the rules, and path and init name it" {
  export ADA_SOURCES_FILE="$BATS_TEST_TMPDIR/elsewhere/rules"
  run "$SOURCES" path
  assert_equal "$output" "$ADA_SOURCES_FILE"
  run "$SOURCES" init
  assert_equal "$output" "$ADA_SOURCES_FILE"
  grep -q '^# ada alert switches' "$ADA_SOURCES_FILE"
  "$SOURCES" off codex
  grep -qx 'off source codex' "$ADA_SOURCES_FILE"
  [ ! -e "$RULES" ]
}

@test "a directory where the rules file should be is refused" {
  mkdir -p "$RULES"
  run "$SOURCES" off codex
  assert_failure
  assert_output_contains "is not a file"
}

# --- the launcher applies them ----------------------------------------------------

@test "a switched-off source shows nothing and leaves no history line" {
  "$SOURCES" off codex
  ADA_SOURCE=codex run "$LAUNCHER" "x" "1s" 0
  assert_success
  refute_file_appears "$ADA_PROBE_OUT"
  [ ! -e "$HISTORY" ]
}

@test "a source that is on shows, and the history records it" {
  "$SOURCES" off codex
  ADA_SOURCE=paseo/claude run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_equal "$(tail -n 1 "$HISTORY" | cut -f15)" paseo/claude
}

@test "an alert without ADA_SOURCE ignores the switches" {
  "$SOURCES" off "*"
  run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
}

@test "an alert you asked for ignores the switches" {
  "$SOURCES" off terminal
  ADA_SOURCE=terminal ADA_IGNORE_PAUSE=1 run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "test alert was dropped"; false; }
}

@test "a project rule drops an alert by the ADA_REPO it was given" {
  "$SOURCES" off repo noisy
  ADA_SOURCE=paseo/codex ADA_REPO=noisy run "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
  ADA_SOURCE=paseo/codex ADA_REPO=quiet run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
}

@test "a project rule resolves the repo with git, and the badge reuses it" {
  local repo="$BATS_TEST_TMPDIR/work/ada"
  mkdir -p "$repo/sub" && git -C "$repo" init -q
  "$SOURCES" only repo ada
  ADA_SOURCE=claude/cli ADA_REPO_DIR="$repo/sub" run "$LAUNCHER" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "alert never fired"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "repo=ada"
  assert_equal "$(cat "$ADA_PROBE_SOURCE_OUT")" "claude/cli|ada"
  rm -f "$ADA_PROBE_OUT"
  ADA_SOURCE=claude/cli ADA_REPO_DIR="$BATS_TEST_TMPDIR" run "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
}

# Resolving the repo is what the launcher saves for alerts it drops; source
# rules alone must not make it run git.
@test "without project rules a dropped alert never runs git" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\necho called >> "%s"\nexit 1\n' "$BATS_TEST_TMPDIR/git-calls" > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  "$SOURCES" off codex
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" ADA_SOURCE=codex run "$LAUNCHER" "x" "1s" 0
  refute_file_appears "$ADA_PROBE_OUT"
  [ ! -e "$BATS_TEST_TMPDIR/git-calls" ]
}

@test "a launcher copied without ada-sources.sh still alerts" {
  local root="$BATS_TEST_TMPDIR/old"
  mkdir -p "$root/lib"
  cp "$REPO_ROOT/lib/ada-show-alert.sh" "$root/lib/"
  "$SOURCES" off "*"
  ADA_SOURCE=codex run "$root/lib/ada-show-alert.sh" "x" "1s" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "helper was never launched"; false; }
}

# The pause timer inherits the environment of the alert whose Pause was
# pressed, ADA_SOURCE included; that source being off must not cost the summary.
@test "a pause summary ignores the source it inherited" {
  "$SOURCES" off codex
  held_record "held one" 1s 0
  ADA_SOURCE=codex ADA_PAUSE_FLUSH=resumed run "$LAUNCHER" "" "" 0
  wait_for_file "$ADA_PROBE_OUT" || { echo "summary never opened"; false; }
  assert_file_contains "$ADA_PROBE_OUT" "mode=summary"
}

# --- the integrations name their source ----------------------------------------------

claude_stop() {
  local sid=$1 payload=$2
  mkdir -p "$TMPDIR/ada-claude"
  printf '%s' "$(( $(/bin/date +%s) - 120 ))" > "$TMPDIR/ada-claude/$sid.start"
  printf '%s' "long turn" > "$TMPDIR/ada-claude/$sid.prompt"
  printf '%s' "$payload" | ADA_SKIP_OWN_TERMINAL=0 "$REPO_ROOT/lib/ada-claude-hook.sh"
}

@test "the Claude hook names Claude Code by where it runs" {
  local entry want
  for pair in "cli claude/cli" "claude-desktop claude/desktop" "local-agent claude/desktop" \
              "claude-vscode claude/ide" "mcp claude" ":unset claude"; do
    entry=${pair%% *}; want=${pair#* }
    rm -f "$ADA_PROBE_SOURCE_OUT"
    if [[ "$entry" == :unset ]]; then unset CLAUDE_CODE_ENTRYPOINT; else export CLAUDE_CODE_ENTRYPOINT=$entry; fi
    claude_stop "s-$entry" '{"hook_event_name":"Stop","session_id":"s-'"$entry"'","cwd":"/tmp"}'
    wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "no alert for $entry"; false; }
    assert_equal "$(cut -d'|' -f1 "$ADA_PROBE_SOURCE_OUT")" "$want"
  done
}

@test "a claude -p turn is quiet by default and alerts once headless is on" {
  export CLAUDE_CODE_ENTRYPOINT=sdk-cli
  claude_stop s-p '{"hook_event_name":"Stop","session_id":"s-p","cwd":"/tmp"}'
  refute_file_appears "$ADA_PROBE_OUT"
  "$SOURCES" on claude/headless
  claude_stop s-p '{"hook_event_name":"Stop","session_id":"s-p","cwd":"/tmp"}'
  wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "headless turn never alerted"; false; }
  assert_equal "$(cut -d'|' -f1 "$ADA_PROBE_SOURCE_OUT")" claude/headless
}

@test "the hook names Codex by its turn_id, whatever the entrypoint says" {
  export CLAUDE_CODE_ENTRYPOINT=claude-desktop
  claude_stop cx1 '{"hook_event_name":"Stop","session_id":"cx1","cwd":"/tmp","turn_id":"t1","model":"gpt"}'
  wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "no alert"; false; }
  assert_equal "$(cut -d'|' -f1 "$ADA_PROBE_SOURCE_OUT")" codex
  rm -f "$ADA_PROBE_SOURCE_OUT"
  claude_stop cx2 '{"hook_event_name":"Stop","session_id":"cx2","cwd":"/tmp","transcript_path":"/Users/x/.codex/sessions/r.jsonl"}'
  wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "no alert"; false; }
  assert_equal "$(cut -d'|' -f1 "$ADA_PROBE_SOURCE_OUT")" codex
}

@test "switching Codex off silences it and leaves Claude Code alone" {
  "$SOURCES" off codex
  export CLAUDE_CODE_ENTRYPOINT=cli
  claude_stop cx3 '{"hook_event_name":"Stop","session_id":"cx3","cwd":"/tmp","turn_id":"t1"}'
  refute_file_appears "$ADA_PROBE_OUT"
  claude_stop cl3 '{"hook_event_name":"Stop","session_id":"cl3","cwd":"/tmp"}'
  wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "Claude turn never alerted"; false; }
}

@test "the opencode plugin names opencode" {
  command -v node >/dev/null 2>&1 || skip "node is required to drive the opencode plugin"
  export ADA_SKIP_OWN_TERMINAL=0 ADA_SKIP_WHEN_ACTIVE=""
  run bash -c "printf '%s' '{\"steps\":[{\"type\":\"chat.message\",\"sessionID\":\"s1\",\"text\":\"t\",\"ageSeconds\":120},{\"type\":\"event\",\"event\":{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"s1\"}}}]}' | node '$BATS_TEST_DIRNAME/opencode_plugin_drive.mjs'"
  wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "alert never fired"; false; }
  assert_equal "$(cut -d'|' -f1 "$ADA_PROBE_SOURCE_OUT")" opencode
}

@test "the zsh hook names the terminal, and its test alert ignores the switch" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  zsh -c "source '$REPO_ROOT/ada.sh' >/dev/null 2>&1; __ada_show_alert 'make' 20 0"
  wait_for_file "$ADA_PROBE_SOURCE_OUT" || { echo "alert never fired"; false; }
  assert_equal "$(cut -d'|' -f1 "$ADA_PROBE_SOURCE_OUT")" terminal
  rm -f "$ADA_PROBE_OUT"
  "$SOURCES" off terminal
  zsh -c "source '$REPO_ROOT/ada.sh' >/dev/null 2>&1; __ada_show_alert 'make' 20 0"
  refute_file_appears "$ADA_PROBE_OUT"
  zsh -c "source '$REPO_ROOT/ada.sh' >/dev/null 2>&1; ada hello"
  wait_for_file "$ADA_PROBE_OUT" || { echo "the ada test alert was dropped"; false; }
}
