#!/bin/bash
# =============================================================
# ada-claude-hook — Agent Done Alert for Claude Code
# -------------------------------------------------------------
# Pops the same maximized-window alert as ada.sh, but when a long
# Claude Code *turn* finishes instead of a shell command.
#
# One script, wired to the UserPromptSubmit + Stop hooks of Claude
# Code *and* Codex — both pass a matching JSON payload on stdin, so
# the same script serves both. It dispatches on hook_event_name:
#
#   UserPromptSubmit -> stamp a start time + a displayable label for
#                       the prompt, keyed by session id. The agent fires
#                       this hook for messages it INJECTS as well as ones
#                       you type (a background task finishing, a slash
#                       command, a system reminder), and those arrive as
#                       raw XML-ish blocks — see label_for() for how the
#                       human part is recovered.
#   Stop             -> if the turn ran longer than
#                       ADA_CLAUDE_THRESHOLD seconds AND you're
#                       not already looking at the terminal that
#                       hosts the agent, fire the alert showing the
#                       prompt and how long it took. If the Stop
#                       payload's session id doesn't match the
#                       stamped one (Codex parity), fall back to the
#                       most recent stamp so the alert still fires.
#                       Additionally, if the turn ended in an API
#                       error (the transcript's last assistant entry
#                       has isApiErrorMessage:true), alert REGARDLESS
#                       of the duration threshold — an error is worth
#                       interrupting for even when it aborts fast.
#                       Note: this catches errors that abort a turn
#                       after it starts. Client pre-flight guards like
#                       "context window is full" reject the prompt
#                       before a turn runs, fire no Stop hook, and so
#                       cannot be caught here.
#
# Environment knobs (shared with ada.sh where noted):
#   ADA_CLAUDE_THRESHOLD  min turn seconds to alert   (default 45)
#   ADA_CLAUDE_ALERT_ON_ERROR  alert on a turn-ending API error even
#                         below the duration threshold (default 1)
#   ADA_ALERT_FILE        alert.html path             (default: alongside the launcher)
#   ADA_NATIVE_ALERT      path to ada-alert helper    (default auto, via launcher)
#   ADA_AUTO_CLOSE        auto-dismiss seconds        (default 90)
#   ADA_SKIP_OWN_TERMINAL silence when terminal is frontmost (default 1)
#   ADA_SKIP_WHEN_ACTIVE  extra frontmost apps to stay silent for
#   ADA_CLAUDE_STALE_MAX  max age (s) of a fallback start stamp (default 21600)
#   ADA_DEBUG_LOG         when set, log each payload for debugging (default off)
# =============================================================
set -u

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
state_dir="${TMPDIR:-/tmp}/ada-claude"
threshold=${ADA_CLAUDE_THRESHOLD:-45}

# Frontmost-app suppression, duration formatting and the launcher call live in
# ada-notify.sh so this hook and the opencode plugin can't drift apart.
# shellcheck source=lib/ada-notify.sh
. "$dir/ada-notify.sh"

