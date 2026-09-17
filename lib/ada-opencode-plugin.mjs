// =============================================================
// ada-opencode-plugin — Agent Done Alert for opencode
// -------------------------------------------------------------
// opencode has no "run a command on agent event" hook config the way Claude
// Code and Codex do. What it has is a server-side PLUGIN api: a module whose
// named exports are async factories returning a hooks object. opencode loads
// every `.js` file in ~/.config/opencode/plugin (global) or
// <project>/.opencode/plugin, so ada-install.sh writes a one-line shim there
// that re-exports this file from the install directory. The shim carries the
// path; this file carries the logic, so editing it takes effect on the next
// opencode start with no re-install.
//
// Only `.js` is scanned — a plain `.mjs` dropped in the plugin directory is
// ignored. THIS file is `.mjs` on purpose (it is imported explicitly by the
// shim, so the scanner's extension filter does not apply, and the extension
// makes the ESM-ness unambiguous regardless of the repo's package.json).
//
// Turn boundaries come from two places:
//   chat.message (hook)  -> a user turn started: stamp the time and prompt
//   session.idle (event) -> that turn finished; fires ONCE, after the last
//                           tool call, not between steps
// plus two interrupt-worthy events:
//   session.error        -> arrives ~1ms BEFORE session.idle, so it is stashed
//                           on the turn and rendered by the idle handler. That
//                           ordering is why a failed turn produces one alert
//                           and not two.
//   permission.asked     -> the agent is blocked waiting for your approval.
//
// Event NAMES are read defensively: the @opencode-ai/sdk types bundled with
// 1.18.20 declare `permission.updated` with {permissionID, response}, while the
// 1.18.30 binary emits `permission.asked` / `permission.replied` with
// {id, requestID, reply}. Both spellings are accepted so an opencode upgrade
// (or downgrade) doesn't silently stop alerting.
//
// The alert itself is NOT rendered here. This spawns lib/ada-notify.sh, which
// owns frontmost-app suppression and the launcher call for every integration.
//
// Environment knobs:
//   ADA_OPENCODE_THRESHOLD  min turn seconds to alert          (default 45)
//   ADA_OPENCODE_EVENTS     which events alert, space separated
//                           (default "finish error permission"; "" disables)
//   ADA_DEBUG_LOG           log every handled event for debugging
//   ADA_DEBUG_LOG_FILE      where to log       (default $TMPDIR/ada-opencode-debug.log)
// ...plus everything ada-notify.sh and ada-show-alert.sh read (ADA_ALERT_FILE,
// ADA_AUTO_CLOSE, ADA_SNOOZE_MINUTES, ADA_SKIP_OWN_TERMINAL,
// ADA_SKIP_WHEN_ACTIVE). An opencode started from a shell that sources ada.sh
// inherits all of them already.
// =============================================================
import { spawn } from "node:child_process"
import { appendFileSync, existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { tmpdir } from "node:os"

const LIB_DIR = dirname(fileURLToPath(import.meta.url))
const NOTIFY = join(LIB_DIR, "ada-notify.sh")

const MAX_LABEL = 120

const intEnv = (name, fallback) => {
  const raw = Number.parseInt(process.env[name] ?? "", 10)
  return Number.isFinite(raw) && raw >= 0 ? raw : fallback
}

const THRESHOLD = intEnv("ADA_OPENCODE_THRESHOLD", 45)
const EVENTS = new Set(
  (process.env.ADA_OPENCODE_EVENTS ?? "finish error permission").split(/\s+/).filter(Boolean),
)

// Opt-in breadcrumb, same shape as the Claude hook's: env var OR a sentinel
// file, because a plugin can inherit a stripped environment depending on how
// opencode was launched. tail it to see what the daemon actually delivered.
const DEBUG_FILE = process.env.ADA_DEBUG_LOG_FILE || join(tmpdir(), "ada-opencode-debug.log")
const DEBUG = Boolean(process.env.ADA_DEBUG_LOG) || existsSync(join(tmpdir(), "ada-opencode-debug.on"))
const debug = (line) => {
  if (!DEBUG) return
  try {
    appendFileSync(DEBUG_FILE, `${new Date().toISOString()}\t${line}\n`)
  } catch {
    /* debug logging must never break a turn */
  }
}

// One line of alert text: no newlines/tabs, collapsed runs of space, clipped.
const oneLine = (value) => {
  const text = String(value ?? "").replace(/\s+/g, " ").trim()
  return text.length > MAX_LABEL ? `${text.slice(0, MAX_LABEL)}…` : text
}

// The user's prompt, for the alert label. opencode delivers a message as an
// array of parts; only the text ones are the prompt (a part can also be a file
// attachment or an agent mention).
const promptFromParts = (parts) =>
  oneLine(
    (Array.isArray(parts) ? parts : [])
      .filter((part) => part?.type === "text" && part?.text)
      .map((part) => part.text)
      .join(" "),
  )

// Which session.error values are worth interrupting you for, and what the alert
// says. Returns null to stay silent.
//
// `error` is opencode's discriminated union: { name, data } where name is
// ProviderAuthError | UnknownError | MessageOutputLengthError |
// MessageAbortedError | APIError. Every field is read defensively — the shipped
// SDK types have already drifted from the binary once (see the permission event
// names below), so assume `data` may be empty.
const errorLabel = (error) => {
  if (!error) return null
  const { name, data } = error

  // You pressed Esc. You already know the turn stopped, and you were at the
  // keyboard to stop it, so a window is pure noise.
  if (name === "MessageAbortedError") return null

  // The one error carrying no `message` at all: the name is the information.
  if (name === "MessageOutputLengthError") {
    return "response hit the model's output length limit"
  }

  const message = oneLine(data?.message)

  // The provider id is the actionable part — it tells you which `opencode auth
  // login` to run — and it reads better than the raw message alone.
  if (name === "ProviderAuthError") {
    return `${data?.providerID || "provider"} auth failed${message ? `: ${message}` : ""}`
  }

  // `isRetryable` is deliberately NOT a reason to stay quiet. opencode retries
  // internally and announces those as `session.status retry`; by the time an
  // error reaches session.error, session.idle is already following it, so the
  // turn is over either way. The status code is the most useful detail to add.
  if (name === "APIError") {
    const status = data?.statusCode
    if (message) return oneLine(`${message}${status ? ` (HTTP ${status})` : ""}`)
    return status ? `API error ${status}` : "API error"
  }

  return message || oneLine(name) || "unknown error"
}

// Spawn the shared notifier, fully detached: `opencode run` exits moments after
// session.idle, and the alert has to outlive it. stdio is ignored and the child
// is unref'd so the event loop isn't held open either.
//
// Failures are swallowed on purpose (an 'error' event with no listener would
// throw inside the host): a missing ada-notify.sh means no alert, never a
// broken opencode.
const fire = (label, elapsedSeconds, repoDir) => {
  if (process.platform !== "darwin") return
  if (!label) return
  debug(`fire label=${label} elapsed=${elapsedSeconds ?? ""} dir=${repoDir ?? ""}`)
  try {
    // Exit code 0 even for a failed turn, matching the Claude/Codex hook: the
    // alert page turns a nonzero code into "Command Failed"/"Exit N", which is
    // shell-command wording that doesn't fit an agent turn. The ⚠️ prefix in
    // the label is how a failure reads instead.
    const child = spawn(NOTIFY, [label, elapsedSeconds == null ? "" : String(elapsedSeconds), "0"], {
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        // The session's own directory, so the alert shows the right repo badge
        // even when one opencode server is serving several projects.
        ADA_REPO_DIR: repoDir || process.cwd(),
        // Clicking the alert focuses the app named by $__CFBundleIdentifier,
        // which the plugin inherited from the terminal hosting opencode.
        ADA_FOCUS_APP_NAME: "opencode",
      },
    })
    child.on("error", (err) => debug(`spawn failed: ${err?.message}`))
    child.unref()
  } catch (err) {
    debug(`spawn threw: ${err?.message}`)
  }
}

