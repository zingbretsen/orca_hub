// Standalone checks for the session page's mobile VOICE VIEW state rules
// (ORCAHUB3-113 phase C). The repo has no JS test runner, so this is a plain
// node script — same convention as tts_hold.check.mjs:
//
//     node assets/js/voice_view.check.mjs
//
// Exits non-zero on the first broken expectation, and is gated by the ExUnit
// suite through test/orca_hub_web/voice_view_check_test.exs.
//
// WHAT THIS CAN AND CANNOT PROVE. It drives the REAL `voice_view.js` — every
// state rule, pager step and return-to-live trigger below is the production
// code path. What it cannot see is the page: that the generated stylesheet
// actually leaves one element visible, that the textarea fills the screen,
// that the feed does not scroll away. Those are layout claims that need a
// real browser at 390x844 (the phase's W4 verification). The hook's wiring of
// these rules to DOM events is pinned by a source assertion at the bottom:
// cheap, honest about what it is, and it catches the regression that would
// silently undo D6 (a return-to-live trigger nobody listens for any more).

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

import {
  RUNNING_STATUSES,
  VOICE_STATES,
  clockRunning,
  currentSelector,
  currentStyleText,
  feedFacts,
  formatElapsed,
  isRunning,
  pagerLabel,
  pagerSequence,
  pagerView,
  pagingAfter,
  resolvePendingStep,
  stepPager,
  voiceViewState,
} from "./voice_view.js"

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

// A conversation: u1 a1 | u2 a2 a3 | u3 — the last turn has no reply yet.
const ITEMS = [
  { id: "u1", role: "user" },
  { id: "a1", role: "assistant" },
  { id: "u2", role: "user" },
  { id: "a2", role: "assistant" },
  { id: "a3", role: "assistant" },
  { id: "u3", role: "user" },
]
const facts = (items) => feedFacts(items)
const state = (over = {}) => voiceViewState({ ...facts(ITEMS), status: "idle", ...over })

// ======================================================================
console.log("\n1. reading the feed (content markers -> facts)")
{
  const f = feedFacts(ITEMS)
  eq("content ids keep document order", f.contentIds, ["u1", "a1", "u2", "a2", "a3", "u3"])
  eq("the last user message", f.lastUserId, "u3")
  eq("no agent text after it yet", f.lastAgentIdThisTurn, null)

  const replied = feedFacts(ITEMS.slice(0, 5))
  eq("this turn's latest assistant text", replied.lastAgentIdThisTurn, "a3")
  eq("...whose turn started at u2", replied.lastUserId, "u2")

  const noUser = feedFacts([
    { id: "a1", role: "assistant" },
    { id: "a2", role: "assistant" },
  ])
  eq("with no user message loaded, the whole window is this turn", noUser.lastAgentIdThisTurn, "a2")
  eq("...and there is no last user message", noUser.lastUserId, null)

  eq("an empty feed", feedFacts([]), { contentIds: [], lastUserId: null, lastAgentIdThisTurn: null })
  eq("junk entries are dropped, not crashed on", feedFacts([null, { role: "user" }, { id: 7, role: "user" }]).contentIds, ["7"])
  eq("not an array at all", feedFacts(undefined).contentIds, [])

  eq("the stream joins the end of the sequence", pagerSequence(["u1", "a1"], "stream:m9"), ["u1", "a1", "stream:m9"])
  eq("no stream, no extra step", pagerSequence(["u1"], null), ["u1"])
  eq("a key already present is not duplicated", pagerSequence(["u1", "stream:m9"], "stream:m9"), ["u1", "stream:m9"])
}

