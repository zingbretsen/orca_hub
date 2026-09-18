/* LiveView hook `Voice` — the browser half of voice mode. Registered in
 * assets/js/app.js as `Voice`, and mounted on `#voice-panel`, which since
 * phase 2b is the root of `OrcaHubWeb.VoiceBarLive` in the app header rather
 * than a strip inside one session page (voice_mode_spec.md §8.1 + §8.2).
 *
 * Pipeline, unchanged from phase 1:
 *
 *   getUserMedia (AEC/NS/AGC on, voiceIsolation off)
 *     -> AudioContext at whatever rate it negotiates
 *     -> orca-capture worklet: ctx.sampleRate -> 16 kHz, 63-tap windowed-sinc
 *        LPF + fractional decimation, ring buffer keyed by ABSOLUTE 16 kHz index
 *     -> vad-web's FrameProcessor + Silero v5, fed OUR frames (see vad.js)
 *     -> onSpeechEnd -> OVS1 binary frame -> channel.push("segment", ...)
 *
 * What §8.2 changed, and why each line of it is load-bearing:
 *
 * 1. LIFECYCLE. The bar is ALWAYS mounted, so `mounted()` must not arm the
 *    mic — that would ask for microphone permission on every page load. The
 *    mic BUTTON is the gesture (sticky activation, §9 trap 2): the first
 *    click opens the AudioContext and joins. `destroyed()` now only fires on
 *    a full page reload, because the bar is `sticky: true`.
 *
 * 2. TARGET. `#voice-panel[data-target-session-id]` is the ONE source of
 *    truth for which session we are dictating into. The hook never sets it
 *    directly: it asks VoiceBarLive (`pushEvent("voice-target")`) and reacts
 *    in `updated()`, so the picker and the channel cannot disagree. A page
 *    advertises itself through `body[data-voice-composer-for]`, watched with
 *    a MutationObserver so this works even if a push_event is missed.
 *
 * 3. RETARGET is leave + join, never a teardown: the mic, the AudioContext
 *    and the VAD session outlive it. The current draft is carried across in
 *    JS and re-seeded with `draft_edit` right after the new join, since the
 *    server's draft is per channel.
 *
 * 4. DRAFT SINK. `_draftEl()` is a FUNCTION, not a fixed selector: the
 *    composer textarea of `form[data-voice-composer-for="<target>"]` when the
 *    page has one, else the bar's own `[data-voice-bar-draft]` box. Both are
 *    written through `_writeDraft()`, which dispatches a real bubbling
 *    `input` event — a bare `.value =` skips `Autocomplete`'s autoresize and
 *    leaves a one-row box holding several rows of text.
 *
 * 5. SEND (ORCAHUB3-86). The server asks (`send_request`); we answer. With a
 *    composer on the page we set its textarea and `requestSubmit()` it, so
 *    `SessionLive.Show.send_message` runs and staged uploads/attachment lines
 *    ride along, then report `sent_ack` / `send_failed`. LiveView dispatches
 *    EVERY push_event on `window` as `phx:<event>` as well as to its own
 *    hooks, so `phx:clear-prompt` and `phx:voice-send-failed` reach the bar
 *    directly and the session page needs no bridging code. With no composer
 *    we push `send_direct` and the server delivers as it did in phase 1.
 */

import { Capture, secureContextProblem, FRAME_SAMPLES } from "./capture"
import { VoiceChannel } from "./channel"
import {
  buildSegmentFrame,
  FLAG_FORCED_END,
  FLAG_PADDED,
  MAX_SEGMENT_SAMPLES,
  MIN_SEGMENT_SAMPLES,
} from "./frame"
import { createVad, VAD_SETTINGS } from "./vad"

const DRAFT_DEBOUNCE_MS = 300
const LOG_LIMIT = 50
const LOG_OPEN_KEY = "orca:voice:log-open"

const STATUS_LABEL = {
  warming: "warming up transcription…",
  listening: "listening",
  transcribing: "transcribing…",
  arming: "sending shortly",
  sending: "sending…",
  error: "error",
}

/** CSS.escape with a fallback, since the target is a UUID from the server and
 * goes straight into a selector. */
