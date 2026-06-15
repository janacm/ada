#!/bin/bash
# =============================================================
# iyf-show-alert — canonical maximized-window alert launcher
# -------------------------------------------------------------
# The alert-launching half of "In Your Face", factored out so
# both entry points share one implementation and can't drift:
#   - iyf.sh             (zsh preexec/precmd terminal hook)
#   - iyf-claude-hook.sh (Claude Code Stop hook)
#
# Usage: iyf-show-alert.sh <label> <formatted-duration> <exit-code>
# Reads from the environment:
#   IYF_ALERT_FILE      path to alert.html        (default ~/.iyf/alert.html)
#   IYF_AUTO_CLOSE      seconds before auto-close (default 90)
#   IYF_SNOOZE_MINUTES  snooze button options     (default "5 10 30 60")
#   IYF_FOCUS_APP       bundle id to focus on click (default $__CFBundleIdentifier)
#   IYF_FOCUS_APP_NAME  optional display name for the click hint
#   IYF_SNOOZED         set by the snooze daemon when re-arming an alert
#   IYF_NATIVE_ALERT    path to iyf-alert native helper
# =============================================================
set -u

cmd=${1:-}
duration=${2:-}
code=${3:-0}

alert_file=${IYF_ALERT_FILE:-$HOME/.iyf/alert.html}
auto_close=${IYF_AUTO_CLOSE:-90}
# Colon-less default: unset -> the defaults, but an explicit "" disables snooze.
snooze_minutes=${IYF_SNOOZE_MINUTES-"5 10 30 60"}
if [[ -n "${IYF_FOCUS_APP+x}" ]]; then
  focus_app=$IYF_FOCUS_APP
else
  focus_app=${__CFBundleIdentifier:-}
fi
focus_app_name=${IYF_FOCUS_APP_NAME:-}

# Where this script lives, so the snooze daemon can be found and re-invoked.
selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

