/* The browser capture path: getUserMedia -> AudioContext -> orca-capture
 * worklet. One capture path for the whole feature — the VAD is driven from the
 * very frames we ship (see vad.js), so there is no second resampler and no
 * chance of the VAD and the server disagreeing about what was said.
 */

import { captureWorkletUrl } from "./paths"

export const TARGET_RATE = 16000
export const FRAME_SAMPLES = 512 // Silero v5: 512 samples = 32 ms
export const MS_PER_FRAME = (FRAME_SAMPLES / TARGET_RATE) * 1000

/* Spec section 4: the browser's AEC/NS/AGC, explicitly requested. `channelCount`
 * pinned to 1 and `voiceIsolation` pinned to FALSE rather than inherited —
 * where it exists it is a third processing stage alongside NS and AEC and can
 * distort speech. */
export const AUDIO_CONSTRAINTS = {
  echoCancellation: true,
  noiseSuppression: true,
  autoGainControl: true,
  channelCount: 1,
  voiceIsolation: false,
}

export function secureContextProblem() {
  if (typeof window === "undefined") return null
  if (!window.isSecureContext || !navigator.mediaDevices) {
    return (
      "Voice mode needs a secure context. navigator.mediaDevices is unavailable on " +
      `${window.location.origin} — use https://, or http://localhost. ` +
      "A LAN IP on plain http will never work (no error is thrown, the API is simply absent)."
    )
  }
  return null
}

export class Capture {
  constructor({ prerollMs = 500, onFrame, onProcessorError, onLiveness } = {}) {
    this.prerollMs = prerollMs
    this.onFrame = onFrame || (() => {})
    this.onProcessorError = onProcessorError || (() => {})
    this.onLiveness = onLiveness || (() => {})
    this.stream = null
    this.track = null
    this.ctx = null
    this.node = null
    this.source = null
    this.sink = null
    this.ready = null // the worklet's "ready" message
    this.trackSettings = null
    this.framesSeen = 0
    this._pending = new Map()
    this._seq = 0
    this._closing = false
  }

  /** Opens the mic and the AudioContext. Does NOT start the worklet — call
   * `start()` once the context is actually running (autoplay policy). */
  async open() {
    const problem = secureContextProblem()
    if (problem) throw new Error(problem)

    this.stream = await navigator.mediaDevices.getUserMedia({ audio: AUDIO_CONSTRAINTS })
    const track = this.stream.getAudioTracks()[0]
    this.track = track || null
    this.trackSettings = track && track.getSettings ? track.getSettings() : {}
    this._watchTrack(track)

    // Never force a sampleRate: the context negotiates its own and the browser
    // resamples the track into it. The worklet reads whatever it gets.
    this.ctx = new AudioContext()
    this.ctx.onstatechange = () =>
      this._liveness(`audio capture ${this.ctx ? this.ctx.state : "closed"}`)
    try {
      await this.ctx.resume()
    } catch (_e) {
      /* resume() can reject before a gesture; the caller checks ctx.state */
    }
    return this.ctx.state
  }

  /* ORCAHUB3-91: the OS takes the microphone away WITHOUT an error. A phone
   * locking its screen suspends the AudioContext and can end or mute the
   * track; nothing throws, `getUserMedia` stays resolved, the promise that
   * `start()` returned stays resolved, and the worklet simply stops being
   * pulled. So liveness has to be OBSERVED — never inferred from the fact
   * that `start()` once succeeded. */
  _watchTrack(track) {
    if (!track) return
    track.onended = () => this._liveness("the microphone stopped")
    track.onmute = () => this._liveness("the microphone was muted by the system")
    track.onunmute = () => this._liveness("the microphone came back")
  }

  _liveness(reason) {
    if (this._closing) return
    this.onLiveness(reason, this.live())
  }

  /** Is audio ACTUALLY flowing right now? Three independent ways to lose it —
   * a suspended/closed context, a track the OS ended, a track the OS muted —
   * and the pipeline survives none of them. */
  live() {
    if (this.suspended()) return false
    if (!this.track) return false
    return this.track.readyState === "live" && !this.track.muted
  }

