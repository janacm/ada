#!/bin/bash
# =============================================================
# ada-paseo-watch — Agent Done Alert for Paseo agents
# -------------------------------------------------------------
# Pops the same maximized-window alert as ada.sh / ada-claude-hook.sh,
# but when a long-running *Paseo agent* finishes a turn (or gets
# blocked waiting on you) instead of a shell command or Claude turn.
#
# Why this exists as a poller and not a hook: Paseo runs agents
# (opencode, claude, codex, …) through its own daemon runtime, NOT
# through the provider CLIs. So ~/.claude/settings.json hooks never
# fire for a Paseo-managed agent — not even a claude/* one — and Paseo
# itself exposes no "run a command on agent event" hook. The only
# stable, supported surface is the daemon's JSON snapshot via the CLI:
#
#   paseo ls --json        -> [{ id, shortId, name, provider, status, … }]
#                             status ∈ initializing|idle|running|error|closed
#   paseo permit ls --json -> [ <pending permission request>, … ]
#
# So we synthesize the missing "Stop" event by polling that snapshot
# and diffing each agent's status between polls:
#
#   running -> idle   = turn finished  -> green "finished" alert
#   running -> error  = turn failed    -> red "failed" alert
#   a new pending permission request   -> "needs you" alert
#
# One watcher covers every agent and every provider, survives daemon
# restarts, and reuses the existing launcher (ada-show-alert.sh),
# alert.html, snooze, auto-close and "stay silent while you're looking"
# logic. Run it as a launchd LaunchAgent (see `install`) for an
# install-once experience, or in the foreground (`run`) to try it out.
#
# The poll/diff loop lives in ada-paseo-watch.py (per-agent state needs
# associative arrays, which macOS bash 3.2 lacks); this script is the
# bash front door: config, launchd management, and a test trigger.
#
# Usage:
#   ada-paseo-watch.sh run         # the poll loop (foreground)
#   ada-paseo-watch.sh install     # install + load the LaunchAgent
#   ada-paseo-watch.sh uninstall   # unload + remove the LaunchAgent
#   ada-paseo-watch.sh status      # is it running? + recent log
#   ada-paseo-watch.sh test [code] # fire one sample alert and exit
#
# Environment knobs (shared with ada.sh where noted):
#   ADA_PASEO_THRESHOLD        min finished-turn seconds to alert (default 45)
#   ADA_PASEO_POLL             snapshot poll interval seconds     (default 3)
#   ADA_PASEO_EVENTS           which events alert; space-separated subset of
#                              "finish error permission"          (default all)
#   ADA_PASEO_SKIP_WHEN_ACTIVE app(s) to stay silent for when frontmost —
#                              i.e. you're already in Paseo watching
#                              (default "sh.paseo.desktop"; set "" to disable)
#   ADA_SKIP_WHEN_ACTIVE       extra frontmost apps to stay silent for (shared)
#   ADA_PASEO_ENV              optional env file sourced at startup
#                              (default: paseo-watch.env next to this script) —
#                              handy for configuring the launchd daemon
#   ADA_PASEO_INSTALL_DIR      where `install` stages the runtime so the
#                              LaunchAgent can run it without Full Disk Access
#                              (default ~/.local/share/ada; see `install`)
#   ADA_ALERT_FILE             alert.html path     (default: alongside this script)
#   ADA_NATIVE_ALERT           path to ada-alert native helper (via launcher)
#   ADA_AUTO_CLOSE             auto-dismiss seconds (default 90, via launcher)
#   ADA_SNOOZE_MINUTES         snooze options       (default "5 10 30 60", via launcher)
#   ADA_FOCUS_APP              bundle id to focus on click (default sh.paseo.desktop)
#   ADA_FOCUS_APP_NAME         display name for the click hint (default Paseo)
# =============================================================
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --- optional env file (lets the launchd daemon be configured out-of-band) ---
env_file=${ADA_PASEO_ENV:-$dir/paseo-watch.env}
if [[ -f "$env_file" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$env_file"; set +a
fi

# Self-contained alert page: default to the one shipped next to this script so
# the watcher works from any clone, not just ~/.ada. The loop and the launcher
# both read these from the environment, so export them.
: "${ADA_ALERT_FILE:=$dir/alert.html}"; export ADA_ALERT_FILE
if [[ -z "${ADA_FOCUS_APP+x}" ]]; then ADA_FOCUS_APP="sh.paseo.desktop"; fi
if [[ -z "${ADA_FOCUS_APP_NAME+x}" ]]; then ADA_FOCUS_APP_NAME="Paseo"; fi
export ADA_FOCUS_APP ADA_FOCUS_APP_NAME
[[ -n "${ADA_AUTO_CLOSE:-}" ]] && export ADA_AUTO_CLOSE
[[ -n "${ADA_SNOOZE_MINUTES+x}" ]] && export ADA_SNOOZE_MINUTES

label_prefix="com.ada.paseo-watch"
plist="$HOME/Library/LaunchAgents/${label_prefix}.plist"
logfile="${TMPDIR:-/tmp}/ada-paseo-watch.log"
# `install` stages the runtime here — a non-TCC location launchd can read.
install_dir="${ADA_PASEO_INSTALL_DIR:-$HOME/.local/share/ada}"

# --- locate the paseo CLI (PATH, then the usual symlink, then the app bundle) ---
__ada_find_paseo() {
  local p
  p=$(command -v paseo 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in "$HOME/.local/bin/paseo" \
           "/Applications/Paseo.app/Contents/Resources/bin/paseo"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# --- locate python3 (launchd jobs don't inherit your interactive PATH) ---
__ada_find_python() {
  local p
  p=$(command -v python3 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Fire the shared launcher. <label> <duration-string> <exit-code>
__ada_fire() {
  "$dir/lib/ada-show-alert.sh" "$1" "$2" "${3:-0}" >/dev/null 2>&1 &
}

# -------------------------------------------------------------
# run — hand off to the python poll loop
# -------------------------------------------------------------
ada_run() {
  local paseo python
  paseo=$(__ada_find_paseo) || {
    echo "ada-paseo-watch: 'paseo' CLI not found on PATH or in /Applications/Paseo.app." >&2
    exit 1
  }
  python=$(__ada_find_python) || {
    echo "ada-paseo-watch: python3 is required (used to parse paseo --json)." >&2
    exit 1
  }
  export PASEO_BIN="$paseo"
  exec "$python" "$dir/lib/ada-paseo-watch.py"
}

# -------------------------------------------------------------
# install / uninstall / status — launchd LaunchAgent management
# -------------------------------------------------------------
ada_install() {
  # Stage the runtime into a non-TCC location. A LaunchAgent runs WITHOUT your
  # Full Disk Access grants, so it cannot exec scripts from TCC-protected folders
  # — ~/Documents, ~/Desktop, ~/Downloads, or a symlink into them (note ~/.ada is
  # often a symlink to ~/Documents/GitHub/ada). launchd would fail with
  # "Operation not permitted" (exit 126). Copying the handful of files it needs
  # into ~/.local/share/ada sidesteps that for good.
  # Mirror the dev-checkout layout into the staging dir: the front door and
  # alert.html at the top, the internal scripts under lib/. Keeping the two
  # layouts identical means every "$dir/lib/..." reference resolves the same way
  # whether we run from a checkout or from the staged LaunchAgent — no flat-vs-lib
  # special-casing, which is exactly the kind of mismatch that used to silently
  # break the staged watcher.
  mkdir -p "$install_dir/lib" "$HOME/Library/LaunchAgents"
  local f
  for f in ada-paseo-watch.sh alert.html; do
    if [[ -f "$dir/$f" ]] && ! [[ "$dir/$f" -ef "$install_dir/$f" ]]; then
      cp "$dir/$f" "$install_dir/$f"
    fi
  done
  for f in ada-paseo-watch.py ada-show-alert.sh ada-snooze-daemon.py; do
    if [[ -f "$dir/lib/$f" ]] && ! [[ "$dir/lib/$f" -ef "$install_dir/lib/$f" ]]; then
      cp "$dir/lib/$f" "$install_dir/lib/$f"
    fi
  done

  local native_alert=""
  for f in "${ADA_NATIVE_ALERT:-}" "$dir/ada-alert" \
           "$dir/.build/release/ada-alert" "$dir/.build/debug/ada-alert"; do
    if [[ -x "$f" ]]; then native_alert="$f"; break; fi
  done
  if [[ -z "$native_alert" && -f "$dir/Package.swift" ]] && command -v swift >/dev/null 2>&1; then
    echo "Building native alert helper..."
    if (cd "$dir" && swift build -c release --product ada-alert >/dev/null 2>&1); then
      native_alert="$dir/.build/release/ada-alert"
    else
      echo "ada-paseo-watch: native helper build failed." >&2
    fi
  fi
  if [[ -z "$native_alert" ]]; then
    echo "ada-paseo-watch: native helper ada-alert is required." >&2
    echo "  Build it with: swift build -c release --product ada-alert" >&2
    return 1
  fi
  if [[ -n "$native_alert" ]] && ! [[ "$native_alert" -ef "$install_dir/ada-alert" ]]; then
    cp "$native_alert" "$install_dir/ada-alert"
  fi

  chmod +x "$install_dir/ada-paseo-watch.sh" "$install_dir/lib/ada-paseo-watch.py" \
           "$install_dir/lib/ada-show-alert.sh" "$install_dir/ada-alert" 2>/dev/null
  local script="$install_dir/ada-paseo-watch.sh"
  if [[ ! -f "$install_dir/lib/ada-paseo-watch.py" || ! -f "$install_dir/lib/ada-show-alert.sh" ]]; then
    echo "ada-paseo-watch: couldn't stage the runtime into $install_dir" >&2
    echo "  (run install from a full ada checkout)" >&2
    return 1
  fi
  # Bake in a PATH that finds paseo (~/.local/bin) plus python3/lsappinfo,
  # because launchd jobs don't inherit your interactive shell PATH.
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label_prefix}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script}</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
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

  : > "$logfile" 2>/dev/null || true   # fresh log so `status` health stays accurate
  launchctl unload "$plist" >/dev/null 2>&1
  if launchctl load -w "$plist" 2>/dev/null; then
    echo "Installed and loaded: $plist"
    echo "  runtime staged in: $install_dir"
    echo "  watching the Paseo daemon; logs -> $logfile"
    echo "  configure via env file: $install_dir/paseo-watch.env"
    echo "  uninstall with: $script uninstall"
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

ada_status() {
  local pid loaded=0
  launchctl list 2>/dev/null | grep -q "$label_prefix" && loaded=1
  # The real health signal is a live poll loop, not just a registered job.
  pid=$(launchctl print "gui/$(id -u)/${label_prefix}" 2>/dev/null \
        | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1)
  [[ -z "$pid" ]] && pid=$(pgrep -f "$install_dir/lib/ada-paseo-watch.py" 2>/dev/null | head -1)

  if [[ -n "$pid" ]]; then
    echo "✅ Paseo watcher: running (pid $pid)"
  elif (( loaded )); then
    echo "⚠️  Paseo watcher: loaded but not running yet"
  else
    echo "❌ Paseo watcher: not loaded — run: $install_dir/ada-paseo-watch.sh install"
  fi

  [[ -f "$plist" ]] && echo "✅ plist: $plist" || echo "❌ plist: (none)"
  echo "   install dir: $install_dir"

  # The loop is silent unless something breaks, so any log output is a problem.
  if [[ -s "$logfile" ]]; then
    echo "⚠️  log has output — last 10 lines ($logfile):"
    tail -n 10 "$logfile" 2>/dev/null | sed 's/^/   /'
  else
    echo "✅ log clean — no errors ($logfile)"
  fi
}

ada_test() {
  __ada_fire "Paseo · test · ada-paseo-watch" "1s" "${1:-0}"
  echo "Fired a test alert."
}

case "${1:-}" in
  run)        ada_run ;;
  install)    ada_install ;;
  uninstall)  ada_uninstall ;;
  status)     ada_status ;;
  test)       ada_test "${2:-0}" ;;
  ""|-h|--help|help)
    sed -n '2,64p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "ada-paseo-watch: unknown command '$1' (try: run install uninstall status test)" >&2
    exit 2 ;;
esac
