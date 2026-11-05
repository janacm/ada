#!/bin/bash
# =============================================================
# ada-update — say when a newer ada is out
# -------------------------------------------------------------
# A Homebrew install has a VERSION file at its root, which the formula writes.
# Once a day (ADA_UPDATE_INTERVAL), the first alert that shows starts
# `ada-update.sh check --background`. It downloads Formula/ada.rb from the tap's
# default branch, the formula `brew upgrade` installs, and reads the version
# out of its url line. Tags are not asked: release.sh pushes a tag before the
# formula bump that makes it installable, and a notice for a version brew
# can't install yet would send people to an upgrade that does nothing.
#
# The answer goes to one cache line, "<epoch> <latest|-> <ok|failed|checking>":
# when the last check started or ended, the newest version it found, and how it
# went. The launcher reads only that line and VERSION, with no forks, and puts
# update=<latest>&installed=<version> on the page when latest is newer. So an
# alert never waits on the network: the check it starts shows on a later one.
# The menu bar reads the same two files.
#
# The request is a plain HTTPS GET of a public file. It carries nothing about
# you or this Mac: no version, no id, no labels, no paths. ADA_UPDATE_CHECK=0,
# or `ada-update.sh off`, stops it and the notice with it. A checkout (no
# VERSION file) and a HEAD build (VERSION "HEAD-1a2b3c4") never check: they
# update with git, and their version says nothing a release could be newer than.
#
# Sourced by ada-show-alert.sh for __ada_update_note. Executed, it is the CLI:
#   ada-update.sh [status]          what the last check found (no network)
#   ada-update.sh check             check now, and say what it found
#   ada-update.sh off               stop checking, for every integration
#   ada-update.sh on                check again
#
# Environment:
#   ADA_UPDATE_CHECK     0 = never check and never show the notice
#   ADA_UPDATE_URL       the formula to read (https only; default: the
#                        janacm/ada tap's Formula/ada.rb on main)
#   ADA_UPDATE_FILE      the cache                     (default $TMPDIR/ada-update)
#   ADA_UPDATE_INTERVAL  seconds between checks        (default 86400); a check
#                        that failed or never finished is retried after an hour
#   ADA_UPDATE_OFF_FILE  the switch `off` writes  (default
#                        ~/.local/share/ada/update-check-off). It lives beside
#                        the Paseo env file, not in TMPDIR, so it lasts, and
#                        the LaunchAgents read it too, which an exported
#                        variable can't reach.
# =============================================================
set -u

ADA_UPDATE_DEFAULT_URL="https://raw.githubusercontent.com/janacm/ada/main/Formula/ada.rb"
# What the notice tells you to run. `brew update` first: `brew upgrade` only
# refreshes taps when its own auto-update is due, which can be a day away.
ADA_UPDATE_COMMAND="brew update && brew upgrade ada"

