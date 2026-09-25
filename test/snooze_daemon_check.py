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
import json
import os
import stat
import sys
import tempfile
import subprocess
import threading
import time
import types

MOD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "lib", "ada-snooze-daemon.py")
TMP = tempfile.mkdtemp(prefix="snooze-check.")
# The module shares the process-wide subprocess and time modules, so every
# patch below is undone right after the scenario that needs it.
REAL_POPEN = subprocess.Popen
REAL_SLEEP = time.sleep
REAL_TIME = time.time
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


class Clock:
    """Wall clock for a snooze: real time plus whatever the daemon has "slept",
    so a 5-minute snooze passes instantly. on_sleep(clock, seconds) runs before
    each sleep, to act mid-snooze (release the hold, jump the clock)."""
    def __init__(self, on_sleep=None):
        self.offset = 0.0
        self.sleeps = []
        self.on_sleep = on_sleep

    def time(self):
        return REAL_TIME() + self.offset

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        if self.on_sleep:
            self.on_sleep(self, seconds)
        self.offset += seconds


def drive(mod, handoff, method, path_fn, clock=None):
    """Run mod.main() with a client thread sending one request once the handoff
    appears. path_fn(token) builds the request path. Returns the HTTP status."""
    mod.daemonize = lambda: None
    clock = clock or Clock()
    mod.time.sleep = clock.sleep
    mod.time.time = clock.time
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
        time.time = REAL_TIME
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

# --- mute ----------------------------------------------------------------------------------
marker = os.path.join(TMP, "muted", "nested", "claude-abc")
handoff = os.path.join(TMP, "h7")
script, out = recorder("mute-relaunch")
mod, _ = load(argv(handoff, script=script, focus="com.mitchellh.ghostty"),
              env={"ADA_MUTE_FILE": marker})
opened = []
mod.subprocess.Popen = lambda cmd, **kw: opened.append(cmd)
status = drive(mod, handoff, "GET", lambda tok: "/%s/mute" % tok)
subprocess.Popen = REAL_POPEN
check("a mute request is accepted", status == 200, status)
check("mute writes the marker, creating its directory", os.path.isfile(marker))
check("mute neither relaunches nor focuses anything",
      opened == [] and not os.path.exists(out), opened)
check("the marker holds the alert's label", open(marker).read() == "make build\n",
      repr(open(marker).read()))
check("the marker is private", stat.S_IMODE(os.stat(marker).st_mode) == 0o600,
      oct(os.stat(marker).st_mode))

with open(marker, "w") as f:
    f.write("a much longer stale label\n")
os.chmod(marker, 0o644)
os.utime(marker, (1, 1))
handoff = os.path.join(TMP, "h8")
mod, _ = load(argv(handoff), env={"ADA_MUTE_FILE": marker})
drive(mod, handoff, "GET", lambda tok: "/%s/mute" % tok)
check("muting again restarts the expiry clock", os.stat(marker).st_mtime > 1000,
      os.stat(marker).st_mtime)
check("muting again rewrites the label instead of appending",
      open(marker).read() == "make build\n", repr(open(marker).read()))
check("muting again makes an older marker private",
      stat.S_IMODE(os.stat(marker).st_mode) == 0o600, oct(os.stat(marker).st_mode))

handoff = os.path.join(TMP, "h8b")
args = argv(handoff)
args[3] = "first line\nsecond\tline " + "x" * 300
mod, _ = load(args, env={"ADA_MUTE_FILE": marker})
drive(mod, handoff, "GET", lambda tok: "/%s/mute" % tok)
label = open(marker).read()
check("a multi-line label becomes one line of at most 200 characters",
      label.startswith("first line second line x") and label.count("\n") == 1
      and len(label) == 201, repr(label[:60]) + " len=%d" % len(label))

