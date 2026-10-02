/* The AUTOPLAY HOLD (ORCAHUB3-113 items 6 + 7) — three pure rules, kept out
 * of app.js so they can be driven by a node script rather than a browser.
 * `assets/js/tts_hold.check.mjs` imports THIS module, not a copy of it.
 *
 * The problem, in Zach's words: "If I'm in the middle of talking I don't
 * necessarily want the microphone to get grabbed away from me… if I have
 * something currently being written in the input box, hold off on starting
 * the text-to-speech, which mutes the microphone, until I've actually sent
 * off my thing. If I have fired off a message and I'm just waiting to hear a
 * result back, then sure, play it automatically."
 *
 * So autoplay — and only autoplay — waits while the draft sink holds text.
 * The three decisions that needed pinning, and why they are here:
 *
 * 1. `draftIsBusy` — WHAT COUNTS AS COMPOSING. Whitespace does not, and
 *    FOCUS IS NOT PART OF IT. Dictation writes into the composer textarea
 *    through `_writeDraft` without ever focusing it (voice_mode_spec.md
 *    §8.2), so a focus requirement would miss the one case the issue is
 *    actually about. An unfocused draft is someone mid-thought either way.
 *
 * 2. `holdReleaseAction` — WHEN A HELD REPLY STARTS BY ITSELF. Only on a
 *    SEND, and only a recent one. "The composer became empty" is not enough
 *    of a signal: emptying it by clearing a stale draft ten minutes later
 *    would start a voice out of nowhere, which is the startle this feature
 *    exists to avoid. A send is the half of that transition Zach explicitly
 *    asked to hear ("I've actually sent off my thing"), and `maxAgeMs`
 *    covers the stale-draft-then-send case: past it the reply stays
 *    manually playable and silent. "Past it" is measured from the LAST
 *    DRAFT ACTIVITY, not from the hold (D10, see `draftActivity`): a long
 *    dictation is not a parked draft.
 *
 * 3. `ttsBarState` — WHAT THE USER SEES. A silent hold is a worse failure
 *    than the bug, so a held reply is never invisible: the voice bar says
 *    "Reply ready" and offers the play control. The same control is the
 *    prominent pause/stop for playback that item 6 asks for, which is why
 *    one function covers playing/paused/held rather than two.
 *
 * NOT covered here, deliberately: MANUAL play. Pressing play with a draft
 * open is an explicit instruction and is obeyed — nothing on this path is
 * consulted by `ttsStart`/`ttsHandleAction`.
 */

/* How long a held reply may wait before a send stops being a reason to speak
 * it. Two minutes: long enough to cover "type the rest of the sentence and
 * send", short enough that a draft parked over a coffee break and then sent
 * does not resurrect a reply from before it. */
export const TTS_HOLD_MAX_AGE_MS = 120000

/* Does the draft sink hold something the user is still writing?
 *
 * `doc` is passed in rather than closed over so the check script can drive
 * this against a fake document. The two sinks are §8.2's, in its order: the
 * composer textarea of the page's `form[data-voice-composer-for]` when there
 * is one, else the bar's own `[data-voice-bar-draft]` box. The bar box is
 * counted only while VISIBLE — the hook hides AND clears it whenever a
 * composer is present, and a hidden box's stale text must not hold a reply
 * hostage on a page the user cannot even see it on. */
export function draftIsBusy(doc) {
  if (!doc || typeof doc.querySelector !== "function") return false

  const form = doc.querySelector("form[data-voice-composer-for]")
  const composer = form && typeof form.querySelector === "function"
    ? form.querySelector("textarea")
    : null
  if (composer && hasText(composer.value)) return true

  const box = doc.querySelector("[data-voice-bar-draft]")
  if (box && hasText(box.value) && !isHidden(box)) return true

  return false
}

function hasText(value) {
  return typeof value === "string" && value.trim().length > 0
}

