/* SPIKE 1 harness — browser voice-capture path for OrcaHub voice mode.
 *
 * Everything measured here is written to `window.__spikeResults` (also
 * rendered on-page and POSTable to out/). Driven either by the buttons or
 * headlessly via `window.__spike.*` from playwright.
 */
import { SileroDirect, SILERO_FRAME, SILERO_MS_PER_FRAME } from './silero-direct.js';

const VERSIONS = {
  'onnxruntime-web': { version: '1.29.0', license: 'MIT', vendored: 'vendor/ort/' },
  '@ricky0123/vad-web': { version: '0.0.31', license: 'ISC', vendored: 'vendor/vad/' },
  'silero model': { file: 'silero_vad_v5.onnx', frameSamples: 512, msPerFrame: 32 },
};

const R = (window.__spikeResults = {
  startedAt: new Date().toISOString(),
  userAgent: navigator.userAgent,
  secureContext: window.isSecureContext,
  crossOriginIsolated: window.crossOriginIsolated,
  versions: VERSIONS,
  assetSizes: null,
  gum: null,
  audioContext: null,
  worklet: null,
  engines: {},
  aec: null,
  segments: [],
  notes: [],
});

const log = (...a) => {
  console.log('[spike]', ...a);
  const el = document.getElementById('log');
  if (el) {
    el.textContent += a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ') + '\n';
    el.scrollTop = el.scrollHeight;
  }
};

// ---------------------------------------------------------------- stats utils
function pct(arr, p) {
  if (!arr.length) return null;
  const s = [...arr].sort((a, b) => a - b);
  const i = Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1));
  return +s[i].toFixed(4);
}
const summ = (arr) => arr.length ? {
  n: arr.length, p50: pct(arr, 50), p95: pct(arr, 95), p99: pct(arr, 99),
  max: +Math.max(...arr).toFixed(4), mean: +(arr.reduce((a, b) => a + b, 0) / arr.length).toFixed(4),
} : { n: 0 };
const rms = (x) => { let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * x[i]; return Math.sqrt(s / (x.length || 1)); };
const dbfs = (x) => 20 * Math.log10(Math.max(rms(x), 1e-12));

// ------------------------------------------------------------------ wav utils
function encodeWav(f32, sampleRate) {
  const n = f32.length;
  const buf = new ArrayBuffer(44 + n * 2);
  const v = new DataView(buf);
  const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVE');
  w(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true);
  v.setUint16(22, 1, true); v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  w(36, 'data'); v.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i++) {
    const s = Math.max(-1, Math.min(1, f32[i]));
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Blob([buf], { type: 'audio/wav' });
}

/** Position (ms) of the first 10 ms window above `thresh` dB relative to peak. */
function onsetMs(f32, sr, relDb = -25) {
  const win = Math.round(sr * 0.010);
  const n = Math.floor(f32.length / win);
  let peak = -Infinity; const e = [];
  for (let i = 0; i < n; i++) {
    const d = dbfs(f32.subarray(i * win, (i + 1) * win));
    e.push(d); if (d > peak) peak = d;
  }
  const thr = peak + relDb;
  for (let i = 0; i < n; i++) if (e[i] > thr) return +(i * 10).toFixed(1);
  return null;
}

async function uploadWav(name, blob) {
  try {
    const r = await fetch(`/upload?name=${encodeURIComponent(name)}`, { method: 'POST', body: blob });
    return await r.text();
  } catch (e) { return 'upload-failed: ' + e.message; }
}

// ------------------------------------------------------------------ mic / gum
const S = {
  stream: null, ctx: null, node: null, source: null, sink: null,
  direct: null, vadweb: null, ort: null,
  frameQ: [], busy: false,
  prerollMs: 500, prerollWaiters: new Map(), prerollSeq: 0,
  engine: null, run: null,
};