handoff = os.path.join(TMP, "h9")
log = os.path.join(TMP, "mute-ignored.log")
mod, _ = load(argv(handoff, deadline="1"), env={"ADA_MUTE_FILE": None, "ADA_SNOOZE_LOG": log})
status = drive(mod, handoff, "GET", lambda tok: "/%s/mute" % tok)
os.environ.pop("ADA_SNOOZE_LOG")
trace_text = open(log).read() if os.path.exists(log) else ""
check("mute is ignored when the launcher named no marker",
      status == 200 and "exit without snooze: None" in trace_text, trace_text)

blocker = os.path.join(TMP, "not-a-dir")
open(blocker, "w").close()
handoff = os.path.join(TMP, "h10")
mod, _ = load(argv(handoff), env={"ADA_MUTE_FILE": os.path.join(blocker, "k")})
status = drive(mod, handoff, "GET", lambda tok: "/%s/mute" % tok)
check("an unwritable marker path does not raise", status == 200, status)
target = os.path.join(TMP, "link-target")
open(target, "w").close()
os.utime(target, (1, 1))
link = os.path.join(TMP, "muted", "nested", "link-1")
os.symlink(target, link)
handoff = os.path.join(TMP, "h11")
mod, _ = load(argv(handoff), env={"ADA_MUTE_FILE": link})
status = drive(mod, handoff, "GET", lambda tok: "/%s/mute" % tok)
check("mute does not follow a symlink named like the marker",
      status == 200 and os.stat(target).st_mtime < 1000 and os.path.islink(link),
      os.stat(target).st_mtime)
os.environ.pop("ADA_MUTE_FILE", None)

# --- session-scoped snooze hold ---------------------------------------------------------------
HOLD_DIR = os.path.join(TMP, "ada-snoozed")
hold = os.path.join(HOLD_DIR, "claude-abc")
seen = {}


def peek(clock, seconds):
    if "marker" not in seen and os.path.exists(hold):
        seen["marker"] = open(hold).read()
        seen["at"] = clock.time()


handoff = os.path.join(TMP, "h21")
script, out = recorder("hold-relaunch")
mod, _ = load(argv(handoff, script=script), env={"ADA_SNOOZE_HOLD_FILE": hold})
clock = Clock(peek)
status = drive(mod, handoff, "GET", lambda tok: "/%s/snooze/5" % tok, clock)
wake, owner = seen.get("marker", "0 ?").split()
check("a session snooze writes the hold marker, creating its directory",
      "marker" in seen and owner == mod.token, seen)
check("the hold lasts exactly the snooze", abs(int(wake) - (seen.get("at", 0) + 300)) <= 1,
      (wake, seen.get("at")))
check("the hold is lifted before the snoozed alert is relaunched",
      wait_file(out) and not os.path.exists(hold), os.path.exists(hold))
check("the daemon never sleeps longer than its poll step",
      clock.sleeps and max(clock.sleeps) <= mod.POLL_SECONDS, clock.sleeps)


def release(clock, seconds):
    if clock.offset >= 60 and os.path.exists(hold):
        os.remove(hold)


handoff = os.path.join(TMP, "h22")
script, out = recorder("released")
log = os.path.join(TMP, "released.log")
mod, _ = load(argv(handoff, script=script),
              env={"ADA_SNOOZE_HOLD_FILE": hold, "ADA_SNOOZE_LOG": log})
clock = Clock(release)
# Record the relaunch synchronously: the recorder script writes its file after
# Popen returns, so checking for that file could pass before it lands.
launched = []
mod.subprocess.Popen = lambda cmd, **kw: launched.append(cmd)
drive(mod, handoff, "GET", lambda tok: "/%s/snooze/30" % tok, clock)
subprocess.Popen = REAL_POPEN
os.environ.pop("ADA_SNOOZE_LOG")
check("a released hold ends the snooze without re-showing the alert",
      launched == [] and "snooze released early" in open(log).read(),
      (launched, open(log).read()))
