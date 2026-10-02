// Standalone checks for the voice view's READ-ALOUD RAIL, HELD STRIP and
// TAP-TO-JUMP (ORCAHUB3-113 phase C, W3). Plain node script, same convention
// as tts_hold.check.mjs:
//
//     node assets/js/tts_rail.check.mjs
//
// Exits non-zero on the first broken expectation, and is gated by the ExUnit
// suite through test/orca_hub_web/tts_rail_check_test.exs.
//
// WHAT THIS CAN AND CANNOT PROVE. It drives the REAL `tts_rail.js`, so every
// decision below — what the rail shows in which state, how a long message's
// progress bar is capped, which sentence a tap lands on — is the production
// code path. It CANNOT prove the browser half: that `caretPositionFromPoint`
// on a phone puts the caret where the finger was, that `Range.comparePoint`
// orders a caret against a chunk the way the fake number line below does,
// or that the rail lays out at 390 px. Those are real-page claims (the
// v120 harness, then Zach's phone). The fake locate here is a stand-in for
// comparePoint's CONTRACT (-1 / 0 / 1), nothing more.
//
// The wiring into app.js is pinned by source assertions at the bottom, the
// same honest-about-what-it-is way tts_hold.check.mjs pins its entry points.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

import {
  railSegments,
  ttsRailState,
  heldStripState,
  tapJumpTarget,
  caretAt,
  chunkIndexAt,
  hasJumpRanges,
  RAIL_MAX_SEGMENTS,
  HELD_STRIP_LABEL,
  RAIL_MARKUP,
  HELD_MARKUP,
  SEGMENT_CLASS,
} from "./tts_rail.js"

const HERE = dirname(fileURLToPath(import.meta.url))

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

// ======================================================================
console.log("\n1. the segmented progress bar")
{
  eq("nothing queued draws nothing", railSegments(0, 0), [])
  eq("a bad total draws nothing", railSegments(undefined, 0), [])
  eq(
    "the mockup: sentence 3 of 5",
    railSegments(5, 2),
    ["done", "done", "on", "todo", "todo"]
  )
  eq("the first sentence lights the first segment", railSegments(3, 0), ["on", "todo", "todo"])
  eq("the last sentence lights the last segment", railSegments(3, 2), ["done", "done", "on"])
  eq("an index past the end is clamped to the last", railSegments(3, 9), ["done", "done", "on"])
  eq("a negative index is clamped to the first", railSegments(3, -4), ["on", "todo", "todo"])

  const long = 120
  ok("a long message is CAPPED", railSegments(long, 0).length === RAIL_MAX_SEGMENTS)
  ok(
    "the cap never invents segments for a short one",
    railSegments(RAIL_MAX_SEGMENTS - 1, 0).length === RAIL_MAX_SEGMENTS - 1
  )

  // Walk every sentence of a capped message: the lit segment must never move
  // backwards, never skip one, start at the first and end at the last, and
  // everything before it must read as done.
  let prevOn = -1,
    monotonic = true,
    skipped = false,
    doneBefore = true,
    exactlyOneOn = true
  for (let i = 0; i < long; i++) {
    const segs = railSegments(long, i)
    const on = segs.indexOf("on")
    if (segs.filter((s) => s === "on").length !== 1) exactlyOneOn = false
    if (on < prevOn) monotonic = false
    if (on > prevOn + 1) skipped = true
    if (segs.slice(0, on).some((s) => s !== "done")) doneBefore = false
    if (segs.slice(on + 1).some((s) => s !== "todo")) doneBefore = false
    prevOn = on
  }
  ok("capped: exactly one segment is lit at every sentence", exactlyOneOn)
  ok("capped: the lit segment never moves backwards", monotonic)
  ok("capped: it never skips a segment", !skipped)
  ok("capped: done before it, todo after it, at every sentence", doneBefore)
  ok("capped: sentence 1 lights segment 1", railSegments(long, 0)[0] === "on")
  ok("capped: the last sentence lights the last segment", railSegments(long, long - 1).at(-1) === "on")
  eq("the cap is overridable", railSegments(10, 9, 2), ["done", "on"])
}

