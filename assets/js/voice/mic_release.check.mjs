// Standalone checks for RELEASE-THE-MIC-DURING-PLAYBACK (ORCAHUB3-105 §9,
// voice_mode_spec.md §4.1). The repo has no JS test runner, so this is a
// plain node script, same convention as capture.check.mjs:
//
//     node assets/js/voice/mic_release.check.mjs
//
// Exits non-zero on the first broken expectation.
//
// WHAT THIS CAN AND CANNOT PROVE. It drives the REAL `VoiceHook` — the
// shipped module, not a copy — against a fake `Capture`, a fake VAD and a
// fake DOM, so every state transition below is the production code path.
// What it cannot answer is the question the issue is actually about:
// whether stopping the track gives the device's audio route back. Neither
// node nor headless Chrome has an audio route to lose. That claim needs
// Zach's phone, and nothing here should be read as evidence for it.
//
// The sibling modules are swapped out through a `module.register()` resolve
// hook rather than by rewriting the source: `voice_hook.js` imports them
// extensionlessly (esbuild resolves that, node does not), so the hook has to
// exist anyway, and pointing it at stubs costs one extra line.

import { register } from "node:module"
import { fileURLToPath, pathToFileURL } from "node:url"
import { dirname, join } from "node:path"

const HERE = dirname(fileURLToPath(import.meta.url))
const dataUrl = (src) => "data:text/javascript," + encodeURIComponent(src)

// --------------------------------------------------------------- the stubs
//
// Every stub reaches into `globalThis.__voiceStubs`, which is how a data:
// URL module (no shared scope with this file) hands its instances back to
// the checks below.

const STUB_CAPTURE = dataUrl(`
  export const FRAME_SAMPLES = 512
  export function secureContextProblem() { return null }
  export class Capture {
    constructor(opts = {}) {
      this.opts = opts
      this.constraints = opts.constraints || null
      this.stopped = false
      this.startCalls = 0
      this.ctx = { state: "running", sampleRate: 48000 }
      this.track = { readyState: "live", muted: false }
      globalThis.__voiceStubs.captures.push(this)
    }
    async open() {
      const delay = globalThis.__voiceStubs.openDelayMs
      if (delay) await new Promise((r) => setTimeout(r, delay))
      if (globalThis.__voiceStubs.openThrows) throw new Error("NotAllowedError-ish")
      return "running"
    }
    async start() { this.startCalls++; return { type: "ready" } }
    suspended() { return !this.ctx || this.ctx.state !== "running" }
    async resume() { return "running" }
    live() {
      if (globalThis.__voiceStubs.forceDead) return false
      return !this.stopped && this.track.readyState === "live" && !this.track.muted
    }
    async stop() {
      this.stopped = true
      this.track.readyState = "ended"
      this.ctx = null
      globalThis.__voiceStubs.stops.push(this)
    }
    async history() { return new Float32Array(0) }
    get sampleRate() { return 48000 }
    get ratio() { return 3 }
  }
`)

const STUB_VAD = dataUrl(`
  export const VAD_SETTINGS = { preSpeechPadMs: 500 }
  export async function createVad(opts = {}) {
    const vad = {
      opts, paused: false, destroyed: false, fed: [],
      framesProcessed: 0, maxBacklog: 0,
      pause() { this.paused = true },
      resume() { this.paused = false },
      feed(samples, endSample) { this.fed.push(endSample) },
      destroy() { this.destroyed = true },
    }
    globalThis.__voiceStubs.vads.push(vad)
    return vad
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
    async join() { return globalThis.__voiceStubs.joinReply }
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
    sent() {}
    startWaiting() {}
    stopWaiting() {}
    destroy() {}
  }
`)

const HOOK_URL = pathToFileURL(join(HERE, "voice_hook.js")).href

