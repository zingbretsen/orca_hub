// Standalone checks for the voice view's FLAG and the Voice hook's half of
// it (ORCAHUB3-113 phase C). The repo has no JS test runner, so this is a
// plain node script, same convention as mic_release.check.mjs:
//
//     node assets/js/voice/voice_view_flag.check.mjs
//
// Exits non-zero on any broken expectation, and is gated by the ExUnit suite
// through test/orca_hub_web/voice_view_flag_check_test.exs.
//
// WHAT THIS CAN AND CANNOT PROVE. Part A drives the REAL `voice_view_flag.js`;
// part B drives the REAL `VoiceHook` (the shipped module, not a copy) against
// a fake `Capture`, VAD, channel and DOM — the same rig mic_release.check.mjs
// uses — so every transition below is the production code path. What it
// cannot answer is anything a browser decides: that the `voice-view:` CSS
// actually hides and restyles the header at 390 px, that a hidden
// `<.link navigate>` click really live-navigates, that a phone's OS killing
// the mic produces the liveness callback this fakes. Those are W4's real-page
// check and Zach's phone. The CSS/JS agreement on the breakpoint IS pinned
// here, by a source assertion against app.css.

import { register } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath, pathToFileURL } from "node:url"
import { dirname, join } from "node:path"

const HERE = dirname(fileURLToPath(import.meta.url))
const dataUrl = (src) => "data:text/javascript," + encodeURIComponent(src)

// --------------------------------------------------------------- the stubs
// (mic_release.check.mjs's, trimmed to what these checks touch)

const STUB_CAPTURE = dataUrl(`
  export const FRAME_SAMPLES = 512
  export function secureContextProblem() { return null }
  export class Capture {
    constructor(opts = {}) {
      this.opts = opts
      this.stopped = false
      this.ctx = { state: "running", sampleRate: 48000 }
      this.track = { readyState: "live", muted: false }
      globalThis.__voiceStubs.captures.push(this)
    }
    async open() {
      const delay = globalThis.__voiceStubs.openDelayMs
      if (delay) await new Promise((r) => setTimeout(r, delay))
      return "running"
    }
    async start() { return { type: "ready" } }
    suspended() { return !this.ctx || this.ctx.state !== "running" }
    async resume() { return "running" }
    live() {
      if (globalThis.__voiceStubs.forceDead) return false
      return !this.stopped && this.track.readyState === "live" && !this.track.muted
    }
    async stop() {
      const delay = globalThis.__voiceStubs.stopDelayMs
      if (delay) await new Promise((r) => setTimeout(r, delay))
      this.stopped = true
      this.track.readyState = "ended"
      this.ctx = null
    }
    async history() { return new Float32Array(0) }
    get sampleRate() { return 48000 }
    get ratio() { return 3 }
  }
`)

const STUB_VAD = dataUrl(`
  export const VAD_SETTINGS = { preSpeechPadMs: 500 }
  export async function createVad(opts = {}) {
    return {
      opts, paused: false, framesProcessed: 0, maxBacklog: 0,
      pause() { this.paused = true }, resume() { this.paused = false },
      feed() {}, destroy() {},
    }
  }
`)

const STUB_CHANNEL = dataUrl(`
  export class VoiceChannel {
    constructor(target, handlers) {
      this.target = target
      this.handlers = handlers
      this.pushes = []
      globalThis.__voiceStubs.channels.push(this)
    }
    async join() {
      if (globalThis.__voiceStubs.joinFails) throw new Error("join refused")
      return globalThis.__voiceStubs.joinReply
    }
    push(event, payload) { this.pushes.push([event, payload]) }
    pushSegment() {}
    leave() { this.left = true }
    joined() { return !this.left }
  }
`)

const STUB_SOUNDS = dataUrl(`
  export const Sounds = {}
  export function soundsEnabled() { return false }
  export function persistSoundsEnabled() {}
  export class VoiceSounds {
    constructor({ enabled } = {}) { this.enabled = !!enabled; this.waiting = false; this.stats = {} }
    sent() {} startWaiting() {} stopWaiting() {} destroy() {}
  }
`)

const HOOK_URL = pathToFileURL(join(HERE, "voice_hook.js")).href
const FLAG_URL = pathToFileURL(join(HERE, "..", "voice_view_flag.js")).href

