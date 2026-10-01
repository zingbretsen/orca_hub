// Standalone checks for the voice DRAFT SINK's write rule (ORCAHUB3-120).
// The repo has no JS test runner, so this is a plain node script, same
// convention as dictated_send.check.mjs:
//
//     node assets/js/voice/draft_sync.check.mjs
//
// Exits non-zero on the first broken expectation. Gated by
// `OrcaHubWeb.VoiceDraftSyncCheckTest`.
//
// The rolling LLM cleanup rewrites text the box ALREADY shows, at any
// moment, so a server snapshot may no longer simply overwrite the box. Two
// halves are pinned here: the pure rule in `draft_sync.js` (which action,
// where the caret goes), and the REAL `_renderDraft` / `_writeDraft` /
// `_syncBarBox` driving a fake composer and the bar's own box — so the
// wiring cannot drift from the rule.
//
// The hook's sibling modules are swapped for inert stubs through a
// `module.register()` resolve hook, exactly as dictated_send.check.mjs does.

import { register } from "node:module"
import { fileURLToPath, pathToFileURL } from "node:url"
import { dirname, join } from "node:path"

const HERE = dirname(fileURLToPath(import.meta.url))
const dataUrl = (src) => "data:text/javascript," + encodeURIComponent(src)

const HOOK_URL = pathToFileURL(join(HERE, "voice_hook.js")).href
const SYNC_URL = pathToFileURL(join(HERE, "draft_sync.js")).href

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
    "./draft_sync": SYNC_URL,
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
  constructor(value = "") {
    this.value = value
    this.selectionStart = value.length
    this.selectionEnd = value.length
    this.scrollTop = 0
    this.scrollHeight = 0
    this.events = []
    this.classList = { add() {}, remove() {} }
  }
  dispatchEvent(e) {
    this.events.push(e.type)
    return true
  }
  /** The user types: the box changes and no `_writeDraft` is involved. */
  type(value, caret = value.length) {
    this.value = value
    this.selectionStart = this.selectionEnd = caret
  }
}

let composer = null
globalThis.document = {
  activeElement: null,
  querySelector: (selector) =>
    selector === `form[data-voice-composer-for="${TARGET}"]` && composer
      ? { querySelector: (s) => (s === "textarea" ? composer : null) }
      : null,
}
globalThis.window = { addEventListener() {}, removeEventListener() {} }

const { draftSinkAction, mapCaret } = await import(SYNC_URL)
const { default: VoiceHook } = await import(HOOK_URL)

function makeHook({ textarea = null, barBox = null } = {}) {
  composer = textarea
  document.activeElement = null
  const hook = Object.create(VoiceHook)
  hook.target = TARGET
  hook.active = true
  hook.composerPresent = !!textarea
  hook._timers = { draft: null }
  hook._pendingSeed = null
  hook._lastSink = null
  hook._lastWrite = null
  hook._applyingDraft = false
  hook.el = { querySelector: (s) => (s === "[data-voice-bar-draft]" ? barBox : null) }
  hook.channel = {
    pushes: [],
    push(event, payload) {
      this.pushes.push([event, payload])
    },
  }
  return hook
}

const edits = (hook) => hook.channel.pushes.filter(([e]) => e === "draft_edit").map(([, p]) => p.text)

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

// ------------------------------------------------------------ the pure rule

console.log("draftSinkAction")
{
  const a = (value, incoming, lastWritten, debouncing = false) =>
    draftSinkAction({ value, incoming, lastWritten, debouncing })

  ok("a draft_edit still debouncing keeps the box", a("typed", "server", "typed", true) === "keep")
  ok("a box that already shows it is in sync", a("same", "same", "old") === "in_sync")
  ok("an empty server draft never empties a non-empty box", a("typed", "", "typed") === "keep")
  ok("an untouched box takes the server's rewrite", a("one. Two.", "One, two.", "one. Two.") === "write")
  ok("a box typed in since our last write is re-asserted", a("one. Two. typed", "One, two.", "one. Two.") === "reassert")
  ok("no record for this box: the server's draft is written, as before", a("x", "server", null) === "write")
  ok("an empty box we emptied takes a new draft", a("", "fresh words", "") === "write")
}

console.log("mapCaret")
{
  ok("a caret before the rewrite stays put", mapCaret("Intro. one. Two.", "Intro. One, two.", 3) === 3)
  // "a one. Two. ty|ped" -> "a One, two, more. ty|ped": same character.
  ok("a caret after a GROWING rewrite shifts right with it", mapCaret("a one. Two. typed", "a One, two, more. typed", 14) === 20)
  ok("a caret behind a SHRINKING rewrite moves left", mapCaret("uh one. Two. tail", "One, two. tail", 14) === 11)
  // "aa on|e. Two. zz" -> the rewritten middle is "One, t"; the caret goes
  // to its end, the first point both texts agree on again.
  ok("a caret inside the rewrite goes to its end", mapCaret("aa one. Two. zz", "aa One, two. zz", 6) === 9)
  ok("an append leaves every mid-text caret where it was", mapCaret("abc def", "abc def ghi", 2) === 2)
  ok("never past the end of the new text", mapCaret("abcdef", "abc", 6) === 3)
}

