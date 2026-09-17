#!/bin/bash
# =============================================================
# ada-notify — "alert me now, unless I'm already watching"
# -------------------------------------------------------------
# The shared middle layer between an integration that knows a turn ended and
# ada-show-alert.sh, which knows how to render a window. It owns the two pieces
# every integration needs and none of them should reimplement:
#
#   1. frontmost-app suppression (ADA_SKIP_OWN_TERMINAL / ADA_SKIP_WHEN_ACTIVE)
#   2. seconds -> human duration formatting
#
# Callers:
#   - lib/ada-claude-hook.sh      sources it (Claude Code / Codex)
#   - lib/ada-opencode-plugin.mjs executes it (opencode)
#
# There are now three implementations of the frontmost check in this repo: this
# one (bash), ada.sh (zsh, sourced into your interactive shell) and
# ada-paseo-watch.py (python, because a LaunchAgent watcher can't source zsh).
# Three languages, three contexts. Do not add a fourth: a new integration
# either sources this file or execs it.
#
# Usage:  ada-notify.sh <label> <elapsed-seconds|""> <exit-code>
#   elapsed-seconds may be empty for an event with no meaningful duration
#   (a permission prompt), which renders an alert with no duration badge.
#
# Environment: everything ada-show-alert.sh reads (ADA_ALERT_FILE,
# ADA_AUTO_CLOSE, ADA_SNOOZE_MINUTES, ADA_REPO_DIR, ADA_CLICK_URL,
# ADA_FOCUS_APP, ADA_FOCUS_APP_NAME, ...) is passed through untouched, plus:
#   ADA_SKIP_OWN_TERMINAL  silence when the hosting terminal is frontmost (default 1)
#   ADA_SKIP_WHEN_ACTIVE   extra frontmost apps to stay silent for
# =============================================================
set -u

# True (0) when the frontmost app means you're already looking at the output, so
# the alert would be noise. Uses lsappinfo, which needs no Automation
# permission (unlike System Events).
__ada_should_skip_active() {
  local skip_own=${ADA_SKIP_OWN_TERMINAL:-1}
  local active_list=${ADA_SKIP_WHEN_ACTIVE:-}
  [[ "$skip_own" != 1 && -z "${active_list// /}" ]] && return 1

  local front bid name raw
  front=$(lsappinfo front 2>/dev/null) || return 1
  [[ -z "$front" ]] && return 1
  raw=$(lsappinfo info -only bundleid "$front" 2>/dev/null); bid=${raw##*=\"}; bid=${bid%\"}
  raw=$(lsappinfo info -only name "$front" 2>/dev/null);     name=${raw##*=\"}; name=${name%\"}

  # You're looking at the very terminal that hosts the agent.
  if [[ "$skip_own" == 1 && -n "${__CFBundleIdentifier:-}" && "$bid" == "${__CFBundleIdentifier:-}" ]]; then
    return 0
  fi

  # Frontmost app is one you explicitly asked to stay silent for.
  local e
  for e in $active_list; do
    [[ -n "$e" && ( "$bid" == "$e" || ( -n "$name" && "$name" == *"$e"* ) ) ]] && return 0
  done
  return 1
}

__ada_format_duration() {
  local s=${1:-}
  [[ -z "$s" ]] && return 0
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm %ds' $(( s / 60 )) $(( s % 60 ))
  else                      printf '%dh %dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); fi
}

# Fire the alert unless you're already watching. Resolves the launcher relative
# to THIS file so it works from a dev checkout, ~/.ada, Homebrew's libexec, or a
# staged runtime — never from a baked absolute path.
__ada_notify() {
  local label=${1:-} elapsed=${2:-} code=${3:-0}
  local selfdir; selfdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

  __ada_should_skip_active && return 0
  # Deliberately NOT exec: this function is meant to be callable in the
  # foreground by a sourced caller, and exec would replace that caller's process
  # mid-script. The launcher backgrounds the alert window itself and returns
  # immediately, so the extra process costs nothing.
  "$selfdir/ada-show-alert.sh" "$label" "$(__ada_format_duration "$elapsed")" "$code"
}

# Executed directly -> notify. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_notify "$@"
fi
