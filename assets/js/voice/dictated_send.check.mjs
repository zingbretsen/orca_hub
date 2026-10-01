// Standalone checks for the VOICE-DICTATION FLAG on the composer send path
// (spec §8.2 / C4). The repo has no JS test runner, so this is a plain node
// script, same convention as mic_release.check.mjs:
//
//     node assets/js/voice/dictated_send.check.mjs
//
// Exits non-zero on the first broken expectation. Gated by
// `OrcaHubWeb.VoiceDictatedSendCheckTest`.
//
// A spoken send submits the session composer with its hidden
// `data-voice-dictated-submit` button (name="voice_dictated") as the
// SUBMITTER, which is how `SessionLive.Show.send_message` knows to tell the
// agent the text was dictated. These checks drive the REAL `_onSendRequest`
// (and the real `_composerForm` / `_writeDraft` under it) against a fake
// form, and pin: the submitter is passed; a page without the button still
// sends, unflagged; no composer still means `send_direct`. That LiveView
// serializes the submitter's name/value into the submit payload is
// LiveView's own contract (`serializeForm(form, {submitter})`); the server
// half is pinned by `SessionLive.ShowTest`'s "voice bar seams".
//
// The hook's sibling modules are swapped for inert stubs through a
// `module.register()` resolve hook: `voice_hook.js` imports them
// extensionlessly (esbuild resolves that, node does not), and nothing here
// mounts the hook, so the stubs only have to export the right names.

import { register } from "node:module"
import { fileURLToPath, pathToFileURL } from "node:url"
import { dirname, join } from "node:path"

const HERE = dirname(fileURLToPath(import.meta.url))
const dataUrl = (src) => "data:text/javascript," + encodeURIComponent(src)

const HOOK_URL = pathToFileURL(join(HERE, "voice_hook.js")).href

const RESOLVER = dataUrl(`
  const MAP = ${JSON.stringify({
    "./capture": dataUrl(
      "export const FRAME_SAMPLES = 512; export class Capture {}; export function secureContextProblem() { return null }",
    ),
    "./vad": dataUrl("export const VAD_SETTINGS = {}; export async function createVad() {}"),
    "./channel": dataUrl("export class VoiceChannel {}"),
    "./sounds": dataUrl(
      "export function soundsEnabled() { return false }; export function persistSoundsEnabled() {}; export class VoiceSounds {}",
    ),
    "./frame": pathToFileURL(join(HERE, "frame.js")).href,
  })}
  export async function resolve(specifier, context, next) {
    const mapped = MAP[specifier]
    if (mapped && context.parentURL === ${JSON.stringify(HOOK_URL)}) {
      return { url: mapped, shortCircuit: true }
    }
    return next(specifier, context)
  }
`)

register(RESOLVER)

// ----------------------------------------------------------- the fake page

const TARGET = "session-under-test"

class FakeTextarea {
  constructor() {
    this.value = ""
    this.selectionStart = 0
    this.selectionEnd = 0
    this.scrollTop = 0
    this.events = []
  }
  dispatchEvent(e) {
    this.events.push(e.type)
    return true
  }
}

class FakeForm {
  constructor({ withSubmitter = true, throws = null } = {}) {
    this.textarea = new FakeTextarea()
    this.submitter = withSubmitter
      ? { name: "voice_dictated", value: "true", dataset: { voiceDictatedSubmit: "" } }
      : null
    this.throws = throws
    this.submits = []
  }
  querySelector(selector) {
    if (selector === "textarea") return this.textarea
    if (selector === "[data-voice-dictated-submit]") return this.submitter
    return null
  }
  requestSubmit(...args) {
    if (this.throws) throw this.throws
    // Record the arity too: `requestSubmit(undefined)` is fine per WebIDL,
    // but the fallback is meant to be an explicit null.
    this.submits.push({ args: args.length, submitter: args[0] })
  }
}

let currentForm = null
globalThis.document = {
  activeElement: null,
  querySelector: (selector) =>
    selector === `form[data-voice-composer-for="${TARGET}"]` ? currentForm : null,
}
globalThis.window = { addEventListener() {}, removeEventListener() {} }

const { default: VoiceHook } = await import(HOOK_URL)

function makeHook(form) {
  currentForm = form
  const hook = Object.create(VoiceHook)
  hook.target = TARGET
  hook._timers = { draft: null }
  hook._pendingSend = null
  hook.el = { querySelector: () => null }
  hook.channel = {
    pushes: [],
    push(event, payload) {
      this.pushes.push([event, payload])
    },
  }
  return hook
}

// --------------------------------------------------------------- the rig

let pass = 0,
  fail = 0
const ok = (name, cond) => {
  if (cond) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}`)
  }
}

// ------------------------------------------------------------- the checks

console.log("a spoken send through the composer carries the dictation submitter")
{
  const form = new FakeForm()
  const hook = makeHook(form)
  hook._onSendRequest({ text: "check the Nemo Tron config" })

  ok("requestSubmit was called exactly once", form.submits.length === 1)
  ok("…with the voice_dictated button as the submitter", form.submits[0]?.submitter === form.submitter)
  ok("the draft was written into the composer first", form.textarea.value === "check the Nemo Tron config")
  ok("…through a bubbling input event (Autocomplete's autoresize)", form.textarea.events.includes("input"))
  ok("the send is pending until clear-prompt / voice-send-failed", hook._pendingSend?.text === "check the Nemo Tron config")
  ok("nothing was pushed on the channel (no send_direct)", hook.channel.pushes.length === 0)
}

console.log("a composer without the button (an older page) still sends, unflagged")
{
  const form = new FakeForm({ withSubmitter: false })
  const hook = makeHook(form)
  hook._onSendRequest({ text: "hello" })

  ok("requestSubmit was still called", form.submits.length === 1)
  ok("…with an explicit null submitter", form.submits[0]?.args === 1 && form.submits[0]?.submitter === null)
}

console.log("no composer for the target: the server delivers (and flags) it")
{
  const hook = makeHook(null)
  hook._onSendRequest({ text: "hello" })

  ok("send_direct was pushed", hook.channel.pushes.length === 1 && hook.channel.pushes[0][0] === "send_direct")
  ok("no send is pending on the client", hook._pendingSend === null)
}

console.log("a submit that throws reports send_failed and clears the pending send")
{
  const form = new FakeForm({ throws: new Error("boom") })
  const hook = makeHook(form)
  hook._onSendRequest({ text: "hello" })

  const [event, payload] = hook.channel.pushes[0] || []
  ok("send_failed was pushed", event === "send_failed" && /boom/.test(payload?.reason || ""))
  ok("the pending send was cleared", hook._pendingSend === null)
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
