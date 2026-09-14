/* Headless driver for the voice spike harness.
 *
 * Runs Chromium with a FAKE audio capture device fed from a fixture WAV whose
 * speech onset timestamp we chose, so items 2-4 of the spike (worklet CPU, VAD
 * inference time, EOS latency, false-trigger rate, pre-roll onset position) are
 * measurable with no human present.
 *
 * It proves NOTHING about acoustic echo cancellation — the fake device bypasses
 * the speaker->room->mic loop entirely. See README.
 */
// Playwright is NOT a dependency of this repo (no package.json change for a
// spike). Resolve it from wherever it already lives: $PLAYWRIGHT_DIR, or the
// npx cache. tools/headless.sh sets PLAYWRIGHT_DIR for you.
const PW = process.env.PLAYWRIGHT_DIR;
if (!PW) throw new Error('set PLAYWRIGHT_DIR (see tools/headless.sh)');
const { chromium } = await import(PW + '/playwright/index.mjs');
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const PORT = process.env.SPIKE_PORT || '8777';
const BASE = `http://localhost:${PORT}`;

const args = Object.fromEntries(process.argv.slice(2)
  .filter(a => a.startsWith('--')).map(a => { const [k, ...v] = a.slice(2).split('='); return [k, v.join('=') || true]; }));

const fixtures = JSON.parse(fs.readFileSync(path.join(ROOT, 'assets', 'fixtures.json'), 'utf8'));

/** One browser launch == one fake audio file (Chrome fixes it at launch). */
async function withFixture(fixtureName, fn, { aec = true } = {}) {
  const fx = fixtures.fixtures[fixtureName];
  if (!fx) throw new Error('unknown fixture ' + fixtureName);
  const wav = path.join(ROOT, 'assets', fx.path);
  const browser = await chromium.launch({
    headless: true,
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      // Chrome LOOPS this file for the lifetime of the browser, which is why
      // each fixture is built as exactly one loop period.
      `--use-file-for-fake-audio-capture=${wav}`,
      '--autoplay-policy=no-user-gesture-required',
      '--allow-file-access-from-files',
      '--no-sandbox',
    ],
  });
  const ctx = await browser.newContext({ permissions: ['microphone'] });
  const page = await ctx.newPage();
  const errs = [];
  page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  page.on('pageerror', e => errs.push('pageerror: ' + e.message));
  await page.goto(BASE + '/', { waitUntil: 'load' });
  await page.waitForFunction(() => !!window.__spike, null, { timeout: 20000 });
  let out;
  try { out = await fn(page, fx); } finally {
    const version = browser.version();
    out = { ...(out || {}), _chromium: version, _consoleErrors: errs.slice(0, 12), _fixture: { name: fixtureName, ...fx } };
    await browser.close();
  }
  return out;
}

const evalScenario = (page, opts) => page.evaluate(o => window.__spike.scenario(o), opts);

