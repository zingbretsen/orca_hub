# Voice Mode — Design Spec (DRAFT, v0.2)

Status: DRAFT — SPIKE 2 (GB10 ASR) folded in; SPIKE 1 (browser capture), 2b
(wake-word), 3 (keyword spotter) pending. Author: orchestrator handoff,
2026-09-14.
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

There is NO existing microphone, VAD, ASR, or audio-capture code anywhere in
the tree (grep for whisper/transcri/getUserMedia/AudioWorklet/MediaRecorder
returns only unrelated `memory_extraction` hits).

## 3. Architecture

Browser does capture, VAD, and wake-word spotting. Server does ASR dispatch,
intent adjudication, and TTS orchestration. GB10 serves ASR + TTS over HTTP.

    mic -> AudioWorklet (48k -> 16k mono, ring buffer w/ pre-roll)
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

Use Silero VAD (~2MB ONNX) via onnxruntime-web; `@ricky0123/vad-web` packages
it. Do NOT roll an energy threshold. Do NOT use the legacy WebRTC GMM VAD.

Ring-buffer ~500ms of PRE-ROLL. VAD fires after speech has begun; without
pre-roll the first phoneme of every utterance is clipped and "send" becomes
"end". This is a known, cheap, easy-to-forget bug.

Belt-and-braces even with VAD — but NOT the v0.1 filter, which is
unimplementable here: the sync lane returns no `no_speech_prob`,
`avg_logprob` or `compression_ratio`, and WhisperX's batched pipeline cannot
produce them (section 6). The two signals that DO exist:

- A HARD MINIMUM SEGMENT DURATION FLOOR of ~0.8s before dispatch. Short
  fragments are the real hallucination mode on this endpoint: a 0.3s cut of
  "Orca" returned `"archives."`, a 0.2s cut returned `"R."`, while anything
  above ~0.8s transcribed correctly. Drop sub-floor segments client-side;
  never send them.
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
   this WILL be hit. Test on localhost or through the https ingress.
2. **Autoplay policy** requires a user gesture before audio can play. The
   "start voice mode" button satisfies it; do not auto-arm on page load.
3. Short-fragment hallucination — sub-0.8s segments transcribe as garbage
   ("archives.", "R."); silence itself is safe (section 3.2).
4. VAD pre-roll clipping (section 3.2).
5. Sample-rate mismatch: mic is 48kHz, ASR wants 16kHz mono — resample in the
   AudioWorklet, not on the server.
6. Mobile Safari AudioWorklet/getUserMedia quirks — explicitly out of scope
   for v1, but do not architect in a way that forecloses it.

## 10. Phasing

1. Mic -> Silero VAD -> utterance -> GB10 ASR -> draft box. Half-duplex.
   SEND via whichever path section 5.1's DECISION resolves to, plus the arming
   window. **This is a usable product and most of the value.**
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
- Is `@ricky0123/vad-web` acceptable as a dependency, or should Silero be
  wired to onnxruntime-web directly? What is the bundle-size cost?
- Porcupine requires a Picovoice access key (free tier). Acceptable, or is
  openWakeWord the right call despite being Python-first?
- Does browser AEC actually suppress our TTS adequately on Zach's real
  hardware, or is half-duplex the permanent answer?

## 12. Changelog

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
