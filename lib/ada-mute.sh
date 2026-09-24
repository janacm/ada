#!/bin/bash
# =============================================================
# ada-mute — "stop alerting me about this session"
# -------------------------------------------------------------
# The alert's "Mute this …" button signals the snooze daemon, which touches a
# marker file named after the session's key. From then on ada-show-alert.sh
# drops every alert (finish, error, permission) carrying that key. The check
# lives in the launcher, not in each integration, because every integration
# reaches the launcher: ada.sh, ada-notify.sh (Claude/Codex, opencode), the
# Paseo watcher, and the daemon's own snooze relaunch.
#
# A key is ADA_SESSION_KEY, set by the integration:
#   claude-<session_id>   Claude Code / Codex conversation
#   opencode-<sessionID>  opencode session
#   paseo-<agent id>      Paseo agent
#   zsh-<pid>-<epoch>     one interactive zsh (a terminal tab)
# Keys become file names, so anything outside [A-Za-z0-9._-] (or starting with
# a dot or dash) is refused and that alert simply has no mute button.
#
# Sourced by ada-show-alert.sh for the helpers below. Executed, it is the CLI:
#   ada-mute.sh list            muted keys and how long ago they were muted
#   ada-mute.sh clear [key...]  unmute the given keys, or every key
#   ada-mute.sh add <key>       mute a key by hand
#
# Environment:
#   ADA_MUTE_DIR      where markers live      (default $TMPDIR/ada-muted)
#   ADA_MUTE_MAX_AGE  seconds a mute lasts    (default 86400; 0 = until cleared)
# =============================================================
set -u

__ada_mute_dir() {
  printf '%s' "${ADA_MUTE_DIR:-${TMPDIR:-/tmp}/ada-muted}"
}

__ada_mute_max_age() {
  local age=${ADA_MUTE_MAX_AGE:-86400}
  [[ "$age" =~ ^[0-9]{1,15}$ ]] || age=86400
  # Force base 10: bash arithmetic reads "086400" as octal and fails on the 8,
  # which would make every mute look expired.
  printf '%s' "$(( 10#$age ))"
}

__ada_mute_key_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$ ]]
}

__ada_mute_file() {
  __ada_mute_key_ok "${1:-}" || return 1
  printf '%s/%s' "$(__ada_mute_dir)" "$1"
}

# True when the key's marker exists as a plain file, not a symlink.
# ADA_MUTE_DIR is user-configurable, so every read, write and delete goes
# through this: nothing else that happens to live there is ever touched.
__ada_mute_is_marker() {
  local file
  file=$(__ada_mute_file "${1:-}") || return 1
  [[ -f "$file" && ! -L "$file" ]]
}

# Seconds since the key was muted, or failure when it isn't muted at all.
__ada_mute_age() {
  local file mtime
  __ada_mute_is_marker "${1:-}" || return 1
  file=$(__ada_mute_file "$1")
  mtime=$(stat -f %m "$file" 2>/dev/null) || return 1
  printf '%s' $(( $(date +%s) - mtime ))
}

# True (0) when alerts for this key should be dropped. An expired marker counts
# as not muted even before the prune below gets to it.
__ada_is_muted() {
  local age max
  age=$(__ada_mute_age "${1:-}") || return 1
  max=$(__ada_mute_max_age)
  (( max == 0 || age <= max ))
}

# Every marker key in the mute dir (direct children only; see above).
__ada_mute_markers() {
  local dir file key
  dir=$(__ada_mute_dir)
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*; do
    key=${file##*/}
    __ada_mute_is_marker "$key" && printf '%s\n' "$key"
  done
  return 0
}

# Delete expired markers so the directory can't grow without bound.
__ada_mute_prune() {
  local key
  (( $(__ada_mute_max_age) > 0 )) || return 0
  while IFS= read -r key; do
    __ada_is_muted "$key" || rm -f "$(__ada_mute_file "$key")"
  done < <(__ada_mute_markers)
  return 0
}

__ada_mute_cli() {
  local action=${1:-list}
  shift 2>/dev/null
  local dir key file age max
  dir=$(__ada_mute_dir)

  case "$action" in
    list)
      __ada_mute_prune
      # Duration wording shared with the alerts themselves.
      # shellcheck source=lib/ada-notify.sh
      . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ada-notify.sh"
      local found=0
      while IFS= read -r key; do
        __ada_is_muted "$key" || continue
        age=$(__ada_mute_age "$key")
        printf '%s\tmuted %s ago\n' "$key" "$(__ada_format_duration "$age")"
        found=1
      done < <(__ada_mute_markers)
      (( found )) || echo "no muted sessions"
      ;;
    clear)
      if (( $# == 0 )); then
        while IFS= read -r key; do
          rm -f "$dir/$key"
        done < <(__ada_mute_markers)
        echo "unmuted every session"
        return 0
      fi
      for key in "$@"; do
        file=$(__ada_mute_file "$key") || { echo "ada-mute: invalid key: $key" >&2; return 1; }
        if __ada_mute_is_marker "$key"; then
          rm -f "$file"
        elif [[ -e "$file" || -L "$file" ]]; then
          echo "ada-mute: $file is not a mute marker; left alone" >&2
          return 1
        fi
        echo "unmuted $key"
      done
      ;;
    add)
      key=${1:-}
      file=$(__ada_mute_file "$key") || { echo "ada-mute: invalid key: $key" >&2; return 1; }
      if [[ ( -e "$file" || -L "$file" ) ]] && ! __ada_mute_is_marker "$key"; then
        echo "ada-mute: $file is not a mute marker; left alone" >&2
        return 1
      fi
      mkdir -p "$dir" && touch "$file" || return 1
      max=$(__ada_mute_max_age)
      if (( max == 0 )); then
        echo "muted $key until cleared"
      else
        echo "muted $key for ${max}s"
      fi
      ;;
    -h|--help|help)
      sed -n '20,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "ada-mute: unknown command: $action (try list, clear, add)" >&2
      return 2
      ;;
  esac
}

# Executed directly -> CLI. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_mute_cli "$@"
fi
