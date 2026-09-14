# SPIKE 3 — in-browser keyword spotting (openWakeWord vs Porcupine)

De-risks `voice_mode_spec.md` §5: can an always-on browser keyword spotter
carry spoken control — §5.2's STOP/PAUSE during TTS playback, and possibly
§5.1's SEND, since SPIKE 2 measured the GB10 Whisper lane transcribing an
isolated "Orca send." as **"or Cassand."** deterministically, which makes
matching `orca send` in a transcript unsafe.

Self-contained. **Not wired into the app**: nothing here is imported by
`assets/js/app.js`, nothing lives under `priv/static`, `package.json` /
`mix.exs` are untouched, and no dependency was added to this repo.

It reuses SPIKE 1's `vendor/ort` (onnxruntime-web 1.29.0) and
`capture-worklet.js` **read-only, over HTTP** — nothing under
`spikes/voice/` outside `kws/` is modified.

---

## TL;DR

| # | Question | Answer |
|---|---|---|
| 1 | Can Porcupine be evaluated at all here? | **No.** It refuses to initialise without a genuine Picovoice AccessKey — built-in keywords included. Measured, not assumed (§3.1). |
| 2 | Is there a free tier to get one? | **No longer a meaningful one.** Picovoice's own FAQ: *"there are no dedicated free or paid plans for personal or non-commercial use"*, and the Free Trial is one-time, enterprise-developer-only. Porcupine bills by **monthly active browser instances** (§3.2). |
| 3 | Does openWakeWord work in the browser on ort? | **Yes — 96/96 detections** across three pre-trained keywords × 16 synthesized renderings × 2 contexts, at every threshold 0.3/0.5/0.7, with **0 extra fires** (§4.1). |
| 4 | How fast does it fire? | **Within one 80 ms chunk of the word ending** (audio-time p50 −80 ms, p95 ≤ +190 ms); frame→callback handling p50 11.7 ms in the live path (§4.2). |
| 5 | What does it cost? | **~10 ms per 80 ms frame back-to-back, ~26 ms realtime-paced, p50 11.6 / p95 39.3 ms live → 13–44 % duty cycle of one core.** The pacing matters more than the audio graph (§4.5). |
| 6 | What does a second keyword cost? | **~0.3 ms.** The melspectrogram+embedding backbone is shared; only the classifier repeats (§4.6). |
| 7 | False accepts? | **0 in 15 minutes of pink noise** at three levels. On speech: **1 in 9.2 min** (`hey jarvis`) / **3 in 9.2 min** (`alexa`) — but **every single one landed on a deliberate near-miss**, 0 on the 120 ordinary sentences (§4.3). |
| 8 | Does it work while the assistant is talking — §5.2's actual case? | **Only if the mic sees you well above the playback.** 16/16 at +10 dB SNR, **7/16 at 0 dB, 2/16 at −6 dB** (§4.4). This makes AEC efficacy — SPIKE 1's one unanswered question — the binding constraint on §5.2, not the spotter. |
| 9 | Can "orca send" be a keyword? | Not today. Custom openWakeWord models are trainable (Apache-2.0, no key, no vendor), but need a GPU training run, not a config change (§5). |

**Recommendation in one line:** adopt **openWakeWord** — Porcupine is
licence-blocked for this project before any technical question is reached —
use it for §5.2 STOP/PAUSE, and **do not** move SEND onto it in phase 1
(§7).

---

## Layout

```
spikes/voice/kws/
  index.html                   harness UI (manual poking)
  kws.js                       engines + offline/live runners + window.__kws
  tools/
    tts_fetch.py               render every phrase on the homelab TTS endpoint
    make_kws_fixtures.py       build 16 kHz fixtures with exact keyword timing
    fetch_vendor.sh            pinned porcupine-web 4.0.1 + openWakeWord v0.5.1
    serve.sh / server.py       static server, root = spikes/voice/ (port 8791)
    headless.mjs / headless.sh playwright driver -> out/kws-report.json
    asset_sizes.py             raw/gzip wire-size accounting
    label_false_accepts.py     name each false accept's utterance, not just count it
  vendor/                      gitignored, ~9.4 MB, re-fetch with fetch_vendor.sh
  assets/                      gitignored WAVs; kws_fixtures.json + phrases.json tracked
  out/                         kws-report.json, asset-sizes.json, false-accepts.json
```

## Running it