async function openMic(constraints) {
  if (!navigator.mediaDevices) {
    const msg = 'navigator.mediaDevices is UNDEFINED — page is not a secure context. '
      + 'Use http://localhost:<port>, NOT a LAN IP. (spec section 9 trap #1)';
    R.gum = { error: msg, secureContext: window.isSecureContext };
    throw new Error(msg);
  }
  const want = constraints || {
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
  };
  const stream = await navigator.mediaDevices.getUserMedia(want);
  const track = stream.getAudioTracks()[0];
  const settings = track.getSettings();
  let caps = {}; try { caps = track.getCapabilities ? track.getCapabilities() : {}; } catch (e) { caps = { error: e.message }; }
  let applied = {}; try { applied = track.getConstraints ? track.getConstraints() : {}; } catch (e) { }

  S.stream = stream;
  R.gum = {
    requested: want.audio,
    supportedConstraints: navigator.mediaDevices.getSupportedConstraints(),
    settings, capabilities: caps, appliedConstraints: applied,
    trackLabel: track.label, trackReadyState: track.readyState,
    // THE question: was echoCancellation actually applied, or silently dropped?
    echoCancellationApplied: settings.echoCancellation === true,
    noiseSuppressionApplied: settings.noiseSuppression === true,
    autoGainControlApplied: settings.autoGainControl === true,
    channelCount: settings.channelCount,
    negotiatedSampleRate: settings.sampleRate ?? null,
  };
  log('getUserMedia ok. settings=', settings);
  return R.gum;
}

// --------------------------------------------------------------- worklet path
async function startWorklet(prerollMs) {
  S.prerollMs = prerollMs ?? 500;
  S.ctx = new AudioContext();
  await S.ctx.resume();
  await S.ctx.audioWorklet.addModule('capture-worklet.js');
  S.source = new MediaStreamAudioSourceNode(S.ctx, { mediaStream: S.stream });
  S.node = new AudioWorkletNode(S.ctx, 'capture-processor', {
    numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
    channelCount: 1, channelCountMode: 'explicit', channelInterpretation: 'speakers',
    processorOptions: { frameSamples: SILERO_FRAME, prerollMs: S.prerollMs, taps: 63 },
  });
  // A worklet with no path to ctx.destination is never pulled by the render
  // graph — process() simply never fires and you get zero frames with no error.
  // Route it through a muted gain node purely to keep the graph alive.
  S.sink = new GainNode(S.ctx, { gain: 0 });
  S.node.onprocessorerror = (e) => {
    R.notes.push('AudioWorkletProcessor ERROR — process() threw; Chrome has stopped '
      + 'calling it. Most likely cause: using an API absent from '
      + 'AudioWorkletGlobalScope (performance.now() is NOT available there).');
    log('!! processorerror — worklet is dead');
  };
  S.source.connect(S.node);
  S.node.connect(S.sink);
  S.sink.connect(S.ctx.destination);
  R.audioContext = {
    negotiatedSampleRate: S.ctx.sampleRate,
    baseLatency: S.ctx.baseLatency ?? null,
    outputLatency: S.ctx.outputLatency ?? null,
    renderQuantum: 128,
    quantumMs: +(128 / S.ctx.sampleRate * 1000).toFixed(4),
    resampleRatio: +(S.ctx.sampleRate / 16000).toFixed(6),
  };

  S.node.port.onmessage = (e) => {
    const m = e.data;
    if (m.type === 'ready') { R.worklet = { ...m }; log('worklet ready', m); }
    else if (m.type === 'frame') { onFrame(m); }
    else if (m.type === 'preroll') {
      const w = S.prerollWaiters.get(m.id); if (w) { S.prerollWaiters.delete(m.id); w(m); }
    } else if (m.type === 'stats') { S._statsResolve && S._statsResolve(m); }
  };
  log('worklet started, ctx.sampleRate=', S.ctx.sampleRate);
  return R.audioContext;
}

function requestPreroll(endSample, ms) {
  return new Promise((res) => {
    const id = ++S.prerollSeq;
    S.prerollWaiters.set(id, res);
    S.node.port.postMessage({ cmd: 'preroll', id, endSample, ms });
    setTimeout(() => { if (S.prerollWaiters.delete(id)) res({ samples: new Float32Array(0), timeout: true }); }, 1000);
  });
}

function workletStats() {
  return new Promise((res) => { S._statsResolve = res; S.node.port.postMessage({ cmd: 'stats' }); });
}

// --------------------------------------------------------------- engine: direct
function onFrame(m) {
  if (!S.run) return;
  S.run.framesSeen++;
  S.run.frameRms.push(rms(m.samples));
  if (S.engine !== 'direct' || !S.direct) return;
  S.frameQ.push(m);
  pump();
}

async function pump() {
  if (S.busy) return;
  S.busy = true;
  while (S.frameQ.length) {
    const m = S.frameQ.shift();
    const backlog = S.frameQ.length;
    S.run.backlog.push(backlog);
    try { await S.direct.push(m.samples, m.endSample, directCallbacks()); }
    catch (e) { log('direct.push error', e.message); }
  }
  S.busy = false;
}

