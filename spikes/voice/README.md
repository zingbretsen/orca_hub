# SPIKE 1 — browser voice-capture path

De-risks the capture half of `voice_mode_spec.md`:

    mic -> getUserMedia({echoCancellation,noiseSuppression,autoGainControl})
        -> AudioWorklet (Nk -> 16k mono resample + ring buffer w/ ~500ms PRE-ROLL)
        -> Silero VAD (onnxruntime-web) -> speech segments only

Self-contained. **Not wired into the app**: nothing here is imported by
`assets/js/app.js`, nothing lives under `priv/static`, and `package.json` /
`mix.exs` are untouched. Serve it yourself with `./serve.sh`.

---

## TL;DR — what the spike proved

| # | Question | Answer |
|---|---|---|
| 1 | Is `echoCancellation` actually applied, or silently dropped? | **Applied.** `track.getSettings().echoCancellation === true`, and it correctly reports `false` when requested `false`. |
| 2 | Can an AudioWorklet do 48k→16k + pre-roll cheaply? | **Yes — ~15–17 µs per 128-frame block, ≈0.6 % duty cycle.** Never a bottleneck. |
| 3 | Is Silero-in-the-browser fast enough? | **Yes — 3.3–3.5 ms p50 per 32 ms frame (realtime factor 0.11).** ~9× headroom. |
| 4 | Does the pre-roll actually prevent first-phoneme clipping? | **Yes — measured speech onset sits at 420–510 ms into a 500 ms-pre-roll segment, not at ~0.** Verified offline on 52 dumped WAVs. |
| 5 | Does Silero false-trigger on noise? | **0 completed segments in 5 × 60 s of pink noise** at −50/−40/−26 dBFS. |
| 6 | Can we hit the spec's 500–700 ms end-of-speech budget? | **Yes, but NOT with `@ricky0123/vad-web`'s defaults**, which give **1376 ms**. Tuned: **608 ms**. |
| 7 | vad-web vs direct Silero? | **Either. Use `vad-web` with explicit settings** — the size difference is ~17 KB gzip out of 5.5 MB. |
| 8 | Does browser AEC suppress our TTS on real hardware? | **UNKNOWN — this spike cannot answer it.** See "What this does NOT prove". |

Three things that will bite production code, found the hard way — see
**Findings against the spec** below:
`performance` does not exist inside an AudioWorklet; `AudioContext.sampleRate`
is not the mic's sample rate; and GB10 currently exposes **no ASR endpoint at all**.

---

## Layout

```
spikes/voice/
  index.html            harness UI
  harness.js            getUserMedia, metrics, WAV dump, AEC panel, window.__spike API
  capture-worklet.js    AudioWorkletProcessor: FIR + decimate to 16k, pre-roll ring
  silero-direct.js      engine B: Silero ONNX driven directly on onnxruntime-web
  serve.sh              static server (see "Running it")
  vendor/               onnxruntime-web 1.29.0 (MIT) + @ricky0123/vad-web 0.0.31 (ISC)
  assets/               TTS speech clips + generated test fixtures + fixtures.json
  tools/
    server.py           static server + /upload (WAV) + /results (JSON) receiver
    make_fixtures.py    builds fixtures with EXACTLY KNOWN speech-onset timestamps
    headless.mjs        playwright driver, fake audio capture device
    headless.sh         wrapper that locates playwright
    verify_wavs.py      independent offline re-measurement of the dumped WAVs
    asset_sizes.py      raw/gzip wire-size accounting
  out/                  results + dumped segment WAVs (gitignored)
```

**Vendored, not CDN.** Deliberate: headless runs stay deterministic and offline,
and it lets the wire-size table below be measured rather than guessed. The
upstream CDN equivalents are in `vendor/vad/README.upstream.md`.

---

## Running it

```bash
cd spikes/voice
./serve.sh                 # http://localhost:8777/
./serve.sh 9001            # another port
./serve.sh 8777 --coi      # + COOP/COEP (see note below)
```