const RESOLVER = dataUrl(`
  const MAP = ${JSON.stringify({
    "./capture": STUB_CAPTURE,
    "./vad": STUB_VAD,
    "./channel": STUB_CHANNEL,
    "./sounds": STUB_SOUNDS,
    "./frame": pathToFileURL(join(HERE, "frame.js")).href,
    "./draft_sync": pathToFileURL(join(HERE, "draft_sync.js")).href,
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

class FakeClassList {
  constructor() { this.set = new Set() }
  add(c) { this.set.add(c) }
  remove(c) { this.set.delete(c) }
  contains(c) { return this.set.has(c) }
  toggle(c, on) { on ? this.add(c) : this.remove(c) }
}

class FakeEl {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase()
    this.dataset = {}
    this.classList = new FakeClassList()
    this.children = []
    this.textContent = ""
    this.value = ""
    this.clicks = 0
    this._bySelector = new Map()
    this._listeners = new Map()
  }
  register(selector, el) { this._bySelector.set(selector, el); return el }
  unregister(selector) { this._bySelector.delete(selector) }
  querySelector(selector) { return this._bySelector.get(selector) || null }
  querySelectorAll(selector) { const el = this.querySelector(selector); return el ? [el] : [] }
  closest() { return null }
  appendChild(el) { this.children.push(el); return el }
  removeChild(el) { this.children = this.children.filter((c) => c !== el); return el }
  get firstChild() { return this.children[0] }
  addEventListener(name, fn) { this._listeners.set(name, fn) }
  removeEventListener(name) { this._listeners.delete(name) }
  click() { this.clicks++ }
  focus() {}
  get scrollHeight() { return 0 }
}

const TARGET = "session-under-test"
const el = new FakeEl()
el.dataset.targetSessionId = TARGET
const micEl = el.register("[data-voice-mic]", new FakeEl("span"))
el.register("[data-voice-log]", new FakeEl("ul"))
el.register("[data-voice-status]", new FakeEl("span"))
el.register("[data-voice-error]", new FakeEl("span"))
el.register("[data-voice-banner]", new FakeEl("span"))
el.register('[data-voice-action="start"]', new FakeEl("button"))
el.register("[data-voice-arming]", new FakeEl("span"))
el.register("[data-voice-arming-label]", new FakeEl("span"))
el.register("[data-voice-bar-draft]", new FakeEl("textarea"))
const toggleBtn = el.register('[data-voice-action="toggle"]', new FakeEl("button"))

const windowListeners = new Map()
const dispatched = []
let mediaMatches = false
globalThis.window = {
  addEventListener: (n, fn) => windowListeners.set(n, fn),
  removeEventListener: (n) => windowListeners.delete(n),
  dispatchEvent: (e) => {
    dispatched.push({ type: e.type, detail: e.detail })
    const fn = windowListeners.get(e.type)
    if (fn) fn(e)
    return true
  },
  matchMedia: (q) => ({ matches: mediaMatches && q === "(max-width: 767px)", media: q }),
  location: { origin: "http://localhost" },
  isSecureContext: true,
  localStorage: { getItem: () => null, setItem: () => {} },
}
globalThis.localStorage = window.localStorage
globalThis.CustomEvent = class CustomEvent {
  constructor(type, init = {}) {
    this.type = type
    this.detail = init.detail
  }
}
globalThis.MutationObserver = class MutationObserver {
  constructor(fn) { this.fn = fn }
  observe() {}
  disconnect() {}
}
const html = new FakeEl("html")
const body = new FakeEl("body")
globalThis.document = {
  body,
  documentElement: html,
  activeElement: null,
  visibilityState: "visible",
  createElement: (tag) => new FakeEl(tag),
  querySelector: () => null,
  querySelectorAll: () => [],
  getElementById: () => null,
  addEventListener: () => {},
  removeEventListener: () => {},
  createTreeWalker: () => ({ nextNode: () => null }),
}
globalThis.NodeFilter = { SHOW_TEXT: 4 }

globalThis.__voiceStubs = {
  captures: [],
  channels: [],
  openDelayMs: 0,
  stopDelayMs: 0,
  forceDead: false,
  joinFails: false,
  joinReply: {
    state: { status: "listening", draft: "", muted: false },
    release_mic_during_playback: false,
  },
}

const flag = await import(FLAG_URL)
const { default: VoiceHook } = await import(HOOK_URL)

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
const eq = (name, got, want) => {
  const g = JSON.stringify(got),
    w = JSON.stringify(want)
  if (g === w) {
    pass++
    console.log(`  ok   ${name}`)
  } else {
    fail++
    console.log(`  FAIL ${name}\n       got  ${g}\n       want ${w}`)
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const settle = async (ms = 5) => {
  await sleep(ms)
  await sleep(0)
}

const fakeDoc = () => ({ documentElement: { dataset: {} } })
const fakeWin = (matches) => ({ matchMedia: () => ({ matches }) })
const events = (type) => dispatched.filter((e) => e.type === type)
const clearEvents = () => (dispatched.length = 0)
const tts = (playing) =>
  windowListeners.get("orca:tts-state")(new CustomEvent("orca:tts-state", { detail: { playing } }))
const voiceAction = (detail) =>
  windowListeners.get("orca:voice-action")(new CustomEvent("orca:voice-action", { detail }))
const click = (hook, action) =>
  el._listeners.get("click")({
    target: { closest: (s) => (s === "[data-voice-action]" ? { dataset: { voiceAction: action } } : null) },
    preventDefault() {},
  })
// The voice view on screen: the page drew its layout, and the viewport is a
// phone's. `this.active` supplies the third fact.
const showLayout = (on) => {
  mediaMatches = on
  if (on) html.dataset.voiceLayout = "session"
  else delete html.dataset.voiceLayout
}

async function freshHook({ release = false, openDelayMs = 0, arm = true } = {}) {
  globalThis.__voiceStubs.captures.length = 0
  globalThis.__voiceStubs.channels.length = 0
  globalThis.__voiceStubs.openDelayMs = openDelayMs
  globalThis.__voiceStubs.stopDelayMs = 0
  globalThis.__voiceStubs.forceDead = false
  globalThis.__voiceStubs.joinFails = false
  globalThis.__voiceStubs.joinReply.release_mic_during_playback = release
  el.dataset.targetSessionId = TARGET
  toggleBtn.setAttribute = () => {}
  toggleBtn.getAttribute = () => "false"
  showLayout(false)
  clearEvents()

  const hook = Object.create(VoiceHook)
  hook.el = el
  hook.pushes = []
  hook.handlers = {}
  hook.pushEvent = (name, payload) => hook.pushes.push([name, payload])
  hook.handleEvent = (name, fn) => (hook.handlers[name] = fn)
  hook.mounted()
  if (arm) {
    await hook._toggle()
    await settle()
  }
  return hook
}

// ======================================================================
console.log("\nA1. the flag module: setters write <html>, and only <html>")
{
  const doc = fakeDoc()
  flag.setVoiceView(true, doc)
  eq("setVoiceView(true) writes \"on\"", doc.documentElement.dataset.voiceView, "on")
  flag.setVoiceView(false, doc)
  ok("setVoiceView(false) removes it", !("voiceView" in doc.documentElement.dataset))
  flag.setVoiceLayout("session", doc)
  eq("setVoiceLayout(name) writes the name", doc.documentElement.dataset.voiceLayout, "session")
  flag.setVoiceLayout(null, doc)
  ok("setVoiceLayout(null) removes it", !("voiceLayout" in doc.documentElement.dataset))
  for (const s of ["live", "released", "stopped", "starting"]) {
    flag.setVoiceMic(s, doc)
    eq(`setVoiceMic("${s}") is written as-is`, doc.documentElement.dataset.voiceMic, s)
  }
  flag.setVoiceMic("listening", doc)
  ok("an unknown mic state CLEARS rather than writing a typo", !("voiceMic" in doc.documentElement.dataset))
  ok("a document with no <html> is tolerated", (flag.setVoiceView(true, {}), true))
}

console.log("\nA2. voiceViewShowing is exactly the CSS variant's three conditions")
{
  const table = [
    [{ view: true, layout: true, media: true }, true],
    [{ view: false, layout: true, media: true }, false],
    [{ view: true, layout: false, media: true }, false],
    [{ view: true, layout: true, media: false }, false],
  ]
  for (const [c, want] of table) {
    const doc = fakeDoc()
    flag.setVoiceView(c.view, doc)
    flag.setVoiceLayout(c.layout ? "session" : null, doc)
    eq(`view=${c.view} layout=${c.layout} phone=${c.media}`, flag.voiceViewShowing(doc, fakeWin(c.media)), want)
  }
  ok("no matchMedia at all is not a phone", flag.voiceViewMediaMatches({}) === false)

  // The CSS half: app.css's variant has to spell the same breakpoint and the
  // same two attributes, or JS and CSS would disagree about whether the view
  // is showing (an End that ends a view nobody sees, a Resume nobody can see).
  const css = readFileSync(join(HERE, "..", "..", "css", "app.css"), "utf8")
  const variant = css.slice(css.indexOf("@custom-variant voice-view"))
  ok("app.css declares the voice-view variant", css.includes("@custom-variant voice-view"))
  ok(
    `...with VOICE_VIEW_MEDIA's breakpoint ${flag.VOICE_VIEW_MEDIA}`,
    variant.slice(0, 200).includes(`@media ${flag.VOICE_VIEW_MEDIA}`)
  )
  ok(
    "...gated on BOTH html attributes",
    variant.slice(0, 200).includes("html[data-voice-view][data-voice-layout] &")
  )
}