check("a released hold ends the daemon at its next poll, not at the wake time",
      clock.offset < 60 + 2 * mod.POLL_SECONDS, clock.offset)


def replace(clock, seconds):
    if clock.offset >= 60 and "replaced" not in seen:
        seen["replaced"] = True
        with open(hold, "w") as f:
            f.write("%d newer-token\n" % (clock.time() + 600))


handoff = os.path.join(TMP, "h23")
script, out = recorder("replaced")
mod, _ = load(argv(handoff, script=script), env={"ADA_SNOOZE_HOLD_FILE": hold})
launched = []
mod.subprocess.Popen = lambda cmd, **kw: launched.append(cmd)
drive(mod, handoff, "GET", lambda tok: "/%s/snooze/5" % tok, Clock(replace))
subprocess.Popen = REAL_POPEN
check("a hold replaced by a newer snooze is left to that snooze",
      launched == [] and "newer-token" in open(hold).read(), launched)
os.remove(hold)


def lid_shut(clock, seconds):
    if len(clock.sleeps) == 1:
        clock.offset += 3600  # the Mac slept through the rest of the snooze


handoff = os.path.join(TMP, "h24")
script, out = recorder("lid")
mod, _ = load(argv(handoff, script=script), env={"ADA_SNOOZE_HOLD_FILE": hold})
clock = Clock(lid_shut)
drive(mod, handoff, "GET", lambda tok: "/%s/snooze/30" % tok, clock)
check("the snooze wakes by the wall clock, however long the sleep ran",
      wait_file(out) and len(clock.sleeps) == 1, clock.sleeps)

handoff = os.path.join(TMP, "h25")
script, out = recorder("unwritable-hold")
mod, _ = load(argv(handoff, script=script),
              env={"ADA_SNOOZE_HOLD_FILE": os.path.join(blocker, "claude-abc")})
drive(mod, handoff, "GET", lambda tok: "/%s/snooze/5" % tok)
check("an unwritable hold falls back to a plain snooze that still relaunches", wait_file(out))
os.environ.pop("ADA_SNOOZE_HOLD_FILE", None)

target = os.path.join(TMP, "hold-target")
with open(target, "w") as f:
    f.write("untouched\n")
os.makedirs(HOLD_DIR, exist_ok=True)
os.symlink(target, hold)
seen.clear()
handoff = os.path.join(TMP, "h26")
script, out = recorder("symlinked-hold")
mod, _ = load(argv(handoff, script=script), env={"ADA_SNOOZE_HOLD_FILE": hold})
drive(mod, handoff, "GET", lambda tok: "/%s/snooze/5" % tok, Clock(peek))
check("a symlink at the hold path is replaced, never written through",
      open(target).read() == "untouched\n" and seen.get("marker", "").split()[1:2] == [mod.token],
      (open(target).read(), seen))
check("the relaunch still happens after replacing it", wait_file(out))
if os.path.lexists(hold):
    os.remove(hold)
os.environ.pop("ADA_SNOOZE_HOLD_FILE", None)

# --- request parsing: which paths become a decision ---------------------------------------
class Request:
    """Just enough of a handler for do_GET: a path, and a server to decide on."""
    def __init__(self, path):
        self.path = path
        self.server = types.SimpleNamespace(ada_result=None, ada_done=False)

    def _respond(self, *_):
        pass


def decision(mod, path):
    req = Request("/%s/%s" % (mod.token, path))
    mod.Handler.do_GET(req)
    return req.server.ada_result


pause_cli = os.path.join(TMP, "pause-cli")
with open(pause_cli, "w") as fh:
    fh.write("#!/bin/bash\n")
TARGETS = '[{"url":"claude://resume?session=x"},{"app":"com.mitchellh.ghostty"},null]'
mod, _ = load(argv(os.path.join(TMP, "p0")), env={"ADA_PAUSE_CLI": pause_cli,
                                                  "ADA_SUMMARY_TARGETS": TARGETS})