Headless (needs the server already running):

```bash
./tools/headless.sh                          # full matrix -> out/headless-report.json
./tools/headless.sh --only=direct_clean_red600
python3 tools/verify_wavs.py                 # independent check of out/*.wav
python3 tools/asset_sizes.py                 # wire sizes
```

`tools/headless.sh` finds playwright in the npx cache (`PLAYWRIGHT_DIR` overrides).
**No dependency was added to this repo.**

### COOP/COEP

Not needed and **not** used by default. `onnxruntime-web` only uses
`SharedArrayBuffer` for multi-threaded wasm; every number here was taken with
`ort.env.wasm.numThreads = 1` and `crossOriginIsolated === false`, and inference
is already 9× faster than realtime, so threads buy nothing. `--coi` exists only
if you want to A/B it. Turning it on in the real app would mean every
cross-origin asset needs CORP/CORS headers — a real cost for no measured gain.

---

## Environment these numbers came from

| | |
|---|---|
| Headless browser | **Chromium 153.0.8010.12** (playwright 1.63.0 bundle) |
| Cross-checked on | **Google Chrome 149.0.7827.114** (system, `channel: 'chrome'`) |
| Host | debian, x86_64, Linux 6.12.90 |
| onnxruntime-web | **1.29.0**, MIT, `ort.wasm.min.js` + `ort-wasm-simd-threaded.wasm`, `numThreads=1` |
| @ricky0123/vad-web | **0.0.31**, ISC |
| Silero model | `silero_vad_v5.onnx`, 2,327,524 B, 512-sample frames = **32 ms/frame** |
| Mic track | fake device, 48 000 Hz mono |
| AudioContext | **44 100 Hz** (negotiated, see finding F2) → resample ratio 2.75625 |

Raw data: `out/headless-report.json`, `out/wav-verification.json`,
`out/asset-sizes.json`.

---

## 1 · getUserMedia + constraints

Requested `{echoCancellation:true, noiseSuppression:true, autoGainControl:true, channelCount:1}`.

| setting | value |
|---|---|
| `echoCancellation` | **true (applied, not dropped)** |
| `noiseSuppression` | true |
| `autoGainControl` | true |
| `voiceIsolation` | false |
| `channelCount` | 1 |
| `sampleRate` | 48000 |
| `sampleSize` | 16 |
| `latency` | 0.01 |

Requesting `false` correctly yields `echoCancellation: false`, so the flag is
genuinely honoured in both directions rather than being a constant.
`navigator.mediaDevices.getSupportedConstraints()` and the full
`getCapabilities()` dump are in `out/headless-report.json` under
`runs.*.results.gum`.

Secondary but real: with NS **on** the pink-noise floor measured **−56.8 dBFS**,
with NS **off** **−50.5 dBFS** — i.e. browser noise suppression is doing ~6.3 dB
of real work on the capture path.

---

## 2 · AudioWorklet resampler + pre-roll ring

Design notes are in `capture-worklet.js`: a 63-tap Blackman-windowed sinc
low-pass at 7.6 kHz, then fractional decimation via a phase accumulator (the
ratio is **not** an integer — see finding F2), a ring buffer holding
pre-roll + 1500 ms of slack, and 512-sample frames posted to the main thread
tagged with an **absolute** 16 kHz sample index so a late pre-roll request still
returns exactly the right audio.

| metric | value |
|---|---|
| AudioContext sample rate (negotiated) | **44 100 Hz** |
| Mic track sample rate | 48 000 Hz |
| Resample ratio | 2.75625 (non-integer) |
| Render quantum | 128 frames = 2.9025 ms |
| **Per-block cost (precise, main-thread kernel bench)** | **p50 0.0153 ms @48k / 0.0172 ms @44.1k** |
| **Duty cycle (precise)** | **0.581 % @48k, 0.586 % @44.1k** |
| Duty cycle (in-worklet estimator, 13 runs) | 0.58 % – 4.10 % |
| Blocks processed | 10 336–10 340 per 30 s (expected 10 337) |
| Empty-input blocks | 0 |
| 16 kHz samples produced | 489 476 per 30 s (= 16 316 /s) |
| Main-thread timer lateness | p50 0.0 ms, p95 0.2 ms, p99 1.3 ms |
| VAD queue backlog | p50 0, p95 0, **max 0** |