```bash
cd spikes/voice/kws
./tools/serve.sh                 # http://localhost:8791/kws/  (8777 is SPIKE 1's)
python3 tools/tts_fetch.py --renders 16     # 312 TTS renders, cached, ~15 min cold
python3 tools/make_kws_fixtures.py          # builds every fixture, ~30 s
PLAYWRIGHT_DIR=/home/zach/.npm/_npx/e41f203b7505f1fb/node_modules \
  ./tools/headless.sh            # full matrix, ~13 min -> out/kws-report.json
python3 tools/label_false_accepts.py
python3 tools/asset_sizes.py
```

`./tools/headless.sh --only=oww_hey_jarvis,live_oww` runs a subset.

---

## Environment these numbers came from

| | |
|---|---|
| Headless browser | **Chromium 153.0.8010.12** (playwright 1.63.0 bundle) |
| Host | debian, x86_64, Linux 6.12.90 — **shared with other agent sessions**, see the CPU caveat in §4.5 |
| onnxruntime-web | **1.29.0**, MIT, `numThreads = 1`, `crossOriginIsolated === false` (SPIKE 1's vendored copy, reused) |
| openWakeWord models | **v0.5.1** release ONNX, Apache-2.0 |
| @picovoice/porcupine-web | **4.0.1** (never successfully initialised — see §3) |
| TTS for fixtures | `tts-chatterbox-23lang` on `https://ai.lab.ingbretsenhome.com/v1/audio/speech`, 24 kHz mono |
| Fixtures | 16 kHz mono 16-bit, built from **312** TTS renderings |

Raw data: `out/kws-report.json`, `out/false-accepts.json`, `out/asset-sizes.json`.

### How the measurements are taken, and why

Two runners, deliberately:

- **Offline** (`runOffline`) feeds a 16 kHz fixture straight into the engine in
  80 ms chunks with **no audio graph in the loop**. Nothing resamples, so a
  keyword's end time is exact to the sample and detection latency is reported
  in **audio time** — "how much audio past the end of the word did the model
  need" — which is reproducible and needs no wall-clock alignment. It also runs
  ~7× realtime, which is the only reason 24 minutes of negative audio is
  affordable.
- **Live** (`runLive`) drives `getUserMedia` → SPIKE 1's `capture-worklet.js` →
  the engine at realtime against Chrome's fake capture device. That is the only
  way to get a wall-clock callback latency and a realistic CPU figure.

Both are in the report; where they disagree (CPU, §4.5) the disagreement is
itself the finding.

### The fixtures, and one trap in building them

**Chatterbox hallucinates after short prompts.** A render of `"Alexa."` came
back **4.00 s** long: 0.03–0.52 s of the actual word, then 2.79–3.63 s and
3.94–3.95 s of unrelated speech-like audio. The pattern held for every keyword
slug — the phrase is always the first voiced burst, everything past the first
≥150 ms silence is junk. Left in, that junk moves the keyword's end time (the
zero point for every latency number) **and** injects unlabelled speech into a
detection fixture.

`make_kws_fixtures.py` therefore keeps only the first voiced burst. The result
is internally consistent in a way the raw renders were not:

| phrase | syllables | mean | min–max |
|---|---|---|---|
| `alexa` | 3 (1 word) | 566 ms | 530–620 |
| `orca stop` | 3 | 695 ms | 550–840 |
| `orca send` | 3 (2 words) | 756 ms | 620–910 |
| `hey jarvis` | 3 (2 words) | 786 ms | 630–1090 |
| `hey mycroft` | 3 (2 words) | 788 ms | 710–890 |
| `orca pause` | 3 | 834 ms | 710–950 |
| `orca cancel` | 4 | 838 ms | 700–990 |

Durations track syllable count and word count with tight spread, and the
16/16 `hey_jarvis` detection rate on these trimmed clips is the independent
functional check — truncating the phrase would have collapsed it.

Negative audio is **fresh** pink noise, not a tiled loop: a tiled loop makes a
single false accept reappear once per tile and inflates the rate.

---

## 3 · Picovoice Porcupine — blocked, and the block is the finding

### 3.1 It will not run without an AccessKey. Measured.

The brief asked whether built-in keywords ('computer', 'jarvis', …) work
keyless in some demos. **They do not.** Three probes, all in
`out/kws-report.json` under `runs.porcupine_probe`:

