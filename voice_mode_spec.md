# Voice Mode — Design Spec (DRAFT, v0.3)

Status: DRAFT — SPIKE 1 (browser capture) + SPIKE 2 (GB10 ASR) folded in;
SPIKE 2b (wake-word) + SPIKE 3 (keyword spotter) pending; AEC acoustic test
pending Zach. Author: orchestrator handoff, 2026-09-14.
Owner: finalize this document before writing production code.

Real-time voice interaction with an OrcaHub session: open mic -> VAD-gated
transcription on GB10 -> accumulate a draft -> a spoken trigger sends it ->
the assistant's reply is spoken back, with barge-in control.

## 1. Goals

1. Talk into the mic; utterances accumulate into a visible draft.
2. A spoken command ("orca send") submits the draft to the session.
3. The assistant's response is spoken back as it arrives, not only at turn end.
4. Spoken playback control ("orca stop", "orca pause") with low latency.
5. Eventually: leave the channel open during playback, with the system's own
   audio filtered out of the mic input so the user can barge in.

Non-goals for v1: multi-speaker diarization, wake-word activation of the whole
mode (there is an explicit button), non-English, mobile Safari parity.

## 2. What already exists (verified in-tree, 2026-09-14)

The OUTPUT half is roughly 70% built. Do not rebuild it.

- `assets/js/app.js` `TTSMethods` — a complete playback engine: sentence
  chunking (`ttsSplitIntoChunks`), an abortable prefetch pipeline with 429
  backoff (`ttsFetchAudio` / `ttsRequestChunk`), play/pause/stop/prev/next,
  autoplay via the `tts-autoplay` LiveView event, bearer token delivered to JS
  via the `tts-config` event, autoplay preference in localStorage.
- `assets/js/app.js` `ttsCleanText` (~line 253) — an already-developed
  speakable-text filter: strips code fences, keeps inline-code content,
  a termMap of Elixir/programming pronunciations, file-path and filename
  flattening, underscore handling.
- `lib/orca_hub_web/controllers/tts_controller.ex` — `POST /api/tts`, behind
  the `:api_authed` pipeline, 4000-byte cap, delegates to
  `OrcaHub.TTS.synthesize/2` with `HubRPC.resolve_tts_config()`.
- `lib/orca_hub/tts_config.ex` — DB-backed provider/model config
  (`tts_provider` / `tts_model` entry kinds) with PER-FIELD resolution
  DB -> env -> hardcoded, deliberately uncached. Default URL is
  `https://ai.lab.ingbretsenhome.com`. Read its moduledoc; the ASR config
  should copy this pattern exactly, including the no-cache decision.
- `lib/orca_hub_web/channels/user_socket.ex` and `terminal_channel.ex` — an
  existing Channel + socket precedent to model `VoiceChannel` on.
- `OrcaHub.ApiTokens` — scoped, revocable, SHA-256-hashed tokens with optional
  per-session pinning. v1 does NOT need one for voice — see section 8 for why,
  and for the pre-existing TTS token exposure it uncovered.
- `SessionViewersRegistry` — per-session live-viewer tracking, the natural
  place to hang a single-voice-owner claim.
- `spikes/voice/` — the SPIKE 1 harness, and the REFERENCE IMPLEMENTATION of
  the capture path: `index.html` / `harness.js` (getUserMedia, metrics, WAV
  dump, AEC A/B panel), `capture-worklet.js` (windowed-sinc LPF + fractional
  decimation to 16kHz with the pre-roll ring), `silero-direct.js` (Silero
  driven straight on onnxruntime-web — the measured exit from vad-web),
  `tools/headless.mjs` (playwright driver on a fake capture device),
  `tools/fetch_vendor.sh` (re-fetches the ~19MB of gitignored wasm/onnx from
  pinned versions, byte-reproducible), `serve.sh` on :8777. DELIBERATELY
  OUTSIDE `priv/static` and `package.json` — nothing in the app imports it and
  no dependency was added. Production code should PORT FROM IT rather than
  re-derive it; every measurement in sections 3.2, 4 and 9 came from there.

There is NO microphone, VAD, ASR, or audio-capture code in the APPLICATION
tree (grep for whisper/transcri/getUserMedia/AudioWorklet/MediaRecorder
returns only unrelated `memory_extraction` hits) — only the `spikes/voice/`
harness above, which is not wired in.

## 3. Architecture

Browser does capture, VAD, and wake-word spotting. Server does ASR dispatch,
intent adjudication, and TTS orchestration. GB10 serves ASR + TTS over HTTP.

    mic -> AudioWorklet (ctx rate -> 16k mono, ring buffer w/ pre-roll)
        -> Silero VAD (onnxruntime-web) -> speech segments only
        -> VoiceChannel (binary frames)
        -> OrcaHub.Voice.ASR (HTTP -> GB10)
        -> transcript -> OrcaHub.Voice.Intent -> {WAIT | SEND | STOP | PAUSE | CANCEL}
        -> on SEND: Cluster.send_message(node, session_id, draft, :queue)

    session PubSub assistant deltas -> sentence accumulator -> existing TTS
        chunk queue -> playback -> playback timeline (text + start/end ts)

### 3.1 Why a Channel, not LiveView

