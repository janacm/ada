#!/usr/bin/env python3
# =============================================================
# iyf-snooze-daemon — re-arms the alert after a snooze, or focuses the source app
# -------------------------------------------------------------
# The alert is a sandboxed file:// page in a browser window; once
# it closes, its JS dies, so it cannot bring itself forcefully
# back (browsers block window activation / focus-stealing from
# timers). A "snooze" therefore has to be re-launched by a
# process that outlives the window. That's this daemon.
#
# It binds an ephemeral loopback port, then fully detaches
# (double-fork + setsid) so it survives the terminal that spawned
# it closing. iyf-show-alert.sh reads the port + token it writes
# to a handoff file and bakes them into the alert URL. The page
# then signals a decision with a no-cors fetch:
#
#   GET /<token>/snooze/<minutes>  -> sleep, then relaunch the alert
#   GET /<token>/focus             -> focus the source app, no relaunch
#   GET /<token>/dismiss           -> exit, no relaunch
#
# If the user never decides (plain dismiss with the beacon blocked,
# or auto-close), the daemon self-exits at <deadline> seconds.
#
# Usage:
#   iyf-snooze-daemon.py <handoff> <deadline> <alert_script> \
#       <cmd> <duration> <code> <alert_file> <auto_close> <snooze_minutes> \
#       [focus_bundle_id]
#
# Set IYF_SNOOZE_LOG=/path to append a trace line per request/decision (debug).
# =============================================================
import os
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

# --- args -----------------------------------------------------
try:
    (handoff, deadline_s, alert_script, cmd, duration, code,
     alert_file, auto_close, snooze_minutes) = sys.argv[1:10]
except ValueError:
    sys.exit(0)
focus_app = sys.argv[10] if len(sys.argv) > 10 else os.environ.get("IYF_FOCUS_APP", "")

try:
    deadline = float(deadline_s)
except ValueError:
    deadline = 105.0
if deadline <= 0:
    deadline = 105.0

token = token_urlsafe(8)

# Opt-in tracing: set IYF_SNOOZE_LOG=/path to append a line per request/decision.
_log_path = os.environ.get("IYF_SNOOZE_LOG", "")


def trace(msg):
    if not _log_path:
        return
    try:
        with open(_log_path, "a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


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
        if action == "snooze" and len(parts) >= 3 and parts[2].isdigit():
            mins = int(parts[2])
            if 0 < mins <= 24 * 60:
                self.server.iyf_result = ("snooze", mins)
                self.server.iyf_done = True
        elif action == "dismiss":
            self.server.iyf_result = ("dismiss", 0)
            self.server.iyf_done = True
        elif action == "focus" and focus_app:
            self.server.iyf_result = ("focus", 0)
            self.server.iyf_done = True

    def log_message(self, *args):
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


def main():
    # Bind before detaching so the port is known and bind errors surface
    # while we still share stderr with the caller.
    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    httpd.timeout = 1  # handle_request() returns after 1s of idle
    httpd.iyf_done = False
    httpd.iyf_result = None
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
    while not httpd.iyf_done and (time.time() - start) < deadline:
        try:
            httpd.handle_request()
        except Exception:
            break
    httpd.server_close()

    result = httpd.iyf_result
    if result and result[0] == "focus":
        trace("focus %s" % focus_app)
        try:
            subprocess.Popen(
                ["open", "-b", focus_app],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass
        return

    if not result or result[0] != "snooze":
        trace("exit without snooze: %r" % (result,))
        return

    trace("snooze %dm -> relaunch after sleep" % result[1])
    time.sleep(result[1] * 60)
    env = dict(os.environ)
    env["IYF_SNOOZED"] = "1"
    env["IYF_ALERT_FILE"] = alert_file
    env["IYF_AUTO_CLOSE"] = auto_close
    env["IYF_SNOOZE_MINUTES"] = snooze_minutes
    if focus_app:
        env["IYF_FOCUS_APP"] = focus_app
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