check("pause/30 is a decision when the launcher named the pause CLI",
      decision(mod, "pause/30") == ("pause", 30), decision(mod, "pause/30"))
check("pause/1 and pause/1440 are the bounds",
      (decision(mod, "pause/1"), decision(mod, "pause/1440")) == (("pause", 1), ("pause", 1440)))
bad = [p for p in ("pause/0", "pause/1441", "pause/²", "pause/٣", "pause/12a",
                   "pause/30/x", "pause/", "pause", "snooze/²", "snooze/٣",
                   "open/3", "open/2", "open/-1", "open/1/x", "open/007", "open/")
       if decision(mod, p) is not None]
check("malformed pause, snooze and open paths decide nothing", bad == [], bad)
check("open/0 and open/1 are the rows with a target",
      (decision(mod, "open/0"), decision(mod, "open/1")) == (("open", 0), ("open", 1)))
check("the targets parse index-aligned, URL and app",
      mod.targets == [("claude://resume?session=x", ""), ("", "com.mitchellh.ghostty"), None],
      mod.targets)
check("minutes() takes ASCII 1..1440 only",
      [mod.minutes(x) for x in ("5", "1440", "0", "1441", "²", "٣", "12a", "", None, "00005")]
      == [5, 1440, None, None, None, None, None, None, None, None])

mod, _ = load(argv(os.path.join(TMP, "p0")), env={"ADA_PAUSE_CLI": os.path.join(TMP, "nope"),
                                                  "ADA_SUMMARY_TARGETS": "not json"})
check("a pause CLI that is not a file is ignored", mod.pause_cli == "" and
      decision(mod, "pause/30") is None, mod.pause_cli)
check("malformed targets JSON opens nothing", mod.targets == [] and decision(mod, "open/0") is None)
for text, want in (('{"url":"claude://x"}', []),
                   ('[{"url":"claude://x\\ny"},{"url":"no scheme"},{"app":"bad id!"},'
                    '{"url":"-x:y"},{"app":"com.a","url":7},"str",5]',
                    [None, None, None, None, ("", "com.a"), None, None]),
                   (json.dumps([{"url": "a:" + "x" * 2047}]), [None]),
                   (json.dumps([None] * 60), [None] * 50)):
    got = mod.parse_targets(text)
    check("targets %s... parse to %s" % (text[:24], want[:3]), got == want, got)
os.environ.pop("ADA_PAUSE_CLI", None)
os.environ.pop("ADA_SUMMARY_TARGETS", None)

# --- pause/<n>: run the pause CLI ------------------------------------------------------------
cli_out = os.path.join(TMP, "pause-cli.out")
with open(pause_cli, "w") as fh:
    fh.write('#!/bin/bash\nprintf "%%s|%%s|%%s\\n" "$#" "$1" "${ADA_PAUSE_FILE:-}" > %s\n' % cli_out)
handoff = os.path.join(TMP, "p1")
script, out = recorder("pause-ok")
log = os.path.join(TMP, "pause-ok.log")
mod, _ = load(argv(handoff, script=script),
              env={"ADA_PAUSE_CLI": pause_cli, "ADA_PAUSE_FILE": "/some/paused", "ADA_SNOOZE_LOG": log})
status = drive(mod, handoff, "GET", lambda tok: "/%s/pause/30" % tok)
check("a pause request runs the pause CLI with the minutes and the daemon's env",
      status == 200 and open(cli_out).read() == "1|30|/some/paused\n",
      open(cli_out).read() if os.path.exists(cli_out) else "(never ran)")
check("a pause is traced and raises no alert when it worked",
      "pause 30m" in open(log).read() and not wait_file(out, 0.3), open(log).read())
os.environ.pop("ADA_PAUSE_FILE")
os.environ.pop("ADA_SNOOZE_LOG")