Channels carry binary payloads natively; LiveView is the wrong shape for
~20ms audio frames. New `OrcaHubWeb.VoiceChannel` on the existing
`user_socket`. Follow `terminal_channel.ex` for structure, but prefer RAW
binary pushes over that module's base64 convention for audio.

### 3.2 Client-side VAD is non-negotiable

Reasons, in order of importance:

1. SEGMENTATION INTO UTTERANCES. The whole draft/command UX is built on them:
   one completed VAD segment is one ASR call, one draft line, and the one
   place a terminal command can appear. Without client-side endpointing there
   are no boundaries to hang any of that on.
2. Raw 48kHz PCM is ~1.5 Mbps and would be mostly silence.
3. GB10 stays idle between utterances.
4. Latency — ASR cost scales with clip length (section 6.1), so shipping only
   speech keeps every call in the 570-800ms band.

NOT a reason, contrary to v0.1: silence hallucination. SPIKE 2 measured 0
non-empty results across 173 requests — digital silence, white and pink noise
at -50/-35/-20/-10 dBFS, room noise with clicks, and a 19s tone. WhisperX runs
a pyannote VAD gate BEFORE the decoder, so this is an architectural property
of the endpoint, not a probabilistic one that a threshold change might
reintroduce. Quiet speech is not dropped either (transcribes correctly at
-50 dBFS peak).

DECISION (SPIKE 1, measured): use `@ricky0123/vad-web` 0.0.31 (ISC) on
onnxruntime-web 1.29.0 (MIT), Silero v5 (`silero_vad_v5.onnx`, 2,327,524 B,
512-sample frames = 32ms), OVERRIDING EVERY DEFAULT:

```js
const VAD = {
  model: 'v5',                      // 512-sample frames = 32 ms
  positiveSpeechThreshold: 0.5,     // library default 0.3
  negativeSpeechThreshold: 0.35,    // library default 0.25
  redemptionMs: 600,                // library default 1400  <- THE latency knob
  preSpeechPadMs: 500,              // library default 800
  minSpeechMs: 250,                 // library default 400
};
```

Do NOT roll an energy threshold. Do NOT use the legacy WebRTC GMM VAD.

WARNING — THE DEFAULTS ARE WRONG FOR THIS PRODUCT. vad-web 0.0.31 ships
`redemptionMs: 1400`, `preSpeechPadMs: 800`, `minSpeechMs: 400` and thresholds
0.3/0.25, which measured EOS 1376ms — 2x the section 6.1 budget, on the term
section 6.1 already names as dominant. Adopting the library without overriding
these silently misses this spec's own latency target. `minSpeechMs` must come
DOWN to 250 as well: a bare "stop" can be under 400ms and would be discarded
without a trace. The API names are `redemptionMs` / `preSpeechPadMs` /
`minSpeechMs` — NOT the `*Frames` names v0.1/v0.2 used; the frame counts are
derived internally (`Math.floor(ms / 32)`).

Bundle size is NOT a differentiator, so choose on maintenance, not on bytes:
5,560,445 B gzip (vad-web) vs 5,543,660 B (direct Silero), 0.3% apart, both
dominated by ort's wasm at 13.96 MB raw / 3.57 MB gzip. SERVE THE WASM
COMPRESSED AND CACHE IT HARD — that is the single biggest first-load lever,
and it never changes between deploys. vad-web wins because it carries the
model's 64-sample context carry, the frame state machine, misfire rejection
and worklet fallback; `spikes/voice/silero-direct.js` stays in-tree as the
MEASURED EXIT if a 0.0.x release cadence becomes a problem.

Measured with exactly those settings (harness in section 2):

- EOS p50 608ms / p95 640ms. EOS tracks `redemptionMs` almost exactly —
  416 / 608 / 1408ms for 400 / 600 / 1400 — so `redemptionMs` IS the
  end-of-speech knob, and everything else in the browser half is single-digit
  milliseconds. 400 also fits (416ms) but shortens the mid-sentence pause the
  user may take before the utterance is cut; expose it as a setting.
- 0 false triggers in 5 x 60s of pink noise at -50 / -40 / -26 dBFS. The
  speech probability on noise peaked at p95 <= 0.0096, max 0.243 — a wide
  margin under 0.5, so this is not a marginal call.
- 7/7 utterances detected, 0 misfires.
- Silero inference p50 3.3-3.5ms / p95 3.9-4.2ms per 32ms frame (realtime
  factor 0.11) on ONE single-threaded wasm thread. Therefore NO COOP/COEP and
  NO wasm threads: there is already ~9x headroom, and cross-origin isolation
  would force CORP/CORS onto every cross-origin asset for no measured gain.
- Session init 499ms (direct Silero) / 533-809ms (`MicVAD.new`). INITIALIZE AT
  ARM TIME (the start-voice-mode button), not on first speech, or the cold
  start eats the first utterance.

Ring-buffer ~500ms of PRE-ROLL. VAD fires after speech has begun; without
pre-roll the first phoneme of every utterance is clipped and "send" becomes
"end". This is a known, cheap, easy-to-forget bug. SPIKE 1 confirms the
mechanism works: speech onsets land at 420-510ms inside a 500ms-pre-roll
segment (median 480ms over 52 dumped WAVs, re-measured offline by an
independent implementation), not at ~0.

