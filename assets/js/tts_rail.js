/* The voice view's READ-ALOUD RAIL and HELD STRIP, plus TAP-TO-JUMP
 * (ORCAHUB3-113 phase C, W3) — the pure half, kept out of app.js so a node
 * script can drive it. `assets/js/tts_rail.check.mjs` imports THIS module,
 * not a copy of it, and the suite gates it via `OrcaHubWeb.TtsRailCheckTest`.
 *
 * In the phone's full-screen voice view the session page draws two EMPTY
 * `phx-update="ignore"` containers, `#voice-rail` and `#voice-held`, and
 * TTSMethods (app.js) writes these into them. Same split as `tts_hold.js`:
 * every DECISION is here, every DOM write is there.
 *
 * 1. `ttsRailState` — what the rail shows. While a message is queued it is a
 *    transport ("Sentence n of N", a segmented progress bar, prev, a big
 *    Pause/Play, next, stop) for WHATEVER is being read, which is not
 *    necessarily the message on screen: paging back while a reply reads
 *    must not lose the pause. With nothing queued it offers ONE thing, a big
 *    Play that reads the message on screen, and only in the two page states
 *    where a message is on screen to read (`reply`, `paging`). A state with
 *    no controls has no footer (D9), so everything else is hidden.
 *
 * 2. `railSegments` — the progress bar, CAPPED. One segment per sentence is
 *    the mockup, and it is right for a five-sentence reply; a 120-sentence
 *    report would draw 120 hairlines. Past the cap a segment stands for a
 *    run of sentences.
 *
 * 3. `heldStripState` — the voice view's copy of the bar's "Reply ready"
 *    (tts_hold.js decision 3: a hold is never silent). Same `ttsHeld`, same
 *    play-it/dismiss-it semantics, voice-view wording.
 *
 * 4. `tapJumpTarget`, `caretAt`, `chunkIndexAt` — TAP-TO-JUMP. A tap inside
 *    the message text plays from the sentence under the finger. The chunk
 *    ranges are DOM ranges (tts_text.js `resolveChunkRange`), so the one
 *    browser-only step — "is this caret before, inside or after this range"
 *    — is passed in as a function and everything around it is checked here.
 */

/* More than this many sentences and a segment stands for several. 24 keeps
 * every segment at least ~10 px wide on a 390 px phone with the 3 px gaps
 * the mockup uses — still a tappable-looking bar rather than a texture. */
export const RAIL_MAX_SEGMENTS = 24

/* The page states (W2's `html[data-voice-state]`) in which a message is on
 * screen and nothing about it is still being written. `working` is excluded
 * on purpose: its current message is the turn in progress, which the
 * streaming producer reads (or the end-of-turn autoplay will), and a Play
 * here would race both. `dictating` has no message on screen at all. */
const READABLE_PAGE_STATES = new Set(["reply", "paging"])

export const HELD_STRIP_LABEL = "Reply ready, held while you talk"

/* One entry per segment, each "done" | "on" | "todo".
 *
 * Segment j covers sentences [floor(j*N/S), floor((j+1)*N/S)) — an even
 * split that never leaves an empty segment (S <= N) and puts every sentence
 * in exactly one. A segment is "on" while it holds the current sentence, so
 * a capped bar still moves exactly once per run of sentences, never skips,
 * and the last sentence always lights the last segment. */
export function railSegments(total, current, cap = RAIL_MAX_SEGMENTS) {
  const n = Number.isInteger(total) && total > 0 ? total : 0
  if (n === 0) return []
  const size = Math.max(1, Math.min(n, Number.isInteger(cap) && cap > 0 ? cap : RAIL_MAX_SEGMENTS))
  const at = Math.min(Math.max(Number.isInteger(current) ? current : 0, 0), n - 1)

  const out = []
  for (let j = 0; j < size; j++) {
    const start = Math.floor((j * n) / size)
    const end = Math.floor(((j + 1) * n) / size)
    out.push(at >= end ? "done" : at >= start ? "on" : "todo")
  }
  return out
}

