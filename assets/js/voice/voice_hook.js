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
 *
 * 6. UI CONTROL (§8.3, ORCAHUB3-87). Two new wire events, one each way:
 *
 *      -> ui_focus   {focus, candidates}  what the user is looking at
 *      <- ui_action  {kind, payload}      what to do about it
 *
 *    The CLIENT owns `focus` — the server never infers it. Everything the
 *    hook does here goes through a seam some other hook ALREADY binds, so a
 *    spoken command drives the exact code path a keyboard does: the
 *    palette's `command-palette:toggle` document event, its
 *    `phx-keyup="search"` input, the autocomplete dropdown's `mousedown`
 *    handler, the palette item's `phx-click="select"`, and — for navigation
 *    — a HIDDEN `<.link navigate>` in VoiceBarLive, because
 *    `window.location` would reload the document and take the mic, the
 *    AudioContext and the channel with it (§8.2).
 *
 * 7. LIFECYCLE, and why none of the above is enough on a phone
 *    (ORCAHUB3-91). Backgrounding a page takes the microphone AND the
 *    LiveView away, and neither loss reports itself:
 *
 *    - The OS suspends the AudioContext and can end or mute the track. No
 *      error is thrown, so `armed` alone is a LIE — everything the user sees
 *      is rendered from `_micLive()`, `Capture` reports the transitions, and
 *      `visibilitychange` repairs the pipeline in place (resume, else re-arm
 *      the stream) without touching the channel, the draft or the target.
 *    - The live socket drops (app.js force-reconnects after >10 s hidden),
 *      so `VoiceBarLive` RE-MOUNTS with no target and voice off, while this
 *      hook keeps both. `_restoreAfterRemount()` re-asserts them; read the
 *      comment there for why that cannot fight the target picker.
 *    - The voice channel rejoins by itself against a brand new server-side
 *      session, so `_onChannelRejoin()` re-sends what `_joinChannel` sends.
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
import * as Sounds from "./sounds"
import { persistSoundsEnabled, soundsEnabled, VoiceSounds } from "./sounds"

const DRAFT_DEBOUNCE_MS = 300
const LOG_LIMIT = 50
const LOG_OPEN_KEY = "orca:voice:log-open"

// §8.3.5/§8.3.9: focus + candidates are recomputed at most this often, and
// only ever pushed when the computed value actually changed.
const UI_SYNC_MS = 150
// The vocabulary only reaches "orca ninth" (§8.3.3), so a tenth candidate is
// unspeakable — do not spend wire bytes on it.
const MAX_CANDIDATES = 9
const LABEL_MAX = 80
const PALETTE_ITEM_PREFIX = "command-palette-item-"

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

/** The PRIMARY label of a selectable row, for §8.3.5's `candidates`.
 *
 * `textContent` of the whole row would glue the name to its subtitle and its
 * hint with no separator ("a sessionorca_hubarchived"), and §8.3.8 matches a
 * spoken name against that string with the spaces removed — so a subtitle
 * would quietly make every name unmatchable. Both lists we read (the palette
 * item and the autocomplete button) put the name FIRST and wrap it in its own
 * element, so the first non-empty text node's owner is exactly the label and
 * nothing else. Icons are inline SVG and contribute no text.
 */