**On the two CPU numbers.** `performance` does not exist in
`AudioWorkletGlobalScope` (finding F1), so the worklet can only time itself with
`Date.now()` at 1 ms resolution — far coarser than the ~15 µs it actually costs.
The in-worklet figure is therefore a *ms-boundary-crossing* estimator: sound in
expectation, noisy per run, and it also absorbs `postMessage` and GC. The precise
number comes from `benchResampler()`, which runs the **identical** FIR +
decimation kernel on the main thread — where `performance.now()` exists — in
200-block batches. Take **~0.6 % duty cycle** as the headline; the worklet is
nowhere near a bottleneck at any plausible tap count.

---

## 3 · Silero VAD

### Inference cost (direct engine, measured per frame)

| | p50 | p95 | p99 | max | mean |
|---|---|---|---|---|---|
| `session.run()` ms | **3.3 – 3.5** | 3.9 – 4.2 | 4.1 – 5.6 | 79–93 (first call) | ~3.0 |

One frame is 32 ms of audio, so the **realtime factor is 0.11** — about 9× headroom
on one wasm thread, no SIMD threads, no WebGPU. The `max` outlier is the first
inference after session creation (warm-up); it never recurs.

Load cost: model fetch 25 ms, `InferenceSession.create` **499 ms**, total 519 ms
(direct). `MicVAD.new()` 533–809 ms. Either way, **arm the VAD at "start voice
mode", not on first speech** — a ~0.5 s cold start would otherwise eat the first
utterance.

### End-of-speech latency vs `redemptionMs`

EOS is measured in **audio time**: from the end of the last frame scoring
≥ `positiveSpeechThreshold` to the frame where the segment closes. That is exact
and needs no wall-clock alignment.

| configured `redemptionMs` | EOS p50 | EOS p95 | over budget? |
|---|---|---|---|
| 400 | **416 ms** | 416 ms | no |
| **600** | **608 ms** | 640 ms | **no — fits 500–700 ms** |
| 1400 (vad-web default) | **1408 ms** | 1408 ms | **yes, 2× over** |

EOS ≈ `redemptionMs` rounded up to the 32 ms frame grid, with essentially no
other overhead. **`redemptionMs` *is* the end-of-speech latency knob**, exactly as
the spec predicted — and it is the only term that matters: everything else in the
browser half costs single-digit milliseconds.

### False triggers on noise

Pink noise, **no speech anywhere in the fixture**, so any activation is false.

| fixture | level | thresholds | duration | starts | completed segments | false triggers/min |
|---|---|---|---|---|---|---|
| `fix_noise_pink_quiet` | −50 dBFS | 0.50/0.35 | 60 s | 0 | 0 | **0.00** |
| `fix_noise_pink_room` | −40 dBFS | 0.50/0.35 | 60 s | 0 | 0 | **0.00** |
| `fix_noise_pink_loud` | −26 dBFS | 0.50/0.35 | 60 s | 0 | 0 | **0.00** |
| `fix_noise_pink_room` | −40 dBFS | 0.30/0.25 | 60 s | 0 | 0 | **0.00** |
| `fix_noise_pink_loud` | −26 dBFS | 0.30/0.25 | 60 s | 0–1 * | 0 | **0.00** |

\* one run of the loud/0.30 case produced a single activation that `minSpeechMs`
rejected as a misfire; a repeat produced none. Either way **zero** segments ever
reached the ASR stage.