const RESOLVER = dataUrl(`
  const MAP = ${JSON.stringify({
    "./capture": STUB_CAPTURE,
    "./vad": STUB_VAD,
    "./channel": STUB_CHANNEL,
    "./sounds": STUB_SOUNDS,
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
//
// Just enough DOM for `mounted()` to run end to end. Running the REAL
// `mounted()` matters: the alternative is hand-writing the hook's initial
// state here, which would mean the checks assert against a copy of the
// defaults rather than the defaults.

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
    this.style = {}
    this._bySelector = new Map()
    this._listeners = new Map()
  }
  register(selector, el) { this._bySelector.set(selector, el); return el }
  querySelector(selector) { return this._bySelector.get(selector) || null }
  querySelectorAll(selector) { const el = this.querySelector(selector); return el ? [el] : [] }
  closest() { return null }
  appendChild(el) { this.children.push(el); return el }
  removeChild(el) { this.children = this.children.filter((c) => c !== el); return el }
  get firstChild() { return this.children[0] }
  addEventListener(name, fn) { this._listeners.set(name, fn) }
  removeEventListener(name) { this._listeners.delete(name) }
  focus() {}
  get scrollHeight() { return 0 }
}

const el = new FakeEl()
el.dataset.targetSessionId = "session-under-test"
const logEl = el.register("[data-voice-log]", new FakeEl("ul"))
const micEl = el.register("[data-voice-mic]", new FakeEl("span"))
el.register("[data-voice-status]", new FakeEl("span"))
el.register("[data-voice-error]", new FakeEl("span"))
el.register("[data-voice-banner]", new FakeEl("span"))
el.register('[data-voice-action="start"]', new FakeEl("button"))
el.register("[data-voice-arming]", new FakeEl("span"))
el.register("[data-voice-arming-label]", new FakeEl("span"))
el.register("[data-voice-box]", new FakeEl("textarea"))

const windowListeners = new Map()
globalThis.window = {
  addEventListener: (n, fn) => windowListeners.set(n, fn),
  removeEventListener: (n) => windowListeners.delete(n),
  dispatchEvent: (e) => {
    const fn = windowListeners.get(e.type)
    if (fn) fn(e)
    return true
  },
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
const body = new FakeEl("body")
globalThis.document = {
  body,
  documentElement: new FakeEl("html"),
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
  vads: [],
  channels: [],
  stops: [],
  openDelayMs: 0,
  openThrows: false,
  forceDead: false,
  joinReply: {
    state: { status: "listening", draft: "", muted: false },
    audio_constraints: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    release_mic_during_playback: true,
  },
}

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
// The hook awaits inside `_arm()`/`_reacquireMic()` and neither is awaited by
// its caller (both are fire-and-forget from an event handler, as in the
// browser), so the checks have to let the microtask queue drain.
const settle = async (ms = 5) => {
  await sleep(ms)
  await sleep(0)
}

const tts = (playing) =>
  windowListeners.get("orca:tts-state")(new CustomEvent("orca:tts-state", { detail: { playing } }))

async function freshHook({ release = true, debounceMs = 40 } = {}) {
  globalThis.__voiceStubs.captures.length = 0
  globalThis.__voiceStubs.vads.length = 0
  globalThis.__voiceStubs.channels.length = 0
  globalThis.__voiceStubs.stops.length = 0
  globalThis.__voiceStubs.openDelayMs = 0
  globalThis.__voiceStubs.openThrows = false
  globalThis.__voiceStubs.forceDead = false
  globalThis.__voiceStubs.joinReply.release_mic_during_playback = release
  logEl.children.length = 0

  const hook = Object.create(VoiceHook)
  hook.el = el
  hook.pushEvent = () => {}
  hook.handleEvent = () => {}
  hook.mounted()
  hook.micReacquireDebounceMs = debounceMs
  await hook._toggle() // the mic button: joins the channel and arms
  await settle()
  return hook
}

const logKinds = () => logEl.children.map((li) => li.dataset.voiceMicRelease).filter(Boolean)

// ======================================================================
console.log("\n1. the flag arrives from the hub, and nothing else does")
{
  const hook = await freshHook({ release: true })
  ok("the join reply turns the release on", hook.releaseMicDuringPlayback === true)
  eq(
    "the constraints are untouched by it",
    hook.audioConstraints,
    globalThis.__voiceStubs.joinReply.audio_constraints
  )
  hook._readReleaseMicFlag({ release_mic_during_playback: "true" })
  ok("a STRING is not a boolean and is refused", hook.releaseMicDuringPlayback === true)
  hook._readReleaseMicFlag({ release_mic_during_playback: false })
  ok("a real false is honoured", hook.releaseMicDuringPlayback === false)
  hook._readReleaseMicFlag({})
  ok("a reply without the field leaves the last value alone", hook.releaseMicDuringPlayback === false)
  hook._teardown()
}

// ======================================================================
console.log("\n2. flag OFF — the shipped behaviour is byte-for-byte unchanged")
{
  const hook = await freshHook({ release: false })
  const capture = hook.capture
  ok("armed", hook._micLive() === true)

  tts(true)
  await settle()
  ok("the track is NOT stopped", capture.stopped === false)
  ok("the capture is still the same object", hook.capture === capture)
  ok("the mic is muted, as today", hook.muted === true)
  ok("the VAD is paused, not destroyed", hook.vad.paused === true && hook.vad.destroyed === false)
  eq("the bar says exactly what it said before", micEl.textContent, "mic muted (TTS playing)")
  ok("no release was logged", logKinds().length === 0)
  ok("the mute watchdog armed as usual", hook.stats().muteWatchdogArmed === true)

  tts(false)
  await settle(80)
  ok("the VAD resumed", hook.vad.paused === false)
  ok("still the same capture — no re-acquire happened", hook.capture === capture)
  eq("metrics record nothing", [hook.metrics.micReleases, hook.metrics.micReacquires], [0, 0])
  hook._teardown()
}

// ======================================================================
console.log("\n3. flag ON — {playing:true} STOPS the track, not just the VAD")
{
  const hook = await freshHook({ release: true })
  const capture = hook.capture

  tts(true)
  await settle()
  ok("the track was stopped", capture.stopped === true)
  ok("readyState is no longer live", capture.track.readyState === "ended")
  ok("the hook is holding no capture", hook.capture === null)
  ok("`armed` went false with it", hook.armed === false)
  ok("the VAD was destroyed, not merely paused", hook.vad === null)
  ok("the release is flagged as OURS", hook._micReleased === true)
  ok("...and the mute still happened, unchanged", hook.muted === true)
  ok("the mute watchdog still armed on the same edge", hook.stats().muteWatchdogArmed === true)
  eq("it was logged", logKinds(), ["released"])
  eq("one release counted", hook.metrics.micReleases, 1)
  hook._teardown()
}

// ======================================================================
console.log("\n4. ORCAHUB3-91's watcher must NOT report a deliberate release")
{
  const hook = await freshHook({ release: true })
  tts(true)
  await settle()
  eq("the bar says released, NOT 'stopped — tap the mic'", micEl.textContent, "mic released (TTS playing)")
  ok("no repair was scheduled", !hook._timers.reconcile)

  // The liveness callback firing anyway (a queued event racing the release)
  // must not turn into a repair either.
  hook._onLiveness("the microphone stopped", false)
  ok("a stray liveness callback schedules no repair", !hook._timers.reconcile)

  // ...nor may a visibilitychange mid-playback re-arm behind the release.
  await hook._reconcileMic()
  await settle()
  ok("a reconcile mid-playback does not re-arm", hook.capture === null)
  ok("...and leaves the release in place", hook._micReleased === true)

  // ...nor may the mic button spend its one repair press on it.
  const before = hook.active
  ok("voice is on before the press", before === true)
  await hook._toggle()
  ok("the press turned voice OFF, the ordinary thing", hook.active === false)
  hook._teardown()
}

// ======================================================================
console.log("\n5. {playing:false} re-acquires — after the debounce, not before")
{
  const hook = await freshHook({ release: true, debounceMs: 60 })
  const first = hook.capture
  tts(true)
  await settle()

  tts(false)
  await settle(10)
  ok("still released 10ms in — the debounce is real", hook._micReleased === true)
  ok("a re-acquire is armed", hook.stats().micReacquireArmed === true)
  ok("the mute was lifted immediately, as before", hook.muted === false)

  await settle(120)
  ok("a NEW capture was opened", hook.capture !== null && hook.capture !== first)
  ok("it is live", hook.capture.live() === true)
  ok("the release state is cleared", hook._micReleased === false)
  ok("armed again", hook._micLive() === true)
  ok("a fresh VAD session was built", hook.vad !== null && hook.vad.destroyed === false)
  eq("the transitions were logged in order", logKinds(), ["released", "re-acquired"])
  eq("counted", [hook.metrics.micReleases, hook.metrics.micReacquires], [1, 1])
  ok("and MEASURED", typeof hook.metrics.micReacquireMs === "number")
  eq("the bar is back to listening", micEl.textContent, "mic: listening")
  hook._teardown()
}

// ======================================================================
console.log("\n6. thrash — chunked playback must not release once per chunk")
{
  const hook = await freshHook({ release: true, debounceMs: 60 })
  tts(true)
  await settle()
  const stopsAfterFirst = globalThis.__voiceStubs.stops.length

  // Four chunk boundaries, each a false/true pair 20 ms apart — well inside
  // the debounce. This is the shape the streaming player would produce if it
  // ever stopped parking with `playing` true across a synthesis gap.
  for (let i = 0; i < 4; i++) {
    tts(false)
    await settle(20)
    ok(`chunk gap ${i + 1}: still released`, hook._micReleased === true)
    tts(true)
    await settle(20)
    ok(`chunk gap ${i + 1}: no re-acquire was left armed`, hook.stats().micReacquireArmed === false)
  }

  eq("the track was stopped exactly ONCE", globalThis.__voiceStubs.stops.length, stopsAfterFirst)
  eq("one release, no re-acquires", [hook.metrics.micReleases, hook.metrics.micReacquires], [1, 0])

  // ...and the end of the message still gets the microphone back.
  tts(false)
  await settle(140)
  ok("the real end re-acquires", hook._micLive() === true)
  eq("exactly one release/re-acquire for the whole message", logKinds(), ["released", "re-acquired"])
  hook._teardown()
}

// ======================================================================
console.log("\n7. the VAD is never fed from a track that is not live")
{
  const hook = await freshHook({ release: true, debounceMs: 20 })
  // Slow the re-acquire down AFTER arming, so the check can land a frame in
  // the window where the pipeline is half-built.
  globalThis.__voiceStubs.openDelayMs = 60
  const vad = hook.vad
  hook._onFrame({ samples: new Float32Array(512), endSample: 512 })
  eq("fed while armed", vad.fed.length, 1)

  tts(true)
  await settle()
  hook._onFrame({ samples: new Float32Array(512), endSample: 1024 })
  eq("not fed while released", vad.fed.length, 1)

  tts(false)
  // Mid re-acquire: `open()` is deliberately slow here, so this lands while
  // the pipeline is half-built. A frame from the old worklet must not reach
  // the new VAD session.
  await settle(30)
  ok("we are mid-re-acquire", hook._reacquiring === true)
  hook._onFrame({ samples: new Float32Array(512), endSample: 2048 })
  // Total across EVERY VAD session ever built: the frame must not have been
  // swallowed by the old one nor handed to a newly-built one.
  const fedEverywhere = () =>
    globalThis.__voiceStubs.vads.reduce((n, v) => n + v.fed.length, 0)
  eq("not fed while re-acquiring", [vad.fed.length, fedEverywhere()], [1, 1])
  eq("the bar says so", micEl.textContent, "mic: taking the microphone back…")

  await settle(140)
  ok("live again", hook.capture.live() === true)
  hook._onFrame({ samples: new Float32Array(512), endSample: 512 })
  eq("fed again once live", hook.vad.fed.length, 1)
  globalThis.__voiceStubs.openDelayMs = 0
  hook._teardown()
}

// ======================================================================
console.log("\n8. ORCAHUB3-95's mute watchdog across a release")
{
  const hook = await freshHook({ release: true, debounceMs: 40 })
  hook.muteWatchdogMs = 60

  tts(true)
  await settle()
  ok("released", hook._micReleased === true)
  ok("the watchdog is armed, exactly as it is without this feature", !!hook._muteTimer)

  // The `{playing: false}` never arrives — the wedge the watchdog exists for.
  await settle(150)
  eq("the watchdog fired once", hook.metrics.muteWatchdogs, 1)
  ok("it unmuted", hook.muted === false)
  ok("AND took the microphone back — an unmuted mic that does not exist is the same wedge",
    hook._micLive() === true)
  eq("no debounce was waited for; it re-acquired at once", hook.metrics.micReacquires, 1)
  hook._teardown()
}

// ======================================================================
console.log("\n9. a frozen page: the debounce is re-derived from the clock")
{
  const hook = await freshHook({ release: true, debounceMs: 50 })
  tts(true)
  await settle()
  tts(false)
  // Simulate a backgrounded page whose setTimeout never ran: cancel the
  // timer by hand and backdate the idle stamp past the debounce.
  clearTimeout(hook._timers.micReacquire)
  hook._timers.micReacquire = null
  hook._playbackIdleSince = Date.now() - 5000
  ok("still released, with no timer left to fix it", hook._micReleased === true)

  await hook._reconcileMic()
  await settle(30)
  ok("the visibility reconcile took the microphone back", hook._micLive() === true)
  eq("and said why", logKinds(), ["released", "re-acquired"])
  hook._teardown()
}

// ======================================================================
console.log("\n10. a re-acquire that does NOT come back live hands over to §7")
{
  const hook = await freshHook({ release: true, debounceMs: 20 })
  tts(true)
  await settle()
  globalThis.__voiceStubs.forceDead = true
  tts(false)
  await settle(80)

  ok("the release state is cleared regardless — never a permanent latch", hook._micReleased === false)
  eq("the failure is counted", hook.metrics.micReacquireFailures, 1)
  eq("and logged honestly", logKinds(), ["released", "re-acquire-failed"])
  ok("the ordinary liveness repair is now scheduled", !!hook._timers.reconcile)
  globalThis.__voiceStubs.forceDead = false
  hook._teardown()
}

// ======================================================================
console.log("\n11. voice off while released")
{
  const hook = await freshHook({ release: true, debounceMs: 30 })
  tts(true)
  await settle()
  await hook._toggle() // voice off
  ok("the release state went with it", hook._micReleased === false)
  ok("no re-acquire timer survived", !hook._timers.micReacquire)

  // A late `{playing: false}` from a player that kept going must not turn
  // the microphone back on behind a user who switched voice off.
  tts(false)
  await settle(80)
  ok("voice is still off", hook.active === false)
  ok("no microphone was opened", hook.capture == null)
}

// ======================================================================
console.log("\n12. the flag turning OFF mid-playback still returns the mic")
{
  const hook = await freshHook({ release: true, debounceMs: 30 })
  tts(true)
  await settle()
  ok("released under the old setting", hook._micReleased === true)

  // A rejoin lands with the flag now off (the user changed the setting).
  hook._readReleaseMicFlag({ release_mic_during_playback: false })
  tts(false)
  await settle(90)
  ok("the mic still came back — only the RELEASE is gated, never the return",
    hook._micLive() === true)
  hook._teardown()
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
