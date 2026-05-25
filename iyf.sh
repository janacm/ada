# =============================================================
# In Your Face for Terminal
# Full-screen alert when long terminal commands finish
# =============================================================

export IYF_THRESHOLD=${IYF_THRESHOLD:-10}
export IYF_ALERT_FILE="${IYF_ALERT_FILE:-$HOME/.iyf/alert.html}"
export IYF_IGNORE_CMDS=${IYF_IGNORE_CMDS:-"vim nvim nano emacs less more man htop top tig lazygit btm bottom glances"}
export IYF_AUTO_CLOSE=${IYF_AUTO_CLOSE:-90}

zmodload zsh/datetime 2>/dev/null

__iyf_is_ignored() {
  local cmd="${1%% *}"
  cmd="${cmd##*/}"
  local ignores=(${(s:,:)IYF_IGNORE_CMDS})
  for ignore in $ignores; do
    ignore="${ignore## }"
    ignore="${ignore%% }"
    [[ "$cmd" == "$ignore" ]] && return 0
  done
  return 1
}

__iyf_format_duration() {
  local seconds=$1
  if (( seconds < 60 )); then
    printf "%.1fs" $seconds
  elif (( seconds < 3600 )); then
    printf "%dm %ds" $(( seconds / 60 )) $(( (int)seconds % 60 ))
  else
    printf "%dh %dm" $(( seconds / 3600 )) $(( ((int)seconds % 3600) / 60 ))
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

  if (( elapsed > IYF_THRESHOLD )) && ! __iyf_is_ignored "$__iyf_cmd"; then
    __iyf_show_alert "$__iyf_cmd" "$elapsed" "$exit_code"
  fi

  __iyf_cmd=
}

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

__iyf_show_alert() {
  local cmd=$1 duration=$2 code=$3
  local formatted=$(__iyf_format_duration $duration)

  local encoded_cmd
  encoded_cmd=$(python3 -c "
import urllib.parse, sys
print(urllib.parse.quote(sys.stdin.read().strip()))
" <<< "$cmd" 2>/dev/null || echo "$cmd")

  local url="file://${IYF_ALERT_FILE}?cmd=${encoded_cmd}&duration=${formatted}&code=${code}&autoclose=${IYF_AUTO_CLOSE}"

  if [[ -d "/Applications/Google Chrome.app" ]]; then
    __iyf_close_alerts "Google Chrome"
    open -n -a "Google Chrome" --args --start-fullscreen --app="$url" &>/dev/null &
  elif [[ -d "/Applications/Brave Browser.app" ]]; then
    __iyf_close_alerts "Brave Browser"
    open -n -a "Brave Browser" --args --start-fullscreen --app="$url" &>/dev/null &
  elif [[ -d "/Applications/Microsoft Edge.app" ]]; then
    __iyf_close_alerts "Microsoft Edge"
    open -n -a "Microsoft Edge" --args --start-fullscreen --app="$url" &>/dev/null &
  else
    open -a Safari "$url" &>/dev/null &
    osascript -e 'delay 0.5' -e 'tell application "Safari" to activate' \
      -e 'tell application "System Events" to tell process "Safari" to keystroke "f" using {command down, control down}' \
      &>/dev/null &
  fi
}

# Manual trigger for testing: iyf any command here
iyf() {
  __iyf_show_alert "${*:-manual}" 0.5 0
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec __iyf_preexec
add-zsh-hook precmd __iyf_precmd
