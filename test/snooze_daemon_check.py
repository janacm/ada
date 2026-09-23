#!/usr/bin/env python3
"""In-process component test for lib/ada-snooze-daemon.py.

The bats tests spawn the real detached daemon, which is the right way to test
the loopback trust boundary but cannot reach the rest: a snooze sleeps whole
minutes before it relaunches the alert, and focus/relaunch shell out to `open`
and the launcher. Here the module is loaded with a chosen argv, daemonize() and
time.sleep are patched out, a client thread drives the real HTTP server, and
the relaunch goes to a recorder script. Exits non-zero on any failure.
"""
import http.client
import importlib.util
import os
import stat
import sys
import tempfile
import subprocess
import threading
import time

MOD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "lib", "ada-snooze-daemon.py")
TMP = tempfile.mkdtemp(prefix="snooze-check.")
# The module shares the process-wide subprocess and time modules, so every
# patch below is undone right after the scenario that needs it.
REAL_POPEN = subprocess.Popen
REAL_SLEEP = time.sleep
FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("ok - %s" % name)
    else:
        print("FAIL - %s %s" % (name, detail))
        FAILURES.append(name)


def load(args, env=None):
    """Import the daemon as if run with these argv[1:]. Returns (module, exit code)."""
    for k, v in (env or {}).items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    saved = sys.argv
    sys.argv = [MOD_PATH] + list(args)
    try:
        spec = importlib.util.spec_from_file_location("snooze_under_test", MOD_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, None
    except SystemExit as exc:
        return None, exc.code
    finally:
        sys.argv = saved


def argv(handoff, deadline="5", script="/usr/bin/true", mins="5 10", focus="", url=""):
    return [handoff, deadline, script, "make build", "2m 3s", "0",
            "/tmp/alert.html", "90", mins, focus, url]


def recorder(name):
    """A stand-in launcher that records its args and the env the daemon set."""
    out = os.path.join(TMP, name + ".out")
    path = os.path.join(TMP, name)
    with open(path, "w") as fh:
        fh.write('#!/bin/bash\n'
                 'printf "%%s|%%s|%%s snoozed=%%s file=%%s close=%%s mins=%%s focus=%%s url=%%s\\n" '
                 '"$1" "$2" "$3" "$ADA_SNOOZED" "$ADA_ALERT_FILE" "$ADA_AUTO_CLOSE" '
                 '"$ADA_SNOOZE_MINUTES" "${ADA_FOCUS_APP:-}" "${ADA_CLICK_URL:-}" > %s\n' % out)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path, out


def wait_file(path, seconds=5):
    end = time.time() + seconds
    while time.time() < end:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return True
        REAL_SLEEP(0.02)
    return False


def drive(mod, handoff, method, path_fn):
    """Run mod.main() with a client thread sending one request once the handoff
    appears. path_fn(token) builds the request path. Returns the HTTP status."""
    mod.daemonize = lambda: None
    mod.time.sleep = lambda s: None
    result = {}

    def client():
        if not wait_file(handoff):
            return
        port, token = open(handoff).read().split()
        conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=5)
        conn.request(method, path_fn(token))
        result["status"] = conn.getresponse().status
        conn.close()

    t = threading.Thread(target=client)
    t.start()
    try:
        mod.main()
    finally:
        time.sleep = REAL_SLEEP
    t.join(5)
    return result.get("status")


# --- argument handling --------------------------------------------------------------
_, code = load(["only", "three", "args"])
check("too few arguments exits quietly with 0", code == 0, code)

mod, _ = load(argv(os.path.join(TMP, "h0"), deadline="soon"))
check("a non-numeric deadline falls back to 105s", mod.deadline == 105.0, mod.deadline)
mod, _ = load(argv(os.path.join(TMP, "h0"), deadline="-3"))
check("a non-positive deadline falls back to 105s", mod.deadline == 105.0, mod.deadline)

mod, _ = load(argv(os.path.join(TMP, "h0"))[:9], env={"ADA_FOCUS_APP": "com.env.app",
                                                     "ADA_CLICK_URL": "claude://env"})
check("focus app and click URL fall back to the environment",
      (mod.focus_app, mod.click_url) == ("com.env.app", "claude://env"),
      (mod.focus_app, mod.click_url))
os.environ.pop("ADA_FOCUS_APP")
os.environ.pop("ADA_CLICK_URL")