console.log("\nA3. voiceMicState: only an UNATTENDED dead mic is \"stopped\"")
{
  const S = (o) => flag.voiceMicState({ active: true, ...o })
  eq("voice off: no attribute at all", flag.voiceMicState({ active: false, live: true }), null)
  eq("capturing", S({ live: true }), "live")
  eq("a deliberate release outranks everything", S({ released: true, starting: true }), "released")
  eq("live outranks an arm in flight", S({ live: true, starting: true }), "live")
  eq("joining / arming / repairing", S({ starting: true }), "starting")
  eq("nothing capturing, nothing trying", S({}), "stopped")
}

console.log("\nA4. pickNavigates: phone + voice mode + a page that is not already it")
{
  const P = (o) => flag.pickNavigates({ flagOn: true, mediaMatches: true, pageSessionId: "a", pickedId: "b", ...o })
  ok("all three: navigate", P({}) === true)
  ok("desktop: never (C5 is phone only)", P({ mediaMatches: false }) === false)
  ok("voice off: never", P({ flagOn: false }) === false)
  ok("already on that session: never", P({ pageSessionId: "b" }) === false)
  ok("off a session page: navigate", P({ pageSessionId: null }) === true)
  ok("no id: never", P({ pickedId: null }) === false)
}

// ======================================================================
console.log("\nB1. data-voice-view follows the USER's toggle, not the mic")
{
  const hook = await freshHook({ arm: false, openDelayMs: 30 })
  ok("mounted, voice off: no flag", !("voiceView" in html.dataset))
  ok("...and no mic state", !("voiceMic" in html.dataset))

  hook._toggle() // NOT awaited: look at the state the click leaves synchronously
  eq("the press sets the flag at once", html.dataset.voiceView, "on")
  eq("joining reads \"starting\", not \"stopped\"", html.dataset.voiceMic, "starting")
  await settle(10)
  eq("arming (open() still pending) reads \"starting\"", html.dataset.voiceMic, "starting")
  await settle(60)
  eq("armed and capturing reads \"live\"", html.dataset.voiceMic, "live")

  // ORCAHUB3-91: a socket remount re-mounts VoiceBarLive with voice_on false
  // and no target. The flag is intent, and intent has not changed.
  delete el.dataset.targetSessionId
  delete html.dataset.voiceView // as if something had cleared it
  hook.updated()
  eq("a remount restores the flag from this.active", html.dataset.voiceView, "on")
  ok("...and tells the bar voice is on", hook.pushes.some(([n, p]) => n === "voice-on" && p.on === true))
  el.dataset.targetSessionId = TARGET

  await hook._toggle()
  ok("the user's toggle-off clears the flag", !("voiceView" in html.dataset))
  ok("...and the mic state", !("voiceMic" in html.dataset))
  hook.destroyed()
}