Belt-and-braces even with VAD — but NOT the v0.1 filter, which is
unimplementable here: the sync lane returns no `no_speech_prob`,
`avg_logprob` or `compression_ratio`, and WhisperX's batched pipeline cannot
produce them (section 6). The two signals that DO exist:

- A HARD MINIMUM SEGMENT DURATION FLOOR of ~0.8s before ASR DISPATCH. Short
  fragments are the real hallucination mode on this endpoint: a 0.3s cut of
  "Orca" returned `"archives."`, a 0.2s cut returned `"R."`, while anything
  above ~0.8s transcribed correctly.

  RECONCILIATION with `minSpeechMs: 250` above — the two floors live at
  different layers and both are right. The CLIENT keeps segments down to
  250ms, because the command path needs them (a bare "stop" is shorter than
  400ms, and under section 5.1 path (a) the short segment may BE the
  command). The ASR DISPATCHER never sends a sub-0.8s segment as-is; it holds
  it and, in order of preference: (i) MERGES it with the next segment if one
  arrives inside the arming window (section 5.1), which is the common case
  for a command spoken right after dictation; else (ii) PADS it to ~0.8s from
  the pre-roll and post-roll silence the ring buffer ALREADY CAPTURED —
  `preSpeechPadMs` 500 in front plus the redemption tail behind (measured
  trailing silence median 673ms), which is always enough. Never synthesize
  silence that was not recorded, and never discard a short segment outright.
- `elapsed_seconds` < ~50ms means the SERVER's VAD found nothing — non-speech
  returns in ~14ms against ~500ms for real speech. Treat such a result as
  silence.

Keep a small blocklist for the known fragment artifacts above; it is now a
mop-up, not a primary defence.

## 4. Echo cancellation — the decision and its rationale

DECISION: use the browser's AEC. Do NOT hand-roll signal-domain cancellation
of the known playback signal.

Knowing the played signal exactly is the easy 10% of AEC. The hard parts:

- The mic hears the signal convolved with room + speaker + mic, an unknown and
  time-varying impulse response. That needs a continuously converging adaptive
  filter (NLMS/RLS) with hundreds of ms of taps.
- The delay is unknown and DRIFTS. Capture ADC and playback DAC run on
  different clocks; a few ppm of drift decorrelates a perfectly aligned
  canceller within seconds. Bluetooth adds 100-300ms on top.
- Speaker/AGC nonlinearity produces harmonics no linear filter can subtract —
  which is why every real AEC bolts a residual echo suppressor on the back.

WebRTC's AEC3 is ~15k lines for these reasons and ships in the browser:
`getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true,
autoGainControl: true } })`. It is applied at capture, before the track reaches
an AudioWorklet, and uses the browser's own render stream as reference — which
is exactly TTS played through the same page. Headphones make it moot.

SPIKE 1 verified the CONSTRAINT half of that on Chrome 149 / Chromium 153 on
Linux: `getSettings()` reports `echoCancellation: true` when requested true and
`false` when requested false, so the flag is genuinely honoured in both
directions rather than being a constant. `noiseSuppression` and
`autoGainControl` apply likewise — NS does ~6.3 dB of real work on the capture
path (pink-noise floor -56.8 dBFS with it on vs -50.5 dBFS off). Also observed:
`channelCount` 1, track 48kHz, `voiceIsolation: false`. PIN `voiceIsolation`
EXPLICITLY rather than inheriting it: where it exists it is a THIRD processing
stage alongside NS and AEC, and it can distort speech.

NONE OF THAT IS EVIDENCE THAT AEC SUPPRESSES OUR TTS. SPIKE 1 ran headless on
a fake capture device, which injects a WAV straight into the capture pipeline
— no speaker, no room, no microphone, and therefore no echo to cancel. Its
~0 dB residual is what "there was never any echo" looks like, not what "AEC
removed the echo" looks like. That question is answerable only by a human with
real speakers and no headphones; see section 4.1.

LAYER 2 — text-domain echo rejection. This is where the "we know what we are
playing" insight genuinely pays off. Maintain a playback timeline of
(text, start_ts, end_ts) for every TTS chunk. Fuzzy-match any transcript
arriving during playback against the text in flight (with a time window); a
near-match is echo, drop it. Immune to drift, impulse response, and
nonlinearity — all the things that make the DSP version miserable. Roughly 40
lines of code.

### 4.1 Barge-in policy ladder

Ship in this order; each rung is independently useful:

1. HALF-DUPLEX — mute mic during playback. Always works. **v1 ships this.**
2. DUCK-ON-DETECT — drop TTS to ~20% when VAD fires. Also cuts echo, and
   feels responsive.
3. FULL DUPLEX — open channel, browser AEC + text-domain rejection.

RUNG 1 IS NOT SKIPPABLE ON SPIKE 1's EVIDENCE (section 4) — v1 mutes the mic
during playback and stands on its own merits. Whether rung 3 is reachable at
all is decided by ONE human measurement, not by any number in this document.
The procedure is in `spikes/voice/README.md`:

    cd ~/orca_hub/spikes/voice && ./serve.sh      # -> http://localhost:8777/