async function main() {
  const report = { generatedAt: new Date().toISOString(), base: BASE, runs: {}, fixtures: fixtures.fixtures };

  // ---- A. direct Silero on clean speech: CPU, inference, EOS, pre-roll onset
  for (const [key, fixture, seconds, vadOpts] of [
    ['direct_clean_red600', 'fix_onset_orca_send', 30, { redemptionMs: 600 }],
    ['direct_clean_red400', 'fix_onset_orca_send', 30, { redemptionMs: 400 }],
    ['direct_clean_red1400', 'fix_onset_orca_send', 30, { redemptionMs: 1400 }],
    ['direct_sentence_red600', 'fix_onset_sentence', 30, { redemptionMs: 600 }],
    ['direct_snr10_red600', 'fix_speech_snr10', 30, { redemptionMs: 600 }],
    ['direct_snr05_red600', 'fix_speech_snr05', 30, { redemptionMs: 600 }],
  ]) {
    if (args.only && !String(args.only).split(',').includes(key)) continue;
    process.stderr.write(`[headless] ${key} (${fixture}, ${seconds}s)\n`);
    report.runs[key] = await withFixture(fixture, async (page) => {
      const r = await evalScenario(page, {
        tag: key, engine: 'direct', seconds, prerollMs: 500,
        vadOpts: { positiveSpeechThreshold: 0.5, negativeSpeechThreshold: 0.35,
                   minSpeechMs: 250, preSpeechPadMs: 500, ...vadOpts },
      });
      const extra = await page.evaluate(async () => ({
        resamplerBench: {
          at48k: window.__spike.benchResampler({ inRate: 48000, blocks: 60 }),
          atCtxRate: window.__spike.benchResampler({
            inRate: window.__spike.state.ctx.sampleRate, blocks: 60 }),
        },
        assets: await window.__spike.measureAssetSizes(),
        results: { gum: window.__spikeResults.gum, audioContext: window.__spikeResults.audioContext,
                   worklet: window.__spikeResults.worklet, engines: window.__spikeResults.engines },
      }));
      return { run: r, ...extra };
    });
  }

  // ---- B. false triggers on pure noise (no speech in the fixture at all)
  for (const [key, fixture] of [
    ['noise_quiet', 'fix_noise_pink_quiet'],
    ['noise_room', 'fix_noise_pink_room'],
    ['noise_loud', 'fix_noise_pink_loud'],
  ]) {
    if (args.only && !String(args.only).split(',').includes(key)) continue;
    process.stderr.write(`[headless] ${key} (${fixture}, 60s)\n`);
    report.runs[key] = await withFixture(fixture, async (page) => ({
      run: await evalScenario(page, {
        tag: key, engine: 'direct', seconds: 60, prerollMs: 500, upload: false,
        vadOpts: { positiveSpeechThreshold: 0.5, negativeSpeechThreshold: 0.35,
                   redemptionMs: 600, preSpeechPadMs: 500, minSpeechMs: 250 },
      }),
    }));
  }

  // ---- B2. false triggers at the LIBRARY's more trigger-happy thresholds
  for (const [key, fixture] of [
    ['noise_room_pos030', 'fix_noise_pink_room'],
    ['noise_loud_pos030', 'fix_noise_pink_loud'],
  ]) {
    if (args.only && !String(args.only).split(',').includes(key)) continue;
    process.stderr.write(`[headless] ${key} (${fixture}, 60s, pos=0.30/neg=0.25 = vad-web defaults)\n`);
    report.runs[key] = await withFixture(fixture, async (page) => ({
      run: await evalScenario(page, {
        tag: key, engine: 'direct', seconds: 60, prerollMs: 500, upload: false,
        vadOpts: { positiveSpeechThreshold: 0.30, negativeSpeechThreshold: 0.25,
                   redemptionMs: 1400, preSpeechPadMs: 800, minSpeechMs: 250 },
      }),
    }));
  }

  // ---- C. @ricky0123/vad-web on the same clean fixture, library defaults AND tuned
  for (const [key, vadOpts] of [
    ['vadweb_defaults', { libraryDefaults: true }],             // genuinely untouched
    ['vadweb_tuned', { positiveSpeechThreshold: 0.5, negativeSpeechThreshold: 0.35,
                       redemptionMs: 600, preSpeechPadMs: 500, minSpeechMs: 250 }],
  ]) {
    if (args.only && !String(args.only).split(',').includes(key)) continue;
    process.stderr.write(`[headless] ${key} (fix_onset_orca_send, 30s)\n`);
    report.runs[key] = await withFixture('fix_onset_orca_send', async (page) => {
      const r = await evalScenario(page, {
        tag: key, engine: 'vadweb', seconds: 30, prerollMs: 500, vadOpts,
      });
      const extra = await page.evaluate(() => ({
        assets: window.__spikeResults.assetSizes,
        engines: window.__spikeResults.engines,
        transferred: performance.getEntriesByType('resource')
          .filter(e => /vendor\//.test(e.name))
          .map(e => ({ name: e.name.split('/').slice(-2).join('/'),
                       transferSize: e.transferSize, encodedBodySize: e.encodedBodySize,
                       decodedBodySize: e.decodedBodySize })),
      }));
      return { run: r, ...extra };
    });
  }

  // ---- D. AEC panel. Runs the SAME code path Zach will click, but with a fake
  //         capture device there is no acoustic loop at all, so the residual
  //         numbers are meaningless as AEC evidence. This only proves the panel
  //         executes end to end.
  if (!args.only || String(args.only).split(',').includes('aec_mechanical')) {
    process.stderr.write('[headless] aec_mechanical (proves the panel runs, NOT that AEC works)\n');
    report.runs.aec_mechanical = await withFixture('fix_noise_pink_quiet', async (page) => ({
      aec: await page.evaluate(() => window.__spike.runAecPanel('assets/tts_playback.wav')),
      caveat: 'FAKE capture device: the speaker->room->mic path does not exist. '
            + 'These numbers say nothing about acoustic echo cancellation.',
    }));
  }

  const dest = path.join(ROOT, 'out', args.out || 'headless-report.json');
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, JSON.stringify(report, null, 2));
  process.stderr.write(`[headless] wrote ${dest}\n`);
  console.log(JSON.stringify(Object.fromEntries(Object.entries(report.runs).map(([k, v]) => [k, {
    starts: v.run?.speechStarts, ends: v.run?.speechEnds, misfires: v.run?.misfires,
    eosP50: v.run?.eosLatencyMs?.p50, workletP50: v.run?.workletProcessMs?.p50,
    inferP50: v.run?.vadInferMs?.p50, segs: v.run?.segments?.length,
    onsets: v.run?.segments?.map(s => s.onsetMs),
  }])), null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