function labelOf(el) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  let node
  while ((node = walker.nextNode())) {
    if (node.nodeValue && node.nodeValue.trim() !== "") {
      const owner = node.parentElement || el
      return owner.textContent.replace(/\s+/g, " ").trim().slice(0, LABEL_MAX)
    }
  }
  return ""
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
    // §8.3.5: the last {focus, candidates} we told the server about, as JSON,
    // so an unchanged recompute costs one string compare and no push.
    this._lastUi = null
    // ORCAHUB3-91: one mic-button press is spent on repairing a stopped
    // microphone; the next one turns voice off as usual. Cleared whenever the
    // microphone is actually capturing again.
    this._repairAttempted = false

    this._bindSounds()
    this._bindDom()
    this._bindWindow()
    this._observeBody()
    this._syncPage()

    if (typeof window !== "undefined") {
      window.__orcaVoice = this
      // ORCAHUB3-93's measurement seam, exposed for the same reason
      // `__orcaVoice` is: the headless VAD check has to render the SHIPPED
      // graph through an OfflineAudioContext to build the microphone file it
      // feeds back in, and a check that renders anything but this module's
      // own builders would prove nothing about what users hear.
      window.__orcaVoiceSounds = Sounds
    }
  },

  /** ORCAHUB3-93's two cues, and the one round-trip that persists the
   * preference.
   *
   * The preference lives in `localStorage` (the bar is re-mounted on every
   * reconnect, so a plain socket assign would reset it) and is hydrated into
   * VoiceBarLive exactly the way `orca:tts-autoplay` / `orca:tts-stream` are:
   * client reads it, pushes an init, and writes back whatever the server
   * echoes. The difference is the DEFAULT — absent means ON here, because
   * these sounds only ever follow a send the user asked for out loud.
   *
   * `voice-turn` is the target session's own turn state, pushed by
   * VoiceBarLive from the `session:<id>` topic. It has to come from the
   * SERVER rather than from anything on screen: the bar is global, and the
   * session being dictated at is very often not the page being looked at. */
  _bindSounds() {
    this.sounds = new VoiceSounds({ enabled: soundsEnabled() })
    this.pushEvent("voice-sounds-init", { enabled: this.sounds.enabled })
    this.handleEvent("voice-sounds-persisted", ({ enabled }) => {
      this.sounds.setEnabled(enabled)
      persistSoundsEnabled(enabled)
    })
    this.handleEvent("voice-turn", ({ session_id, answering }) => {
      // Scoped defensively: VoiceBarLive only ever subscribes to the current
      // target, but a retarget and an in-flight broadcast can cross.
      if (session_id && this.target && session_id !== this.target) return
      if (answering) this.sounds.stopWaiting()
    })
  },

  /** The bar re-rendered: the target may have changed (picker or page), and
   * the strip may have just been inserted. */
  updated() {
    const next = this.el.dataset.targetSessionId || null
    if (next === null && this.target !== null) {
      this._restoreAfterRemount()
    } else if (next !== this.target) {
      const carried = this._currentDraftText()
      this.target = next
      this._retarget(carried)
    }
    this._bindLogToggle()
    this._syncPage()
    this._renderMic()
  },

  /** The bar's LiveView rejoined after a dropped socket (ORCAHUB3-91).
   *
   * Belt and braces for `updated()`'s restore: `reconnected()` fires at the
   * end of every rejoin regardless of what the patch happened to touch, and
   * `_restoreAfterRemount` is idempotent, so calling both is free. */
  reconnected() {
    this._restoreAfterRemount()
  },

  /** Sticky: this only fires on a full page reload, never on navigation. */
  destroyed() {
    this._unbindWindow()
    this.el.removeEventListener("click", this._onClick)
    if (this._bodyObserver) {
      this._bodyObserver.disconnect()
      this._bodyObserver = null
    }
    if (this._onDocInput) document.removeEventListener("input", this._onDocInput, true)
    this._teardown()
    if (this.sounds) this.sounds.destroy()
    if (window.__orcaVoice === this) delete window.__orcaVoice
  },

  // ------------------------------------------------------------- voice mode

  /** The mic button: the user gesture that satisfies the autoplay policy. */
  async _toggle() {
    if (this.active) {
      // ORCAHUB3-91: voice is on but the microphone has stopped (the screen
      // was off), and the strip the user is reading says "tap the mic to
      // resume" — so REPAIR on this press instead of switching voice off.
      // Turning it off and back on is exactly the two-press dance the old
      // `armed` latch forced. One attempt only: if the repair did not take,
      // the next press does the ordinary thing and turns voice off, so a mic
      // that is permanently gone can never trap the button.
      if (!this._micLive() && !this._repairAttempted) {
        this._repairAttempted = true
        return this._reconcileMic()
      }
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
    // Voice off is not "the answer arrived", but it IS the end of the thing
    // the tick was reporting on, and a bar with no mic must make no noise.
    this.sounds && this.sounds.stopWaiting()
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
    // A teardown is the END of voice mode, so say so here rather than relying
    // on every caller to remember: a stale `active` left `_retarget` and the
    // liveness repair running against a pipeline that no longer exists.
    this.active = false
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
      onUiAction: (m) => this._onUiAction(m),
      onRejoin: () => this._onChannelRejoin(),
      onDisconnect: () => this._onChannelDisconnect(),
      onSent: () => {
        this._setArming(null)
        // The draft has been delivered and the server cleared its copy;
        // clear ours so the text cannot be sent twice.
        this._writeDraft("")
        // ORCAHUB3-93. `"sent"` is CONFIRMED DELIVERY — the server pushes it
        // only after the composer's `clear-prompt` (sent_ack) or after a
        // direct delivery returned :ok, never on recognising "orca send" and
        // never after `send_failed`. It is also the reason these sounds
        // cannot reach a TYPED send: a typed send produces `clear-prompt`
        // with no `_pendingSend`, which this hook answers with `"cancel"`,
        // so no `"sent"` is ever pushed back.
        this.sounds.sent()
        this.sounds.startWaiting()
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
    // ...and so is focus: §8.3.1 resets it to "composer" on join and on
    // retarget, so the server's belief starts from a blank slate and has to
    // be told what is actually on screen. Forced, not debounced — a join is
    // not a DOM change and there is nothing to coalesce.
    this._syncUiFocus(true)
    return true
  },

  /** Phoenix rejoined `voice:<target>` by itself after the shared socket came
   * back (ORCAHUB3-91). The server state is new; re-send the per-channel facts
   * `_joinChannel` normally sends, or the server keeps believing the page has
   * no composer and knows nothing about what is selectable on screen. */
  _onChannelRejoin() {
    this.metrics.joins++
    this._hideError()
    this._reportComposer(true)
    this._syncUiFocus(true)
    const el = this._draftEl()
    if (el && el.value !== "") this._pushDraftEdit(el.value)
    this._renderMic()
  },

  /** The channel dropped. Segments are discarded while it is down
   * (`_onSpeechEnd` refuses to push on a channel that is not joined), so say
   * so instead of looking like a working mic that transcribes nothing. */
  _onChannelDisconnect() {
    if (!this.active) return
    this._setStatusText("voice connection lost — reconnecting…")
  },

  /** Leave the old channel and join the new one. The mic, the AudioContext
   * and the VAD are NOT torn down (C4) — retargeting is routine. */
  async _retarget(carried) {
    this._setArming(null)
    this._pendingSend = null
    // The tick reports on ONE session's turn. Pointing the bar at a different
    // one means we are no longer waiting on the old answer and VoiceBarLive
    // has stopped listening for it, so the tick would never be stopped.
    this.sounds && this.sounds.stopWaiting()
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
    // `armed` alone is NOT a reason to refuse (ORCAHUB3-91): it used to be a
    // latch that only `_teardown()` cleared, so once the OS had taken the
    // microphone the only way back was voice-off-then-on — the two presses in
    // the report. Refuse only while genuinely capturing, so re-arming repairs.
    if (this._arming) return
    if (this.armed && this.capture && this.capture.live()) return
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
          onLiveness: (reason, live) => this._onLiveness(reason, live),
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

  // ------------------------------------------------------- liveness (3-91)

  /** Is the microphone ACTUALLY capturing? `armed` says "we finished arming
   * once"; this says "audio is flowing right now". Everything the user sees
   * is rendered from THIS, so the bar can no longer claim "mic: listening"
   * while zero frames arrive. */
  _micLive() {
    const live = !!(this.armed && this.capture && this.capture.live())
    if (live) this._repairAttempted = false
    return live
  },

  /** `Capture` observed the microphone go away (or come back). */
  _onLiveness(reason, live) {
    this._renderMic()
    if (!this.active) return
    if (live) {
      this._renderStatus()
      return
    }
    this._setStatusText(`${reason} — resuming…`)
    // A HIDDEN page is expected to lose the mic; that is the browser doing its
    // job, and re-acquiring a stream there can hang. The visibility handler
    // repairs it on the way back.
    if (typeof document !== "undefined" && document.visibilityState === "visible") {
      this._scheduleReconcile()
    }
  },

  /** Coalesce: a screen unlock can fire `statechange` and `unmute` together. */
  _scheduleReconcile() {
    if (this._timers.reconcile) return
    this._timers.reconcile = setTimeout(() => {
      this._timers.reconcile = null
      this._reconcileMic()
    }, 250)
  },

  /** Put the capture pipeline back into the state the UI claims it is in.
   *
   * Cheapest repair first: a merely SUSPENDED context keeps the worklet, the
   * ring buffer and the VAD session, so `resume()` costs nothing. A track the
   * OS ended cannot be revived, so the stream is rebuilt — but the channel,
   * the draft and the target are untouched: this is a re-arm, not a teardown.
   */
  async _reconcileMic() {
    if (!this.active || this._arming) return
    if (!this.capture) return this._arm()
    if (this.capture.live()) {
      this._renderMic()
      return
    }

    if (this.capture.ctx && this.capture.ctx.state === "suspended") {
      try {
        await this.capture.resume()
      } catch (_e) {
        /* needs a gesture — the mic button and the "Start listening" fallback
           are both still there, and `_arm` now repairs rather than refuse */
      }
    }

    if (this.capture.live()) {
      this._hide(this._el('[data-voice-action="start"]'))
      this._renderStatus()
      this._renderMic()
      return
    }

    this.armed = false
    if (this.vad) {
      this.vad.destroy()
      this.vad = null
    }
    const dead = this.capture
    this.capture = null
    this._renderMic()
    await dead.stop()
    await this._arm()
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

  // ------------------------------------------------- focus + candidates (§8.3)

  /** Everything on screen that a spoken ordinal could pick, in DOM order.
   *
   * §8.3.9 pins BOTH the rule and the order of preference: the palette wins
   * whenever it is open (it is a modal over everything else), and the
   * composer's autocomplete dropdown is consulted only when it is not.
   *
   * `index` is the index the CLIENT will act on, which is why it is read back
   * out of the DOM (the palette's `#command-palette-item-<i>` suffix, the
   * dropdown button's `data-index`) rather than being a position in this
   * array: those are the two attributes `_uiSelect` selects by, so reporting
   * anything else would let the server aim at a row we cannot click.
   */
  _uiState() {
    const palette = document.getElementById("command-palette-results")
    if (palette) {
      const items = palette.querySelectorAll(`[id^="${PALETTE_ITEM_PREFIX}"]`)
      return {
        focus: "palette",
        candidates: this._candidatesFrom(items, (el) => el.id.replace(PALETTE_ITEM_PREFIX, "")),
      }
    }
    const dropdown = document.querySelector("#autocomplete-dropdown:not(.hidden)")
    if (dropdown) {
      const items = dropdown.querySelectorAll("button[data-index]")
      return {
        focus: "composer",
        candidates: this._candidatesFrom(items, (el) => el.dataset.index),
      }
    }
    return { focus: "composer", candidates: [] }
  },

  _candidatesFrom(nodes, indexOf) {
    const out = []
    for (const el of nodes) {
      if (out.length >= MAX_CANDIDATES) break
      const index = parseInt(indexOf(el), 10)
      if (Number.isNaN(index)) continue
      out.push({ index, label: labelOf(el) })
    }
    return out
  },

  /** Recompute and push `ui_focus` — but only when it actually changed.
   *
   * `force` re-pushes an unchanged value, which only a join needs (the
   * server's copy is per channel and starts empty).
   */
  _syncUiFocus(force = false) {
    if (this._timers.ui) {
      clearTimeout(this._timers.ui)
      this._timers.ui = null
    }
    const ui = this._uiState()
    const json = JSON.stringify(ui)
    if (!force && json === this._lastUi) return
    if (!this.channel || !this.channel.joined()) {
      // Nowhere to push it yet. Leave `_lastUi` alone so the next join's
      // forced push is the first thing the server hears.
      return
    }
    this._lastUi = json
    this.channel.push("ui_focus", ui)
  },

  /** The DOM moved. Coalesce: at most one recompute per UI_SYNC_MS.
   *
   * Deliberately a trailing-edge THROTTLE rather than a restarting debounce.
   * The observer below watches `class` on every node in the body subtree, and
   * a streaming assistant reply mutates that many times a second — a
   * restarting debounce would be starved by exactly the page voice mode is
   * most often used on, and the palette would open with the server still
   * believing focus is "composer".
   */
  _scheduleUiSync() {
    if (this._timers.ui) return
    this._timers.ui = setTimeout(() => {
      this._timers.ui = null
      this._syncUiFocus()
    }, UI_SYNC_MS)
  },

  // ----------------------------------------------------------- ui_action (§8.3.9)

  /** The server asked us to drive the UI. Also the test seam for this slice:
   * `window.__orcaVoice._onUiAction({kind: "open_palette", payload: {}})`. */
  _onUiAction(msg) {
    const kind = (msg && msg.kind) || ""
    const payload = (msg && msg.payload) || {}
    let outcome
    switch (kind) {
      case "open_palette":
        outcome = this._togglePalette(true)
        break
      case "close_palette":
        outcome = this._togglePalette(false)
        break
      case "palette_query":
        outcome = this._paletteQuery(payload.text || "")
        break
      case "select":
        outcome = this._uiSelect(payload)
        break
      case "navigate":
        outcome = this._uiNavigate(payload.path || "")
        break
      case "back":
        // LiveView owns the popstate for a live-navigated page, so this
        // unwinds inside the same document — the bar survives it.
        window.history.back()
        outcome = { result: "ok", detail: "history.back()" }
        break
      case "open_help":
        outcome = this._toggleHelp(true)
        break
      default:
        outcome = { result: "error", detail: "unknown kind" }
    }
    this._logUiAction(kind, outcome)
    // The palette opens/closes and the query lands through the SERVER, so the
    // DOM change is a round-trip away; the body observer will catch it. This
    // is belt and braces for the same-tick cases (a dropdown selection).
    this._scheduleUiSync()
  },

  _paletteOpen() {
    return !!document.getElementById("command-palette-results")
  },

  /** Open/close through the one seam `CommandPalette` already binds
   * (`document.addEventListener("command-palette:toggle")`, which the header's
   * search button also dispatches) — so voice and the keyboard cannot drift.
   * It is a TOGGLE, so both directions are no-ops when already there. */
  _togglePalette(open) {
    if (this._paletteOpen() === open) {
      return { result: "noop", detail: `already ${open ? "open" : "closed"}` }
    }
    document.dispatchEvent(new CustomEvent("command-palette:toggle"))
    return { result: "ok" }
  },

  /** §8.3.10's panel is server-rendered, so its existence in the DOM IS the
   * open/closed state — `VoiceBarLive` only renders `#voice-help` while
   * `help_open` is true. */
  _helpOpen() {
    return !!document.getElementById("voice-help")
  },

  /** Open/close the help panel through the trigger the bar already renders
   * beside the mic (`phx-click="toggle_help"`), for the same reason
   * `_togglePalette` goes through the palette's own event: one code path, so
   * spoken and clicked cannot drift. It is a TOGGLE, hence the guard — a
   * second "orca help menu" while the panel is open must leave it open, not
   * close it. The trigger only exists while voice is on, which a spoken
   * command implies. */
  _toggleHelp(open) {
    if (this._helpOpen() === open) {
      return { result: "noop", detail: `already ${open ? "open" : "closed"}` }
    }
    const trigger = document.querySelector("[data-voice-help-toggle]")
    if (!trigger) return { result: "noop", detail: "no help trigger" }
    trigger.click()
    return { result: "ok" }
  },

  /** REPLACE semantics (§8.3.5): each utterance replaces the whole query, so
   * a spoken correction never accumulates on top of the misheard one.
   *
   * `input` alone would resize/autocomplete but reach no server handler — the
   * palette listens on `phx-keyup="search"`, so the keyup is the event that
   * actually does the work. Both bubble, as `clear-command-palette-input`
   * already relies on in app.js.
   */
  _paletteQuery(text) {
    const input = document.getElementById("command-palette-input")
    if (!input) return { result: "noop", detail: "palette not open" }
    input.value = text
    input.dispatchEvent(new Event("input", { bubbles: true }))
    input.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true }))
    return { result: "ok", detail: `“${text}”` }
  },

  /** §8.3.9: resolve to a 0-based index, then apply it to the ACTIVE list —
   * the composer's autocomplete dropdown first, else the palette.
   *
   * Each list is poked through the handler it already has, not a re-
   * implementation of what selecting means: `mousedown` for the dropdown
   * (`Autocomplete.renderDropdown` binds exactly that, because a `click`
   * would land after the textarea's blur has already hidden the list), and a
   * real `.click()` for the palette, which carries `phx-click="select"` with
   * its `phx-value-index` to the LiveComponent.
   */
  _uiSelect(payload) {
    const index =
      typeof payload.ordinal === "number"
        ? payload.ordinal - 1
        : typeof payload.index === "number"
          ? payload.index
          : null
    if (index == null || index < 0 || !Number.isInteger(index))
      return { result: "error", detail: "no usable index" }

    const button = document.querySelector(
      `#autocomplete-dropdown:not(.hidden) button[data-index="${index}"]`
    )
    if (button) {
      button.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }))
      return { result: "ok", detail: `autocomplete #${index} “${labelOf(button)}”` }
    }

    const item = this._paletteOpen() && document.getElementById(PALETTE_ITEM_PREFIX + index)
    if (item) {
      const label = labelOf(item)
      item.click()
      return { result: "ok", detail: `palette #${index} “${label}”` }
    }

    return { result: "noop", detail: `nothing selectable at #${index}` }
  },

  /** MUST live-navigate (§8.3.9). `window.location` — or a plain `<a href>` —
   * is a document reload, and a document reload takes the bar, the mic, the
   * AudioContext and the channel with it (§8.2). So the bar renders one
   * hidden `<.link navigate>` per path in the fixed set and we click THAT:
   * LiveView's window-level click listener sees `data-phx-link="redirect"`,
   * preventDefaults the anchor's own activation and routes it through the
   * live socket, which a hidden anchor does just as well as a visible one.
   *
   * A missing anchor is a no-op ON PURPOSE. Falling back to
   * `window.location` would "work" once and silently kill voice mode. */
  _uiNavigate(path) {
    if (!path) return { result: "error", detail: "no path" }
    const anchor = document.querySelector(`[data-voice-nav="${esc(path)}"]`)
    if (!anchor) return { result: "noop", detail: `no live-nav anchor for ${path}` }
    anchor.click()
    return { result: "ok", detail: path }
  },

  /** One line per ui_action in the same log the segment results use, so the
   * integration slice can assert on what the browser actually did rather than
   * on what the server thought it asked for. */
  _logUiAction(kind, { result, detail } = {}) {
    const log = this._el("[data-voice-log]")
    if (!log) return
    const li = document.createElement("li")
    li.dataset.voiceUiAction = kind
    li.dataset.voiceUiResult = result || ""
    const bits = [`ui_action ${kind}`, `→ ${result}`]
    if (detail) bits.push(`(${detail})`)
    li.textContent = bits.join("  ")
    log.appendChild(li)
    while (log.children.length > LOG_LIMIT) log.removeChild(log.firstChild)
    log.scrollTop = log.scrollHeight
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

  /** What the SERVER currently believes about voice mode, read back out of
   * its own render (`aria-pressed` on the mic button). */
  _serverVoiceOn() {
    const btn = this._el('[data-voice-action="toggle"]')
    return !!btn && btn.getAttribute("aria-pressed") === "true"
  },

  /** ORCAHUB3-91 — re-assert our state after `VoiceBarLive` re-mounted.
   *
   * A dropped LiveView socket (a phone unlocking does it every time: app.js
   * force-reconnects after >10 s hidden) re-runs `VoiceBarLive.mount/3`, which
   * starts from `target_session_id: nil` and `voice_on: false`. Sticky
   * survives NAVIGATION, not socket loss. The hook is the only place the
   * target still exists at that moment, and neither path that could announce
   * it fires: `_syncPage`'s auto-follow is gated on the PAGE's session having
   * changed (it has not), and the session page's own `voice-target` push is
   * gated on it differing from `this.target` (it does not). So without this
   * the two halves silently disagree until a full page reload.
   *
   * An absent `data-target-session-id` after we held one is unambiguous:
   * `VoiceBarLive` has NO path that clears a target once set — both
   * `voice-target` and `set_target` require a binary id and no-op otherwise
   * (voice_bar_live.ex) — so the only way the attribute can vanish is a fresh
   * mount.
   *
   * Why this cannot re-open the fight the change-only rule exists to prevent
   * (spec §8.2: "an unconditional sync fights the picker"): that bug was the
   * PAGE's session id being pushed on every sync, which snapped the target
   * back to the page on screen the instant the user picked a different session
   * in the picker. This pushes `this.target` — the value the picker itself
   * last produced, since a manual pick travels server -> `data-target-session-
   * id` -> `updated()` -> `this.target`. Restoring it re-states the user's own
   * choice; it can never out-vote it. `_syncPage`'s gate is untouched.
   *
   * Idempotent on purpose: once the server answers, the DOM matches and a
   * second call pushes nothing, so `updated()` and `reconnected()` can both
   * call it during the same rejoin.
   */
  _restoreAfterRemount() {
    if (this.target && !(this.el.dataset.targetSessionId || null)) {
      this.pushEvent("voice-target", { session_id: this.target })
    }
    // The strip, the picker, the §8.3.9 nav anchors and the error box all hang
    // off `voice_on`, so a bar that thinks voice is off while the mic is still
    // capturing is not merely cosmetic: a spoken "orca sessions" finds no
    // `data-voice-nav` anchor and silently does nothing.
    if (this.active !== this._serverVoiceOn()) {
      this.pushEvent("voice-on", { on: this.active })
    }
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
    // Live navigation swaps the whole page under the bar, so whatever was
    // selectable a moment ago almost certainly is not any more.
    this._scheduleUiSync()
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
    this._renderStatus()

    if (state.error) this._showError(state.error)
    else this._hideError()

    this._renderDraft(state.draft || "")
    this._syncBarBox()
    this._setArming(state.arming_ms)
    this._renderMic()
  },

  /** The server's own status line. Also how a local, transient message (a
   * microphone that stopped) is taken back down once the pipeline is well
   * again, without inventing a second source of truth for the text. */
  _renderStatus() {
    if (!this.state) return
    const label = STATUS_LABEL[this.state.status] || this.state.status
    const pending = this.state.pending > 0 ? ` (${this.state.pending} in flight)` : ""
    this._setStatusText(label + pending)
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
    else if (this._micLive()) el.textContent = "mic: listening"
    // ORCAHUB3-91: armed-but-not-live is the state that used to render as
    // "listening" while nothing was being captured.
    else if (this.armed) el.textContent = "mic: stopped — tap the mic to resume"
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
   *   visibilitychange       ORCAHUB3-91 — the screen came back on
   *   pageshow               ...and the bfcache restore that fires instead
   *
   * `visibilitychange` is dispatched at `document` and BUBBLES, so a window
   * listener sees it (Phoenix's own socket binds it the same way) and it is
   * unbound with all the others in `_unbindWindow`.
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
    // The screen came back on. The AudioContext may be suspended and the
    // track may have been ended or muted while we were away, so re-derive
    // what the pipeline is actually doing instead of trusting `armed`.
    this._onVisible = () => {
      if (typeof document === "undefined" || document.visibilityState === "visible") {
        this._reconcileMic()
      }
    }

    this._windowEvents = [
      ["orca:tts-state", this._onTtsState],
      ["phx:voice-target", this._onVoiceTarget],
      ["orca:voice-target", this._onVoiceTarget],
      ["phx:clear-prompt", this._onSent],
      ["orca:composer-sent", this._onSent],
      ["phx:voice-send-failed", this._onSendFailed],
      ["orca:composer-send-failed", this._onSendFailed],
      ["phx:page-loading-stop", this._onPageLoaded],
      ["visibilitychange", this._onVisible],
      ["pageshow", this._onVisible],
    ]
    this._windowEvents.forEach(([name, fn]) => window.addEventListener(name, fn))
  },

  _unbindWindow() {
    ;(this._windowEvents || []).forEach(([name, fn]) => window.removeEventListener(name, fn))
    this._windowEvents = []
  },

  /** ONE observer, two jobs.
   *
   * 1. `body[data-voice-composer-for]` is the session page announcing itself.
   *    Watching the attribute directly means auto-follow survives a missed
   *    push_event and works for any future page that wants a composer.
   * 2. §8.3.9's focus/candidate tracking. The palette is INSERTED and REMOVED
   *    (`:if={@open}`, a childList change deep in the body) and the
   *    autocomplete dropdown is shown by dropping one `hidden` CLASS — so the
   *    subtree has to be watched for both, which is why the filter grew a
   *    `class` and the config grew `childList`/`subtree`.
   *
   * A second observer would have been simpler to read, but `observe()` on a
   * node already registered REPLACES its options rather than adding to them,
   * so the two configs have to be one config on one observer.
   *
   * Job 1 is guarded by the cached page target rather than by scanning the
   * records: with a subtree observer those records now arrive in the hundreds
   * on a streaming session page, and `_syncPage` must keep firing exactly
   * when it did before — when the page's session actually changes.
   */
  _observeBody() {
    if (typeof MutationObserver === "undefined") return
    this._bodyObserver = new MutationObserver(() => {
      if ((document.body.dataset.voiceComposerFor || null) !== this._lastPageTarget) {
        this._syncPage()
      }
      this._scheduleUiSync()
    })
    this._bodyObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ["data-voice-composer-for", "class"],
      childList: true,
      subtree: true,
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
      // ORCAHUB3-91: `armed` is "we finished arming once", `micLive` is "audio
      // is flowing right now". The browser check asserts on the second.
      micLive: this._micLive(),
      captureLive: this.capture ? this.capture.live() : false,
      ctxState: this.capture && this.capture.ctx ? this.capture.ctx.state : null,
      trackState: this.capture && this.capture.track ? this.capture.track.readyState : null,
      serverVoiceOn: this._serverVoiceOn(),
      domTarget: this.el.dataset.targetSessionId || null,
      muted: this.muted,
      target: this.target,
      composerPresent: this.composerPresent,
      asrBusy: this._asrBusy,
      frameSamples: FRAME_SAMPLES,
      vadSettings: VAD_SETTINGS,
      vadFramesProcessed: this.vad ? this.vad.framesProcessed : 0,
      vadMaxBacklog: this.vad ? this.vad.maxBacklog : 0,
      channelJoined: this.channel ? this.channel.joined() : false,
      // ORCAHUB3-93: what the two cues have actually done. The headless VAD
      // measurement asserts on `sounds.ticks` against `segment_result`.
      sounds: this.sounds
        ? { enabled: this.sounds.enabled, waiting: this.sounds.waiting, ...this.sounds.stats }
        : null,
      // §8.3: what the browser believes is on screen right now, and what it
      // last told the server. A numeric check has something to assert on.
      ui: this._uiState(),
      uiReported: this._lastUi ? JSON.parse(this._lastUi) : null,
      ctx: this.capture ? this.capture.ctx : null,
      state: this.state,
    }
  },
}

export default VoiceHook
