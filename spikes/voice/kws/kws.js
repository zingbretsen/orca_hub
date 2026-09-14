/* SPIKE 3 harness — in-browser keyword spotting: openWakeWord vs Porcupine.
 *
 * Two ways to drive an engine, deliberately:
 *
 *   OFFLINE (`runOffline`)  — a 16 kHz mono fixture is fed straight into the
 *     engine in 80 ms / 32 ms chunks with no audio graph in the loop. Nothing
 *     resamples, so a keyword's END TIME is exact to the sample and detection
 *     latency can be reported in AUDIO time: "how much audio past the end of
 *     the word did the model need". It also runs far faster than realtime,
 *     which is the only way 24 minutes of negative audio is affordable.
 *
 *   LIVE (`runLive`)        — getUserMedia + SPIKE 1's capture worklet
 *     (../capture-worklet.js, loaded read-only over HTTP) against Chrome's
 *     fake capture device. Proves the engine survives a real AudioWorklet
 *     stream at realtime and gives a WALL-CLOCK callback latency, which the
 *     offline path cannot.
 *
 * window.__kws is the whole API; tools/headless.mjs drives it.
 */

const $ = (id) => document.getElementById(id);
const log = (...a) => {
  console.log(...a);
  const el = $('log');
  if (el) { el.textContent += a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ') + '\n'; el.scrollTop = el.scrollHeight; }
};

const S = {
  fixtures: null,
  oww: null,          // { melspec, embed, classifiers: Map }
  pv: null,           // Porcupine instance, if a key ever exists
  results: {},
};
window.__kwsResults = S.results;

/* ---------------------------------------------------------------- helpers */

function pct(arr, p) {
  if (!arr.length) return null;
  const a = Float64Array.from(arr).sort();
  const i = Math.min(a.length - 1, Math.max(0, Math.ceil((p / 100) * a.length) - 1));
  return Math.round(a[i] * 1000) / 1000;
}
const stats = (a) => ({ n: a.length, p50: pct(a, 50), p95: pct(a, 95), p99: pct(a, 99),
                        max: a.length ? Math.round(Math.max(...a) * 1000) / 1000 : null,
                        mean: a.length ? Math.round((a.reduce((s, x) => s + x, 0) / a.length) * 1000) / 1000 : null });

/** Minimal 16-bit PCM WAV reader. Deliberately NOT decodeAudioData, which
 *  resamples to the AudioContext rate and would destroy the sample-exact
 *  keyword timing the whole measurement rests on. */
function decodeWav(buf) {
  const dv = new DataView(buf);
  const tag = (o) => String.fromCharCode(dv.getUint8(o), dv.getUint8(o + 1), dv.getUint8(o + 2), dv.getUint8(o + 3));
  if (tag(0) !== 'RIFF' || tag(8) !== 'WAVE') throw new Error('not a RIFF/WAVE file');
  let off = 12, fmt = null, data = null;
  while (off + 8 <= dv.byteLength) {
    const id = tag(off), size = dv.getUint32(off + 4, true);
    if (id === 'fmt ') {
      fmt = { format: dv.getUint16(off + 8, true), channels: dv.getUint16(off + 10, true),
              sampleRate: dv.getUint32(off + 12, true), bits: dv.getUint16(off + 22, true) };
    } else if (id === 'data') {
      data = { off: off + 8, size };
    }
    off += 8 + size + (size % 2);
  }
  if (!fmt || !data) throw new Error('missing fmt/data chunk');
  if (fmt.bits !== 16) throw new Error('expected 16-bit PCM, got ' + fmt.bits);
  let pcm = new Int16Array(buf.slice(data.off, data.off + data.size));
  if (fmt.channels > 1) {
    const n = Math.floor(pcm.length / fmt.channels), mono = new Int16Array(n);
    for (let i = 0; i < n; i++) {
      let s = 0;
      for (let c = 0; c < fmt.channels; c++) s += pcm[i * fmt.channels + c];
      mono[i] = s / fmt.channels;
    }
    pcm = mono;
  }
  return { sampleRate: fmt.sampleRate, samples: pcm };
}

async function fetchFixture(name) {
  if (!S.fixtures) await loadFixtures();
  const fx = S.fixtures.fixtures[name];
  if (!fx) throw new Error('unknown fixture ' + name);
  const r = await fetch('/kws/assets/' + fx.path, { cache: 'force-cache' });
  const wav = decodeWav(await r.arrayBuffer());
  return { fx, wav };
}

async function loadFixtures() {
  S.fixtures = await (await fetch('/kws/assets/kws_fixtures.json')).json();
  return Object.keys(S.fixtures.fixtures);
}

function setupOrt() {
  if (!window.ort) throw new Error('window.ort missing — /vendor/ort/ort.wasm.min.js did not load');
  window.ort.env.wasm.wasmPaths = new URL('/vendor/ort/', location.href).href;
  window.ort.env.wasm.numThreads = 1;     // no COOP/COEP -> no SharedArrayBuffer
  window.ort.env.logLevel = 'error';
  return window.ort;
}

/* ------------------------------------------------------- openWakeWord ---- */
/* Faithful port of openwakeword/utils.py AudioFeatures._streaming_features:
 *   per 1280-sample (80 ms) chunk:
 *     melspec( last 1280+480 samples )  -> 8 mel frames, transformed x/10+2
 *     embedding( last 76 mel frames )   -> one 96-d vector
 *     classifier( last N embeddings )   -> one score
 * The 480-sample overlap and the /10+2 transform are both load-bearing:
 * drop either and the scores collapse toward zero on real keywords.          */

const OWW_CHUNK = 1280;          // 80 ms @ 16 kHz
const OWW_MEL_OVERLAP = 480;     // 160*3, exactly as upstream
const OWW_MEL_WINDOW = 76;       // mel frames per embedding
const OWW_MEL_PER_CHUNK = 8;     // mel frames produced per chunk

class OwwEngine {
  /** heads: [{ name, sess, featFrames }] — the melspectrogram + embedding
   *  backbone is SHARED, so a second keyword costs one more classifier run
   *  (sub-millisecond) rather than a second copy of the expensive half. */
  constructor(ort, melspec, embed, heads) {
    this.ort = ort; this.melspec = melspec; this.embed = embed;
    this.heads = heads;
    this.featFrames = Math.max(...heads.map(h => h.featFrames));
    this.name = heads.map(h => h.name).join('+');
    this.t = { mel: [], emb: [], cls: [] };
    this.reset();
  }

  reset() {
    this.raw = new Float32Array(OWW_CHUNK + OWW_MEL_OVERLAP).fill(0);
    // upstream seeds melspectrogram_buffer with ones((76,32))
    this.mel = new Float32Array(OWW_MEL_WINDOW * 32).fill(1);
    this.melFrames = OWW_MEL_WINDOW;
    this.feat = [];
    this.warmed = false;
  }

  /** upstream seeds feature_buffer with the embeddings of 4 s of random
   *  int16 audio in [-1000, 1000); we do the same by streaming it. */
  async warmup() {
    const n = 16000 * 4 / OWW_CHUNK;
    for (let i = 0; i < n; i++) {
      const c = new Int16Array(OWW_CHUNK);
      for (let j = 0; j < OWW_CHUNK; j++) c[j] = (Math.random() * 2000 - 1000) | 0;
      await this.feed(c, { time: false });
    }
    this.warmed = true;
  }

  async feed(chunk /* Int16Array(1280) */, { time = true } = {}) {
    const ort = this.ort;
    // --- rolling raw window: 1280 new + 480 carried over
    this.raw.copyWithin(0, OWW_CHUNK);           // keep last 480
    for (let i = 0; i < OWW_CHUNK; i++) this.raw[OWW_MEL_OVERLAP + i] = chunk[i];
    // melspec wants int16-MAGNITUDE floats, not [-1,1]
    let t0 = performance.now();
    const melOut = await this.melspec.run({
      [this.melspec.inputNames[0]]: new ort.Tensor('float32', this.raw.slice(), [1, this.raw.length]),
    });
    const melT = melOut[this.melspec.outputNames[0]];
    if (time) this.t.mel.push(performance.now() - t0);
    const md = melT.dims, frames = md[md.length - 2], bins = md[md.length - 1];
    if (bins !== 32) throw new Error('unexpected mel bins ' + bins);

    // append transformed frames (x/10 + 2)
    const need = (this.melFrames + frames) * 32;
    if (this.mel.length < need) {
      const g = new Float32Array(Math.max(need, this.mel.length * 2));
      g.set(this.mel.subarray(0, this.melFrames * 32)); this.mel = g;
    }
    for (let i = 0; i < frames * 32; i++) this.mel[this.melFrames * 32 + i] = melT.data[i] / 10 + 2;
    this.melFrames += frames;
    if (this.melFrames > 970) {           // upstream cap: 10*97 frames
      const keep = 970;
      this.mel.copyWithin(0, (this.melFrames - keep) * 32, this.melFrames * 32);
      this.melFrames = keep;
    }

    // --- embedding over the last 76 mel frames
    const start = (this.melFrames - OWW_MEL_WINDOW) * 32;
    const win = this.mel.slice(start, start + OWW_MEL_WINDOW * 32);
    t0 = performance.now();
    const embOut = await this.embed.run({
      [this.embed.inputNames[0]]: new ort.Tensor('float32', win, [1, OWW_MEL_WINDOW, 32, 1]),
    });
    const emb = embOut[this.embed.outputNames[0]];
    if (time) this.t.emb.push(performance.now() - t0);
    this.feat.push(Float32Array.from(emb.data));
    if (this.feat.length > 120) this.feat.splice(0, this.feat.length - 120);

    // --- one classifier run per head, over the last featFrames embeddings
    if (this.feat.length < this.featFrames) return null;
    const D = this.feat[0].length;
    t0 = performance.now();
    const scores = {};
    for (const h of this.heads) {
      const N = h.featFrames;
      const buf = new Float32Array(N * D);
      for (let i = 0; i < N; i++) buf.set(this.feat[this.feat.length - N + i], i * D);
      const clsOut = await h.sess.run({
        [h.sess.inputNames[0]]: new ort.Tensor('float32', buf, [1, N, D]),
      });
      scores[h.name] = clsOut[h.sess.outputNames[0]].data[0];
    }
    if (time) this.t.cls.push(performance.now() - t0);
    return this.heads.length === 1 ? scores[this.heads[0].name] : scores;
  }
}

async function initOww({ classifier = 'hey_jarvis_v0.1' } = {}) {
  const ort = setupOrt();
  const t0 = performance.now();
  if (!S.oww) {
    const opts = { executionProviders: ['wasm'], graphOptimizationLevel: 'all' };
    const melspec = await ort.InferenceSession.create('/kws/vendor/oww/melspectrogram.onnx', opts);
    const embed = await ort.InferenceSession.create('/kws/vendor/oww/embedding_model.onnx', opts);
    S.oww = { melspec, embed, classifiers: new Map(), loadMs: performance.now() - t0 };
  }
  let entry = S.oww.classifiers.get(classifier);
  if (!entry) {
    const t1 = performance.now();
    const sess = await ort.InferenceSession.create('/kws/vendor/oww/' + classifier + '.onnx',
      { executionProviders: ['wasm'], graphOptimizationLevel: 'all' });
    // The number of embedding frames the classifier wants is a property of the
    // model. ort-web does not reliably expose input dims, so probe it.
    let featFrames = null, probeErrors = [];
    for (const n of [16, 28, 32, 24, 12, 8]) {
      try {
        await sess.run({ [sess.inputNames[0]]: new ort.Tensor('float32', new Float32Array(n * 96), [1, n, 96]) });
        featFrames = n; break;
      } catch (e) { probeErrors.push(n + ': ' + (e.message || e).slice(0, 90)); }
    }
    if (!featFrames) throw new Error('could not determine classifier input frames: ' + probeErrors.join(' | '));
    entry = { sess, featFrames, loadMs: performance.now() - t1, probeErrors };
    S.oww.classifiers.set(classifier, entry);
  }
  return {
    backboneLoadMs: Math.round(S.oww.loadMs),
    classifier, classifierLoadMs: Math.round(entry.loadMs),
    featFrames: entry.featFrames,
    melspecIO: { in: S.oww.melspec.inputNames, out: S.oww.melspec.outputNames },
    embedIO: { in: S.oww.embed.inputNames, out: S.oww.embed.outputNames },
    classifierIO: { in: entry.sess.inputNames, out: entry.sess.outputNames },
    wasm: { numThreads: ort.env.wasm.numThreads, simd: ort.env.wasm.simd,
            crossOriginIsolated: self.crossOriginIsolated === true },
  };
}

/* --------------------------------------------------------- Porcupine ---- */

const PV_FRAME = 512;           // Porcupine frame length @ 16 kHz = 32 ms

async function initPorcupine({ accessKey, keyword = 'Computer', sensitivity = 0.5,
                               keywordPath = null } = {}) {
  if (!window.PorcupineWeb) throw new Error('PorcupineWeb global missing');
  const { Porcupine } = window.PorcupineWeb;
  const t0 = performance.now();
  const hits = [];
  // keywordPath bypasses the .ppn files bundled inside the npm package, which
  // in 4.0.1 are stale (see README): a publicPath keyword gets us past the
  // keyword loader so the failure we observe is the AccessKey one.
  const kwSpec = keywordPath
    ? { publicPath: keywordPath, label: keyword, sensitivity, forceWrite: true,
        customWritePath: 'kw_' + keyword }
    : { builtin: keyword, sensitivity };
  try {
    const p = await Porcupine.create(
      accessKey,
      [kwSpec],
      (d) => hits.push({ ...d, at: performance.now() }),
      { publicPath: '/kws/vendor/porcupine/porcupine_params.pv', forceWrite: true },
    );
    S.pv = { p, hits, frameLength: p.frameLength, sampleRate: p.sampleRate, version: p.version };
    return { ok: true, loadMs: Math.round(performance.now() - t0),
             frameLength: p.frameLength, sampleRate: p.sampleRate, version: p.version };
  } catch (e) {
    return { ok: false, loadMs: Math.round(performance.now() - t0),
             error: String(e && e.message || e).slice(0, 600),
             name: e && e.constructor && e.constructor.name,
             stack: String(e && e.stack || '').split('\n').slice(0, 4).join(' | ').slice(0, 500) };
  }
}

/* ------------------------------------------------------ offline runner -- */

/** Turn a score trace into detection events: a rising crossing of `threshold`,
 *  debounced so one long word cannot count as several detections. */
function detectionsFrom(trace, threshold, debounceMs) {
  const out = [];
  let armed = true, lastMs = -1e9;
  for (const s of trace) {
    if (s.score >= threshold) {
      if (armed && s.atMs - lastMs >= debounceMs) {
        out.push({ atMs: s.atMs, score: Math.round(s.score * 1e4) / 1e4 });
        lastMs = s.atMs; armed = false;
      }
    } else if (s.score < threshold * 0.5) {
      armed = true;
    }
  }
  return out;
}

/** Score a detection list against the fixture's known keyword instances. */
function scoreDetections(dets, instances, windowMs) {
  const matched = new Set();
  let tp = 0, fa = 0;
  const latencies = [];
  for (const d of dets) {
    let hit = -1;
    for (let i = 0; i < instances.length; i++) {
      const ins = instances[i];
      if (d.atMs >= ins.onset_ms && d.atMs <= ins.offset_ms + windowMs) { hit = i; break; }
    }
    if (hit >= 0) {
      if (!matched.has(hit)) {
        matched.add(hit); tp++;
        latencies.push(Math.round(d.atMs - instances[hit].offset_ms));
      }
    } else { fa++; }
  }
  return { instances: instances.length, detected: tp, missed: instances.length - tp,
           extraFires: fa, detectionRate: instances.length ? tp / instances.length : null,
           latencyMs: latencies.length ? { ...stats(latencies), values: latencies } : null };
}

async function runOffline({
  tag, engine = 'oww', fixture, classifier = 'hey_jarvis_v0.1',
  thresholds = [0.3, 0.5, 0.7], debounceMs = 1250, matchWindowMs = 1500,
  keepTrace = false, accessKey = null, keyword = 'Computer', classifiers = null,
  // paced: sleep between chunks so the engine runs at REALTIME pace with no
  // audio graph attached. This isolates one effect: offline the chunks run
  // back to back and the core stays boosted, whereas a real spotter works for
  // ~10 ms then idles for ~70 ms, which is a different CPU regime entirely.
  paced = false,
} = {}) {
  const { fx, wav } = await fetchFixture(fixture);
  if (wav.sampleRate !== 16000) throw new Error('fixture is not 16 kHz: ' + wav.sampleRate);
  const trace = [];
  const started = performance.now();
  let chunkSize, engineInfo;

  if (engine === 'oww') {
    const names = classifiers || [classifier];
    engineInfo = null;
    for (const c of names) engineInfo = await initOww({ classifier: c });
    engineInfo.heads = names;
    const e = new OwwEngine(window.ort, S.oww.melspec, S.oww.embed,
      names.map(c => ({ name: c, sess: S.oww.classifiers.get(c).sess,
                        featFrames: S.oww.classifiers.get(c).featFrames })));
    await e.warmup();
    e.t = { mel: [], emb: [], cls: [] };
    chunkSize = OWW_CHUNK;
    const n = Math.floor(wav.samples.length / chunkSize);
    for (let k = 0; k < n; k++) {
      if (paced) await new Promise(r => setTimeout(r, chunkSize / 16));
      const score = await e.feed(wav.samples.subarray(k * chunkSize, (k + 1) * chunkSize));
      if (score !== null) {
        // with several heads, the trace carries the MAX so the existing
        // detection logic still applies; per-head scores ride alongside
        trace.push(typeof score === 'number'
          ? { atMs: (k + 1) * chunkSize / 16, score }
          : { atMs: (k + 1) * chunkSize / 16, score: Math.max(...Object.values(score)), per: score });
      }
    }
    engineInfo.perFrameMs = { melspec: stats(e.t.mel), embedding: stats(e.t.emb), classifier: stats(e.t.cls) };
    const tot = e.t.mel.map((m, i) => m + (e.t.emb[i] || 0) + (e.t.cls[i] || 0));
    engineInfo.perFrameMs.total = stats(tot);
    engineInfo.realtimeFactor = engineInfo.perFrameMs.total.p50 / 80;
  } else if (engine === 'porcupine') {
    engineInfo = await initPorcupine({ accessKey, keyword });
    if (!engineInfo.ok) return { tag, fixture, engine, blocked: true, engineInfo };
    chunkSize = PV_FRAME;
    const p = S.pv.p, hits = S.pv.hits; hits.length = 0;
    const times = [];
    const n = Math.floor(wav.samples.length / chunkSize);
    for (let k = 0; k < n; k++) {
      const t0 = performance.now();
      await p.process(wav.samples.slice(k * chunkSize, (k + 1) * chunkSize));
      times.push(performance.now() - t0);
      while (hits.length) { hits.shift(); trace.push({ atMs: (k + 1) * chunkSize / 16, score: 1 }); }
    }
    engineInfo.perFrameMs = { total: stats(times) };
    engineInfo.realtimeFactor = engineInfo.perFrameMs.total.p50 / 32;
  } else throw new Error('unknown engine ' + engine);

  const wallMs = performance.now() - started;
  const durMs = wav.samples.length / 16;
  const out = {
    tag, fixture, engine, classifier: engine === 'oww' ? classifier : keyword,
    paced, fixtureDurationMs: Math.round(durMs), chunkSize,
    chunks: trace.length, wallMs: Math.round(wallMs),
    speedVsRealtime: Math.round((durMs / wallMs) * 100) / 100,
    engineInfo, byThreshold: {},
  };
  const instances = fx.instances || [];
  for (const th of thresholds) {
    const dets = detectionsFrom(trace, th, debounceMs);
    out.byThreshold[th] = instances.length
      ? scoreDetections(dets, instances, matchWindowMs)
      : { detections: dets.length, durationMs: Math.round(durMs),
          perHour: Math.round((dets.length / (durMs / 3600000)) * 100) / 100,
          at: dets.slice(0, 25) };
  }
  out.scoreCeiling = trace.length ? Math.round(Math.max(...trace.map(t => t.score)) * 1e4) / 1e4 : null;
  out.scorePctl = stats(trace.map(t => t.score));
  if (keepTrace) out.trace = trace.map(t => ({ t: Math.round(t.atMs), s: Math.round(t.score * 1e3) / 1e3 }));
  S.results[tag || fixture] = out;
  return out;
}

/* --------------------------------------------------------- live runner -- */

async function runLive({ tag = 'live', engine = 'oww', classifier = 'hey_jarvis_v0.1',
                         seconds = 25, threshold = 0.5, accessKey = null,
                         keyword = 'Computer' } = {}) {
  const frameSamples = engine === 'oww' ? OWW_CHUNK : PV_FRAME;
  let info, feed;
  if (engine === 'oww') {
    info = await initOww({ classifier });
    const e = new OwwEngine(window.ort, S.oww.melspec, S.oww.embed,
      [{ name: classifier, sess: S.oww.classifiers.get(classifier).sess,
         featFrames: S.oww.classifiers.get(classifier).featFrames }]);
    await e.warmup();
    e.t = { mel: [], emb: [], cls: [] };
    feed = async (int16) => e.feed(int16);
    info.engineRef = () => e;
    var owwRef = e;
  } else {
    info = await initPorcupine({ accessKey, keyword });
    if (!info.ok) return { tag, engine, blocked: true, engineInfo: info };
    feed = async (int16) => { const before = S.pv.hits.length; await S.pv.p.process(int16); return S.pv.hits.length > before ? 1 : 0; };
  }

  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
  });
  const track = stream.getAudioTracks()[0];
  const ctx = new AudioContext();
  await ctx.resume();
  // SPIKE 1's worklet, loaded read-only from the parent directory.
  await ctx.audioWorklet.addModule('/capture-worklet.js');
  const src = ctx.createMediaStreamSource(stream);
  const node = new AudioWorkletNode(ctx, 'capture-processor', {
    processorOptions: { frameSamples, prerollMs: 200 },
    numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
  });
  const errs = [];
  node.onprocessorerror = (e) => errs.push('processorerror ' + (e && e.message || ''));
  const sink = ctx.createGain(); sink.gain.value = 0;
  src.connect(node); node.connect(sink); sink.connect(ctx.destination);

  const detections = [], lat = [], queue = [];
  let busy = false, framesIn = 0, framesDone = 0, maxBacklog = 0, lastFire = -1e9;
  const t0 = performance.now();

  async function drain() {
    if (busy) return;
    busy = true;
    while (queue.length) {
      maxBacklog = Math.max(maxBacklog, queue.length);
      const item = queue.shift();
      const score = await feed(item.samples);
      framesDone++;
      const now = performance.now();
      if (score !== null && score >= threshold && (now - lastFire) > 1250) {
        lastFire = now;
        detections.push({ atMs: Math.round(now - t0), score: Math.round(score * 1e4) / 1e4,
                          queuedAgoMs: Math.round(now - item.postedAt) });
        lat.push(now - item.postedAt);
      }
    }
    busy = false;
  }

  node.port.onmessage = (e) => {
    const m = e.data;
    if (m.type !== 'frame') return;
    framesIn++;
    const i16 = new Int16Array(m.samples.length);
    for (let i = 0; i < m.samples.length; i++) {
      const v = Math.max(-1, Math.min(1, m.samples[i]));
      i16[i] = v < 0 ? v * 32768 : v * 32767;
    }
    queue.push({ samples: i16, postedAt: performance.now() });
    drain();
  };

  await new Promise(r => setTimeout(r, seconds * 1000));
  const wall = performance.now() - t0;
  node.port.onmessage = null;
  try { src.disconnect(); node.disconnect(); sink.disconnect(); } catch (_) {}
  track.stop(); await ctx.close();

  const res = {
    tag, engine, classifier: engine === 'oww' ? classifier : keyword,
    seconds, wallMs: Math.round(wall), frameSamples,
    framesIn, framesDone, maxBacklog, processorErrors: errs,
    audioContextSampleRate: ctx.sampleRate,
    trackSettings: track.getSettings ? track.getSettings() : null,
    detections, detectionCount: detections.length,
    handlingLatencyMs: lat.length ? stats(lat) : null,
    engineInfo: info,
  };
  if (engine === 'oww' && owwRef) {
    res.perFrameMs = { melspec: stats(owwRef.t.mel), embedding: stats(owwRef.t.emb),
                       classifier: stats(owwRef.t.cls) };
    const tot = owwRef.t.mel.map((m, i) => m + (owwRef.t.emb[i] || 0) + (owwRef.t.cls[i] || 0));
    res.perFrameMs.total = stats(tot);
    res.dutyCycle = Math.round((res.perFrameMs.total.mean / 80) * 1e4) / 1e4;
  }
  S.results[tag] = res;
  return res;
}