function isHidden(el) {
  return !!(el.classList && typeof el.classList.contains === "function" && el.classList.contains("hidden"))
}

/* A send was confirmed — the composer's `phx:clear-prompt`, or the voice
 * channel's `orca:voice-sent` (which also covers a spoken send from a page
 * with no composer, where nothing ever pushes `clear-prompt`). Does the reply
 * we are sitting on start speaking, or keep waiting for a press?
 *
 * `draftBusy` is re-evaluated by the caller AFTER the send has actually
 * emptied the box, because a send that leaves text behind (he kept typing
 * while it was in flight) is not the "I'm just waiting to hear a result back"
 * case at all.
 *
 * THE CLOCK (ORCAHUB3-113 D10) starts at the LATER of the hold and the last
 * draft activity (`lastDraftAt`, see `draftActivity`), not at the hold alone.
 * The hold exists because he was writing; a reply held two and a half
 * minutes ago behind a message he was dictating the whole time is exactly
 * the "fired off a message, waiting to hear back" case when he finally sends.
 * Measured from the hold, that reply stayed silent. What the window is
 * actually for is the draft that was PARKED — and a parked draft is one with
 * no activity, which this clock still ages out. */
export function holdReleaseAction({
  held,
  now,
  draftBusy,
  maxAgeMs = TTS_HOLD_MAX_AGE_MS,
  lastDraftAt = null,
} = {}) {
  if (!held || !held.id) return "hold"
  if (draftBusy) return "hold"
  if (typeof held.at !== "number") return "hold"
  const since = typeof lastDraftAt === "number" ? Math.max(held.at, lastDraftAt) : held.at
  if (now - since > maxAgeMs) return "hold"
  return "play"
}

/* Selector for the two draft sinks — §8.2's, same as `draftIsBusy` above. */
export const DRAFT_SINK_SELECTOR = "form[data-voice-composer-for] textarea, [data-voice-bar-draft]"

/* Does this `input` event count as DRAFT ACTIVITY for the D10 clock?
 *
 * The caller listens for bubbling `input` on the document, so this sees the
 * user's typing AND the Voice hook's dictation writes (`_writeDraft` follows
 * every write with a bubbling synthetic `input`, §8.2 — talking is writing).
 *
 * Only an event that LEAVES TEXT in a sink counts. The send itself empties
 * the box, and the Voice hook's `"sent"` clear does it with exactly such an
 * event; counting that would stamp "activity" at the moment of every send and
 * quietly defeat the parked-draft window — a draft left for ten minutes and
 * then sent would read as touched a millisecond ago. */
export function draftActivity(target) {
  if (!target || typeof target.matches !== "function") return false
  if (!target.matches(DRAFT_SINK_SELECTOR)) return false
  return hasText(target.value)
}

/* What the voice bar's transport shows. One function for all three states
 * because they share one pair of buttons — the play/pause control and the
 * stop — and because "held" has to be reachable in exactly the same place a
 * user already looks to pause something that IS speaking. */
export function ttsBarState({ playing = false, queued = 0, held = null } = {}) {
  if (playing) {
    return {
      visible: true,
      mode: "playing",
      icon: "pause",
      label: "Playing",
      toggleTitle: "Pause reading",
      stopTitle: "Stop reading",
      warn: false,
    }
  }

  if (queued > 0) {
    return {
      visible: true,
      mode: "paused",
      icon: "play",
      label: "Paused",
      toggleTitle: "Resume reading",
      stopTitle: "Stop reading",
      warn: false,
    }
  }

  if (held && held.id) {
    return {
      visible: true,
      mode: "held",
      icon: "play",
      label: "Reply ready",
      toggleTitle: "Reply ready — held while you are writing. Send, or tap to hear it now.",
      stopTitle: "Dismiss this reply without reading it",
      warn: true,
    }
  }

  return {
    visible: false,
    mode: "idle",
    icon: "play",
    label: "",
    toggleTitle: "",
    stopTitle: "",
    warn: false,
  }
}
