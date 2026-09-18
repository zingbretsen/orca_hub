# Voice Mode (phase 1 deployed; phase 2 / 2b landed)

Talk to a session: open mic -> client-side VAD cuts utterances -> GB10
transcribes each -> a phonetic matcher looks for "orca send" -> the accumulated
draft is QUEUED to the session. Half-duplex. `voice_mode_spec.md` holds the
contracts (§8.1 the wire contract, §7/§8.2 phase 2/2b); this file is the map
and the invariants — phase 1 first, then "Phase 2 / 2b" at the bottom.

## Data flow

`orca-capture` worklet (63-tap LPF, decimate to 16 kHz, ring buffer keyed by
ABSOLUTE 16 kHz index) -> Silero v5 via vad-web, 512-sample (32 ms) frames ->
`speech_start`/`speech_end` (+500 ms pre-roll) -> the `Voice` hook pushes
`"speech_start"` then `"segment"` (OVS1 binary) -> `VoiceChannel` ->
`Voice.Session.segment_received/3` -> `{:dispatch, seq, pcm}` after
merge/pad/drop -> `Voice.ASR.transcribe/2` in a `Task` ->
`Voice.Session.transcript/4` in DISPATCH order -> `Voice.Intent` ->
`nil | :send | :cancel | :stop | :pause` -> `{:send, draft}` after the 1500 ms
arming window -> `send_request` to the client (phase 1 delivered it server-side
with `Cluster.send_message(node, id, draft, :queue)`).

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
- `live/voice_bar_live.ex` — the GLOBAL voice bar (phase 2b, §8.2 /
  ORCAHUB3-88): one sticky nested LiveView `live_render`ed in the app header
  (`layouts.ex`, `container: {:div, class: "contents"}`), so the mic, the
  `AudioContext`, the VAD session and the `voice:<id>` channel survive live
  navigation. It renders `#voice-panel` (the whole `data-voice-*` DOM
  contract), the mic button, the target picker and the bar's own draft box; the
  hook-written part is an inner `#voice-strip` under `phx-update="ignore"`,
  since the root must stay patchable — `data-target-session-id` is the single
  source of truth for the target.
- `session_live/show.{ex,html.heex}` — NO voice state since 2b (no
  `toggle_voice`, no `:voice_mode`, no panel), only three stateless seams:
  `data-voice-composer-for` on the composer form (draft sink + send target), a
  `voice-target` push on mount, and `voice-send-failed {reason}` on a failed
  delivery. There is no `terminate` push (`terminate/2` cannot `push_event`) —
  the signal that a page stopped being a session page is its composer
  DISAPPEARING from `body[data-voice-composer-for]`.

## Wire contract (summary — §8.1 is normative)

- Existing `UserSocket` at `/terminal_socket` (shared
  `window.__terminalSocket`); topic `voice:<session_id>`, no client_ref suffix.
  Internal PubSub must use the `voice_state:` prefix — never `voice:`, which
  double-delivers (see `.context/terminals.md`).
- `"segment"` is RAW binary, no base64: little-endian 20-byte header
  `"OVS1" | seq | start_sample | sample_count | flags` (bit0 forced_end at 18 s,
  bit1 client-padded), then 16 kHz mono int16 PCM — the SERVER adds the WAV
  header.
- Client -> server: `speech_start`, `mic`, `send_now`, `cancel`, `draft_edit`,
  `retry_warmup` + 2b's `sent_ack`, `send_failed`, `send_direct`, `composer`.
  Server -> client: `state` (the FULL snapshot, after every change),
  `segment_result` (one per segment, carrying its `action`), `sent` + 2b's
  `send_request`. Join errors:
  `not_found | voice_owned | node_unavailable | archived`. Joining IS arming —
  the warm-up ping fires at once (cold start up to 35 s). Retarget is
  leave+join; there is no `retarget` event.

## Config surface

`ASRConfig.resolve/0` -> `%{url, path, language, timeout_ms,
warmup_timeout_ms, threshold}`, resolved PER FIELD: DB row (`asr_provider`) >
`ASR_*` env > default, no cache, deliberately. No `model` field — the lane
offers none. The channel resolves at join and on `retry_warmup` (via `HubRPC`;
agent nodes have no DB), so a change lands on the next join, not mid-utterance.
`threshold` (0.85) is the matcher knob.

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
  and a node with no path to `ctx.destination` is never pulled, which is why the
  `GainNode({gain: 0})` into `destination` is load-bearing, not dead code.
- **0.8 s floor / 20 s cap / `elapsed_seconds < 0.05` = silence.** Sub-0.8 s
  clips hallucinate ("archives.", "R."), so a short segment is held 1500 ms and
  MERGED, else dispatched if client-padded, else `dropped_short` — never padded
  with synthesized silence.