  suspended() {
    return !this.ctx || this.ctx.state !== "running"
  }

  async resume() {
    if (this.ctx) await this.ctx.resume()
    return this.ctx ? this.ctx.state : "closed"
  }

  async start() {
    if (this.node) return this.ready
    await this.ctx.audioWorklet.addModule(captureWorkletUrl())

    this.source = new MediaStreamAudioSourceNode(this.ctx, { mediaStream: this.stream })
    this.node = new AudioWorkletNode(this.ctx, "orca-capture", {
      numberOfInputs: 1,
      numberOfOutputs: 1,
      outputChannelCount: [1],
      channelCount: 1,
      channelCountMode: "explicit",
      channelInterpretation: "speakers",
      processorOptions: { frameSamples: FRAME_SAMPLES, prerollMs: this.prerollMs, taps: 63 },
    })

    // Trap 7: a throw inside process() kills the processor silently forever.
    // Surface it instead of shipping zero frames that look like a dead mic.
    this.node.onprocessorerror = () => {
      this.onProcessorError(
        "The audio capture worklet crashed (onprocessorerror) — no further audio will be " +
          "captured. Turn voice mode off and on again."
      )
    }

    const readyPromise = new Promise((resolve) => {
      this._resolveReady = resolve
    })

    this.node.port.onmessage = (e) => {
      const m = e.data
      if (!m) return
      if (m.type === "frame") {
        this.framesSeen++
        this.onFrame(m)
      } else if (m.type === "ready") {
        this.ready = m
        this._resolveReady && this._resolveReady(m)
      } else if (m.type === "history" || m.type === "stats") {
        const w = this._pending.get(m.id)
        if (w) {
          this._pending.delete(m.id)
          w(m)
        }
      }
    }

    // Trap 8: with no path to ctx.destination the render graph never pulls the
    // node and process() never runs. A muted gain node is enough.
    this.sink = new GainNode(this.ctx, { gain: 0 })
    this.source.connect(this.node)
    this.node.connect(this.sink)
    this.sink.connect(this.ctx.destination)

    return readyPromise
  }

  _ask(msg, timeoutMs, fallback) {
    if (!this.node) return Promise.resolve(fallback)
    const id = ++this._seq
    return new Promise((resolve) => {
      this._pending.set(id, resolve)
      this.node.port.postMessage({ ...msg, id })
      setTimeout(() => {
        if (this._pending.delete(id)) resolve(fallback)
      }, timeoutMs)
    })
  }

  /** The `samples` 16 kHz samples immediately before absolute index `endSample`. */
  async history(endSample, samples) {
    const m = await this._ask({ cmd: "history", endSample, samples }, 1000, null)
    return m && m.samples ? m.samples : new Float32Array(0)
  }

  stats() {
    return this._ask({ cmd: "stats" }, 1000, null)
  }

  get sampleRate() {
    return this.ctx ? this.ctx.sampleRate : null
  }

  get ratio() {
    return this.ctx ? this.ctx.sampleRate / TARGET_RATE : null
  }

  async stop() {
    // Tearing down fires `statechange` (and can fire `ended`); those are our
    // own doing, not the OS taking the mic away, so they must not reach the
    // liveness callback and trigger a repair of something we are closing.
    this._closing = true
    if (this.ctx) this.ctx.onstatechange = null
    if (this.track) {
      this.track.onended = null
      this.track.onmute = null
      this.track.onunmute = null
    }
    try {
      this.node && (this.node.port.onmessage = null)
      this.node && this.node.disconnect()
      this.source && this.source.disconnect()
      this.sink && this.sink.disconnect()
    } catch (_e) {
      /* already torn down */
    }
    if (this.stream) {
      this.stream.getTracks().forEach((t) => t.stop())
      this.stream = null
    }
    if (this.ctx && this.ctx.state !== "closed") {
      try {
        await this.ctx.close()
      } catch (_e) {
        /* already closed */
      }
    }
    this.node = null
    this.source = null
    this.sink = null
    this.ctx = null
    this.track = null
    this._pending.clear()
  }
}
