# Voice Mode (phase 1)

Talk to a session: open mic -> client-side VAD cuts utterances -> GB10
transcribes each -> a phonetic matcher looks for "orca send" -> the accumulated
draft is QUEUED to the session. Half-duplex. `voice_mode_spec.md` is the design
spec and its §8.1 is the NORMATIVE wire contract shared by channel, hook and
panel; this file is the map and the invariants.

## Data Flow

```mermaid
sequenceDiagram
    participant WL as orca-capture worklet
    participant VAD as Silero v5<br>(vad-web FrameProcessor)
    participant Hook as Voice hook
    participant CH as VoiceChannel
    participant VS as Voice.Session<br>(pure)
    participant GB as GB10 sync lane<br>192.168.1.77:8000

    Note over WL: getUserMedia (AEC/NS/AGC) -> AudioContext
    WL->>WL: 63-tap LPF + decimate to 16 kHz;<br>ring buffer keyed by ABSOLUTE 16 kHz index
    WL->>VAD: 512-sample (32 ms) frames
    VAD-->>Hook: speech_start / speech_end (+500 ms pre-roll)
    Hook->>CH: "speech_start", then "segment"<br>(OVS1 binary: 20-byte header + int16 PCM)
    CH->>VS: segment_received/3 -> {state, effects}
    VS-->>CH: {:dispatch, seq, pcm} (after merge/pad/drop)
    CH->>GB: Voice.ASR.transcribe/2 in a Task<br>POST /v1/transcribe/sync (WAV wrapped server-side)
    GB-->>CH: {text, duration, elapsed_seconds, ...}
    CH->>VS: transcript/4 in DISPATCH order;<br>Voice.Intent -> nil | :send | :cancel | :stop | :pause
    VS-->>CH: {:segment_result, _}; {:send, draft} after the 1500 ms arming window
    CH->>CH: Cluster.send_message(runner_node, id, draft, :queue)
    CH-->>Hook: "state" + "segment_result" + "sent"
```

## Module map

- `channels/voice_channel.ex` — thin adapter: decodes OVS1 frames, runs ASR in
  a `Task`, owns both timers via one idempotent `:tick`, pushes events, holds
  the ownership claim, refuses to re-route.
- `voice/session.ex` — the PURE state machine: draft, arming window,
  short-segment hold/merge, `seq`-ordered result application. Returns `{state,
  effects}`; no sockets, tasks, timers or HTTP.
- `voice/asr.ex` — HTTP client for the GB10 sync lane; wraps PCM in a 44-byte
  WAV header, re-enforces the 0.8 s floor / 20 s cap, never raises.
- `voice/intent.ex` — terminal-position phonetic matcher, a port of SPIKE 2b's
  `intent_ref.py` (`intent/2`, `strip_command/3`).
- `asr_config.ex` — hub-managed config, sibling of `TTSConfig`.
- `assets/js/voice/*.js` — capture + resample, VAD, OVS1 encoding, channel
  client, asset URLs, the `Voice` hook (`wav.js` is offline verification only).
- `session_live/show.{ex,html.heex}` — renders `#voice-panel` (the
  `data-voice-*` DOM contract) behind `toggle_voice`; that plus the
  `orca:tts-state` emit in `app.js` is the WHOLE LiveView involvement.

## Wire contract (summary — §8.1 is normative)

- Existing `UserSocket` at `/terminal_socket` (shared
  `window.__terminalSocket`); topic `voice:<session_id>`, no client_ref suffix.
  Internal PubSub must use the `voice_state:` prefix — never `voice:`, which
  double-delivers (see `.context/terminals.md`).
- `"segment"` is a RAW binary payload, no base64: little-endian 20-byte header
  `"OVS1" | seq | start_sample | sample_count | flags` (bit0 forced_end at 18 s,
  bit1 client-padded), then 16 kHz mono int16 PCM. Client ships PCM, the SERVER
  adds the WAV header.
- Client -> server: `speech_start`, `mic`, `send_now`, `cancel`, `draft_edit`,
  `retry_warmup`. Server -> client: `state` (the FULL snapshot, after every
  change), `segment_result` (one per segment, with the `action` taken), `sent`.
  Join errors: `not_found | voice_owned | node_unavailable | archived`. Joining
  IS arming — the warm-up ping fires at once (cold start up to 35 s).

## Config surface

`ASRConfig.resolve/0` -> `%{url, path, language, timeout_ms,
warmup_timeout_ms, threshold}`, resolved PER FIELD: DB row (`asr_provider`) >
`ASR_*` env > hardcoded default, no cache, deliberately. No `model` field — the
lane offers no model selection. The channel resolves once at join and again on
`retry_warmup` (via `HubRPC`; agent nodes have no DB), so a change lands on the
next join, not mid-utterance. `threshold` (0.85) is the matcher knob.

## Invariants that bite

- **The VAD settings are non-default and load-bearing**: `model: 'v5'`,
  `0.5/0.35`, `redemptionMs: 600`, `preSpeechPadMs: 500`, `minSpeechMs: 250`.
  The defaults measured EOS 1376 ms (2x budget) and silently discard a bare
  "stop". Never drop back.
- **Resample from `ctx.sampleRate`, never `/3` or 48000** — context and track
  negotiate independently (measured ratio 2.75625), and a wrong ratio
  pitch-shifts the audio into plausible WRONG WORDS rather than failing.