# Pull the fields we need in one python pass (US/\x1f-delimited, newline-stripped).
payload=$(cat)
fields=$(printf '%s' "$payload" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def clean(s):
    # Single-line and delimiter-safe. Used for PATHS as well as text, so it
    # deliberately does NOT collapse runs of spaces: a directory really can be
    # named "My  Project", and squeezing that breaks `git -C` for the repo badge
    # on the alert and the -f test on the transcript path.
    return (s or "").replace("\n", " ").replace("\t", " ").replace("\x1f", " ").strip()

def one_line(s):
    # For display text, where runs of whitespace are noise.
    return re.sub(r"\s+", " ", (s or "").replace("\x1f", " ")).strip()

# The outer tag of an injected block always contains a hyphen:
# task-notification, system-reminder, local-command-stdout, ci-monitor-event,
# command-name. HTML and JSX element names never do, and that is not a
# coincidence -- a hyphen is exactly what the HTML spec reserves to tell a
# custom element from a standard one. It is the strongest cheap signal there is,
# and it is what keeps a typed "<div>foo</div>" out of the sanitizer entirely.
INJECTED_OUTER_TAG = re.compile(r"^<([A-Za-z0-9_]+-[A-Za-z0-9_-]*)>")

# The Claude desktop app wraps anything you paste in a pasted_content element and
# repeats the id on the CLOSING tag as well:
#   <pasted_content id="c339"> ... </pasted_content id="c339">
# so a plain "</pasted_content>" pattern never matches it. The name has an
# underscore, not a hyphen, and the block usually sits mid-prompt after text you
# typed, so INJECTED_OUTER_TAG rightly ignores it and it needs its own pass.
#
# The attributes are bounded and may not contain "<", so each match attempt does
# a fixed amount of work and one finditer over the prompt stays linear.
PASTED_TAG = re.compile(r"<(/?)pasted_content(?:\s[^<>]{0,256})?>")

def unpaste(p):
    # Returns (text, paste_only). Keep what you typed around a paste and
    # collapse the paste itself to a placeholder: the typed words are what you
    # remember sending, and a pasted Slack thread or log would otherwise fill the
    # whole 120-char label. A prompt that is nothing BUT a paste shows the pasted
    # text, since a lone placeholder names nothing. A stray tag (an unclosed
    # paste) is dropped either way.
    #
    # One pass over the tags, pairing each opening tag with the next closing
    # one. A lazy (.*?) regex did the same pairing but rescanned to the end of
    # the prompt from every opening tag that never closed, which is quadratic,
    # and this runs inside the synchronous UserPromptSubmit hook.
    if "pasted_content" not in p:
        return p, False
    segments = []  # (is_paste, text) in prompt order
    pos, open_end = 0, None
    for m in PASTED_TAG.finditer(p):
        closing = bool(m.group(1))
        if open_end is None:
            segments.append((False, p[pos:m.start()]))
            if not closing:
                open_end = m.end()
            pos = m.end()
        elif closing:
            segments.append((True, p[open_end:m.start()]))
            open_end = None
            pos = m.end()
        # an opening tag inside an open paste is part of the pasted text
    segments.append((False, p[pos:]))
    pastes = [t for is_paste, t in segments if is_paste]
    if not pastes:
        parts, paste_only = [t for _, t in segments], False
    elif any(PASTED_TAG.sub("", t).strip() for is_paste, t in segments if not is_paste):
        parts, paste_only = [" [pasted text] " if is_paste else t for is_paste, t in segments], False
    else:
        parts, paste_only = pastes, True
    return PASTED_TAG.sub(" ", " ".join(parts)).strip(), paste_only

def label_for(prompt):
    # A turn label a human can read on a maximized window.
    #
    # Not every UserPromptSubmit carries something you typed. The agent fires
    # the same hook for messages IT injects into the conversation -- a
    # background task finishing, a slash command, a system reminder, a CI event
    # -- and those arrive as raw markup. Rendering one verbatim fills the alert
    # with task ids and file paths, so recover the human part instead.
    p, paste_only = unpaste((prompt or "").strip())

    # A prompt that is only a paste is something you sent, even when what you
    # pasted is itself harness markup (a copied <task-notification> block). The
    # injected-block rules below would relabel it as an agent event.
    if paste_only:
        return one_line(p)

    # Machine-generated only when the prompt is WHOLLY markup: it opens with a
    # hyphenated custom tag and closes on a tag. So neither
    # "<div>foo</div> is not centering" nor a pasted
    # "<details><summary>log</summary>...</details> why does this fail?" is
    # touched. Both are realistic prompts that the weaker starts-with-< rule
    # mangled.
    if not (INJECTED_OUTER_TAG.match(p) and p.endswith(">")):
        return one_line(p)

    # The regexes below backtrack superlinearly on large or malformed markup
    # (a big <local-command-stdout> of compiler output), and this runs inside a
    # synchronous UserPromptSubmit hook. The label is clipped to 120 chars
    # anyway, so only the head of the block is worth scanning.
    p = p[:8192]

    # A slash command: show the command and its arguments, which IS what the
    # user typed, just wrapped in markup by the agent.
    m = re.search(r"<command-name>\s*(.*?)\s*</command-name>", p, re.S)
    if m:
        args = re.search(r"<command-args>\s*(.*?)\s*</command-args>", p, re.S)
        return one_line(m.group(1) + " " + (args.group(1) if args else ""))

    # Task notifications and CI events carry a one-line <summary> written for a
    # human; prefer it over the ids and file paths around it.
    m = re.search(r"<summary>(.*?)</summary>", p, re.S)
    if m and m.group(1).strip():
        return one_line("\u2699\ufe0f " + m.group(1).strip())

    # Any other injected block: keep the prose, drop the metadata. Metadata
    # lives in NESTED elements (task-id, status, id), so remove those whole
    # rather than merely unwrapping them -- stripping tags alone left an alert
    # labelled "7", or a bare task id. Text sitting directly inside the outer
    # block is the only part a human wrote. An empty result falls back to the
    # generic agent label on the bash side.
    body = re.sub(r"^<[A-Za-z0-9_-]+>", "", p)
    body = re.sub(r"</[A-Za-z0-9_-]+>\s*$", "", body)
    body = re.sub(r"<([A-Za-z0-9_-]+)[^>]*>.*?</\1>", " ", body, flags=re.S)
    return one_line(re.sub(r"<[^>]*>", " ", body))

ev  = d.get("hook_event_name", "") or ""
sid = d.get("session_id", "") or ""
cwd = clean(d.get("cwd", ""))
tp  = clean(d.get("transcript_path", ""))
pr  = clean(d.get("prompt", ""))
lb  = label_for(d.get("prompt", ""))
# Fields are joined with US (\x1f), a NON-whitespace delimiter, so an empty field
# (e.g. a payload with no transcript_path) is preserved instead of collapsing the
# way adjacent IFS-whitespace tabs would — which used to shift the prompt into
# transcript_path and drop it. The RAW prompt stays LAST so read -r keeps it
# whole; it is only used for the debug breadcrumb, while the label is what gets
# stamped and displayed.
print(ev + "\x1f" + sid + "\x1f" + cwd + "\x1f" + tp + "\x1f" + lb + "\x1f" + pr)
' 2>/dev/null)
[[ -z "$fields" ]] && exit 0

IFS=$'\x1f' read -r event session_id cwd transcript_path label prompt <<<"$fields"
[[ -z "$event" ]] && exit 0

# Opt-in breadcrumb for debugging Codex-vs-Claude payload shapes. Triggered by
# ADA_DEBUG_LOG=1 OR a sentinel file (so it works even when the agent strips the
# hook's env, e.g. Codex's shell_environment_policy=core). tail the log to see
# every event the agent actually delivers to this hook.
__ada_dbg_log="${ADA_DEBUG_LOG_FILE:-${TMPDIR:-/tmp}/ada-claude-debug.log}"
if [[ -n "${ADA_DEBUG_LOG:-}" || -e "${TMPDIR:-/tmp}/ada-claude-debug.on" ]]; then
  printf '%s\tevent=%s\tsid=%s\tcwd=%s\tprompt=%.60s\n' \
    "$(date '+%F %T')" "$event" "$session_id" "$cwd" "$prompt" \
    >> "$__ada_dbg_log" 2>/dev/null
fi

# Inspect the transcript tail: if the turn's last assistant entry is an API
# error, echo the error text (stdout) and return 0; otherwise echo nothing and
# return 1. Claude Code writes failed turns as a type:"assistant" JSONL entry
# with "isApiErrorMessage":true and the message text in message.content.
__ada_turn_error_text() {
  local tpath=$1
  [[ -n "$tpath" && -f "$tpath" ]] || return 1
  tail -n 80 "$tpath" 2>/dev/null | python3 -c '
import json, sys
err = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "assistant":
        continue
    if d.get("isApiErrorMessage"):
        c = d.get("message", {}).get("content", "")
        if isinstance(c, list):
            c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
        err = (c or "").replace("\n", " ").strip()
    else:
        # a normal assistant turn after the error clears the error state
        err = None
if err:
    print(err)
    sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

case "$event" in
  UserPromptSubmit)
    [[ -z "$session_id" ]] && exit 0
    mkdir -p "$state_dir"
    date +%s            > "$state_dir/$session_id.start"
    printf '%s' "$label" > "$state_dir/$session_id.prompt"
    ;;

  Stop)
    start_file="$state_dir/$session_id.start"
    # Claude sends the same session_id on UserPromptSubmit and Stop, so the exact
    # stamp is found. Codex parity: if its Stop payload carries a different
    # session_id (or none), fall back to the most recent stamp still younger than
    # ADA_CLAUDE_STALE_MAX seconds, so the alert isn't silently dropped.
    if [[ -z "$session_id" || ! -f "$start_file" ]]; then
      start_file=$(ls -t "$state_dir"/*.start 2>/dev/null | head -1)
      [[ -n "$start_file" && -f "$start_file" ]] || exit 0
      now=$(date +%s)
      mtime=$(stat -f %m "$start_file" 2>/dev/null || echo 0)
      (( now - mtime > ${ADA_CLAUDE_STALE_MAX:-21600} )) && exit 0
    fi
    prompt_file="${start_file%.start}.prompt"
    [[ -f "$start_file" ]] || exit 0
    local_start=$(cat "$start_file" 2>/dev/null)
    saved_prompt=$(cat "$prompt_file" 2>/dev/null)
    rm -f "$start_file" "$prompt_file"
    [[ -z "$local_start" ]] && exit 0

    elapsed=$(( $(date +%s) - local_start ))

    # Did the turn end in an API error? If so, alert regardless of duration —
    # a fast-failing turn is exactly the case the plain threshold would drop.
    err_text=""
    if [[ "${ADA_CLAUDE_ALERT_ON_ERROR:-1}" == 1 ]]; then
      err_text=$(__ada_turn_error_text "$transcript_path") || err_text=""
    fi

    if [[ -z "$err_text" ]]; then
      (( elapsed < threshold )) && exit 0
    fi

    if [[ -n "$err_text" ]]; then
      label="⚠️ Error: ${err_text}"
    else
      label=${saved_prompt:-"Claude Code"}
    fi
    if (( ${#label} > 120 )); then label="${label:0:120}…"; fi

    # Clicking the alert can jump straight to this turn's conversation in the
    # Claude macOS app via its claude://resume?session=<id> deep link. Only wire
    # it for genuine Claude Code sessions: the id must be a UUID AND have a
    # transcript on disk. Codex shares this hook but its sessions can't be
    # imported into Claude.app, so skipping the link avoids a "Couldn't open
    # session" dialog. The id is the basename of the resolved start stamp, which
    # is the right session even on the Codex fallback path above.
    resolved_sid=$(basename "$start_file" .start)
    click_url=""; focus_name=""
    if [[ "$resolved_sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      if [[ -n "$(find "$claude_dir/projects" -maxdepth 2 -name "$resolved_sid.jsonl" -print -quit 2>/dev/null)" ]]; then
        click_url="claude://resume?session=$resolved_sid"
        focus_name="Claude"
      fi
    fi

    # ADA_REPO_DIR points the launcher at the turn's project so it shows the
    # right repo (the hook's own cwd isn't guaranteed to be it). Empty falls
    # back to the launcher's cwd, which is the project in the usual setup.
    # ADA_CLICK_URL makes clicking the alert open the deep link above (empty =
    # plain dismiss). ADA_FOCUS_APP_NAME labels the click hint ("…return to Claude").
    # __ada_notify (lib/ada-notify.sh) owns the frontmost-app suppression, the
    # duration formatting and the launcher call, shared with the opencode plugin.
    ADA_REPO_DIR="$cwd" ADA_CLICK_URL="$click_url" ADA_FOCUS_APP_NAME="$focus_name" \
      __ada_notify "$label" "$elapsed" 0 >/dev/null 2>&1 &
    ;;
esac

exit 0
