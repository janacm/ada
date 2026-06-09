#!/usr/bin/env python3
# =============================================================
# iyf-paseo-watch.py — the poll/diff loop behind iyf-paseo-watch.sh
# -------------------------------------------------------------
# Kept in Python (not bash) because the loop needs per-agent state
# keyed by arbitrary id strings — i.e. associative arrays — and macOS
# still ships bash 3.2, which doesn't have them. python3 is already a
# hard dependency of this repo (JSON parsing + the snooze daemon), so
# this mirrors the existing iyf-show-alert.sh + iyf-snooze-daemon.py
# split: a bash front door, a python worker.
#
# It polls the Paseo daemon via the CLI, diffs each agent's status
# between snapshots, and shells out to the shared launcher when a turn
# finishes / fails, or a new permission request appears. See
# iyf-paseo-watch.sh for the full rationale and the env knobs.
#
# Inherited environment:
#   PASEO_BIN  resolved paseo CLI path (from the .sh)
#   IYF_DIR    dir holding iyf-show-alert.sh (from the .sh)
#   plus all the IYF_* knobs documented in iyf-paseo-watch.sh
# =============================================================
import hashlib
import json
import os
import subprocess
import sys
import time

PASEO = os.environ.get("PASEO_BIN") or "paseo"
IYF_DIR = os.environ.get("IYF_DIR") or os.path.dirname(os.path.abspath(__file__))
LAUNCHER = os.path.join(IYF_DIR, "iyf-show-alert.sh")


def _int(name, default):
    try:
        return int(float(os.environ.get(name) or default))
    except (TypeError, ValueError):
        return default


THRESHOLD = _int("IYF_PASEO_THRESHOLD", 45)
POLL = max(1, _int("IYF_PASEO_POLL", 3))
EVENTS = set((os.environ.get("IYF_PASEO_EVENTS") or "finish error permission").split())

# Default to staying silent while Paseo itself is frontmost (you're watching).
# An explicit empty value disables that, matching the bash ${var-default} feel.
_paseo_skip = os.environ.get("IYF_PASEO_SKIP_WHEN_ACTIVE")
if _paseo_skip is None:
    _paseo_skip = "sh.paseo.desktop"
SKIP = (_paseo_skip + " " + (os.environ.get("IYF_SKIP_WHEN_ACTIVE") or "")).split()


def run_json(args):
    """Run a paseo subcommand and parse its --json output; [] on any failure."""
    try:
        out = subprocess.run(
            [PASEO, *args, "--json"],
            capture_output=True, text=True, timeout=20,
        ).stdout
        data = json.loads(out)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def lsappinfo(key, target):
    try:
        raw = subprocess.run(
            ["lsappinfo", "info", "-only", key, target],
            capture_output=True, text=True, timeout=3,
        ).stdout.strip()
    except Exception:
        return ""
    # raw looks like:  "LSBundleID"="sh.paseo.desktop"
    if '="' in raw:
        return raw.rsplit('="', 1)[1].rstrip('"')
    return raw


def should_skip_active():
    """True when the frontmost app means you're already watching, so an alert
    would just be noise. Errs toward showing (False) if it can't tell."""
    skip = [e for e in SKIP if e]
    if not skip:
        return False
    try:
        front = subprocess.run(
            ["lsappinfo", "front"], capture_output=True, text=True, timeout=3,
        ).stdout.strip()
    except Exception:
        return False
    if not front:
        return False
    bid = lsappinfo("bundleid", front)
    name = lsappinfo("name", front)
    for e in skip:
        if bid == e or (name and e in name):
            return True
    return False


def fmt_duration(s):
    s = int(s)
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm %ds" % (s // 60, s % 60)
    return "%dh %dm" % (s // 3600, (s % 3600) // 60)


def fire(label, duration, code):
    if len(label) > 120:
        label = label[:119] + "…"
    try:
        subprocess.Popen(
            [LAUNCHER, label, duration, str(code)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as exc:
        print("iyf-paseo-watch: launcher failed: %s" % exc, file=sys.stderr)


def agents_snapshot():
    """Map id -> (status, name, provider_base)."""
    snap = {}
    for a in run_json(["ls"]):
        if not isinstance(a, dict):
            continue
        aid = a.get("id") or a.get("shortId")
        if not aid:
            continue
        status = (a.get("status") or "").strip()
        name = str(a.get("name") or a.get("shortId") or aid or "agent").strip()
        provider = str(a.get("provider") or "").split("/")[0]
        snap[aid] = (status, name, provider)
    return snap


def permits_snapshot():
    """Map dedupe-key -> (label, agent-hint). Dedupe by the whole request object
    so we don't depend on Paseo's internal field names."""
    out = {}
    for a in run_json(["permit", "ls"]):
        key = hashlib.sha1(
            json.dumps(a, sort_keys=True, default=str).encode()
        ).hexdigest()[:16]
        label, agent = "", ""
        if isinstance(a, dict):
            for k in ("toolName", "tool", "title", "summary", "reason", "action", "name"):
                if a.get(k):
                    label = str(a[k]).strip()
                    break
            for k in ("agentName", "agentTitle", "agent", "agentId", "agentShortId", "sessionId"):
                if a.get(k):
                    agent = str(a[k]).strip()
                    break
        out[key] = (label or "permission needed", agent)
    return out


def main():
    prev_status = {}   # id -> status
    run_start = {}     # id -> epoch when it entered 'running'
    names = {}         # id -> friendly name
    seen_perm = set()  # currently-pending permission keys
    seeded = False

    while True:
        now = int(time.time())

        snap = agents_snapshot()
        for aid, (status, name, provider) in snap.items():
            names[aid] = name
            prev = prev_status.get(aid)

            # Entering 'running' — stamp a start (even for agents already running
            # at startup, so a later finish never reports a bogus huge duration).
            if status == "running" and prev != "running":
                run_start[aid] = now

            if seeded and prev == "running" and status != prev:
                elapsed = now - run_start.get(aid, now)
                tag = ("%s · %s" % (provider, name)) if provider else name
                if status == "idle" and "finish" in EVENTS \
                        and elapsed >= THRESHOLD and not should_skip_active():
                    fire("Paseo · " + tag, fmt_duration(elapsed), 0)
                elif status == "error" and "error" in EVENTS and not should_skip_active():
                    fire("Paseo · failed · " + tag, fmt_duration(elapsed), 1)
                run_start.pop(aid, None)

            prev_status[aid] = status

        # Forget agents that vanished (closed/archived) so the maps don't grow.
        for aid in list(prev_status):
            if aid not in snap:
                prev_status.pop(aid, None)
                run_start.pop(aid, None)
                names.pop(aid, None)

        # --- pending permission requests ---
        if "permission" in EVENTS:
            perms = permits_snapshot()
            if seeded:
                for key, (label, agent) in perms.items():
                    if key in seen_perm or should_skip_active():
                        continue
                    who = names.get(agent, agent)
                    lbl = "Paseo · needs you" + (" · " + who if who else "")
                    if label:
                        lbl += " — " + label
                    fire(lbl, "permission", 0)
            seen_perm = set(perms)

        seeded = True
        time.sleep(POLL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