| probe | result |
|---|---|
| `accessKey: ''` | `PorcupineInvalidArgumentError: Invalid AccessKey` — client-side base64 round-trip check in `isAccessKeyValid` |
| valid-base64 bogus key + **built-in** keyword | `Keyword file (.ppn) file belongs to a different version of the library. File is '3.0.0' while library is '4.0.0'.` |
| valid-base64 bogus key + `computer_wasm.ppn` from the repo at master | `Failed to parse AccessKey 'bm90LWEt…'` — the wasm's own validation, reached and failed |

The third probe is the decisive one: with a keyword file the library accepts,
initialisation gets all the way into the wasm and dies on the AccessKey. There
is no keyless path, built-in keyword or not.

**Bug worth knowing separately:** the `.ppn` files bundled inside
`@picovoice/porcupine-web@4.0.1` report version **3.0.0** and are rejected by
its own 4.0.0 library, so `BuiltInKeyword` as documented is broken in 4.0.1
**even with a valid key**; you must supply a `.ppn` fetched from the porcupine
repo. That will cost whoever tries this next a debugging cycle.

### 3.2 Licensing, which settles it before the technical question

| | |
|---|---|
| npm package licence | Apache-2.0 (`@picovoice/porcupine-web`) — but that covers the **SDK source only** |
| model files (`.pv`, `.ppn`) | Picovoice-proprietary, redistributed from their repo, not open-source |
| AccessKey | **required**, per-account, cannot be reset, "keep it secret" — yet the Web SDK takes it **in the browser**, so it ships to every client |
| free tier | Picovoice FAQ, verbatim: *"Picovoice is a B2B company focused on on-device AI tools for enterprises. At this time, there are **no dedicated free or paid plans for personal or non-commercial use**."* |
| Free Trial | one-time, non-renewing, **for enterprise developers**, "no credit card required"; Terms §6: Picovoice "reserves the right to approve, deny, modify, or revoke Free Trial access at any time without notice" |
| metering | Porcupine is billed by **monthly active users** — "typically a unique device, app, or **browser instance** that initializes the engine within a 30-day period" |
| offline | permitted; Terms §5 says usage data is buffered on-device and "pushed to a Picovoice server" when next connected. The 4.0.1 web bundle contains exactly one URL, `rest.picovoice.ai`, used only by the training call — so the **runtime** is offline in practice |
| custom keywords | either the Console GUI, or `Porcupine.trainWakeWordFromPhrase(accessKey, writePath, language, phrase)` → one `POST https://rest.picovoice.ai/<lang>/api/ppn` returning a `.ppn`. **Turnaround is one HTTP request, seconds** — no offline build, no waiting. Probed unauthenticated: `403 {"message": "A valid access key is required."}`; with a bogus key: `404 … does not exist` |

The AccessKey does **not** have to ship to the browser for *training* — that
call can be proxied server-side and the resulting `.ppn` vendored. It **does**
have to ship for *runtime*, because `Porcupine.create()` takes it client-side.

For a personal homelab project that is the end of the conversation: there is no
plan to buy, and the free path is an enterprise evaluation that expires.

### 3.3 What is still measurable without a key

Bundle sizes (§6), the API shape, and Picovoice's own published claim —
"97 %+ accuracy (detection rate) with less than 1 false alarm in 10 hours in
the presence of background speech and ambient noise". That claim is *better*
than what openWakeWord delivered here (§4.3), and nothing in this spike
contradicts it; it simply could not be checked.

**Not measurable without Zach's key, stated plainly:** Porcupine's detection
rate, detection latency, CPU per frame, and false-accept rate — on our
fixtures or any others. Every Porcupine cell in the comparison table below is
empty for that reason, and no number in this document is an estimate of one.

---

## 4 · openWakeWord — measured

No browser port was adopted. npm has several (`openwakeword-web`,
`openwakeword-js`, `openwakeword-wasm-browser`, `wakeword-web`, …), all
unversioned 0.1.x single-author packages; wiring the three ONNX stages to the
onnxruntime-web SPIKE 1 already vendors is ~120 lines (`OwwEngine` in
`kws.js`) and adds no dependency. The pipeline is a faithful port of
`openwakeword/utils.py::AudioFeatures._streaming_features`:

```
per 1280-sample (80 ms) chunk:
  melspectrogram( last 1280 + 480 samples )  -> 8 mel frames, transformed x/10 + 2
  embedding( last 76 mel frames )            -> one 96-d vector
  classifier( last 16 embeddings )           -> one score
```

