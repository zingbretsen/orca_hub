/* Capture worklet: <ctx.sampleRate> -> 16 kHz mono, anti-aliased, with a
 * PRE-ROLL ring buffer and per-process() timing instrumentation.
 *
 * Why the ring lives HERE and not on the main thread: the pre-roll must be
 * the audio that physically preceded the VAD's "speech start" decision, and
 * the worklet is the only place that sees every render quantum with no
 * scheduling jitter. The main thread asks for `[endSample-N, endSample)` by
 * absolute sample index, so a late request still returns the right audio.
 */

const TARGET_RATE = 16000;

// Windowed-sinc low-pass, designed once at construction for the real
// (negotiated) input rate. Without this, decimating 48k->16k aliases every
// component above 8 kHz straight down into the speech band.
function designLowpass(inRate, cutoffHz, taps) {
  const h = new Float32Array(taps);
  const fc = cutoffHz / inRate;          // normalised cutoff (cycles/sample)
  const mid = (taps - 1) / 2;
  let sum = 0;
  for (let i = 0; i < taps; i++) {
    const n = i - mid;
    const sinc = n === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * n) / (Math.PI * n);
    // Blackman window
    const w = 0.42 - 0.5 * Math.cos((2 * Math.PI * i) / (taps - 1))
            + 0.08 * Math.cos((4 * Math.PI * i) / (taps - 1));
    h[i] = sinc * w;
    sum += h[i];
  }
  for (let i = 0; i < taps; i++) h[i] /= sum;   // unity DC gain
  return h;
}

class CaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = options.processorOptions || {};
    this.frameSamples = o.frameSamples || 512;      // 32 ms @ 16 kHz (Silero v5/v6)
    this.prerollMs = o.prerollMs || 500;
    this.inRate = sampleRate;                        // worklet global
    this.ratio = this.inRate / TARGET_RATE;

    const taps = o.taps || 63;
    this.h = designLowpass(this.inRate, 7600, taps);
    this.hist = new Float32Array(taps);              // FIR delay line
    this.histPos = 0;
    this.taps = taps;

    this.phase = 0;          // fractional read position into the filtered stream
    this.pending = new Float32Array(this.frameSamples);
    this.pendingLen = 0;

    // Ring buffer of 16 kHz samples, sized to preroll + generous slack so a
    // late main-thread request still resolves.
    this.ringLen = Math.ceil((this.prerollMs + 1500) / 1000 * TARGET_RATE);
    this.ring = new Float32Array(this.ringLen);
    this.ringWrite = 0;
    this.totalOut = 0;       // absolute count of 16 kHz samples ever produced

    // Instrumentation. NOTE: `performance` does NOT exist in
    // AudioWorkletGlobalScope (verified: Chromium 153 and Chrome 149) — calling
    // performance.now() here throws, Chrome fires onprocessorerror ONCE and then
    // silently stops calling process() forever. So we time BATCHES of blocks
    // with Date.now() (1 ms resolution) and divide: batchMs/batchBlocks gives a
    // per-block cost, and the spread across batches gives p50/p95.
    // Date.now() has 1 ms resolution and one process() call costs far less than
    // that, so per-call deltas are almost always 0. Their SUM is still an
    // unbiased estimator of total time spent inside process(): it counts the
    // ms boundaries that elapsed while we were executing. That gives a sound
    // TOTAL and duty cycle. It cannot give a per-block p50/p95 — for that see
    // benchResampler() in harness.js, which runs the identical kernel on the
    // main thread where performance.now() exists.
    this.cpuMs = 0;          // estimated total ms spent inside process()
    this.wallStart = Date.now();
    this.blocks = 0;
    this.times = [];

    this.port.onmessage = (e) => this.onCommand(e.data);
    this.hasPerf = (typeof performance !== 'undefined' && typeof performance.now === 'function');
    this.port.postMessage({ type: 'ready', inRate: this.inRate,
                            hasPerformance: this.hasPerf,
                            ratio: this.ratio, taps, frameSamples: this.frameSamples,
                            ringLen: this.ringLen });
  }

  onCommand(msg) {
    if (msg.cmd === 'preroll') {
      const want = Math.min(Math.round(msg.ms / 1000 * TARGET_RATE), this.ringLen);
      const end = Math.min(msg.endSample ?? this.totalOut, this.totalOut);
      const start = Math.max(0, end - want);
      const n = end - start;
      const out = new Float32Array(n);
      // is the requested window still resident?
      const oldest = Math.max(0, this.totalOut - this.ringLen);
      if (start < oldest) {
        this.port.postMessage({ type: 'preroll', id: msg.id, truncated: true,
                                requested: want, samples: new Float32Array(0),
                                startSample: start });
        return;
      }
      for (let i = 0; i < n; i++) {
        out[i] = this.ring[(start + i) % this.ringLen];
      }
      this.port.postMessage({ type: 'preroll', id: msg.id, truncated: false,
                              requested: want, samples: out, startSample: start },
                            [out.buffer]);
    } else if (msg.cmd === 'stats') {
      this.port.postMessage({ type: 'stats', times: this.times.slice(),
                              blocks: this.blocks, inRate: this.inRate,
                              calls: this.calls || 0, emptyInput: this.emptyInput || 0,
                              emptyChan: this.emptyChan || 0, chans: this.chans || 0,
                              lastChanLen: this.lastChanLen || 0,
                              totalOut: this.totalOut,
                              cpuMs: this.cpuMs,
                              wallMs: Date.now() - this.wallStart,
                              hasPerformance: this.hasPerf,
                              timingMethod: 'sum of Date.now() ms-boundary crossings inside '
                                + 'process() (performance is ABSENT in AudioWorkletGlobalScope)' });
    } else if (msg.cmd === 'resetStats') {
      this.times = []; this.blocks = 0; this.cpuMs = 0;
      this.calls = 0; this.emptyInput = 0; this.emptyChan = 0;
      this.wallStart = Date.now();
      this.port.postMessage({ type: 'statsReset' });
    }
  }

  process(inputs, outputs) {
    const t0 = currentTime;                 // audio-clock, for block accounting
    const w0 = Date.now();
    this.calls = (this.calls || 0) + 1;
    const input = inputs[0];
    if (!input || input.length === 0) { this.emptyInput = (this.emptyInput || 0) + 1; return true; }
    const ch = input[0];
    if (!ch) { this.emptyChan = (this.emptyChan || 0) + 1; return true; }
    this.lastChanLen = ch.length;
    this.chans = input.length;

    const h = this.h, taps = this.taps, hist = this.hist;

    for (let i = 0; i < ch.length; i++) {
      // push into FIR delay line
      hist[this.histPos] = ch[i];
      this.histPos = (this.histPos + 1) % taps;

      // Emit a 16 kHz sample whenever the fractional phase crosses this input
      // sample. phase counts INPUT samples consumed per OUTPUT sample.
      this.phase += 1;
      while (this.phase >= this.ratio) {
        this.phase -= this.ratio;
        // convolve (delay line is circular; histPos points at the oldest slot)
        let acc = 0;
        let idx = this.histPos;
        for (let k = taps - 1; k >= 0; k--) {
          acc += h[k] * hist[idx];
          idx = (idx + 1) % taps;
        }
        // ring
        this.ring[this.ringWrite] = acc;
        this.ringWrite = (this.ringWrite + 1) % this.ringLen;
        this.totalOut++;
        // frame assembly
        this.pending[this.pendingLen++] = acc;
        if (this.pendingLen === this.frameSamples) {
          const f = new Float32Array(this.pending);   // copy, transfer ownership
          this.port.postMessage({
            type: 'frame', samples: f,
            endSample: this.totalOut,                 // absolute 16k index AFTER this frame
            audioTime: t0,
          }, [f.buffer]);
          this.pendingLen = 0;
        }
      }
    }

    // we produce no audio; keep the (muted) output branch silent and valid
    const out = outputs[0];
    if (out) for (let c = 0; c < out.length; c++) out[c].fill(0);

    this.blocks++;
    this.cpuMs += (Date.now() - w0);
    return true;
  }
}

registerProcessor('capture-processor', CaptureProcessor);
