/* The session page's mobile voice view (ORCAHUB3-113 phase C): which ONE
 * message is on screen, and how the pager moves. Pure rules, kept out of the
 * hook so a node script can drive them — `voice_view.check.mjs` imports THIS
 * module, not a copy, and `OrcaHubWeb.VoiceViewCheckTest` gates it.
 *
 * The decisions these encode (the issue's plan is the normative spec):
 *
 *   D3  One message on screen, chosen by state: dictating -> only the draft;
 *       agent working -> its progress; otherwise -> the response.
 *   D4  Prev/next step through CONTENT messages only (user text, assistant
 *       text). Tool calls, results, thinking and system events are not in
 *       the sequence at all — the page only marks content elements
 *       (`data-voice-content`), so they never reach these rules.
 *   D6  Paging back freezes the screen. "Live", starting to talk, or sending
 *       returns to live.
 *   D7  A non-empty draft takes the screen even mid-turn.
 *
 * Everything here is a function of plain values. The hook reads the DOM
 * (content markers, the stream slot, the composer, the feed's has-more
 * flags) and hands the facts in; nothing in this file touches a document.
 */

/* The statuses that mean "the agent is mid-turn". `waiting` is in the set
 * on purpose: a pi dialog overlays a turn still in flight (ORCAHUB3-60), and
 * a Claude AskUserQuestion is a turn paused on the user — neither is a
 * finished reply. (Both also SUPPRESS the view while their tap-answer modal
 * is up, C1; this only matters for the moments around it.) */
export const RUNNING_STATUSES = ["running", "compacting", "waiting"]

export function isRunning(status) {
  return RUNNING_STATUSES.includes(status)
}

/* The four view states, also the values of `html[data-voice-state]`. */
export const VOICE_STATES = ["dictating", "working", "reply", "paging"]

/* Content elements in document order -> the facts the state rules need.
 *
 * `items` is `[{id, role}]`, `role` being the element's
 * `data-voice-content` ("user" | "assistant"). "This turn" is everything
 * after the user's last message: the agent's latest text since you last
 * spoke is what "working" shows, and nothing from an earlier turn may stand
 * in for it — an old reply on screen under a spinner reads as the answer.
 * With no user message loaded at all, the whole window is this turn. */
export function feedFacts(items) {
  const list = Array.isArray(items) ? items.filter((i) => i && i.id) : []
  const contentIds = list.map((i) => String(i.id))

  let lastUserIdx = -1
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i].role === "user") {
      lastUserIdx = i
      break
    }
  }

  let lastAgentIdThisTurn = null
  for (let i = list.length - 1; i > lastUserIdx; i--) {
    if (list[i].role === "assistant") {
      lastAgentIdThisTurn = String(list[i].id)
      break
    }
  }

  return {
    contentIds,
    lastUserId: lastUserIdx >= 0 ? String(list[lastUserIdx].id) : null,
    lastAgentIdThisTurn,
  }
}

/* The pager's sequence: the LOADED content messages, then the live
 * streaming bubble when there is one. The bubble is the newest content on
 * the page while it exists, and it is what "working" shows first, so it has
 * to be a step you can page back FROM. It never duplicates a persisted id
 * (it is keyed `stream:<id>`, the persisted one by its tts id). */
export function pagerSequence(contentIds, streamingKey) {
  const seq = Array.isArray(contentIds) ? contentIds.slice() : []
  if (streamingKey && !seq.includes(streamingKey)) seq.push(streamingKey)
  return seq
}

/* The state rules, in the plan's order. `current` is a sequence key (a
 * persisted tts id, or `stream:<id>` for the live bubble), or null when the
 * screen shows no message at all (dictating, an empty session).
 *
 *   0. suppressed (C1: a tap-answer surface is up)  -> no state at all
 *   1. paging, onto a key still loaded              -> paging, that key
 *   2. the draft holds text                         -> dictating, none
 *   3. the agent is mid-turn                        -> working: the stream,
 *        else this turn's latest assistant text, else your just-sent message
 *   4. otherwise                                    -> reply, the latest
 *
 * A paging key that is no longer loaded (the window moved under it) falls
 * through rather than pinning the screen to nothing; the hook then drops it
 * so it cannot snap back if the element ever re-renders. */
