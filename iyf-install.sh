#!/bin/bash
# =============================================================
# iyf-install — onboarding installer for In Your Face integrations
# -------------------------------------------------------------
# Interactive by default: pick the local surfaces that should trigger IYF.
# Scriptable for docs/Homebrew/curl flows:
#
#   ./iyf-install.sh --agents terminal,claude,codex
#   ./iyf-install.sh --agents all --no-test
#   ./iyf-install.sh --dry-run
# =============================================================
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

AGENT_IDS=(terminal claude codex paseo)
AGENT_NAMES=("Terminal commands" "Claude Code" "Codex" "Paseo")
AGENT_TARGETS=("~/.zshrc" "~/.claude/settings.json" "~/.codex/hooks.json" "LaunchAgent watcher")

dry_run=0
run_test=1
explicit_agents=""

usage() {
  cat <<'USAGE'
Usage:
  iyf-install.sh                         # interactive selector
  iyf-install.sh --agents LIST           # comma/space-separated ids
  iyf-install.sh --agents all            # install every available integration
  iyf-install.sh --dry-run               # print actions without writing
  iyf-install.sh --no-test               # skip final sample alert
  iyf-install.sh --list                  # show known integrations

Integration ids:
  terminal   zsh long-command alerts
  claude     Claude Code UserPromptSubmit/Stop hooks
  codex      Codex UserPromptSubmit/Stop hooks
  paseo      Paseo LaunchAgent watcher
USAGE
}

say() { printf '%s\n' "$*"; }
die() { printf 'iyf-install: %s\n' "$*" >&2; exit 1; }

find_python() {
  local p
  p=$(command -v python3 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

find_paseo() {
  local p
  p=$(command -v paseo 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in "$HOME/.local/bin/paseo" \
           "/Applications/Paseo.app/Contents/Resources/bin/paseo"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

find_swift() {
  local p
  p=$(command -v swift 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in /usr/bin/swift /opt/homebrew/bin/swift /usr/local/bin/swift; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

find_native_alert() {
  local p
  for p in "$dir/iyf-alert" \
           "$dir/.build/release/iyf-alert" \
           "$dir/.build/debug/iyf-alert"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

ensure_native_alert() {
  local helper swift_bin
  if helper=$(find_native_alert); then
    say "Native alert helper -> $helper"
    return 0
  fi

  [[ -f "$dir/Package.swift" ]] || die "missing Package.swift; cannot build native iyf-alert"

  if [[ "$dry_run" == 1 ]]; then
    say "dry-run: would run swift build -c release --product iyf-alert"
    return 0
  fi

  swift_bin=$(find_swift) || die "swift is required to build native iyf-alert"
  say "Building native alert helper -> $dir/.build/release/iyf-alert"
  (cd "$dir" && "$swift_bin" build -c release --product iyf-alert) ||
    die "failed to build native iyf-alert"

  helper=$(find_native_alert) || die "native helper build did not produce an executable iyf-alert"
  say "Native alert helper -> $helper"
}

agent_index() {
  local id=$1 i
  for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
    [[ "${AGENT_IDS[$i]}" == "$id" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

agent_available() {
  case "$1" in
    terminal) [[ -n "${ZSH_VERSION:-}" || -x /bin/zsh || -x /usr/bin/zsh ]] ;;
    claude) [[ -d "$HOME/.claude" || -f "$HOME/.claude/settings.json" ]] ;;
    codex) [[ -d "$HOME/.codex" || -f "$HOME/.codex/hooks.json" ]] ;;
    paseo) find_paseo >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

agent_default_selected() {
  case "$1" in
    terminal) return 0 ;;
    claude|codex|paseo) agent_available "$1" ;;
    *) return 1 ;;
  esac
}

agent_status() {
  case "$1" in
    terminal)
      [[ -f "$HOME/.zshrc" ]] && printf 'detected' || printf 'will create ~/.zshrc'
      ;;
    claude)
      [[ -f "$HOME/.claude/settings.json" ]] && printf 'detected' || printf 'will create settings'
      ;;
    codex)
      [[ -f "$HOME/.codex/hooks.json" ]] && printf 'detected' || printf 'will create hooks.json'
      ;;
    paseo)
      if find_paseo >/dev/null 2>&1; then printf 'detected'; else printf 'not found'; fi
      ;;
  esac
}

print_list() {
  local i id
  for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
    id=${AGENT_IDS[$i]}
    printf '%-9s %-26s %-24s %s\n' "$id" "${AGENT_NAMES[$i]}" "${AGENT_TARGETS[$i]}" "$(agent_status "$id")"
  done
}

