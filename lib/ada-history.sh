#!/bin/bash
# =============================================================
# ada-history — the alerts ada raised, oldest first
# -------------------------------------------------------------
# ada-show-alert.sh appends one line for every alert it decides on: shown, or
# dropped by a pause or a mute. The menu bar's Recent Alerts reads it, so an
# alert dropped while you were paused is still one click from its conversation.
#
# Format v1: one line per alert, tab-separated, the version first so a reader
# can skip lines it doesn't know and ignore columns added after the last one:
#   1  epoch  outcome  snoozed  key  kind  label  duration  code  repo  focus_app  focus_app_name  click_url
# outcome is shown, paused or muted; snoozed is 1 for a snooze relaunch. Tabs
# and line breaks inside a field become spaces, and a field is cut to 200
# characters (the click URL to 500).
#
# The labels are your prompts and commands, so the file is created mode 600 and
# never written through a symlink or when someone else owns it. It stays on
# this machine, under $TMPDIR, trimmed to the newest ADA_HISTORY_MAX lines.
#
# Sourced by ada-show-alert.sh for the helpers below. Executed, it is the CLI:
#   ada-history.sh list    every line, oldest first
#   ada-history.sh clear   forget them
#
# Environment:
#   ADA_HISTORY_FILE  where it lives   (default $TMPDIR/ada-history.tsv)
#   ADA_HISTORY_MAX   lines kept       (default 50; 0 keeps no history)
# =============================================================
set -u

__ada_history_file() {
  printf '%s' "${ADA_HISTORY_FILE:-${TMPDIR:-/tmp}/ada-history.tsv}"
}

__ada_history_max() {
  local max=${ADA_HISTORY_MAX:-50}
  [[ "$max" =~ ^[0-9]{1,6}$ ]] || max=50
  printf '%s' "$(( 10#$max ))"
}

# True when the history file may be written: absent, or a regular file of ours.
__ada_history_writable() {
  local file=$1
  [[ -L "$file" ]] && return 1
  [[ -e "$file" ]] || return 0
  [[ -f "$file" && -O "$file" ]]
}

# Append one field to __ada_history_line: tabs and line breaks become spaces,
# cut to $2 characters. It appends rather than prints so that building a line
# costs no subshells.
__ada_history_add() {
  local value=${1:-} limit=${2:-200}
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  __ada_history_line+=$'\t'"${value:0:$limit}"
}

# Keep the newest MAX lines once the file reaches twice that, so an alert only
# pays for a rewrite every MAX alerts. A line appended during the rewrite can be
# lost; history is a convenience, not a record.
__ada_history_trim() {
  local file=$1 max=$2 lines tmp
  lines=$(wc -l < "$file" 2>/dev/null) || return 0
  (( lines > 2 * max )) || return 0
  tmp=$(mktemp "$file.XXXXXX") || return 0
  if ! { tail -n "$max" "$file" > "$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
  fi
  return 0
}

# __ada_history_record <outcome> <key> <kind> <label> <duration> <code> <repo>
#                      <focus_app> <focus_app_name> <click_url>
# Never fails: a history problem must not cost the alert.
__ada_history_record() {
  local file max snoozed=0 field
  max=$(__ada_history_max)
  (( max > 0 )) || return 0
  file=$(__ada_history_file)
  __ada_history_writable "$file" || return 0
  [[ -n "${ADA_SNOOZED:-}" ]] && snoozed=1
  __ada_history_line="1"$'\t'"$(date +%s)"
  __ada_history_add "${1:-}"
  __ada_history_line+=$'\t'"$snoozed"
  for field in "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}"; do
    __ada_history_add "$field"
  done
  __ada_history_add "${10:-}" 500
  if [[ ! -e "$file" ]]; then
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    ( umask 077; : >> "$file" ) 2>/dev/null || return 0
  fi
  # One write of one short line: appends from concurrent launchers don't mix.
  printf '%s\n' "$__ada_history_line" >> "$file" 2>/dev/null || return 0
  __ada_history_trim "$file" "$max"
}

__ada_history_cli() {
  local action=${1:-list} file
  file=$(__ada_history_file)
  case "$action" in
    list)
      [[ -f "$file" && ! -L "$file" ]] && cat "$file"
      return 0
      ;;
    clear)
      if [[ -f "$file" && ! -L "$file" ]]; then
        rm -f "$file"
        echo "history cleared"
      elif [[ -e "$file" || -L "$file" ]]; then
        echo "ada-history: $file is not a history file; left alone" >&2
        return 1
      else
        echo "no history"
      fi
      ;;
    -h|--help|help)
      sed -n '20,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "ada-history: unknown command: $action (try list, clear)" >&2
      return 2
      ;;
  esac
}

# Executed directly -> CLI. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_history_cli "$@"
fi