# This file's directory, without a fork: VERSION sits one level up.
__ada_update_libdir=${BASH_SOURCE[0]%/*}
[[ "$__ada_update_libdir" == "${BASH_SOURCE[0]}" ]] && __ada_update_libdir=.

# The cache and the off switch.
__ada_update_paths() {
  __ada_update_cache=${ADA_UPDATE_FILE:-${TMPDIR:-/tmp}/ada-update}
  __ada_update_off=${ADA_UPDATE_OFF_FILE:-$HOME/.local/share/ada/update-check-off}
}

# A release version: two to four dot-separated numbers ("0.5", "1.2.3").
__ada_update_version_ok() {
  [[ "${1:-}" =~ ^[0-9]{1,6}(\.[0-9]{1,6}){1,3}$ ]]
}

# __ada_update_newer <a> <b>: true when version a is newer than version b,
# number by number, a missing number counting as 0 (so 0.5.0 is not newer
# than 0.5, and 0.10 is newer than 0.9).
__ada_update_newer() {
  local a=$1 b=$2 x y
  while [[ -n "$a" || -n "$b" ]]; do
    x=${a%%.*}; y=${b%%.*}
    if [[ "$a" == *.* ]]; then a=${a#*.}; else a=""; fi
    if [[ "$b" == *.* ]]; then b=${b#*.}; else b=""; fi
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 1
}

# Checking is on unless ADA_UPDATE_CHECK=0 or the off switch exists.
__ada_update_enabled() {
  [[ "${ADA_UPDATE_CHECK:-1}" != 0 && ! -e "$__ada_update_off" && ! -L "$__ada_update_off" ]]
}

# Sets __ada_update_version to this install's version, or fails: no VERSION
# file (a checkout) or one that is no release version (a HEAD build).
__ada_update_installed() {
  local file="$__ada_update_libdir/../VERSION" v=""
  __ada_update_version=""
  [[ -f "$file" ]] || return 1
  read -r v < "$file" || [[ -n "$v" ]] || return 1
  __ada_update_version_ok "$v" || return 1
  __ada_update_version=$v
}

# Sets __ada_update_at (when the last check started or ended, 0 for never),
# __ada_update_latest (a version, or empty) and __ada_update_state (ok, failed,
# checking, or empty) from the cache. Like the pause file, only a plain file is
# read, and a line that doesn't parse reads as no check at all.
__ada_update_read() {
  local at="" latest="" state=""
  __ada_update_at=0; __ada_update_latest=""; __ada_update_state=""
  [[ -f "$__ada_update_cache" && ! -L "$__ada_update_cache" ]] || return 1
  read -r at latest state < "$__ada_update_cache" || [[ -n "$at" ]] || return 1
  [[ "$at" =~ ^[0-9]{1,11}$ ]] || return 1
  __ada_update_at=$at
  __ada_update_version_ok "$latest" && __ada_update_latest=$latest
  case "$state" in ok|failed|checking) __ada_update_state=$state ;; esac
  return 0
}

# __ada_update_write <epoch> <latest|-> <state>: replace the cache through a
# temp file and a rename, so a reader never sees half a line. Anything at that
# path that isn't a plain file (a symlink, a directory) is not ours and stays.
__ada_update_write() {
  local tmp
  [[ -L "$__ada_update_cache" ]] && return 1
  [[ -e "$__ada_update_cache" && ! -f "$__ada_update_cache" ]] && return 1
  tmp=$(mktemp "$__ada_update_cache.XXXXXX" 2>/dev/null) || return 1
  if printf '%s %s %s\n' "$1" "$2" "$3" > "$tmp" 2>/dev/null && mv -f "$tmp" "$__ada_update_cache" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# __ada_update_due <now>: true when a check is due, from what __ada_update_read
# found. A check that worked lasts ADA_UPDATE_INTERVAL; one that failed, or
# started and never wrote back, is retried after an hour (or the interval, if
# that is shorter), so a Mac offline at the day's first alert doesn't wait a
# day. A check stamped in the future (the clock was set back) is due now.
__ada_update_due() {
  local now=$1 wait=${ADA_UPDATE_INTERVAL:-86400}
  (( __ada_update_at > 0 )) || return 0
  [[ "$wait" =~ ^[0-9]{1,9}$ ]] || wait=86400
  wait=$(( 10#$wait ))
  [[ "$__ada_update_state" == ok ]] || (( wait <= 3600 )) || wait=3600
  (( now < __ada_update_at || now - __ada_update_at >= wait ))
}

# __ada_update_note [now]: for an alert about to show. Succeeds, with
# __ada_update_latest and __ada_update_version set, when the cache names a
# release newer than this install. Starts a background check when one is due;
# its answer is for a later alert. [now] is the epoch, when the caller has it:
# this forks only for the time without it, and to start a check.
__ada_update_note() {
  local now=${1:-}
  __ada_update_paths
  __ada_update_latest=""
  __ada_update_enabled || return 1
  __ada_update_installed || return 1
  __ada_update_read
  [[ "$now" =~ ^[0-9]{1,11}$ ]] || now=$(date +%s 2>/dev/null) || return 1
  if __ada_update_due "$now"; then
    "$__ada_update_libdir/ada-update.sh" check --background </dev/null >/dev/null 2>&1 3>&- &
  fi
  [[ -n "$__ada_update_latest" ]] && __ada_update_newer "$__ada_update_latest" "$__ada_update_version"
}

# Fetch the formula and print the version in its url line. Nothing but the URL
# goes out: no headers or data of ours, and curl may not leave https, even on a
# redirect. -q must come first, or curl reads the user's ~/.curlrc, whose
# header, user, data or url lines would ride along on this request.
__ada_update_fetch() {
  local url=${ADA_UPDATE_URL:-$ADA_UPDATE_DEFAULT_URL} body line found
  local re='^[[:space:]]*url[[:space:]]+"[^"]*/v?([0-9]+(\.[0-9]+)+)\.tar\.gz"'
  body=$(curl -q -fsSL --proto '=https' --proto-redir '=https' --max-time 15 "$url" 2>/dev/null) || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      # Copied first: the check below runs a regex of its own, which replaces
      # BASH_REMATCH.
      found=${BASH_REMATCH[1]}
      __ada_update_version_ok "$found" || return 1
      printf '%s\n' "$found"
      return 0
    fi
  done <<< "$body"
  return 1
}