// ======================================================================
console.log("\n2. what the rail shows")
{
  const reading = ttsRailState({ playing: true, queued: 5, currentIndex: 2, pageState: "reply", currentId: "m1" })
  ok("reading is visible", reading.visible === true)
  eq("reading mode", reading.mode, "playing")
  eq("the live position, 1-based", reading.label, "Sentence 3 of 5")
  eq("its bar", reading.segments, ["done", "done", "on", "todo", "todo"])
  ok("reading is a transport (prev/next/stop shown)", reading.transport === true)
  eq("the big control is Pause", [reading.icon, reading.toggleLabel], ["pause", "Pause"])
  eq("in the mockup's amber", reading.tone, "warning")
  ok("prev works past the first sentence", reading.prevEnabled === true)

  const first = ttsRailState({ playing: true, queued: 5, currentIndex: 0 })
  ok("prev is disabled on the first sentence", first.prevEnabled === false)
  ok("next stays enabled on the last — it ends the read, like the footer's", ttsRailState({ playing: true, queued: 5, currentIndex: 4 }).nextEnabled === true)

  const paused = ttsRailState({ playing: false, queued: 5, currentIndex: 1 })
  eq("a loaded queue with playback stopped is paused", paused.mode, "paused")
  eq("paused offers Play", [paused.icon, paused.toggleLabel], ["play", "Play"])
  eq("paused is not amber — nothing is holding the mic", paused.tone, "primary")
  eq("paused keeps its place", paused.label, "Sentence 2 of 5")

  ok(
    "a read in progress shows WHATEVER the page state — dictating included (a pause must stay reachable)",
    ttsRailState({ playing: true, queued: 3, pageState: "dictating" }).mode === "playing" &&
      ttsRailState({ playing: true, queued: 3, pageState: "working" }).mode === "playing"
  )
  eq(
    "a streamed read growing under the label says so honestly",
    ttsRailState({ playing: true, queued: 4, currentIndex: 3 }).label,
    "Sentence 4 of 4"
  )

  const ready = ttsRailState({ queued: 0, pageState: "reply", currentId: "m7", currentReadable: true })
  eq("nothing queued in `reply` offers a big Play for the message on screen", ready.mode, "ready")
  eq("...which reads THAT message", ready.readId, "m7")
  ok("...with no transport around it", ready.transport === false)
  eq("...and no static hint text (D9)", ready.label, "")
  ok("`paging` offers it too", ttsRailState({ pageState: "paging", currentId: "m3", currentReadable: true }).mode === "ready")
  ok("`dictating` does not (no message on screen)", ttsRailState({ pageState: "dictating", currentId: "m7", currentReadable: true }).visible === false)
  ok(
    "`working` does not (the turn is still being written)",
    ttsRailState({ pageState: "working", currentId: "m7", currentReadable: true }).visible === false
  )
  ok("no current message, no Play", ttsRailState({ pageState: "reply", currentId: null, currentReadable: true }).visible === false)
  ok(
    "a current message with nothing to read (a user message, an all-code reply) gets no Play",
    ttsRailState({ pageState: "reply", currentId: "u1", currentReadable: false }).visible === false
  )
  ok("no page state at all (not the voice view) hides it", ttsRailState({ currentId: "m7", currentReadable: true }).visible === false)

  ok(
    "the reply on screen IS the held one: the held strip already offers that Play, so the rail does not",
    ttsRailState({ pageState: "reply", currentId: "m9", currentReadable: true, held: { id: "m9", at: 1 } }).visible === false
  )
  ok(
    "paged to a DIFFERENT message while one is held: the rail's Play is back (it reads something else)",
    ttsRailState({ pageState: "paging", currentId: "m2", currentReadable: true, held: { id: "m9", at: 1 } }).mode === "ready"
  )
  eq("called with nothing at all", ttsRailState().mode, "hidden")
}

// ======================================================================
console.log("\n3. the held strip")
{
  const shown = heldStripState({ held: { id: "m9", at: 1 } })
  ok("a hold is visible", shown.visible === true)
  eq("the voice view's wording", shown.label, "Reply ready, held while you talk")
  eq("the exported label is that wording", HELD_STRIP_LABEL, "Reply ready, held while you talk")
  ok("no hold, no strip", heldStripState({ held: null }).visible === false)
  ok("a hold with no id is not a hold", heldStripState({ held: { at: 1 } }).visible === false)
  ok("called with nothing at all", heldStripState().visible === false)
}