export function voiceViewState({
  draftBusy = false,
  status = null,
  suppressed = false,
  paging = null,
  contentIds = [],
  streamingId = null,
  lastUserId = null,
  lastAgentIdThisTurn = null,
} = {}) {
  const running = isRunning(status)
  if (suppressed) return { state: null, current: null, running }

  const seq = pagerSequence(contentIds, streamingId)

  if (paging && seq.includes(paging)) return { state: "paging", current: paging, running }
  if (draftBusy) return { state: "dictating", current: null, running }

  if (running) {
    return {
      state: "working",
      current: streamingId || lastAgentIdThisTurn || lastUserId || null,
      running,
    }
  }

  const ids = Array.isArray(contentIds) ? contentIds : []
  return { state: "reply", current: ids.length ? ids[ids.length - 1] : streamingId || null, running }
}

/* What the pager row shows. Hidden while dictating (the draft owns the
 * screen) and whenever there is no message to count. `canPrev` is also true
 * at the oldest LOADED message when the server has older ones: the step
 * then goes through `load_older_messages` (see `stepPager`). */
export function pagerView({
  state = null,
  current = null,
  seq = [],
  hasMore = false,
  loading = false,
} = {}) {
  const idx = current ? seq.indexOf(current) : -1
  const visible = state !== null && state !== "dictating" && idx >= 0

  return {
    visible,
    position: idx + 1,
    total: seq.length,
    canPrev: visible && (idx > 0 || (hasMore && !loading)),
    canNext: visible && idx < seq.length - 1,
    showLive: state === "paging",
  }
}

/* One press of prev or next.
 *
 * Returns the new `paging` key (null = live), plus `loadOlder` when the step
 * has to fetch first. A prev at the oldest loaded message FREEZES on it
 * (`paging` = that key, so a reply landing mid-fetch cannot yank the screen
 * away) and records `pendingFrom`; the hook pushes the existing
 * `load_older_messages` and calls `resolvePendingStep` once it has landed.
 *
 * A next that lands on what live would show anyway IS live — stepping
 * forward onto the newest message must not leave you frozen on it while new
 * replies arrive underneath. */
export function stepPager({
  direction,
  current = null,
  paging = null,
  seq = [],
  live = null,
  hasMore = false,
  loading = false,
} = {}) {
  const none = { paging, loadOlder: false, pendingFrom: null }
  const idx = current ? seq.indexOf(current) : -1
  if (idx < 0) return none

  if (direction === "prev") {
    if (idx > 0) return { paging: seq[idx - 1], loadOlder: false, pendingFrom: null }
    if (hasMore && !loading) return { paging: current, loadOlder: true, pendingFrom: current }
    return none
  }

  if (direction === "next") {
    if (idx >= seq.length - 1) return none
    const target = seq[idx + 1]
    return { paging: target === live ? null : target, loadOlder: false, pendingFrom: null }
  }

  return none
}

/* A prev that had to load older messages first: the page has re-rendered,
 * so step to whatever now sits before the message we were on.
 *
 *   - still loading            -> wait (nothing changes)
 *   - the anchor is gone       -> give up quietly; the screen stays put
 *   - something older loaded   -> page onto it
 *   - nothing older yet, more on the server -> fetch the next page too: a
 *     page of tool calls holds no content message, and stopping there would
 *     make prev look broken
 *   - nothing older, none left -> done; the anchor really is the first */
export function resolvePendingStep({ pendingFrom = null, seq = [], hasMore = false, loading = false } = {}) {
  if (!pendingFrom) return { pending: null, paging: undefined, loadOlder: false }
  if (loading) return { pending: pendingFrom, paging: undefined, loadOlder: false }

  const idx = seq.indexOf(pendingFrom)
  if (idx < 0) return { pending: null, paging: undefined, loadOlder: false }
  if (idx > 0) return { pending: null, paging: seq[idx - 1], loadOlder: false }
  if (hasMore) return { pending: pendingFrom, paging: undefined, loadOlder: true }
  return { pending: null, paging: undefined, loadOlder: false }
}

