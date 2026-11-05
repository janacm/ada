#!/usr/bin/env python3
# =============================================================
# ada-paseo-watch.py — the poll/diff loop behind ada-paseo-watch.sh
# -------------------------------------------------------------
# Kept in Python (not bash) because the loop needs per-agent state
# keyed by arbitrary id strings — i.e. associative arrays — and macOS
# still ships bash 3.2, which doesn't have them. python3 is already a
# hard dependency of this repo (JSON parsing + the snooze daemon), so
# this mirrors the existing ada-show-alert.sh + ada-snooze-daemon.py
# split: a bash front door, a python worker.
#
# It polls the Paseo daemon via the CLI, diffs each agent's status
# between snapshots, and shells out to the shared launcher when a turn
# finishes / fails, or a new permission request appears. See
# ada-paseo-watch.sh for the full rationale and the env knobs.
#
# Inherited environment:
#   PASEO_BIN           resolved paseo CLI path (from the .sh)
#   XPC_SERVICE_NAME    set by launchd; com.ada.paseo-watch turns on the
#                       relaunch rule (see RelaunchWatcher below)
#   ADA_PASEO_RELAUNCH  1 or 0 forces that rule on or off (tests use it)
#   plus all the ADA_* knobs documented in ada-paseo-watch.sh
# (ada-show-alert.sh is found as a sibling of this file, not via the env.)
# =============================================================
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import quote

PASEO = os.environ.get("PASEO_BIN") or "paseo"
# ada-show-alert.sh is always a sibling of this file — both live in lib/ in a dev
# checkout AND in the staged LaunchAgent layout (~/.local/share/ada/lib). Resolve
# it relative to __file__ rather than an inherited ADA_DIR so it can't drift if
# the caller sets ADA_DIR to the wrong base.
# abspath, never realpath: under Homebrew this path runs through the opt symlink,
# and the relaunch rule must keep watching that path, not today's Cellar copy.
SELF = os.path.abspath(__file__)
_HERE = os.path.dirname(SELF)
LAUNCHER = os.path.join(_HERE, "ada-show-alert.sh")


def _int(name, default):
    try:
        return int(float(os.environ.get(name) or default))
    except (TypeError, ValueError):
        return default


THRESHOLD = _int("ADA_PASEO_THRESHOLD", 45)
POLL = max(1, _int("ADA_PASEO_POLL", 3))
EVENTS = set((os.environ.get("ADA_PASEO_EVENTS") or "finish error permission").split())

# Default to staying silent while Paseo itself is frontmost (you're watching).
# An explicit empty value disables that, matching the bash ${var-default} feel.
_paseo_skip = os.environ.get("ADA_PASEO_SKIP_WHEN_ACTIVE")
if _paseo_skip is None:
    _paseo_skip = "sh.paseo.desktop"
SKIP = (_paseo_skip + " " + (os.environ.get("ADA_SKIP_WHEN_ACTIVE") or "")).split()


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


def source_of(provider):
    """The alert's ADA_SOURCE: paseo/<provider>, which `ada-sources off
    paseo/<provider>` switches off (lib/ada-sources.sh), or plain paseo for an
    agent whose provider is unknown or not a name a rule could hold."""
    if provider and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,60}", provider):
        return "paseo/" + provider
    return "paseo"


def repo_of(cwd):
    """The agent's project, for the repo badge and the project switches: the
    folder name of its working directory, which Paseo reports as the workspace
    root (abbreviated with ~). Never git: the watcher is a LaunchAgent, and one
    looking inside ~/Documents can raise a privacy prompt."""
    cwd = (cwd or "").strip().rstrip("/")
    if cwd in ("", "~"):
        return ""
    return cwd.rsplit("/", 1)[-1]


# --- click to open the agent --------------------------------------------------------
# Paseo Desktop opens an existing agent from paseo://h/<server id>/agent/<agent id>
# (Paseo's packages/protocol/src/agent-deep-link.ts; `paseo agent open <id>` builds
# the same link). The server id is the daemon's own, read once from
# `paseo daemon status --json`, which costs about two seconds. It never changes
# for a daemon home, so one success is kept for the life of the loop; a failure
# is asked again at the next alert.
PASEO_APP = "sh.paseo.desktop"
SERVER_ID_RE = re.compile(r"[A-Za-z0-9._~-]{1,128}")
_server_id = None


