/* Headless driver for the SPIKE 3 keyword-spotter harness.
 *
 * Two kinds of run, see kws.js:
 *   - OFFLINE: fixture WAV -> engine directly, no audio graph. Exact keyword
 *     timing, and ~7x realtime so 24 minutes of negative audio is affordable.
 *   - LIVE:    Chrome's fake capture device -> getUserMedia -> SPIKE 1's
 *     capture worklet -> engine, at realtime. One run, as an existence proof.
 *
 * Porcupine cannot be run at all without a Picovoice AccessKey; the matrix
 * probes it anyway and records the exact failure, because "it refuses without
 * a key" is itself one of the findings.
 */
const PW = process.env.PLAYWRIGHT_DIR;
if (!PW) throw new Error('set PLAYWRIGHT_DIR (see tools/headless.sh)');
const { chromium } = await import(PW + '/playwright/index.mjs');
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');              // spikes/voice/kws
const PORT = process.env.SPIKE_PORT || '8791';
const BASE = `http://localhost:${PORT}/kws/index.html`;

const args = Object.fromEntries(process.argv.slice(2)
  .filter(a => a.startsWith('--')).map(a => { const [k, ...v] = a.slice(2).split('='); return [k, v.join('=') || true]; }));
const want = args.only ? String(args.only).split(',') : null;
const pick = (k) => !want || want.includes(k);

const fixtures = JSON.parse(fs.readFileSync(path.join(ROOT, 'assets', 'kws_fixtures.json'), 'utf8'));

async function withPage(fn, { fakeAudio = null } = {}) {
  const extra = fakeAudio ? [
    '--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',
    `--use-file-for-fake-audio-capture=${fakeAudio}`,
    '--autoplay-policy=no-user-gesture-required',
  ] : [];
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', ...extra] });
  const ctx = await browser.newContext(fakeAudio ? { permissions: ['microphone'] } : {});
  const page = await ctx.newPage();
  const errs = [];
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text().slice(0, 300)); });
  page.on('pageerror', e => errs.push('pageerror: ' + e.message.slice(0, 300)));
  await page.goto(BASE, { waitUntil: 'load' });
  await page.waitForFunction(() => !!window.__kws, null, { timeout: 30000 });
  let out;
  try { out = await fn(page); } finally {
    out = { ...(out || {}), _chromium: browser.version(), _consoleErrors: errs.slice(0, 8) };
    await browser.close();
  }
  return out;
}

const offline = (page, o) => page.evaluate(
  x => window.__kws.runOffline(x).catch(e => ({ err: String(e.stack || e).slice(0, 800) })), o);