function esc(value) {
  if (typeof CSS !== "undefined" && CSS.escape) return CSS.escape(value)
  return String(value).replace(/["\\]/g, "\\$&")
}

export const VoiceHook = {
  mounted() {
    this.target = this.el.dataset.targetSessionId || null
    this.active = false // voice mode engaged (the user clicked the mic)
    this.armed = false // the mic is actually capturing
    this.muted = false
    this.state = null
    this.composerPresent = false
    this.metrics = {
      sampleRate: null,
      ratio: null,
      framesSeen: 0,
      vadInitMs: null,
      speechStarts: 0,
      segmentsSent: 0,
      misfires: 0,
      processorError: null,
      joins: 0,
      retargets: 0,
      startedAt: Date.now(),
    }
    this._timers = {}
    this._applyingDraft = false
    this._pendingSend = null
    this._lastSink = null
    this._inFlight = 0
    this._asrBusy = false

    this._bindDom()
    this._bindWindow()
    this._observeBody()
    this._syncPage()

    if (typeof window !== "undefined") window.__orcaVoice = this
  },

  /** The bar re-rendered: the target may have changed (picker or page), and
   * the strip may have just been inserted. */
  updated() {
    const next = this.el.dataset.targetSessionId || null
    if (next !== this.target) {
      const carried = this._currentDraftText()
      this.target = next
      this._retarget(carried)
    }
    this._bindLogToggle()
    this._syncPage()
    this._renderMic()
  },

  /** Sticky: this only fires on a full page reload, never on navigation. */
  destroyed() {
    this._unbindWindow()
    if (this._bodyObserver) {
      this._bodyObserver.disconnect()
      this._bodyObserver = null
    }
    if (this._onDocInput) document.removeEventListener("input", this._onDocInput, true)
    this._teardown()
    if (window.__orcaVoice === this) delete window.__orcaVoice
  },

  // ------------------------------------------------------------- voice mode

  /** The mic button: the user gesture that satisfies the autoplay policy. */
  async _toggle() {
    if (this.active) {
      this._teardown()
      this.active = false
      this.pushEvent("voice-on", { on: false })
      return
    }

    this.active = true
    this.pushEvent("voice-on", { on: true })

    // Trap 1: no secure context means navigator.mediaDevices is simply
    // absent, with no error thrown. Say so loudly before anything else
    // fails weirdly.
    //
    // Only the BANNER waits, because it lands in a strip LiveView is only
    // now rendering — and it waits on a timer rather than
    // requestAnimationFrame, which a hidden tab throttles to never. The
    // connect path deliberately does NOT wait: it stays inside this click's
    // own task, so `AudioContext.resume()` runs under the user activation
    // that the click just granted rather than relying on it being sticky.
    const insecure = secureContextProblem()
    if (insecure) {
      setTimeout(() => {
        this._showBanner(insecure)
        this._setStatusText("unavailable")
      }, 50)
      return
    }
    this._connect()
  },

  _teardown() {
    Object.values(this._timers).forEach((t) => {
      if (!t) return
      clearInterval(t)
      clearTimeout(t)
    })
    this._timers = {}
    this._pendingSend = null
    this._setAsrBusy(0)
    if (this.vad) {
      this.vad.destroy()
      this.vad = null
    }
    if (this.capture) {
      this.capture.stop()
      this.capture = null
    }
    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }
    this.armed = false
    this.state = null
    this._renderMic()
  },

  // ------------------------------------------------------------------ channel

  async _connect() {
    if (!(await this._joinChannel(""))) return
    // Joining IS arming on the server (it fires the ASR warm-up
    // immediately); arm the browser half right away too, never on first
    // speech — SPIKE 1 measured 499-809 ms of VAD session init.
    this._arm()
  },

  /** Join `voice:<target>`. `carried` is a draft rescued from the channel we
   * just left, which only wins when the new sink is EMPTY — §8.1's
   * never-clobber rule outranks it. */
  async _joinChannel(carried) {
    if (!this.target) {
      this._showError("Pick a session in the voice bar to dictate into.")
      return false
    }
    // Pre-typed text in a COMPOSER outranks a carried draft — that is §8.1's
    // never-clobber rule, and it protects something the user typed into the
    // page. The bar's OWN box gets no such deference: it is our scratch
    // space, so a carried draft wins over whatever is still sitting in it.
    const composer = this._composerForm()
    const typed = composer ? composer.querySelector("textarea").value : ""
    this._pendingSeed = typed !== "" ? typed : carried || ""

    this.channel = new VoiceChannel(this.target, {
      onState: (s) => this._renderState(s),
      onSegmentResult: (r) => this._onSegmentResult(r),
      onSendRequest: (m) => this._onSendRequest(m),
      onSent: () => {
        this._setArming(null)
        // The draft has been delivered and the server cleared its copy;
        // clear ours so the text cannot be sent twice.
        this._writeDraft("")
      },
    })
    try {
      await this.channel.join()
    } catch (e) {
      this.channel = null
      this._showError(e.message)
      return false
    }
    this.metrics.joins++
    this._hideError()
    // The server's composer flag is per channel, so it is re-reported at
    // every join, not only when it changes.
    this._reportComposer(true)
    return true
  },

  /** Leave the old channel and join the new one. The mic, the AudioContext
   * and the VAD are NOT torn down (C4) — retargeting is routine. */
  async _retarget(carried) {
    this._setArming(null)
    this._pendingSend = null
    if (!this.active) return
    if (this.channel) {
      this.channel.leave()
      this.channel = null
    }
    this.metrics.retargets++
    await this._joinChannel(carried)
    this._renderMic()
  },

  // --------------------------------------------------------------------- arm

  async _arm() {
    if (this.armed || this._arming) return
    this._arming = true
    try {
      if (!this.capture) {
        this.capture = new Capture({
          prerollMs: VAD_SETTINGS.preSpeechPadMs,
          onFrame: (m) => this._onFrame(m),
          onProcessorError: (msg) => {
            this.metrics.processorError = msg
            this._showError(msg)
          },
        })
        await this.capture.open()
      }

      if (this.capture.suspended()) {
        await this.capture.resume()
      }
      if (this.capture.suspended()) {
        // Autoplay policy (trap 2): no sticky activation yet. Fall back to an
        // explicit gesture rather than silently capturing nothing.
        this._show(this._el('[data-voice-action="start"]'))
        this._setStatusText("click “Start listening” to arm the mic")
        return
      }
      this._hide(this._el('[data-voice-action="start"]'))

      const ready = await this.capture.start()
      this.metrics.sampleRate = this.capture.sampleRate
      this.metrics.ratio = this.capture.ratio
      this.metrics.worklet = ready

      const t0 = performance.now()
      this.vad = await createVad({
        maxSegmentSamples: MAX_SEGMENT_SAMPLES,
        onSpeechStart: () => this._onSpeechStart(),
        onSpeechEnd: (ev) => this._onSpeechEnd(ev),
        onMisfire: () => {
          this.metrics.misfires++
        },
        onError: (e) => this._showError(`VAD failure: ${e.message}`),
      })
      this.metrics.vadInitMs = +(performance.now() - t0).toFixed(1)

      this.armed = true
      this._renderMic()
    } catch (e) {
      this._showError(
        e && e.name === "NotAllowedError"
          ? "Microphone permission was denied — voice mode cannot listen."
          : `Could not start the microphone: ${e && e.message ? e.message : e}`
      )
    } finally {
      this._arming = false
    }
  },

  // ------------------------------------------------------------------- audio

  _onFrame(m) {
    this.metrics.framesSeen++
    if (this.muted || !this.vad) return // half-duplex: drop, do not buffer
    this.vad.feed(m.samples, m.endSample)
  },

  _onSpeechStart() {
    this.metrics.speechStarts++
    // The arming chip must die on ONSET, not 600 ms later when the segment
    // completes. The server cancels it too; this is the local, zero-latency half.
    this._setArming(null)
    this.channel && this.channel.push("speech_start", {})
  },

  async _onSpeechEnd({ audio, endSample, forced }) {
    if (this.muted) return
    let samples = audio
    let startSample = endSample - audio.length
    let flags = forced ? FLAG_FORCED_END : 0

    // Sub-0.8 s segments are the endpoint's real hallucination mode (a 0.3 s
    // cut of "Orca" came back "archives."). Extend from audio the ring buffer
    // ALREADY RECORDED — never synthesised silence, never discarded.
    if (samples.length < MIN_SEGMENT_SAMPLES && this.capture) {
      const need = MIN_SEGMENT_SAMPLES - samples.length
      const pre = await this.capture.history(startSample, need)
      if (pre.length > 0) {
        const merged = new Float32Array(pre.length + samples.length)
        merged.set(pre, 0)
        merged.set(samples, pre.length)
        samples = merged
        startSample -= pre.length
        flags |= FLAG_PADDED
      }
    }

    if (!this.channel || !this.channel.joined()) return
    const frame = buildSegmentFrame({
      seq: this.channel.nextSeq(),
      startSample,
      samples,
      flags,
    })
    this.channel.pushSegment(frame)
    this.metrics.segmentsSent++
    // Spec §7's GPU-contention rule: TTS must not start NEW synthesis while
    // a segment is on its way to the same GB10 box.
    this._setAsrBusy(this._inFlight + 1)
  },

  // -------------------------------------------------------------- half-duplex

  _handleTtsState(e) {
    const playing = !!(e && e.detail && e.detail.playing)
    if (playing === this.muted) return
    this.muted = playing
    if (this.vad) {
      if (playing) this.vad.pause()
      else this.vad.resume()
    }
    this.channel && this.channel.push("mic", { muted: playing, reason: "tts" })
    this._renderMic()
  },

  /** `orca:voice-asr-busy` — consumed by TTSMethods' streaming prefetch. */
  _setAsrBusy(count) {
    this._inFlight = Math.max(0, count)
    const busy = this._inFlight > 0
    if (busy === this._asrBusy) return
    this._asrBusy = busy
    window.dispatchEvent(new CustomEvent("orca:voice-asr-busy", { detail: { busy } }))
  },

  // --------------------------------------------------------------- the send

  /** Spec §8.2 / ORCAHUB3-86: the server asked us to send. */
  _onSendRequest(msg) {
    const text = (msg && msg.text) || ""
    const form = this._composerForm()

    if (!form) {
      // No composer bound to the target on this page — let the server
      // deliver it the phase-1 way.
      this.channel && this.channel.push("send_direct", {})
      return
    }

    this._pendingSend = { text, sessionId: this.target }
    this._writeDraft(text)
    // The textarea IS the draft now; a debounced draft_edit landing after the
    // submit would only re-seed text the server is about to clear.
    this._clearDraftTimer()

    try {
      form.requestSubmit()
    } catch (e) {
      this._pendingSend = null
      this.channel &&
        this.channel.push("send_failed", {
          reason: `The composer could not be submitted: ${e && e.message ? e.message : e}`,
        })
    }
  },

  /** `clear-prompt` — LiveView pushes it only after delivery SUCCEEDED.
   *
   * A page LiveView's `push_event` reaches only ITS OWN hooks, and this hook
   * lives in the sticky bar; but LiveView ALSO dispatches every push_event on
   * `window` as `phx:<event>` (`LiveSocket.dispatchEvents`), which is the
   * seam used here — no re-dispatch is needed in the session page.
   *
   * `clear-prompt` carries no session id, so the scope comes from
   * `composerPresent`: it is only true when the page on screen owns a
   * composer for OUR target, and a submit from any other page's composer is
   * therefore correctly ignored.
   */
  _onComposerSent(e) {
    const sessionId = e && e.detail && (e.detail.sessionId || e.detail.session_id)
    if (sessionId && this.target && sessionId !== this.target) return
    if (!sessionId && !this.composerPresent) return

    this._clearDraftTimer()
    this._setArming(null)

    if (this._pendingSend) {
      this._pendingSend = null
      this.channel && this.channel.push("sent_ack", {})
    } else {
      // The user pressed Send themselves. The draft left the box, so the
      // server's copy must go too or the next spoken send would repeat it.
      this.channel && this.channel.push("cancel", {})
    }
  },

  _onComposerSendFailed(e) {
    if (!this._pendingSend) return
    const reason = (e && e.detail && e.detail.reason) || "The composer could not send that message."
    this._pendingSend = null
    this.channel && this.channel.push("send_failed", { reason })
  },

  // ------------------------------------------------------------- the target

  /** The composer form bound to the CURRENT target, or null. */
  _composerForm() {
    if (!this.target) return null
    const form = document.querySelector(`form[data-voice-composer-for="${esc(this.target)}"]`)
    if (!form) return null
    return form.querySelector("textarea") ? form : null
  },

  /** §8.2's draft sink rule: the target's composer textarea when the page has
   * one, else the bar's own box. Resolved lazily so a re-rendered composer
   * can never leave us holding a detached node. */
  _draftEl() {
    const form = this._composerForm()
    if (form) return form.querySelector("textarea")
    return this.el.querySelector("[data-voice-bar-draft]")
  },

  _currentDraftText() {
    // A debounce still in flight means the box is newer than the server.
    if (this._timers.draft) {
      const el = this._draftEl()
      if (el) return el.value
    }
    return (this.state && this.state.draft) || ""
  },

  /** Re-read the page: which session it is showing, and whether it carries a
   * composer for our target. Cheap and idempotent — called from `updated()`,
   * from the body observer and after live navigation. */
  _syncPage() {
    const pageTarget = document.body.dataset.voiceComposerFor || null
    // Auto-follow fires on NAVIGATION — when the page's session actually
    // changes — not on every sync. `_syncPage` also runs on each re-render,
    // and an unconditional push would snap the target straight back to the
    // page the user is looking at the instant they chose a different one in
    // the picker. Off a session page the target PERSISTS (C4): a null page
    // target is remembered, so returning to the same page does not re-push.
    if (pageTarget !== this._lastPageTarget) {
      this._lastPageTarget = pageTarget
      if (pageTarget && pageTarget !== this.target) {
        this.pushEvent("voice-target", { session_id: pageTarget })
      }
    }
    this._reportComposer()
    this._followSink()
  },

  _reportComposer(force = false) {
    const present = !!this._composerForm()
    const changed = present !== this.composerPresent
    this.composerPresent = present
    this._syncBarBox()
    if (!force && !changed) return
    if (this.channel && this.channel.joined()) this.channel.push("composer", { present })
  },

  /** The bar's own box exists to catch a draft with nowhere else to go.
   *
   * Two rules, both paid for in §8.2's 16 px budget:
   *
   *  - while a composer is present it is not the sink, so it must not keep
   *    showing the last draft it held. Stale text there would resurface —
   *    and out-vote the real draft at the next join — the moment the sink
   *    came back to it.
   *  - an EMPTY box is 37 px of nothing on every composer-less page. It
   *    appears when it actually holds a transcript (or the user has clicked
   *    into it), not merely because voice is on.
   */
  _syncBarBox() {
    const box = this.el.querySelector("[data-voice-bar-draft]")
    if (!box) return
    if (!this.active || this.composerPresent) {
      this._hide(box)
      box.value = ""
      return
    }
    if (box.value !== "" || document.activeElement === box) this._show(box)
    else this._hide(box)
  },

  /** The sink changed under us (navigation, retarget): move the draft into
   * the new one. Never the other way round, and never with an empty draft —
   * that would be the clobber §8.1 forbids. */
  _followSink() {
    const el = this._draftEl()
    if (el === this._lastSink) return
    this._lastSink = el
    const text = (this.state && this.state.draft) || ""
    if (el && text !== "" && el.value === "") this._writeDraft(text, { follow: true })
  },

  // ------------------------------------------------------------------ rendering

  _renderState(state) {
    this.state = state
    const label = STATUS_LABEL[state.status] || state.status
    const pending = state.pending > 0 ? ` (${state.pending} in flight)` : ""
    this._setStatusText(label + pending)

    if (state.error) this._showError(state.error)
    else this._hideError()

    this._renderDraft(state.draft || "")
    this._syncBarBox()
    this._setArming(state.arming_ms)
    this._renderMic()
  },

  _renderDraft(text) {
    const el = this._draftEl()
    if (!el) return
    this._lastSink = el

    // Seed pass: the join reply's snapshot is a fresh, empty draft. If the
    // sink already held text (or we carried one across a retarget), the
    // server is the one that is out of date.
    if (this._pendingSeed != null) {
      const seed = this._pendingSeed
      this._pendingSeed = null
      if (seed !== "" && text === "") {
        this._pushDraftEdit(seed)
        return
      }
    }

    // Never clobber what the user is mid-way through typing: while a
    // draft_edit is still debouncing, the local value is the newer truth.
    if (this._timers.draft) return
    // ...and never let a stale empty snapshot eat typed text either. An empty
    // draft only reaches the sink through an EXPLICIT clear — "sent", a
    // spoken "orca cancel", or the composer's own submit — each of which
    // calls _writeDraft("") directly.
    if (text === "" && el.value !== "") return

    // Server-driven, so an append here is a freshly transcribed segment —
    // follow it down rather than leaving the newest words below the fold.
    this._writeDraft(text, { follow: true })
  },

  /** Write the draft into whichever textarea the sink rule picked.
   *
   * `#prompt-input` is owned by the `Autocomplete` hook and sits inside a
   * phx-update="ignore" wrapper, so assigning `.value` alone would skip its
   * autoresize (and LiveView's own phx-change). Dispatching a bubbling `input`
   * event is what keeps the box growing within its max-h-[7.5rem]. The
   * _applyingDraft flag stops that synthetic event from bouncing straight back
   * to the server as a draft_edit.
   *
   * `follow: true` keeps the newest text visible once the draft outgrows the
   * box. Only the server's own appends follow — an explicit clear has nothing
   * to follow, and neither does a shrinking correction.
   *
   * The one case that overrides all of that is a user parked mid-text with the
   * caret: they are editing, and both their caret and their scroll position
   * are left exactly where they put them.
   */
  _writeDraft(text, { follow = false } = {}) {
    const el = this._draftEl()
    if (!el || el.value === text) return
    // All sampled BEFORE the write: it moves the caret, and the browser then
    // scrolls that caret into view on a focused textarea all by itself.
    const grew = text.length > el.value.length
    const editingMidText =
      document.activeElement === el &&
      (el.selectionStart !== el.value.length || el.selectionEnd !== el.value.length)
    const caret = editingMidText
      ? { start: el.selectionStart, end: el.selectionEnd, scrollTop: el.scrollTop }
      : null
    this._applyingDraft = true
    try {
      el.value = text
      el.selectionStart = el.selectionEnd = text.length
      el.dispatchEvent(new Event("input", { bubbles: true }))
    } finally {
      this._applyingDraft = false
    }
    if (caret) {
      // The server only ever appends, so a mid-text offset still points at the
      // same character. Restore scroll LAST — setting the range re-scrolls.
      el.selectionStart = Math.min(caret.start, text.length)
      el.selectionEnd = Math.min(caret.end, text.length)
      el.scrollTop = caret.scrollTop
      return
    }
    // Autocomplete's autoresize is a plain `input` listener, so it has already
    // run synchronously inside that dispatch — the height (and therefore
    // scrollHeight) is final here, not one frame away.
    if (follow && grew) el.scrollTop = el.scrollHeight
  },

  _clearDraftTimer() {
    if (this._timers.draft) {
      clearTimeout(this._timers.draft)
      this._timers.draft = null
    }
  },

  _pushDraftEdit(text) {
    this._clearDraftTimer()
    this._setArming(null)
    this.channel && this.channel.push("draft_edit", { text })
  },

  _renderMic() {
    const el = this._el("[data-voice-mic]")
    if (!el) return
    const serverMuted = this.state && this.state.muted
    if (this.muted || serverMuted) el.textContent = "mic muted (TTS playing)"
    else if (this.armed) el.textContent = "mic: listening"
    else el.textContent = "mic: not armed"
  },

  _setArming(ms) {
    if (this._timers.arming) {
      clearInterval(this._timers.arming)
      this._timers.arming = null
    }
    const chip = this._el("[data-voice-arming]")
    if (ms == null) {
      this._hide(chip)
      return
    }
    const deadline = performance.now() + ms
    const tick = () => {
      const remaining = deadline - performance.now()
      if (remaining <= 0) {
        clearInterval(this._timers.arming)
        this._timers.arming = null
        this._hide(this._el("[data-voice-arming]"))
        return
      }
      const box = this._el("[data-voice-arming-ms]")
      if (box) box.textContent = `${(remaining / 1000).toFixed(1)}s`
    }
    this._show(chip)
    tick()
    this._timers.arming = setInterval(tick, 50)
  },

  _onSegmentResult(result) {
    this._setAsrBusy(this._inFlight - 1)
    // A spoken "orca cancel" clears the draft server-side; the sink has to be
    // told explicitly (_renderDraft refuses to empty a non-empty box).
    if (result && result.action === "cancel") this._writeDraft("")
    this._appendLog(result)
  },

  _appendLog(result) {
    const log = this._el("[data-voice-log]")
    if (!log) return
    const li = document.createElement("li")
    li.dataset.voiceSeq = result.seq
    li.dataset.voiceAction = result.action || ""
    const bits = [`#${result.seq}`]
    if (result.text) bits.push(`“${result.text}”`)
    bits.push(`→ ${result.action}`)
    if (result.detail) bits.push(`(${result.detail})`)
    if (typeof result.duration === "number") bits.push(`${result.duration.toFixed(2)}s audio`)
    if (typeof result.elapsed_seconds === "number")
      bits.push(`${result.elapsed_seconds.toFixed(2)}s asr`)
    if (result.intent) bits.push(`intent=${result.intent}@${(result.score || 0).toFixed(2)}`)
    li.textContent = bits.join("  ")
    log.appendChild(li)
    while (log.children.length > LOG_LIMIT) log.removeChild(log.firstChild)
    log.scrollTop = log.scrollHeight
  },

  /** Everything the hook writes lives inside `#voice-strip`, which LiveView
   * only renders while voice mode is on — so every lookup is lazy and every
   * writer tolerates a null. */
  _el(selector) {
    return this.el.querySelector(selector)
  },

  _setStatusText(text) {
    const el = this._el("[data-voice-status]")
    if (el) el.textContent = text
  },

  _showBanner(text) {
    const el = this._el("[data-voice-banner]")
    if (!el) return
    el.textContent = text
    this._show(el)
  },

  _showError(text) {
    const el = this._el("[data-voice-error]")
    if (!el) return
    el.textContent = text
    el.title = "Click to retry the transcription warm-up"
    this._show(el)
  },

  _hideError() {
    this._hide(this._el("[data-voice-error]"))
  },

  _show(el) {
    if (el) el.classList.remove("hidden")
  },

  _hide(el) {
    if (el) el.classList.add("hidden")
  },

  // --------------------------------------------------------------------- DOM

  _bindDom() {
    this._onClick = (e) => {
      const target = e.target.closest("[data-voice-action]")
      if (target) {
        const action = target.dataset.voiceAction
        // "send"/"cancel" have no buttons any more (the composer's Send and a
        // select-all-delete do those jobs), but both remain §8.1 events and
        // both are still pushed from elsewhere in this hook.
        if (action === "toggle") this._toggle()
        else if (action === "send") this.channel && this.channel.push("send_now", {})
        else if (action === "cancel") {
          this._setArming(null)
          this._writeDraft("")
          this.channel && this.channel.push("cancel", {})
        } else if (action === "start") this._arm()
        else if (action === "retry") this.channel && this.channel.push("retry_warmup", {})
        return
      }
      const error = this._el("[data-voice-error]")
      if (error && error.contains(e.target)) {
        this.channel && this.channel.push("retry_warmup", {})
      }
    }
    this.el.addEventListener("click", this._onClick)

    // DELEGATED, on the document, because the sink is not one fixed element
    // any more: it moves between the bar's own box and whichever composer the
    // current page renders. A per-element listener would have to be rebound
    // on every navigation and would leak one per page.
    this._onDocInput = (e) => {
      // Our own _writeDraft dispatches `input` to drive Autocomplete's
      // autoresize; that is not a user edit and must not echo back.
      if (this._applyingDraft) return
      if (!this.channel || e.target !== this._draftEl()) return
      this._clearDraftTimer()
      this._timers.draft = setTimeout(() => {
        this._timers.draft = null
        const el = this._draftEl()
        this._setArming(null)
        this.channel && this.channel.push("draft_edit", { text: el ? el.value : "" })
      }, DRAFT_DEBOUNCE_MS)
    }
    document.addEventListener("input", this._onDocInput, true)
  },

  /** Every listener is on `window`, because nothing the bar reacts to is
   * inside its own LiveView:
   *
   *   phx:clear-prompt       SessionLive.Show's success push (see above)
   *   phx:voice-send-failed  ...and its failure counterpart
   *   phx:voice-target       the session page announcing itself on mount
   *   phx:page-loading-stop  the end of a live navigation
   *   orca:tts-state         half-duplex, §8.1
   *   orca:composer-*        optional aliases, in case a future page wants to
   *                          report a send that is not a `clear-prompt`
   */
  _bindWindow() {
    this._onTtsState = (e) => this._handleTtsState(e)
    this._onVoiceTarget = (e) => {
      const d = (e && e.detail) || {}
      const id = d.sessionId || d.session_id
      if (id && id !== this.target) this.pushEvent("voice-target", { session_id: id })
    }
    this._onSent = (e) => this._onComposerSent(e)
    this._onSendFailed = (e) => this._onComposerSendFailed(e)
    // LiveView fires this at the end of every live navigation, which is
    // exactly when the composer (and therefore the sink) appears or vanishes.
    this._onPageLoaded = () => this._syncPage()

    this._windowEvents = [
      ["orca:tts-state", this._onTtsState],
      ["phx:voice-target", this._onVoiceTarget],
      ["orca:voice-target", this._onVoiceTarget],
      ["phx:clear-prompt", this._onSent],
      ["orca:composer-sent", this._onSent],
      ["phx:voice-send-failed", this._onSendFailed],
      ["orca:composer-send-failed", this._onSendFailed],
      ["phx:page-loading-stop", this._onPageLoaded],
    ]
    this._windowEvents.forEach(([name, fn]) => window.addEventListener(name, fn))
  },

  _unbindWindow() {
    ;(this._windowEvents || []).forEach(([name, fn]) => window.removeEventListener(name, fn))
    this._windowEvents = []
  },

  /** `body[data-voice-composer-for]` is the session page announcing itself.
   * Watching the attribute directly means auto-follow survives a missed
   * push_event and works for any future page that wants a composer. */
  _observeBody() {
    if (typeof MutationObserver === "undefined") return
    this._bodyObserver = new MutationObserver(() => this._syncPage())
    this._bodyObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ["data-voice-composer-for"],
    })
  },

  /** The per-segment log is collapsed by default; the strip is
   * phx-update="ignore", so the disclosure is native <details> and only its
   * remembered open state is ours. Idempotent: the strip appears and
   * disappears with voice mode. */
  _bindLogToggle() {
    const details = this._el("[data-voice-log-details]")
    if (!details || details.dataset.voiceBound === "1") return
    details.dataset.voiceBound = "1"
    try {
      if (window.localStorage.getItem(LOG_OPEN_KEY) === "1") details.open = true
    } catch (_e) {
      /* private mode / storage disabled — default closed is fine */
    }
    details.addEventListener("toggle", () => {
      try {
        window.localStorage.setItem(LOG_OPEN_KEY, details.open ? "1" : "0")
      } catch (_e) {
        /* ignore */
      }
    })
  },

  /** Snapshot for the headless capture check and for eyeballing in the
   * console. `ctx` is the live AudioContext object itself: the phase-2
   * navigation check asserts its IDENTITY is unchanged across pages. */
  stats() {
    return {
      ...this.metrics,
      active: this.active,
      armed: this.armed,
      muted: this.muted,
      target: this.target,
      composerPresent: this.composerPresent,
      asrBusy: this._asrBusy,
      frameSamples: FRAME_SAMPLES,
      vadSettings: VAD_SETTINGS,
      vadFramesProcessed: this.vad ? this.vad.framesProcessed : 0,
      vadMaxBacklog: this.vad ? this.vad.maxBacklog : 0,
      channelJoined: this.channel ? this.channel.joined() : false,
      ctx: this.capture ? this.capture.ctx : null,
      state: this.state,
    }
  },
}

export default VoiceHook