- **Two silent zero-frame traps in the worklet.** `performance` does not exist
  in `AudioWorkletGlobalScope` — one `performance.now()` in `process()` makes
  Chrome stop calling it FOREVER with no error (use `currentTime`/`Date.now()`);
  and a node with no path to `ctx.destination` is never pulled at all, which is
  why the `GainNode({gain: 0})` into `destination` is load-bearing, not dead
  code.
- **0.8 s floor / 20 s cap / `elapsed_seconds < 0.05` = silence.** Sub-0.8 s
  clips hallucinate ("archives.", "R."), so a short segment is held 1500 ms and
  MERGED, else dispatched if client-padded, else `dropped_short` — never padded
  with synthesized silence.
- **Matcher: argmax THEN threshold, spaces removed, Ratcliff-Obershelp — not
  Jaro** (whose best zero-FP point is 0.90 @ 92.6% TP vs 0.85 @ 96.8%).
  `intent_test.exs` replays all 344 SPIKE 2b clips and pins intent AND score to
  1.0e-9 against the Python reference; the 6 misses at 0.85 are the
  REFERENCE's. Never "fix" them — parity IS the acceptance test.
- **The arming window opens LATE, so it is also skipped retroactively**: the
  command segment only closes 600 ms after speech offset (VAD redemption) and
  its ASR round trip costs ~0.5 s, so the 1500 ms window really runs ~1.1 s ->
  ~2.6 s after the user stopped talking. `speech_start` cancels an OPEN window;
  an onset in the ~0.6-1.1 s gap before it opens makes `Voice.Session` not arm
  at all (`segment_result` action `send`, detail "arming skipped: speech
  resumed"). Speech resuming inside the first 600 ms merges into the same
  segment, so no command is detected at all.
- **Sending is `:queue`, never `:interrupt`** (`TriggerExecutor` precedent): a
  spoken "send" must not cancel an in-flight turn.
- **Join-time refusals, never workarounds**: no re-routing when the session's
  node is unavailable (`node_unavailable`), and exactly ONE voice owner per
  session via a `%{voice: true}` claim in `SessionViewersRegistry`, released
  when the channel exits. That registry is PER NODE, so the claim covers the
  node that served the page.
- **Half-duplex via `orca:tts-state`**: `app.js` dispatches it on every
  playback transition; the hook pauses the VAD, drops frames and pushes
  `mic {muted, reason: "tts"}`, and the server drops segments while muted.
- **`getUserMedia` needs a secure origin**: the https ingress or
  `http://localhost:4000`, never `http://192.168.1.x:4001`, where
  `navigator.mediaDevices` is simply `undefined` and nothing throws. Instances
  run on LAN hosts on 4001, so this WILL be hit; the panel shows a red banner.

## Asset packaging

vad-web 0.0.31 and onnxruntime-web 1.29.0 are pinned exactly. A second esbuild
profile, `orca_hub_voice` (`config/config.exs`, in `assets.build`/
`assets.deploy`), bundles `capture-worklet.js` (which must stay a separate file
— `addModule()` takes a URL) and COPIES ort's `.mjs`/`.wasm` plus
`silero_vad_v5.onnx` into `priv/static/assets/voice/`. `--entry-names=[name]`
keeps the UNdigested names, since ort and vad-web build those URLs themselves;
immutable caching is bought back with a version-stamped `?vsn=` query
(`paths.js`). `.wasm`/`.onnx`/`.mjs` are in `:gzippable_exts`, so `phx.digest`
gzips them and `Plug.Static` serves the `.gz`. Cost: ~16 MB raw / ~5.5 MB
gzipped in the release, ~3.6 MB of it ort's wasm — first load only.

## DEPLOYMENT PRECONDITION (reachability verified 2026-09-17)

ASR runs in the `VoiceChannel` process (`Task.start`, `voice_channel.ex`
~161/~217), so only the websocket-terminating node needs the lane — in prod the
k3s **`orca-hub` pod** alone (agent-mode nodes 404 every page route via
`:agent_mode_gate`, `endpoint.ex` 14-28; port-4001 LAN instances fail
`getUserMedia`'s secure-origin rule). The URL is a config knob (`asr_provider`
row > `ASR_URL` env > default), so any FQDN resolving from the pod works — not
`ai.lab.ingbretsenhome.com` though, which proxies TTS only.
Reachability VERIFIED 2026-09-17 from inside the pod: `curl
http://192.168.1.77:8000/healthz` -> 200 in ~5 ms, sync lane ready, CUDA up; no
NetworkPolicy in `lab` selects `orca-hub`. `~/homelab/k3s/apps/gb10.yaml` also
gives `http://whisperx-external.lab.svc.cluster.local:8000` and
`https://transcription.lab.ingbretsenhome.com` (no Authelia, so localhost dev
works too) — all three are valid. TRAP: `gb10.lab.ingbretsenhome.com` resolves
to the debian Traefik wildcard 192.168.1.177, not the GB10 — port 8000 refused.

## Out of scope / still pending

Phase 1 is all that exists. NOT built: streaming TTS off assistant deltas
(2), openWakeWord stop/pause during playback (3), AEC / duck-on-detect / open
channel (4), the LLM adjudicator (5). `:stop`/`:pause` are recognized and
stripped from the draft but take no action.

**Phase 1 EXIT CRITERIA are still pending a human** — both parts of
`spikes/voice/ACOUSTIC_TEST.md`: Part A (browser AEC suppression on real
hardware, which also gates phases 3-4) and Part B (the real-voice matcher
check, >= 95% TP and 0 FP at 0.85). The 96.8%/0.0% numbers above are one
synthetic voice, an upper bound until Part B runs.