function directCallbacks() {
  return {
    onFrame: ({ prob, inferMs }) => { S.run.probs.push(prob); },
    onSpeechStart: ({ startSample }) => {
      S.run.starts++;
      S.run.pendingStart = { startSample, t: performance.now() };
      log(`speech start @sample ${startSample}`);
    },
    onMisfire: (p) => { S.run.misfires++; log('VAD misfire', p.durMs.toFixed(0) + 'ms'); },
    onSpeechEnd: async (p) => {
      S.run.ends++;
      S.run.eos.push(p.eosLatencyMs);
      // pre-roll: ask the worklet for the audio immediately BEFORE segment start
      const pr = await requestPreroll(p.startSample, S.prerollMs);
      const pre = pr.samples || new Float32Array(0);
      const full = new Float32Array(pre.length + p.audio.length);
      full.set(pre, 0); full.set(p.audio, pre.length);
      const seg = await recordSegment('direct', full, pre.length, p);
      log(`speech end: dur=${p.durMs.toFixed(0)}ms eos=${p.eosLatencyMs.toFixed(0)}ms `
        + `preroll=${(pre.length / 16).toFixed(0)}ms onset=${seg.onsetMs}ms`);
    },
  };
}

async function recordSegment(engine, full, prerollSamples, p) {
  const idx = R.segments.length + 1;
  const name = `${S.run.tag || 'seg'}-${engine}-${String(idx).padStart(3, '0')}.wav`;
  const blob = encodeWav(full, 16000);
  const onset = onsetMs(full, 16000);
  const prerollMsActual = +(prerollSamples / 16).toFixed(1);
  const seg = {
    idx, engine, file: name, tag: S.run.tag,
    totalMs: +(full.length / 16).toFixed(1),
    prerollMsRequested: S.prerollMs,
    prerollMsActual,
    onsetMs: onset,
    onsetMinusPrerollMs: onset === null ? null : +(onset - prerollMsActual).toFixed(1),
    segmentDurMs: p ? +p.durMs.toFixed(1) : null,
    eosLatencyMs: p ? +p.eosLatencyMs.toFixed(1) : null,
    peakDbfs: +dbfs(full).toFixed(2),
    bytes: blob.size,
  };
  if (S.run.upload !== false) seg.uploaded = await uploadWav(name, blob);
  if (S.run.keepBlobs) { seg.url = URL.createObjectURL(blob); }
  R.segments.push(seg);
  S.run.segments.push(seg);
  renderSegments();
  return seg;
}

// -------------------------------------------------------------- engine: vad-web
async function startVadWeb(vadOpts) {
  if (!window.vad) throw new Error('vad-web bundle not loaded');
  // `libraryDefaults: true` means: pass NOTHING tunable, so we measure what a
  // developer who just calls MicVAD.new() actually gets (v0.0.31:
  // positiveSpeechThreshold 0.3, negativeSpeechThreshold 0.25,
  // preSpeechPadMs 800, redemptionMs 1400).
  const bare = !!(vadOpts && vadOpts.libraryDefaults);
  const tunable = bare ? {} : {
    positiveSpeechThreshold: 0.5,
    negativeSpeechThreshold: 0.35,
    redemptionMs: 600,
    preSpeechPadMs: S.prerollMs,
    minSpeechMs: 250,
  };
  const opts = {
    getStream: async () => S.stream,
    audioContext: S.ctx,
    model: 'v5',
    baseAssetPath: new URL('vendor/vad/', location.href).href,
    onnxWASMBasePath: new URL('vendor/ort/', location.href).href,
    startOnLoad: false,
    ortConfig: (ort) => { ort.env.logLevel = 'error'; ort.env.wasm.numThreads = 1; },
    onFrameProcessed: (probs) => {
      if (!S.run) return;
      S.run.probs.push(probs.isSpeech);
      S.run.vwFrames++;
      if (probs.isSpeech >= (S.vwPosThreshold ?? 0.5)) S.run.vwLastSpeechFrame = S.run.vwFrames;
    },
    onSpeechStart: () => { if (S.run) { S.run.starts++; log('vad-web speech start'); } },
    onVADMisfire: () => { if (S.run) S.run.misfires++; },
    onSpeechEnd: async (audio) => {
      if (!S.run) return;
      S.run.ends++;
      // vad-web returns preSpeechPad-included audio; EOS is redemption frames
      // after the last >=positive frame, which we track from onFrameProcessed.
      const eos = (S.run.vwFrames - S.run.vwLastSpeechFrame) * SILERO_MS_PER_FRAME;
      S.run.eos.push(eos);
      const pad = R.engines.vadweb?.effectiveOptions?.preSpeechPadMs ?? S.prerollMs;
      const seg = await recordSegment('vadweb', audio, Math.round(pad * 16),
        { durMs: audio.length / 16, eosLatencyMs: eos });
      log(`vad-web speech end: dur=${seg.totalMs}ms eos=${eos.toFixed(0)}ms onset=${seg.onsetMs}ms`);
    },
    ...tunable,
    ...(vadOpts || {}),
  };
  delete opts.libraryDefaults;
  const t0 = performance.now();
  S.vadweb = await window.vad.MicVAD.new(opts);
  const initMs = performance.now() - t0;
  await S.vadweb.start();
  const eff = window.vad.getDefaultRealTimeVADOptions
    ? { ...window.vad.getDefaultRealTimeVADOptions(opts.model), ...opts } : opts;
  R.engines.vadweb = { ...(R.engines.vadweb || {}), initMs: +initMs.toFixed(1),
    usedLibraryDefaults: bare,
    effectiveOptions: {
      positiveSpeechThreshold: eff.positiveSpeechThreshold,
      negativeSpeechThreshold: eff.negativeSpeechThreshold,
      redemptionMs: eff.redemptionMs, preSpeechPadMs: eff.preSpeechPadMs,
      minSpeechMs: eff.minSpeechMs, model: eff.model, frameSamples: 512 } };
  // the derived EOS needs the threshold actually in force
  S.vwPosThreshold = eff.positiveSpeechThreshold;
  log('vad-web started in', initMs.toFixed(0), 'ms');
  return R.engines.vadweb;
}