Open it on `localhost` (NEVER the LAN IP — section 9 trap 1), SPEAKERS ON and
HEADPHONES OFF (headphones remove the acoustic path and make the test
meaningless), click `run AEC A/B`, stay quiet ~25s. DECISION RULE on the
reported `AEC suppression`:

- **> ~15 dB** -> rung 3 (full duplex) is plausible. Ship rungs 1-2 first,
  then revisit.
- **< ~6 dB** -> HALF-DUPLEX IS THE PERMANENT ANSWER. Do not build rung 3.
- in between -> duck-on-detect (rung 2) is the ceiling; re-measure on the
  actual target hardware before going further.

Independently of the dB figure: any non-zero `triggers (playback)` with AEC ON
means our own voice false-triggers the VAD, which breaks the product on its
own.

## 5. Command classification — two separate paths

The key design insight: SEND is a transcript-domain decision; STOP/PAUSE is a
wake-word-domain decision. Serving both from one pipeline is what makes these
systems feel sluggish.

### 5.1 SEND (spoken while dictating, mic path healthy)

Cheap layer first — this is the v0.1 design, and SPIKE 2 has since shown it
is not sufficient as written (see the DECISION below):

- TWO-WORD WAKE PREFIX: "orca send", "orca cancel". Bare "send" is a common
  English word; "orca send" is not. This alone kills most false positives.
- MATCH ONLY AT TERMINAL POSITION of a completed VAD segment. "Send the email
  to Bob" cannot fire because `send` is not last. This single heuristic does
  more work than any model.
- Strip command tokens from the draft before submitting.
- ARMING WINDOW: on SEND, show a ~1.5s countdown chip that any further speech
  cancels. Removes the entire "it sent too early" pain class. Default ON for
  SEND only; configurable.

DECISION — PENDING SPIKE 2b / SPIKE 3. The design above is UNSAFE AS WRITTEN.
The two-word prefix at terminal position ASSUMED the ASR renders "orca send"
reliably. SPIKE 2 measured that it does not, deterministically over 10 reps
each:

| spoken | returned |
|---|---|
| "Orca send." (isolated) | `"or Cassand."` |
| "Orca stop." (isolated) | `"Orca stopped."` |
| "Orca stop. Before you do anything else…" | `"or Castap. …"` |
| "Orca send. Let's ship the patch today." | `"Orca Send."` (correct) |

Observed surface forms: `Orca` · `Orca,` · `Orcasend` · `orcus` ·
`or Cassand` · `or Castap` · `or to` · `If Orca`. Whisper needs surrounding
context, and an ISOLATED ONE-WORD COMMAND is exactly how a send is spoken —
so the worst measured case is the primary case.

Two remedies are being measured in parallel; the choice is data-driven, not
editorial:

- (b) KEEP SEND ON THE TRANSCRIPT PATH, with an EMPIRICALLY CHOSEN vocabulary
  plus a phonetic / edit-distance matcher over the last 1-3 normalized tokens
  instead of an exact string match. SPIKE 2b is sweeping ~18 candidate
  phrases x 3 placements x >=5 voice variants against the real endpoint, plus
  false-positive rates against ordinary dictation.
- (a) MOVE SEND ONTO THE KEYWORD-SPOTTER PATH alongside STOP/PAUSE (section
  5.2), collapsing to one rule: ALL control goes through the in-browser
  spotter, and the transcript is dictation only. SPIKE 3 is measuring
  Porcupine vs openWakeWord in the browser.

CRITERION: (b) wins if SPIKE 2b finds a vocabulary with >= 95% true-positive
across variants and ~0% false positives on ordinary speech, confirmed on
Zach's real voice via the 5-recording procedure 2b will publish. Otherwise
(a).

Under (a) the spotter fires BEFORE the final segment's transcript arrives, so
SEND must WAIT for the in-flight ASR call to return and strip the command
tokens from it — that requirement does not disappear, it moves.

Whichever path wins, the ARMING WINDOW stays.

Error costs are asymmetric but neither is catastrophic: a false positive sends
early (recoverable by a follow-up message); a false negative means you repeat
yourself.

LLM adjudicator — ONLY for the ambiguous middle, and only if the heuristics
prove insufficient in real use. A 0.6-1.7B model on GB10 with output
CONSTRAINED TO A SINGLE TOKEN from {WAIT, SEND, STOP, PAUSE, CANCEL}. Do not
generate JSON; take the constrained argmax after prefill. ~30ms, one forward
pass, predictable in a way free-form JSON is not. This is phase 5, not phase 1.

### 5.2 STOP / PAUSE (spoken DURING playback)

Must NOT go through the transcript path — that is precisely when the ASR path
is muted or echo-degraded, and it is the one command where ~1s latency feels
broken. Use a dedicated always-on keyword spotter in the browser: Picovoice
Porcupine (solid web SDK, custom wake words, negligible CPU) or openWakeWord
(Apache-2.0). Target ~100ms, no server round trip, works while ASR is gated.

## 6. ASR on GB10

PATH A (v1) — UTTERANCE-LEVEL, NOT STREAMING, AGAINST THE SERVICE THAT IS
ALREADY RUNNING. VAD supplies segment boundaries; each utterance is one ASR
call. NO NEW SERVICE IS NEEDED. This matches the actual UX: talk, utterances
accumulate into a draft, say send. Word-level streaming partials are NOT
needed for that, and chasing them first will cost weeks.