parse_agent_list() {
  local raw=$1 part idx
  selected=(0 0 0 0)
  raw=${raw//,/ }
  if [[ "$raw" == "all" ]]; then
    for (( idx=0; idx<${#AGENT_IDS[@]}; idx++ )); do
      agent_available "${AGENT_IDS[$idx]}" && selected[$idx]=1
    done
    return 0
  fi
  for part in $raw; do
    idx=$(agent_index "$part") || die "unknown integration '$part' (try --list)"
    agent_available "$part" || die "'$part' is not available on this machine"
    selected[$idx]=1
  done
}

render_selector() {
  local cursor=$1 i id marker pointer availability
  printf '\033[H\033[J'
  say "iyf"
  say
  say "Source: $dir"
  say "Found ${#AGENT_IDS[@]} integrations"
  say "Which integrations do you want to install?"
  say
  say "-- Core alert runtime -- always included"
  say "   iyf-alert, iyf-show-alert.sh, alert.html, snooze helper"
  say
  say "-- Integrations --"
  for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
    id=${AGENT_IDS[$i]}
    pointer=" "
    [[ "$i" == "$cursor" ]] && pointer=">"
    if ! agent_available "$id"; then
      marker="[-]"
      availability="unavailable: $(agent_status "$id")"
    elif [[ "${selected[$i]}" == 1 ]]; then
      marker="[x]"
      availability="$(agent_status "$id")"
    else
      marker="[ ]"
      availability="$(agent_status "$id")"
    fi
    printf ' %s %s %-22s %-22s %s\n' "$pointer" "$marker" "${AGENT_NAMES[$i]}" "(${AGENT_TARGETS[$i]})" "$availability"
  done
  say
  printf 'Selected: '
  local first=1 count=0
  for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
    if [[ "${selected[$i]}" == 1 ]]; then
      (( count++ ))
      [[ "$first" == 0 ]] && printf ', '
      printf '%s' "${AGENT_NAMES[$i]}"
      first=0
    fi
  done
  [[ "$count" == 0 ]] && printf '(none)'
  say
  say
  say "up/down or j/k move, space select, a toggle all, enter confirm, q cancel"
}

interactive_select() {
  [[ -t 0 && -t 1 ]] || die "not running in a terminal; use --agents LIST"

  selected=(0 0 0 0)
  local i
  for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
    agent_default_selected "${AGENT_IDS[$i]}" && selected[$i]=1
  done

  local cursor=0 key rest
  while ! agent_available "${AGENT_IDS[$cursor]}"; do
    (( cursor++ ))
    (( cursor >= ${#AGENT_IDS[@]} )) && break
  done

  printf '\033[?25l'
  trap 'printf "\033[?25h"; stty sane 2>/dev/null || true' EXIT INT TERM
  while true; do
    render_selector "$cursor"
    IFS= read -rsn1 key || true
    case "$key" in
      $'\x1b')
        IFS= read -rsn2 -t 0.05 rest || true
        case "$rest" in
          "[A") key="up" ;;
          "[B") key="down" ;;
        esac
        ;;
      "") break ;;
    esac
    case "$key" in
      up|k)
        while true; do
          (( cursor-- ))
          (( cursor < 0 )) && cursor=$((${#AGENT_IDS[@]} - 1))
          agent_available "${AGENT_IDS[$cursor]}" && break
        done
        ;;
      down|j)
        while true; do
          (( cursor++ ))
          (( cursor >= ${#AGENT_IDS[@]} )) && cursor=0
          agent_available "${AGENT_IDS[$cursor]}" && break
        done
        ;;
      " ")
        if agent_available "${AGENT_IDS[$cursor]}"; then
          if [[ "${selected[$cursor]}" == 1 ]]; then selected[$cursor]=0; else selected[$cursor]=1; fi
        fi
        ;;
      a)
        local any_unselected=0
        for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
          agent_available "${AGENT_IDS[$i]}" && [[ "${selected[$i]}" == 0 ]] && any_unselected=1
        done
        for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
          agent_available "${AGENT_IDS[$i]}" && selected[$i]=$any_unselected
        done
        ;;
      q)
        printf '\033[?25h'
        trap - EXIT INT TERM
        say
        die "cancelled"
        ;;
    esac
  done
  printf '\033[?25h'
  trap - EXIT INT TERM
  say
}

install_terminal() {
  local zshrc="$HOME/.zshrc"
  local source_line="source \"$dir/iyf.sh\""
  say "Installing terminal integration -> $zshrc"
  if [[ "$dry_run" == 1 ]]; then
    say "dry-run: would add managed iyf block sourcing $dir/iyf.sh"
    return 0
  fi
  mkdir -p "$(dirname "$zshrc")"
  touch "$zshrc"
  local python
  python=$(find_python) || die "python3 is required to update $zshrc safely"
  "$python" - "$zshrc" "$source_line" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source_line = sys.argv[2]
start = "# >>> iyf >>>"
end = "# <<< iyf <<<"
block = f"{start}\n# In Your Face terminal command alerts\n{source_line}\n{end}\n"
text = path.read_text() if path.exists() else ""
if start in text and end in text:
    before, rest = text.split(start, 1)
    _, after = rest.split(end, 1)
    text = before.rstrip() + "\n\n" + block + after.lstrip("\n")
elif source_line in text:
    pass
else:
    text = text.rstrip() + "\n\n" + block
path.write_text(text)
PY
}

install_hook_json() {
  local label=$1 settings=$2 stop_async=$3
  local python
  python=$(find_python) || die "python3 is required for $label hook installation"
  local hook="$dir/iyf-claude-hook.sh"
  say "Installing $label integration -> $settings"
  if [[ "$dry_run" == 1 ]]; then
    say "dry-run: would merge UserPromptSubmit and Stop hooks for $hook"
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  "$python" - "$settings" "$hook" "$stop_async" <<'PY'
import json, pathlib, shutil, sys, time

settings = pathlib.Path(sys.argv[1])
hook = sys.argv[2]
stop_async = sys.argv[3] == "1"

if settings.exists() and settings.read_text().strip():
    data = json.loads(settings.read_text())
else:
    data = {}

backup = settings.with_name(settings.name + ".bak.iyf-" + time.strftime("%Y%m%d-%H%M%S"))
if settings.exists():
    shutil.copy2(settings, backup)

hooks_root = data.setdefault("hooks", {})

def has_iyf_command(group):
    for hook_obj in group.get("hooks", []):
        command = hook_obj.get("command", "")
        if command == hook or command.endswith("/iyf-claude-hook.sh"):
            return True
    return False

def make_group(event):
    command = {"type": "command", "command": hook, "timeout": 10}
    if event == "Stop" and stop_async:
        command["async"] = True
    return {"hooks": [command]}

for event in ("UserPromptSubmit", "Stop"):
    groups = hooks_root.setdefault(event, [])
    if not isinstance(groups, list):
        raise SystemExit(f"hooks.{event} must be a list")
    groups[:] = [group for group in groups if not has_iyf_command(group)]
    groups.append(make_group(event))

settings.write_text(json.dumps(data, indent=2) + "\n")
print(f"  backup: {backup}" if backup.exists() else "  created new settings file")
PY
}

install_claude() {
  install_hook_json "Claude Code" "$HOME/.claude/settings.json" 1
}

install_codex() {
  install_hook_json "Codex" "$HOME/.codex/hooks.json" 0
}

install_paseo() {
  find_paseo >/dev/null 2>&1 || die "Paseo CLI/app not found"
  say "Installing Paseo integration -> LaunchAgent"
  if [[ "$dry_run" == 1 ]]; then
    say "dry-run: would run $dir/iyf-paseo-watch.sh install"
    return 0
  fi
  "$dir/iyf-paseo-watch.sh" install
}

run_test_alert() {
  [[ "$run_test" == 1 ]] || return 0
  say "Firing a sample alert"
  if [[ "$dry_run" == 1 ]]; then
    say "dry-run: would run $dir/iyf-show-alert.sh \"iyf install test\" \"1s\" 0"
    return 0
  fi
  IYF_AUTO_CLOSE="${IYF_AUTO_CLOSE:-20}" "$dir/iyf-show-alert.sh" "iyf install test" "1s" 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents)
      shift
      [[ $# -gt 0 ]] || die "--agents requires a value"
      explicit_agents=$1
      ;;
    --agents=*)
      explicit_agents=${1#--agents=}
      ;;
    --all)
      explicit_agents=all
      ;;
    --dry-run)
      dry_run=1
      ;;
    --no-test)
      run_test=0
      ;;
    --list)
      print_list
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument '$1' (try --help)"
      ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "iyf currently supports macOS only"
[[ -x "$dir/iyf-show-alert.sh" ]] || die "missing executable $dir/iyf-show-alert.sh"
[[ -x "$dir/iyf-claude-hook.sh" ]] || die "missing executable $dir/iyf-claude-hook.sh"

if [[ -n "$explicit_agents" ]]; then
  parse_agent_list "$explicit_agents"
else
  interactive_select
fi

selected_count=0
for (( i=0; i<${#selected[@]}; i++ )); do
  [[ "${selected[$i]}" == 1 ]] && (( selected_count++ ))
done
(( selected_count > 0 )) || die "no integrations selected"

ensure_native_alert

for (( i=0; i<${#AGENT_IDS[@]}; i++ )); do
  [[ "${selected[$i]}" == 1 ]] || continue
  case "${AGENT_IDS[$i]}" in
    terminal) install_terminal ;;
    claude) install_claude ;;
    codex) install_codex ;;
    paseo) install_paseo ;;
  esac
done

run_test_alert

say
say "Done."
say "Open a new shell or run: source ~/.zshrc"
say "Re-run this installer any time to change selected integrations."