// ------------------------------------------------------------------- main-thread
// idle probe: a 20 ms interval whose observed lateness measures main-thread
// contention while the pipeline runs.
function startIdleProbe() {
  const lat = []; let last = performance.now();
  const h = setInterval(() => {
    const now = performance.now();
    lat.push(now - last - 20); last = now;
  }, 20);
  return { stop: () => { clearInterval(h); return lat; } };
}

// ------------------------------------------------------------------- run control
async function startRun(tag, engine, opts = {}) {
  S.engine = engine;
  S.run = {
    tag, engine, t0: performance.now(), framesSeen: 0, probs: [], eos: [],
    starts: 0, ends: 0, misfires: 0, backlog: [], frameRms: [], segments: [],
    vwFrames: 0, vwLastSpeechFrame: 0,
    upload: opts.upload !== false, keepBlobs: !!opts.keepBlobs,
  };
  S.node && S.node.port.postMessage({ cmd: 'resetStats' });
  if (engine === 'direct') {
    if (!S.direct) throw new Error('direct engine not loaded');
    S.direct.reset(); S.direct.inferTimes = [];
  }
  S.run.idle = startIdleProbe();
  log(`run "${tag}" started (engine=${engine})`);
}

async function stopRun() {
  const r = S.run; if (!r) return null;
  const durMs = performance.now() - r.t0;
  const idle = r.idle.stop();
  const ws = S.node ? await workletStats() : { times: [], blocks: 0 };
  // let any in-flight segment finish
  await new Promise(res => setTimeout(res, 250));

  const inferTimes = r.engine === 'direct' ? (S.direct?.inferTimes || []) : [];
  const out = {
    tag: r.tag, engine: r.engine, durMs: +durMs.toFixed(1),
    durSec: +(durMs / 1000).toFixed(2),
    workletTimingMethod: ws.timingMethod || null,
    workletHasPerformanceApi: ws.hasPerformance ?? null,
    workletCpuMs: ws.cpuMs ?? null,
    workletWallMs: ws.wallMs ?? null,
    workletMeanPerBlockMs: (ws.blocks ? +((ws.cpuMs || 0) / ws.blocks).toFixed(5) : null),
    workletBlocks: ws.blocks,
    workletProcessCalls: ws.calls ?? null,
    workletEmptyInputBlocks: ws.emptyInput ?? null,
    workletSamplesOut16k: ws.totalOut ?? null,
    workletBlocksExpected: Math.round(durMs / 1000 * (S.ctx ? S.ctx.sampleRate / 128 : 0)),
    // duty cycle = (per-block cost) / (block wall period). >100% means the
    // worklet cannot keep up and audio will glitch.
    workletDutyCyclePct: (ws.wallMs ? +(((ws.cpuMs || 0) / ws.wallMs) * 100).toFixed(3) : null),
    frames16k: r.framesSeen,
    vadInferMs: summ(inferTimes),
    vadRealtimeFactor: inferTimes.length
      ? +((summ(inferTimes).p50) / SILERO_MS_PER_FRAME).toFixed(4) : null,
    queueBacklog: summ(r.backlog),
    mainThreadTimerLatenessMs: summ(idle),
    speechStarts: r.starts, speechEnds: r.ends, misfires: r.misfires,
    eosLatencyMs: summ(r.eos),
    triggersPerMinute: +((r.starts / (durMs / 60000))).toFixed(2),
    falseTriggersPerMinute: opts_isNoise(r.tag) ? +((r.starts / (durMs / 60000))).toFixed(2) : null,
    probStats: summ(r.probs),
    meanFrameRms: r.frameRms.length ? +(r.frameRms.reduce((a, b) => a + b, 0) / r.frameRms.length).toFixed(6) : null,
    meanFrameDbfs: r.frameRms.length
      ? +(20 * Math.log10(Math.max(r.frameRms.reduce((a, b) => a + b, 0) / r.frameRms.length, 1e-12))).toFixed(2) : null,
    segments: r.segments,
    gum: R.gum ? { echoCancellationApplied: R.gum.echoCancellationApplied,
                   noiseSuppressionApplied: R.gum.noiseSuppressionApplied,
                   autoGainControlApplied: R.gum.autoGainControlApplied } : null,
  };
  R.engines[r.engine] = R.engines[r.engine] || {};
  R.engines[r.engine].runs = R.engines[r.engine].runs || [];
  R.engines[r.engine].runs.push(out);
  S.run = null; S.engine = null;
  log('run finished:', out.tag, 'starts=' + out.speechStarts, 'ends=' + out.speechEnds);
  renderResults();
  return out;
}
const opts_isNoise = (tag) => /noise/i.test(tag || '');

