# Voice Mode — Design Spec (DRAFT, v0.1)

Status: DRAFT, pending spike results. Author: orchestrator handoff, 2026-09-14.
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
  per-session pinning. Reuse for the voice bearer; do not invent new auth.
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

1. Whisper HALLUCINATES on silence and noise — it emits "Thank you." /
   "Thanks for watching!" / subtitle-credit text from training data. Feeding it
   open-mic audio produces phantom utterances that look like real transcripts.
   VAD gating is the fix at the source.
2. Raw 48kHz PCM is ~1.5 Mbps and would be mostly silence.
3. GB10 stays idle between utterances.

Use Silero VAD (~2MB ONNX) via onnxruntime-web; `@ricky0123/vad-web` packages
it. Do NOT roll an energy threshold. Do NOT use the legacy WebRTC GMM VAD.

Ring-buffer ~500ms of PRE-ROLL. VAD fires after speech has begun; without
pre-roll the first phoneme of every utterance is clipped and "send" becomes
"end". This is a known, cheap, easy-to-forget bug.

Belt-and-braces even with VAD: filter ASR results on `no_speech_prob`,
`avg_logprob`, `compression_ratio`, plus a small hallucination blocklist.

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

Cheap layer first, and it is probably sufficient:

- TWO-WORD WAKE PREFIX: "orca send", "orca cancel". Bare "send" is a common
  English word; "orca send" is not. This alone kills most false positives.
- MATCH ONLY AT TERMINAL POSITION of a completed VAD segment. "Send the email
  to Bob" cannot fire because `send` is not last. This single heuristic does
  more work than any model.
- Strip command tokens from the draft before submitting.
- ARMING WINDOW: on SEND, show a ~1.5s countdown chip that any further speech
  cancels. Removes the entire "it sent too early" pain class. Default ON for
  SEND only; configurable.

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

PATH A (v1) — UTTERANCE-LEVEL, NOT STREAMING. VAD supplies segment
boundaries; each utterance is one ASR call. `whisper-large-v3-turbo` via
faster-whisper is fine on Blackwell. This matches the actual UX: talk,
utterances accumulate into a draft, say send. Word-level streaming partials
are NOT needed for that, and chasing them first will cost weeks.

PATH B (later, if true streaming is wanted) — NVIDIA Parakeet /
FastConformer-TDT via NeMo. Genuinely streaming (RNNT/TDT) rather than 30s
window models, NVIDIA's own so aarch64 Blackwell is first-class, and
Parakeet-TDT-0.6B is both top-of-leaderboard for English and very fast.
NVIDIA Riva packages streaming ASR + TTS + endpointing in one aarch64
container if buying beats building.

GB10 is ARM64 (aarch64) Grace + Blackwell, 128GB unified memory, at
192.168.1.77. x86 images/binaries will not run. It is the shared local AI
backend and already serves Whisper transcription and TTS in some form — the
spike must establish WHAT, exactly.

### 6.1 Latency budget (path A, end-of-speech to message sent)

| Stage | Target |
|---|---|
| VAD endpointing | 500-700ms **(dominates — main tuning knob)** |
| transport (LAN) | ~20ms |
| ASR | 100-300ms |
| intent (string match) | ~0ms |
| **total** | **< 1s** |

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
- AUTH: mint a SESSION-PINNED `ApiToken` with a new `voice` scope; push the
  bearer to JS the way `tts-config` already does. Do not add a second auth
  mechanism.
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
3. Whisper silence hallucinations (section 3.2).
4. VAD pre-roll clipping (section 3.2).
5. Sample-rate mismatch: mic is 48kHz, ASR wants 16kHz mono — resample in the
   AudioWorklet, not on the server.
6. Mobile Safari AudioWorklet/getUserMedia quirks — explicitly out of scope
   for v1, but do not architect in a way that forecloses it.

## 10. Phasing

1. Mic -> Silero VAD -> utterance -> GB10 ASR -> draft box. Half-duplex.
   Terminal-position "orca send"/"orca cancel" string matching, arming window.
   **This is a usable product and most of the value.**
2. Streaming TTS off assistant deltas + speakable-content policy.
3. Porcupine wake-word path for stop/pause during playback.
4. Browser AEC + text-domain echo rejection -> duck-on-detect -> open channel.
5. LLM intent adjudicator, only if phase 1 heuristics prove insufficient.

## 11. Open questions for the finalizing orchestrator

- Does GB10 currently expose an OpenAI-compatible `/v1/audio/transcriptions`,
  or something else? What model, what latency at 3-10s utterances?
- Is `@ricky0123/vad-web` acceptable as a dependency, or should Silero be
  wired to onnxruntime-web directly? What is the bundle-size cost?
- Porcupine requires a Picovoice access key (free tier). Acceptable, or is
  openWakeWord the right call despite being Python-first?
- Does browser AEC actually suppress our TTS adequately on Zach's real
  hardware, or is half-duplex the permanent answer?
