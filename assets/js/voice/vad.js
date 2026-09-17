/* Silero VAD via @ricky0123/vad-web, driven in NON-MIC mode.
 *
 * WHY NOT MicVAD: MicVAD owns getUserMedia, its own AudioContext, its own
 * resampling worklet and its own ScriptProcessor fallback. Handing it our
 * stream (`getStream`) still gives it its OWN resampler, so the audio the VAD
 * segments would no longer be bit-identical to the audio we ship to ASR — two
 * capture paths, two resamplers, two places for the ratio bug in spec section 9
 * trap 5 to hide. NonRealTimeVAD is offline-only (it consumes a whole buffer
 * through an async generator) and hardcodes the legacy 1536-sample model.
 *
 * So we use the layer underneath both of them, which vad-web exports as public
 * API: `FrameProcessor` (the speech state machine: thresholds, redemption,
 * pre-speech pad buffer, misfire rejection) driven by `Silero` (the v5 model
 * wrapper, including the 64-sample context carry that makes an onset straddling
 * a frame boundary still visible). We feed it the exact 512-sample 16 kHz
 * frames our own worklet produced. One capture path, library semantics intact.
 *
 * The deep imports below are deliberate: `@ricky0123/vad-web`'s root index does
 * not re-export `Silero`, and the package ships no "exports" map, so
 * dist/ subpaths are the supported way in. All of them `require()` the same
 * "onnxruntime-web/wasm" entry, so the bundle carries exactly one ort.
 */

import { FrameProcessor } from "@ricky0123/vad-web/dist/frame-processor"
import { Message } from "@ricky0123/vad-web/dist/messages"
import { Silero } from "@ricky0123/vad-web/dist/models"
import { ort } from "@ricky0123/vad-web/dist/real-time-vad"

import { FRAME_SAMPLES, MS_PER_FRAME, TARGET_RATE } from "./capture"
import { ortWasmPaths, sileroModelUrl } from "./paths"

/* Spec section 3.2, NORMATIVE. Every one of these overrides a vad-web default
 * (0.3 / 0.25 / 1400 / 800 / 400). The library defaults measured EOS 1376 ms,
 * twice this product's budget, and would silently discard a bare "stop"
 * (shorter than minSpeechMs 400). Do not drop back to the defaults. */
export const VAD_SETTINGS = {
  model: "v5",
  positiveSpeechThreshold: 0.5,
  negativeSpeechThreshold: 0.35,
  redemptionMs: 600,
  preSpeechPadMs: 500,
  minSpeechMs: 250,
}

/* Frames vad-web will prepend ahead of the onset, derived the way it derives
 * them internally (Math.floor(ms / msPerFrame)). */
export const PRE_SPEECH_PAD_SAMPLES =
  Math.floor(VAD_SETTINGS.preSpeechPadMs / MS_PER_FRAME) * FRAME_SAMPLES

let ortConfigured = false

function configureOrt() {
  if (ortConfigured) return
  ortConfigured = true
  ort.env.logLevel = "error"
  // Spec section 3.2: single-threaded, no COOP/COEP. Silero inference measured
  // p50 3.3-3.5 ms per 32 ms frame on ONE thread — ~9x headroom — so wasm
  // threads would only buy cross-origin isolation obligations on every asset.
  ort.env.wasm.numThreads = 1
  ort.env.wasm.proxy = false
  ort.env.wasm.wasmPaths = ortWasmPaths()
}

export class VadEngine {
  constructor(fp, model, opts) {
    this.fp = fp
    this.model = model
    this.opts = opts
    this.queue = []
    this.pumping = false
    this.paused = false
    this.destroyed = false
    this.speaking = false
    this.currentEnd = 0 // absolute 16 kHz index just past the frame in flight
    this.segStartEnd = 0 // currentEnd at the last SpeechStart
    this.maxSegmentSamples = opts.maxSegmentSamples || 0
    this.framesProcessed = 0
    this.maxBacklog = 0
    this._forced = false
  }

  /** Enqueue one 512-sample 16 kHz frame. `endSample` is its absolute index. */
  feed(samples, endSample) {
    if (this.destroyed || this.paused) return
    this.queue.push({ samples, endSample })
    if (this.queue.length > this.maxBacklog) this.maxBacklog = this.queue.length
    this._pump()
  }