handoff = os.path.join(TMP, "p2")
log = os.path.join(TMP, "pause-ignored.log")
mod, _ = load(argv(handoff, deadline="1"), env={"ADA_PAUSE_CLI": None, "ADA_SNOOZE_LOG": log})
status = drive(mod, handoff, "GET", lambda tok: "/%s/pause/30" % tok)
os.environ.pop("ADA_SNOOZE_LOG")
check("pause is ignored when the launcher named no pause CLI",
      status == 200 and "exit without snooze: None" in open(log).read(), open(log).read())


def failure_recorder(name):
    out = os.path.join(TMP, name + ".out")
    path = os.path.join(TMP, name)
    with open(path, "w") as fh:
        fh.write('#!/bin/bash\n'
                 'printf "%%s|%%s|%%s|%%s|ignore=%%s key=%%s scope=%%s url=%%s snoozed=%%s mins=%%s repo=%%s\\n" '
                 '"$#" "$1" "$2" "$3" "$ADA_IGNORE_PAUSE" "${ADA_SESSION_KEY-unset}" '
                 '"${ADA_SNOOZE_SCOPE-unset}" "${ADA_CLICK_URL-unset}" "${ADA_SNOOZED-unset}" '
                 '"$ADA_SNOOZE_MINUTES" "${ADA_REPO-unset}" > %s\n' % out)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path, out


with open(pause_cli, "w") as fh:
    fh.write('#!/bin/bash\necho "ada-pause: /x is not a pause file; left alone" >&2\n'
             'echo "second line" >&2\nexit 1\n')
handoff = os.path.join(TMP, "p3")
script, out = failure_recorder("pause-failed")
mod, _ = load(argv(handoff, script=script),
              env={"ADA_PAUSE_CLI": pause_cli, "ADA_SESSION_KEY": "claude-abc",
                   "ADA_SNOOZE_SCOPE": "session", "ADA_CLICK_URL": "claude://x",
                   "ADA_SNOOZED": "1", "ADA_REPO": "repo"})
drive(mod, handoff, "GET", lambda tok: "/%s/pause/30" % tok)
for k in ("ADA_SESSION_KEY", "ADA_SNOOZE_SCOPE", "ADA_CLICK_URL", "ADA_SNOOZED", "ADA_REPO"):
    os.environ.pop(k)
check("a failed pause raises an alert that ignores the pause and belongs to no session",
      wait_file(out) and open(out).read() ==
      "3|⚠️ Couldn't pause alerts: /x is not a pause file; left alone||0|ignore=1 "
      "key=unset scope=unset url=unset snoozed=unset mins= repo=\n",
      open(out).read() if os.path.exists(out) else "(no alert)")

with open(pause_cli, "w") as fh:
    fh.write("#!/bin/bash\nexit 3\n")
handoff = os.path.join(TMP, "p4")
script, out = failure_recorder("pause-silent")
mod, _ = load(argv(handoff, script=script), env={"ADA_PAUSE_CLI": pause_cli})
drive(mod, handoff, "GET", lambda tok: "/%s/pause/5" % tok)
check("a pause CLI that fails without a word still raises the alert",
      wait_file(out) and "Couldn't pause alerts: exit status 3|" in open(out).read(),
      open(out).read() if os.path.exists(out) else "(no alert)")

handoff = os.path.join(TMP, "p4b")
mod, _ = load(argv(handoff, script=os.path.join(TMP, "no-such-launcher")),
              env={"ADA_PAUSE_CLI": pause_cli})
real_run = mod.subprocess.run


def timeout_run(*a, **kw):
    raise subprocess.TimeoutExpired("ada-pause.sh", 10)


mod.subprocess.run = timeout_run
status = drive(mod, handoff, "GET", lambda tok: "/%s/pause/5" % tok)
subprocess.run = real_run
check("a pause CLI that hangs, with no launcher to report it, does not raise", status == 200, status)
os.environ.pop("ADA_PAUSE_CLI", None)