// ------------------------------------------------------------------------- AEC
async function aecTrial(label, ec, clipUrl, playMs) {
  await teardown();
  await openMic({ audio: { echoCancellation: ec, noiseSuppression: ec, autoGainControl: ec, channelCount: 1 } });
  await startWorklet(S.prerollMs);
  await loadDirect();
  // silence baseline
  await startRun(`${label}-silence`, 'direct', { upload: false });
  await sleep(4000);
  const base = await stopRun();
  // playback
  const el = document.getElementById('clip');
  el.src = clipUrl; el.loop = true; el.volume = 1.0;
  await startRun(`${label}-playback`, 'direct', { upload: false });
  try { await el.play(); } catch (e) { log('playback blocked (autoplay policy):', e.message); }
  await sleep(playMs || 8000);
  el.pause(); el.currentTime = 0;
  const play = await stopRun();
  return {
    label, echoCancellationRequested: ec,
    echoCancellationApplied: R.gum.echoCancellationApplied,
    silenceDbfs: base.meanFrameDbfs, playbackDbfs: play.meanFrameDbfs,
    residualDeltaDb: +(play.meanFrameDbfs - base.meanFrameDbfs).toFixed(2),
    silenceTriggers: base.speechStarts, playbackTriggers: play.speechStarts,
    silenceTriggersPerMin: base.triggersPerMinute, playbackTriggersPerMin: play.triggersPerMinute,
    silenceSec: base.durSec, playbackSec: play.durSec,
  };
}

async function runAecPanel(clipUrl) {
  const on = await aecTrial('aec-on', true, clipUrl, 8000);
  const off = await aecTrial('aec-off', false, clipUrl, 8000);
  R.aec = {
    on, off,
    suppressionDb: +(off.residualDeltaDb - on.residualDeltaDb).toFixed(2),
    triggerReduction: off.playbackTriggers - on.playbackTriggers,
    caveat: 'Meaningful ONLY with real speakers + real mic in the room. A fake '
      + 'capture device or headphones makes these numbers say nothing about AEC.',
  };
  renderResults();
  return R.aec;
}

// ------------------------------------------------------------------- lifecycle
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function loadOrt() {
  if (S.ort) return S.ort;
  // vendor/ort/ort.wasm.min.js is UMD and sets window.ort
  if (!window.ort) throw new Error('window.ort missing — ort.wasm.min.js did not load');
  window.ort.env.wasm.wasmPaths = new URL('vendor/ort/', location.href).href;
  window.ort.env.wasm.numThreads = 1;    // no COOP/COEP by default -> no SAB
  window.ort.env.logLevel = 'error';
  S.ort = window.ort;
  R.engines.direct = R.engines.direct || {};
  R.engines.direct.ortEnv = {
    numThreads: window.ort.env.wasm.numThreads,
    simd: window.ort.env.wasm.simd, proxy: window.ort.env.wasm.proxy,
    crossOriginIsolated: window.crossOriginIsolated,
  };
  return S.ort;
}

