#!/bin/bash
# =============================================================
# ada-status — which integrations are wired, and whether they work
# -------------------------------------------------------------
# Executed, it reports each integration as one tab-separated line:
#   <id>  <state>  <name>  <detail>
# state is ok, off (not wired), warn (wired, but something is wrong) or
# unavailable (the tool it hooks into isn't on this machine). The menu bar's
# Integrations menu shows these lines; `ada-setup --status` prints them as a
# table. Sourced, it only defines the finders ada-install.sh uses to decide what
# it can install, which is why they live here: the menu bar runs this file from
# a stage, where the installer is deliberately absent.
#
# Each check reads the marker the installer writes: the managed block in
# ~/.zshrc, the hook commands in ~/.claude/settings.json and
# ~/.codex/hooks.json, the opencode plugin shim, and the LaunchAgent plists of
# the Paseo watcher and the menu bar.
#
#   ada-status.sh           the lines
#   ada-status.sh --table   aligned, for people
#
# Environment:
#   ADA_STATUS_SKIP_PROTECTED  1 = don't check that a wired path exists when it
#       is under $HOME or /Volumes. The menu bar sets it: a LaunchAgent may not
#       look inside ~/Documents and the other protected folders, so the check
#       would report a false "missing" or raise a privacy prompt.
#   ADA_OPENCODE_PLUGIN_DIR    opencode's plugin dir (default: ask opencode)
# =============================================================
set -u

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

