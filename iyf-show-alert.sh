#!/bin/bash
# =============================================================
# iyf-show-alert — canonical maximized-window alert launcher
# -------------------------------------------------------------
# The browser-launching half of "In Your Face", factored out so
# both entry points share one implementation and can't drift:
#   - iyf.sh             (zsh preexec/precmd terminal hook)
#   - iyf-claude-hook.sh (Claude Code Stop hook)
#
# Usage: iyf-show-alert.sh <label> <formatted-duration> <exit-code>
# Reads from the environment:
#   IYF_ALERT_FILE      path to alert.html        (default ~/.iyf/alert.html)
#   IYF_AUTO_CLOSE      seconds before auto-close (default 90)
#   IYF_SNOOZE_MINUTES  snooze button options     (default "5 10 30 60")
#   IYF_SNOOZED         set by the snooze daemon when re-arming an alert
# =============================================================
set -u

cmd=${1:-}
duration=${2:-}
code=${3:-0}

alert_file=${IYF_ALERT_FILE:-$HOME/.iyf/alert.html}
auto_close=${IYF_AUTO_CLOSE:-90}
# Colon-less default: unset -> the defaults, but an explicit "" disables snooze.
snooze_minutes=${IYF_SNOOZE_MINUTES-"5 10 30 60"}

# Where this script lives, so the snooze daemon can be found and re-invoked.
selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# URL-encode the label so query parsing in alert.html stays intact; degrade to
# the raw string if python3 isn't around.
encoded_cmd=$(printf '%s' "$cmd" \
  | python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null \
  || printf '%s' "$cmd")

# Snooze: a sandboxed file:// page can't outlive its window, so we spawn a tiny
# detached daemon that the page signals (no-cors fetch) with the chosen delay;
# the daemon sleeps, then re-launches this same alert. Needs python3 — without
# it the page hides the snooze controls and behaves exactly as before.
sport=""; stoken=""
if [[ -n "${snooze_minutes// /}" ]] && command -v python3 >/dev/null 2>&1 \
   && [[ -f "$selfdir/iyf-snooze-daemon.py" ]]; then
  handoff=$(mktemp -t iyf-snooze.XXXXXX 2>/dev/null) || handoff="${TMPDIR:-/tmp}/iyf-snooze.$$"
  deadline=$(( ${auto_close%%.*} + 15 )); (( deadline > 0 )) || deadline=105
  python3 "$selfdir/iyf-snooze-daemon.py" "$handoff" "$deadline" \
    "$selfdir/iyf-show-alert.sh" "$cmd" "$duration" "$code" \
    "$alert_file" "$auto_close" "$snooze_minutes" >/dev/null 2>&1 &
  for _ in {1..60}; do
    [[ -s "$handoff" ]] && { read -r sport stoken < "$handoff"; break; }
    sleep 0.03
  done
  rm -f "$handoff"
fi

snooze_q="&snooze=0"
if [[ -n "$sport" && -n "$stoken" ]]; then
  snooze_q="&snooze=1&sport=${sport}&stoken=${stoken}&snoozemins=${snooze_minutes// /,}"
fi
[[ -n "${IYF_SNOOZED:-}" ]] && snooze_q="${snooze_q}&snoozed=1"

url="file://${alert_file}?cmd=${encoded_cmd}&duration=${duration}&code=${code}&autoclose=${auto_close}${snooze_q}"

# Close any alert still up so they never stack. Window/tab title is set by
# alert.html and contains "Command Finished".
__iyf_close_alerts() {
  local app=$1
  case "$app" in
    *Chrome*|*Brave*|*Edge*)
      osascript -e "tell app \"$app\" to close (every window whose name contains \"Command Finished\")" 2>/dev/null
      ;;
    *Safari*)
      osascript -e "tell app \"Safari\" to close (every tab of every window whose name contains \"Command Finished\")" 2>/dev/null
      ;;
  esac
}

app=""
if [[ -d "/Applications/Google Chrome.app" ]]; then
  app="Google Chrome"
elif [[ -d "/Applications/Brave Browser.app" ]]; then
  app="Brave Browser"
elif [[ -d "/Applications/Microsoft Edge.app" ]]; then
  app="Microsoft Edge"
fi

if [[ -n "$app" ]]; then
  __iyf_close_alerts "$app"
  # --start-maximized, not --start-fullscreen: a maximized window fills the
  # screen in the *current* Space, while native fullscreen slides the alert onto
  # its own Space — too much visual movement, and it stranded keyboard focus on
  # the terminal. Maximized stays put, in place, and takes focus cleanly.
  open -n -a "$app" --args --start-maximized --app="$url" &>/dev/null &
  # `open -n` shows the window but macOS often leaves keyboard focus on the
  # terminal, so Esc never reaches the alert (you'd have to click first). Pull
  # the browser frontmost once the new window exists so it becomes the key
  # window and receives keystrokes. Backgrounded so we don't stall the caller.
  osascript -e 'delay 0.4' -e "tell application \"$app\" to activate" &>/dev/null &
else
  # Safari fallback: it can't open a Chrome-style --app window, so open a tab and
  # size it to fill the screen — deliberately NOT native fullscreen (Cmd-Ctrl-F),
  # which slides the alert to a new Space (the visual movement we're removing).
  open -a Safari "$url" &>/dev/null &
  # Finder's desktop bounds are {0,0,w,h} on a single display but the union of
  # all screens on multi-monitor; only resize when it's anchored at the origin,
  # otherwise just bring Safari forward as a normal (still non-fullscreen) window.
  osascript &>/dev/null \
    -e 'delay 0.5' \
    -e 'tell application "Safari" to activate' \
    -e 'tell application "Finder" to set b to bounds of window of desktop' \
    -e 'if (item 1 of b is 0) and (item 2 of b is 0) then' \
    -e 'try' \
    -e 'tell application "Safari" to set bounds of front window to b' \
    -e 'end try' \
    -e 'end if' &
fi