Speech-probability ceiling on noise: p95 **0.0033–0.0096**, max **0.037** (quiet/room)
and **0.243** (loud). Even the worst case sits well under a 0.5 threshold, and
under 0.3. Silero is comfortably separating pink noise from speech — this is not
a marginal call.

### Robustness with speech in noise

| fixture | SNR | starts/ends | EOS p50 | onsets (ms, pre-roll = 500) |
|---|---|---|---|---|
| `fix_speech_snr10` | 10 dB | 7 / 7 | 608 | 480, 500, 490, 480, 500, 490, 480 |
| `fix_speech_snr05` | 5 dB | 7 / 7 | 640 | 510, **40**, 480, 500, 490, 490, 480 |

At 5 dB SNR one of seven segments opened early on noise (onset 40 ms) —
the segment is still usable, it just carries extra leading noise.

---

## 4 · Segment cleanliness / pre-roll

Every detected utterance is written as a **16 kHz mono 16-bit WAV** to
`spikes/voice/out/` (52 files in the committed run). `tools/verify_wavs.py`
re-measures them **offline with an independent implementation**, so a bug in the
page's own measurement cannot make the pre-roll look present when it isn't.

| | value |
|---|---|
| Files checked | 52 |
| All 16 kHz mono | **true** |
| Speech onset, median | **480 ms** |
| Speech onset, range | 0 – 800 ms |
| Trailing silence, median | 673 ms (≈ the redemption window) |

Per-segment onsets for the 500 ms pre-roll, clean speech:
**510, 500, 420, 500, 490, 480, 500 ms**.

**The pre-roll is real and correctly sized.** Without it these would all read ~0
and the leading phoneme would be gone — "orca send" becoming "orca end", exactly
the failure the spec warns about. The 0 ms outlier is the 5 dB-SNR early trigger
above; the 800 ms values are vad-web at its 800 ms default pad.

The worklet's pre-roll request never returned `truncated: true`, i.e. the ring
was always deep enough to satisfy a late request.

---

## 5 · Echo / AEC panel

The panel (`btn-aec`) runs a 4-phase A/B: 4 s silence then 8 s of TTS playback,
with `echoCancellation` on, then the same with it off, reporting mic RMS in each
phase and VAD trigger counts.

**Headless result (mechanical only):**

| trial | AEC applied | silence dBFS | playback dBFS | Δ dB | triggers (silence) | triggers (playback) |
|---|---|---|---|---|---|---|
| aec-on | true | −56.81 | −57.16 | −0.35 | 0 | 0 |
| aec-off | false | −50.49 | −50.87 | −0.38 | 0 | 0 |

These numbers confirm **the panel executes end to end** and that the
`echoCancellation` constraint flips as requested. They say **nothing whatsoever**
about AEC efficacy — see below.

---

## What this does NOT prove

**The fake capture device bypasses the acoustic loop entirely.**
`--use-file-for-fake-device-for-media-stream` injects a WAV directly into the
capture pipeline; there is no speaker, no room, no microphone, and therefore no
echo to cancel. The ~0 dB residual above is what "there was never any echo"
looks like, not what "AEC removed the echo" looks like.

**Never read this spike as evidence that browser AEC suppresses our TTS.**
That question is answerable only by a human with real speakers and no headphones
— the procedure below. Until then, spec §4.1's half-duplex rung (v1 mutes the
mic during playback) stands on its own merits and should not be skipped on the
strength of anything measured here.

Also not covered: real microphone hardware, real room acoustics, Bluetooth
latency/drift, multiple simultaneous tabs, mobile Safari, and ASR accuracy
(there is no ASR endpoint to test against — finding F3).

---

## Findings against `voice_mode_spec.md` §3 / §4 / §9

The spec is in good shape. §3.2's insistence on client-side VAD, the pre-roll
warning, §4's "use the browser's AEC, don't hand-roll NLMS", §4.1's phased
barge-in ladder, §9 trap #1 (secure context) and trap #5 (resample in the
worklet) all survived contact with the measurements. Corrections:

**F1 — NEW TRAP, not in §9: `performance` does not exist in
`AudioWorkletGlobalScope`.** Calling `performance.now()` inside `process()`
throws a `ReferenceError`; Chrome fires `onprocessorerror` **once** and then
**silently stops calling `process()` forever**. No console error, no exception
anywhere reachable, the `AudioContext` stays `running` and `currentTime` keeps
advancing — you just get zero audio frames, which looks exactly like a broken
`getUserMedia` or a disconnected graph. Verified on Chromium 153 **and Chrome
149**. This cost the spike a debugging cycle and will cost production one too.
Mitigations, both applied here: always attach `node.onprocessorerror`, and time
the worklet with `Date.now()` or the audio clock only. Worth adding to §9.

**F2 — §9.5 is imprecise: `AudioContext.sampleRate` is NOT the mic's sample
rate.** §9.5 says "mic is 48kHz, ASR wants 16kHz mono — resample in the
AudioWorklet". Correct, but the ratio is **not** 3. Here the track negotiated
48 000 Hz while the `AudioContext` negotiated **44 100 Hz**, giving a resample
ratio of **2.75625**. The worklet sees the *context's* rate (the `sampleRate`
global), and the browser has already resampled the track into it. Any
implementation that hardcodes `/3` or `48000` produces audio ~10 % off-pitch —
and Whisper will happily transcribe pitch-shifted audio into plausible wrong
words rather than failing loudly. Use the `sampleRate` global and a fractional
phase accumulator. (You *can* pass `new AudioContext({sampleRate: 16000})` to
force the issue, but that hands resampling quality to the browser.)

**F3 — §6 / §11 open question answered: GB10 exposes NO ASR endpoint today.**
`https://ai.lab.ingbretsenhome.com/v1/models` lists six models and **not one is
a Whisper/ASR model**: `Qwen3-Next-80B-A3B-Thinking`, `Qwen3.8-27B`,
`gemma-4-26B-A4B`, `qwen2.5-3b-instruct`, `qwen3-coder-next`,
`tts-chatterbox-23lang`. `POST /v1/audio/transcriptions` and
`/v1/audio/translations` both return **404 `{"error":{"message":"not found"}}`**
— a 404, not a 405, so the routes genuinely do not exist. §6 says GB10 "already
serves Whisper transcription and TTS in some form"; the **TTS half is true**
(`POST /v1/audio/speech` with `{model,input,language}` returns 24 kHz mono WAV in
0.6–1.7 s — used to generate this spike's speech fixtures), but **the ASR half
is not deployed**. Standing up an ASR endpoint is therefore a prerequisite
task for phase 1, not a configuration detail, and §6.1's "ASR 100–300 ms" budget
line is currently unvalidated.

**F4 — §3.2's "`@ricky0123/vad-web` packages it" needs a warning label.** True,
but its **defaults are wrong for this product**. v0.0.31 ships
`redemptionMs: 1400`, `preSpeechPadMs: 800`, `positiveSpeechThreshold: 0.3`,
`negativeSpeechThreshold: 0.25`, `minSpeechMs: 400` — measured EOS **1376 ms**,
roughly **2× the §6.1 budget of 500–700 ms**, and §6.1 already identifies VAD
endpointing as the dominant term. Adopting the library without overriding these
would silently miss the spec's own latency target.

**F5 — the API is milliseconds now, not frames.** The spec (and the spike brief)
refer to `redemptionFrames` / `preSpeechPadFrames`. In 0.0.31 those are
`redemptionMs` / `preSpeechPadMs` / `minSpeechMs`; the frame counts are derived
internally (`Math.floor(ms / 32)`). Any implementation guide should use the ms names.

**F6 — §9 trap #2 (autoplay) is real but has a second face.** A user gesture
gates playback as described. Additionally, an `AudioWorkletNode` with **no path
to `ctx.destination`** is never pulled by the render graph and `process()` never
runs — silently, as in F1. The capture node must be connected onward (a
`GainNode(gain: 0)` into the destination is enough) even though it produces no
audio. Worth a line in §9.

**F7 — minor, §4:** `getSettings()` also reports `voiceIsolation` (false here).
On platforms where it exists it is a *third* processing stage alongside
NS and AEC, and it can distort speech. Pin it explicitly rather than inheriting it.

---

## Recommendation

### vad-web vs direct Silero — **use `@ricky0123/vad-web`, with every setting stated explicitly.**

Wire size is **not** a differentiator. Both options ship the same
`onnxruntime-web` wasm and the same 2.3 MB Silero model; that is ~97 % of the
payload either way.

| | raw | gzip |
|---|---|---|
| `@ricky0123/vad-web` 0.0.31 + ort 1.29.0 | 16,435,608 | **5,560,445** |
| direct Silero + ort 1.29.0 (our ~14 KB of state machine) | 16,377,497 | **5,543,660** |
| **difference** | 58,111 | **16,785 (0.3 %)** |

Per-file (raw / gzip): `ort-wasm-simd-threaded.wasm` 13,961,845 / 3,570,014 ·
`silero_vad_v5.onnx` 2,327,524 / 1,943,547 · `vad-bundle.min.js` 69,345 / 20,679 ·
`ort.wasm.min.js` 50,196 / 16,097 · `ort-wasm-simd-threaded.mjs` 24,218 / 9,047 ·
`vad.worklet.bundle.min.js` 2,480 / 1,061.

So decide on maintenance, not bytes. vad-web is 69 KB of well-trodden code that
handles the model's 64-sample context carry, the frame state machine, misfire
rejection, and worklet/ScriptProcessor fallback. Our direct engine
(`silero-direct.js`) matched it on every measured axis — so the library is not
buying us performance, it is buying us the fiddly edge cases.

Two caveats that make this a *qualified* recommendation:

1. **Override every default** (F4). Adopting them silently misses the latency budget.
2. **`silero-direct.js` stays in-tree as the exit.** It is ~150 lines, it is
   measured, and it is the fallback if vad-web's release cadence (a 0.0.x
   package, ISC) becomes a problem. Vendoring rather than CDN-loading is also
   the right call for production: 5.5 MB is a lot to make conditional on
   `cdn.jsdelivr.net` being up.