# --- open/<i>: a summary row -----------------------------------------------------------------
for i, want in ((1, ["open", "-b", "com.mitchellh.ghostty"]), (0, ["open", "claude://resume?session=x"])):
    handoff = os.path.join(TMP, "p10-%d" % i)
    mod, _ = load(argv(handoff, focus="com.other.app", url="claude://other"),
                  env={"ADA_SUMMARY_TARGETS": TARGETS})
    opened = []
    mod.subprocess.Popen = lambda cmd, **kw: opened.append(cmd)
    status = drive(mod, handoff, "GET", lambda tok, i=i: "/%s/open/%d" % (tok, i))
    subprocess.Popen = REAL_POPEN
    check("open/%d opens that row's own target, not the alert's" % i, opened == [want], opened)
os.environ.pop("ADA_SUMMARY_TARGETS", None)

# --- the pause file, read by lib/ada-pause.sh's rule -------------------------------------------
pf = os.path.join(TMP, "paused")


def put(text):
    if os.path.lexists(pf):
        os.remove(pf)
    with open(pf, "w") as fh:
        fh.write(text)


reads = []
for text in ("1790000000\n", "0000000002089\n", "0", "", "soon\n", "12 34\n", "1" * 16 + "\n"):
    put(text)
    reads.append(mod.read_pause_until(pf))
check("read_pause_until reads a decimal first line and nothing else",
      reads == [1790000000, 2089, 0, None, None, None, None], reads)
os.remove(pf)
os.symlink(os.path.join(TMP, "link-target"), pf)
check("a symlink is not a pause file", mod.read_pause_until(pf) is None)
os.remove(pf)
os.mkdir(pf)
check("a directory is not a pause file", mod.read_pause_until(pf) is None)
os.rmdir(pf)
check("no file is no pause", mod.read_pause_until(pf) is None)

# --- the pause timer ----------------------------------------------------------------------------
def timer_recorder(name):
    out = os.path.join(TMP, name + ".out")
    path = os.path.join(TMP, name)
    with open(path, "w") as fh:
        fh.write('#!/bin/bash\nprintf "%%s|%%s|%%s flush=%%s\\n" "$1" "$2" "$3" "$ADA_PAUSE_FLUSH" > %s\n' % out)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path, out


def run_timer(minutes_left, on_sleep=None, launcher=None, record=True, until=None):
    """pause_timer() on a fake clock. Returns (clock, launches); a launch is
    recorded instead of run unless record is False."""
    clock = Clock(on_sleep)
    mod.time.time, mod.time.sleep = clock.time, clock.sleep
    if until is None:
        until = int(clock.time()) + minutes_left * 60
    launches = []
    if record:
        mod.subprocess.Popen = lambda cmd, **kw: launches.append((cmd, kw["env"].get("ADA_PAUSE_FLUSH")))
    try:
        mod.pause_timer(until, pf, launcher or "/usr/bin/true")
    finally:
        time.time, time.sleep = REAL_TIME, REAL_SLEEP
        subprocess.Popen = REAL_POPEN
    return clock, launches, until


clock = Clock()
put("%d\n" % (int(clock.time()) + 300))
launcher, out = timer_recorder("timer")
mod, _ = load(argv(os.path.join(TMP, "t0")))
clock, launches, _ = run_timer(0, launcher=launcher, record=False,
                               until=int(open(pf).read()))
check("the timer runs the launcher in flush mode once the pause is over",
      wait_file(out) and open(out).read() == "||0 flush=ended\n",
      open(out).read() if os.path.exists(out) else "(never ran)")
check("the timer never sleeps longer than its poll step, and waits the whole pause",
      clock.sleeps and max(clock.sleeps) <= mod.POLL_SECONDS and sum(clock.sleeps) >= 299,
      (len(clock.sleeps), sum(clock.sleeps)))


def rewrite(clock, seconds):
    if clock.offset >= 60:
        put("%d\n" % (int(clock.time()) + 3600))


