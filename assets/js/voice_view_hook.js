/* The session page's mobile voice view (ORCAHUB3-113 phase C) — the hook
 * mounted on `#voice-view` in session_live/show.html.heex.
 *
 * Direction B (D1): the SESSION PAGE restyles itself into the voice view, in
 * the same document. There is no overlay and no second copy of anything:
 * the feed on screen is the real `#message-feed`, the draft is the real
 * composer textarea (§8.2's one draft), and Send is the real form. This
 * hook owns only the page half of the view:
 *
 *   - announcing that this page draws a voice layout
 *     (`html[data-voice-layout="session"]`, W1's `setVoiceLayout`) — unless
 *     the page is SUPPRESSED (C1: a question that needs a tap answer, plan
 *     review, node unavailable), when the normal page must show instead;
 *   - deciding which ONE message is on screen (the rules are pure, in
 *     voice_view.js) and publishing it as `html[data-voice-state]` and
 *     `html[data-voice-current]`, which the TTS rail (W3) reads;
 *   - showing only that message, through a generated <style> in <head>;
 *   - the pager row, the elapsed clock, and load-older stepping.
 *
 * The bar half (the mic, End, Resume, the flag itself) is VoiceHook's.
 *
 * TRAPS, each of which this file is shaped around:
 *
 * 1. NEVER write attributes or classes onto LiveView-rendered elements with
 *    bare DOM calls: the next patch strips them, and mid-turn the feed is
 *    patched constantly. Everything this hook writes lives on <html>, in
 *    <head>, inside `phx-update="ignore"` containers (`#voice-pager`, the
 *    `[data-voice-elapsed]` spans), or on the composer textarea, which sits
 *    inside the already-ignored `#prompt-wrapper`.
 * 2. The feed is ScrollToBottom's. In voice view it shows one short
 *    element, so its follow-to-bottom and near-the-top `load_older_messages`
 *    would fight this view (the second one would page in the WHOLE history).
 *    It stands down while `voiceViewShowing()`; this hook scrolls the feed
 *    to the current message's top instead, and back to the bottom on exit.
 * 3. The textarea is hidden (display: none) outside `dictating`, and
 *    Autocomplete's autoresize runs on every dictated write — against a
 *    hidden box, where scrollHeight is 0, leaving an inline `height: 0px`.
 *    Inside the view the CSS flexes it and the inline height is moot; on the
 *    way OUT this hook re-runs the same resize, or the normal page would
 *    show a zero-height composer.
 */

import { draftIsBusy } from "./tts_hold"
import { setVoiceLayout, voiceViewShowing, VOICE_VIEW_MEDIA } from "./voice_view_flag"
import {
  clockRunning,
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
} from "./voice_view"

const COMPOSER = "form[data-voice-composer-for] textarea"