// ======================================================================
console.log("\n4. which taps ask to jump")
{
  // A fake element chain: `closest(sel)` walks up and returns the first node
  // whose `tags` intersect what the selector names. Enough for the two
  // selectors tapJumpTarget asks about.
  const node = (tags, parent = null, id = "") => ({
    tags,
    parent,
    id,
    closest(sel) {
      const wants = sel.split(",").map((s) => s.trim())
      for (let n = this; n; n = n.parent) {
        if (wants.some((w) => n.tags.includes(w))) return n
      }
      return null
    },
  })
  const bubble = node(["[data-tts-text]"], null, "tts-text-abc-123")
  const para = node(["p"], bubble)
  const link = node(["a"], para)
  const linkText = node(["span"], link)
  const button = node(["button"], para)
  const outside = node(["div"])

  eq("a tap on the message text in voice view jumps", tapJumpTarget({ target: para, viewShowing: true }), "abc-123")
  eq("the bubble itself counts", tapJumpTarget({ target: bubble, viewShowing: true }), "abc-123")
  eq("NOT off the voice view — a click on text is a click on text", tapJumpTarget({ target: para, viewShowing: false }), null)
  eq("a link keeps its tap (it still follows)", tapJumpTarget({ target: link, viewShowing: true }), null)
  eq("...including a tap on text INSIDE the link", tapJumpTarget({ target: linkText, viewShowing: true }), null)
  eq("a button keeps its tap", tapJumpTarget({ target: button, viewShowing: true }), null)
  eq(
    "not while text is selected (a long-press to copy ends in a click)",
    tapJumpTarget({ target: para, viewShowing: true, selectionCollapsed: false }),
    null
  )
  eq("outside any message bubble, nothing", tapJumpTarget({ target: outside, viewShowing: true }), null)
  eq(
    "a bubble whose id is not tts-text-<id> is not trusted",
    tapJumpTarget({ target: node(["[data-tts-text]"], null, "something-else"), viewShowing: true }),
    null
  )
  eq(
    "an empty id after the prefix is not an id",
    tapJumpTarget({ target: node(["[data-tts-text]"], null, "tts-text-"), viewShowing: true }),
    null
  )
  eq("a target with no closest() (a text node) is ignored", tapJumpTarget({ target: {}, viewShowing: true }), null)
  eq("called with nothing at all", tapJumpTarget(), null)
}

// ======================================================================
console.log("\n5. the caret under a point, from either browser API")
{
  const textNode = { nodeType: 3 }
  const std = { caretPositionFromPoint: () => ({ offsetNode: textNode, offset: 7 }) }
  const webkit = { caretRangeFromPoint: () => ({ startContainer: textNode, startOffset: 4 }) }
  const both = { ...std, caretRangeFromPoint: () => ({ startContainer: {}, startOffset: 99 }) }

  eq("the standard API", caretAt(std, 10, 20), { node: textNode, offset: 7 })
  eq("WebKit's", caretAt(webkit, 10, 20), { node: textNode, offset: 4 })
  eq("the standard one wins when both exist", caretAt(both, 10, 20).offset, 7)
  eq(
    "a standard API that finds nothing falls through to WebKit's",
    caretAt({ caretPositionFromPoint: () => null, ...webkit }, 1, 1),
    { node: textNode, offset: 4 }
  )
  eq("neither API: null", caretAt({}, 1, 1), null)
  eq("non-finite coordinates: null", caretAt(std, NaN, 1), null)
  eq("no document: null", caretAt(null, 1, 1), null)
}

// ======================================================================
console.log("\n6. which sentence a tap lands on")
{
  // A number line stands in for document order: each chunk is [start, end]
  // and `locate` answers Range.comparePoint's -1 / 0 / 1 for a caret at `c`.
  // Boundaries are INCLUSIVE, as comparePoint's are.
  const chunks = [
    { s: 0, e: 10 },
    { s: 12, e: 20 }, // gap 10..12 = the space between sentences
    { s: 20, e: 30 }, // shares a boundary with the one before
    { s: 50, e: 60 }, // gap 30..50 = a fenced code block, never read
  ]
  const at = (c, ranges = chunks) =>
    chunkIndexAt(ranges, (r) => (c < r.s ? -1 : c > r.e ? 1 : 0))

  eq("inside the first sentence", at(5), 0)
  eq("inside a later one", at(55), 3)
  eq("in the gap between two sentences -> the next one", at(11), 1)
  eq("in a skipped code block -> the prose after it", at(40), 3)
  eq("ON a shared boundary -> the LATER sentence (the caret is at its first character)", at(20), 2)
  eq("at the very start", at(0), 0)
  eq("before every chunk -> the first", at(-5), 0)
  eq("after every chunk -> the last", at(99), 3)

  const withHoles = [null, chunks[1], null, chunks[3]]
  eq("unresolved ranges are skipped, not matched", at(5, withHoles), 1)
  eq("...and never chosen as 'the last'", at(99, withHoles), 3)
  eq(
    "a range the browser could not compare (null) is skipped",
    chunkIndexAt(chunks, (r) => (r === chunks[0] ? null : 5 < r.s ? -1 : 5 > r.e ? 1 : 0)),
    1
  )
  eq("nothing comparable at all -> -1 (the caller does nothing)", chunkIndexAt([null, null], () => 0), -1)
  eq("an empty message -> -1", chunkIndexAt([], () => 0), -1)
  eq("no ranges array -> -1", chunkIndexAt(null, () => 0), -1)
  eq("no locate -> -1", chunkIndexAt(chunks, null), -1)
}