put("%d\n" % (int(REAL_TIME()) + 300))
clock, launches, _ = run_timer(0, rewrite, until=int(open(pf).read()))
check("a newer pause retires the old timer without a summary", launches == [] and
      clock.offset < 60 + 2 * mod.POLL_SECONDS, (launches, clock.offset))


def resume(clock, seconds):
    if clock.offset >= 60 and os.path.exists(pf):
        os.remove(pf)


put("%d\n" % (int(REAL_TIME()) + 300))
clock, launches, _ = run_timer(0, resume, until=int(open(pf).read()))
check("a resume before the end retires the timer (resume shows the summary itself)",
      launches == [], launches)


def status_cleanup(clock, seconds):
    # `ada-pause status` deletes an expired pause file: here, during the sleep
    # that carries the timer past the end.
    if clock.time() + seconds >= seen["until"] and os.path.exists(pf):
        os.remove(pf)


seen["until"] = int(REAL_TIME()) + 60
put("%d\n" % seen["until"])
clock, launches, _ = run_timer(0, status_cleanup, until=seen["until"])
check("the timer still flushes once when the expired file was cleaned up meanwhile",
      launches == [(["/usr/bin/true", "", "", "0"], "ended")] and not os.path.exists(pf),
      launches)

if os.path.lexists(pf):
    os.remove(pf)
os.symlink(os.path.join(TMP, "link-target"), pf)
clock, launches, _ = run_timer(0, until=int(REAL_TIME()) + 300)
check("a symlink at the pause path is no pause of ours, so the timer leaves it",
      launches == [] and clock.sleeps == [], (launches, clock.sleeps))
os.remove(pf)


def lid(clock, seconds):
    if len(clock.sleeps) == 1:
        clock.offset += 7200


put("%d\n" % (int(REAL_TIME()) + 1800))
clock, launches, _ = run_timer(0, lid, until=int(open(pf).read()))
check("a Mac that slept through the end flushes after one more step",
      len(launches) == 1 and len(clock.sleeps) == 1, (launches, clock.sleeps))

put("%d\n" % (int(REAL_TIME()) + 1))
mod.subprocess.Popen = no_open
clock = Clock()
mod.time.time, mod.time.sleep = clock.time, clock.sleep
try:
    mod.pause_timer(int(open(pf).read()), pf, "/nonexistent")
    check("a launcher that cannot start does not raise out of the timer", True)
except Exception as exc:  # noqa: BLE001
    check("a launcher that cannot start does not raise out of the timer", False, exc)
finally:
    time.time, time.sleep = REAL_TIME, REAL_SLEEP
    subprocess.Popen = REAL_POPEN
os.remove(pf)

# --pause-timer is its own mode; bad arguments exit 2 before it detaches.
codes = [subprocess.run([sys.executable, MOD_PATH, "--pause-timer"] + args,
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=10).returncode
         for args in (["soon", pf, "/l"], ["0", pf, "/l"], ["5", "", "/l"], ["5", pf, ""],
                      ["5", pf], ["5", pf, "/l", "extra"])]
check("--pause-timer refuses malformed arguments with exit 2", codes == [2] * 6, codes)

# --- binding never waits on reverse DNS ----------------------------------------------------
import socket
real_getfqdn = socket.getfqdn
def no_dns(*_):
    raise AssertionError("server_bind did a reverse-DNS lookup")
socket.getfqdn = no_dns
try:
    mod, _ = load(argv(os.path.join(TMP, "h12")))
    srv = mod.LoopbackServer(("127.0.0.1", 0), mod.Handler)
    check("binding the loopback server does no reverse-DNS lookup",
          srv.server_name == "127.0.0.1" and srv.server_port == srv.server_address[1],
          (srv.server_name, srv.server_port))
    srv.server_close()
except AssertionError as exc:
    check("binding the loopback server does no reverse-DNS lookup", False, exc)
finally:
    socket.getfqdn = real_getfqdn

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
