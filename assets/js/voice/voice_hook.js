/* LiveView hook `Voice` — the browser half of voice mode (spec section 10,
 * phase 1). Registered in assets/js/app.js as `Voice`.
 *
 * Pipeline, all of it inside this hook's lifetime:
 *
 *   getUserMedia (AEC/NS/AGC on, voiceIsolation off)
 *     -> AudioContext at whatever rate it negotiates
 *     -> orca-capture worklet: ctx.sampleRate -> 16 kHz, 63-tap windowed-sinc
 *        LPF + fractional decimation, ring buffer keyed by ABSOLUTE 16 kHz index
 *     -> vad-web's FrameProcessor + Silero v5, fed OUR frames (see vad.js)
 *     -> onSpeechEnd -> OVS1 binary frame -> channel.push("segment", ...)
 *
 * The DOM is the pinned `[data-voice-*]` contract (spec 8.1); the panel carries
 * phx-update="ignore", so everything inside it is ours to write.
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

const STATUS_LABEL = {
  warming: "warming up transcription…",
  listening: "listening",
  transcribing: "transcribing…",
  arming: "sending shortly",
  sending: "sending…",
  error: "error",
}

export const VoiceHook = {
  mounted() {
    this.sessionId = this.el.dataset.sessionId
    this.armed = false
    this.muted = false
    this.state = null
    this.metrics = {
      sampleRate: null,
      ratio: null,
      framesSeen: 0,
      vadInitMs: null,
      speechStarts: 0,
      segmentsSent: 0,
      misfires: 0,
      processorError: null,
      startedAt: Date.now(),
    }
    this._timers = {}
    this._els = {
      banner: this.el.querySelector("[data-voice-banner]"),
      status: this.el.querySelector("[data-voice-status]"),
      mic: this.el.querySelector("[data-voice-mic]"),
      error: this.el.querySelector("[data-voice-error]"),
      draft: this.el.querySelector("[data-voice-draft]"),
      arming: this.el.querySelector("[data-voice-arming]"),
      armingMs: this.el.querySelector("[data-voice-arming-ms]"),
      log: this.el.querySelector("[data-voice-log]"),
      start: this.el.querySelector('[data-voice-action="start"]'),
    }

    // Trap 1: no secure context means navigator.mediaDevices is simply absent,
    // with no error thrown. Say so loudly before anything else fails weirdly.
    const insecure = secureContextProblem()
    if (insecure) {
      this._showBanner(insecure)
      this._setStatusText("unavailable")
      return
    }

    this._bindDom()
    this._onTtsState = (e) => this._handleTtsState(e)
    window.addEventListener("orca:tts-state", this._onTtsState)

    if (typeof window !== "undefined") window.__orcaVoice = this

    this._connect()
  },

  destroyed() {
    if (this._onTtsState) window.removeEventListener("orca:tts-state", this._onTtsState)
    Object.values(this._timers).forEach((t) => {
      if (!t) return
      clearInterval(t)
      clearTimeout(t)
    })
    this._timers = {}
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
    if (window.__orcaVoice === this) delete window.__orcaVoice
  },

  // ------------------------------------------------------------------ channel

  async _connect() {
    this.channel = new VoiceChannel(this.sessionId, {
      onState: (s) => this._renderState(s),
      onSegmentResult: (r) => this._appendLog(r),
      onSent: () => this._setArming(null),
    })
    try {
      await this.channel.join()
    } catch (e) {
      this._showError(e.message)
      return
    }
    // Joining IS arming on the server (it fires the ASR warm-up immediately);
    // arm the browser half right away too, never on first speech — SPIKE 1
    // measured 499-809 ms of VAD session init.
    this._arm()
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
        this._show(this._els.start)
        this._setStatusText("click “Start listening” to arm the mic")
        return
      }
      this._hide(this._els.start)

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

  // ------------------------------------------------------------------ rendering

  _renderState(state) {
    this.state = state
    const label = STATUS_LABEL[state.status] || state.status
    const pending = state.pending > 0 ? ` (${state.pending} in flight)` : ""
    this._setStatusText(label + pending)

    if (state.error) this._showError(state.error)
    else this._hideError()

    this._renderDraft(state.draft || "")
    this._setArming(state.arming_ms)
    this._renderMic()
  },

  _renderDraft(text) {
    const el = this._els.draft
    if (!el) return
    // Never clobber what the user is mid-way through typing: while a
    // draft_edit is still debouncing, the local value is the newer truth.
    if (this._timers.draft) return
    if (el.value !== text) el.value = text
  },

  _renderMic() {
    const el = this._els.mic
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
    if (ms == null) {
      this._hide(this._els.arming)
      return
    }
    const deadline = performance.now() + ms
    const tick = () => {
      const remaining = deadline - performance.now()
      if (remaining <= 0) {
        clearInterval(this._timers.arming)
        this._timers.arming = null
        this._hide(this._els.arming)
        return
      }
      if (this._els.armingMs) this._els.armingMs.textContent = (remaining / 1000).toFixed(1)
    }
    this._show(this._els.arming)
    tick()
    this._timers.arming = setInterval(tick, 50)
  },

  _appendLog(result) {
    const log = this._els.log
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

  _setStatusText(text) {
    if (this._els.status) this._els.status.textContent = text
  },

  _showBanner(text) {
    if (!this._els.banner) return
    this._els.banner.textContent = text
    this._show(this._els.banner)
  },

  _showError(text) {
    if (!this._els.error) return
    this._els.error.textContent = text
    this._els.error.title = "Click to retry the transcription warm-up"
    this._show(this._els.error)
  },

  _hideError() {
    this._hide(this._els.error)
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
        if (action === "send") this.channel && this.channel.push("send_now", {})
        else if (action === "cancel") {
          this._setArming(null)
          this.channel && this.channel.push("cancel", {})
        } else if (action === "start") this._arm()
        else if (action === "retry") this.channel && this.channel.push("retry_warmup", {})
        return
      }
      if (this._els.error && this._els.error.contains(e.target)) {
        this.channel && this.channel.push("retry_warmup", {})
      }
    }
    this.el.addEventListener("click", this._onClick)

    if (this._els.draft) {
      this._onDraftInput = () => {
        if (this._timers.draft) clearTimeout(this._timers.draft)
        this._timers.draft = setTimeout(() => {
          this._timers.draft = null
          this._setArming(null)
          this.channel && this.channel.push("draft_edit", { text: this._els.draft.value })
        }, DRAFT_DEBOUNCE_MS)
      }
      this._els.draft.addEventListener("input", this._onDraftInput)
    }
  },

  /** Snapshot for the headless capture check and for eyeballing in the console. */
  stats() {
    return {
      ...this.metrics,
      armed: this.armed,
      muted: this.muted,
      frameSamples: FRAME_SAMPLES,
      vadSettings: VAD_SETTINGS,
      vadFramesProcessed: this.vad ? this.vad.framesProcessed : 0,
      vadMaxBacklog: this.vad ? this.vad.maxBacklog : 0,
      channelJoined: this.channel ? this.channel.joined() : false,
      state: this.state,
    }
  },
}

export default VoiceHook