export const AdaAlert = async ({ directory }) => {
  // Per turn: when it started, what was asked, where it ran, how it failed.
  const turns = new Map()
  // Sub-sessions (a subagent/task has parentID set). Their idle is not YOUR
  // turn ending — the parent session is still busy — so they never alert.
  const children = new Set()
  // Permission ids already alerted for, so a re-emitted ask doesn't double up.
  const announced = new Set()
  const directories = new Map()

  const dirFor = (sessionID) => directories.get(sessionID) || directory

  const trackSession = (info) => {
    if (!info?.id) return
    if (info.parentID) {
      children.add(info.id)
      turns.delete(info.id)
      return
    }
    if (info.directory) directories.set(info.id, info.directory)
  }

  return {
    // A user turn starts here. Also fires for sub-sessions, hence the guard.
    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID
      if (!sessionID || children.has(sessionID)) return
      turns.set(sessionID, {
        start: Date.now(),
        prompt: promptFromParts(output?.parts),
        error: null,
        silenced: false,
      })
      debug(`chat.message sid=${sessionID}`)
    },

    event: async ({ event }) => {
      const type = event?.type
      const props = event?.properties ?? {}

      switch (type) {
        case "session.created":
        case "session.updated":
          trackSession(props.info)
          return

        case "session.error": {
          if (!EVENTS.has("error")) return
          const label = errorLabel(props.error)
          debug(`session.error sid=${props.sessionID ?? ""} name=${props.error?.name ?? ""}`)
          if (!label) {
            // An error we deliberately ignore (an abort) silences the whole
            // turn, not just the error alert: you were at the keyboard to cause
            // it, so the finish alert would be noise for the same reason.
            const silenced = props.sessionID ? turns.get(props.sessionID) : null
            if (silenced) silenced.silenced = true
            return
          }
          // Stash it on the turn; session.idle renders it a beat later. With no
          // session id there is no turn to attach to (a failure that precedes
          // the session, e.g. an unresolvable model), so alert immediately.
          const sessionID = props.sessionID
          if (!sessionID) {
            fire(`⚠️ Error: ${label}`, null, directory)
            return
          }
          const turn = turns.get(sessionID) ?? { start: null, prompt: "" }
          turn.error = label
          turns.set(sessionID, turn)
          return
        }

        case "session.idle": {
          const sessionID = props.sessionID
          if (!sessionID || children.has(sessionID)) return
          const turn = turns.get(sessionID)
          turns.delete(sessionID)
          if (!turn) return

          if (turn.silenced) return

          const elapsed = turn.start ? Math.round((Date.now() - turn.start) / 1000) : null

          // An error skips the duration threshold: a turn that fails in two
          // seconds is exactly the case a duration gate would swallow.
          if (turn.error) {
            fire(`⚠️ Error: ${turn.error}`, elapsed, dirFor(sessionID))
            return
          }
          if (!EVENTS.has("finish") || elapsed == null) return
          if (elapsed < THRESHOLD) return
          fire(turn.prompt || "opencode", elapsed, dirFor(sessionID))
          return
        }

        // 1.18.30 emits permission.asked; the 1.18.20 sdk types call it
        // permission.updated. Accept both.
        case "permission.asked":
        case "permission.updated": {
          if (!EVENTS.has("permission")) return
          const id = props.id ?? props.permissionID
          if (id) {
            if (announced.has(id)) return
            // Bounded: a long session can ask hundreds of times.
            if (announced.size > 500) announced.clear()
            announced.add(id)
          }
          const what = props.permission ?? props.type ?? "permission"
          const detail =
            props.metadata?.command ??
            (Array.isArray(props.patterns) ? props.patterns[0] : props.pattern) ??
            props.title
          const label = detail ? `${what} — ${oneLine(detail)}` : String(what)
          debug(`permission sid=${props.sessionID ?? ""} what=${what}`)
          // No duration: the turn is still running, and the turn state is left
          // in place so the finish alert still fires when it completes.
          fire(`🔐 Needs permission: ${label}`, null, dirFor(props.sessionID))
          return
        }

        default:
          return
      }
    },
  }
}
