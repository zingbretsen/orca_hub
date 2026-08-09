# TTS Rewrite Spec

Read-only survey + proposal. No source files changed by this document.

## 1. Inventory (13 files reference TTS)

| File | Role |
|---|---|
| `lib/orca_hub_web/controllers/tts_controller.ex` | `POST /api/tts` — proxies text to ElevenLabs, streams mpeg back |
| `lib/orca_hub_web/router.ex:80` | Route registration, `:api` pipeline (see §3.5) |
| `assets/js/app.js:692-967` | `TTSPlayer` hook (per-message player: chunking, fetch, playback, cache) |
| `assets/js/app.js:654-664` | `ScrollToBottom` hook's `tts-autoplay` handler — DOM query to find "last" player |
| `lib/orca_hub_web/components/message_components.ex:247-282` | Renders the per-message TTS footer + `phx-hook="TTSPlayer"` (assistant messages only) |
| `lib/orca_hub_web/components/markdown.ex` | Not actually TTS-specific — `split_blocks`/`join_blocks` are generic markdown helpers with no TTS caller; likely a false positive from the original grep. No TTS-related code found in this file. |
| `lib/orca_hub_web/live/session_live/show.ex:98,760-762,1886-1890,300-310` | `:tts_autoplay` assign, toggle handler, autoplay push on turn-idle, and a comment documenting the per-message-hook mount-cost tradeoff |
| `lib/orca_hub_web/live/session_live/show.html.heex:970-974` | Header toggle button |
| `lib/orca_hub_web/live/queue_live.ex:33-34,358-364,414-440` | Second, independent TTS surface: `:tts_autoplay` / `:tts_autoplay_pending` assigns, its own toggle handler, autoplay-on-new-entry logic |
| `lib/orca_hub_web/live/queue_live.html.heex:98-157` | Duplicate copy-pasted TTS footer markup (same SVGs, same `data-tts-*` attrs) |
| `config/runtime.exs:114-118` | `ELEVENLABS_API_KEY` / `ELEVENLABS_VOICE_ID` env config |
| `.env.example:25-27` | Documents the two env vars (commented out — opt-in) |
| `README.md:113-114` | Env var table entries |
| `.context/architecture.md:24,100,108,171` | `TTSController` node in the architecture diagram |

No test files reference TTS anywhere in `test/`.

## 2. What it actually does today

**End-to-end flow (session page):** user clicks the speaker icon in a message's
footer → `TTSPlayer.toggle()` → `start()` extracts `innerText` from the
adjacent `[data-tts-text]` markdown bubble, runs it through
`cleanTextForTTS()` (regex-based markdown/programming-term normalization —
strips code fences, expands `HEEx`→"heeks", `phx`→"phoenix", turns
`file_name.ex`→"file name dot ex", etc.), then `splitIntoChunks()` splits on
sentence boundaries with an 80-char minimum bucket size. Each chunk is
fetched **on demand** via `fetch("/api/tts", {text})` (one HTTP round-trip
per chunk, one-ahead prefetch), converted to a blob URL, played through a
fresh `Audio()` element, and the next chunk is fetched while the current one
plays. `TTSController.create/2` synchronously proxies to ElevenLabs
(`eleven_turbo_v2_5`, 30s timeout) and streams the whole MP3 back — there is
no server-side caching and no streaming (the entire clip is generated before
any byte reaches the browser).

**Autoplay:** session page — `show.ex:1886` pushes a `"tts-autoplay"` client
event whenever a turn ends (status → idle) and `:tts_autoplay` is true. The
`ScrollToBottom` hook (not `TTSPlayer` itself) catches it, waits 200ms for
DOM patch settling, does `querySelectorAll("[phx-hook='TTSPlayer']")` over
the *entire* feed container, and clicks the toggle button on the last one.
Queue page — separate logic (`queue_live.ex:414-440`): when the entry list
transitions from empty to non-empty while autoplay is on, the newest card
(index 0) renders with `data-tts-autoplay` already set, and `TTSPlayer.mounted()`
self-starts. Two independent, non-shared implementations of "autoplay the
newest thing."