Two details are load-bearing and easy to get wrong: the melspectrogram model
wants **int16-magnitude floats**, not `[-1, 1]`; and the 480-sample overlap
(`160*3`) plus the `x/10 + 2` transform are both required — drop either and
scores collapse toward zero on real keywords.

Model I/O, probed at runtime: melspec `input → output`, embedding
`input_1 → conv2d_19`, classifier `x.1 → 53` with a `[1, 16, 96]` input.
Load cost: backbone **370 ms**, classifier **58 ms** — arm it at "start voice
mode", not on first speech.

### 4.1 Detection rate — 96/96

16 distinct TTS renderings per keyword, each in two contexts (isolated in
near-silence, and at terminal position after a carrier sentence).

| run | th 0.3 | th 0.5 | th 0.7 | extra fires |
|---|---|---|---|---|
| `hey_jarvis`, isolated | 16/16 | 16/16 | 16/16 | 0 |
| `hey_jarvis`, after a carrier sentence | 16/16 | 16/16 | 16/16 | 0 |
| `alexa`, isolated | 16/16 | 16/16 | 16/16 | 0 |
| `alexa`, after a carrier sentence | 16/16 | 16/16 | 16/16 | 0 |
| `hey_mycroft`, isolated | 16/16 | 16/16 | 16/16 | 0 |
| `hey_mycroft`, after a carrier sentence | 16/16 | 16/16 | 16/16 | 0 |

**100 % at every threshold, zero extra fires.** A preceding sentence changes
nothing, which is the property §5.1 needs ("send the email to Bob" must not
fire, a keyword at terminal position must).

Cross-check, `hey_jarvis` model against our four phrases: **0/16 on each of
`orca send`, `orca cancel`, `orca stop`, `orca pause`** — a pre-trained model
is not going to accidentally serve as our keyword, as expected.

### 4.2 Detection latency

Audio-time, measured from the end of the trimmed keyword clip to the chunk at
which the score crosses threshold (th 0.5):

| run | p50 | p95 |
|---|---|---|
| `hey_jarvis` isolated | −80 ms | +10 ms |
| `hey_jarvis` carrier | −80 ms | +90 ms |
| `alexa` isolated | −80 ms | 0 ms |
| `alexa` carrier | −40 ms | +50 ms |
| `hey_mycroft` isolated | −130 ms | +10 ms |
| `hey_mycroft` carrier | −100 ms | +190 ms |

Negative means it fires *before* the clip's last sample — the final phoneme's
decay and a 60 ms tail pad are still running. **In practice the spotter fires
within one 80 ms chunk of the word ending**, worst case +190 ms.

Live path, wall clock: frame posted from the worklet → detection callback,
p50 **11.7 ms**, p95 **58.6 ms**. Over 34 s the 11 detections tracked the
fixture's 12.53 s loop with all residuals inside ±140 ms, 0 missed, 0 extra
(`runs.live_oww`). End to end, **keyword end → callback lands under ~200 ms**,
against §5.2's ~100 ms target — close, and dominated by the 80 ms chunk grid
rather than by inference.

### 4.3 False accepts

Negative audio only; any detection is a false accept.

| fixture | duration | `hey_jarvis` | `alexa` |
|---|---|---|---|
| pink noise −50 dBFS | 5 min | 0 | 0 |
| pink noise −40 dBFS | 5 min | 0 | 0 |
| pink noise −26 dBFS | 5 min | 0 | 0 |
| **noise total** | **15 min** | **0 → 0.00/h** | **0 → 0.00/h** |
| continuous speech, no keyword (148 utterances, 28 of them adversarial) | 9.18 min | 1 → **6.5/h** | 3 → **19.6/h** |

Score ceiling on noise never exceeded **0.016** (`hey_jarvis`) / **0.0003**
(`alexa`) — nowhere near a 0.3 threshold. Noise is a non-issue.

Speech is not, but the raw rate overstates it badly. The corpus is
**deliberately adversarial**: 28 of its 148 utterances are near-misses written
to attack these specific keywords. `label_false_accepts.py` names every hit,
and **all of them are near-misses**:

- `hey_jarvis` — *"Hey, Jarvis Cocker was the singer in Pulp."* (0.919). That is
  a near-homophone of the keyword; arguably a correct fire.