async function main() {
  const report = { generatedAt: new Date().toISOString(), base: BASE, runs: {},
                   fixtures: Object.fromEntries(Object.entries(fixtures.fixtures)
                     .map(([k, v]) => [k, { ...v, instances: undefined,
                                            nInstances: v.instances ? v.instances.length : undefined }])) };

  // ---- 0. environment + Porcupine probe (no AccessKey exists in this repo) --
  if (pick('porcupine_probe')) {
    process.stderr.write('[kws] porcupine_probe\n');
    report.runs.porcupine_probe = await withPage(async (page) => ({
      env: await page.evaluate(() => window.__kws.env()),
      noKey: await page.evaluate(() => window.__kws.initPorcupine({ accessKey: '', keyword: 'Computer' })),
      // syntactically valid base64, semantically bogus: passes the SDK's
      // client-side check and reaches the wasm's real validation
      bogusKey: await page.evaluate(() => window.__kws.initPorcupine({
        accessKey: 'bm90LWEtcmVhbC1hY2Nlc3Mta2V5LXNwaWtlLTM=', keyword: 'Computer' })),
      // The npm package's bundled built-in .ppn files are stale in 4.0.1 (see
      // bogusKey above), so also try a keyword file fetched from the porcupine
      // repo at master: that gets past the keyword loader and lets the REAL
      // blocker -- AccessKey activation inside the wasm -- surface on its own.
      bogusKeyPublicPpn: await page.evaluate(() => window.__kws.initPorcupine({
        accessKey: 'bm90LWEtcmVhbC1hY2Nlc3Mta2V5LXNwaWtlLTM=', keyword: 'Computer',
        keywordPath: '/kws/vendor/porcupine/computer_wasm.ppn' })),
      exports: await page.evaluate(() => Object.keys(window.PorcupineWeb)),
    }));
  }

  // ---- A. openWakeWord: detection rate + latency on its OWN keyword --------
  const detMatrix = [
    ['oww_hey_jarvis', 'hey_jarvis_v0.1', 'det_hey_jarvis'],
    ['oww_hey_jarvis_carrier', 'hey_jarvis_v0.1', 'det_hey_jarvis_carrier'],
    ['oww_alexa', 'alexa_v0.1', 'det_alexa'],
    ['oww_alexa_carrier', 'alexa_v0.1', 'det_alexa_carrier'],
    ['oww_hey_mycroft', 'hey_mycroft_v0.1', 'det_hey_mycroft'],
    ['oww_hey_mycroft_carrier', 'hey_mycroft_v0.1', 'det_hey_mycroft_carrier'],
  ];
  for (const [key, cls, fx] of detMatrix) {
    if (!pick(key)) continue;
    process.stderr.write(`[kws] ${key}\n`);
    report.runs[key] = await withPage(page => offline(page,
      { tag: key, engine: 'oww', fixture: fx, classifier: cls, keepTrace: true }));
  }

  // ---- B. cross-keyword: does a pre-trained model fire on OUR phrases? -----
  //        (it must not: "orca send" is not "hey jarvis")
  for (const fx of ['det_orca_send', 'det_orca_cancel', 'det_orca_stop', 'det_orca_pause']) {
    const key = 'cross_' + fx;
    if (!pick(key)) continue;
    process.stderr.write(`[kws] ${key}\n`);
    report.runs[key] = await withPage(page => offline(page,
      { tag: key, engine: 'oww', fixture: fx, classifier: 'hey_jarvis_v0.1' }));
  }

  // ---- C. false accepts: speech with no keyword, and pure noise ------------
  for (const cls of ['hey_jarvis_v0.1', 'alexa_v0.1']) {
    for (const fx of ['neg_speech', 'neg_pink_quiet', 'neg_pink_room', 'neg_pink_loud']) {
      const key = `fa_${cls.split('_v')[0]}_${fx}`;
      if (!pick(key)) continue;
      process.stderr.write(`[kws] ${key}\n`);
      report.runs[key] = await withPage(page => offline(page,
        { tag: key, engine: 'oww', fixture: fx, classifier: cls }));
    }
  }

  // ---- C2. the same detection fixture, PACED to realtime but with no audio
  //          graph. Isolates the CPU-regime effect the live run shows.
  for (const [key, cls, fx] of [['paced_hey_jarvis', 'hey_jarvis_v0.1', 'det_hey_jarvis']]) {
    if (!pick(key)) continue;
    process.stderr.write(`[kws] ${key} (realtime-paced, no audio graph)\n`);
    report.runs[key] = await withPage(page => offline(page,
      { tag: key, engine: 'oww', fixture: fx, classifier: cls, paced: true }));
  }

  // ---- C4. the keyword spoken WHILE the assistant is talking (spec 5.2) ----
  for (const slug of ['hey_jarvis', 'alexa']) {
    for (const snr of ['snr10', 'snr00', 'snrm06']) {
      const key = `bg_${slug}_${snr}`;
      if (!pick(key)) continue;
      process.stderr.write(`[kws] ${key}\n`);
      report.runs[key] = await withPage(page => offline(page, {
        tag: key, engine: 'oww', fixture: key,
        classifier: slug === 'hey_jarvis' ? 'hey_jarvis_v0.1' : 'alexa_v0.1',
      }));
    }
  }

  // ---- C3. THREE keywords at once over the one shared backbone. The design
  //          needs four (send/cancel/stop/pause), so what an extra keyword
  //          costs is a first-order question.
  for (const [key, paced] of [['multi3', false], ['multi3_paced', true]]) {
    if (!pick(key)) continue;
    process.stderr.write(`[kws] ${key}\n`);
    report.runs[key] = await withPage(page => offline(page, {
      tag: key, engine: 'oww', fixture: 'det_hey_jarvis', paced,
      classifiers: ['hey_jarvis_v0.1', 'alexa_v0.1', 'hey_mycroft_v0.1'],
    }));
  }

  // ---- D. live: realtime through getUserMedia + SPIKE 1's capture worklet --
  if (pick('live_oww')) {
    process.stderr.write('[kws] live_oww (realtime, fake capture device)\n');
    const wav = path.join(ROOT, 'assets', fixtures.fixtures.live_hey_jarvis_48k.path);
    report.runs.live_oww = await withPage(page => page.evaluate(
      o => window.__kws.runLive(o).catch(e => ({ err: String(e.stack || e).slice(0, 800) })),
      { tag: 'live_oww', engine: 'oww', classifier: 'hey_jarvis_v0.1', seconds: 34, threshold: 0.5 },
    ), { fakeAudio: wav });
    report.runs.live_oww._fixture = fixtures.fixtures.live_hey_jarvis_48k;
  }

  const dest = path.join(ROOT, 'out', args.out || 'kws-report.json');
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, JSON.stringify(report, null, 2));
  process.stderr.write(`[kws] wrote ${dest}\n`);

  const summary = {};
  for (const [k, v] of Object.entries(report.runs)) {
    if (!v.byThreshold) continue;
    const t = v.byThreshold['0.5'] || {};
    summary[k] = t.instances !== undefined
      ? { det: `${t.detected}/${t.instances}`, extraFires: t.extraFires,
          latP50: t.latencyMs && t.latencyMs.p50, latP95: t.latencyMs && t.latencyMs.p95,
          frameP50: v.engineInfo?.perFrameMs?.total?.p50 }
      : { detections: t.detections, perHour: t.perHour, durS: Math.round(v.fixtureDurationMs / 1000),
          ceiling: v.scoreCeiling };
  }
  console.log(JSON.stringify(summary, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