- **Matcher: argmax THEN threshold, spaces removed, Ratcliff-Obershelp — not
  Jaro** (best zero-FP point 0.90 @ 92.6% TP vs 0.85 @ 96.8%).
  `intent_test.exs` replays all 344 SPIKE 2b clips and pins intent AND score to
  1.0e-9 against the Python reference; the 6 misses at 0.85 are the
  REFERENCE's. Never "fix" them — parity IS the acceptance test.
- **The arming window opens LATE, so it is also skipped retroactively**: 600 ms
  VAD redemption + ~0.5 s ASR means the 1500 ms window really runs ~1.1 s ->
  ~2.6 s after the user stopped talking. `speech_start` cancels an OPEN window;
  an onset in the ~0.6-1.1 s gap before it opens makes `Voice.Session` not arm
  at all (action `send`, detail "arming skipped: speech resumed").
- **Sending is `:queue`, never `:interrupt`** (`TriggerExecutor` precedent): a
  spoken "send" must not cancel an in-flight turn. Phase 2b moved WHO delivers
  (the composer, not the server), not this.
- **The draft lives in a composer textarea the hook does not own.** It belongs
  to `Autocomplete` inside a `phx-update="ignore"` wrapper, so every write is
  followed by a bubbling `input` event (a bare `.value =` skips the autoresize),
  guarded against echoing back as a `draft_edit`, and delegated on `document`
  rather than bound to an element that moves between pages. Merge rule, chosen
  because it cannot destroy typing: composer edits push `draft_edit` (300 ms
  debounce) and seed the server at every join (retarget makes joins routine),
  and an empty `state.draft` NEVER empties a non-empty composer — clearing is
  explicit only (`"sent"`, a `cancel` segment_result, `clear-prompt`). The
  bar's OWN box is scratch space, not protected text: a draft carried across a
  retarget out-votes it, and it is cleared whenever it is not the sink.
- **Join-time refusals, never workarounds**: no re-routing when the session's
  node is unavailable (`node_unavailable`), and exactly ONE voice owner per
  session via a `%{voice: true}` claim in `SessionViewersRegistry` (PER NODE, so
  it covers the node that served the page), released when the channel exits.
- **Half-duplex via `orca:tts-state`**: `app.js` dispatches it on every
  playback transition; the hook pauses the VAD, drops frames and pushes
  `mic {muted, reason: "tts"}`, and the server drops segments while muted.
- **`getUserMedia` needs a secure origin**: the https ingress or
  `http://localhost:4000`, never `http://192.168.1.x:4001`, where
  `navigator.mediaDevices` is simply `undefined` and nothing throws. Instances
  run on LAN hosts on 4001, so this WILL be hit; the bar shows a red banner.

## Asset packaging

vad-web 0.0.31 and onnxruntime-web 1.29.0 are pinned exactly. A second esbuild
profile, `orca_hub_voice` (`config/config.exs`), bundles `capture-worklet.js`
(must stay a separate file — `addModule()` takes a URL) and copies ort's
`.mjs`/`.wasm` + `silero_vad_v5.onnx` into `priv/static/assets/voice/`.
`--entry-names=[name]` keeps those names UNdigested, since ort and vad-web
build the URLs themselves; caching is bought back with a `?vsn=` query
(`paths.js`), and the three extensions are in `:gzippable_exts`. Cost ~5.5 MB
gzipped, ~3.6 MB of it ort's wasm — first load only.

## DEPLOYMENT PRECONDITION (reachability verified 2026-09-17)