**Serve the wasm compressed.** 13.96 MB raw → 3.57 MB gzip is the single biggest
lever on first load. (FWIW ort 1.19.2's wasm is 11.0 MB vs 1.29.0's 13.96 MB —
~21 % smaller, but not worth pinning a runtime 10 minors behind for.) Cache it
hard: it never changes between deploys.

### VAD settings for a 500–700 ms end-of-speech budget

```js
const VAD = {
  model: 'v5',                      // 512-sample frames = 32 ms
  positiveSpeechThreshold: 0.5,     // vs library 0.3
  negativeSpeechThreshold: 0.35,    // vs library 0.25
  redemptionMs: 600,                // vs library 1400  <-- THE latency knob
  preSpeechPadMs: 500,              // vs library 800
  minSpeechMs: 250,                 // vs library 400
};
```

Measured with exactly these: **EOS p50 608 ms / p95 640 ms**, inside budget;
**0 false triggers** in 5 minutes of pink noise; pre-roll onset 420–510 ms;
7/7 utterances detected, 0 misfires.

Rationale per knob:

- **`redemptionMs: 600`** — the budget is 500–700 ms and EOS ≈ `redemptionMs`
  rounded to the 32 ms grid. 400 ms also works (416 ms measured) and is worth
  trying live, but shortens the natural mid-sentence pause you can take before
  the utterance is cut. 600 is the safe default; expose it as a setting.
- **`positiveSpeechThreshold: 0.5`** (raised from 0.3) — noise never exceeded
  0.243 even at −26 dBFS, so 0.5 keeps a wide margin at no measured cost to
  detection (7/7 at both 10 dB and 5 dB SNR).