/* D6's return-to-live triggers, as one transition. Everything that is not
 * one of them leaves `paging` alone — in particular a reply arriving does
 * NOT, or paging back to re-read something would be impossible mid-turn.
 *
 *   live          the Live button
 *   speech-start  `orca:voice-speech-start`, a VAD onset: you started talking
 *   clear-prompt  `phx:clear-prompt`, a send went through
 *   draft         the composer changed; only EMPTY -> NON-EMPTY counts (you
 *                 started a new draft). Editing an existing one does not. */
export function pagingAfter(paging, event, { wasBusy = false, busy = false } = {}) {
  switch (event) {
    case "live":
    case "speech-start":
    case "clear-prompt":
      return null
    case "draft":
      return !wasBusy && busy ? null : paging
    default:
      return paging
  }
}

/* The elapsed clock ticks only while a clock is on screen: the activity
 * list (working) or the agent strip over a draft (dictating mid-turn). A
 * reply, or paging back, shows no clock, so it costs no timer. */
export function clockRunning({ state = null, running = false } = {}) {
  return !!running && (state === "working" || state === "dictating")
}

/* "m:ss", or "h:mm:ss" past an hour. Negative or missing reads as 0:00 — a
 * clock skewed a little ahead of the server must not show "-0:03". */
export function formatElapsed(ms) {
  const total = Math.max(0, Math.floor((Number(ms) || 0) / 1000))
  const s = total % 60
  const m = Math.floor(total / 60) % 60
  const h = Math.floor(total / 3600)
  const ss = String(s).padStart(2, "0")
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`
}

/* The pager's caption: who wrote the message on screen, and where it sits.
 * "Agent · 14 of 14", "You, 9:58 AM · 11 of 15". */
export function pagerLabel({ role = null, time = null, position = 0, total = 0 } = {}) {
  const who = role === "user" ? "You" : role === "assistant" ? "Agent" : ""
  const head = who && time ? `${who}, ${time}` : who
  const count = total > 0 && position > 0 ? `${position} of ${total}` : ""
  return [head, count].filter(Boolean).join(" · ")
}

/* The stylesheet that shows ONLY the current message in the feed.
 *
 * Why a generated <style> rather than toggling a class per element: the
 * feed is ordinary LiveView-rendered markup, and a class or attribute set on
 * it with a bare DOM call is stripped by the next patch (a reply streaming
 * in patches constantly). A <style> in <head> is outside every LiveView
 * root, so nothing can undo it, and one rule keyed on the current id covers
 * every element the feed will ever render.
 *
 * Every rule sits under the same media query + <html> attributes as the
 * `voice-view` Tailwind variant, so it is inert on desktop and while the
 * view is off. `#message-feed` keeps it to this page's feed. */
export const VOICE_VIEW_SCOPE = "html[data-voice-view][data-voice-layout]"
export const VOICE_VIEW_MEDIA_QUERY = "(max-width: 767px)"

export function currentSelector(key) {
  if (!key) return null
  const s = String(key)
  if (s.startsWith("stream:")) return `[data-assistant-stream="${cssString(s.slice(7))}"]`
  return `[data-voice-msg="${cssString(s)}"]`
}

export function currentStyleText(key) {
  const feed = `${VOICE_VIEW_SCOPE} #message-feed`
  const sel = currentSelector(key)

  // No current message: the feed shows nothing (it is hidden outright while
  // dictating anyway; this covers an empty session).
  const rules = sel
    ? [
        // every top-level feed item that does not hold the current element
        `${feed} > :not(:has(${sel})) { display: none !important; }`,
        // and, inside the one that does, its siblings (the tool calls and
        // results rendered in the same feed item, or other live bubbles)
        `${feed} > :has(${sel}) > :not(${sel}) { display: none !important; }`,
      ]
    : [`${feed} > * { display: none !important; }`]

  return `@media ${VOICE_VIEW_MEDIA_QUERY} {\n  ${rules.join("\n  ")}\n}\n`
}

/* An id inside a double-quoted CSS string: escape the two characters that
 * could end or break it. Ids are uuids / row ids / "h<hash>" in practice,
 * but the stylesheet must not become injectable if one ever is not. */
function cssString(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\n\r\f]/g, " ")
}
