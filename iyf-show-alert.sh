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

url="file://${alert_file}?cmd=${encoded_cmd}&duration=${duration}&code=${code}&autoclose=${auto_close}&repo=${encoded_repo}${snooze_q}"

app=""
if [[ -d "/Applications/Google Chrome.app" ]]; then
  app="Google Chrome"
elif [[ -d "/Applications/Brave Browser.app" ]]; then
  app="Brave Browser"
elif [[ -d "/Applications/Microsoft Edge.app" ]]; then
  app="Microsoft Edge"
fi

if [[ -n "$app" ]]; then
  # A maximized WINDOW, not native fullscreen. The macOS catch: when the browser
  # is already running, `open --args` silently drops every startup flag, so an
  # --app window just inherits native fullscreen (its own Space — the visual
  # movement we're removing) no matter what --window-* / --start-* flags we pass.
  # The fix is a dedicated, throwaway browser instance (its own --user-data-dir):
  # that's a fresh process, so the geometry flags DO apply and the alert opens as
  # an ordinary window in the current Space.
  profile="${IYF_BROWSER_PROFILE:-$HOME/.iyf-alert-profile}"
  mkdir -p "$profile" 2>/dev/null

  # Quit any previous alert instance: stops windows stacking AND guarantees this
  # launch is a genuinely fresh process (a reused instance would ignore the
  # geometry flags — the whole bug we're sidestepping).
  pkill -f "user-data-dir=$profile" 2>/dev/null
  for _ in {1..20}; do pgrep -f "user-data-dir=$profile" >/dev/null 2>&1 || break; sleep 0.05; done

  # Primary display's visible frame (below the menu bar, above the Dock), in the
  # top-left coordinates --window-position expects. Read straight from AppKit via
  # JXA — no Accessibility prompt, and correct on a multi-monitor setup.
  geom=$(osascript -l JavaScript -e 'ObjC.import("AppKit");var p=$.NSScreen.screens.objectAtIndex(0);var f=p.frame,v=p.visibleFrame;[Math.round(v.origin.x),Math.round(f.size.height-(v.origin.y+v.size.height)),Math.round(v.size.width),Math.round(v.size.height)].join(",")' 2>/dev/null)
  IFS=, read -r wx wy ww wh <<<"$geom"

  args=(--user-data-dir="$profile" --no-first-run --no-default-browser-check --disable-session-crashed-bubble)
  if [[ -n "$ww" && "$ww" -gt 0 ]]; then
    args+=(--window-position="${wx},${wy}" --window-size="${ww},${wh}")
  fi
  # `open -na` starts the separate instance and brings it frontmost, so the
  # ordinary in-Space window takes keyboard focus and Esc reaches it.
  open -na "$app" --args "${args[@]}" --app="$url" &>/dev/null &
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