__iyf_find_native_alert() {
  local p
  if [[ -n "${IYF_NATIVE_ALERT:-}" ]]; then
    [[ -x "$IYF_NATIVE_ALERT" ]] && { printf '%s\n' "$IYF_NATIVE_ALERT"; return 0; }
    return 1
  fi

  for p in "$selfdir/iyf-alert" \
           "$selfdir/.build/release/iyf-alert" \
           "$selfdir/.build/debug/iyf-alert"; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

__iyf_kill_previous_native_alert() {
  local pid_file pid command_name
  pid_file=${IYF_NATIVE_PID_FILE:-${TMPDIR:-/tmp}/iyf-alert.pid}
  [[ -r "$pid_file" ]] || return 0
  read -r pid < "$pid_file" || return 0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  command_name=$(ps -p "$pid" -o comm= 2>/dev/null)
  [[ "${command_name##*/}" == "iyf-alert" ]] || return 0

  kill "$pid" 2>/dev/null || return 0
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
}

__iyf_kill_legacy_browser_alert() {
  local profile
  profile="$HOME/.iyf-alert-profile"
  # Migration cleanup only: old iyf versions launched a dedicated browser
  # profile. Native-only iyf never launches this process.
  pgrep -f "user-data-dir=$profile" >/dev/null 2>&1 || return 0
  pkill -f "user-data-dir=$profile" 2>/dev/null || return 0
  for _ in {1..20}; do
    pgrep -f "user-data-dir=$profile" >/dev/null 2>&1 || break
    sleep 0.05
  done
}

native_alert=$(__iyf_find_native_alert 2>/dev/null || true)
if [[ -z "$native_alert" ]]; then
  echo "iyf-show-alert: native helper iyf-alert was not found or executable." >&2
  echo "  Build it with: swift build -c release --product iyf-alert" >&2
  exit 1
fi

# URL-encode the label so query parsing in alert.html stays intact; degrade to
# the raw string if python3 isn't around.
encoded_cmd=$(printf '%s' "$cmd" \
  | python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null \
  || printf '%s' "$cmd")

# Repo name shown on the alert so you can tell which project a finished command
# / turn belongs to. Resolved ONCE here and exported: a snoozed relaunch runs
# from the detached daemon's unrelated cwd, but inherits this environment, so it
# reuses the value instead of recomputing the wrong repo. Already-set (even
# empty) => trust it; empty means "not a git repo" and the page hides the badge.
# IYF_REPO_DIR lets a caller name the directory to inspect (the Claude hook does,
# since its cwd isn't guaranteed to be the project); the zsh hook needs nothing —
# the launcher already inherits the directory the command ran in.
if [[ -z "${IYF_REPO+set}" ]]; then
  repo=$(git -C "${IYF_REPO_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)
  export IYF_REPO="${repo##*/}"
fi
encoded_repo=$(printf '%s' "$IYF_REPO" \
  | python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null \
  || printf '%s' "$IYF_REPO")
encoded_focus_app_name=$(printf '%s' "$focus_app_name" \
  | python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null \
  || printf '%s' "$focus_app_name")

# Snooze/focus: a sandboxed file:// page can't outlive its window or activate
# another app itself, so we spawn a tiny detached daemon that the page signals
# through the native WebKit bridge. Needs python3 — without it the page hides the
# snooze controls and click-anywhere degrades to plain dismiss.
sport=""; stoken=""
needs_daemon=0
[[ -n "${snooze_minutes// /}" || -n "${focus_app// /}" ]] && needs_daemon=1
if [[ "$needs_daemon" == 1 ]] && command -v python3 >/dev/null 2>&1 \
   && [[ -f "$selfdir/iyf-snooze-daemon.py" ]]; then
  handoff=$(mktemp -t iyf-snooze.XXXXXX 2>/dev/null) || handoff="${TMPDIR:-/tmp}/iyf-snooze.$$"
  deadline=$(( ${auto_close%%.*} + 15 )); (( deadline > 0 )) || deadline=105
  python3 "$selfdir/iyf-snooze-daemon.py" "$handoff" "$deadline" \
    "$selfdir/iyf-show-alert.sh" "$cmd" "$duration" "$code" \
    "$alert_file" "$auto_close" "$snooze_minutes" "$focus_app" >/dev/null 2>&1 &
  for _ in {1..60}; do
    [[ -s "$handoff" ]] && { read -r sport stoken < "$handoff"; break; }
    sleep 0.03
  done
  rm -f "$handoff"
fi

daemon_q="&snooze=0&focus=0"
if [[ -n "$sport" && -n "$stoken" ]]; then
  daemon_q="&sport=${sport}&stoken=${stoken}"
  if [[ -n "${snooze_minutes// /}" ]]; then
    daemon_q="${daemon_q}&snooze=1&snoozemins=${snooze_minutes// /,}"
  else
    daemon_q="${daemon_q}&snooze=0"
  fi
  if [[ -n "${focus_app// /}" ]]; then
    daemon_q="${daemon_q}&focus=1"
    [[ -n "$encoded_focus_app_name" ]] && daemon_q="${daemon_q}&focusname=${encoded_focus_app_name}"
  else
    daemon_q="${daemon_q}&focus=0"
  fi
fi
[[ -n "${IYF_SNOOZED:-}" ]] && daemon_q="${daemon_q}&snoozed=1"

url="file://${alert_file}?cmd=${encoded_cmd}&duration=${duration}&code=${code}&autoclose=${auto_close}&repo=${encoded_repo}${daemon_q}"

__iyf_kill_previous_native_alert
__iyf_kill_legacy_browser_alert
"$native_alert" "$url" &>/dev/null &
native_pid=$!
printf '%s\n' "$native_pid" > "${IYF_NATIVE_PID_FILE:-${TMPDIR:-/tmp}/iyf-alert.pid}" 2>/dev/null || true
