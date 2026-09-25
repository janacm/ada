#!/usr/bin/env python3
# =============================================================
# ada-snooze-daemon — re-arms the alert after a snooze, or focuses the source app
# -------------------------------------------------------------
# The alert is a sandboxed file:// page in a browser window; once
# it closes, its JS dies, so it cannot bring itself forcefully
# back (browsers block window activation / focus-stealing from
# timers). A "snooze" therefore has to be re-launched by a
# process that outlives the window. That's this daemon.
#
# It binds an ephemeral loopback port, then fully detaches
# (double-fork + setsid) so it survives the terminal that spawned
# it closing. ada-show-alert.sh reads the port + token it writes
# to a handoff file and bakes them into the alert URL. The page
# then signals a decision with a no-cors fetch:
#
#   GET /<token>/snooze/<minutes>  -> sleep, then relaunch the alert. With
#                                     $ADA_SNOOZE_HOLD_FILE set, also hold the
#                                     session's other alerts until then, and
#                                     skip the relaunch if the hold is released
#   GET /<token>/focus             -> `open` the click URL if one was provided
#                                     (e.g. claude://resume?session=…), else
#                                     focus the source app; no relaunch
#   GET /<token>/mute              -> touch $ADA_MUTE_FILE so the launcher drops
#                                     every later alert for this session; no
#                                     relaunch (only honored when that is set)
#   GET /<token>/pause/<minutes>   -> run $ADA_PAUSE_CLI <minutes> (lib/ada-pause.sh),
#                                     which pauses every alert and starts the
#                                     timer below; an alert of its own if that
#                                     fails (only honored when that is set)
#   GET /<token>/open/<i>          -> a summary alert's row: `open` target i of
#                                     $ADA_SUMMARY_TARGETS, like focus
#   GET /<token>/dismiss           -> exit, no relaunch
#
# If the user never decides (plain dismiss with the beacon blocked,
# or auto-close), the daemon self-exits at <deadline> seconds.
#
# Usage:
#   ada-snooze-daemon.py <handoff> <deadline> <alert_script> \
#       <cmd> <duration> <code> <alert_file> <auto_close> <snooze_minutes> \
#       [focus_bundle_id] [click_url]
#   ada-snooze-daemon.py --pause-timer <end epoch> <pause file> <alert_script>
#       detach, wait by the wall clock until the pause that ends at <end epoch>
#       is over, then run <alert_script> with ADA_PAUSE_FLUSH=ended to show
#       what arrived meanwhile. Exits early once the pause file holds another
#       value (a newer pause, or a resume, which shows the summary itself).
#
# Set ADA_SNOOZE_LOG=/path to append a trace line per request/decision (debug).
# =============================================================
import json
import os
import re
import stat
import sys
import time
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    from secrets import token_urlsafe
except Exception:  # pragma: no cover - secrets is stdlib everywhere we run
    import base64
    def token_urlsafe(n):
        return base64.urlsafe_b64encode(os.urandom(n)).rstrip(b"=").decode()

# How often a snoozing daemon or a pause timer wakes to check the clock and its
# marker.
POLL_SECONDS = 10.0

# Opt-in tracing: set ADA_SNOOZE_LOG=/path to append a line per request/decision.
_log_path = os.environ.get("ADA_SNOOZE_LOG", "")