/* What the rail shows.
 *
 * `queued`/`currentIndex`/`playing` are the player's own (`chunks.length`,
 * `currentIndex`, `playing`); `pageState`/`currentId` are W2's
 * `html[data-voice-state]`/`[data-voice-current]`; `currentReadable` says
 * the current message actually has text and a footer to read from (a user
 * message, or an assistant message that is all code, has neither).
 *
 * `held` only matters in the `ready` case: when the reply on screen IS the
 * held one, the held strip already offers exactly this Play, and two buttons
 * doing one thing is noise. Paging to a different message brings the rail's
 * Play back, because then it reads something else. */
export function ttsRailState({
  playing = false,
  queued = 0,
  currentIndex = 0,
  pageState = null,
  currentId = null,
  currentReadable = false,
  held = null,
} = {}) {
  if (queued > 0) {
    const at = Math.min(Math.max(currentIndex, 0), queued - 1)
    return {
      visible: true,
      mode: playing ? "playing" : "paused",
      label: `Sentence ${at + 1} of ${queued}`,
      segments: railSegments(queued, at),
      transport: true,
      prevEnabled: at > 0,
      // At the last sentence "next" ends the read, exactly as the footer's
      // and the bar's do — and a streamed reply may still be growing.
      nextEnabled: true,
      icon: playing ? "pause" : "play",
      // Amber while reading, as in the mockup: the mic is paused under it
      // (half-duplex), and the mockup's "Mic paused" pill is the same tone.
      tone: playing ? "warning" : "primary",
      toggleLabel: playing ? "Pause" : "Play",
      toggleTitle: playing ? "Pause reading" : "Resume reading",
      readId: null,
    }
  }

  const heldHere = !!(held && held.id && held.id === currentId)
  if (READABLE_PAGE_STATES.has(pageState) && currentId && currentReadable && !heldHere) {
    return {
      visible: true,
      mode: "ready",
      label: "",
      segments: [],
      transport: false,
      prevEnabled: false,
      nextEnabled: false,
      icon: "play",
      tone: "primary",
      toggleLabel: "Play",
      toggleTitle: "Read this message aloud",
      readId: currentId,
    }
  }

  return {
    visible: false,
    mode: "hidden",
    label: "",
    segments: [],
    transport: false,
    prevEnabled: false,
    nextEnabled: false,
    icon: "play",
    tone: "primary",
    toggleLabel: "",
    toggleTitle: "",
    readId: null,
  }
}

/* The voice view's held strip. Visible whenever there is a hold, whatever
 * else is going on: a reply held while something ELSE is playing (a manual
 * read of an older message, with a draft open) is still a reply nobody has
 * heard, and the bar's own precedence (playing > held) would hide it. */
export function heldStripState({ held = null } = {}) {
  if (!held || !held.id) return { visible: false, label: "", heldId: null }
  return { visible: true, label: HELD_STRIP_LABEL, heldId: held.id }
}

/* Elements a tap must keep for themselves: a link still follows, a button
 * still presses, a `<details>` summary still toggles. The message bubble is
 * rendered markdown, so links are the common case. */
export const TAP_IGNORE_SELECTOR =
  "a, button, input, textarea, select, summary, label, [role='button'], [contenteditable], [data-tts-action]"

/* Which message, if any, a click inside the feed asks to jump within.
 * Returns the message's TTS id (the `<id>` of `#tts-text-<id>`) or null.
 *
 * Only in the voice view — on a normal page a click on message text is a
 * click on text, and starting a voice would be a startle. Never while text
 * is SELECTED: a long-press to copy ends in a click on mobile too. */
