// Standalone checks for the live assistant bubble's LIFETIME rules
// (voice_mode_spec.md §7.2 / C2, and ORCAHUB3-114). The repo has no JS test
// runner, so this is a plain node script, same convention as
// tts_stream.check.mjs:
//
//     node assets/js/assistant_stream.check.mjs
//
// It is also run from Elixir (see assistant_stream_check_test.exs) so the
// suite actually gates it.
//
// Exits non-zero on the first broken expectation.
//
// An optional argument points at a DIFFERENT module to check — used to prove
// these assertions actually go red against the pre-ORCAHUB3-114 implementation
// rather than merely passing against the fixed one:
//
//     node assets/js/assistant_stream.check.mjs /tmp/legacy_assistant_stream.js
//
// Everything below drives the methods object directly against a minimal DOM
// shim; there is no Phoenix, no socket and no browser involved.

const modulePath = process.argv[2] || "./assistant_stream.js"

let pass = 0, fail = 0
const ok = (name, cond) => {
  if (cond) { pass++; console.log(`  ok   ${name}`) }
  else { fail++; console.log(`  FAIL ${name}`) }
}
const eq = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  if (g === w) { pass++; console.log(`  ok   ${name}`) }
  else { fail++; console.log(`  FAIL ${name}\n       got  ${g}\n       want ${w}`) }
}

// ── minimal DOM shim ────────────────────────────────────────────────────
// Only what assistant_stream.js actually touches: createElement, appendChild,
// remove, textContent, dataset, id/className, isConnected, getElementById and
// a single-attribute querySelector.

class El {
  constructor(tag) {
    this.tagName = tag
    this.dataset = {}
    this.children = []
    this.parent = null
    this._id = ""
    this.className = ""
    this._text = ""
  }
  get id() { return this._id }
  set id(v) { this._id = v; if (v) doc._byId.set(v, this) }
  get textContent() {
    return this._text + this.children.map(c => c.textContent).join("")
  }
  set textContent(v) { this._text = String(v); this.children = [] }
  appendChild(child) { child.parent = this; this.children.push(child); return child }
  remove() {
    if (!this.parent) return
    const i = this.parent.children.indexOf(this)
    if (i >= 0) this.parent.children.splice(i, 1)
    this.parent = null
  }
  get isConnected() {
    let n = this
    while (n.parent) n = n.parent
    return n === doc.root
  }
  // Supports exactly `[attr="value"]` and `[attr]`, which is all the module
  // asks for. Walks the subtree depth-first.
  querySelector(sel) {
    const m = /^\[([a-z-]+)(?:="(.*)")?\]$/.exec(sel)
    if (!m) throw new Error(`shim querySelector: unsupported selector ${sel}`)
    const key = m[1].replace(/^data-/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase())
    const want = m[2]
    const walk = (node) => {
      for (const c of node.children) {
        const v = c.dataset[key]
        if (v !== undefined && (want === undefined || v === want)) return c
        const found = walk(c)
        if (found) return found
      }
      return null
    }
    return walk(this)
  }
}

const doc = {
  root: new El("html"),
  _byId: new Map(),
  createElement: (tag) => new El(tag),
  getElementById: (id) => {
    const el = doc._byId.get(id)
    return el && el.isConnected ? el : null
  },
  querySelector: (sel) => doc.root.querySelector(sel)
}

globalThis.document = doc
globalThis.window = { dispatchEvent() {} }
globalThis.CustomEvent = class { constructor(t, o) { this.type = t; Object.assign(this, o) } }

const {
  AssistantStreamMethods,
  ASSISTANT_STREAM_MAX_IDLE_MS
} = await import(modulePath)

// ── harness ─────────────────────────────────────────────────────────────

// A fresh slot + a fresh `this` for each scenario. `handleEvent` is captured
// so a scenario can push events the way LiveView would.
function newHook() {
  doc.root.children = []
  doc._byId.clear()

  const slot = doc.createElement("div")
  slot.id = "assistant-stream-slot"
  doc.root.appendChild(slot)

  const feed = doc.createElement("div")
  feed.id = "message-feed"
  doc.root.appendChild(feed)

  const hook = Object.assign(Object.create(null), AssistantStreamMethods, {
    following: false,
    handleEvent(_name, cb) { hook._push = cb }
  })
  hook.assistantStreamMount()
  hook._slot = slot
  hook._feed = feed
  return hook
}