// ======================================================================
console.log("\n7. can the loaded message be jumped within")
{
  ok("chunks with ranges can", hasJumpRanges(["a", "b"], [{}, {}]) === true)
  ok("some unresolved ranges still can", hasJumpRanges(["a", "b"], [null, {}]) === true)
  ok(
    "a STREAMED read cannot (chunks, no ranges) — the tap re-reads it from the DOM",
    hasJumpRanges(["a", "b", "c"], []) === false
  )
  ok("ranges that do not line up with the chunks cannot", hasJumpRanges(["a", "b", "c"], [{}, {}]) === false)
  ok("all-unresolved cannot", hasJumpRanges(["a"], [null]) === false)
  ok("nothing loaded cannot", hasJumpRanges([], []) === false)
}

// ======================================================================
console.log("\n8. the skeletons carry every hook the renderer looks up")
{
  for (const hook of [
    "data-tts-rail ",
    "data-tts-rail-progress",
    "data-tts-rail-label",
    "data-tts-rail-segments",
    'data-tts-rail-action="prev"',
    'data-tts-rail-action="toggle"',
    'data-tts-rail-action="next"',
    'data-tts-rail-action="stop"',
    "data-tts-rail-icon",
    "data-tts-rail-toggle-label",
  ]) {
    ok(`rail: ${hook.trim()}`, RAIL_MARKUP.includes(hook))
  }
  for (const hook of [
    "data-tts-held ",
    "data-tts-held-label",
    'data-tts-held-action="play"',
    'data-tts-held-action="dismiss"',
  ]) {
    ok(`held: ${hook.trim()}`, HELD_MARKUP.includes(hook))
  }
  ok(
    "both start hidden — an idle container must collapse to nothing (D9)",
    /data-tts-rail class="hidden /.test(RAIL_MARKUP) && /data-tts-held class="hidden /.test(HELD_MARKUP)
  )
  ok(
    "every button is type=button, so none can ever submit an enclosing form",
    [RAIL_MARKUP, HELD_MARKUP].every(
      (m) => (m.match(/<button\b/g) || []).length === (m.match(/<button type="button"/g) || []).length
    )
  )
  ok("the dismiss says what it does", /aria-label="Dismiss this reply without reading it"/.test(HELD_MARKUP))
  ok("every segment state has classes", ["done", "on", "todo"].every((s) => typeof SEGMENT_CLASS[s] === "string"))
}