export function tapJumpTarget({ target, viewShowing = false, selectionCollapsed = true } = {}) {
  if (!viewShowing || !selectionCollapsed) return null
  if (!target || typeof target.closest !== "function") return null
  if (target.closest(TAP_IGNORE_SELECTOR)) return null

  const bubble = target.closest("[data-tts-text]")
  const id = bubble && typeof bubble.id === "string" ? bubble.id : ""
  return id.startsWith("tts-text-") && id.length > "tts-text-".length
    ? id.slice("tts-text-".length)
    : null
}

/* The text position under a point, as `{node, offset}`, from whichever of
 * the two APIs the browser has: the standard `caretPositionFromPoint`
 * (Firefox, Chrome 128+) or WebKit's `caretRangeFromPoint` (Safari, older
 * Chrome). Both exist in the wild on phones, so both are tried, standard
 * first. Null when neither exists or the point is over nothing. */
export function caretAt(doc, x, y) {
  if (!doc || !Number.isFinite(x) || !Number.isFinite(y)) return null

  if (typeof doc.caretPositionFromPoint === "function") {
    const pos = doc.caretPositionFromPoint(x, y)
    if (pos && pos.offsetNode) return { node: pos.offsetNode, offset: pos.offset }
  }
  if (typeof doc.caretRangeFromPoint === "function") {
    const range = doc.caretRangeFromPoint(x, y)
    if (range && range.startContainer) return { node: range.startContainer, offset: range.startOffset }
  }
  return null
}

/* Which chunk a caret falls in. `ranges` is the player's `chunkRanges` (one
 * entry per chunk, null where a range could not be resolved); `locate(spec)`
 * answers Range.comparePoint's question for the caret against that chunk's
 * range — -1 the caret is BEFORE it, 0 inside, 1 after — or null when the
 * browser could not compare (a detached node; app.js wraps the throw).
 *
 * The rules, in order:
 *   - Inside a chunk -> that chunk. When two chunks share a boundary (no
 *     whitespace between them) a caret ON it is inside both; the LATER one
 *     wins, because a caret there sits at that sentence's first character.
 *   - In a gap -> the next chunk after it. Gaps are the whitespace between
 *     sentences and, more to the point, fenced code blocks, which are never
 *     read (tts_text.js drops `<pre>`): tapping one plays from the prose
 *     that follows it.
 *   - After every chunk -> the last one. A tap below the final sentence is
 *     still a tap on this message.
 *   - Nothing comparable at all -> -1, and the caller does nothing.
 */
export function chunkIndexAt(ranges, locate) {
  if (!Array.isArray(ranges) || typeof locate !== "function") return -1

  let inside = -1
  let firstAfterCaret = -1
  let lastResolved = -1

  for (let i = 0; i < ranges.length; i++) {
    if (!ranges[i]) continue
    const where = locate(ranges[i])
    if (where !== -1 && where !== 0 && where !== 1) continue
    lastResolved = i
    if (where === 0) inside = i
    else if (where === -1 && firstAfterCaret === -1) firstAfterCaret = i
  }

  if (inside !== -1) return inside
  if (firstAfterCaret !== -1) return firstAfterCaret
  return lastResolved
}

/* Can the player jump within what it already holds, or does the message have
 * to be re-read from its DOM first? A message read AS IT STREAMED (§7.3) has
 * chunks but no ranges — the producer's sentences never had DOM positions —
 * and even once re-keyed onto the persisted bubble its chunking is the
 * accumulator's, not tts_text's, so there is nothing to map a tap onto. */
export function hasJumpRanges(chunks, chunkRanges) {
  return (
    Array.isArray(chunks) &&
    Array.isArray(chunkRanges) &&
    chunks.length > 0 &&
    chunkRanges.length === chunks.length &&
    chunkRanges.some(Boolean)
  )
}

// ----------------------------------------------------------------- markup
//
// The two skeletons TTSMethods writes ONCE into the empty containers, then
// updates in place (text, classes, disabled) — never re-`innerHTML`s on a
// sentence advance, because swapping the buttons out from under a finger
// that is mid-tap loses the tap. Here rather than in app.js so the check
// can pin the `data-` hooks the renderer looks up; the classes are
// Tailwind's, and `assets/js` is an `@source`, so they compile.