// Renders the persisted assistant message the live bubble is standing in for.
function renderPersisted(hook, streamId, text = "hello world") {
  const bubble = doc.createElement("div")
  bubble.dataset.messageId = streamId
  bubble.textContent = text
  hook._feed.appendChild(bubble)
  return bubble
}

const liveBubble = (hook, streamId) => doc.getElementById(`stream-${streamId}`)
const liveCount = (hook) => hook._slot.children.length

// Streams a normal text message WITHOUT ever sending the stop.
function streamText(hook, streamId, text = "hello world") {
  hook.assistantStreamApply({ op: "start", stream_id: streamId })
  hook.assistantStreamApply({ op: "block_start", stream_id: streamId, block_index: 0, block_type: "text" })
  hook.assistantStreamApply({ op: "delta", stream_id: streamId, block_index: 0, text })
}

const cleanup = (hook) => hook.assistantStreamDestroy()

// ── 1. the reported bug: no stop, persisted message rendered ────────────
// The server never sent `op: "stop"` (interrupt / crash / dropped push) and
// the real message rendered anyway. The live bubble is now a duplicate and
// must go, stop or no stop.
{
  const hook = newHook()
  streamText(hook, "msg_1")
  ok("bubble is live while streaming", !!liveBubble(hook, "msg_1"))

  renderPersisted(hook, "msg_1")
  hook.assistantStreamReconcile()

  ok("ORCAHUB3-114: a bubble whose persisted message rendered is removed without a stop",
     !liveBubble(hook, "msg_1"))
  eq("no live bubbles left", liveCount(hook), 0)
  cleanup(hook)
}

// ── 2. reconcile does NOT fire early, mid-stream ────────────────────────
// The persisted message is not on screen yet, so the bubble must survive —
// otherwise the text would flash out and back in on every feed patch.
{
  const hook = newHook()
  streamText(hook, "msg_2")
  hook.assistantStreamReconcile()
  ok("a bubble with no persisted message yet survives reconcile", !!liveBubble(hook, "msg_2"))
  eq("its text is intact", liveBubble(hook, "msg_2").textContent, "Assistanthello world")
  cleanup(hook)
}

// ── 3. socket reconnect drops every live bubble ─────────────────────────
// Deltas (and the stop) pushed while disconnected are gone for good; the
// persisted message is authoritative. This is the mobile/LTE path.
{
  const hook = newHook()
  streamText(hook, "msg_3a")
  streamText(hook, "msg_3b")
  eq("two bubbles live", liveCount(hook), 2)

  hook.assistantStreamReconnected()

  eq("ORCAHUB3-114: reconnect drops every live bubble", liveCount(hook), 0)
  cleanup(hook)
}

// ── 4. a late event cannot resurrect a removed bubble ───────────────────
// assistantStreamEnsure used to happily re-create a bubble for a stream that
// had already been swapped out — and nothing would ever stop it again.
{
  const hook = newHook()
  streamText(hook, "msg_4")
  renderPersisted(hook, "msg_4")
  hook.assistantStreamReconcile()
  ok("bubble swapped out", !liveBubble(hook, "msg_4"))

  // A straggler delta and a straggler tool chip for the finished stream.
  hook.assistantStreamApply({ op: "delta", stream_id: "msg_4", block_index: 0, text: " more" })
  hook.assistantStreamApply({
    op: "block_start", stream_id: "msg_4", block_index: 1,
    block_type: "tool_use", name: "mcp__orca__run_elixir"
  })

  eq("ORCAHUB3-114: a late delta/chip does not resurrect a finished bubble", liveCount(hook), 0)
  cleanup(hook)
}