{
  const hook = await freshHook()
  eq("on again", html.dataset.voiceView, "on")
  hook.destroyed()
  ok("destroyed() clears the flag (a page reload)", !("voiceView" in html.dataset))
  ok("...and the mic state", !("voiceMic" in html.dataset))
  eq("...and announces NO voice-ended: a reload is not a decision", events("orca:voice-ended").length, 0)
}

console.log("\nB2. orca:voice-ended — user toggle-off only, viewShowing read BEFORE the clear")
{
  const hook = await freshHook()
  clearEvents()
  await hook._toggle()
  eq("off voice view: one event, viewShowing false", events("orca:voice-ended").map((e) => e.detail), [
    { viewShowing: false },
  ])
  hook.destroyed()
}
{
  const hook = await freshHook()
  showLayout(true)
  ok("the view is showing before the press", flag.voiceViewShowing() === true)
  clearEvents()
  await hook._toggle()
  eq("End in the voice view: viewShowing TRUE", events("orca:voice-ended").map((e) => e.detail), [
    { viewShowing: true },
  ])
  ok("...although the flag is already gone by the time anyone hears it", !("voiceView" in html.dataset))
  hook.destroyed()
}

console.log("\nB3. a mic the OS killed: \"stopped\", End still ends, Resume never does")
async function killMic(hook) {
  globalThis.__voiceStubs.forceDead = true
  hook._onLiveness("the microphone stopped", false)
  eq("the coalesced repair is pending: \"starting\"", html.dataset.voiceMic, "starting")
  await settle(320) // the 250 ms reconcile, which fails against a dead mic
}
{
  const hook = await freshHook()
  await killMic(hook)
  eq("the repair could not bring it back: \"stopped\"", html.dataset.voiceMic, "stopped")
  eq("the flag is UNCHANGED — the view stays (D8)", html.dataset.voiceView, "on")
  eq("off voice view the strip still says tap the mic", micEl.textContent, "mic: stopped — tap the mic to resume")

  // Off voice view the ORCAHUB3-91 repair press is untouched.
  await hook._toggle()
  ok("off voice view: the first mic press REPAIRS (unchanged)", hook.active === true)
  await settle(20)
  hook.destroyed()
}
{
  // The repair's own awaits (tearing the dead stream down, here made slow)
  // leave the mic neither live nor arming. That window must still read
  // "starting", or every screen unlock would flash the big Resume.
  const hook = await freshHook()
  globalThis.__voiceStubs.stopDelayMs = 60
  globalThis.__voiceStubs.forceDead = true
  hook._onLiveness("the microphone stopped", false)
  await settle(280) // the reconcile has fired and is inside `await dead.stop()`
  ok("mid-repair: the old capture is gone", hook.capture === null && !hook._arming)
  eq("...and it still reads \"starting\", not \"stopped\"", html.dataset.voiceMic, "starting")
  await settle(120)
  eq("once the repair has given up: \"stopped\"", html.dataset.voiceMic, "stopped")
  hook.destroyed()
}
{
  const hook = await freshHook()
  showLayout(true)
  await killMic(hook)
  eq("in the voice view the strip does not point at the End button", micEl.textContent, "mic: stopped")

  // Resume, twice — where a second toggle press would turn voice off.
  const before = globalThis.__voiceStubs.captures.length
  click(hook, "resume")
  await settle(20)
  click(hook, "resume")
  await settle(20)
  ok("Resume never turns voice off", hook.active === true)
  eq("...the flag stays", html.dataset.voiceView, "on")
  ok("...and it really ran the repair (a fresh arm)", globalThis.__voiceStubs.captures.length > before)
  ok("...without spending the mic button's repair press", hook._repairAttempted === false)

  globalThis.__voiceStubs.forceDead = false
  click(hook, "resume")
  await settle(20)
  eq("with the mic back, Resume leaves it \"live\"", html.dataset.voiceMic, "live")

  globalThis.__voiceStubs.forceDead = true
  await killMic(hook)
  clearEvents()
  await hook._toggle()
  ok("End with a dead mic ENDS — no repair in the voice view", hook.active === false)
  eq("...and says it was the view's End", events("orca:voice-ended").map((e) => e.detail), [
    { viewShowing: true },
  ])
  hook.destroyed()
}
{
  const hook = await freshHook({ arm: false })
  showLayout(true)
  click(hook, "resume")
  await settle(20)
  ok("Resume with voice OFF does not turn it on", hook.active === false)
  ok("...and opens no microphone", globalThis.__voiceStubs.captures.length === 0)
  hook.destroyed()
}
{
  const hook = await freshHook({ arm: false })
  globalThis.__voiceStubs.joinFails = true
  await hook._toggle()
  await settle()
  eq("a refused join leaves voice on with nothing arming: \"stopped\"", html.dataset.voiceMic, "stopped")
  globalThis.__voiceStubs.joinFails = false
  click(hook, "resume")
  await settle(20)
  eq("Resume re-runs the connect path, and the mic comes up", html.dataset.voiceMic, "live")
  hook.destroyed()
}