- `alexa` — *"A Lexus is not really my kind of car."* (0.997),
  *"The lexer produces a token stream for the parser."* (0.924),
  *"Orchestration of the containers is handled by Flux."* (0.509).
  (A fourth, *"Electra was a Greek tragedy by Sophocles."*, fired in an earlier
  build with a different shuffle — so treat `alexa` as 3–4 per 9.2 min.)

**Zero false accepts on the 120 ordinary sentences** (7.0 min of speech,
7.6 min of stream). The honest reading: openWakeWord is robust to noise and to ordinary conversation,
and vulnerable to deliberate phonetic neighbours — so the phrase choice, not
the threshold, is the lever. `alexa` is the worst of the three (one word, three
syllables, many English neighbours); `hey jarvis` is much better; a two-word
phrase like `orca send` with a rare first word is better still.

Raising the threshold barely helps (`alexa` 3 → 2 going 0.5 → 0.7) while
costing detections under background speech (§4.4) — which is the usual shape
for this kind of model, and the reason §5.1's *terminal-position* heuristic
is worth more than any threshold tuning.

### 4.4 The §5.2 case: the keyword spoken WHILE the assistant is talking

Keyword mixed over continuous TTS speech, standing in for our own playback
leaking into the mic. SNR is keyword relative to background.

| SNR | `hey_jarvis` th 0.3 / 0.5 | `alexa` th 0.3 / 0.5 |
|---|---|---|
| +10 dB | **16/16 / 16/16** | 15/16 / 14/16 |
| 0 dB | 10/16 / **7/16** | 5/16 / 4/16 |
| −6 dB | 3/16 / **2/16** | 3/16 / 3/16 |

**This is the most important result in the spike.** The spotter is excellent
when the mic hears you clearly over the playback and falls apart when it does
not. So §5.2's viability is set by **how much of our own TTS the browser's AEC
removes** — the one question SPIKE 1 explicitly could not answer with a fake
capture device, and which needs Zach at a real microphone with real speakers.

Read against SPIKE 1's human-in-the-loop procedure: its "AEC suppression > ~15 dB
→ full duplex is plausible" threshold is roughly where this table stays at
16/16, and its "< ~6 dB → half-duplex is the permanent answer" is roughly
where it falls to 7/16. The two spikes agree on where the cliff is.

### 4.5 CPU — and why the three numbers disagree

Per 80 ms chunk, `hey_jarvis`, single-threaded wasm (`numThreads = 1`), no
cross-origin isolation, no WebGPU:

| regime | melspec p50 | embedding p50 | classifier p50 | **total p50** | p95 | duty cycle |
|---|---|---|---|---|---|---|
| offline, chunks back to back | 0.9 ms | 8.6 ms | 0.3 ms | **9.9 ms** | 11.8 ms | 12 % |
| offline, **paced to realtime**, no audio graph | 3.6 ms | 22.5 ms | 0.4 ms | **26.1 ms** | 38.5 ms | 33 % |
| **live**, worklet + getUserMedia | 1.2 ms | 9.9 ms | 0.4 ms | **11.6 ms** | 39.3 ms | 25 % (mean 20.1 ms) |

The paced control exists precisely to separate two explanations, and it
settles them: **most of the slowdown is the duty-cycle regime, not the audio
graph.** Working for ~10 ms then idling for ~70 ms leaves the core in a low
power state and pays wake-up cost on every frame; the back-to-back figure is
the best case and is not what a deployed spotter will see.

The live figure is also **noisy across runs**: two identical runs gave
per-frame p50 **34.9 ms** and **11.6 ms**, mean 29.3 ms and 20.1 ms — i.e.
duty cycles of **37 %** and **25 %**. This host is shared with other agent
sessions, so treat that as a **25–37 % of one core** range with 14–44 %
instantaneous spread, not a point estimate, and re-measure on the target
machine before budgeting.

For scale, SPIKE 1's Silero VAD costs 3.3–3.5 ms per 32 ms frame ≈ **11 %**
duty in the same live regime. **Running the spotter always-on roughly triples
the browser-side CPU of voice mode** (VAD ~11 % → VAD + spotter ~36–48 %). Mitigations, in order of preference:

1. **Gate the spotter on the VAD** — only run it while the VAD says speech is
   present, plus a ~1 s tail. In ordinary use that is a large multiple cheaper
   and costs nothing in latency, because the VAD leads the spotter.