async function loadDirect(opts) {
  await loadOrt();
  const t0 = performance.now();
  S.direct = await SileroDirect.create(S.ort, 'vendor/vad/silero_vad_v5.onnx', opts || {
    positiveSpeechThreshold: 0.5, negativeSpeechThreshold: 0.35,
    redemptionMs: 600, preSpeechPadMs: S.prerollMs, minSpeechMs: 250,
  });
  R.engines.direct = R.engines.direct || {};
  R.engines.direct.loadMs = +(performance.now() - t0).toFixed(1);
  R.engines.direct.modelFetchMs = +S.direct.fetchMs.toFixed(1);
  R.engines.direct.sessionInitMs = +S.direct.initMs.toFixed(1);
  R.engines.direct.modelBytes = S.direct.modelBytes;
  R.engines.direct.options = S.direct.opt;
  R.engines.direct.redemptionFrames = S.direct.redemptionFrames;
  R.engines.direct.minSpeechFrames = S.direct.minSpeechFrames;
  log('direct Silero loaded in', R.engines.direct.loadMs, 'ms');
  return R.engines.direct;
}

async function teardown() {
  try { if (S.vadweb) { await S.vadweb.destroy?.(); S.vadweb = null; } } catch (e) { }
  try { if (S.sink) { S.sink.disconnect(); S.sink = null; } } catch (e) { }
  try { if (S.node) { S.node.disconnect(); S.node = null; } } catch (e) { }
  try { if (S.source) { S.source.disconnect(); S.source = null; } } catch (e) { }
  try { if (S.ctx) { await S.ctx.close(); S.ctx = null; } } catch (e) { }
  try { if (S.stream) { S.stream.getTracks().forEach(t => t.stop()); S.stream = null; } } catch (e) { }
  S.direct = null; S.frameQ = []; S.busy = false;
}

// ------------------------------------------------------------------- rendering
function renderResults() {
  const el = document.getElementById('results');
  if (el) el.textContent = JSON.stringify(R, (k, v) => k === 'url' ? undefined : v, 2);
  const g = document.getElementById('gum-summary');
  if (g && R.gum) {
    g.innerHTML = R.gum.error ? `<b class="bad">${R.gum.error}</b>` : `
      <table>
      <tr><th>echoCancellation applied</th><td class="${R.gum.echoCancellationApplied ? 'good' : 'bad'}">${R.gum.echoCancellationApplied}</td></tr>
      <tr><th>noiseSuppression applied</th><td class="${R.gum.noiseSuppressionApplied ? 'good' : 'bad'}">${R.gum.noiseSuppressionApplied}</td></tr>
      <tr><th>autoGainControl applied</th><td class="${R.gum.autoGainControlApplied ? 'good' : 'bad'}">${R.gum.autoGainControlApplied}</td></tr>
      <tr><th>channelCount</th><td>${R.gum.channelCount}</td></tr>
      <tr><th>track sampleRate</th><td>${R.gum.negotiatedSampleRate}</td></tr>
      <tr><th>AudioContext sampleRate</th><td>${R.audioContext?.negotiatedSampleRate ?? '-'}</td></tr>
      <tr><th>device</th><td>${R.gum.trackLabel}</td></tr>
      </table>`;
  }
  const a = document.getElementById('aec-summary');
  if (a && R.aec) {
    const row = (o) => `<tr><th>${o.label}</th><td>${o.echoCancellationApplied}</td>
      <td>${o.silenceDbfs}</td><td>${o.playbackDbfs}</td><td><b>${o.residualDeltaDb}</b></td>
      <td>${o.silenceTriggers}</td><td><b>${o.playbackTriggers}</b></td></tr>`;
    a.innerHTML = `<table>
      <tr><th>trial</th><th>AEC applied</th><th>silence dBFS</th><th>playback dBFS</th>
          <th>Δ dB</th><th>triggers (silence)</th><th>triggers (playback)</th></tr>
      ${row(R.aec.on)}${row(R.aec.off)}
      </table><p><b>AEC suppression = ${R.aec.suppressionDb} dB</b>
      (off Δ minus on Δ). ${R.aec.caveat}</p>`;
  }
}

