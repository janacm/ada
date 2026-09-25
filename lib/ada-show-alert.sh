#!/bin/bash
# =============================================================
# ada-show-alert — canonical maximized-window alert launcher
# -------------------------------------------------------------
# The alert-launching half of "Agent Done Alert", factored out so
# both entry points share one implementation and can't drift:
#   - ada.sh             (zsh preexec/precmd terminal hook)
#   - ada-claude-hook.sh (shared Claude Code / Codex hook)
#
# Usage: ada-show-alert.sh <label> <formatted-duration> <exit-code>
# Reads from the environment:
#   ADA_ALERT_FILE      path to alert.html        (default: alongside this script)
#   ADA_AUTO_CLOSE      seconds before auto-close (default 90)
#   ADA_SNOOZE_MINUTES  snooze button options     (default "5 10 30 60")
#   ADA_FOCUS_APP       bundle id to focus on click (default $__CFBundleIdentifier)
#   ADA_FOCUS_APP_NAME  optional display name for the click hint
#   ADA_CLICK_URL       URL to `open` on click (e.g. claude://resume?session=…);
#                       takes precedence over ADA_FOCUS_APP for the click action
#   ADA_SESSION_KEY     which session this alert belongs to (e.g. claude-<id>);
#                       a muted key drops the alert, a valid one adds the
#                       "Mute this …" button. See lib/ada-mute.sh.
#   ADA_SESSION_KIND    what the button calls it: conversation, session, agent,
#                       terminal (default "session")
#   ADA_MUTE_BUTTON     0 hides the mute button (existing mutes still apply)
#   ADA_MUTE_DIR / ADA_MUTE_MAX_AGE  see lib/ada-mute.sh
#   ADA_SNOOZE_SCOPE    "session": snoozing also holds the session's later
#                       alerts until the snooze wakes. Default "alert" re-shows
#                       only the snoozed alert. See lib/ada-mute.sh.
#   ADA_PAUSE_FILE      see lib/ada-pause.sh; a pause drops every alert
#   ADA_IGNORE_PAUSE    1 for an alert the user asked for (the test alerts)
#   ADA_HISTORY_FILE / ADA_HISTORY_MAX  see lib/ada-history.sh
#   ADA_SNOOZED         set by the snooze daemon when re-arming an alert
#   ADA_NATIVE_ALERT    path to ada-alert native helper
# =============================================================
set -u

cmd=${1:-}
duration=${2:-}
code=${3:-0}

# Where this script lives, so the snooze daemon and the sibling alert page can
# be found and re-invoked.
selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The pause file, the mute markers and the alert pid file all live under
# TMPDIR, so every process that reads or writes them has to agree on it. A hook
# or plugin started from a stripped environment may arrive without TMPDIR, and
# falling back to /tmp would then miss a pause the menu bar set. Terminals and
# launchd jobs both get the per-user Darwin temp dir, so ask for that instead.
if [[ -z "${TMPDIR:-}" ]]; then
  TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || TMPDIR=""
  [[ -n "$TMPDIR" ]] || TMPDIR=/tmp
  export TMPDIR
fi

# Which session raised this alert and where a click on it leads. Plain
# assignments, made before the pause and mute checks so that the history line
# of a dropped alert still carries its click target.
session_key=${ADA_SESSION_KEY:-}
session_kind=${ADA_SESSION_KIND:-session}
if [[ -n "${ADA_FOCUS_APP+x}" ]]; then
  focus_app=$ADA_FOCUS_APP
else
  focus_app=${__CFBundleIdentifier:-}
fi
focus_app_name=${ADA_FOCUS_APP_NAME:-}
click_url=${ADA_CLICK_URL:-}

# Every alert decided here gets a line in the history (lib/ada-history.sh) that
# the menu bar's Recent Alerts reads: shown, paused or muted. A missing
# ada-history.sh means no history, never a missing alert.
if [[ -f "$selfdir/ada-history.sh" ]]; then
  # shellcheck source=lib/ada-history.sh
  . "$selfdir/ada-history.sh"
else
  __ada_history_record() { :; }
fi
# A dropped alert records ADA_REPO only when it was inherited (a snooze
# relaunch has it): resolving the repo runs git, which waits until the alert is
# known to be shown.
__ada_record() {
  __ada_history_record "$1" "$session_key" "$session_kind" "$cmd" "$duration" "$code" \
    "${ADA_REPO:-}" "$focus_app" "$focus_app_name" "$click_url"
}

# A pause (the menu bar's Pause menu, or lib/ada-pause.sh) drops every alert,
# whichever integration raised it, the snooze relaunch included. Test alerts
# pass ADA_IGNORE_PAUSE=1. A missing ada-pause.sh means no pausing, never a
# missing alert.
if [[ "${ADA_IGNORE_PAUSE:-}" != 1 && -f "$selfdir/ada-pause.sh" ]]; then
  # shellcheck source=lib/ada-pause.sh
  . "$selfdir/ada-pause.sh"
  if __ada_is_paused; then
    __ada_record paused
    exit 0
  fi
