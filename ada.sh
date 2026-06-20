# =============================================================
# Agent Done Alert for Terminal
# Maximized-window alert when long terminal commands finish
# =============================================================

export ADA_THRESHOLD=${ADA_THRESHOLD:-10}
export ADA_ALERT_FILE="${ADA_ALERT_FILE:-$HOME/.ada/alert.html}"
export ADA_IGNORE_CMDS=${ADA_IGNORE_CMDS:-"vim nvim nano emacs less more man htop top tig lazygit btm bottom glances"}
export ADA_AUTO_CLOSE=${ADA_AUTO_CLOSE:-90}
# Snooze options (minutes) shown as buttons on the alert. Needs python3; an
# explicit empty value hides them. Colon-less so "" is preserved, not defaulted.
# See ada-snooze-daemon.py for how a snooze re-arms the alert.
export ADA_SNOOZE_MINUTES=${ADA_SNOOZE_MINUTES-"5 10 30 60"}
# When the command finishes while you're already looking at the terminal that
# ran it, the output is right there and the alert is just noise. Suppress it.
export ADA_SKIP_OWN_TERMINAL=${ADA_SKIP_OWN_TERMINAL:-1}
# Extra apps to stay silent for when they're frontmost. Space-separated; each
# entry matches a frontmost app's bundle id exactly or its name as a substring.
# Note: terminal-TUI agents (opencode, etc.) are NOT separate apps — list the
# terminal that hosts them (e.g. "ghostty Termius iTerm2 Terminal").
export ADA_SKIP_WHEN_ACTIVE=${ADA_SKIP_WHEN_ACTIVE:-""}

zmodload zsh/datetime 2>/dev/null

# Directory this file lives in, captured at source time, so we can find the
# sibling ada-show-alert.sh launcher regardless of cwd.
typeset -g _ADA_DIR="${${(%):-%x}:A:h}"

__ada_is_ignored() {
  local cmd="${1%% *}"
  cmd="${cmd##*/}"
  local ignores=(${=ADA_IGNORE_CMDS})
  for ignore in $ignores; do
    [[ "$cmd" == "$ignore" ]] && return 0
  done
  return 1
}

# True when the frontmost macOS app means you're already watching the output,
# so the alert would be redundant. Uses lsappinfo (no Automation permission
# prompt, unlike System Events). Only called after the duration threshold, so
# it never touches the fast interactive path.
__ada_should_skip_active() {
  local skip_own=${ADA_SKIP_OWN_TERMINAL:-1}
  [[ "$skip_own" != 1 && -z "${ADA_SKIP_WHEN_ACTIVE// /}" ]] && return 1

  local front bid name raw
  front=$(lsappinfo front 2>/dev/null) || return 1
  [[ -z "$front" ]] && return 1
  raw=$(lsappinfo info -only bundleid "$front" 2>/dev/null); bid=${raw##*=\"}; bid=${bid%\"}
  raw=$(lsappinfo info -only name "$front" 2>/dev/null);     name=${raw##*=\"}; name=${name%\"}

  # You're looking at the very terminal that ran the command.
  if [[ "$skip_own" == 1 && -n "$__CFBundleIdentifier" && "$bid" == "$__CFBundleIdentifier" ]]; then
    return 0
  fi

  # Frontmost app is one you explicitly asked to stay silent for.
  local entries=(${=ADA_SKIP_WHEN_ACTIVE}) e
  for e in $entries; do
    [[ -n "$e" && ( "$bid" == "$e" || ( -n "$name" && "$name" == *"$e"* ) ) ]] && return 0
  done

  return 1
}

__ada_format_duration() {
  local seconds=$1
  if (( seconds < 60 )); then
    printf "%.1fs" $seconds
  elif (( seconds < 3600 )); then
    local s=${seconds%%.*}
    printf "%dm %ds" $(( s / 60 )) $(( s % 60 ))
  else
    local s=${seconds%%.*}
    printf "%dh %dm" $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

__ada_preexec() {
  typeset -g __ada_cmd="$1"
  typeset -g __ada_start_time=$EPOCHREALTIME
}

__ada_precmd() {
  local exit_code=$?
  [[ -z "${__ada_cmd:-}" ]] && return

  local end_time=$EPOCHREALTIME
  local elapsed=$(( end_time - __ada_start_time ))

  if (( elapsed > ADA_THRESHOLD )) && ! __ada_is_ignored "$__ada_cmd" && ! __ada_should_skip_active; then
    __ada_show_alert "$__ada_cmd" "$elapsed" "$exit_code"
  fi

  __ada_cmd=
}

__ada_show_alert() {
  local cmd=$1 duration=$2 code=$3
  local formatted=$(__ada_format_duration $duration)
  "$_ADA_DIR/lib/ada-show-alert.sh" "$cmd" "$formatted" "$code"
}

# Manual trigger for testing: ada any command here
ada() {
  __ada_show_alert "${*:-manual}" 0.5 0
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __ada_preexec
add-zsh-hook precmd __ada_precmd
