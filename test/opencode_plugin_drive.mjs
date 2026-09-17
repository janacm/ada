// Test driver for lib/ada-opencode-plugin.mjs.
//
// Reads a JSON program on stdin and replays it against the real plugin, so the
// bats tests exercise the whole chain the way opencode does: plugin ->
// lib/ada-notify.sh -> lib/ada-show-alert.sh -> the fake native helper, which
// records the alert URL. Nothing here reimplements plugin behaviour.
//
// Program shape:
//   { "directory": "/path",            // the plugin's session directory
//     "steps": [
//       // a user turn starting `ageSeconds` ago (Date.now is shifted for the
//       // one call, so elapsed time is exact instead of wall-clock dependent)
//       {"type": "chat.message", "sessionID": "s1", "text": "hi", "ageSeconds": 120},
//       // any raw opencode event
//       {"type": "event", "event": {"type": "session.idle",
//                                   "properties": {"sessionID": "s1"}}},
//       // wait for the detached notify to reach the fake helper
//       {"type": "settle", "ms": 400}
//     ] }
import { AdaAlert } from "../lib/ada-opencode-plugin.mjs"

const program = JSON.parse(await new Promise((resolve, reject) => {
  let raw = ""
  process.stdin.setEncoding("utf8")
  process.stdin.on("data", (chunk) => { raw += chunk })
  process.stdin.on("end", () => resolve(raw))
  process.stdin.on("error", reject)
}))

const hooks = await AdaAlert({ directory: program.directory ?? process.cwd() })
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

for (const step of program.steps ?? []) {
  switch (step.type) {
    case "chat.message": {
      const realNow = Date.now
      if (step.ageSeconds) {
        const shifted = realNow() - step.ageSeconds * 1000
        Date.now = () => shifted
      }
      try {
        await hooks["chat.message"](
          { sessionID: step.sessionID },
          { parts: step.parts ?? [{ type: "text", text: step.text ?? "" }] },
        )
      } finally {
        Date.now = realNow
      }
      break
    }
    case "event":
      await hooks.event({ event: step.event })
      break
    case "settle":
      await sleep(step.ms ?? 300)
      break
    default:
      throw new Error(`unknown step type: ${step.type}`)
  }
}

// The alert is spawned detached; give it a moment to reach the fake helper
// before node exits (the bats side also polls, this just avoids a race where
// the process dies before the spawn is even handed to the OS).
await sleep(program.trailingSettleMs ?? 250)
