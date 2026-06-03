# =============================================================
# In Your Face for Terminal
# Maximized-window alert when long terminal commands finish
# =============================================================

export IYF_THRESHOLD=${IYF_THRESHOLD:-10}
export IYF_ALERT_FILE="${IYF_ALERT_FILE:-$HOME/.iyf/alert.html}"
export IYF_IGNORE_CMDS=${IYF_IGNORE_CMDS:-"vim nvim nano emacs less more man htop top tig lazygit btm bottom glances"}
export IYF_AUTO_CLOSE=${IYF_AUTO_CLOSE:-90}
# Snooze options (minutes) shown as buttons on the alert. Needs python3; an
# explicit empty value hides them. Colon-less so "" is preserved, not defaulted.
# See iyf-snooze-daemon.py for how a snooze re-arms the alert.
export IYF_SNOOZE_MINUTES=${IYF_SNOOZE_MINUTES-"5 10 30 60"}
# When the command finishes while you're already looking at the terminal that
# ran it, the output is right there and the alert is just noise. Suppress it.
export IYF_SKIP_OWN_TERMINAL=${IYF_SKIP_OWN_TERMINAL:-1}
# Extra apps to stay silent for when they're frontmost. Space-separated; each
# entry matches a frontmost app's bundle id exactly or its name as a substring.
# Note: terminal-TUI agents (opencode, etc.) are NOT separate apps — list the
# terminal that hosts them (e.g. "ghostty Termius iTerm2 Terminal").
export IYF_SKIP_WHEN_ACTIVE=${IYF_SKIP_WHEN_ACTIVE:-""}

zmodload zsh/datetime 2>/dev/null

# Directory this file lives in, captured at source time, so we can find the
# sibling iyf-show-alert.sh launcher regardless of cwd.
typeset -g _IYF_DIR="${${(%):-%x}:A:h}"

__iyf_is_ignored() {
  local cmd="${1%% *}"
  cmd="${cmd##*/}"
  local ignores=(${=IYF_IGNORE_CMDS})
  for ignore in $ignores; do
    [[ "$cmd" == "$ignore" ]] && return 0
  done
  return 1
}

# True when the frontmost macOS app means you're already watching the output,
# so the alert would be redundant. Uses lsappinfo (no Automation permission
# prompt, unlike System Events). Only called after the duration threshold, so
# it never touches the fast interactive path.
__iyf_should_skip_active() {
  local skip_own=${IYF_SKIP_OWN_TERMINAL:-1}
  [[ "$skip_own" != 1 && -z "${IYF_SKIP_WHEN_ACTIVE// /}" ]] && return 1

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
  local entries=(${=IYF_SKIP_WHEN_ACTIVE}) e
  for e in $entries; do
    [[ -n "$e" && ( "$bid" == "$e" || ( -n "$name" && "$name" == *"$e"* ) ) ]] && return 0
  done

  return 1
}

__iyf_format_duration() {
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

__iyf_preexec() {
  typeset -g __iyf_cmd="$1"
  typeset -g __iyf_start_time=$EPOCHREALTIME
}

__iyf_precmd() {
  local exit_code=$?
  [[ -z "${__iyf_cmd:-}" ]] && return

  local end_time=$EPOCHREALTIME
  local elapsed=$(( end_time - __iyf_start_time ))

  if (( elapsed > IYF_THRESHOLD )) && ! __iyf_is_ignored "$__iyf_cmd" && ! __iyf_should_skip_active; then
    __iyf_show_alert "$__iyf_cmd" "$elapsed" "$exit_code"
  fi

  __iyf_cmd=
}

__iyf_show_alert() {
  local cmd=$1 duration=$2 code=$3
  local formatted=$(__iyf_format_duration $duration)
  "$_IYF_DIR/iyf-show-alert.sh" "$cmd" "$formatted" "$code"
}

# Manual trigger for testing: iyf any command here
iyf() {
  __iyf_show_alert "${*:-manual}" 0.5 0
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __iyf_preexec
add-zsh-hook precmd __iyf_precmd
