/* Engine B: Silero v5/v6 ONNX driven directly on onnxruntime-web, fed by our
 * own capture worklet's 16 kHz frames. No @ricky0123/vad-web.
 *
 * Contract (matches silero-vad's utils_vad.py OnnxWrapper.__call__):
 *   inputs  { input: f32[1, 64+512], state: f32[2,1,128], sr: i64 16000 }
 *   outputs { output: f32[1,1] speech prob, stateN: f32[2,1,128] }
 * The leading 64 samples are the tail of the PREVIOUS frame, so an onset
 * straddling a frame boundary is still seen whole.
 */

const CONTEXT = 64;
const FRAME = 512;          // 32 ms @ 16 kHz
const MS_PER_FRAME = FRAME / 16;

export class SileroDirect {
  constructor(ort, session, opts) {
    this.ort = ort;
    this.session = session;
    this.state = this._zeroState();
    this.sr = new ort.Tensor('int64', [16000n]);
    this.ctx = new Float32Array(CONTEXT);
    this.buf = new Float32Array(CONTEXT + FRAME);
    this.setOptions(opts || {});
    this.reset();
    this.inferTimes = [];
  }

  static async create(ort, modelUrl, opts) {
    const t0 = performance.now();
    const resp = await fetch(modelUrl);
    const bytes = await resp.arrayBuffer();
    const fetchMs = performance.now() - t0;
    const t1 = performance.now();
    const session = await ort.InferenceSession.create(bytes, {
      executionProviders: ['wasm'],
      graphOptimizationLevel: 'all',
    });
    const initMs = performance.now() - t1;
    const s = new SileroDirect(ort, session, opts);
    s.modelBytes = bytes.byteLength;
    s.fetchMs = fetchMs;
    s.initMs = initMs;
    return s;
  }

  _zeroState() {
    return new this.ort.Tensor('float32', new Float32Array(2 * 128), [2, 1, 128]);
  }

  setOptions(o) {
    this.opt = {
      positiveSpeechThreshold: o.positiveSpeechThreshold ?? 0.5,
      negativeSpeechThreshold: o.negativeSpeechThreshold ?? 0.35,
      redemptionMs: o.redemptionMs ?? 600,
      preSpeechPadMs: o.preSpeechPadMs ?? 500,
      minSpeechMs: o.minSpeechMs ?? 250,
    };
    this.redemptionFrames = Math.max(1, Math.round(this.opt.redemptionMs / MS_PER_FRAME));
    this.minSpeechFrames = Math.max(1, Math.round(this.opt.minSpeechMs / MS_PER_FRAME));
  }

  reset() {
    this.state = this._zeroState();
    this.ctx = new Float32Array(CONTEXT);
    this.speaking = false;
    this.redemption = 0;
    this.speechFrames = 0;
    this.seg = null;
    this.lastSpeechEndSample = null;   // abs 16k index of end of last >=pos frame
  }

  /** Run one 512-sample frame. Returns the speech probability. */
  async infer(frame) {
    this.buf.set(this.ctx, 0);
    this.buf.set(frame, CONTEXT);
    this.ctx = frame.slice(-CONTEXT);
    const t = new this.ort.Tensor('float32', this.buf, [1, this.buf.length]);
    const t0 = performance.now();
    const out = await this.session.run({ input: t, state: this.state, sr: this.sr });
    const dt = performance.now() - t0;
    this.inferTimes.push(dt);
    this.state = out.stateN;
    return { prob: out.output.data[0], inferMs: dt };
  }

  /**
   * Feed one frame plus its absolute end index (16 kHz samples since capture
   * start). Emits events via the callbacks in `cb`.
   *   cb.onFrame({prob, inferMs, endSample})
   *   cb.onSpeechStart({startSample})
   *   cb.onSpeechEnd({startSample, endSample, lastSpeechEndSample,
   *                   eosLatencyMs, audio})   audio == frames only, no pre-roll
   *   cb.onMisfire({...})   segment shorter than minSpeechMs
   */
  async push(frame, endSample, cb) {
    const { prob, inferMs } = await this.infer(frame);
    cb.onFrame && cb.onFrame({ prob, inferMs, endSample });

    const isSpeech = prob >= this.opt.positiveSpeechThreshold;
    if (isSpeech) this.lastSpeechEndSample = endSample;

    if (!this.speaking) {
      if (isSpeech) {
        this.speaking = true;
        this.redemption = 0;
        this.speechFrames = 1;
        this.seg = { startSample: endSample - FRAME, frames: [frame.slice()] };
        cb.onSpeechStart && cb.onSpeechStart({ startSample: this.seg.startSample });
      }
      return prob;
    }

    // speaking
    this.seg.frames.push(frame.slice());
    if (isSpeech) {
      this.speechFrames++;
      this.redemption = 0;
      return prob;
    }
    if (prob < this.opt.negativeSpeechThreshold) {
      this.redemption++;
      if (this.redemption >= this.redemptionFrames) {
        const seg = this.seg;
        this.speaking = false; this.seg = null; this.redemption = 0;
        // EOS latency in AUDIO time: from the end of the last speech frame to
        // the moment the end event fires. Exact, and independent of any
        // wall-clock/loop-phase alignment.
        const eosLatencyMs = ((endSample - this.lastSpeechEndSample) / 16000) * 1000;
        const total = seg.frames.length * FRAME;
        const audio = new Float32Array(total);
        seg.frames.forEach((f, i) => audio.set(f, i * FRAME));
        const payload = {
          startSample: seg.startSample, endSample,
          lastSpeechEndSample: this.lastSpeechEndSample,
          eosLatencyMs, audio,
          speechFrames: this.speechFrames,
          durMs: (total / 16000) * 1000,
        };
        if (this.speechFrames < this.minSpeechFrames) {
          cb.onMisfire && cb.onMisfire(payload);
        } else {
          cb.onSpeechEnd && cb.onSpeechEnd(payload);
        }
        this.speechFrames = 0;
      }
    }
    return prob;
  }
}

export const SILERO_FRAME = FRAME;
export const SILERO_MS_PER_FRAME = MS_PER_FRAME;
