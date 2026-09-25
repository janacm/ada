#!/bin/bash
# =============================================================
# ada-menubar — the ADA menu bar item as a login item
# -------------------------------------------------------------
# ada-menubar is a native status item: pause every alert, see recent alerts
# (including the ones a pause or mute kept off your screen), unmute sessions,
# and check which integrations are wired. This front door makes it start at
# login, as a LaunchAgent, and keeps it running until you quit it.
#
# A LaunchAgent cannot exec anything under ~/Documents, ~/Desktop or
# ~/Downloads, nor can anything it starts, so a dev checkout is staged into
# ~/.local/share/ada (shared with the Paseo watcher's stage; see
# lib/ada-stage.sh). A Homebrew install runs in place from its opt path, so
# `brew upgrade` updates it; the menu bar notices its binary was replaced and
# lets launchd restart it.
#
# Usage:
#   ada-menubar.sh install     # stage (or check the Homebrew install), load the LaunchAgent
#   ada-menubar.sh uninstall   # unload and remove the LaunchAgent (the stage stays)
#   ada-menubar.sh status      # is it running, and is the stage current?
#   ada-menubar.sh start       # start it again after "Quit ADA Menu Bar"
#
# Environment:
#   ADA_MENUBAR_INSTALL_DIR  where a checkout is staged
#                            (default ADA_PASEO_INSTALL_DIR, else ~/.local/share/ada)
# =============================================================
set -u

# Homebrew installs live in a VERSIONED Cellar directory that the next
# `brew upgrade` deletes. Anything durable we write out (the ~/.zshrc source
# line, agent hook commands, the LaunchAgent plist) must therefore point at the
# version-stable .../opt/<formula>/libexec symlink instead, or the install
# silently dies on the next upgrade. Map Cellar -> opt when the equivalent opt
# path exists; leave every other layout untouched.
# Deliberately duplicated in ada-install.sh, ada-paseo-watch.sh and
# ada-menubar.sh: each is a standalone entry point that needs this before it
# knows where its lib/ is (the last two are even copied elsewhere when staged).
# test/ada-menubar.bats checks the three copies stay identical.
__ada_stable_dir() {
  local d=$1 prefix rest name tail
  case "$d" in
    */Cellar/*)
      prefix=${d%%/Cellar/*}   # /opt/homebrew
      rest=${d#*/Cellar/}      # ada/0.2/libexec
      name=${rest%%/*}         # ada
      tail=${rest#*/}          # 0.2/libexec
      tail=${tail#*/}          # libexec  (drop the version component)
      if [[ -n "$tail" && -d "$prefix/opt/$name/$tail" ]]; then
        printf '%s\n' "$prefix/opt/$name/$tail"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$d"
}

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir=$(__ada_stable_dir "$dir")

install_dir="${ADA_MENUBAR_INSTALL_DIR:-${ADA_PASEO_INSTALL_DIR:-$HOME/.local/share/ada}}"
label="com.ada.menubar"
plist="$HOME/Library/LaunchAgents/${label}.plist"
logfile="${TMPDIR:-/tmp}/ada-menubar.log"

__ada_load_stage_lib() {
  if [[ ! -f "$dir/lib/ada-stage.sh" ]]; then
    echo "ada-menubar: missing $dir/lib/ada-stage.sh (run this from a full ada install)" >&2
    return 1
  fi
  # shellcheck source=lib/ada-stage.sh
  . "$dir/lib/ada-stage.sh"
}

# The plist for a menu bar running from <runtime>.
#   KeepAlive/SuccessfulExit=false  restart after a crash or the exit(75) that
#                                   follows a replaced binary, but not after Quit
#   LimitLoadToSessionType=Aqua     a GUI login session, where a status item can live
#   AbandonProcessGroup             a Test Alert window outlives the menu bar
#   PATH                            launchd jobs don't get your shell's PATH, and
#                                   the scripts need python3 and lsappinfo
__ada_menubar_plist() {
  local runtime=$1
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${runtime}/ada-menubar</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>AbandonProcessGroup</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>${logfile}</string>
  <key>StandardErrorPath</key>
  <string>${logfile}</string>
</dict>
</plist>
PLIST
}

