#!/bin/bash
# =============================================================
# iyf-paseo-watch — In Your Face for Paseo agents
# -------------------------------------------------------------
# Pops the same maximized-window alert as iyf.sh / iyf-claude-hook.sh,
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
# restarts, and reuses the existing launcher (iyf-show-alert.sh),
# alert.html, snooze, auto-close and "stay silent while you're looking"
# logic. Run it as a launchd LaunchAgent (see `install`) for an
# install-once experience, or in the foreground (`run`) to try it out.
#
# The poll/diff loop lives in iyf-paseo-watch.py (per-agent state needs
# associative arrays, which macOS bash 3.2 lacks); this script is the
# bash front door: config, launchd management, and a test trigger.
#
# Usage:
#   iyf-paseo-watch.sh run         # the poll loop (foreground)
#   iyf-paseo-watch.sh install     # install + load the LaunchAgent
#   iyf-paseo-watch.sh uninstall   # unload + remove the LaunchAgent
#   iyf-paseo-watch.sh status      # is it running? + recent log
#   iyf-paseo-watch.sh test [code] # fire one sample alert and exit
#
# Environment knobs (shared with iyf.sh where noted):
#   IYF_PASEO_THRESHOLD        min finished-turn seconds to alert (default 45)
#   IYF_PASEO_POLL             snapshot poll interval seconds     (default 3)
#   IYF_PASEO_EVENTS           which events alert; space-separated subset of
#                              "finish error permission"          (default all)
#   IYF_PASEO_SKIP_WHEN_ACTIVE app(s) to stay silent for when frontmost —
#                              i.e. you're already in Paseo watching
#                              (default "sh.paseo.desktop"; set "" to disable)
#   IYF_SKIP_WHEN_ACTIVE       extra frontmost apps to stay silent for (shared)
#   IYF_PASEO_ENV              optional env file sourced at startup
#                              (default: paseo-watch.env next to this script) —
#                              handy for configuring the launchd daemon
#   IYF_PASEO_INSTALL_DIR      where `install` stages the runtime so the
#                              LaunchAgent can run it without Full Disk Access
#                              (default ~/.local/share/iyf; see `install`)
#   IYF_ALERT_FILE             alert.html path     (default: alongside this script)
#   IYF_AUTO_CLOSE             auto-dismiss seconds (default 90, via launcher)
#   IYF_SNOOZE_MINUTES         snooze options       (default "5 10 30 60", via launcher)
# =============================================================
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --- optional env file (lets the launchd daemon be configured out-of-band) ---
env_file=${IYF_PASEO_ENV:-$dir/paseo-watch.env}
if [[ -f "$env_file" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$env_file"; set +a
fi

# Self-contained alert page: default to the one shipped next to this script so
# the watcher works from any clone, not just ~/.iyf. The loop and the launcher
# both read these from the environment, so export them.
: "${IYF_ALERT_FILE:=$dir/alert.html}"; export IYF_ALERT_FILE
[[ -n "${IYF_AUTO_CLOSE:-}" ]] && export IYF_AUTO_CLOSE
[[ -n "${IYF_SNOOZE_MINUTES+x}" ]] && export IYF_SNOOZE_MINUTES

label_prefix="com.iyf.paseo-watch"
plist="$HOME/Library/LaunchAgents/${label_prefix}.plist"
logfile="${TMPDIR:-/tmp}/iyf-paseo-watch.log"
# `install` stages the runtime here — a non-TCC location launchd can read.
install_dir="${IYF_PASEO_INSTALL_DIR:-$HOME/.local/share/iyf}"

# --- locate the paseo CLI (PATH, then the usual symlink, then the app bundle) ---
__iyf_find_paseo() {
  local p
  p=$(command -v paseo 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in "$HOME/.local/bin/paseo" \
           "/Applications/Paseo.app/Contents/Resources/bin/paseo"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# --- locate python3 (launchd jobs don't inherit your interactive PATH) ---
__iyf_find_python() {
  local p
  p=$(command -v python3 2>/dev/null) && { printf '%s' "$p"; return 0; }
  for p in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Fire the shared launcher. <label> <duration-string> <exit-code>
__iyf_fire() {
  "$dir/iyf-show-alert.sh" "$1" "$2" "${3:-0}" >/dev/null 2>&1 &
}

# -------------------------------------------------------------
# run — hand off to the python poll loop
# -------------------------------------------------------------
iyf_run() {
  local paseo python
  paseo=$(__iyf_find_paseo) || {
    echo "iyf-paseo-watch: 'paseo' CLI not found on PATH or in /Applications/Paseo.app." >&2
    exit 1
  }
  python=$(__iyf_find_python) || {
    echo "iyf-paseo-watch: python3 is required (used to parse paseo --json)." >&2
    exit 1
  }
  export PASEO_BIN="$paseo" IYF_DIR="$dir"
  exec "$python" "$dir/iyf-paseo-watch.py"
}

# -------------------------------------------------------------
# install / uninstall / status — launchd LaunchAgent management
# -------------------------------------------------------------
iyf_install() {
  # Stage the runtime into a non-TCC location. A LaunchAgent runs WITHOUT your
  # Full Disk Access grants, so it cannot exec scripts from TCC-protected folders
  # — ~/Documents, ~/Desktop, ~/Downloads, or a symlink into them (note ~/.iyf is
  # often a symlink to ~/Documents/GitHub/iyf). launchd would fail with
  # "Operation not permitted" (exit 126). Copying the handful of files it needs
  # into ~/.local/share/iyf sidesteps that for good.
  mkdir -p "$install_dir" "$HOME/Library/LaunchAgents"
  local f
  for f in iyf-paseo-watch.sh iyf-paseo-watch.py iyf-show-alert.sh \
           iyf-snooze-daemon.py alert.html; do
    if [[ -f "$dir/$f" ]] && ! [[ "$dir/$f" -ef "$install_dir/$f" ]]; then
      cp "$dir/$f" "$install_dir/$f"
    fi
  done
  chmod +x "$install_dir/iyf-paseo-watch.sh" "$install_dir/iyf-paseo-watch.py" \
           "$install_dir/iyf-show-alert.sh" 2>/dev/null
  local script="$install_dir/iyf-paseo-watch.sh"
  if [[ ! -f "$install_dir/iyf-paseo-watch.py" || ! -f "$install_dir/iyf-show-alert.sh" ]]; then
    echo "iyf-paseo-watch: couldn't stage the runtime into $install_dir" >&2
    echo "  (run install from a full iyf checkout)" >&2
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

iyf_uninstall() {
  launchctl unload -w "$plist" >/dev/null 2>&1
  if [[ -f "$plist" ]]; then rm -f "$plist" && echo "Removed: $plist"
  else echo "Not installed (no $plist)"; fi
}

iyf_status() {
  if launchctl list 2>/dev/null | grep -q "$label_prefix"; then
    echo "LaunchAgent: loaded ($label_prefix)"
  else
    echo "LaunchAgent: not loaded"
  fi
  [[ -f "$plist" ]] && echo "plist: $plist" || echo "plist: (none)"
  echo "install dir: $install_dir"
  if [[ -f "$logfile" ]]; then
    echo "--- last 10 log lines ($logfile) ---"
    tail -n 10 "$logfile" 2>/dev/null
  fi
}

iyf_test() {
  __iyf_fire "Paseo · test · iyf-paseo-watch" "1s" "${1:-0}"
  echo "Fired a test alert."
}

case "${1:-}" in
  run)        iyf_run ;;
  install)    iyf_install ;;
  uninstall)  iyf_uninstall ;;
  status)     iyf_status ;;
  test)       iyf_test "${2:-0}" ;;
  ""|-h|--help|help)
    sed -n '2,64p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "iyf-paseo-watch: unknown command '$1' (try: run install uninstall status test)" >&2
    exit 2 ;;
esac