ASR runs in the `VoiceChannel` process (`Task.start`), so only the
websocket-terminating node needs the lane — in prod the k3s **`orca-hub` pod**
alone (agent-mode nodes 404 every page route; port-4001 LAN instances fail
`getUserMedia`'s secure-origin rule). VERIFIED 2026-09-17 from inside the pod:
`http://192.168.1.77:8000/healthz` -> 200 in ~5 ms, CUDA up, egress
unrestricted. The URL is a config knob; two other valid targets and one DNS
trap (`gb10.lab.ingbretsenhome.com` is the debian Traefik wildcard, NOT the
GB10) are in spec §8 — read it before changing it.

## Phase 2 / 2b (landed, `113fa91`)

Phase 1 is what is DEPLOYED (`d679c12`). Phase 2 (streaming deltas + streaming
TTS, §7.1-7.3 / C1-C3) and phase 2b (global bar + single send path, §8.2 / C4)
are IMPLEMENTED, integration-verified 9/9 on the real page at
`0e64e67`+`113fa91`. The contracts stay in the spec (§10.5 maps contract ->
phase -> section); here is the shape and the traps.

- **Deltas (C1).** Each backend's `normalize/2` folds its native
  partial-output frames into ONE kind, `"orca_delta"`
  (`OrcaHub.Backend.Deltas`, advertised by `Capabilities.streaming_deltas`);
  one `SessionRunner` clause fans those out as the five C1 tuples
  (`assistant_stream_start`/`_block_start`/`_delta`/`_block_stop`/`_stream_stop`)
  on the EXISTING `session:<id>` topic. Never persisted, never accumulated,
  never in `turn_result`; `stream_id == message.id` of the persisted
  `assistant` event is the only correlation (Claude reuses the API id, Codex/pi
  mint a UUID and stamp it into the normalized event too); TEXT blocks only.
- **Client (C2/C3).** `SessionLive.Show` pushes each tuple as one
  `assistant-stream` event (no per-delta assigns); `AssistantStreamMethods`,
  mixed into the feed hook, owns `#stream-<stream_id>` in the
  `phx-update="ignore"` `#assistant-stream-slot` and re-dispatches every
  payload as a `window` `orca:assistant-stream` CustomEvent, so TTS never
  couples to feed DOM. `assets/js/tts_stream.js` is the pure accumulator —
  fence tracking, release on a sentence boundary >= 40 chars / a clause
  boundary past 240 chars / 1500 ms idle with >= 20 chars (a 500 ms tick fires
  that last rule during silence) — behind the "Speak while streaming" toggle
  (`orca:tts-stream`, off by default). At `stream_stop` the queue re-keys onto
  the persisted id.
- **Single send path (C4).** The server stops delivering the draft: it pushes
  `send_request {text}` and the client `requestSubmit()`s the REAL composer
  form, so staged uploads and `[Attached image: …]` lines ride along, then
  answers `sent_ack` (seen via `phx:clear-prompt` — LiveView dispatches every
  `push_event` on `window`, so the session page needs no bridging code) or
  `send_failed {reason}`. With no composer for the target it pushes
  `send_direct` and the server delivers as in phase 1. The target follows
  navigation on a page-session-id CHANGE only (an unconditional sync fights the
  picker); retarget is leave+join carrying the draft client-side.

More invariants that bite:

- **Every internal link must live-navigate** (`<.link navigate>`,
  `JS.navigate`, `push_navigate`). One plain `<a href>` to an in-app route
  reloads the document and takes the bar, the mic, the `AudioContext` and the
  channel with it. External links and downloads stay anchors.
- **A spoken command needs its OWN segment**: the matcher fires only at the
  TAIL of a completed segment, and speech resuming inside the 600 ms redemption
  merges into the previous one — dictation then "orca send" is TWO segments.
- **Mark a message spoken on its FIRST chunk, not at the re-key**: end-of-turn
  `tts-autoplay` can land before the persisted message renders (measured: stop
  2038 ms, DOM 2079 ms, autoplay ~2100 ms), so suppression that waits for that
  render loses the race and reads the whole message again.
- **Every host of the shared `TTSMethods` must accept every push it makes.**
  `ttsMountShared` pushes `tts_stream_init`; `QueueLive` had no clause, so every
  connect raised and killed the LiveView, discarding the `tts_autoplay_init`
  pushed one line earlier (`113fa91`). `ScrollToBottom` and `TTSFeed` are the
  only hosts.
- **Header budget: 48 px idle / 64 px armed = a 16 px strip at 390 px**,
  re-measured with `getBoundingClientRect`, never a screenshot. `gap-y-0`, the
  height-clamped picker and the hide-until-nonempty draft box each pay a third
  of it, and the bar is on EVERY page.
- **The ASR prefetch gate is a courtesy, not correctness**:
  `orca:voice-asr-busy` holds only NEW synthesis, only for 4000 ms, so a missed
  `{busy: false}` cannot wedge playback.

Phase 2c (§13 / C5, ORCAHUB3-87) is next and DESIGN ONLY — voice navigation
plus spoken composer control sequences; new vocabulary must score 0 new FPs at
0.85 against `test/support/fixtures/voice/intent_corpus.json`. Phases 3-5 are
unbuilt (openWakeWord stop/pause, AEC / duck-on-detect, the LLM adjudicator);
`:stop`/`:pause` are recognized and stripped but take no action. **Phase 1's
EXIT CRITERIA still await a human** — `spikes/voice/ACOUSTIC_TEST.md` Part A
(real-hardware AEC) and Part B (real-voice matcher, >= 95% TP / 0 FP at 0.85;
the 96.8%/0.0% above is one synthetic voice, an upper bound). They gate phases
3-4, not phase 2.