/* ------------------------------------------------------------------ API -- */

window.__kws = {
  state: S, loadFixtures, initOww, initPorcupine, runOffline, runLive,
  decodeWav, stats,
  env: () => ({
    ua: navigator.userAgent, crossOriginIsolated: self.crossOriginIsolated === true,
    hasPorcupineGlobal: !!window.PorcupineWeb, hasOrt: !!window.ort,
    ortVersion: window.ort && window.ort.env && window.ort.env.versions
      ? window.ort.env.versions : (window.ort ? window.ort.version : null),
  }),
};

/* ------------------------------------------------------------------- UI -- */
document.addEventListener('DOMContentLoaded', async () => {
  try {
    const names = await loadFixtures();
    log('fixtures:', names.length, 'loaded');
    const sel = $('fixture');
    if (sel) for (const n of names) { const o = document.createElement('option'); o.value = o.textContent = n; sel.appendChild(o); }
  } catch (e) { log('fixture load failed:', String(e)); }
  const b = (id, fn) => { const el = $(id); if (el) el.onclick = () => fn().then(r => log(JSON.stringify(r, null, 2))).catch(e => log('ERROR ' + (e.stack || e))); };
  b('btn-init-oww', () => initOww({ classifier: $('classifier').value }));
  b('btn-offline', () => runOffline({ tag: 'ui', engine: 'oww', fixture: $('fixture').value, classifier: $('classifier').value }));
  b('btn-live', () => runLive({ tag: 'ui-live', engine: 'oww', classifier: $('classifier').value, seconds: 20 }));
  b('btn-pv', () => initPorcupine({ accessKey: $('accesskey').value, keyword: 'Computer' }));
  b('btn-env', async () => window.__kws.env());
});