// ======================================================================
console.log("\n2. the state rules")
{
  eq("the status-only fallback is running|compacting", RUNNING_STATUSES, ["running", "compacting"])
  ok("idle is not running", !isRunning("idle"))
  ok("error is not running", !isRunning("error"))
  ok("waiting ALONE is not running (only the server can tell a mid-turn one)", !isRunning("waiting"))
  eq("the four states", VOICE_STATES, ["dictating", "working", "reply", "paging"])

  // rule 0
  eq(
    "suppressed (C1) wins over everything — no state, no current",
    state({ suppressed: true, paging: "a1", draftBusy: true, status: "running" }),
    { state: null, current: null, running: true }
  )

  // rule 1
  eq("paging onto a loaded message", state({ paging: "a1" }), { state: "paging", current: "a1", running: false })
  eq(
    "paging wins over a busy draft (it is cleared by the transition, not by the rule)",
    state({ paging: "a1", draftBusy: true }).state,
    "paging"
  )
  eq("paging wins over a running turn", state({ paging: "u2", status: "running" }).current, "u2")
  eq(
    "paging onto the live stream bubble",
    state({ paging: "stream:m9", streamingId: "stream:m9", status: "running" }),
    { state: "paging", current: "stream:m9", running: true }
  )
  eq(
    "a paging key no longer loaded FALLS THROUGH to live",
    state({ paging: "gone" }),
    { state: "reply", current: "u3", running: false }
  )

  // rule 2
  eq("a busy draft is dictating, with no message", state({ draftBusy: true }), {
    state: "dictating",
    current: null,
    running: false,
  })
  eq(
    "D7: the draft takes the screen even mid-turn",
    state({ draftBusy: true, status: "running", streamingId: "stream:m9" }),
    { state: "dictating", current: null, running: true }
  )

  // rule 3
  eq(
    "working shows the streaming bubble first",
    state({ status: "running", streamingId: "stream:m9" }),
    { state: "working", current: "stream:m9", running: true }
  )
  eq(
    "...else this turn's latest assistant text",
    voiceViewState({ ...feedFacts(ITEMS.slice(0, 5)), status: "running" }),
    { state: "working", current: "a3", running: true }
  )
  eq(
    "...else the user's just-sent message — NOT an earlier turn's reply",
    state({ status: "running" }),
    { state: "working", current: "u3", running: true }
  )
  eq("compacting is working", state({ status: "compacting" }).state, "working")

  // The two `waiting`s (#voice-view[data-turn-running], computed server-side
  // by Session.waiting_mid_turn?/1). A pi dialog overlays a turn still in
  // flight; a Claude AskUserQuestion has ENDED the turn, so once its question
  // is dismissed (C1 lifts) the view is the reply: Play, no clock.
  eq(
    "waiting mid-turn (pi dialog, running: true) is working",
    voiceViewState({ ...feedFacts(ITEMS.slice(0, 5)), status: "waiting", running: true }),
    { state: "working", current: "a3", running: true }
  )
  eq(
    "waiting that ENDED the turn (Claude question, running: false) is reply",
    voiceViewState({ ...feedFacts(ITEMS.slice(0, 5)), status: "waiting", running: false }),
    { state: "reply", current: "a3", running: false }
  )
  ok(
    "...and its clock does not run",
    !clockRunning(voiceViewState({ ...feedFacts(ITEMS.slice(0, 5)), status: "waiting", running: false }))
  )
  ok(
    "...while the mid-turn one's does",
    clockRunning(voiceViewState({ ...feedFacts(ITEMS.slice(0, 5)), status: "waiting", running: true }))
  )
  eq("waiting with no running flag falls back to NOT running", state({ status: "waiting" }).state, "reply")
  eq("running: false overrides a running status", state({ status: "running", running: false }).state, "reply")
  eq("running: true overrides an idle status", state({ status: "idle", running: true }).state, "working")
  eq("a non-boolean running is ignored (status decides)", state({ status: "running", running: "yes" }).state, "working")
  eq(
    "working with nothing loaded at all",
    voiceViewState({ status: "running" }),
    { state: "working", current: null, running: true }
  )

  // rule 4
  eq("idle is reply, on the latest content message", state(), { state: "reply", current: "u3", running: false })
  eq(
    "a finished turn's reply",
    voiceViewState({ ...feedFacts(ITEMS.slice(0, 5)), status: "idle" }),
    { state: "reply", current: "a3", running: false }
  )
  eq("error is reply too", state({ status: "error" }).state, "reply")
  eq(
    "reply prefers the persisted message over a lingering bubble",
    state({ streamingId: "stream:m9" }).current,
    "u3"
  )
  eq(
    "reply falls back to a lingering bubble on an otherwise empty feed",
    voiceViewState({ status: "idle", streamingId: "stream:m9" }).current,
    "stream:m9"
  )
  eq("an empty session", voiceViewState({ status: "idle" }), { state: "reply", current: null, running: false })
  eq("no inputs at all does not throw", voiceViewState().state, "reply")
}

