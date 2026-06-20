#!/usr/bin/env python3
"""Component test for the ada-paseo-watch poll/diff loop.

The .py is the heart of the Paseo integration (running->idle finish, running->
error fail, the seeding gate, permission dedupe, and ADA_PASEO_EVENTS subsetting)
and the bats front-door tests can't reach it. This drives main() directly with a
scripted sequence of `paseo --json` snapshots and a pinned clock, capturing the
fire() calls. Run by test/ada-paseo-watch.bats; exits non-zero on any failure.
"""
import importlib.util
import os

MOD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "lib", "ada-paseo-watch.py")


class StopLoop(Exception):
    pass


def load_mod(env):
    # Set env BEFORE import so module-level THRESHOLD / EVENTS / SKIP pick it up.
    for k, v in env.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    spec = importlib.util.spec_from_file_location("pw_under_test", MOD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_loop(mod, ls_snaps, permit_snaps, times):
    """Run main() over len(ls_snaps) polls; return the list of fire() calls."""
    fires = []
    mod.fire = lambda label, duration, code: fires.append((label, duration, code))
    mod.should_skip_active = lambda: False

    ls_iter = iter(ls_snaps)
    permit_iter = iter(permit_snaps)
    time_iter = iter(times)

    def fake_run_json(args):
        if args and args[0] == "permit":
            return next(permit_iter, [])
        return next(ls_iter, [])

    polls = {"n": 0}

    def fake_sleep(_):
        polls["n"] += 1
        if polls["n"] >= len(ls_snaps):
            raise StopLoop

    mod.run_json = fake_run_json
    mod.time.time = lambda: next(time_iter)
    mod.time.sleep = fake_sleep

    try:
        mod.main()
    except StopLoop:
        pass
    return fires


def agent(aid, status, name="agent-x", provider="claude"):
    return {"id": aid, "status": status, "name": name, "provider": provider}


FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("ok - %s" % name)
    else:
        print("FAIL - %s %s" % (name, detail))
        FAILURES.append(name)


# 1. running -> idle fires a finish (code 0) when elapsed >= threshold.
m = load_mod({"ADA_PASEO_THRESHOLD": "45", "ADA_PASEO_EVENTS": "finish error permission",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[agent("a1", "running")], [agent("a1", "idle")]],
                 [[], []], [1000, 1050])  # elapsed 50 >= 45
check("running->idle fires finish above threshold",
      len(fires) == 1 and fires[0][2] == 0 and "Paseo" in fires[0][0], fires)

# 1b. boundary: elapsed == threshold must fire (proves the gate is `>=`, not `>`).
m = load_mod({"ADA_PASEO_THRESHOLD": "45", "ADA_PASEO_EVENTS": "finish error permission",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[agent("a1", "running")], [agent("a1", "idle")]],
                 [[], []], [1000, 1045])  # elapsed == 45
check("running->idle fires at exactly the threshold", len(fires) == 1, fires)

# 2. running -> idle does NOT fire when elapsed < threshold.
m = load_mod({"ADA_PASEO_THRESHOLD": "45", "ADA_PASEO_EVENTS": "finish error permission",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[agent("a1", "running")], [agent("a1", "idle")]],
                 [[], []], [1000, 1030])  # elapsed 30 < 45
check("running->idle stays silent below threshold", fires == [], fires)

# 3. seeding: an agent already running at the first poll must not fire a bogus
#    finish; the finish only fires on the later transition.
m = load_mod({"ADA_PASEO_THRESHOLD": "0", "ADA_PASEO_EVENTS": "finish error permission",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[agent("a1", "running")], [agent("a1", "running")], [agent("a1", "idle")]],
                 [[], [], []], [1000, 1001, 1002])
check("no spurious fire on the seeding poll; finish fires once on transition",
      len(fires) == 1 and fires[0][2] == 0, fires)

# 4. running -> error fires a failure (code 1), no threshold gate.
m = load_mod({"ADA_PASEO_THRESHOLD": "999", "ADA_PASEO_EVENTS": "finish error permission",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[agent("a1", "running")], [agent("a1", "error")]],
                 [[], []], [1000, 1001])  # elapsed 1, but error ignores threshold
check("running->error fires failure (code 1) regardless of threshold",
      len(fires) == 1 and fires[0][2] == 1 and "failed" in fires[0][0], fires)

# 5. permission seeding + dedupe: a permit already pending at the first poll must
#    NOT alert (seeding), a genuinely new one alerts exactly once, and neither
#    re-alerts on later polls.
perm_a = {"toolName": "bash", "agentId": "a1"}     # pre-existing at startup
perm_b = {"toolName": "write", "agentId": "a2"}    # appears at poll 2
m = load_mod({"ADA_PASEO_EVENTS": "finish error permission",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[], [], []],
                 [[perm_a], [perm_a, perm_b], [perm_a, perm_b]], [1, 2, 3])
check("pre-existing permit is seeded silently; only the new one fires, once",
      len(fires) == 1 and "needs you" in fires[0][0], fires)

# 6. ADA_PASEO_EVENTS subsetting: with only 'error', a finish is suppressed.
m = load_mod({"ADA_PASEO_THRESHOLD": "0", "ADA_PASEO_EVENTS": "error",
              "ADA_PASEO_SKIP_WHEN_ACTIVE": ""})
fires = run_loop(m, [[agent("a1", "running")], [agent("a1", "idle")]],
                 [[], []], [1000, 1100])
check("ADA_PASEO_EVENTS='error' suppresses finish alerts", fires == [], fires)

if FAILURES:
    raise SystemExit("paseo diff-loop checks failed: %s" % ", ".join(FAILURES))
print("all paseo diff-loop checks passed")