// ======================================================================
console.log("\n9. app.js wiring")
{
  const app = readFileSync(join(HERE, "app.js"), "utf8")
  const body = (sig, n = 1200) => {
    const at = app.search(sig)
    return at < 0 ? "" : app.slice(at, at + n)
  }

  ok("the rules are imported, not re-implemented", /from "\.\/tts_rail"/.test(app))
  ok("voiceViewShowing comes from W1's shared flag module", /import \{ voiceViewShowing \} from "\.\/voice_view_flag"/.test(app))

  // The spec's "same choke point as ttsRenderBar, not new call sites": the
  // rail rides ttsRenderBar (so every ttsEmitState and hold transition) and
  // ttsUpdateUI (every index change). The only other callers are the mount
  // and the <html> observer, which is state the player does not own.
  ok("ttsRenderBar renders the voice view too", /ttsRenderBar\(\)\s*\{\s*this\.ttsRenderVoice\(\)/.test(app))
  ok("ttsUpdateUI renders it (the sentence counter moves there)", /ttsUpdateUI\(id\)\s*\{[\s\S]{0,400}?this\.ttsRenderVoice\(\)/.test(app))
  ok(
    "and nothing else grew a call site",
    (app.match(/this\.ttsRenderVoice\(\)/g) || []).length === 4
  )
  ok(
    "the observer watches exactly the page state the rail reads",
    /attributeFilter: \["data-voice-state", "data-voice-current", "data-voice-view", "data-voice-layout"\]/.test(app)
  )
  ok("it is disconnected on unmount", /_ttsVoiceObserver\.disconnect\(\)/.test(app))
  ok("unmount empties both containers (no dead Play left behind)", /\["voice-rail", "voice-held"\][\s\S]{0,120}?replaceChildren\(\)/.test(app))

  ok(
    "End stops the reading only from the voice view (D2)",
    /addEventListener\("orca:voice-ended", this\._onVoiceEnded\)/.test(app) &&
      /_onVoiceEnded = \(e\) => \{\s*if \(e\.detail && e\.detail\.viewShowing\) this\.ttsStop\(\)/.test(app)
  )

  const tap = body(/ttsTapJump\(e\)\s*\{/, 1400)
  ok("the tap listener is on the feed element", /this\.el\.addEventListener\("click", \(e\) => this\.ttsTapJump\(e\)\)/.test(app))
  ok("the tap asks voiceViewShowing()", /viewShowing: voiceViewShowing\(\)/.test(tap))
  ok("the tap respects a text selection", /selectionCollapsed:/.test(tap))
  ok(
    "a tap on another message starts it AT the tapped chunk",
    /this\.ttsStart\(id, \{ startIndex: index \}\)/.test(tap)
  )
  ok("a tap on the loaded message jumps within it", /this\.ttsJumpTo\(index\)/.test(tap))
  ok(
    "the browser comparison cannot throw into a tap",
    /ttsComparePoint\(spec, caret\)\s*\{\s*try \{[\s\S]{0,300}?comparePoint\(caret\.node, caret\.offset\)[\s\S]{0,80}?catch/.test(app)
  )
  ok(
    "ttsStart clamps the start index",
    /ttsStart\(id, \{ startIndex = 0 \} = \{\}\)\s*\{[\s\S]{0,900}?Math\.min\(Math\.max\(startIndex, 0\), chunks\.length - 1\)/.test(app)
  )

  const rail = body(/ttsRailAction\(action\)\s*\{/, 700)
  ok("the rail's Play reads the message on screen through the normal toggle", /ttsHandleAction\(state\.readId, "toggle"\)/.test(rail))
  ok("prev/next/stop only act on a loaded read", /if \(!state\.transport\) return/.test(rail))

  ok(
    "the held strip and the bar share ONE play/dismiss",
    /data-tts-held-action[\s\S]{0,400}?this\.ttsPlayHeld\(\)[\s\S]{0,200}?this\.ttsDismissHeld\(\)/.test(app) &&
      /state\.mode === "held"\) this\.ttsPlayHeld\(\)/.test(app)
  )
  ok(
    "the skeleton is written once and then updated in place",
    /ttsVoiceSkeleton\(host, markup, selector\)\s*\{\s*let root = host\.querySelector\(selector\)\s*if \(!root\) \{/.test(app)
  )
}

// ======================================================================
console.log("\n10. the reading highlight in the voice view (app.css)")
{
  const css = readFileSync(join(HERE, "..", "css", "app.css"), "utf8")

  ok(
    "the voice view has its own, stronger highlight",
    /html\[data-voice-view\]\[data-voice-layout\] ::highlight\(tts-reading\)\s*\{[^}]*40%/.test(css)
  )
  ok(
    "...under the variant's media query",
    /@media \(max-width: 767px\)\s*\{\s*html\[data-voice-view\]\[data-voice-layout\] ::highlight\(tts-reading\)/.test(css)
  )
  // THE TRAP: written as `@variant voice-view { ... }` nested inside
  // `::highlight(...) { }`, the dev build keeps native nesting, a nesting `&`
  // cannot stand for a pseudo-element, and the override silently matches
  // nothing in dev while working in the minified prod build. Measured in
  // headless Chrome, 2026-10-02.
  ok(
    "it is NOT nested under the pseudo-element (that form is dead in the dev build)",
    !/::highlight\(tts-reading\)\s*\{[^}]*@(variant|media)/.test(css)
  )
  ok("the fallback class gets the same treatment", /html\[data-voice-view\]\[data-voice-layout\] \.tts-reading-fallback\s*\{/.test(css))
  ok("the normal feed keeps its subtler tint", /^::highlight\(tts-reading\)\s*\{\s*background-color: color-mix\(in oklch, var\(--color-primary\) 25%/m.test(css))
}

// ======================================================================
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
