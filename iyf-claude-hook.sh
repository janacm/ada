#!/bin/bash
# =============================================================
# iyf-claude-hook — In Your Face for Claude Code
# -------------------------------------------------------------
# Pops the same maximized-window alert as iyf.sh, but when a long
# Claude Code *turn* finishes instead of a shell command.
#
# One script, wired to two Claude Code hooks. It reads the hook
# payload as JSON on stdin and dispatches on hook_event_name:
#
#   UserPromptSubmit -> stamp a start time + the prompt text,
#                       keyed by session id.
#   Stop             -> if the turn ran longer than
#                       IYF_CLAUDE_THRESHOLD seconds AND you're
#                       not already looking at the terminal that
#                       hosts Claude, fire the alert showing the
#                       prompt and how long it took.
#
# Environment knobs (shared with iyf.sh where noted):
#   IYF_CLAUDE_THRESHOLD  min turn seconds to alert   (default 45)
#   IYF_ALERT_FILE        alert.html path             (default ~/.iyf/alert.html)
#   IYF_AUTO_CLOSE        auto-dismiss seconds        (default 90)
#   IYF_SKIP_OWN_TERMINAL silence when terminal is frontmost (default 1)
#   IYF_SKIP_WHEN_ACTIVE  extra frontmost apps to stay silent for
# =============================================================
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
state_dir="${TMPDIR:-/tmp}/iyf-claude"
threshold=${IYF_CLAUDE_THRESHOLD:-45}

# Pull the fields we need in one python pass (tab-delimited, newline-stripped).
payload=$(cat)
fields=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ev  = d.get("hook_event_name", "") or ""
sid = d.get("session_id", "") or ""
cwd = (d.get("cwd", "") or "").replace("\n", " ").replace("\t", " ").strip()
pr  = (d.get("prompt", "") or "").replace("\n", " ").replace("\t", " ").strip()
# prompt stays LAST: read -r gives the final field every remaining tab, so only
# a trailing free-text field is safe there.
print(ev + "\t" + sid + "\t" + cwd + "\t" + pr)
' 2>/dev/null)
[[ -z "$fields" ]] && exit 0

IFS=$'\t' read -r event session_id cwd prompt <<<"$fields"
[[ -z "$session_id" ]] && exit 0

__iyf_format_duration() {
  local s=$1
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm %ds' $(( s / 60 )) $(( s % 60 ))
  else                      printf '%dh %dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); fi
}

# Mirror of iyf.sh __iyf_should_skip_active, in bash: true (0) when the
# frontmost app means you're already watching, so the alert would be noise.
__iyf_should_skip_active() {
  local skip_own=${IYF_SKIP_OWN_TERMINAL:-1}
  local active_list=${IYF_SKIP_WHEN_ACTIVE:-}
  [[ "$skip_own" != 1 && -z "${active_list// /}" ]] && return 1

  local front bid name raw
  front=$(lsappinfo front 2>/dev/null) || return 1
  [[ -z "$front" ]] && return 1
  raw=$(lsappinfo info -only bundleid "$front" 2>/dev/null); bid=${raw##*=\"}; bid=${bid%\"}
  raw=$(lsappinfo info -only name "$front" 2>/dev/null);     name=${raw##*=\"}; name=${name%\"}

  if [[ "$skip_own" == 1 && -n "${__CFBundleIdentifier:-}" && "$bid" == "${__CFBundleIdentifier:-}" ]]; then
    return 0
  fi
  local e
  for e in $active_list; do
    [[ -n "$e" && ( "$bid" == "$e" || ( -n "$name" && "$name" == *"$e"* ) ) ]] && return 0
  done
  return 1
}

case "$event" in
  UserPromptSubmit)
    mkdir -p "$state_dir"
    date +%s            > "$state_dir/$session_id.start"
    printf '%s' "$prompt" > "$state_dir/$session_id.prompt"
    ;;

  Stop)
    start_file="$state_dir/$session_id.start"
    prompt_file="$state_dir/$session_id.prompt"
    [[ -f "$start_file" ]] || exit 0
    local_start=$(cat "$start_file" 2>/dev/null)
    saved_prompt=$(cat "$prompt_file" 2>/dev/null)
    rm -f "$start_file" "$prompt_file"
    [[ -z "$local_start" ]] && exit 0

    elapsed=$(( $(date +%s) - local_start ))
    (( elapsed < threshold )) && exit 0
    __iyf_should_skip_active && exit 0

    label=${saved_prompt:-"Claude Code"}
    if (( ${#label} > 120 )); then label="${label:0:120}…"; fi
    # IYF_REPO_DIR points the launcher at the turn's project so it shows the
    # right repo (the hook's own cwd isn't guaranteed to be it). Empty falls
    # back to the launcher's cwd, which is the project in the usual setup.
    IYF_REPO_DIR="$cwd" "$dir/iyf-show-alert.sh" "$label" "$(__iyf_format_duration "$elapsed")" 0 >/dev/null 2>&1 &
    ;;
esac

exit 0