function renderSegments() {
  const el = document.getElementById('segments');
  if (!el) return;
  el.innerHTML = `<table><tr><th>#</th><th>engine</th><th>file</th><th>total ms</th>
    <th>pre-roll ms</th><th>onset ms</th><th>onset − pre-roll</th><th>EOS ms</th><th></th></tr>`
    + R.segments.map(s => `<tr><td>${s.idx}</td><td>${s.engine}</td><td>${s.file}</td>
      <td>${s.totalMs}</td><td>${s.prerollMsActual}</td>
      <td class="${s.onsetMs > 50 ? 'good' : 'bad'}">${s.onsetMs}</td>
      <td>${s.onsetMinusPrerollMs}</td><td>${s.eosLatencyMs ?? '-'}</td>
      <td>${s.url ? `<a download="${s.file}" href="${s.url}">download</a>` : (s.uploaded || '')}</td></tr>`).join('')
    + '</table>';
}

/**
 * Cross-check for the worklet CPU number. The worklet can only be timed with
 * Date.now() (see capture-worklet.js), so run the IDENTICAL FIR + decimation on
 * the main thread, where performance.now() exists, over the same block size.
 * Same arithmetic, same JIT, different clock — if the two agree, the batch
 * timing is trustworthy.
 */
function benchResampler({ inRate = 48000, taps = 63, blocks = 4000 } = {}) {
  const TARGET = 16000, N = 128;
  const h = new Float32Array(taps);
  const fc = 7600 / inRate, mid = (taps - 1) / 2;
  let sum = 0;
  for (let i = 0; i < taps; i++) {
    const n = i - mid;
    const sinc = n === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * n) / (Math.PI * n);
    const w = 0.42 - 0.5 * Math.cos((2 * Math.PI * i) / (taps - 1))
            + 0.08 * Math.cos((4 * Math.PI * i) / (taps - 1));
    h[i] = sinc * w; sum += h[i];
  }
  for (let i = 0; i < taps; i++) h[i] /= sum;
  const hist = new Float32Array(taps);
  const ring = new Float32Array(Math.ceil(2.0 * TARGET));
  const blk = new Float32Array(N);
  for (let i = 0; i < N; i++) blk[i] = Math.sin(i * 0.07) * 0.3;
  const ratio = inRate / TARGET;
  let histPos = 0, phase = 0, rw = 0, out = 0;
  // performance.now() is clamped to ~100 us in Chrome and one block costs
  // ~15 us, so time BATCHES of blocks in a tight loop (here wall time IS cpu
  // time — unlike the worklet, which idles between quanta) and divide.
  const BATCH = 200;
  const times = [];
  for (let b = 0; b < blocks; b++) {
    const t0 = performance.now();
    for (let rep = 0; rep < BATCH; rep++)
    for (let i = 0; i < N; i++) {
      hist[histPos] = blk[i]; histPos = (histPos + 1) % taps;
      phase += 1;
      while (phase >= ratio) {
        phase -= ratio;
        let acc = 0, idx = histPos;
        for (let k = taps - 1; k >= 0; k--) { acc += h[k] * hist[idx]; idx = (idx + 1) % taps; }
        ring[rw] = acc; rw = (rw + 1) % ring.length; out++;
      }
    }
    times.push((performance.now() - t0) / BATCH);
  }
  const warm = times.slice(Math.floor(times.length * 0.25));   // drop JIT warmup
  const res = {
    inRate, taps, blocks, batchPerSample: BATCH, samplesOut: out,
    perBlockMs: summ(warm),
    blockPeriodMs: +(N / inRate * 1000).toFixed(4),
    dutyCyclePct: +((summ(warm).p50 / (N / inRate * 1000)) * 100).toFixed(3),
    method: 'main thread, performance.now() over ' + BATCH
      + '-block batches, identical FIR+decimation kernel',
  };
  R.resamplerBench = R.resamplerBench || {};
  R.resamplerBench[inRate] = res;
  return res;
}