fi

# A muted session drops every alert, whichever integration raised it: this
# launcher is the one place they all pass through, the snooze relaunch included.
# A missing ada-mute.sh (an old copy of just this script) means no muting, never
# a missing alert.
mute_file=""
hold_file=""
if [[ -f "$selfdir/ada-mute.sh" ]]; then
  # shellcheck source=lib/ada-mute.sh
  . "$selfdir/ada-mute.sh"
  __ada_mute_prune
  if [[ -n "$session_key" ]]; then
    if __ada_is_muted "$session_key"; then
      __ada_record muted
      exit 0
    fi
    # A session-scoped snooze holds the session's alerts until it wakes. The
    # daemon lifts the hold before its own relaunch, so the reminder gets out.
    if __ada_snooze_held "$session_key"; then
      __ada_record held
      exit 0
    fi
    # ADA_MUTE_BUTTON=0 hides the button; existing mutes still apply.
    if [[ "${ADA_MUTE_BUTTON:-1}" == 1 ]]; then
      mute_file=$(__ada_mute_file "$session_key") || mute_file=""
    fi
    # Only an integration that can tell your prompts from the agent's own turns
    # opts in, because it is also the one that releases the hold when you type.
    if [[ "${ADA_SNOOZE_SCOPE:-alert}" == session ]]; then
      hold_file=$(__ada_snooze_hold_file "$session_key") || hold_file=""
    fi
  fi
fi

# alert.html ships one level up from lib/. Resolve it relative to THIS script so
# the launcher works from a dev checkout, ~/.ada, Homebrew's libexec, or the
# staged Paseo runtime. A hardcoded ~/.ada default renders a blank window on a
# Homebrew install, where no such directory exists; keep it only as a fallback
# for older layouts.
alert_file=${ADA_ALERT_FILE:-}
if [[ -z "$alert_file" ]]; then
  if [[ -f "$selfdir/../alert.html" ]]; then
    alert_file="$(cd "$selfdir/.." && pwd)/alert.html"
  else
    alert_file="$HOME/.ada/alert.html"
  fi
fi
auto_close=${ADA_AUTO_CLOSE:-90}
# Colon-less default: unset -> the defaults, but an explicit "" disables snooze.
snooze_minutes=${ADA_SNOOZE_MINUTES-"5 10 30 60"}

__ada_url_encode() {
  local value=${1:-}
  printf '%s' "$value" \
    | python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null \
    || printf '%s' "$value"
}

__ada_b64url_encode() {
  local value=${1:-}
  printf '%s' "$value" \
    | python3 -c "import base64,sys; data=sys.stdin.read().strip().encode(); print(base64.urlsafe_b64encode(data).decode().rstrip('='))" 2>/dev/null \
    || true
}