export const VoiceViewHook = {
  mounted() {
    // `paging`: the sequence key the user paged back to (null = live).
    // `pending`: the key a prev-at-the-oldest is stepping back FROM while
    // `load_older_messages` is in flight (see voice_view.js stepPager).
    this._paging = null
    this._pending = null
    this._loadInFlight = false
    this._draftBusy = draftIsBusy(document)
    this._current = undefined
    this._styleKey = undefined
    this._showing = false
    this._runningSince = null
    this._clock = null
    this._frame = null

    // One <style> per hook INSTANCE, never looked up by a shared id: across
    // a live navigation between two sessions the old page's destroyed() and
    // the new page's mounted() must not be able to remove each other's.
    this._style = document.createElement("style")
    this._style.dataset.voiceViewStyle = ""
    document.head.appendChild(this._style)

    this._onClick = (e) => {
      const btn = e.target.closest && e.target.closest("[data-voice-view-action]")
      if (!btn || !this.el.contains(btn)) return
      e.preventDefault()
      this._act(btn.dataset.voiceViewAction)
    }
    this.el.addEventListener("click", this._onClick)

    // D6's return-to-live triggers that arrive as events. (The fourth, the
    // draft becoming busy, is a transition `_sync` sees for itself.)
    this._onSpeechStart = () => this._returnToLive("speech-start")
    this._onClearPrompt = () => this._returnToLive("clear-prompt")
    // Everything else is just "something may have changed": coalesced into
    // one recompute per frame, since a streaming reply fires these per
    // delta and every patch fires `phx:update`.
    this._onChange = () => this._schedule()

    this._windowEvents = [
      ["orca:voice-speech-start", this._onSpeechStart],
      ["phx:clear-prompt", this._onClearPrompt],
      ["orca:assistant-stream", this._onChange],
      ["orca:tts-state", this._onChange],
    ]
    this._windowEvents.forEach(([name, fn]) => window.addEventListener(name, fn))

    // `phx:update` is dispatched at `document` after every patch — the
    // feed's included, which is a different element from this one, so
    // `updated()` alone would miss it. Composer input is delegated (the
    // voice hook writes dictation into the textarea and fires a synthetic
    // `input` after each write, §8.2).
    this._onInput = (e) => {
      if (e.target && typeof e.target.matches === "function" && e.target.matches(COMPOSER)) this._schedule()
    }
    document.addEventListener("phx:update", this._onChange)
    document.addEventListener("input", this._onInput, true)

    // The view appears and disappears without this page re-rendering: the
    // Voice hook flips `html[data-voice-view]` from user intent, and the
    // viewport can cross the phone breakpoint (rotation). Both matter for
    // the scroll/resize hand-off in `_afterShowing`.
    this._observer = new MutationObserver(this._onChange)
    this._observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-voice-view"] })
    this._media = window.matchMedia ? window.matchMedia(VOICE_VIEW_MEDIA) : null
    if (this._media && this._media.addEventListener) this._media.addEventListener("change", this._onChange)

    this._sync()
  },

  updated() {
    this._schedule()
  },

  destroyed() {
    if (this._frame) cancelAnimationFrame(this._frame)
    this._stopClock()
    this.el.removeEventListener("click", this._onClick)
    ;(this._windowEvents || []).forEach(([name, fn]) => window.removeEventListener(name, fn))
    document.removeEventListener("phx:update", this._onChange)
    document.removeEventListener("input", this._onInput, true)
    if (this._observer) this._observer.disconnect()
    if (this._media && this._media.removeEventListener) this._media.removeEventListener("change", this._onChange)
    if (this._style) this._style.remove()

    // Leaving the session page: no page layout any more, so the next page
    // shows normally with the bar (D11) until it draws its own. Skipped if
    // another session page's #voice-view is already up (a navigation whose
    // new hook mounted first): those attributes are now ITS.
    const other = document.getElementById("voice-view")
    if (!other || other === this.el) this._clearPublished()
  },

  // ------------------------------------------------------------ the loop

  _schedule() {
    if (this._frame) return
    const run = () => {
      this._frame = null
      this._sync()
    }
    this._frame = typeof requestAnimationFrame === "function" ? requestAnimationFrame(run) : setTimeout(run, 16)
  },

  _returnToLive(event) {
    this._paging = pagingAfter(this._paging, event)
    if (this._paging === null) this._pending = null
    this._schedule()
  },

  /* Everything the rules need, read off the page in one pass. */
  _read() {
    const feed = document.getElementById("message-feed")
    const items = feed
      ? Array.from(feed.querySelectorAll("[data-voice-content]")).map((el) => ({
          id: el.dataset.voiceMsg,
          role: el.dataset.voiceContent,
        }))
      : []
    const facts = feedFacts(items)

    // The newest live bubble that has TEXT (assistant_stream.js parks them in
    // the ignored `#assistant-stream-slot`). A bubble exists from the
    // stream's `start`, before any text, and tool calls stream into it as
    // chips — counting that would put an empty header, or a tool call (D5:
    // none inline), on screen in place of the agent's last words. Keyed
    // `stream:<id>` so it can never collide with a persisted message's id.
    const bubbles = Array.from(
      document.querySelectorAll("#assistant-stream-slot [data-assistant-stream]")
    ).filter((b) => Array.from(b.querySelectorAll("[data-stream-block]")).some((d) => d.textContent.trim()))
    const bubble = bubbles.length ? bubbles[bubbles.length - 1] : null
    const streamingId = bubble ? `stream:${bubble.dataset.assistantStream}` : null

    return {
      feed,
      facts,
      streamingId,
      seq: pagerSequence(facts.contentIds, streamingId),
      hasMore: !!feed && feed.dataset.hasMore === "true",
      loading: !!feed && feed.dataset.loadingOlder === "true",
      status: this.el.dataset.sessionStatus || null,
      // The server's answer, because `waiting` alone cannot say: a pi dialog
      // is mid-turn, a Claude question has ended the turn
      // (`Session.waiting_mid_turn?/1`; see RUNNING_STATUSES).
      running:
        "turnRunning" in this.el.dataset
          ? this.el.dataset.turnRunning === "true"
          : isRunning(this.el.dataset.sessionStatus || null),
      suppressed: this.el.dataset.voiceSuppressed === "true",
    }
  },

  _sync() {
    const page = this._read()
    const running = page.running

    // The clock's fallback start, for a turn whose opening message is not
    // in the loaded window (`data-turn-started-at` absent): when this page
    // first saw it running. Late, but never wrong in the alarming direction.
    if (running && !this._runningSince) this._runningSince = Date.now()
    if (!running) this._runningSince = null

    if (page.suppressed) {
      // C1: never hide a question behind the voice view. Drop the layout so
      // the normal page (and its modal) shows; voice itself stays on.
      this._paging = null
      this._pending = null
      this._draftBusy = draftIsBusy(document)
      this._clearPublished()
      this._stopClock()
      this._afterShowing(false)
      return
    }

    if (document.documentElement.dataset.voiceLayout !== "session") setVoiceLayout("session")

    // D6: a draft going from empty to non-empty returns to live, however it
    // got there (dictation, typing, a restored draft).
    const busy = draftIsBusy(document)
    this._paging = pagingAfter(this._paging, "draft", { wasBusy: this._draftBusy, busy })
    this._draftBusy = busy

    if (this._pending && !this._loadInFlight) {
      const step = resolvePendingStep({
        pendingFrom: this._pending,
        seq: page.seq,
        hasMore: page.hasMore,
        loading: page.loading,
      })
      this._pending = step.pending
      if (step.paging !== undefined) this._paging = step.paging
      if (step.loadOlder) this._loadOlder()
    }

    const view = voiceViewState({
      ...page.facts,
      draftBusy: busy,
      status: page.status,
      running: page.running,
      paging: this._paging,
      streamingId: page.streamingId,
    })
    // A paged-to message that is no longer loaded fell through to live;
    // forget it, so it cannot snap back if it ever re-renders.
    if (this._paging && view.state !== "paging") this._paging = null

    this._publish(view)
    this._setStyle(view.current)
    this._renderPager(view, page)

    if (clockRunning(view)) this._startClock()
    else this._stopClock()
    this._tick()

    const changed = view.current !== this._current
    this._current = view.current
    this._afterShowing(changed)
  },

  // ------------------------------------------------------------ output

  _publish(view) {
    const ds = document.documentElement.dataset
    if (ds.voiceState !== view.state) ds.voiceState = view.state

    // Only a PERSISTED message is published: W3's rail plays and jumps
    // within `#tts-text-<id>`, which a live bubble does not have.
    const id = view.current && !view.current.startsWith("stream:") ? view.current : null
    if (id) {
      if (ds.voiceCurrent !== id) ds.voiceCurrent = id
    } else if ("voiceCurrent" in ds) {
      delete ds.voiceCurrent
    }
  },

  _clearPublished() {
    const ds = document.documentElement.dataset
    if (ds.voiceLayout === "session") setVoiceLayout(null)
    delete ds.voiceState
    delete ds.voiceCurrent
  },

  _setStyle(key) {
    if (!this._style || key === this._styleKey) return
    this._styleKey = key
    this._style.textContent = currentStyleText(key)
  },

  _renderPager(view, page) {
    const root = this.el.querySelector("#voice-pager")
    if (!root) return
    const pv = pagerView({
      state: view.state,
      current: view.current,
      seq: page.seq,
      hasMore: page.hasMore,
      loading: page.loading || this._loadInFlight,
    })

    const row = root.querySelector("[data-voice-pager-row]")
    if (row) row.hidden = !pv.visible

    const { role, time } = this._describe(view.current, page.feed)
    const label = root.querySelector("[data-voice-pager-label]")
    const text = pagerLabel({ role, time, position: pv.position, total: pv.total })
    if (label && label.textContent !== text) label.textContent = text

    const prev = root.querySelector('[data-voice-view-action="prev"]')
    const next = root.querySelector('[data-voice-view-action="next"]')
    const live = root.querySelector('[data-voice-view-action="live"]')
    if (prev) prev.disabled = !pv.canPrev
    if (next) next.disabled = !pv.canNext
    if (live) live.hidden = !pv.showLive
  },

  /* Who wrote the message on screen, and the time its header shows. */
  _describe(key, feed) {
    if (!key) return { role: null, time: null }
    if (key.startsWith("stream:")) return { role: "assistant", time: null }
    if (!feed) return { role: null, time: null }

    const sel = typeof CSS !== "undefined" && CSS.escape ? CSS.escape(key) : key.replace(/"/g, '\\"')
    const el = feed.querySelector(`[data-voice-msg="${sel}"]`)
    if (!el) return { role: null, time: null }
    const timeEl = el.querySelector(".chat-header time")
    return { role: el.dataset.voiceContent || null, time: timeEl ? timeEl.textContent.trim() : null }
  },

  // ------------------------------------------------------------ the pager

  _act(action) {
    if (action === "live") {
      this._returnToLive("live")
      return
    }
    if (action !== "prev" && action !== "next") return

    const page = this._read()
    const base = {
      ...page.facts,
      draftBusy: draftIsBusy(document),
      status: page.status,
      running: page.running,
      streamingId: page.streamingId,
    }
    const view = voiceViewState({ ...base, paging: this._paging })
    const live = voiceViewState({ ...base, paging: null }).current

    const step = stepPager({
      direction: action,
      current: view.current,
      paging: this._paging,
      seq: page.seq,
      live,
      hasMore: page.hasMore,
      loading: page.loading || this._loadInFlight,
    })
    this._paging = step.paging
    if (step.pendingFrom) this._pending = step.pendingFrom
    if (step.loadOlder) this._loadOlder()
    this._sync()
  },

  /* The EXISTING windowed-feed pagination, the same event ScrollToBottom
   * pushes when you scroll near the top. Its handler commits the page
   * synchronously, so by the time the reply lands the older messages are
   * in the DOM and `resolvePendingStep` can step onto them. */
  _loadOlder() {
    if (this._loadInFlight) return
    this._loadInFlight = true
    const done = () => {
      this._loadInFlight = false
      this._schedule()
    }
    try {
      const p = this.pushEvent("load_older_messages", {})
      if (p && typeof p.then === "function") p.then(done, () => {
        // Disconnected or rejected: drop the step rather than retry in a loop.
        this._pending = null
        done()
      })
      else done()
    } catch (_e) {
      this._pending = null
      done()
    }
  },

  // ------------------------------------------------------------ the clock

  _startClock() {
    if (this._clock) return
    this._clock = setInterval(() => this._tick(), 1000)
  },

  _stopClock() {
    if (!this._clock) return
    clearInterval(this._clock)
    this._clock = null
  },

  /* Writes "m:ss" into every `[data-voice-elapsed]` span (the activity
   * list's and the agent strip's — both `phx-update="ignore"`, so a patch
   * re-rendering the list around them does not blank the clock). */
  _tick() {
    const spans = this.el.querySelectorAll("[data-voice-elapsed]")
    if (!spans.length) return
    const started = Number(this.el.dataset.turnStartedAt) || this._runningSince
    const text = started && this._clock ? formatElapsed(Date.now() - started) : ""
    spans.forEach((s) => {
      if (s.textContent !== text) s.textContent = text
    })
  },

  // ------------------------------------------------------------ hand-offs

  /* The scroll and size hand-offs between this view and the normal page.
   * Entering, or moving to another message: the feed shows one element,
   * so put its TOP on screen. Leaving: give the feed back at the bottom (where
   * ScrollToBottom's follow mode expects it) and re-run the composer's
   * autoresize (trap 3). */
  _afterShowing(currentChanged) {
    const showing = voiceViewShowing()
    const feed = document.getElementById("message-feed")

    if (showing && (!this._showing || currentChanged) && feed) {
      // After the <style> above has applied, or scrollHeight is stale.
      requestAnimationFrame(() => {
        if (voiceViewShowing()) feed.scrollTop = 0
      })
    }

    if (!showing && this._showing) {
      const ta = document.querySelector(COMPOSER)
      if (ta) {
        // Autocomplete.resize, verbatim. Not dispatched as an `input` event:
        // that would also run autocomplete and be echoed to the voice
        // channel as a draft edit.
        ta.style.height = "auto"
        ta.style.height = ta.scrollHeight + "px"
      }
      if (feed) feed.scrollTop = feed.scrollHeight
    }

    this._showing = showing
  },
}
