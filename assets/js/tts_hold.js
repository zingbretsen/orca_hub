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
 *    manually playable and silent.
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

/* The composer just reported a successful send (`phx:clear-prompt`). Does the
 * reply we are sitting on start speaking, or keep waiting for a press?
 *
 * `draftBusy` is re-evaluated by the caller AFTER the send has actually
 * emptied the box, because a send that leaves text behind (he kept typing
 * while it was in flight) is not the "I'm just waiting to hear a result back"
 * case at all. */
export function holdReleaseAction({ held, now, draftBusy, maxAgeMs = TTS_HOLD_MAX_AGE_MS } = {}) {
  if (!held || !held.id) return "hold"
  if (draftBusy) return "hold"
  if (typeof held.at !== "number") return "hold"
  if (now - held.at > maxAgeMs) return "hold"
  return "play"
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
