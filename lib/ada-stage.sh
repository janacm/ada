#!/bin/bash
# =============================================================
# ada-stage — what the LaunchAgent front doors share
# -------------------------------------------------------------
# ada-paseo-watch.sh and ada-menubar.sh each install a LaunchAgent, and
# a LaunchAgent cannot exec anything under a TCC-protected folder (~/Documents,
# ~/Desktop, ~/Downloads, or a symlink into one), nor can anything it starts.
# So a dev checkout is staged into one per-user directory (~/.local/share/ada)
# that every job shares, while a Homebrew install runs in place from its
# version-stable opt path, where `brew upgrade` keeps it current.
#
# Sourced by the front doors for install, uninstall and status; the `run` path
# a LaunchAgent executes never needs it. ada-install.sh sources it for the
# helper staleness check. Nothing here runs on its own.
# =============================================================

# Every file a staged job reaches for, relative to the runtime root. One list
# for every job, because they share one stage: a job staged with a shorter list
# silently loses whatever its scripts source (a staged `ada-mute.sh list` once
# failed for want of ada-notify.sh). The installer, ada.sh, the Claude hook and
# the opencode plugin are deliberately absent: a staged installer would wire
# integrations to the stage.
ADA_RUNTIME_FILES=(ada-paseo-watch.sh ada-menubar.sh alert.html
                   lib/ada-paseo-watch.py lib/ada-show-alert.sh
                   lib/ada-snooze-daemon.py lib/ada-mute.sh lib/ada-pause.sh
                   lib/ada-history.sh lib/ada-notify.sh lib/ada-stage.sh
                   lib/ada-status.sh)

# True when <dir> is a Homebrew install: under $(brew --prefix)/opt, which is
# outside every TCC root and survives upgrades, so launchd can run it in place.
# Staging it would freeze a snapshot `brew upgrade` could never refresh.
__ada_from_brew_prefix() {
  local dir=$1 prefix=${HOMEBREW_PREFIX:-}
  [[ -n "$prefix" ]] || prefix=$(brew --prefix 2>/dev/null) || return 1
  [[ -n "$prefix" ]] || return 1
  [[ "$dir" == "$prefix/opt/"* ]]
}

# What a helper is called in progress messages.
__ada_helper_noun() {
  case "$1" in
    ada-alert) printf 'native alert helper' ;;
    *) printf '%s helper' "$1" ;;
  esac
}