console.log("\nB4. a deliberate release during playback is \"released\", and Resume leaves it alone")
{
  const hook = await freshHook({ release: true })
  tts(true)
  await settle()
  eq("released (ORCAHUB3-105), not stopped", html.dataset.voiceMic, "released")
  const before = globalThis.__voiceStubs.captures.length
  click(hook, "resume")
  await settle(20)
  eq("Resume does not re-arm behind a release", globalThis.__voiceStubs.captures.length, before)
  eq("...the state is still released", html.dataset.voiceMic, "released")
  hook.destroyed()
}

console.log("\nB5. orca:voice-sent and orca:voice-speech-start")
{
  const hook = await freshHook()
  const channel = globalThis.__voiceStubs.channels.at(-1)
  clearEvents()
  channel.handlers.onSent()
  eq("the channel's \"sent\" is re-dispatched once", events("orca:voice-sent").length, 1)
  eq("...naming the target", events("orca:voice-sent")[0].detail, { sessionId: TARGET })

  clearEvents()
  hook._onSpeechStart()
  eq("a VAD onset, unmuted, is announced", events("orca:voice-speech-start").length, 1)
  hook.muted = true
  clearEvents()
  hook._onSpeechStart()
  eq("...but never while muted", events("orca:voice-speech-start").length, 0)
  hook.muted = false
  hook.destroyed()
}