// ── 5. absolute watchdog: no stop, no persisted message, ever ───────────
// A backend that dies mid-message leaves a bubble nothing will ever render a
// persisted counterpart for. It still has to terminate.
{
  const hook = newHook()
  streamText(hook, "msg_5")
  const t0 = Date.now()

  hook.assistantStreamReconcile(t0 + ASSISTANT_STREAM_MAX_IDLE_MS - 1000)
  ok("bubble survives inside the idle window", !!liveBubble(hook, "msg_5"))

  hook.assistantStreamReconcile(t0 + ASSISTANT_STREAM_MAX_IDLE_MS + 1000)
  ok("ORCAHUB3-114: a bubble with no activity at all is eventually removed",
     !liveBubble(hook, "msg_5"))
  cleanup(hook)
}

// ── 6. the server's end-of-turn `clear` sweep ───────────────────────────
// Carries no stream id on purpose — it is exactly the case where the server
// no longer knows which ids the client holds.
{
  const hook = newHook()
  streamText(hook, "msg_6a")
  streamText(hook, "msg_6b")
  renderPersisted(hook, "msg_6a")
  renderPersisted(hook, "msg_6b")

  hook.assistantStreamApply({ op: "clear" })

  eq("ORCAHUB3-114: op:clear finishes every live bubble", liveCount(hook), 0)
  cleanup(hook)
}

// ── 7. happy path is unchanged (regression guard) ───────────────────────
// An EMPTY bubble (started, then stopped with no block at all) has nothing to
// wait for and goes immediately. A bubble carrying a tool chip does NOT —
// the chip is content, so it takes the same settle poll a text bubble does.
{
  const hook = newHook()
  hook.assistantStreamApply({ op: "start", stream_id: "msg_7a" })
  ok("empty bubble exists", !!liveBubble(hook, "msg_7a"))
  hook.assistantStreamApply({ op: "stop", stream_id: "msg_7a" })
  ok("an empty bubble is removed immediately on stop", !liveBubble(hook, "msg_7a"))

  hook.assistantStreamApply({ op: "start", stream_id: "msg_7b" })
  hook.assistantStreamApply({
    op: "block_start", stream_id: "msg_7b", block_index: 0,
    block_type: "tool_use", name: "Bash"
  })
  ok("tool chip rendered", liveBubble(hook, "msg_7b").textContent.includes("Bash…"))

  // The chip is content, so stop starts the settle poll rather than removing
  // outright — and the poll ends the moment the persisted message renders.
  hook.assistantStreamApply({ op: "stop", stream_id: "msg_7b" })
  ok("a bubble with a tool chip waits for the persisted render",
     !!liveBubble(hook, "msg_7b"))

  renderPersisted(hook, "msg_7b")
  hook.assistantStreamReconcile()
  ok("...and goes once it is there", !liveBubble(hook, "msg_7b"))
  cleanup(hook)
}

// ── 8. a thinking block renders nothing but keeps the bubble alive ──────
{
  const hook = newHook()
  hook.assistantStreamApply({ op: "start", stream_id: "msg_8" })
  hook.assistantStreamApply({
    op: "block_start", stream_id: "msg_8", block_index: 0, block_type: "thinking"
  })
  ok("thinking renders no visible block", liveBubble(hook, "msg_8").textContent === "Assistant")
  cleanup(hook)
}

// ── 9. the sweep timer does not outlive the last bubble ─────────────────
// A leaked interval would keep the node process (and a real browser tab)
// awake forever. If this regresses, this script hangs instead of exiting.
{
  const hook = newHook()
  streamText(hook, "msg_9")
  ok("sweep timer armed while a bubble is live", !!hook._streamSweepTimer)

  renderPersisted(hook, "msg_9")
  hook.assistantStreamReconcile()

  ok("ORCAHUB3-114: sweep timer cleared once the last bubble goes", !hook._streamSweepTimer)
  cleanup(hook)
}

// ── 10. destroy tears everything down ───────────────────────────────────
{
  const hook = newHook()
  streamText(hook, "msg_10")
  hook.assistantStreamDestroy()
  eq("destroy removes every bubble", liveCount(hook), 0)
  ok("destroy clears the sweep timer", !hook._streamSweepTimer)
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