// --------------------------------------------- the real hook, fake composer

console.log("an untouched composer takes the cleanup's rewrite")
{
  const box = new FakeTextarea()
  const hook = makeHook({ textarea: box })
  hook._renderDraft("so the thing is.")
  hook._renderDraft("so the thing is. It keeps disconnecting.")
  hook._renderDraft("So the thing is, it keeps disconnecting.")

  ok("the box shows the cleaned text", box.value === "So the thing is, it keeps disconnecting.")
  ok("…written through a bubbling input event", box.events.filter((e) => e === "input").length === 3)
  ok("nothing was pushed back", hook.channel.pushes.length === 0)
}

console.log("typing while a draft_edit debounces: the box is the newer truth")
{
  const box = new FakeTextarea()
  const hook = makeHook({ textarea: box })
  hook._renderDraft("alpha. Beta.")
  box.type("alpha. Beta. gamma")
  hook._timers.draft = 1 // the 300 ms debounce is running
  hook._renderDraft("Alpha, beta.")

  ok("the typed text survives", box.value === "alpha. Beta. gamma")
  ok("nothing was pushed (the debounce will)", hook.channel.pushes.length === 0)
}

console.log("typing whose draft_edit already went out: re-asserted, never overwritten")
{
  const box = new FakeTextarea()
  const hook = makeHook({ textarea: box })
  hook._renderDraft("alpha. Beta.")
  box.type("alpha. Beta. gamma")
  // The debounce fired (timer cleared) but the server answered the cleanup
  // before it saw the edit.
  hook._renderDraft("Alpha, beta.")

  ok("the typed text survives", box.value === "alpha. Beta. gamma")
  ok("the box was re-asserted as a draft_edit", JSON.stringify(edits(hook)) === JSON.stringify(["alpha. Beta. gamma"]))

  // The server's echo of the typed text, then fresh dictation on top of it.
  hook._renderDraft("alpha. Beta. gamma")
  hook._renderDraft("alpha. Beta. gamma delta.")
  ok("the echo brings them back in sync, and the next append is written", box.value === "alpha. Beta. gamma delta.")
  ok("…with no further draft_edit", edits(hook).length === 1)
}

console.log("an empty server draft never empties the composer")
{
  const box = new FakeTextarea()
  const hook = makeHook({ textarea: box })
  hook._renderDraft("keep me")
  hook._renderDraft("")
  ok("the box still holds its text", box.value === "keep me")
  ok("nothing was pushed", hook.channel.pushes.length === 0)
}

console.log("a caret parked mid-text is mapped through the rewrite")
{
  const box = new FakeTextarea()
  const hook = makeHook({ textarea: box })
  hook._renderDraft("Intro typed. one. Two.")
  document.activeElement = box
  box.selectionStart = box.selectionEnd = 5 // inside "Intro", before the rewrite
  hook._renderDraft("Intro typed. One, two.")
  ok("the text was rewritten", box.value === "Intro typed. One, two.")
  ok("the caret before the rewrite did not move", box.selectionStart === 5 && box.selectionEnd === 5)

  hook._renderDraft("Intro typed. One, two. uh three.")
  box.selectionStart = box.selectionEnd = 27 // "t|hree", behind the rewrite
  hook._renderDraft("Intro typed. One, two, three.")
  ok("the text was rewritten again", box.value === "Intro typed. One, two, three.")
  ok(
    "a caret behind the rewrite keeps its character (t|hree)",
    box.selectionStart === 24 && box.value.slice(0, box.selectionStart).endsWith(", t"),
  )
  document.activeElement = null
}

console.log("a sink with no record falls back to the old rule")
{
  const box = new FakeTextarea("left over")
  const hook = makeHook({ textarea: box })
  hook._lastWrite = { el: new FakeTextarea(), text: "something else" } // a different element
  hook._renderDraft("server draft")
  ok("the server's draft is written, as an append always was", box.value === "server draft")
  ok("nothing was pushed", hook.channel.pushes.length === 0)
}

console.log("the bar's own box obeys the same rule")
{
  const bar = new FakeTextarea()
  const hook = makeHook({ barBox: bar })
  hook._renderDraft("alpha. Beta.")
  bar.type("alpha. Beta. typed in the bar")
  hook._renderDraft("Alpha, beta.")
  ok("the bar box keeps the typing", bar.value === "alpha. Beta. typed in the bar")
  ok("…and re-asserts it", JSON.stringify(edits(hook)) === JSON.stringify(["alpha. Beta. typed in the bar"]))
}

console.log("the bar box emptied while not the sink does not re-assert \"\" later")
{
  const bar = new FakeTextarea()
  const hook = makeHook({ barBox: bar })
  hook._renderDraft("dictated on /queue")
  // A composer appears: the bar box is no longer the sink and is emptied.
  hook.composerPresent = true
  hook._syncBarBox()
  ok("the bar box was emptied", bar.value === "")
  // ...and disappears again; the next snapshot must refill it, not wipe the
  // server's draft with the empty box.
  hook.composerPresent = false
  hook._renderDraft("dictated on /queue, cleaned.")
  ok("the box was refilled from the server", bar.value === "dictated on /queue, cleaned.")
  ok("no empty draft_edit was pushed", edits(hook).length === 0)
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