# --- trace() -------------------------------------------------------------------------
mod, _ = load(argv(os.path.join(TMP, "h0")), env={"ADA_SNOOZE_LOG": TMP})  # a directory
try:
    mod.trace("cannot be written")
    check("an unwritable trace log is ignored", True)
except Exception as exc:  # noqa: BLE001 - the point is that nothing escapes
    check("an unwritable trace log is ignored", False, exc)
os.environ.pop("ADA_SNOOZE_LOG")

# --- _respond survives a client that went away ----------------------------------------
class Gone:
    def write(self, _):
        raise BrokenPipeError


class FakeHandler:
    wfile = Gone()
    def send_response(self, _): pass
    def send_header(self, *_): pass
    def end_headers(self): pass


try:
    mod.Handler._respond(FakeHandler(), 200, b"ok")
    check("a write to a closed connection is swallowed", True)
except Exception as exc:  # noqa: BLE001
    check("a write to a closed connection is swallowed", False, exc)

# --- a real snooze: relaunch the alert with the snoozed environment ----------------------
handoff = os.path.join(TMP, "h1")
script, out = recorder("relaunch")
mod, _ = load(argv(handoff, script=script, focus="com.mitchellh.ghostty", url="claude://resume?session=x"))
status = drive(mod, handoff, "GET", lambda tok: "/%s/snooze/5" % tok)
check("a snooze request is accepted", status == 200, status)
check("the snoozed alert is relaunched with the original label and state",
      wait_file(out) and open(out).read().strip() ==
      "make build|2m 3s|0 snoozed=1 file=/tmp/alert.html close=90 mins=5 10 "
      "focus=com.mitchellh.ghostty url=claude://resume?session=x",
      open(out).read() if os.path.exists(out) else "(never relaunched)")

handoff = os.path.join(TMP, "h2")
mod, _ = load(argv(handoff, script=os.path.join(TMP, "no-such-launcher")))
status = drive(mod, handoff, "GET", lambda tok: "/%s/snooze/1" % tok)
check("a relaunch whose launcher is gone does not raise", status == 200, status)

# --- preflight and focus ------------------------------------------------------------------
handoff = os.path.join(TMP, "h3")
mod, _ = load(argv(handoff, deadline="2"))
status = drive(mod, handoff, "OPTIONS", lambda tok: "/%s/dismiss" % tok)
check("a CORS/PNA preflight gets 204 with no body", status == 204, status)

opened = []
handoff = os.path.join(TMP, "h4")
mod, _ = load(argv(handoff, focus="com.mitchellh.ghostty"))
mod.subprocess.Popen = lambda cmd, **kw: opened.append(cmd)
status = drive(mod, handoff, "GET", lambda tok: "/%s/focus" % tok)
subprocess.Popen = REAL_POPEN
check("focus with no click URL activates the bundle id",
      opened == [["open", "-b", "com.mitchellh.ghostty"]], opened)


def no_open(cmd, **kw):
    raise OSError("no open(1)")


handoff = os.path.join(TMP, "h5")
mod, _ = load(argv(handoff, focus="com.mitchellh.ghostty"))
mod.subprocess.Popen = no_open
status = drive(mod, handoff, "GET", lambda tok: "/%s/focus" % tok)
subprocess.Popen = REAL_POPEN
check("a missing open(1) does not raise", status == 200, status)

# --- failure paths in main() ---------------------------------------------------------------
mod, _ = load(argv(os.path.join(TMP, "missing-dir", "handoff")))
mod.daemonize = lambda: None
mod.main()
check("an unwritable handoff ends the daemon (the page could never reach it)",
      not os.path.exists(os.path.join(TMP, "missing-dir")))

mod, _ = load(argv(os.path.join(TMP, "h6"), deadline="30"))
mod.daemonize = lambda: None
real_handle = mod.HTTPServer.handle_request


def broken(self):
    raise OSError("socket gone")


mod.HTTPServer.handle_request = broken
started = time.time()
mod.main()
mod.HTTPServer.handle_request = real_handle
check("a server error ends the loop instead of spinning until the deadline",
      time.time() - started < 5, time.time() - started)

if FAILURES:
    raise SystemExit("snooze daemon checks failed: %s" % ", ".join(FAILURES))
print("all snooze daemon checks passed")