**No persistence anywhere:** `:tts_autoplay` is a plain LiveView socket
assign on both pages — it resets to `false` on every mount (page load,
reconnect, navigation). A user who wants autoplay must re-toggle it every
session.

**Queue page:** fully duplicated markup/hook usage, not shared with the
session page beyond the JS hook itself.

## 3. Where the jank is

### 3.1 One hook instance per message (`message_components.ex:255`, `app.js:692`)
Every assistant message with text unconditionally renders
`phx-hook="TTSPlayer" phx-update="ignore"` (message_components.ex:255),
regardless of whether the user has ever touched TTS. Each mount allocates a
JS object with 6 fields (`audio`, `chunks`, `currentIndex`, `playing`,
`audioCache`, `abortController`) and binds a click listener. Cost scales
with *rendered* message count, not usage — this is bad but bounded now that
`show.ex` windows the feed to `@window_size = 20` (a sibling worker is
actively adding pagination on top of that same window; see
`show.ex:300-310`, which already calls this out by name as the reason
buffered older pages aren't silently merged into the DOM). Before windowing
existed this scaled with entire conversation length; today it's capped at
~20 hook instances live at once per session view, which is a real
mitigation but doesn't fix the fundamental one-hook-per-message design.

### 3.2 O(n) DOM scan to find "the last player" (`app.js:657`)
`ScrollToBottom`'s `tts-autoplay` handler does
`this.el.querySelectorAll("[phx-hook='TTSPlayer']")` over the whole feed on
every turn-completion when autoplay is on, then indexes `[length - 1]`. This
couples scroll behavior to TTS internals (a hook that has nothing to do with
audio is the one dispatching playback), and is fragile: it assumes DOM order
== chronological order and that the *last mounted TTSPlayer* is the *newest
assistant message*, which breaks the moment older pages get spliced back in
above it (exactly what the incoming pagination work does) or if a
non-text-only final message (e.g., a tool-only turn) has no player to find
at all.

### 3.3 Client-side regex chunking, duplicated nowhere else (`app.js:719-746, 755-815`)
`splitIntoChunks` is a naive sentence-boundary regex (`/(?<=[.!?])\s+/`) with
an 80-char minimum bucket — it will mis-split on abbreviations, decimals,
code fragments inside prose, etc. `cleanTextForTTS` re-derives plain text
from `innerText` of already-rendered HTML rather than working from the
original markdown/message data the server already has — meaning the exact
same markdown→text extraction logic exists nowhere server-side and can't be
tested (no `test/` coverage exists for either). It also independently
reimplements what `Markdown.render/1` already produces, just walking it
backwards through the DOM.

### 3.4 Caching/abort correctness
- **Cache**: `audioCache` is a per-hook-instance in-memory map of
  `chunkIndex → blob URL`, cleared on `stop()`. It is never persisted, never
  shared across messages/sessions, and — see next point — never released.
- **Leak**: `URL.createObjectURL(blob)` (app.js:912) is called for every
  fetched chunk and its result is **never** passed to
  `URL.revokeObjectURL()` anywhere in the file. `stop()` (app.js:858-872)
  discards the JS references (`this.audioCache = {}`) but the browser keeps
  each blob alive until the tab closes. Rapid toggle (start → stop → start)
  or repeated autoplay across a long-lived session tab accumulates leaked
  blobs indefinitely.
- **Abort**: only one in-flight fetch is tracked
  (`this.abortController`, singular) even though `playCurrentChunk` fires a
  *second*, un-aborted prefetch fetch for the next chunk
  (app.js:939-941, `.catch(() => {})`, no controller stored) — so `stop()`
  can abort the current chunk's fetch but not a concurrent prefetch, which
  will complete and populate `audioCache` after the player has already reset
  to empty state (harmless today since the object is discarded on the next
  `start()`, but it's an untracked in-flight request per stop/rapid-toggle).
- **Re-render**: because the whole footer is `phx-update="ignore"`, a
  message being re-rendered (e.g. a live-edit/patch to that same DOM node id)
  never re-triggers `mounted()` — LiveView diffing simply skips the subtree.
  Fine in the current app since messages are immutable once persisted, but
  it means `destroyed()` is the *only* cleanup path, and it only fires when
  the element is actually removed from the DOM (i.e., evicted by windowing),
  not on ordinary patches.
- **Cross-patch leakage**: no reproducible instance of audio literally
  playing across an unrelated LiveView patch was found — `destroyed()` does
  call `stop()` — but the blob-URL leak above means every *dismissed*
  player still leaves referenced memory behind regardless of whether cleanup
  ran correctly.

### 3.5 API key / endpoint exposure (`router.ex:78-82`, `tts_controller.ex:4`)
`POST /api/tts` sits on the bare `:api` pipeline (`accepts, ["json"]` only)
— unlike `/api/v1/runs` and `/a2a/*`, which both require `:api_authed`
(`OrcaHubWeb.Plugs.ApiAuth`). There is no application-level auth, no rate
limiting, and no upper bound on `text` size (`tts_controller.ex:4` only
checks `byte_size(text) > 0`) — any request that reaches this route
(whatever the network/reverse-proxy boundary allows) triggers a live,
metered ElevenLabs call with attacker-controlled text length. The client
does send a CSRF header (`app.js:904`), but `:api` doesn't run
`protect_from_forgery`, so it's inert. The ElevenLabs key itself
(`ELEVENLABS_API_KEY`) is server-side only and never reaches the client —
that part is fine.

## 4. Is it actually used / worth keeping?

- Shipped in a single commit (`8c329bc`, 2026-03-02) plus one same-day
  follow-up fix (`ad9b2fd`). **Zero commits touching it since** — 5+ months
  untouched while the rest of the app has had heavy iteration.
- **Zero test coverage** — no file under `test/` mentions TTS in any form.
- **Opt-in and not persisted** — `tts_autoplay` defaults to `false` and
  resets on every page load on both surfaces; there's no evidence it's a
  "sticky" workflow default for anyone.
- **Configured in prod**: `ELEVENLABS_API_KEY`/`ELEVENLABS_VOICE_ID` are
  present in both the local `.env` and the k3s `orca-hub-secrets` secret, so
  the feature is live and reachable in prod today, not dead-by-config.
- No analytics/telemetry hooks exist anywhere in this code path, so actual
  click/usage frequency can't be determined from the codebase — this survey
  can't tell you whether anyone uses it, only that nothing in the code
  suggests it's load-bearing (no other feature depends on it, no tests
  guard it, it's fully isolated behind `phx-hook`/one controller action).

**Assessment:** this is a small, isolated, self-contained feature — not
entangled with the rest of the app (message rendering degrades gracefully
without it; nothing else calls `TTSController` or reads `:tts_autoplay`).
That makes it cheap to either fix or delete. Given it's configured live in
prod, "delete it" is defensible but not free — someone may actually be using
voice playback for hands-free review of long agent output, which is a
plausible reason it was built. **Recommendation: don't delete blind — ask
the user directly whether they (or anyone) actually uses read-aloud today.**
If the answer is no, delete outright (~350 net lines across 8 files, no
migration needed, no data to preserve). If the answer is yes, do the
rewrite below rather than patching the leaks/DOM-scan piecemeal — the
current design's flaws are structural, not surface bugs.

## 5. Replacement options

### Option A — Single delegated hook on the feed container
One `TTSPlayer` hook lives on `#message-feed` itself (same element
`ScrollToBottom` already occupies — could even merge into it, or sit
alongside it) instead of on every message. Playback state (`chunks`,
`currentIndex`, `playing`, one `Audio()` element, one cache, one abort
controller) is a **single instance total**, not one per message. Message
footers become dumb `<button data-tts-target={msg_id}>` markup with no hook
attribute at all. A click is caught via one delegated listener on the
container (`e.target.closest("[data-tts-target]")`), which reads
`msg.dataset.ttsTarget` to know *which* message to speak and locates that
message's `[data-tts-text]` node by id lookup (`getElementById`), not by DOM
position. Autoplay-latest becomes "read the id LiveView told me was the
newest," pushed explicitly as event payload (`push_event(socket,
"tts-autoplay", %{message_id: id})`) instead of scanning the DOM for "last
`[phx-hook='TTSPlayer']`" — this also fixes §3.2 for free, and stays
correct under the incoming pagination/windowing since it never assumes DOM
order.

- **Cost scaling**: O(1) hook instances regardless of conversation length —
  fully decoupled from `@window_size`/pagination.
- **Survives the 20-message window** cleanly: since state lives on the
  container (which is never evicted), older messages scrolling out of the
  DOM has zero effect on in-progress playback of a message still visible;
  playback of a message that scrolls *out* mid-read is a product decision
  (stop it, or keep the audio playing with no visual target — recommend
  stopping, since the counter/controls UI needs the DOM node to update).
- **Survival of current code**: `cleanTextForTTS`, `splitIntoChunks`, the
  fetch/prefetch/cache logic, and `TTSController` all survive close to
  as-is — this is a *relocation* of state ownership, not a logic rewrite.
  Roughly 70-80% of the current `TTSPlayer` object's methods carry over
  unchanged; the parts that change are `mounted()`/`destroyed()` (container
  lifecycle instead of per-message) and how "which message" is resolved
  (id-based lookup instead of `this.el.closest(...)`).
- **Chunking**: stays client-side (cheapest change) — see Option C for the
  server-side alternative if correctness matters more than migration cost.
- **Caching**: same in-memory blob-URL cache, but now correctly scoped to
  "the message currently being read" — trivially fixed to
  `URL.revokeObjectURL()` on `stop()`/replacement since there's only ever
  one cache alive at a time instead of up to 20.

### Option B — Keep per-message hooks, make them lazy
Only mount `TTSPlayer` when a message first becomes visible (IntersectionObserver)
or defer state allocation until first click (keep the DOM element/hook
declaration but make `mounted()` a no-op until `toggle()` is first called).
Fixes the *idle allocation* cost (§3.1) but not the DOM-scan-for-autoplay
problem (§3.2, since "the last player" still needs to be found in the DOM,
now possibly not-yet-hydrated) and does nothing for the leak (§3.4) or the
chunking/auth issues, which are orthogonal to hook-per-message vs.
delegated. This is the smaller diff but leaves most of the actual jank in
place — it only addresses the concern that was already partially mitigated
by windowing anyway (§3.1 note above).

### Option C — Option A + server-side chunking and text extraction
Same container-delegation architecture as Option A, but `TTSController`
(or a new endpoint) accepts a message id / uses the already-rendered
markdown source server-side (Earmark AST or plain source text, both
available in `message_components.ex`/`markdown.ex`) to produce chunks,
returning `{chunks: [...]}` metadata or even one combined audio file with
timing cues. Eliminates `cleanTextForTTS`'s DOM-scraping/regex fragility
entirely and makes chunking testable (currently impossible — no JS test
harness in this repo). Larger diff: `TTSController` needs a new endpoint
shape, and the sentence-splitting/term-pronunciation logic (§3.3) has to be
ported to Elixir. Best long-term correctness, worst migration cost of the
three.

## 6. Recommendation

**Option A** (single delegated hook on `#message-feed`, keep chunking and
caching client-side, keep `TTSController` as-is). It fixes the two
structural problems that actually matter — allocation-per-message (§3.1)
and DOM-order-coupled autoplay (§3.2) — for a genuinely small diff, since
most of the existing `TTSPlayer` logic (chunking, fetch/prefetch, cache,
playback control) is reusable almost verbatim once state moves from "one
per message" to "one per feed." It's also the option most naturally
compatible with the pagination work already landing in `show.ex` from the
sibling worker, since it never depends on message DOM order or presence —
only on an id LiveView already knows. While doing that move, also fix for
free: `URL.revokeObjectURL()` on stop/replace (§3.4 leak), track the
prefetch abort controller too (§3.4), and put `/api/tts` behind
`:api_authed` with a text-length cap (§3.5) — none of these require the
larger server-side-chunking rewrite (Option C), which I'd only reach for if
correctness complaints about mis-split sentences actually surface. Before
starting any of this, though, get a straight answer from the user on
whether the feature has real users — if not, deleting ~350 lines across 8
files with zero test coverage and zero other-feature dependencies is the
actually-cheapest option on the table.