2. Run it in a Worker: does not reduce CPU, but removes it from the UI thread.
3. ort wasm threads (needs COOP/COEP — SPIKE 1 argued against that, for good
   reasons) or a WebGPU EP. Unmeasured here.

### 4.6 A second keyword is nearly free

Three classifiers over the one shared backbone vs one:

| | melspec | embedding | classifier | total p50 |
|---|---|---|---|---|
| 1 classifier (back-to-back) | 0.9 ms | 8.6 ms | **0.3 ms** | 9.9 ms |
| 3 classifiers (back-to-back) | 0.9 ms | 8.5 ms | **0.6 ms** | 10.1 ms |
| 1 classifier (paced) | 3.6 ms | 22.5 ms | **0.4 ms** | 26.1 ms |
| 3 classifiers (paced) | 3.5 ms | 23.0 ms | **1.1 ms** | 27.2 ms |

Detection stayed 16/16 with three heads running. **The expensive half is
shared**, so `send` / `cancel` / `stop` / `pause` as four separate keywords
costs about **+1 ms per frame** over one — not 4×. That is a real point in
openWakeWord's favour for this design, and it holds for Porcupine too (one
engine, N `.ppn`s).

---

## 5 · Training `orca send` — openWakeWord

Nothing was trained in this spike. The path, from upstream's own docs:

- **Data is 100 % synthetic.** Every shipped openWakeWord model was trained on
  TTS output; no recordings of a human saying the phrase are needed.
- Upstream's generator is `piper-sample-generator`. GB10's Chatterbox could
  substitute, but with a caveat this spike measured the hard way: **Chatterbox
  hallucinates trailing audio after short prompts** (§"fixtures" above), so a
  first-voiced-burst filter like `make_kws_fixtures.py::first_utterance` would
  be mandatory in the generation pipeline, plus a duration sanity check.
  At the ~1.5–3 s per render measured here, ~1000 positives is ~30–50 min of
  wall clock serial, less with concurrency.
- Upstream's automated notebook's demo config: `n_samples: 1000`,
  `n_samples_val: 1000`, `steps: 10000`, ~**10 minutes on a free Colab T4**.
  Upstream recommends "a minimum of several thousand" positives for real use,
  and performance "increases smoothly with dataset size".
- Negatives are the expensive part: the shipped models used **~30,000 hours**
  of negative audio. The notebook route uses pre-computed feature files
  (`openwakeword_features_ACAV100M_2000_hrs_16bit.npy`) plus AudioSet/FMA
  backgrounds and MIT room impulse responses for augmentation — downloads, not
  compute.
- Only the classifier head is trained; melspectrogram + embedding stay frozen,
  which is why a new keyword is a small model and a short run.

**Effort estimate: half a day for a first model** (generate ~1000–5000
Chatterbox renderings with the burst filter, pull the negative feature sets,
run the notebook on GB10 or Colab), then an evaluation pass against a corpus
like this spike's `neg_speech` to pick a threshold. That is a real task, not a
config change — which is the main reason not to put SEND on the spotter in
phase 1.

One free upside: `orca send` is a *good* wake word by Picovoice's own
published guidance and by §4.3's evidence — two words, four+ phonemes, a rare
first word with few English neighbours. The failures we measured were all on
one-word keywords with common neighbours.

---

## 6 · Wire size

Raw / gzip bytes, measured (`out/asset-sizes.json`):

| group | raw | gzip |
|---|---|---|
| **already shipped by SPIKE 1's VAD** (ort runtime + silero) | 16,363,783 | 5,538,705 |
| **openWakeWord marginal** — melspec 1,087,958 + embedding 1,326,578 + `hey_jarvis` 1,271,370 | **3,685,906** | **3,000,976** |
| each additional keyword classifier | 854,246–857,691 | 789,023–791,067 |
| **Porcupine marginal** — SDK+wasm 3,360,435 + `porcupine_params.pv` 984,948 + one `.ppn` 4,264 | **4,349,647** | **1,827,197** |
| this spike's engine code (`kws.js`, whole file) | 22,938 | 7,584 |

Two things cut against the obvious expectation and should be said plainly:

- **Porcupine is smaller on the wire than openWakeWord**, 1.83 MB gzip vs
  3.00 MB, despite bringing an entire second wasm runtime (inlined as base64
  inside `porcupine-web.iife.min.js`, so it shares nothing with ort). The ONNX
  files barely compress — `embedding_model.onnx` goes 1.33 MB → 1.22 MB — while
  Porcupine's JS bundle goes 3.36 MB → 0.88 MB.