def trace(msg):
    if not _log_path:
        return
    try:
        with open(_log_path, "a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def daemonize():
    """Double-fork + setsid so we detach from the launching terminal."""
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        try:
            os.dup2(devnull, fd)
        except OSError:
            pass


def detach():
    """daemonize(), and close every other inherited descriptor as well. A pause
    timer can outlive its caller by hours, and must not hold open a pipe the
    caller reads to its end (bats' fd 3, the menu bar's stderr pipe), nor the
    directory it was started from (a drive there could not be ejected). Only
    the timer detaches this way: a snooze relaunch records its working
    directory in the history, so daemonize() keeps it."""
    daemonize()
    os.closerange(3, 256)
    try:
        os.chdir("/")
    except OSError:
        pass


def minutes(text):
    """A snooze or pause length: 1..1440, in ASCII digits. None otherwise.
    str.isdigit() is not enough: it takes "\u00b2" (superscript two), which
    int() rejects, and "\u0663" (Arabic-Indic three), which int() reads as 3."""
    if not re.fullmatch(r"[0-9]{1,4}", text or ""):
        return None
    n = int(text)
    return n if 0 < n <= 24 * 60 else None


def read_pause_until(path):
    """The value of the pause file by lib/ada-pause.sh's rule (__ada_pause_until):
    a regular file, not a symlink, whose first line is a decimal integer. None
    for anything else, a missing file included."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        data = os.read(fd, 64)
    except OSError:
        return None
    finally:
        os.close(fd)
    line = data.split(b"\n", 1)[0].decode("ascii", "replace")
    return int(line) if re.fullmatch(r"[0-9]{1,15}", line) else None


def pause_timer(until, pause_file, launcher):
    """Wait for the pause that ends at <until>, then show what it held. The
    file's value is this timer's token: a newer pause changes it, and that
    pause's own timer owns the end. A file that is gone before <until> was
    resumed, and resume shows the summary itself; gone after <until>, it was
    only cleaned up by `ada-pause status`, and the pause still ended."""
    while True:
        value = read_pause_until(pause_file)
        if value != until and not (value is None and time.time() >= until):
            trace("pause timer: replaced or resumed")
            return 0
        left = until - time.time()
        if left <= 0:
            break
        time.sleep(min(left, POLL_SECONDS))
    env = dict(os.environ)
    env["ADA_PAUSE_FLUSH"] = "ended"
    # The file this timer watched, by its absolute path: the flush runs from /,
    # where a relative ADA_PAUSE_FILE would name some other file.
    env["ADA_PAUSE_FILE"] = pause_file
    trace("pause over, showing the summary")
    try:
        subprocess.Popen(
            [launcher, "", "", "0"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass
    return 0


# --- pause timer ------------------------------------------------
# Its own mode, dispatched before the alert argv below is parsed.
if __name__ == "__main__" and sys.argv[1:2] == ["--pause-timer"]:
    timer_args = sys.argv[2:]
    if len(timer_args) != 3 or not re.fullmatch(r"[0-9]{1,15}", timer_args[0]) \
            or int(timer_args[0]) <= 0 or not timer_args[1] or not timer_args[2]:
        sys.exit(2)
    # Absolute before detach() moves to /, so a path relative to the caller
    # still names the same file.
    pause_file, launcher = os.path.abspath(timer_args[1]), os.path.abspath(timer_args[2])
    detach()
    sys.exit(pause_timer(int(timer_args[0]), pause_file, launcher))

# --- args -----------------------------------------------------
try:
    (handoff, deadline_s, alert_script, cmd, duration, code,
     alert_file, auto_close, snooze_minutes) = sys.argv[1:10]
except ValueError:
    sys.exit(0)
focus_app = sys.argv[10] if len(sys.argv) > 10 else os.environ.get("ADA_FOCUS_APP", "")
click_url = sys.argv[11] if len(sys.argv) > 11 else os.environ.get("ADA_CLICK_URL", "")
# The marker the "Mute this …" button creates. ada-show-alert.sh resolves and
# validates it (lib/ada-mute.sh owns the naming rule), so it is used verbatim.
mute_file = os.environ.get("ADA_MUTE_FILE", "")
# The session hold a snooze writes when the integration opted into
# ADA_SNOOZE_SCOPE=session (see the snooze hold section of lib/ada-mute.sh).
# Resolved and validated by the launcher as well, so also used verbatim.
hold_file = os.environ.get("ADA_SNOOZE_HOLD_FILE", "")
# lib/ada-pause.sh beside the launcher, named when the alert offers "Pause all
# alerts". It is the one writer of the pause file, so the daemon runs it rather
# than writing the file itself. Only a regular file is run.
pause_cli = os.environ.get("ADA_PAUSE_CLI", "")
if pause_cli and not os.path.isfile(pause_cli):
    pause_cli = ""

SUMMARY_URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:[^\x00-\x1f\x7f]*")
SUMMARY_APP = re.compile(r"[A-Za-z0-9.-]{1,255}")


def parse_targets(text):
    """ADA_SUMMARY_TARGETS, set by the launcher for a summary alert: a JSON list
    with one entry per row, {"url": ...}, {"app": <bundle id>} or null. The
    page only ever sends a row index, and a row can only open what the launcher
    named for it: anything malformed is None and opens nothing."""
    try:
        raw = json.loads(text) if text else []
    except ValueError:
        return []
    if not isinstance(raw, list):
        return []
    out = []
    for entry in raw[:50]:
        target = None
        if isinstance(entry, dict):
            url, app = entry.get("url"), entry.get("app")
            if isinstance(url, str) and len(url) <= 2048 and SUMMARY_URL.fullmatch(url):
                target = (url, "")
            elif isinstance(app, str) and SUMMARY_APP.fullmatch(app):
                target = ("", app)
        out.append(target)
    return out


targets = parse_targets(os.environ.get("ADA_SUMMARY_TARGETS", ""))

try:
    deadline = float(deadline_s)
except ValueError:
    deadline = 105.0
if deadline <= 0:
    deadline = 105.0

token = token_urlsafe(8)


def marker_label(text):
    """One line of at most 200 characters, the rule lib/ada-mute.sh uses."""
    return " ".join(text.replace("\t", " ").replace("\r", " ").split("\n"))[:200]

class Handler(BaseHTTPRequestHandler):
    def _respond(self, status, body=b""):
        self.send_response(status)
        # Permissive CORS + Private Network Access so the file:// (opaque)
        # origin's no-cors request to loopback is allowed to go through,
        # including any PNA preflight Chrome sends ahead of it.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except Exception:
                pass

    def do_OPTIONS(self):
        trace("OPTIONS %s" % self.path)
        self._respond(204)  # No Content — must not carry a body

    def do_GET(self):
        trace("GET %s" % self.path)
        parts = self.path.strip("/").split("/")
        ok = len(parts) >= 2 and parts[0] == token
        self._respond(200 if ok else 404, b"ok")
        if not ok:
            return
        action = parts[1]
        if action == "snooze" and len(parts) >= 3 and minutes(parts[2]):
            self.server.ada_result = ("snooze", minutes(parts[2]))
            self.server.ada_done = True
        elif action == "pause" and len(parts) == 3 and pause_cli and minutes(parts[2]):
            self.server.ada_result = ("pause", minutes(parts[2]))
            self.server.ada_done = True
        elif action == "open" and len(parts) == 3 and re.fullmatch(r"[0-9]{1,2}", parts[2]) \
                and int(parts[2]) < len(targets) and targets[int(parts[2])]:
            self.server.ada_result = ("open", int(parts[2]))
            self.server.ada_done = True
        elif action == "dismiss":
            self.server.ada_result = ("dismiss", 0)
            self.server.ada_done = True
        elif action == "mute" and mute_file:
            self.server.ada_result = ("mute", 0)
            self.server.ada_done = True
        elif action == "focus" and (click_url or focus_app):
            self.server.ada_result = ("focus", 0)
            self.server.ada_done = True

    def log_message(self, *args):
        pass


def write_hold(wake):
    """Publish the session hold for this snooze. False when there is none to
    write or it could not be written, which leaves a plain one-alert snooze."""
    if not hold_file:
        return False
    try:
        os.makedirs(os.path.dirname(hold_file), exist_ok=True)
        # Written beside the marker and renamed over it, so the launcher never
        # reads half a line. O_EXCL | O_NOFOLLOW: nothing already sitting at
        # the temp name, a symlink included, is ever written through.
        tmp = "%s.%s.tmp" % (hold_file, token)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "w") as f:
            f.write("%d %s\n" % (wake, token))
        os.replace(tmp, hold_file)
        return True
    except OSError:
        return False


def hold_is_ours():
    try:
        fd = os.open(hold_file, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as f:
            return f.read().split()[1:2] == [token]
    except OSError:
        return False


def open_target(url, app):
    """`open` a click URL (e.g. claude://resume?session=…), which both launches
    or focuses the target app and navigates it, else bring forward the app
    with this bundle id."""
    if url:
        trace("focus url %s" % url)
        open_cmd = ["open", url]
    else:
        trace("focus %s" % app)
        open_cmd = ["open", "-b", app]
    try:
        subprocess.Popen(
            open_cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def run_pause(mins):
    """Pause every alert through lib/ada-pause.sh, which also starts the timer
    that shows the summary. The page has already said "Paused", so a pause
    that did not happen gets an alert of its own, which ignores the pause and
    belongs to no session."""
    trace("pause %dm" % mins)
    error = ""
    try:
        done = subprocess.run(
            ["/bin/bash", pause_cli, str(mins)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        if done.returncode != 0:
            lines = done.stderr.decode("utf-8", "replace").strip().splitlines()
            error = lines[0] if lines else "exit status %d" % done.returncode
    except (OSError, subprocess.SubprocessError) as exc:
        error = str(exc) or exc.__class__.__name__
    if not error:
        return
    if error.startswith("ada-pause: "):
        error = error[len("ada-pause: "):]
    trace("pause failed: %s" % error)
    env = dict(os.environ)
    env["ADA_IGNORE_PAUSE"] = "1"
    env["ADA_ALERT_FILE"] = alert_file
    env["ADA_AUTO_CLOSE"] = auto_close
    env["ADA_SNOOZE_MINUTES"] = ""
    env["ADA_REPO"] = ""
    for key in ("ADA_SESSION_KEY", "ADA_SNOOZE_SCOPE", "ADA_CLICK_URL", "ADA_SNOOZED"):
        env.pop(key, None)
    try:
        subprocess.Popen(
            [alert_script, marker_label("\u26a0\ufe0f Couldn't pause alerts: " + error), "", "0"],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def wait_until(wake, holding):
    """Sleep in short steps until the wall-clock wake time, which is what the
    hold marker records; one long time.sleep() is not guaranteed to line up
    with it across a Mac that slept with its lid shut. Returns False as soon as
    the session's hold is gone, i.e. the user went back to the session."""
    while True:
        if holding and not hold_is_ours():
            return False
        left = wake - time.time()
        if left <= 0:
            return True
        time.sleep(min(left, POLL_SECONDS))


def main():
    # Bind before detaching so the port is known and bind errors surface
    # while we still share stderr with the caller.
    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    httpd.timeout = 1  # handle_request() returns after 1s of idle
    httpd.ada_done = False
    httpd.ada_result = None
    port = httpd.server_address[1]

    daemonize()

    # The grandchild owns the socket; publish the connection info atomically.
    try:
        tmp = handoff + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d %s\n" % (port, token))
        os.replace(tmp, handoff)
    except OSError:
        # Without the handoff the page can't reach us; nothing to do.
        return

    start = time.time()
    while not httpd.ada_done and (time.time() - start) < deadline:
        try:
            httpd.handle_request()
        except Exception:
            break
    httpd.server_close()

    result = httpd.ada_result
    if result and result[0] == "mute":
        trace("mute %s" % mute_file)
        try:
            os.makedirs(os.path.dirname(mute_file), exist_ok=True)
            # O_NOFOLLOW: ADA_MUTE_DIR is user-configurable, so a symlink by
            # the marker's name must not be followed to touch its target.
            fd = os.open(mute_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            try:
                # The marker holds the alert's label, so the menu bar and
                # `ada-mute list` can say what was muted. It is your prompt, so
                # keep it private. Writing also restarts the expiry clock.
                os.fchmod(fd, 0o600)
                os.write(fd, (marker_label(cmd) + "\n").encode("utf-8", "replace"))
            finally:
                os.close(fd)
        except OSError:
            pass
        return

    if result and result[0] == "focus":
        # A click URL navigates as well as focusing, so it wins over the app.
        open_target(click_url, focus_app)
        return

    if result and result[0] == "open":
        trace("open row %d" % result[1])
        open_target(*targets[result[1]])
        return

    if result and result[0] == "pause":
        run_pause(result[1])
        return

    if not result or result[0] != "snooze":
        trace("exit without snooze: %r" % (result,))
        return

    wake = int(time.time() + result[1] * 60)
    holding = write_hold(wake)
    trace("snooze %dm -> relaunch after sleep%s"
          % (result[1], " (holding %s)" % hold_file if holding else ""))
    if not wait_until(wake, holding):
        trace("snooze released early: %s" % hold_file)
        return
    if holding:
        # Lift the hold first, or the launcher would drop this very relaunch.
        try:
            os.remove(hold_file)
        except OSError:
            pass
    env = dict(os.environ)
    env["ADA_SNOOZED"] = "1"
    env["ADA_ALERT_FILE"] = alert_file
    env["ADA_AUTO_CLOSE"] = auto_close
    env["ADA_SNOOZE_MINUTES"] = snooze_minutes
    if focus_app:
        env["ADA_FOCUS_APP"] = focus_app
    if click_url:
        env["ADA_CLICK_URL"] = click_url
    try:
        subprocess.Popen(
            [alert_script, cmd, duration, code],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


if __name__ == "__main__":
    main()
