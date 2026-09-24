#!/usr/bin/env python3
"""Component test for the ada-paseo-watch helpers that paseo_diff_check.py fakes.

paseo_diff_check.py replaces run_json, fire and should_skip_active to drive the
diff loop in isolation. This file covers those functions for real: the paseo
CLI and lsappinfo are small stub scripts, and fire() spawns a recorder in place
of the launcher. Run by test/ada-paseo-watch.bats with test/stubs on PATH (for
lsappinfo); exits non-zero on any failure.
"""
import importlib.util
import os
import stat
import sys
import tempfile
import time

MOD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "lib", "ada-paseo-watch.py")
TMP = tempfile.mkdtemp(prefix="paseo-helpers.")
FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("ok - %s" % name)
    else:
        print("FAIL - %s %s" % (name, detail))
        FAILURES.append(name)


def load_mod(env):
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    spec = importlib.util.spec_from_file_location("pw_helpers", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def script(name, body):
    path = os.path.join(TMP, name)
    with open(path, "w") as fh:
        fh.write("#!/bin/bash\n" + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


BASE = {"ADA_PASEO_SKIP_WHEN_ACTIVE": "", "ADA_SKIP_WHEN_ACTIVE": None,
        "ADA_PASEO_THRESHOLD": None, "ADA_PASEO_POLL": None, "PASEO_BIN": None}

# --- module-level config ---------------------------------------------------------
m = load_mod(dict(BASE, ADA_PASEO_THRESHOLD="soon", ADA_PASEO_POLL="0"))
check("a non-numeric threshold falls back to the default", m.THRESHOLD == 45, m.THRESHOLD)
check("the poll interval is at least one second", m.POLL == 1, m.POLL)

m = load_mod(dict(BASE, ADA_PASEO_SKIP_WHEN_ACTIVE=None, ADA_SKIP_WHEN_ACTIVE="Termius"))
check("an unset Paseo skip list defaults to the Paseo app, plus the shared list",
      m.SKIP == ["sh.paseo.desktop", "Termius"], m.SKIP)

# --- fmt_duration ------------------------------------------------------------------
m = load_mod(BASE)
check("fmt_duration seconds", m.fmt_duration(42) == "42s", m.fmt_duration(42))
check("fmt_duration minutes", m.fmt_duration(125) == "2m 5s", m.fmt_duration(125))
check("fmt_duration hours", m.fmt_duration(3720) == "1h 2m", m.fmt_duration(3720))

# --- run_json against a stub CLI ---------------------------------------------------
m.PASEO = script("paseo-list", 'echo \'[{"id": "a1"}]\'\n')
check("run_json returns the parsed list", m.run_json(["ls"]) == [{"id": "a1"}])
m.PASEO = script("paseo-object", 'echo \'{"id": "a1"}\'\n')
check("run_json turns a non-list document into []", m.run_json(["ls"]) == [])
m.PASEO = script("paseo-garbage", "echo 'daemon not running'\n")
check("run_json turns unparseable output into []", m.run_json(["ls"]) == [])
m.PASEO = os.path.join(TMP, "no-such-paseo")
check("run_json survives a missing CLI", m.run_json(["ls"]) == [])

# --- agents_snapshot / permits_snapshot shapes -------------------------------------
m.run_json = lambda args: ["not a dict", {"status": "idle"},
                           {"shortId": "s9", "status": " running ", "provider": "codex/gpt"},
                           {"id": "a1", "name": "fixer", "status": "idle"}]
snap = m.agents_snapshot()
check("agents_snapshot skips non-objects and id-less entries, falls back to shortId",
      snap == {"s9": ("running", "s9", "codex"), "a1": ("idle", "fixer", "")}, snap)

m.run_json = lambda args: [{"title": "Run tests", "agentName": "fixer"}, "raw", {}]
perms = m.permits_snapshot()
labels = sorted(perms.values())
check("permits_snapshot labels by the first descriptive field, else a generic label",
      labels == [("Run tests", "fixer", ""), ("permission needed", "", ""),
                 ("permission needed", "", "")],
      labels)

m.run_json = lambda args: [{"title": "Run tests", "agentName": "fixer", "agentId": "a1"},
                           {"title": "Other", "agentId": "gone"}]
ids = sorted(v[2] for v in m.permits_snapshot({"a1": ("running", "fixer", "")}).values())
check("permits_snapshot takes the agent id only when it names a known agent",
      ids == ["", "a1"], ids)

# --- should_skip_active against the lsappinfo stub ---------------------------------
m = load_mod(dict(BASE, ADA_PASEO_SKIP_WHEN_ACTIVE="sh.paseo.desktop"))
os.environ["STUB_FRONT_BUNDLEID"] = "sh.paseo.desktop"
check("Paseo frontmost skips the alert", m.should_skip_active() is True)
os.environ["STUB_FRONT_BUNDLEID"] = "com.apple.Safari"
os.environ["STUB_FRONT_NAME"] = "Safari"
check("another app frontmost alerts", m.should_skip_active() is False)
m.SKIP = ["Saf"]
check("a skip entry matches part of the app name", m.should_skip_active() is True)
os.environ.pop("STUB_FRONT_BUNDLEID")
os.environ.pop("STUB_FRONT_NAME")

m.SKIP = []
check("an empty skip list never asks lsappinfo", m.should_skip_active() is False)

saved_path = os.environ["PATH"]
m.SKIP = ["sh.paseo.desktop"]
os.environ["PATH"] = script("lsappinfo", "exit 0\n").rsplit("/", 1)[0]
check("no frontmost app reported means alert", m.should_skip_active() is False)
os.environ["PATH"] = os.path.join(TMP, "empty-dir")
check("a missing lsappinfo errs toward alerting", m.should_skip_active() is False)
check("lsappinfo() itself returns '' when the tool is missing", m.lsappinfo("name", "x") == "")
script("lsappinfo", "echo plain-value\n")
os.environ["PATH"] = TMP
check("lsappinfo() passes through a value with no key=value shape",
      m.lsappinfo("name", "x") == "plain-value", m.lsappinfo("name", "x"))
os.environ["PATH"] = saved_path

# --- fire: the mute key reaches the launcher ----------------------------------------
keyrec = os.path.join(TMP, "fired-key.txt")
m.LAUNCHER = script("launcher-key",
                    'printf "%%s|%%s\\n" "$ADA_SESSION_KEY" "$ADA_SESSION_KIND" >> %s\n' % keyrec)
m.fire("finished", "3s", 0, "a1")
m.fire("needs you", "permission", 0)
for _ in range(100):
    if os.path.exists(keyrec) and len(open(keyrec).read().splitlines()) >= 2:
        break
    time.sleep(0.02)
keys = sorted(open(keyrec).read().splitlines()) if os.path.exists(keyrec) else []
check("fire passes paseo-<agent id> as the session key, and none without an id",
      keys == sorted(["paseo-a1|agent", "|agent"]),
      keys)

# --- fire: label clipping and a launcher that can't start --------------------------
record = os.path.join(TMP, "fired.txt")
m.LAUNCHER = script("launcher", 'printf "%%s|%%s|%%s\\n" "$1" "$2" "$3" >> %s\n' % record)
m.fire("x" * 200, "3s", 1)
for _ in range(100):
    if os.path.exists(record):
        break
    time.sleep(0.02)
fired = open(record).read().strip() if os.path.exists(record) else ""
label = fired.split("|")[0]
check("fire clips a long label to 120 characters ending in an ellipsis",
      len(label) == 120 and label.endswith("…") and fired.endswith("|3s|1"), fired)

m.LAUNCHER = os.path.join(TMP, "no-such-launcher")
err = os.path.join(TMP, "stderr.txt")
real_stderr = sys.stderr
with open(err, "w") as sys.stderr:
    m.fire("x", "1s", 0)
sys.stderr = real_stderr
check("a launcher that cannot start is reported, not raised",
      "launcher failed" in open(err).read())

# --- main: vanished agents are forgotten --------------------------------------------
class StopLoop(Exception):
    pass


m = load_mod(dict(BASE, ADA_PASEO_THRESHOLD="0"))
snaps = iter([
    [{"id": "a1", "status": "running", "name": "one"}],
    [],                                                  # a1 closed mid-turn
    [{"id": "a1", "status": "idle", "name": "one"}],     # same id reappears idle
])
fires = []
m.run_json = lambda args: [] if args[0] == "permit" else next(snaps, [])
m.fire = lambda label, duration, code: fires.append(label)
m.should_skip_active = lambda: False
polls = {"n": 0}


def fake_sleep(_):
    polls["n"] += 1
    if polls["n"] >= 3:
        raise StopLoop


m.time.sleep = fake_sleep
try:
    m.main()
except StopLoop:
    pass
check("an agent that vanished and came back idle is not reported as finished",
      fires == [], fires)

if FAILURES:
    raise SystemExit("paseo helper checks failed: %s" % ", ".join(FAILURES))
print("all paseo helper checks passed")