- **`preSpeechPadMs: 500`** — enough to contain the onset (measured 420–510 ms)
  without padding every segment with 800 ms of room tone that Whisper can
  hallucinate on. Do not go below ~300 ms.
- **`minSpeechMs: 250`** (lowered from 400) — "orca send" is ~660 ms, but a bare
  "stop" can be under 400 ms and would be silently dropped at the default.

Per §6.1 the rest of the browser-side budget is noise: resampling ~0.6 % duty,
VAD inference 3.5 ms/frame pipelined (queue backlog max 0). The 500–700 ms
target is achievable, and `redemptionMs` is the only knob that moves it.

---

## Human-in-the-loop procedure (Zach)

**~10 minutes.** Everything above except AEC efficacy is already measured; this
is the part a machine cannot do.

### Getting there

`getUserMedia` needs a **secure context**. `http://localhost:<port>` counts;
`http://192.168.1.177:<port>` does **not** — `navigator.mediaDevices` is simply
`undefined`, with no error, which looks exactly like broken code. The page shows
a red banner if you land on a non-secure origin.

```bash
# on debian (192.168.1.177)
cd ~/orca_hub/spikes/voice && ./serve.sh          # -> http://localhost:8777/
```

- **Chrome on debian itself:** open <http://localhost:8777/>
- **Chrome on another machine:** `ssh -L 8777:127.0.0.1:8777 zach@192.168.1.177`
  then open <http://localhost:8777/> **on your own machine** (the tunnel makes
  `localhost` the secure origin — do not use the LAN IP).

Port 8777 is deliberate: **4000 and 4001 belong to the dev server and the local
prod release.**

### Step 1 — mic + pre-roll (2 min) · **speakers or headphones, doesn't matter**

1. Click **`open mic (AEC/NS/AGC ON)`**, grant the permission prompt.
2. Check the table: **`echoCancellation applied` should be green `true`**. Note
   the **AudioContext sampleRate** (may well not be 48000 — that is finding F2).
3. Click **`record (direct Silero)`**.
4. Say **"orca send"**, pause ~2 s, repeat **three times**. Then **`stop run`**.
5. In the segments table, read the **`onset ms`** column. **It should be ~420–510,
   not ~0.** That is the pre-roll working. Three WAVs are already saved to
   `spikes/voice/out/` — play one and confirm you hear the full word "orca",
   not "rca".

### Step 2 — AEC A/B (5 min) · **SPEAKERS ON, HEADPHONES OFF — this is the point**

Headphones make the test meaningless: there is no acoustic path to cancel.

1. Turn the speakers to a normal listening volume.
2. Click **`run AEC A/B`** and **stay quiet for ~25 s** while it plays a TTS clip
   twice (once with AEC on, once off).
3. Read the AEC table.

What to copy back:

| | what it means |
|---|---|
| `Δ dB` for **aec-on** | how much of our own TTS leaks into the mic **with** AEC |
| `Δ dB` for **aec-off** | the same **without** AEC |
| **`AEC suppression = N dB`** | the headline. **> ~15 dB → spec §4.1 rung 3 (full duplex) is plausible. < ~6 dB → half-duplex is the permanent answer.** |
| `triggers (playback)` for each | **any non-zero with AEC on means our own voice would false-trigger the VAD** — the thing that actually breaks the product |

### Step 3 — barge-in feel (2 min, optional but valuable)

Click `run AEC A/B` again and this time **say "orca send" while the clip is
playing**. Watch whether a segment is detected and whether the dumped WAV
contains your voice or mostly the TTS. This is the qualitative half of the
barge-in question that no metric captures.

### Step 4 — send the results back

Click **`copy results JSON`** (or **`POST results to out/`**, which writes
`spikes/voice/out/results-<ts>.json`) and paste it into the thread. If you only
want the short version, the four AEC numbers from step 2 plus the onset column
from step 1 are enough.

**Stopping the server:** `Ctrl-C`, or `kill $(cat out/server.pid)`.
