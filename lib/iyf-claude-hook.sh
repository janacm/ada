#!/bin/bash
# =============================================================
# iyf-claude-hook — In Your Face for Claude Code
# -------------------------------------------------------------
# Pops the same maximized-window alert as iyf.sh, but when a long
# Claude Code *turn* finishes instead of a shell command.
#
# One script, wired to the UserPromptSubmit + Stop hooks of Claude
# Code *and* Codex — both pass a matching JSON payload on stdin, so
# the same script serves both. It dispatches on hook_event_name:
#
#   UserPromptSubmit -> stamp a start time + the prompt text,
#                       keyed by session id.
#   Stop             -> if the turn ran longer than
#                       IYF_CLAUDE_THRESHOLD seconds AND you're
#                       not already looking at the terminal that
#                       hosts the agent, fire the alert showing the
#                       prompt and how long it took. If the Stop
#                       payload's session id doesn't match the
#                       stamped one (Codex parity), fall back to the
#                       most recent stamp so the alert still fires.
#
# Environment knobs (shared with iyf.sh where noted):
#   IYF_CLAUDE_THRESHOLD  min turn seconds to alert   (default 45)
#   IYF_ALERT_FILE        alert.html path             (default ~/.iyf/alert.html)
#   IYF_NATIVE_ALERT      path to iyf-alert helper    (default auto, via launcher)
#   IYF_AUTO_CLOSE        auto-dismiss seconds        (default 90)
#   IYF_SKIP_OWN_TERMINAL silence when terminal is frontmost (default 1)
#   IYF_SKIP_WHEN_ACTIVE  extra frontmost apps to stay silent for
#   IYF_CLAUDE_STALE_MAX  max age (s) of a fallback start stamp (default 21600)
#   IYF_DEBUG_LOG         when set, log each payload for debugging (default off)
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
[[ -z "$event" ]] && exit 0

# Opt-in breadcrumb for debugging Codex-vs-Claude payload shapes. Triggered by
# IYF_DEBUG_LOG=1 OR a sentinel file (so it works even when the agent strips the
# hook's env, e.g. Codex's shell_environment_policy=core). tail the log to see
# every event the agent actually delivers to this hook.
__iyf_dbg_log="${IYF_DEBUG_LOG_FILE:-${TMPDIR:-/tmp}/iyf-claude-debug.log}"
if [[ -n "${IYF_DEBUG_LOG:-}" || -e "${TMPDIR:-/tmp}/iyf-claude-debug.on" ]]; then
  printf '%s\tevent=%s\tsid=%s\tcwd=%s\tprompt=%.60s\n' \
    "$(date '+%F %T')" "$event" "$session_id" "$cwd" "$prompt" \
    >> "$__iyf_dbg_log" 2>/dev/null
fi

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
    [[ -z "$session_id" ]] && exit 0
    mkdir -p "$state_dir"
    date +%s            > "$state_dir/$session_id.start"
    printf '%s' "$prompt" > "$state_dir/$session_id.prompt"
    ;;

  Stop)
    start_file="$state_dir/$session_id.start"
    # Claude sends the same session_id on UserPromptSubmit and Stop, so the exact
    # stamp is found. Codex parity: if its Stop payload carries a different
    # session_id (or none), fall back to the most recent stamp still younger than
    # IYF_CLAUDE_STALE_MAX seconds, so the alert isn't silently dropped.
    if [[ -z "$session_id" || ! -f "$start_file" ]]; then
      start_file=$(ls -t "$state_dir"/*.start 2>/dev/null | head -1)
      [[ -n "$start_file" && -f "$start_file" ]] || exit 0
      now=$(date +%s)
      mtime=$(stat -f %m "$start_file" 2>/dev/null || echo 0)
      (( now - mtime > ${IYF_CLAUDE_STALE_MAX:-21600} )) && exit 0
    fi
    prompt_file="${start_file%.start}.prompt"
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

    # Clicking the alert can jump straight to this turn's conversation in the
    # Claude macOS app via its claude://resume?session=<id> deep link. Only wire
    # it for genuine Claude Code sessions: the id must be a UUID AND have a
    # transcript on disk. Codex shares this hook but its sessions can't be
    # imported into Claude.app, so skipping the link avoids a "Couldn't open
    # session" dialog. The id is the basename of the resolved start stamp, which
    # is the right session even on the Codex fallback path above.
    resolved_sid=$(basename "$start_file" .start)
    click_url=""; focus_name=""
    if [[ "$resolved_sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      if [[ -n "$(find "$claude_dir/projects" -maxdepth 2 -name "$resolved_sid.jsonl" -print -quit 2>/dev/null)" ]]; then
        click_url="claude://resume?session=$resolved_sid"
        focus_name="Claude"
      fi
    fi

    # IYF_REPO_DIR points the launcher at the turn's project so it shows the
    # right repo (the hook's own cwd isn't guaranteed to be it). Empty falls
    # back to the launcher's cwd, which is the project in the usual setup.
    # IYF_CLICK_URL makes clicking the alert open the deep link above (empty =
    # plain dismiss). IYF_FOCUS_APP_NAME labels the click hint ("…return to Claude").
    IYF_REPO_DIR="$cwd" IYF_CLICK_URL="$click_url" IYF_FOCUS_APP_NAME="$focus_name" \
      "$dir/iyf-show-alert.sh" "$label" "$(__iyf_format_duration "$elapsed")" 0 >/dev/null 2>&1 &
    ;;
esac

exit 0