const ICON_PREV = `<svg viewBox="0 0 24 24" class="size-6" fill="currentColor" aria-hidden="true"><path d="M6 6h2v12H6zm3.5 6l8.5 6V6z"/></svg>`
const ICON_NEXT = `<svg viewBox="0 0 24 24" class="size-6" fill="currentColor" aria-hidden="true"><path d="M16 6h2v12h-2zM6 18l8.5-6L6 6z"/></svg>`
const ICON_STOP = `<svg viewBox="0 0 24 24" class="size-6" fill="currentColor" aria-hidden="true"><path d="M6 6h12v12H6z"/></svg>`
const ICON_CLOSE = `<svg viewBox="0 0 24 24" class="size-4" fill="currentColor" aria-hidden="true"><path d="M18.3 5.7L12 12l6.3 6.3-1.4 1.4L10.6 13.4 4.3 19.7 2.9 18.3 9.2 12 2.9 5.7 4.3 4.3l6.3 6.3 6.3-6.3z"/></svg>`
export const RAIL_ICON_PLAY = `<svg viewBox="0 0 24 24" class="size-7" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg>`
export const RAIL_ICON_PAUSE = `<svg viewBox="0 0 24 24" class="size-7" fill="currentColor" aria-hidden="true"><path d="M6 5h4v14H6zm8 0h4v14h-4z"/></svg>`

const SIDE_BTN = "btn btn-circle size-14 min-h-0 shrink-0 border-0 bg-base-300"

export const RAIL_MARKUP = `<div data-tts-rail class="hidden flex-col gap-3 border-t border-base-300 bg-base-200 px-3 pt-3 pb-4">
  <div data-tts-rail-progress class="flex flex-col gap-2">
    <span data-tts-rail-label class="text-xs opacity-70 tabular-nums"></span>
    <div data-tts-rail-segments class="flex h-1 gap-[3px]"></div>
  </div>
  <div class="flex items-center gap-2.5">
    <button type="button" data-tts-rail-action="prev" class="${SIDE_BTN}" title="Previous sentence" aria-label="Previous sentence">${ICON_PREV}</button>
    <button type="button" data-tts-rail-action="toggle" class="btn h-[72px] min-h-0 flex-1 gap-2.5 rounded-2xl border-0 text-xl font-bold">
      <span data-tts-rail-icon></span><span data-tts-rail-toggle-label></span>
    </button>
    <button type="button" data-tts-rail-action="next" class="${SIDE_BTN}" title="Next sentence" aria-label="Next sentence">${ICON_NEXT}</button>
    <button type="button" data-tts-rail-action="stop" class="${SIDE_BTN}" title="Stop reading" aria-label="Stop reading">${ICON_STOP}</button>
  </div>
</div>`

export const HELD_MARKUP = `<div data-tts-held class="hidden items-center gap-2 rounded-xl border border-warning/45 bg-warning/10 px-2.5 py-1.5 text-sm text-warning">
  <span data-tts-held-label class="min-w-0 flex-1"></span>
  <button type="button" data-tts-held-action="play" class="btn btn-warning btn-sm" title="Read this reply now" aria-label="Read this reply now">Play</button>
  <button type="button" data-tts-held-action="dismiss" class="btn btn-ghost btn-sm btn-square text-warning" title="Dismiss this reply without reading it" aria-label="Dismiss this reply without reading it">${ICON_CLOSE}</button>
</div>`

/* The classes a segment carries for each state — the mockup's three
 * shades: unread track, read (dimmed accent), current (full accent). */
export const SEGMENT_CLASS = {
  done: "flex-1 rounded-sm bg-primary/45",
  on: "flex-1 rounded-sm bg-primary",
  todo: "flex-1 rounded-sm bg-base-300",
}
