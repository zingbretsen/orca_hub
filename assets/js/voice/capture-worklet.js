/* orca-capture: <ctx.sampleRate> -> 16 kHz mono, anti-aliased, with a pre-roll
 * ring buffer addressed by ABSOLUTE 16 kHz sample index.
 *
 * Ported from spikes/voice/capture-worklet.js (SPIKE 1, measured: 0.58% duty
 * cycle, p50 15-17 us per 128-frame block, at both 48 kHz and 44.1 kHz).
 * Behaviour is unchanged; the instrumentation was trimmed and the processor
 * renamed.
 *
 * Two things here look optional and are not:
 *
 * - The ratio is `sampleRate / 16000` READ AT CONSTRUCTION, never a hardcoded
 *   3 or 48000. SPIKE 1 saw a track negotiated at 48 kHz inside a context
 *   negotiated at 44.1 kHz -> ratio 2.75625. A wrong ratio pitch-shifts the
 *   audio ~10% and Whisper transcribes pitch-shifted speech into plausible
 *   WRONG WORDS rather than failing (spec section 9 trap 5).
 * - `performance` DOES NOT EXIST in AudioWorkletGlobalScope. Calling
 *   performance.now() in process() throws, Chrome fires onprocessorerror ONCE
 *   and then silently stops calling process() forever (spec section 9 trap 7).
 *   All timing here is the audio clock (`currentTime`) or `Date.now()`, both
 *   of which do exist. Do not add a performance.now().
 */

const TARGET_RATE = 16000

/* Windowed-sinc low-pass, designed once for the real (negotiated) input rate.
 * Without it, decimating 48k->16k aliases everything above 8 kHz straight down
 * into the speech band. */
function designLowpass(inRate, cutoffHz, taps) {
  const h = new Float32Array(taps)
  const fc = cutoffHz / inRate // normalised cutoff (cycles/sample)
  const mid = (taps - 1) / 2
  let sum = 0
  for (let i = 0; i < taps; i++) {
    const n = i - mid
    const sinc = n === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * n) / (Math.PI * n)
    // Blackman window
    const w =
      0.42 -
      0.5 * Math.cos((2 * Math.PI * i) / (taps - 1)) +
      0.08 * Math.cos((4 * Math.PI * i) / (taps - 1))
    h[i] = sinc * w
    sum += h[i]
  }
  for (let i = 0; i < taps; i++) h[i] /= sum // unity DC gain
  return h
}

class OrcaCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const o = (options && options.processorOptions) || {}
    this.frameSamples = o.frameSamples || 512 // 32 ms @ 16 kHz (Silero v5)
    this.prerollMs = o.prerollMs || 500
    this.inRate = sampleRate // AudioWorkletGlobalScope global
    this.ratio = this.inRate / TARGET_RATE

    const taps = o.taps || 63
    this.taps = taps
    this.h = designLowpass(this.inRate, 7600, taps)
    this.hist = new Float32Array(taps) // FIR delay line
    this.histPos = 0

    this.phase = 0 // fractional read position into the filtered stream
    this.pending = new Float32Array(this.frameSamples)
    this.pendingLen = 0

    // Ring of 16 kHz samples: the pre-roll plus generous slack, so a late
    // main-thread request for [end-N, end) still resolves. `padSlackMs` buys
    // room for the sub-0.8 s pad-from-history path in voice_hook.js.
    const slackMs = o.slackMs || 1500
    this.ringLen = Math.ceil(((this.prerollMs + slackMs) / 1000) * TARGET_RATE)
    this.ring = new Float32Array(this.ringLen)
    this.ringWrite = 0
    this.totalOut = 0 // absolute count of 16 kHz samples ever produced

    this.blocks = 0
    this.calls = 0
    this.emptyInput = 0
    this.cpuMs = 0
    this.wallStart = Date.now()

    this.port.onmessage = (e) => this.onCommand(e.data)
    this.port.postMessage({
      type: "ready",
      inRate: this.inRate,
      ratio: this.ratio,
      taps,
      frameSamples: this.frameSamples,
      ringLen: this.ringLen,
      hasPerformance: typeof performance !== "undefined",
    })
  }

  onCommand(msg) {
    if (!msg) return
    if (msg.cmd === "history") {
      // Return the `samples` 16 kHz samples immediately BEFORE `endSample`.
      // Absolute indices, so a late request still returns exactly the right
      // audio (spec section 9 trap 5).
      const want = Math.min(msg.samples | 0, this.ringLen)
      const end = Math.min(msg.endSample == null ? this.totalOut : msg.endSample, this.totalOut)
      const oldest = Math.max(0, this.totalOut - this.ringLen)
      const start = Math.max(oldest, end - want)
      const n = Math.max(0, end - start)
      const out = new Float32Array(n)
      for (let i = 0; i < n; i++) out[i] = this.ring[(start + i) % this.ringLen]
      this.port.postMessage(
        {
          type: "history",
          id: msg.id,
          truncated: n < want,
          requested: want,
          startSample: start,
          samples: out,
        },
        [out.buffer]
      )
    } else if (msg.cmd === "stats") {
      this.port.postMessage({
        type: "stats",
        id: msg.id,
        inRate: this.inRate,
        ratio: this.ratio,
        blocks: this.blocks,
        calls: this.calls,
        emptyInput: this.emptyInput,
        totalOut: this.totalOut,
        cpuMs: this.cpuMs,
        wallMs: Date.now() - this.wallStart,
        audioTime: currentTime,
      })
    }
  }

  process(inputs, outputs) {
    const w0 = Date.now()
    this.calls++
    const input = inputs[0]
    if (!input || input.length === 0) {
      this.emptyInput++
      return true
    }
    const ch = input[0]
    if (!ch) {
      this.emptyInput++
      return true
    }

    const h = this.h
    const taps = this.taps
    const hist = this.hist

    for (let i = 0; i < ch.length; i++) {
      hist[this.histPos] = ch[i]
      this.histPos = (this.histPos + 1) % taps

      // Emit a 16 kHz sample whenever the fractional phase crosses this input
      // sample. `phase` counts INPUT samples consumed per OUTPUT sample.
      this.phase += 1
      while (this.phase >= this.ratio) {
        this.phase -= this.ratio
        let acc = 0
        let idx = this.histPos // oldest slot
        for (let k = taps - 1; k >= 0; k--) {
          acc += h[k] * hist[idx]
          idx = (idx + 1) % taps
        }
        this.ring[this.ringWrite] = acc
        this.ringWrite = (this.ringWrite + 1) % this.ringLen
        this.totalOut++

        this.pending[this.pendingLen++] = acc
        if (this.pendingLen === this.frameSamples) {
          const f = new Float32Array(this.pending) // copy; ownership transferred
          this.port.postMessage(
            {
              type: "frame",
              samples: f,
              endSample: this.totalOut, // absolute 16 kHz index AFTER this frame
              audioTime: currentTime,
            },
            [f.buffer]
          )
          this.pendingLen = 0
        }
      }
    }

    // We produce no audio, but the node must still be connected onward or the
    // render graph never pulls it (spec section 9 trap 8). Keep the muted
    // output branch valid.
    const out = outputs[0]
    if (out) for (let c = 0; c < out.length; c++) out[c].fill(0)

    this.blocks++
    this.cpuMs += Date.now() - w0
    return true
  }
}

registerProcessor("orca-capture", OrcaCaptureProcessor)