// ------------------------------------------------------------------ asset sizes
async function measureAssetSizes() {
  const files = [
    'vendor/ort/ort.wasm.min.js', 'vendor/ort/ort-wasm-simd-threaded.wasm',
    'vendor/vad/vad-bundle.min.js', 'vendor/vad/vad.worklet.bundle.min.js',
    'vendor/vad/silero_vad_v5.onnx',
  ];
  const out = {};
  for (const f of files) {
    try {
      const r = await fetch(f, { method: 'HEAD' });
      out[f] = { bytes: +(r.headers.get('content-length') || 0),
                 encoding: r.headers.get('content-encoding') || 'identity' };
    } catch (e) { out[f] = { error: e.message }; }
  }
  // what the browser ACTUALLY transferred
  try {
    const entries = performance.getEntriesByType('resource')
      .filter(e => /vendor\//.test(e.name))
      .map(e => ({ name: e.name.replace(location.origin + '/', ''),
                   transferSize: e.transferSize, encodedBodySize: e.encodedBodySize,
                   decodedBodySize: e.decodedBodySize, durationMs: +e.duration.toFixed(1) }));
    out._transferred = entries;
  } catch (e) { }
  R.assetSizes = out;
  return out;
}

// ------------------------------------------------------------------- public API
window.__spike = {
  R, openMic, startWorklet, loadDirect, startVadWeb, startRun, stopRun,
  teardown, sleep, measureAssetSizes, runAecPanel, aecTrial, workletStats,
  encodeWav, onsetMs, summ, benchResampler,
  setPreroll: (ms) => { S.prerollMs = ms; },
  state: S,
  async postResults() {
    const r = await fetch('/results', { method: 'POST', body: JSON.stringify(R, null, 2) });
    return await r.text();
  },
  /** One-call headless scenario: open mic, run one engine for N seconds. */
  async scenario({ tag, engine = 'direct', seconds = 20, prerollMs = 500, vadOpts, constraints, upload = true }) {
    S.prerollMs = prerollMs;
    if (!S.stream) await openMic(constraints);
    if (!S.ctx) await startWorklet(prerollMs);
    if (engine === 'direct') { if (!S.direct) await loadDirect(vadOpts); else S.direct.setOptions(vadOpts || S.direct.opt); }
    else if (!S.vadweb) await startVadWeb(vadOpts);
    await startRun(tag, engine, { upload });
    await sleep(seconds * 1000);
    return await stopRun();
  },
};

// ------------------------------------------------------------------ UI wiring
function wire() {
  const $ = (id) => document.getElementById(id);
  const guard = (fn) => async () => { try { await fn(); } catch (e) { log('ERROR:', e.message); console.error(e); } };

  $('btn-open').onclick = guard(async () => {
    await openMic(); await startWorklet(+$('preroll').value || 500);
    await measureAssetSizes(); await loadDirect(readVadOpts()); renderResults();
  });
  $('btn-open-noaec').onclick = guard(async () => {
    await teardown();
    await openMic({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, channelCount: 1 } });
    await startWorklet(+$('preroll').value || 500); await loadDirect(readVadOpts()); renderResults();
  });
  $('btn-run-direct').onclick = guard(async () => {
    if (S.direct) S.direct.setOptions(readVadOpts());
    await startRun($('tag').value || 'manual', 'direct', { keepBlobs: true });
    $('btn-stop').disabled = false;
  });
  $('btn-run-vadweb').onclick = guard(async () => {
    if (!S.vadweb) await startVadWeb(readVadOpts());
    await startRun($('tag').value || 'manual', 'vadweb', { keepBlobs: true });
    $('btn-stop').disabled = false;
  });
  $('btn-stop').onclick = guard(async () => { await stopRun(); $('btn-stop').disabled = true; });
  $('btn-aec').onclick = guard(async () => { $('aec-summary').textContent = 'running ~25s...'; await runAecPanel('assets/tts_playback.wav'); });
  $('btn-copy').onclick = guard(async () => {
    await navigator.clipboard.writeText(JSON.stringify(R, (k, v) => k === 'url' ? undefined : v, 2));
    $('btn-copy').textContent = 'copied!'; setTimeout(() => $('btn-copy').textContent = 'copy results JSON', 1500);
  });
  $('btn-post').onclick = guard(async () => { log('posted ->', await window.__spike.postResults()); });
  $('btn-teardown').onclick = guard(async () => { await teardown(); log('torn down'); });

  const readVadOpts = () => ({
    positiveSpeechThreshold: +$('pos').value, negativeSpeechThreshold: +$('neg').value,
    redemptionMs: +$('redemption').value, preSpeechPadMs: +$('preroll').value,
    minSpeechMs: +$('minspeech').value,
  });
  window.__spike.readVadOpts = readVadOpts;

  R.secureContextNote = window.isSecureContext ? 'secure context OK'
    : 'NOT a secure context — getUserMedia will fail (use http://localhost:<port>)';
  $('ctx-banner').innerHTML = window.isSecureContext
    ? `<span class="good">secure context OK</span> — ${location.origin}`
    : `<span class="bad">NOT A SECURE CONTEXT (${location.origin}) — navigator.mediaDevices will be undefined. `
      + `Use http://localhost:&lt;port&gt;, or ssh -L from another machine.</span>`;
  renderResults();
  log('harness ready. secureContext=', window.isSecureContext,
      'crossOriginIsolated=', window.crossOriginIsolated);
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire);
else wire();