# ADA_OPENCODE_FALLBACK_PATHS overrides the absolute fallbacks (the test suite
# empties it to observe the no-CLI branch on a machine that has opencode).
find_opencode() {
  local p
  p=$(command -v opencode 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in ${ADA_OPENCODE_FALLBACK_PATHS-"$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode}; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Where opencode scans for global plugins. Ask opencode itself first — it is the
# only authority on its own config root, which moves with XDG_CONFIG_HOME — and
# fall back to the XDG default when the binary isn't there to ask.
# ADA_OPENCODE_PLUGIN_DIR overrides both (used by the test suite, and by the
# menu bar, which asks once and passes the answer back).
# Memoized because the interactive selector calls agent_status for every row on
# every keypress, and asking opencode costs a process spawn. The config root
# cannot change while the installer runs.
# Callers read it via $(...), a subshell, so the memo is filled by
# resolve_opencode_plugin_dir in the parent shell rather than in here.
__ada_opencode_plugin_dir=""
resolve_opencode_plugin_dir() {
  local oc config=""
  if [[ -n "${ADA_OPENCODE_PLUGIN_DIR:-}" ]]; then
    __ada_opencode_plugin_dir=$ADA_OPENCODE_PLUGIN_DIR
    return 0
  fi
  if oc=$(find_opencode); then
    config=$("$oc" debug paths 2>/dev/null | sed -n 's/^config[[:space:]][[:space:]]*//p' | head -1)
  fi
  [[ -n "$config" ]] || config="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  __ada_opencode_plugin_dir="$config/plugin"
}
opencode_plugin_dir() {
  [[ -n "$__ada_opencode_plugin_dir" ]] || resolve_opencode_plugin_dir
  printf '%s' "$__ada_opencode_plugin_dir"
}

# --- the report ----------------------------------------------------------------

# $HOME shown as ~.
__ada_status_tilde() {
  local path=$1
  case "$path" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${path#"$HOME"}" ;;
    *) printf '%s' "$path" ;;
  esac
}

# Whether a path the installer wired still exists: ok, missing, or unverified
# (ADA_STATUS_SKIP_PROTECTED and the path might be in a protected folder).
__ada_status_path() {
  local path=$1
  if [[ "${ADA_STATUS_SKIP_PROTECTED:-}" == 1 ]]; then
    case "$path" in "$HOME"/*|/Volumes/*) printf 'unverified'; return 0 ;; esac
  fi
  if [[ -e "$path" ]]; then printf 'ok'; else printf 'missing'; fi
}

__ada_status_row() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

# A wired path: ok when it exists, warn when it doesn't, ok with a note when it
# can't be checked from here.
__ada_status_wired() {
  local id=$1 name=$2 what=$3 path=$4 shown
  shown=$(__ada_status_tilde "$path")
  case "$(__ada_status_path "$path")" in
    ok) __ada_status_row "$id" ok "$name" "$what $shown" ;;
    unverified) __ada_status_row "$id" ok "$name" "$what $shown (not checked from here)" ;;
    *) __ada_status_row "$id" warn "$name" "$what $shown, which is missing" ;;
  esac
}

__ada_status_terminal() {
  local rc="$HOME/.zshrc" path
  if [[ ! -f "$rc" ]]; then
    __ada_status_row terminal off "Terminal commands" "no ~/.zshrc"
    return 0
  fi
  # The installer's managed block holds `source "<dir>/ada.sh"`; a hand-written
  # `source ~/.ada/ada.sh` or `. $HOME/.ada/ada.sh` counts too. Commented-out
  # lines don't match because of the leading-space anchor.
  path=$(sed -En 's/^[[:space:]]*(source|\.)[[:space:]]+["'"'"']?([^"'"'"']*\/ada\.sh)["'"'"']?[[:space:]]*$/\2/p' "$rc" | tail -n 1)
  if [[ -z "$path" ]]; then
    __ada_status_row terminal off "Terminal commands" "not in ~/.zshrc"
    return 0
  fi
  case "$path" in
    "~/"*) path="$HOME/${path#"~/"}" ;;
    '$HOME/'*) path="$HOME/${path#'$HOME/'}" ;;
    '${HOME}/'*) path="$HOME/${path#'${HOME}/'}" ;;
  esac
  __ada_status_wired terminal "Terminal commands" "~/.zshrc sources" "$path"
}

# Claude Code and Codex share a hook and a settings shape. The python prints
# state, detail and hook path separated by the ASCII unit separator: a tab
# would not do, because read collapses runs of IFS whitespace and an empty
# detail would shift the path into its place. It recognizes ada's hook by the
# same suffixes as is_managed_command in ada-install.sh.
__ada_status_hooks() {
  local id=$1 name=$2 home=$3 settings=$4 python result state detail hook
  if [[ ! -d "$home" && ! -f "$settings" ]]; then
    __ada_status_row "$id" unavailable "$name" "$(__ada_status_tilde "$home") not found"
    return 0
  fi
  if [[ ! -f "$settings" ]]; then
    __ada_status_row "$id" off "$name" "no $(__ada_status_tilde "$settings")"
    return 0
  fi
  if ! python=$(find_python); then
    __ada_status_row "$id" warn "$name" "python3 is needed to read $(__ada_status_tilde "$settings")"
    return 0
  fi
  result=$("$python" - "$settings" "$(__ada_status_tilde "$settings")" <<'PY'
import json, sys

path, shown = sys.argv[1], sys.argv[2]
US = "\x1f"

def report(state, detail="", hook=""):
    print(US.join((state, detail, hook)))

def managed(command):
    return command.endswith("/ada-claude-hook.sh") or command.endswith("/iyf-claude-hook.sh")

try:
    with open(path) as fh:
        text = fh.read()
    data = json.loads(text) if text.strip() else {}
except (OSError, ValueError):
    report("warn", "%s is not valid JSON" % shown)
    sys.exit(0)

hooks = data.get("hooks") if isinstance(data, dict) else None
found = {}
for event in ("UserPromptSubmit", "Stop"):
    groups = hooks.get(event) if isinstance(hooks, dict) else None
    for group in groups if isinstance(groups, list) else []:
        entries = group.get("hooks") if isinstance(group, dict) else None
        for entry in entries if isinstance(entries, list) else []:
            command = entry.get("command") if isinstance(entry, dict) else None
            if isinstance(command, str) and managed(command):
                found[event] = command

if not found:
    report("off", "no ada hooks in %s" % shown)
elif len(found) == 1:
    (event, command), = found.items()
    report("warn", "only the %s hook is wired in %s" % (event, shown), command)
else:
    report("ok", "", found["Stop"])
PY
)
  IFS=$'\x1f' read -r state detail hook <<<"$result"
  case "$state" in
    ok) __ada_status_wired "$id" "$name" "hooks run" "$hook" ;;
    off|warn) __ada_status_row "$id" "$state" "$name" "$detail" ;;
    *) __ada_status_row "$id" warn "$name" "could not read $(__ada_status_tilde "$settings")" ;;
  esac
}

__ada_status_opencode() {
  local dir shim target
  dir=$(opencode_plugin_dir)
  shim="$dir/ada.js"
  if [[ -f "$shim" ]]; then
    if ! grep -q 'ada-opencode-plugin' "$shim" 2>/dev/null; then
      __ada_status_row opencode warn opencode "$(__ada_status_tilde "$shim") is not ada's plugin"
      return 0
    fi
    target=$(sed -n 's/.*from[[:space:]]*"\([^"]*\)".*/\1/p' "$shim" | head -n 1)
    if [[ -n "$target" ]]; then
      __ada_status_wired opencode opencode "plugin loads" "$target"
    else
      __ada_status_row opencode ok opencode "plugin $(__ada_status_tilde "$shim")"
    fi
  elif find_opencode >/dev/null 2>&1 || [[ -d "$(dirname "$dir")" ]]; then
    __ada_status_row opencode off opencode "no ada plugin in $(__ada_status_tilde "$dir")"
  else
    __ada_status_row opencode unavailable opencode "opencode not found"
  fi
}

# A LaunchAgent job: ok while it runs, warn when its plist is there but it
# isn't, off when there is no plist.
__ada_status_job() {
  local id=$1 name=$2 label=$3 off_detail=$4 plist pid=""
  plist="$HOME/Library/LaunchAgents/$label.plist"
  if [[ ! -f "$plist" ]]; then
    __ada_status_row "$id" off "$name" "$off_detail"
    return 0
  fi
  if declare -F __ada_launchd_pid >/dev/null; then
    pid=$(__ada_launchd_pid "$label")
    if [[ -n "$pid" ]]; then
      __ada_status_row "$id" ok "$name" "running (pid $pid)"
    elif __ada_launchd_loaded "$label"; then
      __ada_status_row "$id" warn "$name" "loaded but not running"
    else
      __ada_status_row "$id" warn "$name" "installed but not loaded"
    fi
  else
    __ada_status_row "$id" ok "$name" "installed"
  fi
}

__ada_status_paseo() {
  if [[ ! -f "$HOME/Library/LaunchAgents/com.ada.paseo-watch.plist" ]] && ! find_paseo >/dev/null 2>&1; then
    __ada_status_row paseo unavailable Paseo "Paseo not found"
    return 0
  fi
  __ada_status_job paseo Paseo com.ada.paseo-watch "watcher not installed"
}

__ada_status_all() {
  __ada_status_terminal
  __ada_status_hooks claude "Claude Code" "$HOME/.claude" "$HOME/.claude/settings.json"
  __ada_status_hooks codex Codex "$HOME/.codex" "$HOME/.codex/hooks.json"
  __ada_status_opencode
  __ada_status_paseo
  __ada_status_job menubar "Menu bar" com.ada.menubar "not a login item"
}

__ada_status_cli() {
  local selfdir id state name detail
  selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # The launchd queries; without them a job reports only whether it is installed.
  # shellcheck source=lib/ada-stage.sh
  [[ -f "$selfdir/ada-stage.sh" ]] && . "$selfdir/ada-stage.sh"
  case "${1:-}" in
    "")
      __ada_status_all
      ;;
    --table)
      while IFS=$'\t' read -r id state name detail; do
        printf '%-9s %-18s %-12s %s\n' "$id" "$name" "$state" "$detail"
      done < <(__ada_status_all)
      ;;
    -h|--help|help)
      sed -n '18,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "ada-status: unknown argument: $1 (try --table)" >&2
      return 2
      ;;
  esac
}

# Executed directly -> the report. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_status_cli "$@"
fi
