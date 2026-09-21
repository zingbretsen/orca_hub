// Standalone checks for the AUTOPLAY HOLD (ORCAHUB3-113 items 6 + 7).
// The repo has no JS test runner, so this is a plain node script — same
// convention as tts_stream.check.mjs / assistant_stream.check.mjs:
//
//     node assets/js/tts_hold.check.mjs
//
// Exits non-zero on the first broken expectation, and is gated by the ExUnit
// suite through test/orca_hub_web/tts_hold_check_test.exs so nobody has to
// remember to run it.
//
// WHAT THIS CAN AND CANNOT PROVE. It drives the REAL `tts_hold.js` — the
// shipped rules, not a copy — so every decision below is the production code
// path. What it CANNOT answer is whether the microphone actually stays with
// the user: a hold that never starts playback never emits
// `orca:tts-state {playing: true}`, so the mute and ORCAHUB3-105's release
// never run — but "the speaker/route came back" and "the dictation was not
// cut off" are device claims, and neither node nor headless Chrome has an
// audio route to lose. Those need Zach's phone. Nothing here is evidence for
// them.
//
// The sibling half of the feature — that app.js CONSULTS these rules at both
// autoplay entry points — is not reachable from node (app.js imports phoenix,
// the live socket and colocated hooks). It is pinned instead by a source
// assertion at the bottom: cheap, honest about what it is, and it catches the
// one regression that would silently undo the whole thing (an autoplay path
// added later that forgets to ask).

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

import {
  draftIsBusy,
  holdReleaseAction,
  ttsBarState,
  TTS_HOLD_MAX_AGE_MS,
} from "./tts_hold.js"

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

// ------------------------------------------------------------ a fake page
//
// Only what `draftIsBusy` touches: two selectors, a `.value`, and a class
// list. Deliberately NOT jsdom — the rule is three lines of querySelector and
// a pulled-in DOM would be testing jsdom's CSS engine, not ours.

function fakePage({ composer = null, barDraft = null, barHidden = true } = {}) {
  const composerEl = composer === null ? null : { value: composer }
  const form = composerEl ? { querySelector: () => composerEl } : null
  const boxEl =
    barDraft === null
      ? null
      : { value: barDraft, classList: { contains: (c) => c === "hidden" && barHidden } }

  return {
    querySelector(sel) {
      if (sel === "form[data-voice-composer-for]") return form
      if (sel === "[data-voice-bar-draft]") return boxEl
      return null
    },
  }
}

// ======================================================================
console.log("\n1. what counts as composing (decision 3)")
{
  ok("no composer and no bar box is not busy", draftIsBusy(fakePage()) === false)
  ok("an empty composer is not busy", draftIsBusy(fakePage({ composer: "" })) === false)
  ok(
    "a whitespace-only composer is NOT busy",
    draftIsBusy(fakePage({ composer: "   \n\t  " })) === false
  )
  ok("real text is busy", draftIsBusy(fakePage({ composer: "what about the" })) === true)
  ok(
    "one non-space character is enough",
    draftIsBusy(fakePage({ composer: "?" })) === true
  )
  ok(
    "focus is not consulted — nothing in the page says which element is focused",
    draftIsBusy(fakePage({ composer: "mid-thought" })) === true
  )
  ok("a non-document argument is not busy", draftIsBusy(null) === false)
  ok("an object with no querySelector is not busy", draftIsBusy({}) === false)
}

// ======================================================================
console.log("\n2. the bar's own draft box is the sink only while visible")
{
  ok(
    "a VISIBLE bar box with text is busy (no composer on this page)",
    draftIsBusy(fakePage({ barDraft: "dictating on /queue", barHidden: false })) === true
  )
  ok(
    "a HIDDEN bar box is not the sink, so its stale text holds nothing",
    draftIsBusy(fakePage({ barDraft: "stale", barHidden: true })) === false
  )
  ok(
    "a visible but whitespace-only bar box is not busy",
    draftIsBusy(fakePage({ barDraft: "  ", barHidden: false })) === false
  )
  ok(
    "the composer outranks nothing — either sink holding text is enough",
    draftIsBusy(fakePage({ composer: "", barDraft: "typed here", barHidden: false })) === true
  )
}

// ======================================================================
console.log("\n3. when a held reply starts by itself (decision 2)")
{
  const now = 1_000_000
  const fresh = { id: "m1", at: now - 5_000 }
  const stale = { id: "m1", at: now - (TTS_HOLD_MAX_AGE_MS + 1) }

  eq(
    "a recent hold + a send that emptied the box PLAYS",
    holdReleaseAction({ held: fresh, now, draftBusy: false }),
    "play"
  )
  eq(
    "a send that left text behind keeps holding (he kept typing)",
    holdReleaseAction({ held: fresh, now, draftBusy: true }),
    "hold"
  )
  eq(
    "a STALE hold does not speak on a send — it stays manually playable",
    holdReleaseAction({ held: stale, now, draftBusy: false }),
    "hold"
  )
  eq(
    "exactly at the boundary still plays (the cutoff is strictly greater)",
    holdReleaseAction({ held: { id: "m1", at: now - TTS_HOLD_MAX_AGE_MS }, now, draftBusy: false }),
    "play"
  )
  eq("nothing held, nothing to do", holdReleaseAction({ held: null, now, draftBusy: false }), "hold")
  eq(
    "a hold with no id is not a hold",
    holdReleaseAction({ held: { at: now }, now, draftBusy: false }),
    "hold"
  )
  eq(
    "a hold with no timestamp cannot be aged, so it does not auto-play",
    holdReleaseAction({ held: { id: "m1" }, now, draftBusy: false }),
    "hold"
  )
  eq("called with nothing at all", holdReleaseAction(), "hold")
  eq(
    "the window is overridable (the caller owns the clock)",
    holdReleaseAction({ held: { id: "m1", at: now - 50 }, now, draftBusy: false, maxAgeMs: 10 }),
    "hold"
  )
}