def server_id():
    """The Paseo daemon's server id, or "" when the CLI can't say."""
    global _server_id
    if _server_id:
        return _server_id
    try:
        out = subprocess.run(
            [PASEO, "daemon", "status", "--json"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        data = json.loads(out)
        sid = str(data.get("serverId") or "").strip() if isinstance(data, dict) else ""
    except Exception:
        sid = ""
    if SERVER_ID_RE.fullmatch(sid):
        _server_id = sid
        return sid
    return ""


def agent_link(agent_id, focus_app=None):
    """The paseo:// link that opens this agent, or "" when clicking should just
    bring Paseo forward: no agent id, no server id, or a click target that is
    not the Paseo app (ADA_FOCUS_APP set to another app, or to "" for none)."""
    if focus_app is None:
        focus_app = os.environ.get("ADA_FOCUS_APP", PASEO_APP)
    if not agent_id or focus_app != PASEO_APP:
        return ""
    sid = server_id()
    if not sid:
        return ""
    return "paseo://h/%s/agent/%s" % (quote(sid, safe=""), quote(agent_id, safe=""))


def fire(label, duration, code, agent_id="", source="paseo", repo=""):
    if len(label) > 120:
        label = label[:119] + "…"
    # The agent id lets the alert's "Mute this agent" button silence this
    # agent; the launcher drops alerts for a muted key (lib/ada-mute.sh).
    env = dict(os.environ)
    env["ADA_SESSION_KEY"] = ("paseo-" + agent_id) if agent_id else ""
    env["ADA_SESSION_KIND"] = "agent"
    env["ADA_SOURCE"] = source
    # Clicking opens this agent in Paseo; with no link the click still brings
    # Paseo forward through ADA_FOCUS_APP, as before.
    env["ADA_CLICK_URL"] = agent_link(agent_id)
    # Set only when known: the launcher reads an empty ADA_REPO as "not a repo",
    # while an unset one lets it ask git about its own cwd, as before.
    if repo:
        env["ADA_REPO"] = repo
    # A session of its own: when this loop exits (a relaunch, an unload), launchd
    # kills whatever is left in the job's process group, and an alert window the
    # launcher backgrounded would close with it.
    try:
        subprocess.Popen(
            [LAUNCHER, label, duration, str(code)],
            env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as exc:
        print("ada-paseo-watch: launcher failed: %s" % exc, file=sys.stderr)


# --- relaunch when the code underneath is replaced ---------------------------------
# A `brew upgrade` points the opt symlink at a new keg and deletes the old one, and
# a re-stage renames a new copy over this file; either way this process would go
# on running the old code until the next login. A different file at the launch
# path means exit RELAUNCH_EXIT, which launchd's KeepAlive restarts (the menu bar's
# RelaunchWatcher in Sources/ADAAlertCore/MenuBarSupport.swift does the same).
# A missing file is not a reason to exit (nor for the menu bar): `brew reinstall`
# renames the keg away for the whole Swift build (ada ships no bottles), so
# "missing" lasts minutes and is followed by a new file. The loop waits for it.
# After an uninstall it lingers, harmlessly, until logout, and the plist's guard
# keeps the next login from starting it (see ada-paseo-watch.sh install).
RELAUNCH_EXIT = 75   # EX_TEMPFAIL, the menu bar's code too
LAUNCHD_LABEL = "com.ada.paseo-watch"


def relaunch_enabled(env=None):
    """Only under the LaunchAgent. A foreground `run` has no launchd to start it
    again, so an editor saving the checkout's copy would just end the loop."""
    env = os.environ if env is None else env
    forced = env.get("ADA_PASEO_RELAUNCH")
    if forced in ("0", "1"):
        return forced == "1"
    return env.get("XPC_SERVICE_NAME") == LAUNCHD_LABEL


def file_identity(path):
    """(device, inode) of path, None when it is gone. stat follows symlinks on
    purpose: the file behind the opt link is the one an upgrade replaces."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


class RelaunchWatcher:
    KEEP, RELAUNCH = "keep", "relaunch"

    def __init__(self, path):
        self.path = path
        self.original = file_identity(path)

    def check(self):
        """KEEP while the launch path is this file or missing (mid-swap, mid-
        reinstall, or uninstalled); RELAUNCH once it is a different file."""
        current = file_identity(self.path)
        if current is None or current == self.original:
            return self.KEEP
        return self.RELAUNCH


def relaunch_watcher(env=None, path=None):
    """The watcher for this run, or None when the rule is off. Also None when the
    script can't be stat'ed at startup: with no original to compare, any file
    that later appeared there would read as a replacement."""
    if not relaunch_enabled(env):
        return None
    watcher = RelaunchWatcher(path or SELF)
    return watcher if watcher.original is not None else None


def agents_snapshot():
    """Map id -> (status, name, provider_base, cwd)."""
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
        cwd = str(a.get("cwd") or "").strip()
        snap[aid] = (status, name, provider, cwd)
    return snap


def permits_snapshot(known_ids=()):
    """Map dedupe-key -> (label, agent-hint, agent-id). Dedupe by the whole
    request object so we don't depend on Paseo's internal field names. The
    agent id is whichever id-ish field names an agent from the current `ls`
    snapshot, so a permission alert carries the same mute key as a finish."""
    out = {}
    for a in run_json(["permit", "ls"]):
        key = hashlib.sha1(
            json.dumps(a, sort_keys=True, default=str).encode()
        ).hexdigest()[:16]
        label, agent, agent_id = "", "", ""
        if isinstance(a, dict):
            for k in ("toolName", "tool", "title", "summary", "reason", "action", "name"):
                if a.get(k):
                    label = str(a[k]).strip()
                    break
            for k in ("agentName", "agentTitle", "agent", "agentId", "agentShortId", "sessionId"):
                if a.get(k):
                    agent = str(a[k]).strip()
                    break
            for k in ("agentId", "agent", "agentShortId", "sessionId", "id"):
                if str(a.get(k) or "").strip() in known_ids:
                    agent_id = str(a[k]).strip()
                    break
        out[key] = (label or "permission needed", agent, agent_id)
    return out


def main():
    prev_status = {}   # id -> status
    run_start = {}     # id -> epoch when it entered 'running'
    names = {}         # id -> friendly name
    seen_perm = set()  # currently-pending permission keys
    seeded = False
    relaunch = relaunch_watcher()

    while True:
        now = int(time.time())

        snap = agents_snapshot()
        for aid, (status, name, provider, cwd) in snap.items():
            names[aid] = name
            prev = prev_status.get(aid)

            # Entering 'running' — stamp a start (even for agents already running
            # at startup, so a later finish never reports a bogus huge duration).
            if status == "running" and prev != "running":
                run_start[aid] = now

            if seeded and prev == "running" and status != prev:
                elapsed = now - run_start.get(aid, now)
                tag = ("%s · %s" % (provider, name)) if provider else name
                where = {"source": source_of(provider), "repo": repo_of(cwd)}
                if status == "idle" and "finish" in EVENTS \
                        and elapsed >= THRESHOLD and not should_skip_active():
                    fire("Paseo · " + tag, fmt_duration(elapsed), 0, aid, **where)
                elif status == "error" and "error" in EVENTS and not should_skip_active():
                    fire("Paseo · failed · " + tag, fmt_duration(elapsed), 1, aid, **where)
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
            perms = permits_snapshot(snap)
            if seeded:
                for key, (label, agent, agent_id) in perms.items():
                    if key in seen_perm or should_skip_active():
                        continue
                    who = names.get(agent, agent)
                    lbl = "Paseo · needs you" + (" · " + who if who else "")
                    if label:
                        lbl += " — " + label
                    owner = snap.get(agent_id) or ("", "", "", "")
                    fire(lbl, "permission", 0, agent_id,
                         source=source_of(owner[2]), repo=repo_of(owner[3]))
            seen_perm = set(perms)

        seeded = True

        # Checked after a full poll, so whatever the old code saw is already
        # alerted when it exits. Silent on purpose: `status` reads any log output
        # as a fault, and launchd keeps the exit code (`last exit code = 75`).
        if relaunch is not None and relaunch.check() == RelaunchWatcher.RELAUNCH:
            sys.exit(RELAUNCH_EXIT)
        time.sleep(POLL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