- Neither is the dominant term. `ort-wasm-simd-threaded.wasm` alone is
  3.57 MB gzip and is already required by the VAD, so voice mode goes from
  **5.54 MB gzip to 8.54 MB** with openWakeWord. Serve compressed and cache
  hard, as SPIKE 1 already recommends.

---

## 7 · Comparison and recommendation

| | Picovoice Porcupine 4.0.1 | openWakeWord v0.5.1 |
|---|---|---|
| licence | SDK Apache-2.0; **models proprietary** | **Apache-2.0 throughout** (incl. Google `speech_embedding` backbone) |
| key / account | **AccessKey required at runtime, in the browser**; measured, no keyless path | **none** |
| free tier | **none for personal/non-commercial**; one-time enterprise Free Trial; billed by monthly active browser instances | n/a |
| custom keyword path | Console GUI, or one `POST rest.picovoice.ai/<lang>/api/ppn` | train a classifier head on synthetic TTS data |
| custom keyword turnaround | **seconds** (one HTTP request) | **~half a day** for a first model (§5) |
| bundle, marginal over the VAD stack | 4,349,647 raw / **1,827,197 gzip** | 3,685,906 raw / 3,000,976 gzip |
| CPU per frame p50/p95 | **not measurable** | 9.9 / 11.8 ms back-to-back · 26.1 / 38.5 ms paced · 11.6 / 39.3 ms live (80 ms frames) |
| duty cycle | **not measurable** | **25–37 % of one core** live, across two identical runs |
| extra keyword cost | (shared engine) | **+0.3 ms per frame** |
| detection latency | **not measurable** | within one 80 ms chunk of word end; p95 ≤ +190 ms audio-time; < ~200 ms end to end |
| detection rate | **not measurable** (vendor claims 97 %+) | **96/96** on synthesized keywords, isolated and after speech |
| false accepts / hour, noise | **not measurable** (vendor claims < 0.1/h) | **0.00** over 15 min at 3 levels |
| false accepts / hour, speech | **not measurable** | **6.5** (`hey jarvis`) / **19.6** (`alexa`) on an adversarial corpus; **0** on 7.6 min of ordinary speech |
| under background speech | **not measurable** | 16/16 @ +10 dB, 7/16 @ 0 dB, 2/16 @ −6 dB |
| offline capable | yes at runtime (usage buffered + reported per Terms §5); training needs the network | **yes, fully** — no network at runtime or training |

### 7.1 §5.2 — STOP / PAUSE during playback

**Use openWakeWord.** Porcupine is not available to this project on any terms
it would accept, and openWakeWord is good enough: it fires within one 80 ms
chunk, never on noise, and never on ordinary conversation.

But ship it with the §4.4 result understood: **the spotter is not the risk,
the acoustic path is.** Before building this, run SPIKE 1's human AEC
procedure. If AEC suppression comes back above ~15 dB, §5.2 works as specced.
If it comes back near 6 dB, the spotter will miss most of the time during
playback and §5.2 needs a different answer (duck the playback volume on any
VAD speech-start, then spot; or keep a physical/keyboard stop).

Two settings to start from, both measured: **threshold 0.5** (0.3 buys ~3
extra detections in 16 under 0 dB background but roughly doubles the
adversarial false-accept exposure), and **gate the spotter on the VAD** to
claw back most of §4.5's CPU.

### 7.2 §5.1 — should SEND ride the spotter?

**No, not in phase 1. Separate view from the above, and it is a different
answer.**

For it: SPIKE 2 showed the transcript route genuinely broken for this phrase
("or Cassand."), and §4.1 showed a spotter is completely unbothered by what
precedes the keyword.

Against it, on the numbers here:

1. **It does not exist yet.** There is no `orca send` model; §5 is a half-day
   training task plus an evaluation pass, and it must be repeated for
   `cancel` / `stop` / `pause`. That is the whole of phase 1's budget spent on
   the cheapest-to-fix half of the problem.
2. **The failure mode is wrong for SEND.** A spotter fires on phonetics with no
   notion of position in a sentence. §5.1's single strongest heuristic —
   *match only at terminal position of a completed VAD segment* — is exactly
   what a spotter throws away. §4.3 shows what that costs: fires on "A Lexus",
   "the lexer", "Orchestration". For STOP that is a recoverable annoyance; for
   SEND it means a half-formed draft goes to the model mid-sentence.