# The check's lock: a directory beside the cache, which mkdir creates
# atomically, so of the checks that find one due only one fetches and writes.
# Without it two alerts arriving together each fetched, and on a first check
# one's "- failed" could land over the other's answer. A lock older than a
# minute was left by a check that died (a fetch gives up after 15 seconds), so
# it is taken over; rmdir only ever removes an empty directory. Anything else at
# that path (a file, a symlink) is not ours: no check runs while it is there.
__ada_update_lock() {
  local lock="$__ada_update_cache.lock" at now
  mkdir "$lock" 2>/dev/null && return 0
  [[ -d "$lock" && ! -L "$lock" ]] || return 1
  at=$(stat -f %m "$lock" 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  (( now - at > 60 )) || return 1
  rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null
}

__ada_update_unlock() {
  rmdir "$__ada_update_cache.lock" 2>/dev/null || true
}

# Check now, holding the lock (__ada_update_lock). Marks the check as running
# first, so alerts that show meanwhile don't start another, and keeps the last
# answer when this one fails.
__ada_update_check() {
  local now latest
  now=$(date +%s) || return 1
  __ada_update_read
  __ada_update_write "$now" "${__ada_update_latest:--}" checking || true
  if latest=$(__ada_update_fetch); then
    __ada_update_latest=$latest
    __ada_update_state=ok
  else
    __ada_update_state=failed
  fi
  now=$(date +%s) || return 1
  __ada_update_at=$now
  __ada_update_write "$now" "${__ada_update_latest:--}" "$__ada_update_state" || true
  [[ "$__ada_update_state" == ok ]]
}

# "just now", "5m ago", "3h ago", "2d ago".
__ada_update_ago() {
  local seconds=$(( $1 - $2 ))
  if (( seconds < 60 )); then printf 'just now'
  elif (( seconds < 3600 )); then printf '%dm ago' $(( seconds / 60 ))
  elif (( seconds < 86400 )); then printf '%dh ago' $(( seconds / 3600 ))
  else printf '%dd ago' $(( seconds / 86400 ))
  fi
}

# One line on what the cache says, for people.
__ada_update_report() {
  local now
  now=$(date +%s)
  if [[ -n "$__ada_update_latest" ]] && __ada_update_newer "$__ada_update_latest" "$__ada_update_version"; then
    printf 'ada %s is out (you have %s). Update with: %s\n' \
      "$__ada_update_latest" "$__ada_update_version" "$ADA_UPDATE_COMMAND"
  elif [[ "$__ada_update_state" == ok ]]; then
    printf 'ada %s is the latest release (checked %s).\n' \
      "$__ada_update_version" "$(__ada_update_ago "$now" "$__ada_update_at")"
  elif [[ "$__ada_update_state" == failed ]]; then
    printf 'ada %s. The last update check failed (%s); the next alert retries within an hour.\n' \
      "$__ada_update_version" "$(__ada_update_ago "$now" "$__ada_update_at")"
  elif [[ "$__ada_update_state" == checking ]]; then
    printf 'ada %s. An update check is running.\n' "$__ada_update_version"
  else
    printf 'ada %s. Not checked for updates yet: the next alert checks, or run: ada-update check\n' \
      "$__ada_update_version"
  fi
}

__ada_update_cli() {
  local action=${1:-status}
  __ada_update_paths
  case "$action" in
    status|check)
      if ! __ada_update_enabled; then
        if [[ "${ADA_UPDATE_CHECK:-1}" == 0 ]]; then
          [[ "${2:-}" == --background ]] || echo "Update checks are off (ADA_UPDATE_CHECK=0)."
        else
          [[ "${2:-}" == --background ]] || echo "Update checks are off. Turn them back on with: ada-update on"
        fi
        return 0
      fi
      if ! __ada_update_installed; then
        [[ "${2:-}" == --background ]] && return 0
        echo "Update checks are for Homebrew installs. Update a checkout with: git pull"
        return 0
      fi
      __ada_update_read
      if [[ "$action" == check ]]; then
        # The launcher's background check: one per due period, however many
        # alerts asked for it. A check already running has it covered, and one
        # that finished while this waited for the lock made it moot, so the
        # cache is read again once the lock is held.
        if [[ "${2:-}" == --background ]]; then
          __ada_update_due "$(date +%s)" || return 0
          __ada_update_lock || return 0
          trap __ada_update_unlock EXIT
          trap 'exit 130' INT TERM
          __ada_update_read
          __ada_update_due "$(date +%s)" && __ada_update_check
          return 0
        fi
        # Asked for by hand: wait out a check that is running (its fetch gives
        # up after 15 seconds), then check again.
        local tries=100 lock="$__ada_update_cache.lock"
        until __ada_update_lock; do
          if [[ ! -d "$lock" || -L "$lock" ]] && [[ -e "$lock" || -L "$lock" ]] || (( tries-- <= 0 )); then
            echo "ada-update: another update check holds $lock" >&2
            return 1
          fi
          sleep 0.2
        done
        trap __ada_update_unlock EXIT
        trap 'exit 130' INT TERM
        if ! __ada_update_check; then
          echo "ada-update: could not read ${ADA_UPDATE_URL:-$ADA_UPDATE_DEFAULT_URL}" >&2
          return 1
        fi
      fi
      __ada_update_report
      ;;
    off)
      if [[ -L "$__ada_update_off" ]] || [[ -e "$__ada_update_off" && ! -f "$__ada_update_off" ]]; then
        echo "ada-update: $__ada_update_off exists and is not ada's; leaving it alone" >&2
        return 1
      fi
      mkdir -p "${__ada_update_off%/*}" 2>/dev/null
      if ! : > "$__ada_update_off" 2>/dev/null; then
        echo "ada-update: could not write $__ada_update_off" >&2
        return 1
      fi
      echo "Update checks are off. ada will not look for new releases or show the notice."
      echo "Turn them back on with: ada-update on"
      ;;
    on)
      if [[ -f "$__ada_update_off" && ! -L "$__ada_update_off" ]]; then
        rm -f "$__ada_update_off"
      elif [[ -e "$__ada_update_off" || -L "$__ada_update_off" ]]; then
        echo "ada-update: $__ada_update_off exists and is not ada's; leaving it alone" >&2
        return 1
      fi
      if [[ "${ADA_UPDATE_CHECK:-1}" == 0 ]]; then
        echo "Update checks stay off while ADA_UPDATE_CHECK=0 is set."
      else
        echo "Update checks are on. The next alert checks if one is due."
      fi
      ;;
    -h|--help|help)
      sed -n '26,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      echo "ada-update: unknown command: $action (try status, check, off, on)" >&2
      return 2
      ;;
  esac
}

# Executed directly -> the CLI. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_update_cli "$@"
fi