# The built <product> in <dir>: <dir>/<product>, then the SwiftPM release and
# debug outputs. ADA_NATIVE_ALERT, when set, is the ada-alert to use.
__ada_find_helper() {
  local dir=$1 product=$2 override="" f
  [[ "$product" == ada-alert ]] && override=${ADA_NATIVE_ALERT:-}
  for f in "$override" "$dir/$product" \
           "$dir/.build/release/$product" "$dir/.build/debug/$product"; do
    [[ -n "$f" && -x "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# True when <helper> is a SwiftPM build of the checkout <dir> that is older than
# the checkout's Swift sources: a `git pull` brought in helper changes (a new
# message handler, say) since the last build, and copying or using the old
# binary would silently drop them. Only a .build/ output counts; a prebuilt
# <dir>/<product> (Homebrew's, inside a read-only keg) or any other path is used
# as-is. ADA_REBUILD_HELPER=0 turns the check off, which the test suite does so
# a run from a dev checkout never kicks off a real swift build.
__ada_helper_stale() {
  local dir=$1 helper=$2
  [[ "${ADA_REBUILD_HELPER:-1}" != 0 ]] || return 1
  case "$helper" in "$dir"/.build/*) ;; *) return 1 ;; esac
  [[ -f "$dir/Package.swift" ]] || return 1
  [[ "$dir/Package.swift" -nt "$helper" ]] && return 0
  [[ -d "$dir/Sources" ]] || return 1
  [[ -n "$(find "$dir/Sources" -name '*.swift' -newer "$helper" -print -quit 2>/dev/null)" ]]
}

# The <product> a stage should copy from <dir>, printed on stdout. A missing
# helper is built, and one older than the Swift sources rebuilt. A failed
# rebuild still hands back the old helper, with a warning: it works, it just
# lacks what the newer sources added. Messages go to stderr, prefixed <who>.
__ada_stage_helper() {
  local who=$1 dir=$2 product=$3 helper="" stale=0 noun
  noun=$(__ada_helper_noun "$product")
  helper=$(__ada_find_helper "$dir" "$product") || helper=""
  [[ -n "$helper" ]] && __ada_helper_stale "$dir" "$helper" && stale=1
  if [[ ( -z "$helper" || "$stale" == 1 ) && -f "$dir/Package.swift" ]] \
     && command -v swift >/dev/null 2>&1; then
    if [[ "$stale" == 1 ]]; then
      echo "Rebuilding $noun (Swift sources changed since the last build)..." >&2
    else
      echo "Building $noun..." >&2
    fi
    if (cd "$dir" && swift build -c release --product "$product" >/dev/null 2>&1) \
       && [[ -x "$dir/.build/release/$product" ]]; then
      # SwiftPM leaves an up-to-date binary untouched; stamp it so a touched but
      # unchanged source doesn't trigger a rebuild on every install.
      touch "$dir/.build/release/$product"
      helper="$dir/.build/release/$product"
    else
      echo "$who: native helper build failed." >&2
    fi
  fi
  if [[ -z "$helper" ]]; then
    echo "$who: native helper $product is required." >&2
    echo "  Build it with: swift build -c release --product $product" >&2
    return 1
  fi
  if [[ "$stale" == 1 ]] && __ada_helper_stale "$dir" "$helper"; then
    echo "$who: staging the older $helper; rebuild with: swift build -c release --product $product" >&2
  fi
  printf '%s' "$helper"
}

# Replace <dst> with a copy of <src> by renaming a temp copy into place. A plain
# cp rewrites the file in place, and a staged binary may be running (the menu
# bar always is, and an alert may be up) or a staged script mid-read by bash.
# A rename leaves them their old file. Same file already: nothing to do.
__ada_stage_copy() {
  local src=$1 dst=$2 tmp
  [[ "$src" -ef "$dst" ]] && return 0
  mkdir -p "$(dirname "$dst")" || return 1
  tmp=$(mktemp "$dst.XXXXXX") || return 1
  if cp -p "$src" "$tmp" && mv -f "$tmp" "$dst"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# What was staged from where, for status and for the menu bar, which can read
# this without touching the checkout (it may be under ~/Documents).
__ada_stage_info() {
  local who=$1 src=$2 rev="" dirty=""
  if rev=$(git -C "$src" rev-parse --short HEAD 2>/dev/null); then
    if [[ -n "$(git -C "$src" status --porcelain 2>/dev/null)" ]]; then dirty=1; else dirty=0; fi
  else
    rev=""
  fi
  printf 'source=%s\nrev=%s\ndirty=%s\nstaged_at=%s\nby=%s\n' "$src" "$rev" "$dirty" "$(date +%s)" "$who"
}

# Stage the runtime from checkout <src> into <dst>: the given helper products,
# then every file in ADA_RUNTIME_FILES that <src> has (lib/ first, so a front
# door never lands before the scripts it calls), then stage-info.
__ada_stage_runtime() {
  local who=$1 src=$2 dst=$3 product helper f
  shift 3
  mkdir -p "$dst/lib" || return 1
  for product in "$@"; do
    helper=$(__ada_stage_helper "$who" "$src" "$product") || return 1
    __ada_stage_copy "$helper" "$dst/$product" || return 1
  done
  for f in "${ADA_RUNTIME_FILES[@]}"; do
    [[ "$f" == lib/* && -f "$src/$f" ]] || continue
    __ada_stage_copy "$src/$f" "$dst/$f" || return 1
  done
  for f in "${ADA_RUNTIME_FILES[@]}"; do
    [[ "$f" != lib/* && -f "$src/$f" ]] || continue
    __ada_stage_copy "$src/$f" "$dst/$f" || return 1
  done
  if ! [[ "$src" -ef "$dst" ]]; then
    __ada_stage_info "$who" "$src" > "$dst/stage-info.tmp" && mv -f "$dst/stage-info.tmp" "$dst/stage-info"
  fi
}

# True when the stage <dst> no longer matches checkout <src>: a runtime file or
# one of the given helpers differs. A file <src> lacks is not compared.
__ada_stage_stale() {
  local src=$1 dst=$2 f product helper
  shift 2
  for f in "${ADA_RUNTIME_FILES[@]}"; do
    [[ -f "$src/$f" ]] && ! cmp -s "$src/$f" "$dst/$f" && return 0
  done
  for product in "$@"; do
    helper=$(__ada_find_helper "$src" "$product") && ! cmp -s "$helper" "$dst/$product" && return 0
  done
  return 1
}

# For a Homebrew install run in place: every runtime file and helper must be
# there. Says what is missing on stderr.
__ada_check_in_place() {
  local who=$1 dir=$2 f product helper missing=0
  shift 2
  for f in "${ADA_RUNTIME_FILES[@]}"; do
    [[ -f "$dir/$f" ]] || { echo "$who: missing $dir/$f" >&2; missing=1; }
  done
  for product in "$@"; do
    helper="$dir/$product"
    [[ "$product" == ada-alert ]] && helper=${ADA_NATIVE_ALERT:-$helper}
    if [[ ! -x "$helper" ]]; then
      echo "$who: native helper $product is required (looked for $helper)." >&2
      missing=1
    fi
  done
  (( missing == 0 ))
}

# The pid launchd reports for <label>, or nothing when it isn't running.
__ada_launchd_pid() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null \
    | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1
}

# True when launchd has a job called <label> loaded, running or not.
__ada_launchd_loaded() {
  launchctl list 2>/dev/null | awk '{print $NF}' | grep -qxF "$1"
}