The contract, measured (SPIKE 2):

- `POST http://192.168.1.77:8000/v1/transcribe/sync` — the SYNC LANE of the
  existing `transcription` container, compose-managed at
  `/home/zach/transcription/docker/docker-compose.yml`. There is NO systemd
  unit. Stack: WhisperX 3.3.1 -> faster-whisper 1.1.0 -> CTranslate2 4.4.0.
- Warm, GPU-RESIDENT, and UNAUTHENTICATED ON THE LAN.
- Model `large-v3-turbo`, float16, CUDA, arbiter priority 80. There is no
  model selection on this lane.
- It is NOT OpenAI-compatible. `/v1/audio/transcriptions` 404s everywhere on
  this box, INCLUDING `ai.lab.ingbretsenhome.com` — that hostname resolves to
  the k3s VIP and fronts an `ai-gateway` app that proxies only TTS.
- DO NOT RE-DERIVE "GB10 HAS NO ASR" FROM THE GATEWAY. SPIKE 1 probed only
  `ai.lab.ingbretsenhome.com` and concluded that no ASR endpoint exists
  anywhere. That is CORRECT ABOUT THE GATEWAY — its `/v1/models` lists six
  models and not one is ASR, while TTS `/v1/audio/speech` does work (24kHz
  mono WAV in 0.6-1.7s) — and WRONG AS A CONCLUSION: the ASR lane is the LAN
  sync lane above, `192.168.1.77:8000`, which SPIKE 2 measured end to end.
  Both statements are true at once; they are different hosts.
- `multipart/form-data` ONLY; anything else is 415. Fields: `file` plus
  `language=en`. MAX 4 FORM FIELDS — more is a 400.
- Clip <= 20s and upload <= 25 MiB, else 413. Server timeout 30s, surfaced as
  504.
- `response_format` and `initial_prompt` are SILENTLY IGNORED. PROMPT BIASING
  IS NOT AVAILABLE — do not design around it. (This is what forces the
  section 5.1 decision.)
- Errors are `{"detail": "<string>"}` with no machine-readable code — switch
  on HTTP STATUS, not on the body.
- `200` with `text: ""` is the NORMAL non-speech result, NOT an error.
- webm/opus uploads are accepted directly and were FASTER than WAV (596ms vs
  930ms), so the browser may post MediaRecorder output as-is, with no
  client-side WAV encoding. SPIKE 2b is confirming whether that win is decode
  cost or payload size.
- ASR (`:8000`) and Chatterbox TTS (`tts-service:8110`, 24kHz) are SEPARATE
  containers, sharing only the GPU arbiter at `:8090`.

```bash
curl -sS -X POST http://192.168.1.77:8000/v1/transcribe/sync \
  -F file=@utterance.wav -F language=en --max-time 35
```

```json
{"text":"Send the email to Bob and copy Alice on it, then open a new session on the GB10 box and start benchmarking the transcription endpoint with 10-second utterances, please.",
 "language":"en","duration":8.32,"model":"large-v3-turbo","elapsed_seconds":0.967}
```

The response is EXACTLY those five fields — `text`, `language`, `duration`,
`model`, `elapsed_seconds`. No segments, no word timestamps, no confidence
fields.

COLD START: 12.5s measured; 35s is the arbiter's own restore budget. Design
for it — see section 6.1.

PATH B (later, if true streaming is wanted) — NVIDIA Parakeet /
FastConformer-TDT via NeMo. Genuinely streaming (RNNT/TDT) rather than 30s
window models, NVIDIA's own so aarch64 Blackwell is first-class, and
Parakeet-TDT-0.6B is both top-of-leaderboard for English and very fast.
NVIDIA Riva packages streaming ASR + TTS + endpointing in one aarch64
container if buying beats building.

PATH B assessment (measured, SPIKE 2) — NOT v1. Nothing NeMo/Riva/Parakeet is
installed on GB10 today; `onnxruntime 1.23.2` is. `parakeet-tdt-0.6b-v2.nemo`
is 2.30 GiB at 6.05% WER, but Parakeet-TDT is an OFFLINE model and therefore
the WRONG TARGET for streaming — the cache-aware
`stt_en_fastconformer_hybrid_*_streaming_*` models are the right one. The
binding constraint on GB10 is MEMORY (the arbiter reports
`exceeds_threshold: true` today), not speed, so throughput gains buy little.
If it is ever spiked: ONNX first (~0.62 GiB int8), NOT `nemo_toolkit` (~5 GB,
and it pins torch). Estimated 1-2 days.

GB10 is ARM64 (aarch64) Grace + Blackwell, 128GB unified memory, at
192.168.1.77. x86 images/binaries will not run. It is the shared local AI
backend; what it serves for ASR and TTS is now established above.

### 6.1 Latency budget (path A, end-of-speech to message sent)

Measured warm wall clock on the sync lane, 12 reps per clip. The p95/p50
spread is under 5% and all 13 clips returned byte-identical transcripts on
every rep — this endpoint is deterministic, not merely fast on average:

| clip duration | p50 | p95 |
|---|---|---|
| 1.4-1.8s (bare command) | 569ms | 596ms |
| 3.9-5.0s | 772ms | 791ms |
| 5.9-8.3s | 1020ms | 1046ms |
| 9.9-11.9s | 1323ms | 1349ms |