__ada_find_native_alert() {
  local p
  if [[ -n "${ADA_NATIVE_ALERT:-}" ]]; then
    [[ -x "$ADA_NATIVE_ALERT" ]] && { printf '%s\n' "$ADA_NATIVE_ALERT"; return 0; }
    return 1
  fi

  local repodir; repodir=$(cd "$selfdir/.." && pwd)
  for p in "$repodir/ada-alert" \
           "$repodir/.build/release/ada-alert" \
           "$repodir/.build/debug/ada-alert"; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

__ada_kill_previous_native_alert() {
  local pid_file pid command_name
  pid_file=${ADA_NATIVE_PID_FILE:-${TMPDIR:-/tmp}/ada-alert.pid}
  [[ -r "$pid_file" ]] || return 0
  read -r pid < "$pid_file" || return 0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  command_name=$(ps -p "$pid" -o comm= 2>/dev/null)
  [[ "${command_name##*/}" == "ada-alert" ]] || return 0

  kill "$pid" 2>/dev/null || return 0
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
}

__ada_kill_legacy_browser_alert() {
  local profile
  profile="$HOME/.ada-alert-profile"
  # Migration cleanup only: old ada versions launched a dedicated browser
  # profile. Native-only ada never launches this process.
  pgrep -f "user-data-dir=$profile" >/dev/null 2>&1 || return 0
  pkill -f "user-data-dir=$profile" 2>/dev/null || return 0
  for _ in {1..20}; do
    pgrep -f "user-data-dir=$profile" >/dev/null 2>&1 || break
    sleep 0.05
  done
}

native_alert=$(__ada_find_native_alert 2>/dev/null || true)
if [[ -z "$native_alert" ]]; then
  echo "ada-show-alert: native helper ada-alert was not found or executable." >&2
  echo "  Build it with: swift build -c release --product ada-alert" >&2
  exit 1
fi

# URL-encode the label so query parsing in alert.html stays intact; degrade to
# the raw string if python3 isn't around. Also pass URL-safe base64 for the
# native WebKit path, which can re-escape percent-encoded file:// query values.
encoded_cmd=$(__ada_url_encode "$cmd")
encoded_cmd_b64=$(__ada_b64url_encode "$cmd")

# Repo name shown on the alert so you can tell which project a finished command
# / turn belongs to. Resolved ONCE here and exported: a snoozed relaunch runs
# from the detached daemon's unrelated cwd, but inherits this environment, so it
# reuses the value instead of recomputing the wrong repo. Already-set (even
# empty) => trust it; empty means "not a git repo" and the page hides the badge.
# ADA_REPO_DIR lets a caller name the directory to inspect (the Claude hook does,
# since its cwd isn't guaranteed to be the project); the zsh hook needs nothing —
# the launcher already inherits the directory the command ran in.
if [[ -z "${ADA_REPO+set}" ]]; then
  repo=$(git -C "${ADA_REPO_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)
  export ADA_REPO="${repo##*/}"
fi
__ada_record shown
encoded_repo=$(__ada_url_encode "$ADA_REPO")
encoded_repo_b64=$(__ada_b64url_encode "$ADA_REPO")
encoded_focus_app_name=$(__ada_url_encode "$focus_app_name")
encoded_focus_app_name_b64=$(__ada_b64url_encode "$focus_app_name")
# The session noun ("conversation", "terminal", ...) labels both the mute button
# and a session-wide snooze, so it goes out when either one is on. The param is
# still called mutekindb64 because the mute button used it first.
encoded_session_kind_b64=""
[[ -n "$mute_file" || -n "$hold_file" ]] && encoded_session_kind_b64=$(__ada_b64url_encode "$session_kind")

# Snooze/focus: a sandboxed file:// page can't outlive its window or activate
# another app itself, so we spawn a tiny detached daemon that the page signals
# through the native WebKit bridge. Needs python3 — without it the page hides the
# snooze controls and click-anywhere degrades to plain dismiss.
sport=""; stoken=""
needs_daemon=0
[[ -n "${snooze_minutes// /}" || -n "${focus_app// /}" || -n "${click_url// /}" || -n "$mute_file" ]] && needs_daemon=1
if [[ "$needs_daemon" == 1 ]] && command -v python3 >/dev/null 2>&1 \
   && [[ -f "$selfdir/ada-snooze-daemon.py" ]]; then
  handoff=$(mktemp -t ada-snooze.XXXXXX 2>/dev/null) || handoff="${TMPDIR:-/tmp}/ada-snooze.$$"
  deadline=$(( ${auto_close%%.*} + 15 )); (( deadline > 0 )) || deadline=105
  ADA_MUTE_FILE="$mute_file" ADA_SNOOZE_HOLD_FILE="$hold_file" \
    python3 "$selfdir/ada-snooze-daemon.py" "$handoff" "$deadline" \
    "$selfdir/ada-show-alert.sh" "$cmd" "$duration" "$code" \
    "$alert_file" "$auto_close" "$snooze_minutes" "$focus_app" "$click_url" >/dev/null 2>&1 &
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
    # The page says what a snooze covers, and only this launcher knows: a
    # session-wide one needs the hold file named above.
    [[ -n "$hold_file" ]] && daemon_q="${daemon_q}&snoozescope=session"
  else
    daemon_q="${daemon_q}&snooze=0"
  fi
  if [[ -n "${focus_app// /}" || -n "${click_url// /}" ]]; then
    daemon_q="${daemon_q}&focus=1"
    [[ -n "$encoded_focus_app_name" ]] && daemon_q="${daemon_q}&focusname=${encoded_focus_app_name}"
    [[ -n "$encoded_focus_app_name_b64" ]] && daemon_q="${daemon_q}&focusnameb64=${encoded_focus_app_name_b64}"
  else
    daemon_q="${daemon_q}&focus=0"
  fi
  [[ -n "$mute_file" ]] && daemon_q="${daemon_q}&mute=1"
  [[ -n "$encoded_session_kind_b64" ]] && daemon_q="${daemon_q}&mutekindb64=${encoded_session_kind_b64}"
fi
[[ -n "${ADA_SNOOZED:-}" ]] && daemon_q="${daemon_q}&snoozed=1"

text_q=""
[[ -n "$encoded_cmd_b64" ]] && text_q="${text_q}&cmdb64=${encoded_cmd_b64}"
[[ -n "$encoded_repo_b64" ]] && text_q="${text_q}&repob64=${encoded_repo_b64}"

url="file://${alert_file}?cmd=${encoded_cmd}${text_q}&duration=${duration}&code=${code}&autoclose=${auto_close}&repo=${encoded_repo}${daemon_q}"

__ada_kill_previous_native_alert
__ada_kill_legacy_browser_alert
"$native_alert" "$url" &>/dev/null &
native_pid=$!
printf '%s\n' "$native_pid" > "${ADA_NATIVE_PID_FILE:-${TMPDIR:-/tmp}/ada-alert.pid}" 2>/dev/null || true