// ======================================================================
console.log("\n3. the pager row")
{
  const seq = facts(ITEMS).contentIds

  eq("live at the end: n of N, prev only", pagerView({ state: "reply", current: "u3", seq }), {
    visible: true,
    position: 6,
    total: 6,
    canPrev: true,
    canNext: false,
    showLive: false,
  })
  eq("paging in the middle: both ways, plus Live", pagerView({ state: "paging", current: "u2", seq }), {
    visible: true,
    position: 3,
    total: 6,
    canPrev: true,
    canNext: true,
    showLive: true,
  })
  ok("hidden while dictating", pagerView({ state: "dictating", current: null, seq }).visible === false)
  ok(
    "hidden while dictating even if a current were passed",
    pagerView({ state: "dictating", current: "u3", seq }).visible === false
  )
  ok("hidden with no message to count", pagerView({ state: "reply", current: null, seq: [] }).visible === false)
  ok("hidden when suppressed (no state)", pagerView({ state: null, current: "u3", seq }).visible === false)
  ok("Live only while paging", pagerView({ state: "working", current: "u3", seq }).showLive === false)

  const oldest = { state: "paging", current: "u1", seq }
  ok("prev at the oldest loaded with nothing older: disabled", pagerView(oldest).canPrev === false)
  ok("prev at the oldest loaded with OLDER on the server: enabled", pagerView({ ...oldest, hasMore: true }).canPrev === true)
  ok(
    "...but not while a load is already in flight",
    pagerView({ ...oldest, hasMore: true, loading: true }).canPrev === false
  )

  eq("label: the agent, live", pagerLabel({ role: "assistant", position: 14, total: 14 }), "Agent · 14 of 14")
  eq(
    "label: you, with the time",
    pagerLabel({ role: "user", time: "9:58 AM", position: 11, total: 15 }),
    "You, 9:58 AM · 11 of 15"
  )
  eq("label: nothing to say", pagerLabel({}), "")
}

// ======================================================================
console.log("\n4. stepping")
{
  const seq = facts(ITEMS).contentIds
  const live = "u3"

  eq("prev from live freezes one back", stepPager({ direction: "prev", current: "u3", seq, live }), {
    paging: "a3",
    loadOlder: false,
    pendingFrom: null,
  })
  eq("prev again", stepPager({ direction: "prev", current: "a3", paging: "a3", seq, live }).paging, "a2")
  eq("next steps forward while paging", stepPager({ direction: "next", current: "a2", paging: "a2", seq, live }).paging, "a3")
  eq(
    "next ONTO what live shows is live (null), not a frozen copy of it",
    stepPager({ direction: "next", current: "a3", paging: "a3", seq, live }).paging,
    null
  )
  eq(
    "next at the end changes nothing",
    stepPager({ direction: "next", current: "u3", paging: null, seq, live }),
    { paging: null, loadOlder: false, pendingFrom: null }
  )
  eq(
    "prev at the oldest with nothing older changes nothing",
    stepPager({ direction: "prev", current: "u1", paging: "u1", seq, live }),
    { paging: "u1", loadOlder: false, pendingFrom: null }
  )
  eq(
    "prev at the oldest WITH older: freeze there, load, remember where from",
    stepPager({ direction: "prev", current: "u1", paging: "u1", seq, live, hasMore: true }),
    { paging: "u1", loadOlder: true, pendingFrom: "u1" }
  )
  eq(
    "prev at the oldest LIVE message (a one-message window) freezes it too",
    stepPager({ direction: "prev", current: "u3", seq: ["u3"], live: "u3", hasMore: true }),
    { paging: "u3", loadOlder: true, pendingFrom: "u3" }
  )
  eq(
    "...not while a load is in flight",
    stepPager({ direction: "prev", current: "u1", paging: "u1", seq, live, hasMore: true, loading: true }).loadOlder,
    false
  )
  eq(
    "stepping from the stream bubble back into persisted messages",
    stepPager({ direction: "prev", current: "stream:m9", seq: [...seq, "stream:m9"], live: "stream:m9" }).paging,
    "u3"
  )
  eq(
    "no current message: nothing to step from",
    stepPager({ direction: "prev", current: null, seq, live: null }),
    { paging: null, loadOlder: false, pendingFrom: null }
  )
  eq("an unknown direction is ignored", stepPager({ direction: "up", current: "u3", seq, live }).paging, null)
}

