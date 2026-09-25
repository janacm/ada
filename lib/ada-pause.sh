#!/bin/bash
# =============================================================
# ada-pause — "no alerts for a while"
# -------------------------------------------------------------
# One switch that silences every alert, from every integration, until a given
# time or until resumed. Like muting, it is enforced only in ada-show-alert.sh,
# the launcher every integration reaches (ada.sh, ada-notify.sh, the Paseo
# watcher) and the snooze daemon's relaunch re-enters. The menu bar's Pause
# menu, the alert's "Pause all alerts" and this CLI set the same switch.
#
# The state is one file holding one integer: the epoch second the pause ends,
# or 0 for "until resumed". No file means alerts are on. A file holding
# anything else is not ours: it pauses nothing and is never overwritten or
# deleted. Writes go to a temp file renamed into place, so a reader never sees
# half a number.
#
# An alert that arrives while paused is kept, not lost: the launcher writes its
# history line (lib/ada-history.sh) as one file in <pause file>.held/. When the
# pause ends, they are shown together in one summary alert. Three events end a
# pause that way: a timed pause's timer runs out, `resume`, or a later alert
# finds the pause over with records left. Each runs the launcher with
# ADA_PAUSE_FLUSH, which claims the directory with one rename to
# <pause file>.claim.<epoch>.<pid>/ and shows what it took.
#
# Sourced by ada-show-alert.sh for the helpers below. Executed, it is the CLI:
#   ada-pause.sh <minutes>        pause for that many minutes
#   ada-pause.sh until <epoch>    pause until that epoch second
#   ada-pause.sh forever          pause until resumed
#   ada-pause.sh resume           turn alerts back on
#   ada-pause.sh status           whether alerts are paused, and until when
# resume also shows what arrived while paused, as one summary alert.
#
# Environment:
#   ADA_PAUSE_FILE    the state file                (default $TMPDIR/ada-paused)
#   ADA_IGNORE_PAUSE  1 = this alert ignores a pause (the test alerts set it)
#   ADA_PAUSE_TIMER   0 = a timed pause starts no timer, so its summary waits
#                     for resume or the next alert (the test suite sets it)
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

# --- what arrives while paused -------------------------------------------------
# <pause file>.held/ holds one file per alert the pause kept off the screen,
# <epoch>.<pid>.<random>.tsv, containing that alert's history line. Only a real
# directory we own counts: anything else at that path is never written into,
# claimed or deleted, and the alert simply shows. Past 500 records an alert
# adds one byte to held/overflow instead, so a runaway agent costs a counter,
# not a file per turn. The helpers below name paths with printf -v and glob with
# builtins, because the launcher runs them for every alert.

__ada_pause_held_dir() {
  printf -v "$1" '%s.held' "${ADA_PAUSE_FILE:-${TMPDIR:-/tmp}/ada-paused}"
}

# True when <dir> may hold records: a real directory, not a symlink, of ours.
__ada_pause_dir_ok() {
  [[ -d "$1" && ! -L "$1" && -O "$1" ]]
}