// ======================================================================
console.log("\n4. what the user sees (decision 1)")
{
  const idle = ttsBarState({ playing: false, queued: 0, held: null })
  ok("nothing playing and nothing held hides the transport", idle.visible === false)
  eq("idle mode", idle.mode, "idle")

  const playing = ttsBarState({ playing: true, queued: 3, held: null })
  ok("playing is visible", playing.visible === true)
  eq("playing shows a pause control", playing.icon, "pause")
  eq("playing says so", playing.label, "Playing")

  const paused = ttsBarState({ playing: false, queued: 3, held: null })
  eq("a queue with playback stopped is paused", paused.mode, "paused")
  eq("paused offers play", paused.icon, "play")

  const held = ttsBarState({ playing: false, queued: 0, held: { id: "m1", at: 1 } })
  ok("a held reply is VISIBLE — a silent hold is the failure mode", held.visible === true)
  eq("held mode", held.mode, "held")
  eq("held wording", held.label, "Reply ready")
  eq("held offers play", held.icon, "play")
  ok("held is called out visually", held.warn === true)
  ok(
    "held explains itself in the tooltip",
    /held while you are writing/i.test(held.toggleTitle) && /tap to hear it now/i.test(held.toggleTitle)
  )
  ok(
    "held's stop dismisses rather than stopping something that never started",
    /dismiss/i.test(held.stopTitle)
  )

  ok(
    "live playback outranks a held reply",
    ttsBarState({ playing: true, queued: 2, held: { id: "m1", at: 1 } }).mode === "playing"
  )
  ok(
    "a paused queue outranks a held reply",
    ttsBarState({ playing: false, queued: 2, held: { id: "m1", at: 1 } }).mode === "paused"
  )
  ok("a held entry with no id is not a hold", ttsBarState({ held: { at: 1 } }).visible === false)
  eq("called with nothing at all", ttsBarState().mode, "idle")
}

// ======================================================================
console.log("\n5. app.js asks — both autoplay entry points, and only those")
{
  const app = readFileSync(join(HERE, "app.js"), "utf8")

  ok(
    "the autoplay push consults the hold",
    /handleEvent\("tts-autoplay"[\s\S]{0,400}?ttsDraftBusy\(\)[\s\S]{0,80}?ttsHoldAutoplay/.test(app)
  )
  ok(
    "the streaming takeover consults it too and suppresses that stream",
    /ttsStreamActiveId !== streamId[\s\S]{0,900}?ttsDraftBusy\(\)[\s\S]{0,200}?ttsStreamSuppressed\.add/.test(
      app
    )
  )
  ok(
    "MANUAL play does not consult it — ttsStart never asks (item 5)",
    !/ttsStart\(id\)\s*\{[\s\S]{0,1200}?ttsDraftBusy/.test(app)
  )
  ok(
    "ttsStart clears a hold rather than leaving it advertised",
    /ttsStart\(id\)\s*\{[\s\S]{0,1600}?this\.ttsHeld = null/.test(app)
  )
  ok(
    "the hold itself never emits orca:tts-state, so no mute/release runs",
    /ttsHoldAutoplay\(id\)\s*\{[\s\S]{0,300}?\},/.test(app) &&
      !/ttsHoldAutoplay\(id\)\s*\{[\s\S]{0,300}?ttsEmitState/.test(app)
  )
  ok(
    "a send is the release signal, via the composer's own clear-prompt push",
    /addEventListener\("phx:clear-prompt", this\._onComposerSent\)/.test(app)
  )
  ok(
    "the rules are imported, not re-implemented here",
    /from "\.\/tts_hold"/.test(app)
  )
  // The bar is sticky against NAVIGATION, not socket loss (ORCAHUB3-91) — it
  // re-mounts and rebuilds the transport idle, underneath audio that is
  // still playing. Both hosts of TTSMethods have to re-assert it.
  ok(
    "ScrollToBottom re-asserts the transport after a reconnect",
    /assistantStreamReconnected\(\)\s*\n\s*this\.ttsHoldReconnected\(\)/.test(app)
  )
  ok(
    "TTSFeed does too",
    /TTSFeed:\s*\{[\s\S]{0,400}?reconnected\(\)\s*\{\s*this\.ttsHoldReconnected\(\)/.test(app)
  )
}

// ======================================================================
console.log("\n6. the bar markup the renderer writes into actually exists")
{
  const bar = readFileSync(
    join(HERE, "..", "..", "lib", "orca_hub_web", "live", "voice_bar_live.ex"),
    "utf8"
  )

  ok("the transport is in the voice bar", /data-tts-bar\b/.test(bar))
  ok("it has the toggle the renderer targets", /data-tts-bar-action="toggle"/.test(bar))
  ok("it has the stop the renderer targets", /data-tts-bar-action="stop"/.test(bar))
  ok("it has the label the renderer writes", /data-tts-bar-label/.test(bar))
  ok(
    "it is hook-owned, so a bar re-render cannot put the idle markup back",
    /id="voice-tts-transport"\s+phx-update="ignore"/.test(bar)
  )
  ok(
    "it is NOT gated on voice mode — a pause must be reachable with the mic off",
    !/:if=\{@voice_on\}[\s\S]{0,200}?data-tts-bar\b/.test(bar)
  )
}

// ======================================================================
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
