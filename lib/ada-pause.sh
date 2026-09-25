#!/bin/bash
# =============================================================
# ada-pause — "no alerts for a while"
# -------------------------------------------------------------
# One switch that silences every alert, from every integration, until a given
# time or until resumed. Like muting, it is enforced only in ada-show-alert.sh,
# the launcher every integration reaches (ada.sh, ada-notify.sh, the Paseo
# watcher) and the snooze daemon's relaunch re-enters. The menu bar's Pause
# menu and this CLI set the same switch.
#
# The state is one file holding one integer: the epoch second the pause ends,
# or 0 for "until resumed". No file means alerts are on. A file holding
# anything else is not ours: it pauses nothing and is never overwritten or
# deleted. Writes go to a temp file renamed into place, so a reader never sees
# half a number.
#
# Sourced by ada-show-alert.sh for the helpers below. Executed, it is the CLI:
#   ada-pause.sh <minutes>        pause for that many minutes
#   ada-pause.sh until <epoch>    pause until that epoch second
#   ada-pause.sh forever          pause until resumed
#   ada-pause.sh resume           turn alerts back on
#   ada-pause.sh status           whether alerts are paused, and until when
#
# Environment:
#   ADA_PAUSE_FILE    the state file                (default $TMPDIR/ada-paused)
#   ADA_IGNORE_PAUSE  1 = this alert ignores a pause (the test alerts set it)
# =============================================================
set -u

__ada_pause_file() {
  printf '%s' "${ADA_PAUSE_FILE:-${TMPDIR:-/tmp}/ada-paused}"
}

# The end of the current pause: an epoch second, or 0 for "until resumed".
# Fails when there is no pause file or it isn't one of ours. The value is read
# as decimal, because bash arithmetic would take a leading 0 as octal.
__ada_pause_until() {
  local file value=""
  file=$(__ada_pause_file)
  [[ -f "$file" && ! -L "$file" ]] || return 1
  IFS= read -r value < "$file" || [[ -n "$value" ]] || return 1
  [[ "$value" =~ ^[0-9]{1,15}$ ]] || return 1
  printf '%s' "$(( 10#$value ))"
}

# True (0) while alerts are paused. An expired pause counts as over even though
# its file is still there: only the CLI deletes the file, because a launcher
# deleting it could race a new pause being renamed into place.
__ada_is_paused() {
  local until now
  until=$(__ada_pause_until) || return 1
  (( until == 0 )) && return 0
  now=${1:-$(date +%s)}
  (( now < until ))
}

# Replace the pause file with one holding $1. Refuses to replace a file that
# isn't a pause file, so a misdirected ADA_PAUSE_FILE can't clobber anything.
__ada_pause_write() {
  local file tmp
  file=$(__ada_pause_file)
  if [[ -e "$file" || -L "$file" ]] && ! __ada_pause_until >/dev/null; then
    echo "ada-pause: $file is not a pause file; left alone" >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")" || return 1
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if ! { printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# "15:30" today, "Fri 15:30" within a week, "2026-10-02 15:30" beyond that.
__ada_pause_when() {
  local until=$1 now=$2
  if [[ "$(date -r "$until" +%Y-%m-%d)" == "$(date -r "$now" +%Y-%m-%d)" ]]; then
    date -r "$until" +%H:%M
  elif (( until - now < 6 * 86400 )); then
    date -r "$until" '+%a %H:%M'
  else
    date -r "$until" '+%Y-%m-%d %H:%M'
  fi
}

__ada_pause_describe() {
  local until=$1 now=$2
  if (( until == 0 )); then
    echo "paused until resumed"
  else
    printf 'paused until %s (%s left)\n' "$(__ada_pause_when "$until" "$now")" \
      "$(__ada_format_duration $(( until - now )))"
  fi
}

__ada_pause_cli() {
  local action=${1:-status}
  shift 2>/dev/null
  local file until now
  file=$(__ada_pause_file)
  # Duration wording shared with the alerts themselves.
  # shellcheck source=lib/ada-notify.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ada-notify.sh"

  case "$action" in
    status)
      now=$(date +%s)
      if until=$(__ada_pause_until); then
        if (( until == 0 || now < until )); then
          __ada_pause_describe "$until" "$now"
          return 0
        fi
        rm -f "$file"
      elif [[ -e "$file" || -L "$file" ]]; then
        echo "ada-pause: $file is not a pause file; ignoring it" >&2
      fi
      echo "not paused"
      ;;
    resume)
      if __ada_pause_until >/dev/null; then
        rm -f "$file"
        echo "alerts resumed"
      elif [[ -e "$file" || -L "$file" ]]; then
        echo "ada-pause: $file is not a pause file; left alone" >&2
        return 1
      else
        echo "alerts were not paused"
      fi
      ;;
    forever)
      __ada_pause_write 0 || return 1
      echo "paused until resumed"
      ;;
    until)
      until=${1:-}
      [[ "$until" =~ ^[0-9]{1,15}$ ]] || { echo "ada-pause: until needs an epoch second, got '$until'" >&2; return 2; }
      until=$(( 10#$until ))
      now=$(date +%s)
      (( until > now )) || { echo "ada-pause: $until is not in the future" >&2; return 2; }
      __ada_pause_write "$until" || return 1
      __ada_pause_describe "$until" "$now"
      ;;
    -h|--help|help)
      sed -n '17,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      # A bare number of minutes, capped at a year.
      if [[ "$action" =~ ^[0-9]{1,6}$ ]] && (( 10#$action > 0 && 10#$action <= 525600 )); then
        now=$(date +%s)
        until=$(( now + 10#$action * 60 ))
        __ada_pause_write "$until" || return 1
        __ada_pause_describe "$until" "$now"
      else
        echo "ada-pause: unknown command: $action (try <minutes>, until, forever, resume, status)" >&2
        return 2
      fi
      ;;
  esac
}

# Executed directly -> CLI. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_pause_cli "$@"
fi