// ======================================================================
console.log("\n5. load-older stepping")
{
  // Before: [u1 a1 ...]; pending from u1. After the load: [u0 a0 u1 a1 ...].
  const before = ["u1", "a1", "u2"]
  const after = ["u0", "a0", "u1", "a1", "u2"]

  eq("still loading: wait", resolvePendingStep({ pendingFrom: "u1", seq: before, hasMore: true, loading: true }), {
    pending: "u1",
    paging: undefined,
    loadOlder: false,
  })
  eq("landed: step onto what is now before it", resolvePendingStep({ pendingFrom: "u1", seq: after, hasMore: true }), {
    pending: null,
    paging: "a0",
    loadOlder: false,
  })
  eq(
    "a page with no content (all tool calls): fetch the next one too",
    resolvePendingStep({ pendingFrom: "u1", seq: before, hasMore: true }),
    { pending: "u1", paging: undefined, loadOlder: true }
  )
  eq(
    "nothing older and none left: done, the screen stays put",
    resolvePendingStep({ pendingFrom: "u1", seq: before, hasMore: false }),
    { pending: null, paging: undefined, loadOlder: false }
  )
  eq(
    "the anchor vanished: give up quietly",
    resolvePendingStep({ pendingFrom: "gone", seq: after, hasMore: true }),
    { pending: null, paging: undefined, loadOlder: false }
  )
  eq("nothing pending: nothing to do", resolvePendingStep({ seq: after }).pending, null)

  // The whole loop, end to end: prev at the oldest, load, land.
  const live = "u2"
  const s1 = stepPager({ direction: "prev", current: "u1", paging: "u1", seq: before, live, hasMore: true })
  ok("step 1 asks for a load", s1.loadOlder && s1.pendingFrom === "u1")
  const v1 = voiceViewState({ ...feedFacts(before.map((id) => ({ id, role: id[0] === "u" ? "user" : "assistant" }))), paging: s1.paging })
  eq("...and the screen holds still on u1 meanwhile", v1.current, "u1")
  const s2 = resolvePendingStep({ pendingFrom: s1.pendingFrom, seq: after, hasMore: true })
  eq("step 2 lands one before u1", s2.paging, "a0")
}

// ======================================================================
console.log("\n6. returning to live (D6)")
{
  eq("Live", pagingAfter("a1", "live"), null)
  eq("starting to talk (VAD onset)", pagingAfter("a1", "speech-start"), null)
  eq("a send went through (clear-prompt)", pagingAfter("a1", "clear-prompt"), null)
  eq("the draft becoming busy", pagingAfter("a1", "draft", { wasBusy: false, busy: true }), null)
  eq("editing a draft that was already busy does not", pagingAfter("a1", "draft", { wasBusy: true, busy: true }), "a1")
  eq("emptying the draft does not", pagingAfter("a1", "draft", { wasBusy: true, busy: false }), "a1")
  eq("an empty input event does not", pagingAfter("a1", "draft", { wasBusy: false, busy: false }), "a1")
  eq("a reply arriving does NOT (it is not a trigger)", pagingAfter("a1", "feed"), "a1")
  eq("TTS state does not", pagingAfter("a1", "tts-state"), "a1")
  eq("already live stays live", pagingAfter(null, "feed"), null)
}