ada_install() {
  local runtime tmp
  __ada_load_stage_lib || return 1
  mkdir -p "$HOME/Library/LaunchAgents"
  if __ada_from_brew_prefix "$dir"; then
    __ada_check_in_place ada-menubar "$dir" ada-alert ada-menubar || return 1
    runtime=$dir
    echo "Homebrew install detected: running the menu bar in place from $dir"
    echo "  (no staging, so 'brew upgrade ada' updates it too)"
  else
    __ada_stage_runtime ada-menubar "$dir" "$install_dir" ada-alert ada-menubar || return 1
    runtime=$install_dir
  fi

  tmp=$(mktemp "$plist.XXXXXX") || return 1
  if ! { __ada_menubar_plist "$runtime" > "$tmp" && mv -f "$tmp" "$plist"; }; then
    rm -f "$tmp"
    echo "ada-menubar: couldn't write $plist" >&2
    return 1
  fi

  : > "$logfile" 2>/dev/null || true
  # Unloading stops a running copy, so the load starts the one just staged.
  launchctl unload "$plist" >/dev/null 2>&1
  if launchctl load -w "$plist" 2>/dev/null; then
    echo "Installed and loaded: $plist"
    echo "  runtime: $runtime"
    echo "  starts at login; logs -> $logfile"
    echo "  uninstall with: $runtime/ada-menubar.sh uninstall"
  else
    echo "Wrote $plist but 'launchctl load' failed — try: launchctl load -w \"$plist\"" >&2
    return 1
  fi
}

ada_uninstall() {
  launchctl unload -w "$plist" >/dev/null 2>&1
  if [[ -f "$plist" ]]; then rm -f "$plist" && echo "Removed: $plist"
  else echo "Not installed (no $plist)"; fi
}

ada_start() {
  if [[ ! -f "$plist" ]]; then
    echo "ada-menubar: not installed — run: $dir/ada-menubar.sh install" >&2
    return 1
  fi
  __ada_load_stage_lib || return 1
  if ! __ada_launchd_loaded "$label"; then
    launchctl load -w "$plist" 2>/dev/null || { echo "ada-menubar: 'launchctl load' failed" >&2; return 1; }
  fi
  if launchctl kickstart "gui/$(id -u)/$label" 2>/dev/null; then
    echo "Started the ADA menu bar."
  else
    echo "ada-menubar: 'launchctl kickstart' failed — try: launchctl kickstart gui/$(id -u)/$label" >&2
    return 1
  fi
}

ada_status() {
  local pid runtime="" info
  __ada_load_stage_lib || return 1
  pid=$(__ada_launchd_pid "$label")
  if [[ -n "$pid" ]]; then
    echo "✅ Menu bar: running (pid $pid)"
  elif __ada_launchd_loaded "$label"; then
    echo "⚠️  Menu bar: loaded but not running (quit from its menu?) — start it: $dir/ada-menubar.sh start"
  else
    echo "❌ Menu bar: not a login item — run: $dir/ada-menubar.sh install"
  fi

  if [[ -f "$plist" ]]; then
    echo "✅ plist: $plist"
    runtime=$(sed -n 's|.*<string>\(.*\)/ada-menubar</string>.*|\1|p' "$plist" | head -1)
  else
    echo "❌ plist: (none)"
  fi
  if [[ -n "$runtime" ]]; then
    echo "   runtime: $runtime"
    if [[ "$runtime" != "$dir" ]] && __ada_stage_stale "$dir" "$runtime" ada-alert ada-menubar; then
      echo "   source:  $dir differs from the staged copy (re-run install)"
    fi
    info="$runtime/stage-info"
    if [[ -f "$info" ]]; then
      echo "   staged from: $(sed -n 's/^source=//p' "$info") at $(sed -n 's/^rev=//p' "$info")"
    fi
  else
    echo "   runtime: (not installed)"
  fi

  if [[ -s "$logfile" ]]; then
    echo "⚠️  log has output — last 10 lines ($logfile):"
    tail -n 10 "$logfile" 2>/dev/null | sed 's/^/   /'
  else
    echo "✅ log clean ($logfile)"
  fi
}

case "${1:-}" in
  install)    ada_install ;;
  uninstall)  ada_uninstall ;;
  start)      ada_start ;;
  status)     ada_status ;;
  *)
    sed -n '17,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [[ -z "${1:-}" ]] || { echo "ada-menubar: unknown command: $1" >&2; exit 2; }
    ;;
esac