# True when some alert is waiting for a summary.
__ada_pause_has_held() {
  local dir f
  __ada_pause_held_dir dir
  __ada_pause_dir_ok "$dir" || return 1
  for f in "$dir"/*.tsv "$dir/overflow"; do
    [[ -f "$f" && ! -L "$f" ]] && return 0
  done
  return 1
}

# __ada_pause_count <var>: how many alerts are waiting, the overflow included.
__ada_pause_count() {
  local __ada_pc_dir __ada_pc_f __ada_pc_n=0 __ada_pc_size
  __ada_pause_held_dir __ada_pc_dir
  if __ada_pause_dir_ok "$__ada_pc_dir"; then
    for __ada_pc_f in "$__ada_pc_dir"/*.tsv; do
      [[ -f "$__ada_pc_f" && ! -L "$__ada_pc_f" ]] && __ada_pc_n=$(( __ada_pc_n + 1 ))
    done
    if [[ -f "$__ada_pc_dir/overflow" && ! -L "$__ada_pc_dir/overflow" ]]; then
      __ada_pc_size=$(stat -f %z "$__ada_pc_dir/overflow" 2>/dev/null) || __ada_pc_size=0
      [[ "$__ada_pc_size" =~ ^[0-9]{1,15}$ ]] && __ada_pc_n=$(( __ada_pc_n + 10#$__ada_pc_size ))
    fi
  fi
  printf -v "$1" '%s' "$__ada_pc_n"
}

# __ada_pause_hold <history line>: keep one record for this alert. Sets
# __ada_pause_rec to the record's path, or to "" when the alert only counted
# toward the overflow. Fails when nothing was kept, and then the alert shows.
# The record is written under a dot name and renamed into place, so a flush
# never reads half a line; if the directory is renamed away mid-write, the
# rename fails and the alert counts as not kept.
__ada_pause_hold() {
  local dir name epoch n=0 f
  __ada_pause_rec=""
  __ada_pause_held_dir dir
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    mkdir -m 700 "$dir" 2>/dev/null
  fi
  __ada_pause_dir_ok "$dir" || return 1
  for f in "$dir"/*.tsv; do
    [[ -f "$f" ]] && n=$(( n + 1 ))
  done
  if (( n >= 500 )); then
    [[ -L "$dir/overflow" ]] && return 1
    printf 'x' >> "$dir/overflow" 2>/dev/null
    return
  fi
  epoch=${1#*$'\t'}
  epoch=${epoch%%$'\t'*}
  name="$epoch.$$.$RANDOM.tsv"
  if ! printf '%s\n' "$1" > "$dir/.$name.tmp" 2>/dev/null; then
    rm -f "$dir/.$name.tmp"
    return 1
  fi
  if ! mv -f "$dir/.$name.tmp" "$dir/$name" 2>/dev/null; then
    rm -f "$dir/.$name.tmp"
    return 1
  fi
  __ada_pause_rec="$dir/$name"
}

# __ada_pause_gate <history line>: the launcher's pause decision for one alert,
# made while paused. Returns 0 when the alert is held (it will be in the
# summary) and 1 when it should show now.
#
# The record goes in first and the pause is checked again after, because the
# pause can end in between, and a flush that already ran would never see a
# record written after it. Still paused: the record waits. Over: this launcher
# takes its own record back with rm and shows the alert. That rm can only fail
# because a flush renamed the directory first, and a flush claims only once it
# has seen the pause over itself, so the record is in that summary. Either way
# the alert lands exactly once. The overflow byte skips the recheck: only the
# count is at stake there.
__ada_pause_gate() {
  __ada_pause_hold "$1" || return 1
  [[ -n "$__ada_pause_rec" ]] || return 0
  __ada_is_paused && return 0
  rm "$__ada_pause_rec" 2>/dev/null && return 1
  return 0
}

# __ada_pause_arm <end epoch>: start the timer that shows the summary when this
# pause runs out, a detached `ada-snooze-daemon.py --pause-timer`. It checks the
# pause file at least every 10s by the wall clock and gives up as soon as the
# file holds another value, so a newer pause or a resume retires it. Nothing
# happens without python3 or the daemon beside this script; the summary then
# waits for resume or the next alert.
__ada_pause_arm() {
  local here
  [[ "${ADA_PAUSE_TIMER:-1}" == 0 ]] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f "$here/ada-snooze-daemon.py" && -f "$here/ada-show-alert.sh" ]] || return 0
  # Every descriptor closed or on /dev/null: the timer can outlive its caller
  # by hours, and must not hold a pipe the caller is reading (the menu bar
  # waits for its script's stderr, bats for fd 3).
  python3 "$here/ada-snooze-daemon.py" --pause-timer "$1" "$(__ada_pause_file)" \
    "$here/ada-show-alert.sh" </dev/null >/dev/null 2>&1 3>&- &
  return 0
}

# __ada_pause_resume_cmd <var>: the command that ends the pause on this
# install, for the alert to show: `ada-pause resume` when that is on PATH (the
# Homebrew wrapper), else this script's own path, with ~ for the home folder.
__ada_pause_resume_cmd() {
  local __ada_rc_src=${BASH_SOURCE[0]} __ada_rc_home=${HOME:-} __ada_rc_q
  if type -P ada-pause >/dev/null 2>&1; then
    printf -v "$1" '%s' "ada-pause resume"
    return 0
  fi
  [[ "$__ada_rc_src" == /* ]] || __ada_rc_src="$PWD/$__ada_rc_src"
  if [[ -n "$__ada_rc_home" && "$__ada_rc_src" == "$__ada_rc_home"/* ]]; then
    printf -v __ada_rc_q '%q' "${__ada_rc_src#"$__ada_rc_home"/}"
    # shellcheck disable=SC2088  # a literal ~, for the page to show
    printf -v "$1" '~/%s resume' "$__ada_rc_q"
  else
    printf -v __ada_rc_q '%q' "$__ada_rc_src"
    printf -v "$1" '%s resume' "$__ada_rc_q"
  fi
}

# __ada_pause_summary <ended|resumed> <end epoch>: claim what the pause held
# and print the summary alert's payload. Line 1 is the base64url JSON the page
# reads (summaryb64; the format is in the launcher's header). Line 2 is the
# click targets for the snooze daemon's open/<i>, a JSON list aligned with the
# rows, or empty when no row can open anything. Prints nothing when nothing is
# left to show. ADA_MUTED_KEYS (one key per line) names the sessions muted
# since, whose records are dropped here; the launcher owns the mute rule.
#
# The claim is one rename of held/ to claim.<epoch>.<pid>/, so of two flushes
# only one gets the records. A claim older than 10 minutes belongs to a flush
# that died; this one takes it with a rename of its own and shows it too.
# Without python3 nothing is claimed, and the records wait for a flush that
# has it.
__ada_pause_summary() {
  local dir
  command -v python3 >/dev/null 2>&1 || return 0
  __ada_pause_held_dir dir
  python3 - "$dir" "${1:-ended}" "${2:-}" 2>/dev/null <<'PY'
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time

held, why, end = sys.argv[1:4]
base = held[: -len(".held")]
now = int(time.time())
end = int(end) if re.fullmatch(r"[0-9]{1,15}", end) else now
if why not in ("ended", "resumed"):
    why = "ended"
uid = os.getuid()
ROWS, LIMIT = 30, 12000
URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:[^\x00-\x1f\x7f]*")
APP = re.compile(r"[A-Za-z0-9.-]{1,255}")


def ours(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == uid


# Claims a flush left behind when it died, then this flush's own. A stale
# claim is taken with its own rename, as held/ is, so of two flushes that both
# list it only one shows it. Its new name carries this flush's epoch: if this
# flush dies too, the next one takes it 10 minutes later.
claims = []
parent, prefix = os.path.split(base)
prefix += ".claim."
try:
    names = os.listdir(parent or ".")
except OSError:
    names = []
for name in names:
    m = re.fullmatch(re.escape(prefix) + r"([0-9]{1,15})\.[0-9]+(?:\.[0-9]+)?", name)
    path = os.path.join(parent, name)
    if m and now - int(m.group(1)) > 600 and ours(path):
        taken = os.path.join(parent, "%s%d.%d.%d" % (prefix, now, os.getpid(), len(claims)))
        try:
            os.rename(path, taken)
        except OSError:
            continue
        claims.append(taken)
if ours(held):
    mine = os.path.join(parent, "%s%d.%d" % (prefix, now, os.getpid()))
    try:
        os.rename(held, mine)
        claims.append(mine)
    except OSError:
        pass
if not claims:
    sys.exit(0)

muted = set(os.environ.get("ADA_MUTED_KEYS", "").split())
rows, extra = [], 0
for claim in claims:
    try:
        entries = sorted(os.listdir(claim))
    except OSError:
        continue
    for name in entries:
        path = os.path.join(claim, name)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if name.startswith(".") or not stat.S_ISREG(st.st_mode):
            continue
        if name == "overflow":
            extra += st.st_size
            continue
        if not name.endswith(".tsv") or st.st_size > 8192:
            continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as f:
                line = f.read(8192).decode("utf-8", "replace").split("\n", 1)[0]
        except OSError:
            continue
        f = line.split("\t")
        if len(f) < 13 or f[0] != "1" or not re.fullmatch(r"[0-9]{1,15}", f[1]):
            continue
        if f[4] and f[4] in muted:
            continue
        rows.append((f + [""] * 14)[:14])
for claim in claims:
    shutil.rmtree(claim, ignore_errors=True)
total = len(rows) + extra
if not total:
    sys.exit(0)


# Needs you, failed, finished: the label shapes the integrations use.
def status(f):
    label, duration, code = f[6], f[7], f[8]
    if duration == "permission" or label.startswith("\U0001f510 Needs permission"):
        return "ask"
    if code != "0" or label.startswith("⚠️ Error"):
        return "fail"
    return "ok"


rows.sort(key=lambda f: int(f[1]))
# Totals for the subtitle, taken before the cap and the trim below drop rows.
asks = sum(1 for f in rows if status(f) == "ask")
fails = sum(1 for f in rows if status(f) == "fail")
urgent = [f for f in rows if status(f) == "ask"] + [f for f in rows if status(f) == "fail"]
urgent = urgent[:ROWS]
done = [f for f in rows if status(f) == "ok"]
room = ROWS - len(urgent)
done = done[-room:] if room > 0 else []

repos = {}


def repo_of(f):
    if f[9]:
        return f[9]
    where = f[13]
    if not where.startswith("/"):
        return ""
    # A LaunchAgent of ours (the menu bar resuming) must not look under the
    # home folder: ~/Documents and friends would raise a privacy prompt. The
    # rule and its switch are the status report's (lib/ada-status.sh).
    agent = os.environ.get("XPC_SERVICE_NAME", "").startswith("com.ada.") \
        or os.environ.get("ADA_STATUS_SKIP_PROTECTED") == "1"
    if agent and (where.startswith(os.path.expanduser("~") + "/") or where.startswith("/Volumes/")):
        return ""
    if where not in repos:
        try:
            out = subprocess.run(["git", "-C", where, "rev-parse", "--show-toplevel"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=2)
            top = out.stdout.decode("utf-8", "replace").strip() if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            top = ""
        repos[where] = os.path.basename(top)
    return repos[where]


def target_of(f):
    url, app = f[12], f[10]
    if url and len(url) <= 2048 and URL.fullmatch(url):
        return {"url": url}
    if app and APP.fullmatch(app):
        return {"app": app}
    return None


def build(chosen):
    items, targets = [], []
    for f in chosen:
        target = target_of(f)
        targets.append(target)
        items.append({"t": int(f[1]), "l": f[6][:120], "d": f[7], "c": f[8],
                      "r": repo_of(f), "k": f[5], "s": status(f),
                      "z": 1 if f[3] == "1" else 0, "o": 1 if target else 0,
                      "a": f[11]})
    text = json.dumps({"v": 1, "n": total, "why": why, "end": end, "ask": asks, "fail": fails,
                       "items": items}, ensure_ascii=False, separators=(",", ":"))
    return base64.urlsafe_b64encode(text.encode("utf-8")).decode().rstrip("="), targets


# The payload rides in a file:// URL, so it is kept short: the oldest finished
# rows go first, then the newest of the rest.
while True:
    payload, targets = build(urgent + done)
    if len(payload) <= LIMIT or not (urgent or done):
        break
    if done:
        done.pop(0)
    else:
        urgent.pop()
print(payload)
if any(targets):
    print(json.dumps(targets, separators=(",", ":")))
PY
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

# "1 alert", "3 alerts".
__ada_pause_alerts() {
  if (( $1 == 1 )); then printf '1 alert'; else printf '%s alerts' "$1"; fi
}

# Show what the pause held as one summary alert, through the launcher beside
# this script. Its output is the alert window, not text.
__ada_pause_flush() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  ADA_PAUSE_FLUSH=$1 /bin/bash "$here/ada-show-alert.sh" '' '' 0 </dev/null >/dev/null 3>&-
}

__ada_pause_cli() {
  local action=${1:-status}
  shift 2>/dev/null
  local file until now held line paused
  file=$(__ada_pause_file)
  # Duration wording shared with the alerts themselves.
  # shellcheck source=lib/ada-notify.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ada-notify.sh"
  __ada_pause_count held

  case "$action" in
    status)
      now=$(date +%s)
      if until=$(__ada_pause_until); then
        if (( until == 0 || now < until )); then
          line=$(__ada_pause_describe "$until" "$now")
          (( held > 0 )) && line+=" · $(__ada_pause_alerts "$held") held"
          echo "$line"
          return 0
        fi
        rm -f "$file"
      elif [[ -e "$file" || -L "$file" ]]; then
        echo "ada-pause: $file is not a pause file; ignoring it" >&2
      fi
      if (( held > 0 )); then
        echo "not paused · $(__ada_pause_alerts "$held") held from an ended pause (resume shows them)"
      else
        echo "not paused"
      fi
      ;;
    resume)
      if __ada_pause_until >/dev/null; then
        rm -f "$file"
        paused=1
      elif [[ -e "$file" || -L "$file" ]]; then
        echo "ada-pause: $file is not a pause file; left alone" >&2
        return 1
      else
        paused=0
      fi
      # Counted again now that the pause is gone: an alert held between the
      # count above and the rm is waiting in held/, and no timer will show it
      # (it takes a missing file for a resume).
      __ada_pause_count held
      if (( held == 0 )); then
        if (( paused )); then echo "alerts resumed · nothing arrived while paused"; else echo "alerts were not paused"; fi
        return 0
      fi
      if (( paused )); then line="alerts resumed"; else line="not paused"; fi
      if ! command -v python3 >/dev/null 2>&1; then
        if (( held == 1 )); then
          echo "$line · 1 held alert needs python3 to show"
        else
          echo "$line · $held held alerts need python3 to show"
        fi
        return 0
      fi
      if (( paused )); then
        if (( held == 1 )); then
          echo "$line · showing the 1 alert that arrived while paused"
        else
          echo "$line · showing the $held alerts that arrived while paused"
        fi
      else
        echo "$line · showing $(__ada_pause_alerts "$held") held from an earlier pause"
      fi
      __ada_pause_flush resumed
      return 0
      ;;
    forever)
      __ada_pause_write 0 || return 1
      line="paused until resumed"
      (( held > 0 )) && line+=" · $(__ada_pause_alerts "$held") held so far"
      echo "$line"
      ;;
    until)
      until=${1:-}
      [[ "$until" =~ ^[0-9]{1,15}$ ]] || { echo "ada-pause: until needs an epoch second, got '$until'" >&2; return 2; }
      until=$(( 10#$until ))
      now=$(date +%s)
      (( until > now )) || { echo "ada-pause: $until is not in the future" >&2; return 2; }
      __ada_pause_write "$until" || return 1
      __ada_pause_arm "$until"
      line=$(__ada_pause_describe "$until" "$now")
      (( held > 0 )) && line+=" · $(__ada_pause_alerts "$held") held so far"
      echo "$line"
      ;;
    -h|--help|help)
      sed -n '25,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *)
      # A bare number of minutes, capped at a year.
      if [[ "$action" =~ ^[0-9]{1,6}$ ]] && (( 10#$action > 0 && 10#$action <= 525600 )); then
        now=$(date +%s)
        until=$(( now + 10#$action * 60 ))
        __ada_pause_write "$until" || return 1
        __ada_pause_arm "$until"
        line=$(__ada_pause_describe "$until" "$now")
        (( held > 0 )) && line+=" · $(__ada_pause_alerts "$held") held so far"
        echo "$line"
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