// ======================================================================
console.log("\n7. the elapsed clock")
{
  ok("ticks while working", clockRunning({ state: "working", running: true }))
  ok("ticks under the agent strip while dictating mid-turn", clockRunning({ state: "dictating", running: true }))
  ok("not while dictating with the agent idle", !clockRunning({ state: "dictating", running: false }))
  ok("not on a reply", !clockRunning({ state: "reply", running: false }))
  ok("not while paging back mid-turn (no clock on screen)", !clockRunning({ state: "paging", running: true }))
  ok("not when suppressed", !clockRunning({ state: null, running: true }))

  eq("0", formatElapsed(0), "0:00")
  eq("seconds", formatElapsed(42_000), "0:42")
  eq("minutes", formatElapsed(72_500), "1:12")
  eq("past an hour", formatElapsed(3_723_000), "1:02:03")
  eq("a clock skewed ahead of the server does not go negative", formatElapsed(-3000), "0:00")
  eq("garbage reads as zero", formatElapsed("soon"), "0:00")
}

// ======================================================================
console.log("\n8. the single-message stylesheet")
{
  eq("a persisted message is addressed by its marker", currentSelector("abc-123"), '[data-voice-msg="abc-123"]')
  eq("the live bubble by its stream id", currentSelector("stream:msg_01"), '[data-assistant-stream="msg_01"]')
  eq("no current, no selector", currentSelector(null), null)
  eq("a quote cannot break out of the string", currentSelector('a"]{}b'), '[data-voice-msg="a\\"]{}b"]')

  const css = currentStyleText("abc-123")
  ok("scoped to the voice-view media query", css.startsWith("@media (max-width: 767px)"))
  ok(
    "scoped to the voice-view <html> attributes and this page's feed",
    css.includes("html[data-voice-view][data-voice-layout] #message-feed")
  )
  ok("hides every feed item not holding the current one", css.includes(':not(:has([data-voice-msg="abc-123"]))'))
  ok("hides the siblings inside the one that does", css.includes('> :not([data-voice-msg="abc-123"])'))
  ok("hides everything when there is no current", currentStyleText(null).includes("#message-feed > * { display: none"))
}

// ======================================================================
console.log("\n9. the hook consults these rules (source check)")
{
  const src = readFileSync(join(HERE, "voice_view_hook.js"), "utf8")
  ok("imports the rules from voice_view.js", /from\s+["']\.\/voice_view(\.js)?["']/.test(src))
  ok("decides through voiceViewState", src.includes("voiceViewState("))
  ok("steps through stepPager", src.includes("stepPager("))
  ok("resolves load-older steps through resolvePendingStep", src.includes("resolvePendingStep("))
  ok("pushes the EXISTING load_older_messages event", src.includes('"load_older_messages"'))
  for (const ev of ["orca:voice-speech-start", "phx:clear-prompt", "orca:assistant-stream", "orca:tts-state", "phx:update"]) {
    ok(`listens for ${ev}`, src.includes(`"${ev}"`))
  }
  ok("returns to live through pagingAfter", src.includes("pagingAfter("))
  ok("sets the page layout through W1's setVoiceLayout", src.includes('setVoiceLayout("session"'))
  ok("clears it again", src.includes("setVoiceLayout(null"))
  ok("publishes html[data-voice-state]", src.includes("voiceState"))
  ok("publishes html[data-voice-current]", src.includes("voiceCurrent"))
  ok("reads the server's #voice-view[data-turn-running]", src.includes("dataset.turnRunning"))
  ok("passes it to the rules as `running`", /running:\s*page\.running/.test(src))
}

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