console.log("\nB6. orca:voice-action — a whitelist of exactly one: cancel")
{
  const hook = await freshHook()
  const channel = globalThis.__voiceStubs.channels.at(-1)
  channel.pushes.length = 0
  for (const action of ["toggle", "send", "resume", "send_now", "start", undefined]) {
    voiceAction({ action })
  }
  voiceAction(undefined)
  eq("anything else pushes nothing", channel.pushes, [])
  ok("...and never touches voice mode", hook.active === true)

  voiceAction({ action: "cancel" })
  eq("cancel runs the existing path: one `cancel` push", channel.pushes, [["cancel", {}]])

  // A Clear pressed while a typed edit is still debouncing: the server only
  // clears (and only answers `cancelled` for) a draft it HOLDS.
  channel.pushes.length = 0
  const box = el.querySelector("[data-voice-bar-draft]")
  box.value = "typed just now"
  hook._timers.draft = setTimeout(() => {}, 10000)
  voiceAction({ action: "cancel" })
  eq(
    "a pending draft_edit is flushed FIRST, then cancel",
    channel.pushes,
    [["draft_edit", { text: "typed just now" }], ["cancel", {}]]
  )
  ok("...and the debounce is spent", !hook._timers.draft)
  box.value = ""
  hook.destroyed()
}

console.log("\nB7. C5 — a MANUAL pick navigates on a phone in voice mode, live")
{
  const hook = await freshHook()
  ok("the hook listens for voice-picked", typeof hook.handlers["voice-picked"] === "function")
  const anchor = el.register('[data-voice-retarget-nav="session-b"]', new FakeEl("a"))
  body.dataset.voiceComposerFor = "session-a"

  hook.handlers["voice-picked"]({ session_id: "session-b" })
  eq("desktop: no navigation", anchor.clicks, 0)

  mediaMatches = true
  hook.handlers["voice-picked"]({ session_id: "session-b" })
  eq("phone + voice on: the hidden live-nav anchor is clicked", anchor.clicks, 1)

  body.dataset.voiceComposerFor = "session-b"
  hook.handlers["voice-picked"]({ session_id: "session-b" })
  eq("already on that session's page: no navigation", anchor.clicks, 1)

  body.dataset.voiceComposerFor = "session-a"
  hook.handlers["voice-picked"]({ session_id: "session-c" })
  eq("no anchor for that id: a no-op, never a reload", anchor.clicks, 1)

  // Auto-follow: the PAGE changing session moves the target through
  // `voice-target`, and must never navigate anywhere.
  body.dataset.voiceComposerFor = "session-b"
  hook._syncPage()
  ok("auto-follow asks the bar to retarget", hook.pushes.some(([n, p]) => n === "voice-target" && p.session_id === "session-b"))
  eq("...and clicks nothing", anchor.clicks, 1)

  await hook._toggle()
  mediaMatches = true
  body.dataset.voiceComposerFor = "session-a"
  hook.handlers["voice-picked"]({ session_id: "session-b" })
  eq("voice off: no navigation", anchor.clicks, 1)

  el.unregister('[data-voice-retarget-nav="session-b"]')
  delete body.dataset.voiceComposerFor
  hook.destroyed()
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