Concurrency is a clean FIFO on a single GPU thread: 2/3/4 simultaneous
requests give p50 1450/1466/1522ms, p95 topping out at 2912ms, 0 errors. One
voice session never contends with itself, but a second voice session — or any
sibling transcription job — roughly doubles the tail.

Budget for a typical 1.5-5s utterance:

| Stage | Measured / target |
|---|---|
| VAD endpointing | 500-700ms **(dominates — main tuning knob)** |
| transport (LAN) | ~20ms |
| ASR (sync lane, warm) | 570-800ms |
| intent (string match) | ~0ms |
| **total** | **~1.1-1.5s end-of-speech -> sent** |

That is the honest number. v0.1's "< 1s" was not achievable against this
endpoint and must not be held as a target.

COLD-START CLIFF: if the model has been evicted, the FIRST call costs up to
35s (12.5s measured restore; 35s is the arbiter's own restore budget). The
design must therefore fire a WARM-UP request the moment voice mode is ARMED
(the start button), show an explicit "warming up" state until it returns, and
use a 35s client timeout FOR THAT FIRST CALL ONLY — steady-state calls get a
much tighter one.

CLIP CAP: the endpoint rejects anything over 20s (413), so a VAD segment
longer than ~18s must be SPLIT client-side before dispatch.

## 7. TTS as deltas arrive

Today `tts-autoplay` fires with a `message_id` at message COMPLETION. To speak
during a turn, add a sentence accumulator on the assistant text deltas from the
`session:<id>` PubSub topic, feeding the EXISTING chunk queue. The queue,
prefetch, and transport controls already work — this is a new producer, not a
new player.

The real product problem is WHAT NOT TO SPEAK. The feed is mostly tool calls,
diffs, and file lists. `ttsCleanText` handles the lexical layer but not "do not
read 400 lines of diff aloud". Policy: speak assistant PROSE blocks only;
render tool activity as short earcons or a one-phrase announcement ("running
tests"), never the payload.

## 8. Server-side shape

- `OrcaHubWeb.VoiceChannel` — audio frames in, transcripts/state out.
- `OrcaHub.Voice` context, with `Voice.ASR` (HTTP client to GB10) and
  `Voice.Intent`.
- `OrcaHub.ASRConfig` — sibling of `TTSConfig`, same kind/name/spec/enabled
  table shape, same PER-FIELD DB -> env -> hardcoded resolution, same
  deliberate no-cache decision. Read `tts_config.ex`'s moduledoc first.
  Fields: `url` (default `http://192.168.1.77:8000`), `path` (default
  `/v1/transcribe/sync`), `language`, `timeout_ms`, `warmup_timeout_ms`.
  There is NO `model` field — the sync lane offers no model selection
  (section 6).
- AUTH: v1 needs NO new `ApiToken` and NO new scope. v0.1 said to mint a
  session-pinned token with a `voice` scope and push it "the way `tts-config`
  already does". Verified in-tree, that is wrong on both halves:
  - `tts-config` pushes the GLOBAL `ORCA_API_TOKEN`
    (`Application.get_env(:orca_hub, :api_token)`, `session_live/show.ex`
    ~line 3368) to the browser — not a scoped `ApiToken`. It is a
    PRE-EXISTING EXPOSURE, not a pattern to copy.
  - `tts` and `a2a` are both in `@pinned_forbidden_scopes` (`api_token.ex`),
    so a session-pinned token cannot carry `tts` today in any case.
  - `OrcaHubWeb.UserSocket.connect/3` accepts every connection with no token,
    and `TerminalChannel.join/3` has no auth of its own; the deployment
    relies on Authelia at the ingress plus `check_origin`.

  So `VoiceChannel` rides `user_socket` on the terminal precedent; ASR calls
  are made SERVER-SIDE, so the browser never holds an ASR credential (the lane
  is LAN-unauthenticated anyway); and the only browser-held bearer remains the
  existing TTS one. Still: do not add a second auth mechanism.
- FOLLOW-UP, out of scope for voice but do not lose it: replace the global
  `ORCA_API_TOKEN` pushed by `tts-config` with a `tts`-scoped, non-pinned
  `ApiToken`.
- DEPLOYMENT PRECONDITION: every node that can terminate a voice websocket
  must be able to reach `192.168.1.77:8000` — k3s pods included, since they
  sit on the pod network rather than the LAN.
- SENDING: `Cluster.send_message(node, session_id, text, :queue)`. Default
  `:queue`, matching the `TriggerExecutor` precedent — "send" must not cancel
  an in-flight turn.
- OWNERSHIP: a single-voice-owner claim per session via
  `SessionViewersRegistry`, so two open tabs do not both capture.
- NODE ROUTING: never silently re-route to a different node if the session's
  assigned `runner_node` is unavailable — surface the error. See
  `.context/clustering.md`.

## 9. Known traps

1. **`getUserMedia` requires a SECURE CONTEXT.**
   `https://orca.lab.ingbretsenhome.com` OK, `http://localhost:4000` OK, but
   `http://192.168.1.x:4001` FAILS — `navigator.mediaDevices` is simply
   `undefined`, no error thrown. Instances run on LAN hosts on port 4001, so
   this WILL be hit. Test on localhost or through the https ingress. The
   `spikes/voice/` harness shows a RED BANNER when loaded from a non-secure
   origin — the cheapest possible version of this check; copy it.
2. **Autoplay policy** requires a user gesture before audio can play. The
   "start voice mode" button satisfies it; do not auto-arm on page load.
3. Short-fragment hallucination — sub-0.8s segments transcribe as garbage
   ("archives.", "R."); silence itself is safe (section 3.2).
4. VAD pre-roll clipping (section 3.2).
5. **`AudioContext.sampleRate` is NOT the mic's sample rate.** In SPIKE 1 the
   track negotiated 48000 Hz while the context negotiated 44100 Hz — a
   resample ratio of **2.75625, not 3**. The worklet sees the CONTEXT's rate
   (the `sampleRate` global); the browser has already resampled the track into
   it. NEVER hardcode `/3` or `48000`: a wrong ratio yields ~10% pitch-shifted
   audio, and Whisper transcribes pitch-shifted audio into plausible WRONG
   WORDS rather than failing loudly. Resample from `ctx.sampleRate` to 16000
   in the worklet (not on the server) with a PROPER LOW-PASS — SPIKE 1 used a
   63-tap windowed-sinc LPF plus fractional decimation via a phase
   accumulator, measured at 0.58% duty cycle (p50 15-17 us per 128-frame
   block) at both 48k and 44.1k, with VAD queue backlog max 0. Tag every frame
   posted to the main thread with an ABSOLUTE 16kHz sample index, so a late
   pre-roll request still returns exactly the right audio.
6. Mobile Safari AudioWorklet/getUserMedia quirks — explicitly out of scope
   for v1, but do not architect in a way that forecloses it.
7. **`performance` does not exist in `AudioWorkletGlobalScope`.** Calling
   `performance.now()` inside `process()` throws a `ReferenceError`; Chrome
   then fires `onprocessorerror` ONCE and SILENTLY STOPS CALLING `process()`
   FOREVER. No console error, no exception anywhere reachable, the
   `AudioContext` stays `running` and `currentTime` keeps advancing — you just
   get zero audio frames, which is indistinguishable from broken
   `getUserMedia`. Verified on Chromium 153 AND Chrome 149; it cost SPIKE 1 a
   debugging cycle and will cost production one too. Mitigation: always attach
   `node.onprocessorerror`, time the worklet with the audio clock
   (`currentTime` / `currentFrame`) only, and do ALL wall-clock timing on the
   main thread.
8. **A worklet node with no path to `ctx.destination` is never pulled by the
   render graph**, so `process()` never runs — equally silently, with the same
   zero-frames symptom as trap 7. The capture node emits no audible output but
   must still be connected onward: a `GainNode({gain: 0})` into
   `ctx.destination` is enough.

## 10. Phasing

1. Mic -> Silero VAD -> utterance -> GB10 ASR -> draft box. Half-duplex.
   VAD is `@ricky0123/vad-web` with section 3.2's EXPLICIT settings
   (`model: 'v5'`, thresholds 0.5/0.35, `redemptionMs: 600`,
   `preSpeechPadMs: 500`, `minSpeechMs: 250`) — never its defaults. SEND via
   whichever path section 5.1's DECISION resolves to, plus the arming window.
   **This is a usable product and most of the value.**
   PHASE 1 EXIT CRITERION: Zach's acoustic AEC A/B (section 4.1) plus a
   3 x "orca send" WAV dump from the `spikes/voice/` harness on REAL
   microphone hardware, confirming pre-roll onsets at ~420-510ms rather than
   ~0.
2. Streaming TTS off assistant deltas + speakable-content policy.
3. Porcupine wake-word path for stop/pause during playback.
4. Browser AEC + text-domain echo rejection -> duck-on-detect -> open channel.
5. LLM intent adjudicator, only if phase 1 heuristics prove insufficient.

## 11. Open questions for the finalizing orchestrator

- ~~Does GB10 currently expose an OpenAI-compatible
  `/v1/audio/transcriptions`, or something else? What model, what latency at
  3-10s utterances?~~ **ANSWERED — see section 6.** No OpenAI-compatible
  route; the sync lane of the existing `transcription` container,
  `large-v3-turbo`, 772ms p50 at 3.9-5.0s.
- Which SEND path — section 5.1 (a) keyword spotter vs (b) transcript
  vocabulary + phonetic matcher? Pending SPIKE 2b and SPIKE 3.
- WAV vs webm/opus for the browser upload? Pending SPIKE 2b.
- ~~Is `@ricky0123/vad-web` acceptable as a dependency, or should Silero be
  wired to onnxruntime-web directly? What is the bundle-size cost?~~
  **ANSWERED — see section 3.2.** vad-web 0.0.31 with every default
  overridden; bundle cost is 0.3% over direct Silero (5,560,445 vs 5,543,660 B
  gzip), both dominated by ort's wasm, so the choice is maintenance, not size.
- Porcupine requires a Picovoice access key (free tier). Acceptable, or is
  openWakeWord the right call despite being Python-first?
- Does browser AEC actually suppress our TTS adequately on Zach's real
  hardware, or is half-duplex the permanent answer? STILL OPEN, and SPIKE 1
  CANNOT ANSWER IT — a fake capture device has no acoustic loop. The
  10-minute human procedure and the >~15 dB / <~6 dB decision rule are now in
  section 4.1.

## 12. Changelog

**v0.2 -> v0.3** — SPIKE 1 (browser capture path, commit `2f774cd`,
`spikes/voice/`) folded in. Everything below is measured on Chromium
153.0.8010.12 / Chrome 149.0.7827.114, not estimated.

- Header: version bumped; status now records that SPIKE 1 and 2 are folded in,
  that 2b and 3 are pending, and that the AEC acoustic test is pending Zach.
- §2: `spikes/voice/` added as the reference implementation of the capture
  path; the "no audio-capture code in the tree" claim narrowed to the
  APPLICATION tree.
- §3.2: DECISION recorded — `@ricky0123/vad-web` 0.0.31 on onnxruntime-web
  1.29.0, Silero v5, with every default overridden (0.5/0.35,
  `redemptionMs: 600`, `preSpeechPadMs: 500`, `minSpeechMs: 250`); the
  defaults carry an explicit warning (EOS 1376ms, 2x budget); the `*Frames`
  API names corrected to `*Ms`; measured EOS/false-trigger/inference/init
  numbers added; bundle-size question settled at 0.3%.
- §3.2: the ~0.8s ASR floor reconciled with `minSpeechMs: 250` — the client
  keeps short segments, the DISPATCHER merges-or-pads them rather than
  dropping them.
- §4: `echoCancellation` / `noiseSuppression` / `autoGainControl` verified
  honoured in both directions (NS ~6.3 dB), `voiceIsolation` pinned
  explicitly — and an explicit statement that NONE of it is evidence about
  AEC efficacy, because the fake capture device bypasses the acoustic loop.
- §4.1: rung 1 (half-duplex) marked not-skippable on this evidence, and the
  human A/B procedure plus its >~15 dB / <~6 dB decision rule recorded.
- §6: SPIKE 1's "GB10 exposes no ASR" finding reconciled — true of the
  `ai.lab.ingbretsenhome.com` gateway, false as a conclusion; the sync lane on
  `192.168.1.77:8000` is the ASR path.
- §9: trap 1 gains the harness's non-secure-origin red banner; trap 5 rewritten
  — `AudioContext.sampleRate` is not the mic's rate (2.75625, not 3), with the
  measured resampler design; NEW trap 7 (`performance` is absent in
  `AudioWorkletGlobalScope`, and the silent-stop failure mode it causes) and
  NEW trap 8 (an unconnected worklet node is never pulled). §3's pipeline
  diagram no longer asserts a 48k mic rate for the same reason.
- §10: phase 1 names the chosen VAD settings and gains an exit criterion
  (Zach's acoustic A/B + a 3 x "orca send" WAV dump on real hardware).
- §11: the vad-web/bundle-size question marked ANSWERED; the AEC question
  re-pointed at §4.1's human procedure.

**v0.1 -> v0.2** — SPIKE 2 (GB10 ASR contract, commit `887d3cc` in
`/home/zach/transcription`) folded in. These correct the draft's own
assumptions so implementation does not inherit them.

- Header: version bumped, status now names which spikes are folded in and
  which are still pending.
- §2: the "reuse `ApiTokens` for the voice bearer" note now defers to §8.
- §3.2: silence hallucination REFUTED for this endpoint (0 non-empty in 173
  requests); VAD's rationale reordered around segmentation, bandwidth, GPU
  idle time and latency.
- §3.2: deleted the `no_speech_prob`/`avg_logprob`/`compression_ratio` filter
  — those fields do not exist here — and replaced it with a ~0.8s minimum
  segment floor plus the `elapsed_seconds` < ~50ms silence signal.
- §5.1: DECISION recorded — the two-word terminal-position prefix is unsafe as
  written ("Orca send." -> "or Cassand."); (a) spotter vs (b) empirical
  vocabulary + phonetic matcher, decided by SPIKE 2b/3 against a stated
  criterion, with the arming window kept either way.
- §6 PATH A: assumptions replaced by the measured contract of the existing
  sync lane — no new service, URL, multipart-only, field/size/duration caps,
  exact five-field response, no prompt biasing, webm/opus accepted, cold
  start.
- §6 PATH B: measured assessment — nothing installed, Parakeet-TDT is offline
  and so the wrong target, memory rather than speed is the constraint, ONNX
  before `nemo_toolkit`.
- §6.1: latency budget replaced with measured p50/p95 and concurrency data;
  total corrected from "< 1s" to ~1.1-1.5s; cold-start cliff and the 20s clip
  cap added.
- §8: AUTH corrected — no new token or scope for v1, `tts-config`'s global
  token flagged as a pre-existing exposure with a follow-up item; `ASRConfig`
  field list fixed (no `model`); GB10 reachability added as a deployment
  precondition.
- §9: trap 3 re-pointed from silence hallucination to short-fragment
  hallucination.
- §10: phase 1's SEND mechanism now defers to §5.1's pending decision rather
  than naming the refuted string match.
- §11: the ASR-endpoint question marked ANSWERED; SEND-path and upload-format
  questions added.
