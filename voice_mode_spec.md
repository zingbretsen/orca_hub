# Voice Mode — Design Spec (DRAFT, v0.5)

Status: DRAFT v0.5 — **phase 1 deployed (`d679c12`); phase 2 + 2b implemented
at `113fa91`; phase 2c (voice navigation + spoken composer control sequences)
next.**
Phase 1 commits: A `f23b5b8`, B `0080399`, C `4a28f2b`, D `ef9f87a`+`f101886`,
E `df935f1`, F `6f0e6d4`+`097806d`+`735b396`, integration fix `8d67708`, panel
shrink §8.1 DOM change — see §12. Phase 1 EXIT CRITERIA PENDING —
`spikes/voice/ACOUSTIC_TEST.md` Parts A and B have not been run; they gate
phases 3-4, not phase 2.
Phase 2/2b commits: A1 `a07de0d`+`202b870` (header nav -> live navigation),
A2 `f112b6e` (assistant text deltas from claude/codex/pi,
`OrcaHub.Backend.Deltas`, `Capabilities.streaming_deltas`), A3
`d82b2e3`+`2ba418c` (this spec's v0.5 contracts C1-C5), B1
`593fde6`+`8567169`+`908847d`+`528cde0`+`0e64e67` (AssistantStream bubble,
streaming TTS producer `assets/js/tts_stream.js`, the "Speak while streaming"
toggle, the spoken-mark race fix), B3 `9b56ea7`+`538ae5d`+`74f7541`
(`Voice.Session` `send_request`/`sent_ack`/`send_failed`/`send_direct`/
`composer`, the sticky `OrcaHubWeb.VoiceBarLive`, the hook rework, the in-page
panel removed, the §8.1/§8.2 corrections), scroll fix `f5413f9`, stage-C fix
`113fa91` (`QueueLive`'s `tts_stream_init` clause). Integration: 9/9 PASS on
the real page at `0e64e67`+`113fa91` — Claude + pi live streaming, nav survival
with one AudioContext and one join, spoken send through the composer with the
attachment line persisted, half-duplex 143/143 muted samples, the prefetch gate
holding 0/20 requests during a busy window, header 48/64/16 px at 390 px, and
retarget carrying the draft.
Phase 2 = §7.1-7.3 (C1-C3, streaming deltas + streaming TTS); phase 2b = §8.2
(C4, the global voice bar and the single send path); phase 2c = §13 (C5, voice
navigation + composer control sequences — design only). See §10 and the §10.5
map.
Author: orchestrator handoff, 2026-09-14; phase 2 contracts pinned 2026-09-18.
Owner: phases 1-2b landed; phase 2c per §10.

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
- `spikes/voice/kws/` — the SPIKE 3 harness, and the REFERENCE IMPLEMENTATION
  of section 5.2's keyword spotter: `kws.js`'s `OwwEngine` is ~120 lines
  wiring openWakeWord's three ONNX stages to the onnxruntime-web SPIKE 1
  already vendors (no new dependency), and it reuses SPIKE 1's `vendor/ort`
  and `capture-worklet.js` READ-ONLY over HTTP. `tools/serve.sh` on :8791.
  Same deliberate exclusion from `priv/static` and `package.json`.
- `spikes/voice/ACOUSTIC_TEST.md` — the two human-in-the-loop measurements the
  spec is blocked on (sections 4.1, 5.1, 5.2, 10), consolidated into one
  ~10-minute procedure with explicit PASS/FAIL thresholds.

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
**The procedure is `spikes/voice/ACOUSTIC_TEST.md` part A** (consolidated
there from SPIKE 1's README, together with section 5.1's real-voice check):

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

THE SAME NUMBER ALSO DECIDES SECTION 5.2. SPIKE 3 measured its keyword spotter
over continuous background speech at **16/16 at +10 dB SNR, 7/16 at 0 dB,
2/16 at -6 dB** — and the two spikes agree on where the cliff is: >15 dB
suppression is roughly where detection stays at 16/16, <6 dB is roughly where
it falls to 7/16 or worse. So this one measurement gates BOTH the open channel
and spoken STOP/PAUSE during playback.

## 5. Command classification — two separate paths

The key design insight: SEND is a transcript-domain decision; STOP/PAUSE is a
wake-word-domain decision. Serving both from one pipeline is what makes these
systems feel sluggish.

### 5.1 SEND (spoken while dictating, mic path healthy)

Cheap layer first — this is the v0.1 design; SPIKE 2 showed the EXACT-MATCH
form of it is unusable, and SPIKE 2b showed the rest of it survives once the
match is phonetic (see the DECISION below):

- TWO-WORD WAKE PREFIX: "orca send", "orca cancel". Bare "send" is a common
  English word; "orca send" is not. This alone kills most false positives.
- MATCH ONLY AT TERMINAL POSITION of a completed VAD segment. "Send the email
  to Bob" cannot fire because `send` is not last. This single heuristic does
  more work than any model.
- Strip command tokens from the draft before submitting.
- ARMING WINDOW: on SEND, show a ~1.5s countdown chip that any further speech
  cancels. Removes the entire "it sent too early" pain class. Default ON for
  SEND only; configurable.

DECISION (SPIKE 2b, measured) — **OPTION (b): KEEP SEND ON THE TRANSCRIPT
PATH, with a PHONETIC TAIL-MATCHER instead of an exact string match.** The
vocabulary stays `orca send` / `orca cancel` / `orca stop` / `orca pause`.
Specification in section 5.1.1.

**THIS REVERSES THE INTERIM RECOMMENDATION** made after SPIKE 2 and before
SPIKE 2b, which was to move SEND onto the keyword-spotter path (option (a)).
That recommendation was right about the transcripts and wrong about the
consequence. SPIKE 2 measured that the ASR does not render "orca send"
reliably, deterministically over 10 reps each:

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

SPIKE 2b confirmed that at scale and then beat it. Over **190 command
observations**, EXACT STRING MATCH TP = **0.0% on all four commands** —
"orca send" never once came back as itself. The surface forms it did come back
as, isolated: `or Cascend,` `Orcasend.` `Orc Ascend.` `or consent.` /
`Orca Paws.` `or Kapaz.` `work a pause.` / `Orca stopped.` `Orcastop.` /
`or cut cancel.` `or it could cancel.` — and note `or Kapaz` and `orca pause`
reduce to the SAME phonetic key `arkps`, which is the whole idea.

Argmax over the vocabulary of `max(Ratcliff-Obershelp ratio, the same ratio on
a phonetic key)`, computed on the LAST 1-3 tokens WITH SPACES REMOVED,
thresholded at **0.85**:

| phrase | exact | phon. key exact | ratio >= .85 | phon. ratio >= .85 | max of both |
|---|---|---|---|---|---|
| orca send | **0.0%** | 33.3% | 25.0% | **100.0%** | **100.0%** |
| orca cancel | **0.0%** | 82.6% | 78.3% | **95.7%** | **95.7%** |
| orca stop | **0.0%** | 83.3% | 79.2% | **95.8%** | **95.8%** |
| orca pause | **0.0%** | 95.8% | 37.5% | **95.8%** | **95.8%** |
| FP on 154 negatives | 0.0% | 0.0% | 0.0% | 0.0% | **0.0%** |

Overall: **96.8% TP (184/190), 0 wrong-intent, 0.0% FP (0/154)** — which MEETS
the v0.2 criterion (>= 95% TP, ~0% FP). The phonetic key does nearly all the
work; character ratio alone is 25-79%.

Threshold sweep (190 positives / 154 negatives):

| threshold | TP | wrong intent | FP |
|---|---|---|---|
| 0.80 | 97.9% | **2** | **2.6%** |
| **0.85** | **96.8%** | **0** | **0.0%** |
| 0.90 | 93.7% | 0 | 0.0% |

0.85 is the knee and the first threshold at which wrong-intent vanishes.

KEEP THE `orca` PREFIX. The tempting alternative is worse: `submit`,
`send message`, `stop now`, `hold on`, `never mind` transcribe **100%
literally at every placement** — and false-positive at **2.6-7.8%**, because
ordinary dictation ends in them ("I filled in the form and then I clicked
submit."). Those FPs are CORRECT TRANSCRIPTS; no matcher can undo them. The
wake-word prefix is what buys FP = 0.

WHY THIS BEATS OPTION (a), which was the interim recommendation:

- **Cost.** The matcher's marginal cost is ~zero — the transcript already
  exists and the comparison is string work. The spotter costs **25-37% of one
  core continuously** plus **3.0 MB gzip** on the wire (section 5.2). Same
  accuracy, vastly different cost.
- **The reason for wanting a spotter does not apply to SEND.** The spotter
  exists because the transcript path is DEGRADED DURING PLAYBACK (section
  5.2). SEND is spoken while dictating, with the mic open and the transcript
  path healthy. It never needed the spotter's one advantage.
- **No `orca send` spotter model exists** (SPIKE 3 §5): ~half a day of
  training per phrase, repeated for cancel/stop/pause. That is phase 1's whole
  budget spent on the cheaper half of the problem.
- **A spotter discards the terminal-position rule**, which does most of
  §5.1's work. It fires on phonetics with no notion of sentence position —
  SPIKE 3 measured it firing on "Orchestration". For STOP that is an
  annoyance; for SEND it means a half-formed draft goes to the model
  mid-sentence.
- **SEND must wait for the transcript anyway**, to strip the command tokens
  from the draft. The spotter's latency win is UI feedback only, not an actual
  send-sooner win.

SCALE AND CAVEAT: 26 phrases x 4 placements x 5-9 renderings = 688 clips,
**1690 ASR observations**; transcripts on this lane are FULLY DETERMINISTIC
(zero clips returned more than one distinct transcript), so reps measure
nothing and the budget went to renderings. But **it is ONE synthetic
Chatterbox voice** — no accent variation, no room, no breath, no mic AGC.
96.8%/0.0% is an UPPER BOUND on a real larynx, and `or Kapaz` / `or Cascend`
may be artifacts of this voice. **REAL-VOICE VALIDATION IS THE OPEN GAP** —
`spikes/voice/ACOUSTIC_TEST.md` part B, and it is a phase 1 exit criterion
(section 10).

The ARMING WINDOW stays. The phase-5 LLM adjudicator stays. **Option (a)
remains the documented fallback** if the real-voice check fails: train
`orca send` on openWakeWord (SPIKE 3 §5) and run it ALONGSIDE the transcript
matcher — fire on either, or on both within a window — not instead of it.
SPIKE 3 §8 has the sequencing if it ever comes to that.

### 5.1.1 Matcher specification for `OrcaHub.Voice.Intent`

The NORMATIVE REFERENCE is SPIKE 2b's `spike-asr/intent_ref.py`
(`/home/zach/transcription`, commit `4675905`), which runs standalone against
the committed transcripts. Reproduced verbatim:

```python
VOCAB = {"send": "orca send", "cancel": "orca cancel",
         "stop": "orca stop", "pause": "orca pause"}
THRESHOLD = 0.85
_PUNCT = re.compile(r"[^a-z0-9 ]+")
_FOLD = {"c":"k","q":"k","g":"k","x":"ks","z":"s","d":"t","b":"p","v":"f","j":"s","y":"i","w":""}
_DIGRAPH = (("ph","f"),("ck","k"),("sh","s"),("ch","k"),("th","t"),("qu","k"))

def phonetic(s):
    s = re.sub(r"[^a-z]", "", s.lower())
    for a, b in _DIGRAPH: s = s.replace(a, b)
    out = []
    for i, ch in enumerate(s):
        k = _FOLD.get(ch, ch)
        if k in "aeiou": k = "a" if i == 0 else ""   # keep only a leading vowel
        if k and (not out or out[-1] != k): out.append(k)   # collapse doubles
    return "".join(out)

def score(text, phrase):
    toks = _PUNCT.sub(" ", text.lower()).split()
    target = phrase.replace(" ", "")     # Whisper glues and splits words freely,
    target_p = phonetic(target)          # so compare with spaces removed
    best = 0.0
    for k in (1, 2, 3):
        if k > len(toks): break
        cand = "".join(toks[-k:])
        best = max(best,
                   difflib.SequenceMatcher(None, cand, target).ratio(),
                   difflib.SequenceMatcher(None, phonetic(cand), target_p).ratio())
    return best

def intent(text, vocab=VOCAB, threshold=THRESHOLD):
    best, best_s = None, 0.0
    for name, phrase in vocab.items():
        s = score(text, phrase)
        if s > best_s: best, best_s = name, s
    return (best, best_s) if best_s >= threshold else (None, best_s)
```

Five rules the port must not get wrong:

1. **Compare with SPACES REMOVED**, on both the candidate tail and the target.
   Whisper glues and splits words freely (`Orcasend.`, `Orc Ascend.`); a
   token-aligned comparison throws away the only stable signal.
2. **ARGMAX THEN THRESHOLD, never first-match.** Score every vocabulary entry,
   take the best, and only then apply 0.85. First-match is what produces the
   wrong-intent errors the 0.80 sweep row shows.
3. **`String.jaro_distance/2` IS NOT A DROP-IN.** Measured on this corpus its
   best zero-FP operating point is **0.90 at 92.6% TP**, against 0.85 at 96.8%
   for Ratcliff-Obershelp (`python3 intent_ref.py jaro` reproduces it). Either
   port `difflib.SequenceMatcher.ratio` semantics (Ratcliff-Obershelp) to
   Elixir, or keep the matcher client-side in JS. Do not silently substitute
   Jaro because it is in the standard library.
4. **0.85 IS TUNED ON THIS CORPUS.** Expose it as a config knob (an
   `ASRConfig`-style entry, section 8), not a module attribute.
5. **Strip the command tokens from the segment before it joins the draft.** A
   segment that is ENTIRELY the command contributes nothing to the draft and
   must be dropped, not appended.

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
broken. Use a dedicated in-browser keyword spotter: no server round trip,
works while ASR is gated.

DECISION (SPIKE 3, measured) — **openWakeWord v0.5.1 (Apache-2.0), threshold
0.5, run ONLY WHILE TTS IS PLAYING and GATED ON THE VAD.** Not always-on.

**PORCUPINE IS LICENCE-BLOCKED, before any technical question is reached.**

- Built-in keywords are **NOT keyless**. Proved three ways: empty key fails a
  client-side base64 check; a valid-base64 bogus key with a built-in keyword
  fails on the keyword file version; a bogus key with a `.ppn` the library
  accepts gets all the way INTO THE WASM and dies there on the AccessKey.
- Picovoice's FAQ, verbatim: *"there are no dedicated free or paid plans for
  personal or non-commercial use."* The Free Trial is one-time, non-renewing,
  enterprise-developer-only.
- Billing is per **monthly active browser instance**.
- The AccessKey **must ship to the browser** — `Porcupine.create()` takes it
  client-side. (Training can be proxied server-side; runtime cannot.)
- Separate real bug: `@picovoice/porcupine-web@4.0.1` bundles `.ppn` files
  reporting version `3.0.0` which its own `4.0.0` library rejects, so
  `BuiltInKeyword` is broken in 4.0.1 **even with a valid key**.

**EVERY PORCUPINE PERFORMANCE NUMBER IS DELIBERATELY UNMEASURED** — detection
rate, latency, CPU, false accepts. Never backfill one with an estimate; there
is no measurement behind it and Picovoice's own published claims were not
checkable here.

openWakeWord, MEASURED (hand-wired to the onnxruntime-web SPIKE 1 already
vendors, ~120 lines, NO NEW DEPENDENCY — the npm ports are all unversioned
0.1.x single-author packages):

| | measured |
|---|---|
| detection rate | **96/96** (3 keywords x 16 TTS renderings x isolated/after-a-carrier-sentence) at thresholds 0.3 / 0.5 / 0.7, **0 extra fires** |
| detection latency | fires **within one 80 ms chunk of the word ending** (audio-time p50 -80 ms, p95 <= +190 ms); live frame->callback p50 11.7 ms; **< ~200 ms end to end** |
| false accepts, noise | **0 in 15 min** at -50 / -40 / -26 dBFS; score ceiling <= 0.016 |
| false accepts, speech | **0 on 120 ordinary sentences**; 4 on a deliberately adversarial corpus, ALL on near-misses ("A Lexus", "the lexer", "Hey, Jarvis Cocker") |
| 2nd/3rd keyword | **+0.3 ms per frame** — melspectrogram + embedding backbone is shared, only the classifier head repeats |
| wire size, marginal over the VAD stack | 3,685,906 raw / **3,000,976 gzip** (Porcupine 4,349,647 / **1,827,197** — Porcupine is SMALLER gzipped; ONNX barely compresses) |
| offline | **fully**, runtime AND training |
| CPU per 80 ms frame | 9.9 ms back-to-back · 26.1 ms realtime-paced · live p50 11.6 / p95 39.3 ms -> **25-37% of one core continuously** |

THE CPU NUMBER IS WHY IT IS NOT ALWAYS-ON. A paced control (realtime pacing,
no audio graph) shows most of the cost is the **duty-cycle regime, not the
AudioWorklet**: working ~10 ms then idling ~70 ms never lets the core leave a
low power state. For scale, Silero VAD is ~11% duty in the same regime, so an
always-on spotter roughly TRIPLES voice mode's browser CPU. Mitigation, and
it is free: **STOP/PAUSE is only meaningful during playback**, so run the
spotter only while TTS is playing, gated on the VAD (which leads it and costs
a third as much). The duty cycle then collapses to the fraction of playback
time containing speech.

CUSTOM `orca stop` / `orca pause` MODELS MUST BE TRAINED — none exist. The
path is openWakeWord's synthetic-TTS training route (Apache-2.0, no key, no
vendor; only the classifier head trains, backbone frozen), ~half a day for a
first model plus an evaluation pass. GB10's Chatterbox can generate the
positives, **but its post-prompt hallucination must be trimmed to the first
voiced burst** — a render of "Alexa." came back 4.00 s long, 0.5 s of word and
3 s of unrelated speech-like audio, on every slug. See
`spikes/voice/kws/README.md` §5 and `make_kws_fixtures.py::first_utterance`.

Two implementation traps, both load-bearing and both silent when wrong (scores
collapse toward zero on real keywords rather than erroring):

1. The **melspectrogram model wants int16-magnitude floats**, not `[-1, 1]`.
2. The **480-sample overlap** (`160*3`) and the **`x/10 + 2` transform** are
   both required.

The spotter consumes the SAME 16 kHz stream as the VAD — one `getUserMedia`,
one worklet. Frame sizes differ (Silero 512 = 32 ms, openWakeWord 1280 =
80 ms) and 1280 is not a multiple of 512, so emit **256-sample frames** from
the worklet and let each consumer accumulate. Convert to int16 once, on the
main thread.

**§5.2 IS UNVALIDATED UNTIL ZACH RUNS THE ACOUSTIC PROCEDURE.** SPIKE 3
measured the keyword spoken OVER continuous speech at **16/16 at +10 dB SNR,
7/16 at 0 dB, 2/16 at -6 dB** — so the spotter is not the risk, the acoustic
path is. Whether this works during playback is set entirely by how much of our
own TTS the browser's AEC removes, which is SPIKE 1's one unanswered question,
and the cliff sits almost exactly at section 4.1's >15 dB / <6 dB decision
points. The procedure is `spikes/voice/ACOUSTIC_TEST.md` (part A). Until it
returns a number, do not build this: **half-duplex (section 4.1 rung 1) is
phase 1 regardless.**

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
  IS NOT AVAILABLE AS SHIPPED — do not design around it. (This is what forces
  the section 5.1 matcher; see the biasing note below for what it would take
  to change.)
- Errors are `{"detail": "<string>"}` with no machine-readable code — switch
  on HTTP STATUS, not on the body.
- `200` with `text: ""` is the NORMAL non-speech result, NOT an error.
- ENCODING — DECISION (SPIKE 2b): **there is NO speed argument either way.
  Send 16kHz WAV from the worklet (least client code) or MediaRecorder output,
  implementer's choice.** v0.2's "webm/opus was FASTER than WAV (596ms vs
  930ms)" DID NOT REPLICATE — those were TWO DIFFERENT CLIPS (1.40s vs 5.92s),
  both from SPIKE 2's own `latency.json`. A controlled A/B on IDENTICAL audio
  (4 encodings x 5 clips x 10 reps) found non-server overhead **flat at
  88-126ms across a 95x payload range**, biggest within-clip spread 2.8%,
  server `elapsed_seconds` differing by <= 3ms. Accuracy: **53/56 correct
  intents on WAV vs 52/56 on opus** — opus perturbs 25-46% of transcripts
  ("Orca cancel…" -> "or to cancel…") but the section 5.1.1 matcher absorbs it.
  webm/opus uploads are still accepted directly, so posting MediaRecorder
  output as-is remains valid; it is just not faster.
- `initial_prompt` BIASING ON THE SYNC LANE IS STILL UNMEASURED. It is
  silently ignored today (above), and testing it needs a ~5-line change to
  `api.py` in the `transcription` repo. Worth doing: SPIKE 3 recommends it
  independently, it would likely target "or Cassand." directly, and it might
  make section 5.1.1's phonetic key unnecessary. **Keep the matcher
  regardless** — biasing changes the transcript distribution, it does not make
  exact matching safe.
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

ASR AND TTS CONTEND FOR THE GB10 GPU (SPIKE 2b). Isolated commands measure
**541ms p50 with TTS idle vs 842ms p50 while TTS is synthesising — ~1.55x**.
Voice mode speaks and listens on the same box, so this is the normal case, not
an edge case.

Budget for a typical 1.5-5s utterance:

| Stage | Measured / target |
|---|---|
| VAD endpointing | 500-700ms **(dominates — main tuning knob)** |
| transport (LAN) | ~20ms |
| ASR (sync lane, warm, TTS idle) | 570-800ms |
| ASR (sync lane, warm, **TTS synthesising**) | **~850ms** |
| intent (section 5.1.1 matcher) | ~0ms |
| **total** | **~1.1-1.5s quiet, ~1.4-1.8s while speaking and listening** |

That is the honest number. v0.1's "< 1s" was not achievable against this
endpoint and must not be held as a target. Budget the ~850ms figure whenever
playback and capture overlap; section 7 has the mitigation.

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

PAUSE THE TTS PREFETCH PIPELINE WHILE THE MIC IS HOT. ASR and TTS share the
GB10 GPU, and SPIKE 2b measured ASR going from 541ms to 842ms p50 (~1.55x)
while TTS is synthesising (section 6.1). The existing prefetch is abortable
(`ttsFetchAudio` / `ttsRequestChunk`), so this is a scheduling change, not new
machinery: do not speculatively synthesise chunks the user is not about to
hear while a segment is in flight to ASR.

The real product problem is WHAT NOT TO SPEAK. The feed is mostly tool calls,
diffs, and file lists. `ttsCleanText` handles the lexical layer but not "do not
read 400 lines of diff aloud". Policy: speak assistant PROSE blocks only;
render tool activity as short earcons or a one-phrase announcement ("running
tests"), never the payload.

### 7.1 Delta stream contract (C1)

**Assistant delta stream (server side; phase 2).** NORMATIVE.

The SessionRunner broadcasts, on the existing `"session:<id>"` PubSub topic and
WITHOUT persisting, these tuples (maps use string keys, same as persisted
events):

- `{:assistant_stream_start, %{"stream_id" => id}}` — once per assistant API
  message.
- `{:assistant_block_start, %{"stream_id" => id, "block_index" => i, "type" => "text" | "tool_use" | "thinking", "name" => tool_name_or_nil}}`
- `{:assistant_delta, %{"stream_id" => id, "block_index" => i, "text" => chunk}}`
  — TEXT blocks only. No tool-input JSON deltas, no thinking deltas.
- `{:assistant_block_stop, %{"stream_id" => id, "block_index" => i}}`
- `{:assistant_stream_stop, %{"stream_id" => id}}`

`stream_id` MUST equal the `message.id` carried by the persisted `assistant`
event that follows for the same message, so the client can correlate the live
bubble with the final render. Claude: the API message id from `message_start`.
Codex/pi: the normalizer mints one UUID per assistant message and stamps it into
the normalized `assistant` event's `message.id` as well. Deltas are best-effort:
a client that missed them (page loaded mid-turn) simply sees the persisted
message. All three backends emit this shape; a backend that cannot stream emits
nothing (no fake deltas).

### 7.2 Client streaming events (C2)

**Client streaming events (LiveView -> browser; phase 2).** NORMATIVE.

`SessionLive.Show` forwards §7.1 as
`push_event(socket, "assistant-stream", %{op: "start"|"block_start"|"delta"|"block_stop"|"stop", stream_id, block_index, text, block_type, name})`
(nil fields omitted). A single `AssistantStream` hook on the feed container owns
an in-progress bubble `#stream-<stream_id>` (plain text, escaped,
`white-space: pre-wrap`; one `<div>` per text block; a one-line `"<name>…"` chip
per tool_use block), appends deltas, and removes the bubble on `stop` after the
persisted message has rendered (the LiveView also assigns nothing per delta — no
growing string assigns).

TTS consumes the SAME `assistant-stream` events inside `TTSMethods` (a `window`
CustomEvent `orca:assistant-stream` re-dispatched by the hook, so QueueLive and
any future host can listen without coupling to the feed DOM).

### 7.3 Streaming TTS producer (C3)

**Streaming TTS producer (phase 2).** NORMATIVE.

A sentence accumulator in `TTSMethods`, enabled by a "Speak while streaming"
toggle next to the existing autoplay toggle (localStorage key
`orca:tts-stream`, off by default). Per `stream_id`:

- buffer text deltas; track fence state (```` ``` ````/`~~~`) and never emit text
  inside an open fence;
- release a chunk when a sentence boundary is seen (reuse
  `ttsSplitIntoChunks`' boundary rules) AND the buffered sentence is >= 40
  chars, or when the buffer exceeds 240 chars at a clause boundary, or 1500 ms
  have elapsed since the last release with >= 20 chars buffered;
- flush the remainder at `block_stop`.

Each released chunk goes through `ttsCleanText` and is appended to the existing
chunk queue for this `stream_id` (`activeId = stream_id`; on `stop` the queue is
re-keyed to the persisted message id so the per-message controls keep working).

A tool_use `block_start` enqueues ONE short announcement ("running `<name>`" via
a small name -> phrase map, default "running a tool") and never the payload.

A message spoken while streaming is marked spoken so the existing end-of-turn
`tts-autoplay` does NOT read it again.

**MEASURED NUANCE (stage-C integration, `113fa91`).** The mark has to be set on
the message's FIRST released chunk, not at the `stop` re-key: the end-of-turn
`tts-autoplay` push can arrive before the persisted message renders (measured
stream stop 2038 ms, message in the DOM 2079 ms, autoplay ~2100 ms), so a
suppression that waits for that render loses the race and reads the whole
message a second time. Relatedly, the accumulator's `flush()` at `stop` can
enqueue the tail sentence a few ms AFTER the persisted node has rendered
(measured ~3 ms) — that is the same read continuing, not a re-read, because the
queue is still the streamed one and is only then re-keyed onto the persisted
id. So the invariant to assert is "no `ttsPlayById` for that message, and no
duplicated text", NOT literally zero enqueues after the render.

While a voice segment is in flight to ASR (the Voice hook dispatches
`orca:voice-asr-busy {busy: bool}` on `window`), the prefetch pipeline does not
start NEW synthesis requests (the current chunk finishes; the next fetch waits)
— §7's GPU-contention rule.

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
- DEPLOYMENT PRECONDITION: the ASR call runs inside the `VoiceChannel`
  process (`Task.start` in `voice_channel.ex`, warm-up ~line 161 and dispatch
  ~line 217), i.e. on whichever node terminates the browser's websocket — so
  in prod that is the k3s `orca-hub` pod and nothing else, and IT is what must
  reach the ASR lane from the pod network. The other nodes are moot:
  `orca-agent-discord`/`orca-agent-dell`/`mini`/`gb10` run in agent mode and
  404 every page route via `:agent_mode_gate` (`lib/orca_hub_web/endpoint.ex`
  lines 14-28), so a browser can never hold a voice websocket to them, and the
  LAN instances on port 4001 are excluded a second time by `getUserMedia`'s
  secure-origin requirement (§9 trap 1) — leaving only the pod (via
  `https://orca.lab.ingbretsenhome.com`) plus a dev server on localhost. The
  target is a config knob (`asr_provider` row > `ASR_URL` env > the
  `http://192.168.1.77:8000` default), so an FQDN is fine as long as it
  resolves from the hub pod; `ai.lab.ingbretsenhome.com` is NOT such an FQDN,
  since the ai-gateway proxies only TTS (§6).
  Reachability from the pod: VERIFIED 2026-09-17 (read-only check from inside
  `orca-hub-687d7b8b49-qbbw5`). `curl http://192.168.1.77:8000/healthz` returns
  200 in ~5 ms with `lanes.sync.state: ready` and `cuda.available: true`; no
  NetworkPolicy in `lab` selects `orca-hub`, so its egress is unrestricted.
  Two names already exist in `~/homelab/k3s/apps/gb10.yaml` and both work as an
  `ASR_URL`/`asr_provider` url: in-cluster
  `http://whisperx-external.lab.svc.cluster.local:8000` (Service + Endpoints ->
  192.168.1.77:8000) and LAN-wide `https://transcription.lab.ingbretsenhome.com`
  (Traefik Ingress, deliberately without Authelia, so a localhost dev server can
  use it too); the IP default works as well. The agent pods
  (`orca-agent-dell`/`orca-agent-discord`) carry egress NetworkPolicies that do
  NOT allow 192.168.1.77 — moot for voice, since agent nodes never terminate a
  browser websocket, but relevant if anything else ever calls the lane from one.
  Note `/healthz` returns 200 even when `gpu_ready` is false; voice warm-up is a
  real transcription POST rather than a healthz probe, so it is unaffected.
  TRAP: `gb10.lab.ingbretsenhome.com` (and
  `promaxgb10-654f.lab.ingbretsenhome.com`) resolve to 192.168.1.177, the debian
  Traefik wildcard — NOT the GB10; port 8000 there is connection-refused. Do not
  use them.
- SENDING: `Cluster.send_message(node, session_id, text, :queue)`. Default
  `:queue`, matching the `TriggerExecutor` precedent — "send" must not cancel
  an in-flight turn.
- OWNERSHIP: a single-voice-owner claim per session via
  `SessionViewersRegistry`, so two open tabs do not both capture.
- NODE ROUTING: never silently re-route to a different node if the session's
  assigned `runner_node` is unavailable — surface the error. See
  `.context/clustering.md`.

### 8.1 VoiceChannel wire contract (phase 1)

> **Read §8.2 with this section.** Phase 2b (C4) moves the markup below out of
> `SessionLive.Show` and into `OrcaHubWeb.VoiceBarLive`, and replaces the
> server-side delivery of `"orca send"` with a `send_request` the client
> executes against the real composer form. Everything else here — the OVS1
> frame, the join semantics, every phase-1 event, the `[data-voice-*]`
> selectors — survives verbatim. §8.2 lists exactly what stays and what moves.

This contract is fixed and is NORMATIVE for the VoiceChannel (slice D), the
browser hook (slice E) and the panel renderer (slice F — `SessionLive.Show` in
phase 1, `VoiceBarLive` from phase 2b, see §8.2). Any change must be agreed
across all three before any of them deviates.

#### Transport

- Socket: the existing `OrcaHubWeb.UserSocket` at `/terminal_socket` (no new socket; reuse `window.__terminalSocket` exactly like `assets/js/terminal_hook.js` does).
- Channel topic: `"voice:" <> session_id` (no client_ref suffix — there must be exactly ONE voice owner per session; a second join for the same session from any tab is REJECTED, see join errors).
- Internal PubSub, if any is ever needed by the channel, uses the prefix `"voice_state:"` — NEVER `"voice:"` (Phoenix subscribes the channel process to its own topic name; same-name PubSub double-delivers — see `.context/terminals.md`).
- Audio goes as Phoenix BINARY payloads: client `channel.push("segment", arrayBuffer)`; server `handle_in("segment", {:binary, bin}, socket)`. No base64.

#### Binary segment frame (client -> server, event `"segment"`)

Little-endian header, 20 bytes, then raw 16 kHz mono int16 PCM:

    bytes 0-3   magic  "OVS1"
    bytes 4-7   seq            u32   monotonically increasing per channel, from 1
    bytes 8-11  start_sample   u32   absolute 16 kHz sample index of the first PCM sample (from the worklet's absolute index)
    bytes 12-15 sample_count   u32   number of int16 samples that follow
    bytes 16-19 flags          u32   bit0 = forced_end (client split the segment because it approached 18 s); bit1 = padded (client extended a sub-0.8 s VAD segment from its ring buffer); other bits 0

The client ships RAW PCM; the SERVER wraps it in a 44-byte WAV header for the multipart upload (decision: one capture path aligned to VAD boundaries, minimal JS, and server-side merge/pad logic needs PCM anyway). The segment the client ships INCLUDES vad-web's preSpeechPad (500 ms) and redemption tail (~600 ms). The client enforces: sample_count <= 18 s * 16000 (force-end + bit0 above), and pads any completed segment shorter than 0.8 s from its ring buffer (bit1) — never synthesizes silence, never discards.

#### Client -> server JSON events

- `"speech_start"` `{}` — VAD onset. Cancels an open arming window IMMEDIATELY (the arming chip must die on speech ONSET, not 600 ms later when the segment completes).
- `"mic"` `{muted: bool, reason: "tts" | "user"}` — the client's half-duplex state; the server mirrors it in `state.muted` and DROPS any `"segment"` that arrives while muted (defensive).
- `"send_now"` `{}` — sends the current draft immediately, no arming window. No-op on an empty draft. Still served, but no longer pushed by the panel: the composer's own Send button submits through `SessionLive.Show`'s `send_message` (also `:queue`) instead.
- `"cancel"` `{}` — clears the draft and any arming window.
- `"draft_edit"` `{text: string}` — the user edited the draft by hand in the composer textarea (see the DOM contract below); server replaces its draft with `text`. Also used to SEED the server with whatever was already typed into the composer when voice mode was turned on.
- `"retry_warmup"` `{}` — re-fire the ASR warm-up ping after an error.

#### Join

- `channel.join()` reply `ok`: `{state: <snapshot>}` (see below). Joining IS arming: the server fires the ASR warm-up ping immediately and `state.status` starts at `"warming"`.
- reply `error`: `{reason: "not_found" | "voice_owned" | "node_unavailable" | "archived"}`. `voice_owned` = another channel process already holds the voice claim for this session in `OrcaHub.SessionViewersRegistry` (value `%{voice: true}`); `node_unavailable` = the session's `runner_node` is set but not connected — the client shows it, NEVER re-routes.

#### Server -> client events

- `"state"` — the FULL snapshot, pushed after every change. Shape:

      {
        status: "warming" | "listening" | "transcribing" | "arming" | "sending" | "error",
        draft: string,                    // the accumulated draft, lines joined by " "
        muted: bool,                      // mirror of the last "mic" event
        warm: bool,                       // warm-up ping succeeded at least once
        pending: int,                     // segments in flight to ASR
        arming_ms: int | null,            // ms remaining in the SEND arming window (null when not arming); client renders the countdown chip from this
        error: string | null              // human-readable; non-null forces status "error" until retry_warmup or the next successful call
      }

  `status` precedence: error > sending > arming > transcribing > warming > listening. `muted` is orthogonal (rendered as the half-duplex indicator, whatever the status).
- `"segment_result"` — one per segment, for the per-utterance log: `{seq, text, intent: "send"|"cancel"|"stop"|"pause"|null, score: float, elapsed_seconds: float, duration: float, action: "appended"|"dropped_silence"|"dropped_command_only"|"dropped_short"|"dropped_muted"|"send"|"cancel"|"ignored_stop_pause"|"error", detail: string|null}`.
- `"sent"` — `{text: string}` after `Cluster.send_message(..., :queue)` accepted the draft; server clears the draft and pushes a fresh `"state"` right after.

#### Server-side semantics (slice D)

- Warm-up: on join, `Voice.ASR.warmup/1` with `warmup_timeout_ms` (cold start up to 35 s). Success -> `warm: true`, status `listening`. Failure -> `error` with a readable message ("ASR unreachable at <url>: <reason>").
- Per segment: verify magic/lengths (bad frame -> `segment_result` action `error`, no crash); if `muted` -> `dropped_muted`; if sample_count > 20 s*16000 -> `error` "segment over 20 s cap" (never dispatch); if sample_count < 0.8 s*16000 -> hold it up to 1500 ms and MERGE (concatenate PCM) with the next segment if one arrives, else dispatch it anyway if flag bit1 (client already padded) or drop it as `dropped_short` if not. Dispatch = `Voice.ASR.transcribe/2` in a `Task` (never block the channel process); results are applied in `seq` order (buffer out-of-order completions — the ASR lane is FIFO but be defensive).
- On result: `Voice.ASR.silence?/1` (elapsed_seconds < 0.05 or blank text) -> `dropped_silence`. Else `Voice.Intent.intent(text, threshold: cfg.threshold)`:
    - `nil` -> append text to the draft (`appended`).
    - `:send` -> `Voice.Intent.strip_command/2`; append the remainder if non-empty (else `dropped_command_only`), then open the ARMING WINDOW (1500 ms). If the draft is empty, do NOT arm (`segment_result` action `send`, detail "empty draft").
    - `:cancel` -> clear draft + arming (`cancel`).
    - `:stop` / `:pause` -> strip the command from the segment, append the remainder if any, and take no other action (`ignored_stop_pause`). Phase 3 owns these; in half-duplex the mic is muted during playback so they are unreachable by design.
- Arming window expiry -> status `sending`; `Cluster.send_message(runner_node, session_id, draft, :queue)` — `:queue`, never `:interrupt`. `:ok`/`{:queued, _}` -> `"sent"`, clear draft. Any error -> `error` with `Cluster.node_unavailable_message/1` when applicable (see `handle_delivery_result/3` in `session_live/show.ex:285` for the exact result shapes).
- Arming is cancelled by `speech_start`, `cancel`, `draft_edit`, and by any appended non-command segment.
- Arming is also SKIPPED — never opened — when speech resumed between the command segment's RECEIPT and its transcript landing: the segment only closes 600 ms after speech offset (VAD redemption) and its ASR round trip costs another ~0.5 s, so the window would otherwise open ~1.1 s after the user stopped talking and a `speech_start` in that gap would be forgotten. The stripped remainder is appended as usual and the `segment_result` goes out with action `send`, detail "arming skipped: speech resumed"; state stays `listening`. Only onsets strictly AFTER receipt count — the one that started the command utterance itself arrives before it. (Speech resuming within the first 600 ms merges into the same segment, so no command is detected at all.) Manual `send_now` is unaffected. Measured on the real page during phase 1 integration; fixed in `8d67708`.
- Ownership: on join, `Registry.lookup(OrcaHub.SessionViewersRegistry, session_id)` — if any entry's value has `voice: true`, reply `voice_owned`; else `Registry.register(OrcaHub.SessionViewersRegistry, session_id, %{voice: true})` (the registry is `keys: :duplicate`; `SessionLive.Show` registers `%{}` there and its `abandoned_cleanup` only checks for emptiness, so an extra `%{voice: true}` entry is harmless). The registry is per-node; the claim covers the node that terminates the websocket, which is the node that served the page. Note that in the moduledoc.
- The channel never re-routes: it resolves the session via `HubRPC.get_session/1`, its node via `Cluster.runner_node_for/1`, and if `Cluster.node_available?/1` is false it rejects the join.

#### DOM contract (slice F renders, slice E's hook drives)

`SessionLive.Show` renders, when `@voice_mode` is true:

    <div id="voice-panel" phx-hook="Voice" phx-update="ignore"
         data-session-id={@session.id} data-voice-draft-target="#prompt-input">
      <div data-voice-banner class="hidden">   <!-- red non-secure-origin banner text, hook unhides -->
      <div data-voice-error class="peer hidden"></div>  <!-- hook writes error text, unhides -->
      <button data-voice-action="retry" class="hidden peer-[:not(.hidden)]:inline-flex">Retry warm-up</button>
      <details data-voice-log-details>         <!-- CLOSED on load; hook restores/persists `open` in localStorage "orca:voice:log-open" -->
        <summary>
          <span data-voice-status></span>      <!-- hook writes status text -->
          <span data-voice-mic></span>         <!-- hook writes "mic: listening" / "mic muted (TTS playing)" -->
          <div data-voice-arming class="hidden"><span data-voice-arming-ms></span></div>  <!-- countdown chip -->
          events                               <!-- the disclosure affordance -->
        </summary>
        <ol data-voice-log></ol>               <!-- hook appends one <li> per segment_result -->
      </details>
      <button data-voice-action="start" class="hidden">Start listening</button>  <!-- fallback gesture if AudioContext stays suspended -->
    </div>

**The draft sink is the page's NORMAL composer textarea, not an element of the
panel's own.** `data-voice-draft-target` is a selector for it (`#prompt-input`);
there is no `data-voice-draft`, no "Send now" and no "Clear" button, because the
composer's Send button and a select-all-delete already do those two jobs and the
second textarea cost roughly half a 390 px viewport. The hook therefore writes
OUTSIDE its own element, which imposes three rules:

- `#prompt-input` belongs to the `Autocomplete` hook inside a
  `phx-update="ignore"` wrapper, so every write must be followed by a bubbling
  `input` event — a bare `.value =` skips Autocomplete's autoresize and leaves a
  one-row box holding several rows of text. The hook guards that synthetic event
  so it is not echoed straight back as a `draft_edit`.
- The composer's `input` (debounced 300 ms) still pushes `draft_edit`, exactly as
  the old draft textarea did. Text already typed into the composer when voice
  mode is turned on is pushed as a `draft_edit` seed on join, so the first
  `"state"` snapshot cannot wipe it.
- **An empty `state.draft` never empties a non-empty composer.** Clearing is
  explicit only: the `"sent"` event, a `segment_result` with action `cancel`, and
  the LiveView's `clear-prompt` push (which also pushes `"cancel"` so the server
  draft cannot be re-sent). That ordering is what keeps a stale snapshot from
  destroying typed text.

`"orca send"` is unchanged: the SERVER delivers the draft with
`Cluster.send_message(..., :queue)` on arming expiry and pushes `"sent"`. The
client does NOT submit the composer form for it (that would double-send); it
only clears the box. `"send_now"` remains a valid client->server event but has no
button any more.

The per-segment log is collapsed behind a native `<details>`, CLOSED on load. The
panel is `phx-update="ignore"`, so a LiveView assign could not drive a toggle
inside it; the disclosure is CSS-only and the hook merely restores/persists the
choice in `localStorage`.

The LiveView button that toggles `@voice_mode` (`phx-click="toggle_voice"`) is the user gesture (sticky activation) — the hook arms in `mounted()`; if `ctx.state` is still `suspended` after `resume()`, it unhides the `start` button and arms on that click instead. Leaving voice mode = the LiveView un-rendering the panel -> hook `destroyed()` tears everything down (channel leave, tracks stopped, AudioContext closed, and the composer's `input` listener removed — the composer outlives the hook).

Half-duplex: `TTSMethods` (app.js) dispatches `window.dispatchEvent(new CustomEvent("orca:tts-state", {detail: {playing: bool}}))` whenever `this.playing` changes (ttsStart/ttsPause/ttsResumeOrStart/ttsStop). The Voice hook listens, pauses the VAD + drops frames while playing, and pushes `"mic"` `{muted, reason: "tts"}`. Slice F owns that tiny additive emit in app.js; slice E owns the listener.

### 8.2 Global voice bar and single send path (C4)

NORMATIVE for phase 2b. This section RESOLVES **ORCAHUB3-88** (voice is
per-session and dies on navigation) and **ORCAHUB3-86** (the spoken send path
bypasses the composer's upload/attachment handling), and it SUPERSEDES phase 1's
`SessionLive.Show`-only voice panel: after 2b, `SessionLive.Show` renders no
voice toggle and no voice panel at all.

What §8.1 keeps and what moves:

- **Stays, unchanged and still normative**: the OVS1 binary segment frame, the
  join semantics and join errors, every phase-1 client -> server and server ->
  client event, the single-voice-owner claim, the no-re-routing rule, the
  half-duplex `orca:tts-state` contract, and the `[data-voice-*]` DOM
  contract — `#voice-panel`, `data-voice-banner`, `data-voice-error`,
  `data-voice-action="retry"|"start"`, `data-voice-log-details`,
  `data-voice-status`, `data-voice-mic`, `data-voice-arming`,
  `data-voice-arming-ms`, `data-voice-log`.

  **CORRECTION, written after implementing 2b (`538ae5d`)** — this list
  originally also promised `data-voice-draft-target`, and that one could not
  survive:

  - **`data-voice-draft-target` is GONE.** It was the server DECLARING the
    sink, which only works while the sink is one fixed element on one page.
    The 2b sink rule is a client-side FUNCTION of the current target
    (`form[data-voice-composer-for="<target>"] textarea`, else
    `[data-voice-bar-draft]`), re-evaluated on every write, so there is
    nothing for the server to declare. `_draftSelector` became `_draftEl()`.
  - **`data-session-id` on the panel became `data-target-session-id`**, and it
    is now the single source of truth for the target: the hook never sets the
    target directly, it pushes `voice-target` at `VoiceBarLive` and reacts to
    the re-render, so the picker and the channel cannot diverge.
  - **`phx-update="ignore"` moved off the panel root onto an inner
    `#voice-strip`.** The root has to be patchable now — it carries
    `data-target-session-id`, which changes. Everything the hook writes is
    still inside an ignored subtree; nothing else about the contract moves.
  - **Two new selectors**: `data-voice-action="toggle"` (the mic button — the
    autoplay gesture that `toggle_voice` used to be) and
    `[data-voice-bar-draft]` (the bar's own draft box).
  - **Element lookups are lazy.** The strip only exists while voice mode is
    on, so `mounted()` cannot cache `_els`; every writer resolves its element
    per call and tolerates a null.
- **Carries over from §8.1's v0.4.2 rewrite, named explicitly because 2b is
  exactly where each would silently break**:
  - **The mic button is ALWAYS rendered and is a real click target** — it is the
    autoplay-policy gesture (sticky activation) that `toggle_voice` was in phase
    1. The hook still arms in `mounted()` and still unhides
    `data-voice-action="start"` if `ctx.state` is `suspended` after `resume()`.
    A bar that renders its mic only once voice is already on cannot be turned
    on.
  - **Every write to a composer textarea is followed by a bubbling synthetic
    `input` event**, guarded so it is not echoed back as a `draft_edit`. A bare
    `.value =` skips `Autocomplete`'s autoresize and leaves a one-row box
    holding several rows of text. This now applies to whichever textarea the
    draft sink rule selected, not just `#prompt-input`.
  - **The never-clobber seeding rules**: pre-typed text is pushed as a
    `draft_edit` seed at join (and, per the retarget rule below, at every
    re-join), and an empty `state.draft` NEVER empties a non-empty composer.
    Clearing stays explicit — `"sent"`, a `cancel` `segment_result`, or
    `clear-prompt`. Retarget makes joins routine rather than once-per-page, so
    this is load-bearing in 2b in a way it was not in phase 1.
  - **The one-line strip and the `<details>` log** (`data-voice-log-details`,
    CLOSED on load, `open` persisted in `localStorage` under
    `orca:voice:log-open`, CSS-only because the panel is
    `phx-update="ignore"`).
- **MOBILE CONSTRAINT (a hard budget, not a preference)**: the bar's IDLE state
  is ONE icon button sitting in the EXISTING header row — it adds no row and no
  vertical pixels when voice is off. When armed, the status/mic/error/arming
  strip must cost no more than phase 1's **16 px** on a 390 px viewport. Phase 1
  spent a cycle getting the panel from 167 px down to 16 px (§12, v0.4.1 ->
  v0.4.2) and `29c9778` then deliberately reclaimed the session header's budget
  down to ~97 px on a phone; a global bar is on EVERY page, so regressing that
  costs more than the phase-1 panel did. Measure it (`getBoundingClientRect`,
  not a screenshot) at 390x844 before calling 2b done. The target-session picker
  and the bar's own draft box are part of this budget: the picker is a control
  in the same row, and the draft box is shown ONLY when the page has no composer
  for the target.

  **MEASURED at 390x844 in Chromium 153 (`538ae5d`), the budget met:** header
  **48.00 px idle before and after** the bar exists (reconstructed in-page by
  restoring the old header class list and removing the bar, so it is the same
  CSS and the same content), and **64.00 px armed — a strip of exactly
  16.00 px**. Three things were needed to land on 16 and each is load-bearing:

  - the header is `flex-wrap` with **`gap-y-0`** (`gap-x-2` is the old
    `gap-2`, since nothing else in that row wraps). The strip is a
    `basis-full` item; an 8 px row gap would have spent half the budget on
    the wrap itself.
  - the picker is height-clamped (`h-4 min-h-0 py-0 … text-[11px]`). A stock
    daisyUI `select-xs` is **24 px** and blows the budget on its own.
  - the bar's draft box is hidden until it holds text. Left visible whenever
    a page has no composer it is **37 px**, which took `/projects` armed to
    53 px before it was fixed.

  Two `display: contents` wrappers are what let a nested LiveView put one item
  in the header row and another on a wrapped line below it: both the
  `live_render` container (`container: {:div, class: "contents"}`) and the
  template root are `contents`, so the real children are flex items of the
  header itself.
- **Moves**: the markup carrying those selectors moves OUT of
  `session_live/show.html.heex` and INTO `OrcaHubWeb.VoiceBarLive`, together with
  the `toggle_voice` gesture. §8.1's "slice F renders" now means VoiceBarLive
  renders.
- **Changes**: the draft sink is no longer hard-wired to one page's
  `#prompt-input` (see the draft sink rule below), and the SERVER no longer
  delivers the draft by itself (see SINGLE SEND PATH below), which is the one
  place 2b contradicts §8.1's phase-1 text.

The contract:

- `OrcaHubWeb.VoiceBarLive` is rendered in the app header via
  `live_render(@socket, OrcaHubWeb.VoiceBarLive, id: "voice-bar", sticky: true,
  container: {:div, class: "contents"})` (same mechanism as the idle badge; the
  `container` is the correction above). It renders the mic button, a compact
  status/mic/error/arming strip, a target-session picker, and a small draft box
  that is shown ONLY when the current page has no composer for the target
  session. It carries `phx-hook="Voice"` on its root (`id="voice-panel"` keeps
  the existing hook selectors working). `SessionLive.Show` no longer renders a
  voice toggle or panel.
- All in-app navigation is LIVE navigation (`<.link navigate>` / `JS.navigate` /
  `push_navigate`), never a plain `<a href>` to an internal route, so the sticky
  bar (and the hook's mic/AudioContext/channel) survive page changes. External
  links and downloads stay anchors.
- **Target session**: the bar tracks `target_session_id`. When the user
  navigates to `/sessions/:id`, the target auto-follows that session (the bar
  listens for LiveView navigation: `SessionLive.Show` pushes
  `voice-target {session_id}` on mount and `voice-target {session_id: null}` on
  terminate; the bar's hook also reads `document.body.dataset.voiceComposerFor`,
  set by the session page's composer form). Off a session page the target
  persists as the last one; the picker lists recent non-archived sessions.

  **CORRECTIONS from implementing it (`538ae5d`):**

  - **There is no `terminate` push.** `Phoenix.LiveView.terminate/2` cannot
    `push_event`. The signal that a page stopped being a session page is the
    DISAPPEARANCE of its composer — `document.body.dataset.voiceComposerFor`,
    set and deleted by the feed hook's own mount/destroy (`593fde6`), watched
    with a `MutationObserver` on that one attribute.
  - **Auto-follow fires on NAVIGATION, not on every sync.** The hook's page
    sync runs on each re-render too, and an unconditional push would snap the
    target straight back to the page on screen the instant the user chose a
    different session in the picker. The rule is therefore: push
    `voice-target` only when the PAGE's session id changes from the last one
    observed. Picking manually then sticks until you navigate somewhere else.
    (Found by the browser check: the picker appeared to do nothing because
    two retargets fired and cancelled out.)
- **Retarget (client -> channel)**: the hook leaves `voice:<old>` and joins
  `voice:<new>`, carrying the CURRENT draft text client-side and seeding it with
  `draft_edit` right after join (the server draft is per channel). Mic,
  AudioContext, and VAD are NOT torn down on retarget.
- **Draft sink rule**: if the page has
  `form[data-voice-composer-for="<target>"]` with its textarea, mirror the draft
  into that textarea (today's behaviour, incl. the scroll-to-end fix); otherwise
  mirror into the bar's own draft box.

  **CORRECTIONS from implementing it (`538ae5d`):**

  - **The never-clobber rule applies to a COMPOSER, not to the bar's own
    box.** §8.1's rule protects text the user typed into the page. The bar's
    box is our scratch space, so a draft carried across a retarget WINS over
    whatever is still sitting in it. Seeding the new channel is therefore:
    pre-typed composer text if any, else the carried draft.
  - **The bar's box is cleared whenever it is not the sink.** Otherwise the
    last draft it held resurfaces — and, under the rule above, would have
    out-voted the real draft at the next join.
  - **It is shown only once it holds something** (or has focus), not merely
    because voice is on and no composer is present. An empty box is 37px that
    the 16px budget below cannot afford on every composer-less page.
  - **The draft `input` listener is delegated on `document`**, not bound to
    the sink element. The sink moves between pages and between targets; a
    per-element listener would have to be rebound on every navigation and
    would leak one per page.
- **SINGLE SEND PATH (ORCAHUB3-86)**: on arming expiry / `send_now`, the SERVER
  no longer delivers by itself. It pushes `"send_request" {text}` to the client
  and moves to status `sending`. The client:
  - (a) if a composer form for the target is present: sets the textarea to
    `text`, flushes any pending `draft_edit`, and calls `form.requestSubmit()` so
    `SessionLive.Show`'s `send_message` runs — uploads consumed and transferred,
    attachment lines appended, `handle_delivery_result` semantics intact,
    `clear-prompt` pushed only on success. The hook observes `clear-prompt`
    (success) -> pushes `"sent_ack"` to the channel (server clears draft, pushes
    `sent`); or observes the LiveView's error flash / a
    `voice-send-failed {reason}` event that `send_message` now pushes on failure
    -> pushes `"send_failed" {reason}` (server keeps the draft, status `error`
    with the reason).
  - (b) if no composer is present: pushes `"send_direct"` and the server delivers
    via `Cluster.send_message(node, id, text, :queue)` exactly as today.
  - A `send_request` with no client response within 5 s -> server falls back to
    `send_direct` semantics ONLY if no composer was reported present at
    join/retarget time; otherwise it errors visibly ("composer did not
    respond").

  **CORRECTIONS / findings from implementing it (`9b56ea7`, `538ae5d`):**

  - **No bridging code is needed in the session page, and none was added.**
    This bullet assumed the bar would have to be handed `clear-prompt`
    somehow, since a page LiveView's `push_event` reaches only ITS OWN hooks.
    It does not: `LiveSocket.dispatchEvents` ALSO dispatches every
    `push_event` on `window` as `phx:<event>`. The bar listens for
    `phx:clear-prompt`, `phx:voice-send-failed` and `phx:voice-target`
    directly. This is a generally useful seam for any sticky/nested LiveView
    that needs to hear a page LiveView's events.
  - **The "error flash" half of the (a) branch was not implemented and should
    not be.** `voice-send-failed {reason}` (`593fde6`) is the signal; reading
    a flash would be guessing at DOM that means many other things too.
  - **`clear-prompt` carries no session id**, so the bar scopes it with its
    own `composer_present` flag — true only when the page on screen owns a
    composer for the CURRENT target. A submit from any other page's composer
    is correctly ignored.
  - **A `clear-prompt` with no send pending means the user pressed Send
    themselves**, so the bar pushes `cancel` to clear the server's copy of
    the draft. Otherwise the next spoken send would repeat text that has
    already gone.
  - **`cancel` abandons an outstanding `send_request`.** A spoken "orca
    cancel" landing while one is in flight otherwise lets the 5 s deadline
    deliver the very text the user just cancelled.
- The existing OVS1 binary frame and all phase-1 events are unchanged. There is
  NO `retarget` client -> server event — retarget is leave+join. New client ->
  server events: `sent_ack`, `send_failed {reason}`, `send_direct`,
  `composer {present: bool}` (sent at join and whenever the page's composer
  appears/disappears). New server -> client event: `send_request {text}`.

### 8.3 Voice-driven interaction (phase 2c, C5 — ORCAHUB3-87)

NORMATIVE for phase 2c. This contract was pinned by the orchestrator BEFORE any
code was written, in the same manner as §7.1-7.3 and §8.2, and it SUPERSEDES
§13 for everything it covers — §13 stays as the design record, so where the two
disagree this section wins. Tracked as **ORCAHUB3-87**.

#### 8.3.1 Focus

`focus` is one of `"composer"` | `"palette"`. The CLIENT owns it and tells the
server; the server NEVER infers it.

- `composer` (default): transcripts accumulate into the server draft exactly as
  §8.1/§8.2 describe.
- `palette`: the Ctrl+K command palette is open. While focus is `palette` the
  server does NOT touch the draft at all — no appends, no clears, no inserts.

Focus resets to `"composer"` on join and on retarget.

#### 8.3.2 Intent classes

`OrcaHub.Voice.Intent` keeps `intent/2`, `strip_command/3`, `score/2`,
`phonetic/1`, `ratio/2`, `tokenize/1`, `default_threshold/0` and
`default_vocab/0` **unchanged and byte-for-byte compatible with §5.1.1**:
`default_vocab/0` STAYS exactly the four phase-1 commands, and the 344-clip
parity test in `test/orca_hub/voice/intent_test.exs` is NOT edited.

Phase 2c adds, purely additively:

- `command_vocab/0` — an ORDERED LIST of `{name, phrase}`: the four
  `default_vocab/0` entries first, in their existing order
  (`:send, :cancel, :stop, :pause`), then the phase 2c entries in the order of
  §8.3.3. Ties keep the earlier entry, so no phase-1 behaviour can be displaced.
- `class/1` — `name -> :action | :insert | :select | :navigate | :ignore`.
  `:send`/`:cancel` -> `:action`; `:stop`/`:pause` -> `:ignore`; the rest per
  the §8.3.3 table.
- `payload/1` — `name -> map`. Insert names -> `%{text: "\n" | "\n\n" | "#" | "##"}`.
  Select names -> `%{ordinal: n}` (1-BASED). Navigate names -> `%{kind: "open_palette"}`,
  `%{kind: "close_palette"}`, `%{kind: "back"}`, or `%{kind: "navigate", path: "/sessions"}`.
  Any other name -> `%{}`.
- `match_label/2` — the conservative name matcher of §8.3.8.

`Voice.Session` calls `intent/2` and `strip_command/3` with
`vocab: Intent.command_vocab()` and its configured threshold.

#### 8.3.3 Vocabulary

Every phrase is AT MOST THREE TOKENS — the matcher only ever compares the last
1-3 tokens of a segment, so a four-token phrase can never match in full. (That
is why "orca the third one" from §13.5 is NOT in the list.)

This is `command_vocab/0` in full and it is the SHIPPED list — measured against
the corpus and pinned by `test/orca_hub/voice/intent_vocab_test.exs` (`ceb43d7`),
not the original proposal. The first four rows are §5.1.1's phase-1 entries,
unchanged and first in the ordering. "max on negatives" is each entry's MAXIMUM
score over the corpus's 154 negative clips — the closest any ordinary dictation
comes to firing it, against the 0.85 threshold. Re-wording an entry means
re-measuring it, never guessing.

| name | phrase | class | payload | max on negatives |
|---|---|---|---|---|
| `:send` | orca send | action | — | 0.833 (phase 1) |
| `:cancel` | orca cancel | action | — | 0.833 (phase 1) |
| `:stop` | orca stop | ignore | — | 0.727 (phase 1) |
| `:pause` | orca pause | ignore | — | 0.750 (phase 1) |
| `:search` | orca search | navigate | open_palette | 0.667 |
| `:open` | orca open | navigate | open_palette | 0.727 |
| `:back` | orca back | navigate | back | 0.600 |
| `:sessions` | orca all sessions | navigate | path `/sessions` | 0.727 |
| `:new_session` | orca new session | navigate | path `/sessions/new` | 0.727 |
| `:new_line` | orca new line | insert | `"\n"` | 0.667 |
| `:new_paragraph` | orca new paragraph | insert | `"\n\n"` | 0.667 |
| `:session_search` | orca session search | insert | `"#"` | 0.714 |
| `:hashtag` | orca hashtag | insert | `"#"` | 0.667 |
| `:project_search` | orca project search | insert | `"##"` | 0.588 |
| `:double_hashtag` | orca double hashtag | insert | `"##"` | 0.667 |
| `:first` | orca first item | select | ordinal 1 | 0.714 |
| `:second` | orca second item | select | ordinal 2 | 0.769 |
| `:third` | orca third item | select | ordinal 3 | 0.769 |
| `:fourth` | orca fourth item | select | ordinal 4 | 0.769 |
| `:fifth` | orca fifth item | select | ordinal 5 | 0.667 |
| `:sixth` | orca sixth item | select | ordinal 6 | 0.667 |
| `:seventh` | orca seventh item | select | ordinal 7 | 0.714 |
| `:eighth` | orca eighth item | select | ordinal 8 | 0.667 |
| `:ninth` | orca ninth item | select | ordinal 9 | 0.833 |

**Two entries were REWORDED by §8.3.4, and the reason is recorded here rather
than rediscovered:**

- **The BARE ORDINALS are out** — the proposal's `orca first` .. `orca ninth`
  failed BOTH acceptance bars. `orca second` is a phonetic TWIN of the commonest
  ASR surface form of `orca send`: `phonetic("orcasecond") == "arksknt" ==
  phonetic("orcascend")`. It scored 1.0 against and STOLE 30 positive SEND
  clips, and produced 2 false positives at 0.900; `orca ninth` fired on a
  negative (the JFK clip) at 0.909, a false positive on its own. `orca <ord>
  item` fixes both — worst-in-family negative 0.909 -> 0.833, stolen positives
  30 -> 0 — while keeping the siblings separable (worst rival 0.933, first-item
  vs fourth-item). The CARDINAL families (`orca select one`..`nine`, `orca
  number one`..`nine`, `orca one`..`nine`) are ALL disqualified for a different
  reason: "one" and "nine" are phonetically IDENTICAL after folding (score
  1.000), so slot 9 could never be reached at all.
- **`orca sessions` ships as `orca all sessions`.** The short form is not a
  false positive but sits at 0.800 — 0.05 of headroom against the threshold.
  The reworded phrase measures 0.727, and the user loses nothing: speaking the
  short "orca sessions" still resolves to `:sessions` at 0.923.

`:ninth` is KEPT despite measuring 0.833, which is the same margin phase-1's
`:send` and `:cancel` have carried since day one; dropping it would make the
9th palette result unreachable by ordinal.

**Known limitations, each pinned as a test:**

- A truncated `orca ninth` resolves to `:send` (0.909), NOT `:ninth` — so the
  §8.3.10 help text must teach the full three-token phrase. `orca first` ..
  `orca eighth` DO resolve to their own names (0.909-0.933).
- Truncated `orca second` beats `:send` by only 0.010 (0.933 vs 0.923). Do not
  narrow that margin.
- Aliases that need no entry because they already reduce to the same target:
  `orca newline` == `orca new line` (1.0), `orca hash tag` -> `:hashtag` (1.0),
  `orca go back` -> `:back` (1.0).

Both rewordings stayed inside the three-token budget above, which is why
`orca <ord> item` was available at all.

#### 8.3.4 Corpus acceptance bar

Against `test/support/fixtures/voice/intent_corpus.json` with `command_vocab/0`
at threshold 0.85, a COMMITTED test asserts:

1. **Zero false positives** — every negative clip still returns `nil`.
2. **No stolen positives** — every positive clip returns the SAME intent name it
   returns under `default_vocab/0`.
3. The §5.1.1 parity test (default vocab, scores pinned to 1.0e-9) is untouched
   and still green.

Any entry that breaks 1 or 2 is DROPPED or REWORDED, and the drop is recorded.
Each shipped entry's MAXIMUM score over the negative clips is recorded.

That test is `test/orca_hub/voice/intent_vocab_test.exs` (`ceb43d7`). It ran
against all 344 clips and forced the two rewordings recorded in §8.3.3; the
per-entry margins it pins are the same numbers as that section's table, so the
two cannot drift apart.

#### 8.3.5 Wire additions

**Client -> server, one new event.**

- `"ui_focus"` — `%{"focus" => "composer" | "palette", "candidates" => [%{"index" => i, "label" => s}]}`
  - `index` is 0-BASED and is the index the CLIENT will act on.
  - `label` is the visible text, truncated to 80 chars; at most 9 candidates.
  - Pushed at join, on every focus change, and whenever the visible candidate
    list changes; debounced 150 ms; pushed only when the value actually changed.
  - `candidates` describes whichever selectable list is visible: the palette's
    results when `focus == "palette"`, else the composer autocomplete dropdown's
    items when it is open, else `[]`.
  - The nine-candidate cap is enforced INDEPENDENTLY on both sides — the client
    stops collecting at `MAX_CANDIDATES` (`assets/js/voice/voice_hook.js`) and
    the server re-applies `@max_candidates` in `Voice.Session.ui_focus/3`. That
    is deliberate duplication, not redundancy to be tidied away: the client cap
    keeps unspeakable rows off the wire, and the server cap is what stops a
    stale, hostile or simply buggy client from growing the state it keeps per
    session. Removing either one because "the other does it" is a regression.

**Server -> client, one new event.**

- `"ui_action"` — `%{kind: k, payload: p}` with
  `k ∈ "open_palette" | "close_palette" | "palette_query" | "select" | "navigate" | "back"`:
  - `open_palette` / `close_palette` / `back` — payload `%{}`
  - `palette_query` — `%{text: t}`, REPLACE semantics (each utterance replaces
    the whole query; spoken corrections never accumulate)
  - `select` — `%{ordinal: n}` (1-based, from an ordinal command) or
    `%{index: i, label: l}` (0-based, from a name match)
  - `navigate` — `%{path: "/sessions"}` etc., a path from the fixed set in
    §8.3.3

`"state"` (the full snapshot) gains `focus`, echoing the server's current belief.

`"segment_result"`'s `action` gains `"insert"`, `"select"`, `"navigate"`,
`"palette_query"`, `"ignored_palette_focus"`; `intent` carries the matched
vocabulary name for each of them.

#### 8.3.6 Routing rules (server, `Voice.Session`)

For each applied transcript, in order:

1. `intent/2` over `command_vocab/0` at the session threshold.
2. If a command matched, dispatch by `class/1`:
   - `:action` — §8.1/§8.2 unchanged, EXCEPT while `focus == "palette"`:
     `:send` is IGNORED (`action: "ignored_palette_focus"`, draft untouched) and
     `:cancel` emits `ui_action close_palette` and does NOT clear the draft.
   - `:ignore` — unchanged (`ignored_stop_pause`).
   - `:insert` — strip the command; if a remainder is left, append it with the
     ordinary space-join FIRST; then append the payload text using §8.3.7's join
     rule. Emits NO `ui_action` — the client learns about it through the ordinary
     `"state"` snapshot, which the §8.2 draft-sink rule already mirrors into the
     composer with a real bubbling `input` event (that is exactly what makes the
     `#`/`##` autocomplete open as if typed). `action: "insert"`. IGNORED while
     `focus == "palette"` (`ignored_palette_focus`).
   - `:select` — strip the command, DISCARD any remainder (a selection utterance
     is not dictation), emit `ui_action select %{ordinal: n}`, leave the draft
     alone. `action: "select"`.
   - `:navigate` — strip the command, discard any remainder, emit the
     corresponding `ui_action`, leave the draft alone. `action: "navigate"`.
3. If NO command matched:
   - `focus == "composer"` -> §8.1 append, unchanged (`action: "appended"`).
   - `focus == "palette"` -> try `match_label/2` against the last reported
     `candidates` (§8.3.8); on a match emit `ui_action select %{index:, label:}`
     (`action: "select"`), else emit `ui_action palette_query %{text:}`
     (`action: "palette_query"`). The draft is NEVER touched either way.

**Amendment (measured 2026-09-18, landed with `e3afb74`).** The text of a
`palette_query` is stripped of trailing sentence punctuation (`.`, `,`, `!`,
`?`, and runs of them) before it goes on the wire; the DRAFT is never stripped.
Every filter behind `CommandPaletteLive` is a literal `String.contains?` on the
downcased name, and the ASR punctuates nearly every utterance — so `"security."`
matched zero rows where `"security"` matched one, which made every spoken query
dead on arrival. The normalization lives on the spoken-query path alone:
`CommandPaletteLive`'s matching belongs to typed users, and dictation must keep
its punctuation. `match_label/3` is deliberately NOT given the stripped text —
it already normalizes for itself, and it matched `"session."` to the `Sessions`
row before this amendment and still does.

**Arming.** `:insert`, `:select`, `:navigate` and a palette query all CANCEL an
open arming window (the user kept talking, so it is not a confirmation) and
NEVER open one. Only `:send` ever opens it. Nothing in phase 2c sets `sending`.

#### 8.3.7 Insert join rules

- `"\n"` / `"\n\n"`: `String.trim_trailing/1` the existing draft, then
  concatenate with NO separator.
- `"#"` / `"##"`: joined with a SINGLE SPACE when the draft is non-empty and does
  not already end in whitespace; otherwise concatenated directly.
- After a `#`/`##` insert the session sets `pending_insert: true`, which makes
  the NEXT appended transcript concatenate with NO separator — so the spoken
  query lands immediately after the trigger where `Autocomplete`'s
  `/#(\S*)$/` can see it. `pending_insert` is cleared by that append, by any
  other insert, by `cancel/1`, by a send, and by a manual `draft_edit`.
- An append never doubles a separator: when the draft already ends in
  whitespace, the next appended transcript is concatenated directly rather than
  space-joined. (Amendment landed with `1214efa`. Without it every spoken
  newline would put a leading space on the line it just opened. It is invisible
  to phases 1 and 2, where a draft could not end in whitespace at all.)
- KNOWN LIMITATION, documented not fixed: the autocomplete trigger regex stops
  at the first space, so a multi-word spoken query searches on its FIRST WORD
  only. Selecting a result replaces everything from the trigger to the caret, so
  the extra words are consumed by the replacement rather than left behind.
- The segment that CONSUMES `pending_insert` also loses the ASR's trailing
  sentence punctuation, by the same argument as §8.3.6's palette query: that
  segment is by definition the spoken query for a `#`/`##` trigger the user has
  just uttered, not prose. Measured 2026-09-18: the session search behind the
  autocomplete is an ILIKE on the raw query, so `#Voice.` matched nothing where
  `#Voice` matches two. The normalization is `pending_insert`-scoped and reuses
  §8.3.6's normalizer, so ordinary dictation keeps its punctuation — and so
  does the line after a spoken NEWLINE, which never sets the flag. This is what
  makes the whole §13.5 headline sequence reachable BY VOICE: "orca session
  search" -> spoken query -> "orca second item", verified end to end with no
  keyboard.

#### 8.3.8 Name matching — `match_label/2`

Deliberately conservative: ordinals are the reliable path, names are a bonus.

Compare the WHOLE transcript (not the terminal 1-3 tokens) against each
candidate label, spaces removed on both sides, scoring
`max(ratio(a, b), ratio(phonetic(a), phonetic(b)))`. A match requires
`best >= 0.85` AND `best - runner_up >= 0.10` (with a single candidate, treat
the runner-up as 0.0). Otherwise: no match.

**As implemented (`ceb43d7`)** — the signatures the `Voice.Session` slice calls,
pinned here because the contract left the exact shapes open:

    Intent.command_vocab() :: [{name, phrase}]
    Intent.class(name)     :: :action | :insert | :select | :navigate | :ignore
    Intent.payload(name)   :: map
    Intent.match_label(text, candidates, opts \\ []) ::
      {:ok, %{index: integer, label: String.t(), score: float}} | :no_match

`class/1` returns `:ignore` for an unknown name and `payload/1` returns `%{}`,
so an unrecognised name can never be routed as an action, an insert or a
navigation. `match_label/3` accepts candidates in the §8.3.5 WIRE shape
(`%{"index" => i, "label" => s}`), with atom keys, or as bare strings — a bare
or missing index falls back to list position — and takes `:threshold` (0.85)
and `:margin` (0.10) as options rather than hard-coding them. The default
`opts` is what makes it satisfy this section's `match_label/2`.

#### 8.3.9 Client obligations

- **Focus tracking.** A MutationObserver on `document.body` recomputes
  `{focus, candidates}`, debounced 150 ms. `focus = "palette"` iff
  `#command-palette-results` is in the DOM. Candidates come from
  `#command-palette-item-<i>` label text when the palette is open, else from
  `#autocomplete-dropdown:not(.hidden) button[data-index]`, else `[]`.
- **`open_palette`**: no-op when already open; else
  `document.dispatchEvent(new CustomEvent("command-palette:toggle"))` (the
  existing seam `CommandPalette` already binds).
- **`close_palette`**: no-op when closed; else the same toggle seam.
- **`palette_query`**: set `#command-palette-input.value`, then dispatch a
  bubbling `input` AND a bubbling `KeyboardEvent("keyup")` — `phx-keyup="search"`
  is what actually reaches the LiveComponent.
- **`select`**: resolve to a 0-based index (`ordinal - 1` for an ordinal), then
  apply to the active list — the composer autocomplete dropdown FIRST
  (`#autocomplete-dropdown:not(.hidden) button[data-index="<i>"]` -> dispatch
  `mousedown`, which is the handler that hook binds), else the palette
  (`#command-palette-item-<i>` -> `.click()`, which carries `phx-click="select"`
  with its `phx-value-index`). Out of range or no list: no-op plus a log line.
- **`navigate`**: MUST live-navigate. `VoiceBarLive` renders one HIDDEN
  `<.link navigate={path} data-voice-nav={path}>` per path in the fixed set, and
  the hook clicks the matching anchor. NEVER `window.location`, never a plain
  `<a href>` — a document reload takes the bar, the mic, the `AudioContext` and
  the channel with it (§8.2).
- **`back`**: `window.history.back()` (LiveView handles the popstate for
  live-navigated pages).
- The §8.2 draft-sink rule is unchanged; palette queries never go through it.

#### 8.3.10 Discoverability

The bar carries a help affordance listing the current vocabulary grouped by
class, rendered from the SERVER-SIDE source of truth (`Intent.command_vocab/0` +
`class/1`) so the list cannot drift from the matcher. Collapsed by default, and
it must cost ZERO header height while collapsed — §8.2's 48 px idle / 64 px armed
budget at 390 px still holds and is re-measured with `getBoundingClientRect`,
never a screenshot.

#### 8.3.11 Cancel is armed, and cancel is undoable (ORCAHUB3-99)

**The defect.** On 2026-09-19 a user dictated 41 segments — ~4 minutes, a
detailed design argument — and segment #41, `"That is not what the original
goal was."`, was classified `:cancel`. `Voice.Session.cancel/1` set
`draft: ""` and the whole thing was gone, with no undo. They never said
"orca cancel".

**The guards were backwards.** §5.1.1's asymmetry note — "a false positive
sends early (recoverable by a follow-up message)" — is a statement about
SEND, and it was the only action guarded. `:send` got a 1500 ms arming
window that any further speech aborts; `:cancel`, whose false positive
destroys unbounded work, fired instantly.

**The threshold is NOT the lever, and this is measured, not assumed.**
Segment #41 scores `0.8571428571428571` against `orca cancel` — 0.0071 over
the shared 0.85. Six GENUINE "orca cancel" clips in the §5.1.1 corpus, which
Whisper heard as `"or cut cancel."`, score the IDENTICAL float. A
`:cancel`-specific threshold is defensible in principle (the error costs
really are asymmetric) and impossible in practice: every threshold strictly
above 0.8571428571428571 — including 1.0, since nothing sits in between —
takes the corpus's cancel true positives from 44/46 to 38/46 while removing
exactly one false positive. `Intent`'s threshold therefore stays at 0.85 for
every entry, and the defence is the two rules below. Pinned in
`intent_vocab_test.exs`, "§8.3.11 real dictation".

**Rule 1 — a spoken cancel ARMS.** It reuses the SAME machinery `:send`
uses (`arming_until` + a new `arming_kind`, `speech_start/1`, `armable?/2`),
never a second timer:

- the stripped remainder is appended first, exactly as `:send` does it — an
  aborted cancel must not eat the dictation that preceded the command word;
- an open SEND window and any outstanding `send_request` die immediately, as
  before — calling off a send is never destructive;
- the draft is cleared only when the window expires, and the window is
  aborted by speech onset, `armable?/2`'s resumed-speech case, a following
  appended segment, a manual `draft_edit`, and every §8.3.6 non-action class;
- `status` stays `"arming"`, with the snapshot's new `arming: "send"|"cancel"`
  saying which. The bar renders "cancelling in 1.2s" in an error-coloured
  chip, because those 1500 ms are the user's chance to talk it away.
- the EXPLICIT gesture (`cancel/1`, the `"cancel"` wire event) is NOT armed.
  A button press is not a transcription guess.

**Rule 2 — every clear is recoverable.** Whatever a cancel throws away is
kept in `last_cancelled_draft`, the snapshot carries `restorable`, and the
bar shows a "restore draft" control in the summary ROW (zero extra header
height). Tuning the matcher only reduces the FREQUENCY of a false positive;
keeping the text removes its SEVERITY, which is why this half ships even
though the measurement above says the matcher cannot be tuned out of the
problem at all.

Wire additions, on top of §8.3.5:

- server -> client `"cancelled" {text}` — a cancel actually cleared a draft.
  Its own event, because the spoken cancel's `segment_result` now fires
  1500 ms BEFORE the clear, and a palette-focus cancel fires it before no
  clear at all.
- client -> server `"restore_draft" {}` — put it back. A no-op when there is
  nothing to restore, and a no-op over a NON-EMPTY draft: restoring over
  fresh dictation would be a second way to lose text.
- client -> server `"draft_delivered" {}` — the page's own composer delivered
  the draft (a TYPED send). Clears exactly what `"cancel"` clears and records
  NO undo. The hook used to push `"cancel"` here, which was harmless only
  while a cancel had no undo to get wrong; a "restore draft" button after a
  successful send would invite a double send.
- snapshot gains `arming` and `restorable`.

**The client's copy of the draft wins.** §8.2's merge rule already allows the
sink to be ahead of the server — a debounced `draft_edit` may be in flight —
so the hook captures `_draftEl().value` BEFORE emptying it and restores THAT,
writing it back through the ordinary sink path (`_writeDraft` + `draft_edit`)
so the composer and the server agree. `"restore_draft"` is the fallback for a
client with no copy of its own (a rejoin, a second tab, the bar's own box).

**The other finding from the same transcript.** Scored against the whole
vocabulary, the other 40 segments fire nothing — but #30, "…do a bunch of
research,", reaches **0.8333 against `orca search`**, 0.0167 short of opening
the command palette and having "bunch of research" eaten out of the draft by
`strip_command/3`. That is the same hazard shape as ORCAHUB3-92's "…orca hub"
and it was found the same way: by hand, against a phrase the corpus does not
contain. Not reworded (no false positive, and `orca search` is the phrase
users actually reach for), but pinned in `intent_vocab_test.exs` so a future
re-wording that makes it worse fails loudly. #9 and #25 both reach 0.800
against `orca third item`, on the word "orchestrator".

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
   section 5.1's phonetic tail-matcher (section 5.1.1) at threshold 0.85, plus
   the arming window. **This is a usable product and most of the value.**

   PHASE 1 EXIT CRITERIA — both from `spikes/voice/ACOUSTIC_TEST.md`:
   1. **Part A (AEC) recorded.** The `AEC suppression` number, the
      `triggers (playback)` counts, and a 3 x "orca send" WAV dump on REAL
      microphone hardware confirming pre-roll onsets at ~420-510ms rather
      than ~0.
   2. **Part B (real-voice wake word) >= 95% TP and 0 FP at threshold 0.85**
      (>= 19/20 correct, 0 wrong intent). If it fails, fall back to section
      5.1 option (a) — train `orca send` on openWakeWord and run it alongside
      the matcher.
2. **Streaming TTS off assistant deltas + speakable-content policy — C1-C3,
   NORMATIVE in §7.1, §7.2 and §7.3.** Server-side delta broadcast on
   `session:<id>` (§7.1), the `assistant-stream` push_event + `AssistantStream`
   hook (§7.2), and the sentence accumulator behind the "Speak while streaming"
   toggle (§7.3). IN PROGRESS.

2b. **Global voice bar + single send path — C4, NORMATIVE in §8.2.**
   `OrcaHubWeb.VoiceBarLive` sticky in the app header, live navigation
   everywhere in-app, retarget by leave+join, and `send_request` -> the real
   composer form so uploads and attachments stop being bypassed. Resolves
   ORCAHUB3-88 and ORCAHUB3-86; supersedes phase 1's `SessionLive.Show`-only
   panel. IN PROGRESS.

2c. **Voice-driven navigation — C5, DESIGN ONLY, §13.** The `composer |
   palette` focus concept, `orca search` / `orca open` / `orca back` /
   `orca sessions` / `orca new session`, selection by spoken ordinal, and the
   rule that every new vocabulary entry is scored against
   `test/support/fixtures/voice/intent_corpus.json` (0 new FPs at 0.85) before
   it ships. Tracked as ORCAHUB3-87. Implementation is a later phase and will
   get its own contract; §13 is notes, not a contract.

3. openWakeWord path for stop/pause during playback: trained `orca stop` /
   `orca pause` classifier heads, **playback-only, VAD-gated** (section 5.2).
   Blocked on phase 1's exit criterion 1.
4. Browser AEC + text-domain echo rejection -> duck-on-detect -> open channel.
   GO/NO-GO IS ACOUSTIC_TEST.md PART A's `AEC suppression` NUMBER: >15 dB go,
   6-15 dB duck-on-detect only, <6 dB do not build.
5. LLM intent adjudicator, only if phase 1 heuristics prove insufficient.

### 10.5 Contract -> phase -> section map

Phases 3, 4 and 5 keep their original numbers; only phase 2 was split, into 2,
2b and 2c.

| Contract | Phase | Normative section | Issue | Status |
|---|---|---|---|---|
| C1 assistant delta stream (server) | 2 | §7.1 | — | in progress |
| C2 client streaming events | 2 | §7.2 | — | in progress |
| C3 streaming TTS producer | 2 | §7.3 | — | in progress |
| C4 global voice bar + single send | 2b | §8.2 | ORCAHUB3-88, ORCAHUB3-86 | in progress |
| C5 voice-driven interaction | 2c | §8.3 (design notes: §13) | ORCAHUB3-87 | in progress |

Phase-1 contracts are unchanged and remain normative: §8.1 (wire + DOM),
§5.1.1 (the matcher), §3.2 (the VAD settings).

## 11. Open questions for the finalizing orchestrator

- ~~Does GB10 currently expose an OpenAI-compatible
  `/v1/audio/transcriptions`, or something else? What model, what latency at
  3-10s utterances?~~ **ANSWERED — see section 6.** No OpenAI-compatible
  route; the sync lane of the existing `transcription` container,
  `large-v3-turbo`, 772ms p50 at 3.9-5.0s.
- ~~Which SEND path — section 5.1 (a) keyword spotter vs (b) transcript
  vocabulary + phonetic matcher?~~ **ANSWERED — see section 5.1.** (b), the
  transcript matcher: 96.8% TP / 0 wrong-intent / 0.0% FP at threshold 0.85
  over 190 positives and 154 negatives, at ~zero marginal cost. This REVERSES
  the interim post-SPIKE-2 recommendation of (a). (a) stays as the documented
  fallback if the real-voice check below fails.
- ~~WAV vs webm/opus for the browser upload?~~ **ANSWERED — see section 6.**
  No measurable difference: non-server overhead is flat 88-126ms across a 95x
  payload range, and SPIKE 2's contrary result was two different clips.
  Implementer's choice.
- ~~Is `@ricky0123/vad-web` acceptable as a dependency, or should Silero be
  wired to onnxruntime-web directly? What is the bundle-size cost?~~
  **ANSWERED — see section 3.2.** vad-web 0.0.31 with every default
  overridden; bundle cost is 0.3% over direct Silero (5,560,445 vs 5,543,660 B
  gzip), both dominated by ort's wasm, so the choice is maintenance, not size.
- ~~Porcupine requires a Picovoice access key (free tier). Acceptable, or is
  openWakeWord the right call despite being Python-first?~~ **ANSWERED — see
  section 5.2.** openWakeWord. There IS no free tier: Picovoice's FAQ says
  there are no free or paid personal/non-commercial plans, billing is per
  monthly active browser instance, and the key must ship to the browser —
  Porcupine is licence-blocked before any technical question, and every
  Porcupine performance number is therefore unmeasured.

STILL OPEN — all three are human-in-the-loop or a small upstream change:

- Does browser AEC actually suppress our TTS adequately on Zach's real
  hardware, or is half-duplex the permanent answer? **STILL OPEN**, and
  neither SPIKE 1 nor SPIKE 3 can answer it — a fake capture device has no
  acoustic loop. It gates section 4.1 rung 3 AND section 5.2.
  `spikes/voice/ACOUSTIC_TEST.md` part A, ~5 minutes.
- Does the section 5.1.1 matcher survive a real larynx? **STILL OPEN** —
  SPIKE 2b's corpus is one synthetic Chatterbox voice, so 96.8%/0.0% is an
  upper bound and the specific surface forms (`or Kapaz`, `or Cascend`) may be
  artifacts of it. `spikes/voice/ACOUSTIC_TEST.md` part B, ~4 minutes; it is a
  phase 1 exit criterion.
- Does `initial_prompt` biasing help on the sync lane? **STILL OPEN and
  UNMEASURED** — it is ignored as shipped and needs a ~5-line `api.py` change
  in the `transcription` repo. Recommended independently by SPIKE 3; it might
  make the phonetic key unnecessary, but keep the matcher either way
  (section 6).

## 12. Changelog

**v0.6 (2026-09-18, phase 2c integration-verified)** — the contract survived
contact with a real page, a fake mic and real speech; the amendments here are
what the measurement forced, not redesign. §8.3.6 gains the palette-query
PUNCTUATION amendment (`e3afb74`): the ASR punctuates nearly every utterance
and every palette filter is a literal `String.contains?`, so `"security."`
matched zero rows where `"security"` matched one and spoken palette search was
dead on arrival — stripped on the spoken-query path only, never on the draft.
§8.3.7 records `1214efa`'s append amendment verbatim (an append never doubles a
separator) and a SECOND, deliberately unfixed punctuation limitation: the same
full stop reaches the composer autocomplete inside the DRAFT, where it cannot
be normalized without either rewriting dictation or changing the typed-user
search. §8.3.5 records that the nine-candidate cap is enforced independently on
both sides of the wire, so a future reader does not delete one believing the
other covers it. §10.5's C5 row is retitled "voice-driven interaction" to match
§8.3, which covers inserts and selection as well as navigation.

**v0.5.1 (2026-09-19, ORCAHUB3-99)** — §8.3.11 NEW: a spoken `:cancel` is
ARMED with the same 1500 ms window `:send` already had, and every cleared
draft is recoverable (`last_cancelled_draft` + `restore/1` + a "restore draft"
control in the bar). Filed after a real 41-segment dictation lost ~4 minutes
to one false positive. The threshold question is answered by MEASUREMENT and
the answer is "no change": the offending utterance scores
`0.8571428571428571` against `orca cancel` and so do six genuine "orca cancel"
corpus clips, so no `:cancel`-specific threshold can separate them (cancel TP
would go 44/46 -> 38/46 for one fewer FP). Wire additions: `"cancelled"`,
`"restore_draft"`, `"draft_delivered"`, plus `arming` and `restorable` on the
snapshot. The 41-segment transcript ships as
`test/support/fixtures/voice/dictation_orcahub3_99.json` — the project's only
adversarial sample produced by a human — and pins a second finding: "…do a
bunch of research," sits 0.0167 under firing `orca search`.

**v0.5 (2026-09-18, phase 2c contract pinned)** — §8.3 NEW (C5): phase 2c's
contract, pinned BEFORE any of it was implemented, in the same manner as
§7.1-7.3 and §8.2. It makes `focus` (`composer | palette`) a CLIENT-owned fact
the server never infers; keeps §5.1.1's matcher and `default_vocab/0`
byte-for-byte intact and adds `command_vocab/0` / `class/1` / `payload/1` /
`match_label/2` purely additively; pins the candidate vocabulary (every phrase
at most three tokens, so §13.5's "orca the third one" cannot ship) behind a
corpus acceptance bar of zero new false positives and zero stolen positives at
0.85; adds exactly one client -> server event (`ui_focus`) and one server ->
client event (`ui_action`), plus `focus` on the `state` snapshot and five new
`segment_result` actions; and pins the server routing table, the insert
join/`pending_insert` rules, the conservative `match_label/2` margin, the
client's live-navigation and palette-driving obligations, and a
zero-header-height discoverability affordance. §8.3 SUPERSEDES §13, which is
now labelled the DESIGN RECORD; §10.5's map re-points C5 at §8.3 with §13 kept
as the design notes.

**§8.3.3 filled in from the measurement (`ceb43d7`)** — the candidate table is
replaced by `command_vocab/0` as SHIPPED, with each entry's real maximum score
over the corpus's 154 negative clips, pinned by
`test/orca_hub/voice/intent_vocab_test.exs`. Scoring forced the two rewordings
§8.3.4 anticipated, both now recorded with their reasons: the BARE ORDINALS are
out (`orca second` is a phonetic twin of `orca send` — identical after folding —
and stole 30 positive SEND clips plus 2 FPs at 0.900; `orca ninth` was an FP on
its own at 0.909), replaced by `orca <ord> item`, with the cardinal families
disqualified separately because "one" and "nine" fold identically and slot 9
would be unreachable; and `orca sessions` (0.800, only 0.05 of headroom) ships
as `orca all sessions` (0.727) while the short form still resolves at 0.923.
`:ninth` is kept at 0.833 — phase-1 `:send`/`:cancel` have carried that same
margin since day one. Three known limitations are recorded and tested, the
sharpest being that a truncated `orca ninth` resolves to `:send`, so §8.3.10's
help text has to teach the full three-token phrase. §8.3.8 also gains the
concrete `Intent` signatures that slice's implementation pinned.

**v0.5 (2026-09-18, phase 2/2b landed)** — C1-C4 are IMPLEMENTED and
integration-verified 9/9 at `113fa91` (commit list and the nine checks are in
the header). Spec changes in this pass are documentation only: the header now
reads "phase 2 + 2b implemented at `113fa91`; phase 2c next", and §7.3 records
the measured nuance that the spoken mark must be set on the FIRST chunk while
the accumulator's `stop` flush may legitimately enqueue the tail sentence ~3 ms
after the persisted node renders — the invariant is "no `ttsPlayById`, no
duplicated text", not zero post-render enqueues. `.context/voice-mode.md` now
carries the phase 2/2b map and its own invariants (live navigation, the
two-segment rule for a spoken command, the shared-`TTSMethods` push rule, the
48/64/16 px header budget). C5 (§13) stays design-only and is next.

**v0.4.2 -> v0.5** — phase 2 opened. Three new NORMATIVE contracts (C1-C3) for
streaming assistant deltas and streaming TTS, one (C4) for the global voice bar
and the single send path, and a design-only record (C5) of voice-driven
navigation. Header status is now "phase 1 deployed (`d679c12`); phase 2/2b in
progress"; phase 1's two ACOUSTIC_TEST exit criteria are still un-run and still
gate phases 3-4.

- §7.1 NEW (C1): the assistant delta stream — `assistant_stream_start` /
  `assistant_block_start` / `assistant_delta` / `assistant_block_stop` /
  `assistant_stream_stop` on the existing `session:<id>` topic, unpersisted,
  string-keyed. TEXT deltas only (no tool-input JSON, no thinking), `stream_id`
  == the persisted message's `message.id` so the live bubble correlates with the
  final render, best-effort (a client that missed them sees the persisted
  message), and a backend that cannot stream emits NOTHING rather than fake
  deltas.
- §7.2 NEW (C2): `push_event "assistant-stream"` and the single
  `AssistantStream` hook owning `#stream-<stream_id>` — no per-delta LiveView
  assigns. TTS consumes the same events via a re-dispatched `window`
  `orca:assistant-stream` CustomEvent, so nothing couples to the feed DOM.
- §7.3 NEW (C3): the sentence accumulator in `TTSMethods` behind a
  "Speak while streaming" toggle (`orca:tts-stream`, off by default) — fence
  tracking, the 40/240/1500 ms release rules, re-keying the queue to the
  persisted id at `stop`, ONE short announcement per tool_use block and never
  the payload, spoken-marking so end-of-turn autoplay does not repeat it, and
  §7's GPU-contention rule made concrete as `orca:voice-asr-busy`.
- §8.2 NEW (C4): `OrcaHubWeb.VoiceBarLive`, sticky-rendered in the app header —
  resolves ORCAHUB3-88 (voice died on navigation) and ORCAHUB3-86 (the spoken
  send bypassed the composer's uploads/attachments). It SUPERSEDES phase 1's
  `SessionLive.Show`-only panel: the `[data-voice-*]` DOM contract and every
  phase-1 event survive verbatim, but the markup moves to `VoiceBarLive`, the
  draft sink is indirected through `form[data-voice-composer-for]`, all in-app
  navigation becomes live navigation, retarget is leave+join, and the server
  stops delivering the draft itself — it pushes `send_request {text}` and the
  client submits the real composer form (`sent_ack` / `send_failed` /
  `send_direct` / `composer {present}` added).
- §10: the phase list now splits phase 2 into 2 (C1-C3), 2b (C4) and 2c (C5,
  design only); phases 3-5 keep their numbers. §10.5 NEW — a contract ->
  phase -> section map.
- §13 NEW (C5): the phase-2c design notes for voice-driven navigation —
  the focus concept, the corpus-scoring requirement, and ORCAHUB3-87's
  motivating example, candidate vocabulary and design questions recorded
  verbatim, plus which of them §8.2 already makes easier.
- §8.2, second pass: the three v0.4.2 §8.1 rules that 2b would most easily
  break are now named rather than folded into "the DOM contract" — the mic
  button as the always-rendered autoplay gesture, the bubbling synthetic
  `input` event on every composer write, and the never-clobber seeding rules
  (which retarget promotes from once-per-page to routine). Plus a hard MOBILE
  BUDGET: idle = one icon button in the existing header row, armed <= phase
  1's 16 px at 390 px, measured with `getBoundingClientRect`, picker and draft
  box included — a global bar is on every page, so it cannot spend what
  `29c9778` reclaimed.
- §13.5 NEW (C5 addendum, from Zach 2026-09-18): spoken COMPOSER control
  sequences — "orca new line" / "orca new paragraph" and the "#" / "##"
  autocomplete triggers as a NEW "insert" intent class carrying a payload,
  distinct from actions and NOT opening the arming window, with ordinal
  selection shared with the palette (ONE selection mechanism) and the same
  corpus-scoring gate.

**v0.4.1 -> v0.4.2** — the §8.1 DOM contract shrank. The panel occupied roughly
half a 390 px viewport (status row + its own 2-row draft textarea + a
Send/Clear button row + a tall scrolling log), leaving the conversation feed a
sliver, while the real composer sat right below it with a second, redundant
textarea. Measured headlessly at 390x844 and 1440x900: 167 px -> 16 px, all
151 px of it returned to `#message-feed`.

- §8.1 DOM contract: `data-voice-draft` and the `send`/`cancel` buttons are
  GONE. The draft sink is the composer's own `#prompt-input`, named by a new
  `data-voice-draft-target` attribute on the panel; the hook writes it and then
  dispatches a bubbling `input` event so `Autocomplete`'s autoresize still runs.
  Merge rule: `draft_edit` still flows composer -> server (debounced 300 ms) and
  now also SEEDS the server with pre-typed text at join, and an empty
  `state.draft` never empties a non-empty composer — clearing is explicit
  (`"sent"`, a `cancel` segment_result, or LiveView's `clear-prompt`).
- §8.1 DOM contract: the per-segment log moved inside a native `<details>`
  (`data-voice-log-details`) that is CLOSED on load, with the open state
  persisted in `localStorage` under `orca:voice:log-open`. The panel is
  `phx-update="ignore"`, so the disclosure cannot be a LiveView assign.
- Unchanged, and re-pinned here because the shrink could have broken it:
  `"orca send"` still delivers SERVER-side with `:queue` (never `:interrupt`,
  never a client-side form submit), and the `toggle_voice` button is still an
  always-rendered real click target for the autoplay policy.

**v0.4 -> v0.4.1** — §8.1 added, the VoiceChannel wire contract. Phase 1 then
built against it (slices A `f23b5b8`, B `0080399`, C `4a28f2b`, D `ef9f87a` +
`f101886`, E `df935f1`, F `6f0e6d4` + `097806d` + `735b396`); the header now
records that, and the architecture + invariants live in `.context/voice-mode.md`.
Both phase 1 exit criteria (ACOUSTIC_TEST.md Parts A and B) remain un-run.

- §8: the deployment precondition was overstated — narrowed from "every node
  that can terminate a voice websocket" to the k3s `orca-hub` pod alone (the
  agent-mode gate and `getUserMedia`'s secure-origin rule rule out every other
  prod node), and noted that the ASR URL may be any FQDN resolvable from the
  pod.
- §8: reachability from the `orca-hub` pod VERIFIED 2026-09-17 —
  `http://192.168.1.77:8000/healthz` 200 in ~5 ms with the sync lane ready and
  CUDA up, no NetworkPolicy restricting the pod's egress; the in-cluster
  `whisperx-external` Service and the Authelia-free
  `transcription.lab.ingbretsenhome.com` Ingress are equally valid targets, and
  `gb10.lab.ingbretsenhome.com` is recorded as a trap (it resolves to the debian
  Traefik wildcard, not the GB10).
- §8.1: integration found the arming window opens ~1.1 s after speech offset
  (600 ms VAD redemption + ~0.5 s ASR), so a `speech_start` in the gap before
  it opened was ignored and the send still fired. Arming is now skipped
  outright in that case (action `send`, detail "arming skipped: speech
  resumed") — `8d67708`.

**v0.3 -> v0.4** — SPIKE 2b (wake-word robustness on the GB10 sync lane,
commit `4675905` in `/home/zach/transcription`, report `spike-asr/WAKEWORD.md`)
and SPIKE 3 (in-browser keyword spotting, commits `e5012a6` + `796b4b3`,
report `spikes/voice/kws/README.md`) folded in. The spike phase is complete;
what remains is two human measurements.

- Header: v0.4; status now records that SPIKEs 1, 2, 2b and 3 are all folded
  in, and names the two remaining human-in-the-loop checks.
- §4.1: the human AEC procedure re-pointed at the consolidated
  `spikes/voice/ACOUSTIC_TEST.md` part A, and the same number recorded as the
  gate on §5.2 as well as on rung 3 — SPIKE 3's 16/16 @ +10 dB, 7/16 @ 0 dB,
  2/16 @ -6 dB SNR results line up with the >15 dB / <6 dB decision points.
- §5.1: RESOLVED to option (b), the transcript phonetic tail-matcher —
  **REVERSING the interim post-SPIKE-2 recommendation of (a)**. Exact match is
  0.0% TP on all four commands over 190 observations; argmax of
  `max(Ratcliff-Obershelp, phonetic-key ratio)` over the last 1-3 space-stripped
  tokens at 0.85 gives 96.8% TP / 0 wrong-intent / 0.0% FP on 154 negatives.
  Per-phrase table, threshold sweep (0.80 / 0.85 / 0.90), the case for keeping
  the `orca` prefix (unprefixed phrases transcribe perfectly and FP at
  2.6-7.8%), the cost comparison against the spotter, and the one-synthetic-voice
  caveat all recorded.
- §5.1.1: NEW — the normative matcher reference (SPIKE 2b's `intent_ref.py`,
  verbatim) plus five rules for the port: spaces removed, argmax-then-threshold,
  `String.jaro_distance/2` is NOT a drop-in (0.90 @ 92.6% TP at best), 0.85 is
  a config knob, and strip command tokens from the draft.
- §5.2: RESOLVED to openWakeWord v0.5.1 at threshold 0.5, **playback-only and
  VAD-gated**. Porcupine recorded as licence-blocked before any technical
  question (no keyless built-ins — proved into the wasm, no personal/
  non-commercial plan, per-browser-instance billing, key ships to the client,
  plus a 3.0.0/4.0.0 `.ppn` version bug), with an explicit instruction never to
  backfill its unmeasured performance cells. openWakeWord's measured numbers,
  the 25-37%-of-a-core duty-cycle finding that forces playback-only, the
  training requirement for `orca stop` / `orca pause`, and the two
  implementation traps (int16-magnitude floats; the 480-sample overlap and
  `x/10 + 2`) recorded. Marked UNVALIDATED until ACOUSTIC_TEST.md part A runs.
- §6: v0.2's "opus faster than WAV (596 vs 930ms)" WITHDRAWN — it was two
  different clips (1.40s vs 5.92s). Controlled A/B shows flat 88-126ms
  non-server overhead across a 95x payload range and 53/56 vs 52/56 correct
  intents, so encoding is the implementer's choice. `initial_prompt` biasing
  recorded as still unmeasured and what it would take to measure.
- §6.1: ASR/TTS GPU contention added — 541ms p50 idle vs 842ms p50 while TTS
  synthesises (~1.55x); the budget now carries a ~850ms speaking-and-listening
  line and a ~1.4-1.8s total for that case.
- §7: pause the TTS prefetch pipeline while the mic is hot, for the same
  reason.
- §10: phase 1 exit criteria restated as ACOUSTIC_TEST.md parts A and B, with
  part B's >= 95% TP / 0 FP bar and the fallback to §5.1 option (a); phase 3
  is now openWakeWord, playback-only, VAD-gated; phase 4's go/no-go is part
  A's number.
- §11: SEND path, WAV-vs-opus and Porcupine-vs-openWakeWord marked ANSWERED;
  the remaining open questions narrowed to AEC on real hardware, the
  real-voice wake-word check, and `initial_prompt` biasing.
- NEW `spikes/voice/ACOUSTIC_TEST.md` — SPIKE 1's harness procedure and SPIKE
  2b's `--human` real-voice check merged into one ~10-minute numbered
  procedure with explicit PASS/FAIL thresholds and a paste-back template.

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

## 13. Phase 2c design notes: voice-driven navigation (C5)

**This section is now the DESIGN RECORD only — §8.3 is phase 2c's NORMATIVE
contract and supersedes everything below wherever the two differ.**

DESIGN ONLY. Nothing here is a contract yet — phase 2c is the design, and the
implementation is a later phase that will get its OWN normative contract in the
manner of §7.1-7.3 and §8.2. Recorded here so the design is not re-derived, and
because §5.1.1's correctness lives as much in the corpus as in the code.

Tracked as **ORCAHUB3-87**.

### 13.1 The shape (C5)

A "focus" concept in the hook (`composer | palette`). `orca search` / `orca open`
opens the Ctrl+K palette and routes transcript to its input (no server draft
accumulation while `focus = palette` — the channel gets `focus {target:
"palette"}` and treats transcripts as `query` events instead of draft appends).
Selection by spoken ordinal (the reliable path) with name matching as a bonus.
`orca back` / `orca sessions` / `orca new session`.

**Every new vocabulary entry must be scored against
`test/support/fixtures/voice/intent_corpus.json` (0 new FPs at 0.85) before it
ships.**

### 13.2 Motivating example and candidate vocabulary (from ORCAHUB3-87)

Voice mode phase 1 can only do one thing with your voice: accumulate a
transcript into the composer and send it ("orca send" / "orca cancel").
Everything else in the app still needs hands. The natural next step is to let
voice drive ordinary UI interaction, so a session can be operated end to end by
speech.

The motivating example from the user (2026-09-18): say "orca search" to open the
Ctrl+K command palette, speak the query, then speak to select one of the results
— a project, a session, an orchestrator — and navigate there. Generalising from
that: a spoken command vocabulary for navigation and selection, not just send.

Candidate commands worth scoping (not a committed list):

- "orca search" / "orca open" — raise the Ctrl+K palette and route subsequent
  transcript into its query input instead of the composer;
- selecting a result by spoken ordinal ("the third one") or by name, with the
  phonetic matcher doing the fuzzy work against the visible result labels;
- "orca back", "orca sessions", "orca new session";
- in-session chrome that currently needs a click: interrupt a running turn,
  toggle the terminal/file panels, switch tabs.

### 13.3 Design questions this will have to answer (from ORCAHUB3-87)

- Where does the transcript go when the palette is open? The draft sink is
  currently hard-wired to `#prompt-input` via the hook's `_draftSelector`; a
  mode/focus concept is needed so the same pipeline can target a different
  input, and so the server-side draft does not accumulate palette queries.
- `OrcaHub.Voice.Intent` is a phonetic matcher over a fixed command set with a
  tuned threshold and a 344-clip corpus
  (`test/support/fixtures/voice/intent_corpus.json`). Growing the vocabulary
  risks new false positives against ordinary dictation — every added command
  needs to be scored against that corpus, not just eyeballed.
- Matching a spoken selection against dynamic, arbitrary result labels (project
  names, session titles) is a different problem from matching a fixed command
  set, and probably wants ordinals as the reliable path with name matching as a
  bonus.
- Command adjudication is server-side in `OrcaHub.Voice.Session`, but navigation
  is a client concern — this needs a new client-directed effect/event in the
  OVS1 contract rather than another `{:send, text}`-shaped one.
- Discoverability: a spoken vocabulary nobody can see is unusable. Probably
  belongs in the voice strip's collapsed events area or a small help affordance.

### 13.4 Notes against the phase-2b baseline

Two of those questions get easier once §8.2 lands, and the design should assume
it: the draft sink is already indirected (§8.2's draft sink rule replaces the
hard-wired `#prompt-input`, so `focus = palette` is a third sink rather than a
new mechanism), and the voice bar already survives navigation, which is what
makes "speak a command, land on another page, keep talking" possible at all. The
client-directed effect the fourth question asks for is also the same shape as
§8.2's `send_request` — a server -> client instruction the client executes —
so that precedent, not `{:send, text}`, is the one to copy.

### 13.5 C5 addendum (from Zach, 2026-09-18): spoken COMPOSER control sequences, in-session

Beyond navigation, dictation needs a small set of spoken control sequences that
insert Orca-specific tokens into the composer draft rather than trigger an
action:

- "orca new line" (also accept "orca newline") -> append "\n" to the draft (no
  space-join around it); "orca new paragraph" -> "\n\n".
- "orca session search" (or "orca hashtag") -> append "#" to the draft, which is
  the composer's session-search autocomplete trigger; "orca project search" (or
  "orca double hashtag") -> append "##", the project-search trigger. The words
  spoken AFTER the trigger, in the same or the next segment, are the query; the
  draft mirror must dispatch a real `input` event so the composer's autocomplete
  hook opens exactly as if typed.
- Picking a result from the autocomplete: spoken ordinal ("orca first" / "orca
  second" / "orca the third one") as the reliable path; name matching as a
  bonus. This is the same selection mechanism as the palette in C5 — design ONE
  selection mechanism for both.
- Rules that carry over unchanged: two-word `orca` prefix; terminal-position
  matching on a completed segment; argmax-then-threshold on the phonetic
  matcher; EVERY new vocabulary entry scored against
  `test/support/fixtures/voice/intent_corpus.json` with 0 new false positives at
  0.85 before it ships; insertion commands strip themselves from the draft the
  way send/cancel do. Insertions are a NEW intent class ("insert" with a
  payload) in `OrcaHub.Voice.Intent` / `Voice.Session`, distinct from actions,
  and they must not open the arming window.
- Discoverability: the voice bar's help affordance lists the current vocabulary.

Still DESIGN ONLY, like the rest of §13. Note the dependency it creates on §8.2:
the `input`-event rule these insertions need is exactly the one §8.2 carries
over from §8.1, and the help affordance lives in the bar §8.2 introduces — so
this addendum assumes phase 2b has landed.