  async _pump() {
    if (this.pumping) return
    this.pumping = true
    try {
      while (this.queue.length && !this.paused && !this.destroyed) {
        const { samples, endSample } = this.queue.shift()
        this.currentEnd = endSample
        await this.fp.process(samples, (ev) => this._handle(ev))
        this.framesProcessed++
        // Force-end BETWEEN process() calls, never from inside the event
        // handler: endSegment() clears the buffer process() is still using.
        if (
          this.speaking &&
          this.maxSegmentSamples &&
          this.currentEnd - this.segStartEnd + PRE_SPEECH_PAD_SAMPLES >= this.maxSegmentSamples
        ) {
          this.endSegment(true)
        }
      }
    } catch (e) {
      this.opts.onError && this.opts.onError(e)
    } finally {
      this.pumping = false
    }
  }

  /** Close the open segment now (the 18 s runaway split). */
  endSegment(forced) {
    if (!this.speaking) return
    this._forced = !!forced
    try {
      this.fp.endSegment((ev) => this._handle(ev))
    } finally {
      this._forced = false
    }
  }

  _handle(ev) {
    switch (ev.msg) {
      case Message.FrameProcessed:
        this.opts.onFrameProcessed &&
          this.opts.onFrameProcessed({ probs: ev.probs, endSample: this.currentEnd })
        break
      case Message.SpeechStart:
        this.speaking = true
        this.segStartEnd = this.currentEnd
        this.opts.onSpeechStart && this.opts.onSpeechStart({ endSample: this.currentEnd })
        break
      case Message.SpeechRealStart:
        break
      case Message.VADMisfire:
        this.speaking = false
        this.opts.onMisfire && this.opts.onMisfire()
        break
      case Message.SpeechEnd:
        this.speaking = false
        this.opts.onSpeechEnd &&
          this.opts.onSpeechEnd({
            audio: ev.audio,
            endSample: this.currentEnd,
            forced: this._forced,
          })
        break
      default:
        break
    }
  }

  /** Half-duplex: stop consuming while TTS plays. Drops the open segment and
   * the queued frames rather than stitching our own voice into an utterance. */
  pause() {
    if (this.paused) return
    this.paused = true
    this.queue.length = 0
    this.speaking = false
    this.fp.pause(() => {}) // submitUserSpeechOnPause: false -> reset(), no event
  }

  resume() {
    if (!this.paused) return
    this.paused = false
    this.fp.resume()
    this._pump()
  }

  async destroy() {
    this.destroyed = true
    this.queue.length = 0
    try {
      await this.model.release()
    } catch (_e) {
      /* session may already be gone */
    }
  }
}

/**
 * Loads the Silero v5 model and returns a started VadEngine.
 *
 * Call this at ARM time (the start-voice-mode gesture), never on first speech:
 * SPIKE 1 measured 499-809 ms of session init, which would otherwise eat the
 * first utterance.
 */
export async function createVad(opts = {}) {
  configureOrt()

  const url = sileroModelUrl()
  const res = await fetch(url)
  if (!res.ok) throw new Error(`could not load the VAD model from ${url} (HTTP ${res.status})`)
  const modelBuffer = await res.arrayBuffer()

  const model = await Silero.new(ort, async () => modelBuffer)
  const fp = new FrameProcessor(
    model.process,
    model.reset_state,
    {
      positiveSpeechThreshold: VAD_SETTINGS.positiveSpeechThreshold,
      negativeSpeechThreshold: VAD_SETTINGS.negativeSpeechThreshold,
      redemptionMs: VAD_SETTINGS.redemptionMs,
      preSpeechPadMs: VAD_SETTINGS.preSpeechPadMs,
      minSpeechMs: VAD_SETTINGS.minSpeechMs,
      submitUserSpeechOnPause: false,
    },
    MS_PER_FRAME
  )
  fp.resume()

  return new VadEngine(fp, model, opts)
}

export { TARGET_RATE, FRAME_SAMPLES, MS_PER_FRAME }