3. **The cheaper fix is upstream.** The real defect SPIKE 2 found is that ASR
   has no idea `orca` is a word. Whisper takes an `initial_prompt` / biasing
   hint; a fixed prompt listing the four commands is a one-line change on the
   ASR call, costs nothing, and fixes "or Cassand." directly. That should be
   tried before a training pipeline is built. (Not tested here — SPIKE 1
   finding F3 says GB10 exposes no ASR endpoint yet at all.)
4. **Spotter and transcript disagree about time.** A spotter fires ~600 ms
   before the ASR for the same utterance returns, so SEND still has to wait for
   the transcript anyway in order to strip the command tokens from the draft
   (§8). The latency win is a UI-feedback win, not an actual send-sooner win.

**Recommended shape:** keep SEND on the transcript path with §5.1's
terminal-position rule plus an ASR biasing prompt. If real use shows that is
still unreliable, train `orca send` *then* — and when you do, use it as a
**confirmation signal that runs alongside** the transcript matcher (fire on
either, or on both within a window), not as a replacement for it. The
infrastructure built for §5.2 makes that a small addition.

---

## 8 · Sequencing, if SEND ever does ride the spotter

The spotter fires before the final VAD segment's transcript returns, so the
command is known before the words are:

```
T   spotter crosses threshold, ~0-80 ms after "orca send" ends.
    The VAD segment containing T has NOT closed (redemptionMs = 600 ms of
    trailing silence still to run) and its ASR has not been dispatched.
1.  Latch pending_send = T. Do NOT submit. Render the arming chip NOW --
    the whole value of the spotter is that the UI reacts in ~100 ms.
2.  Wait for that segment to close and its ASR to return (600 ms + 100-300 ms).
    Bound it: if nothing lands within ~2.5 s, submit the draft as it stands.
3.  Strip the command by TIME, not by text: drop trailing words whose start
    is >= T - 700 ms (the measured length of "orca send" is 620-910 ms).
    Text matching is the FALLBACK, because SPIKE 2 showed the transcript may
    contain no matchable token at all ("or Cassand.").
4.  If the stripped segment is empty, drop it from the draft entirely.
5.  Arming window: 1.5 s countdown started at step 3, cancelled by any new
    VAD speech-start. Then submit.
Cancel path: "orca cancel" latches the same way and clears the draft, so a
mis-fire at step 1 is recoverable by voice without waiting for step 5.
```

**Where the spotter sits relative to the AudioWorklet.** It consumes the *same*
16 kHz int16 stream as the VAD — one `getUserMedia`, one worklet, no second
capture path. Frame sizes differ (Silero 512 = 32 ms; openWakeWord 1280 =
80 ms; Porcupine 512 = 32 ms) and 1280 is not a multiple of 512, so **emit
256-sample frames from the worklet** and let each consumer accumulate (VAD 2,
openWakeWord 5). SPIKE 1's worklet already tags every frame with an absolute
16 kHz sample index, so `T` is exact and step 3's time-based strip is exact
with it. Convert to int16 once, on the main thread, not per consumer.

Per §4.5, run the spotter **gated by the VAD** rather than free-running: the
VAD leads it, costs a third as much, and never has to be gated itself.

---

## 9 · What this does NOT prove

- **Nothing about Porcupine's runtime behaviour.** No key, no numbers. Every
  Porcupine performance cell above is blank on purpose.
- **Nothing about real microphones, rooms, or AEC.** Same limitation as
  SPIKE 1: the fake capture device injects a WAV with no acoustic path. §4.4's
  SNR sweep brackets the AEC question, it does not answer it.
- **Nothing about real human speakers.** Every keyword instance is Chatterbox
  TTS. Synthetic speech is systematically easier than real speech with accents,
  distance, and vocal effort, so §4.1's 96/96 is an upper bound and §4.3's
  false-accept rates are a lower bound for the true-positive side.
- **Nothing about `orca send` as a keyword.** No model exists; the four
  `det_orca_*` fixtures are built and committed so the moment one is trained
  the same matrix runs against it unchanged.
- **Nothing about mobile, Safari, Firefox, or battery.** CPU was measured on
  one x86 Linux host under Chromium, and varied 3× between identical runs.
