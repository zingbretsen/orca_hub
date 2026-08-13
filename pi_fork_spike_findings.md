# pi Fork Spike Findings (2026-08-13)

Pre-implementation spike for `pi_fork_spec.md` — answers Q1 (BLOCKING), Q4, Q7,
and the §5.1 entries-reading API question. **No Elixir changed.** All
commands run against the locally-installed pi **0.83.0**
(`/home/zach/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent`),
provider `gb10-coder` (llama-server at `192.168.1.77:8082`, confirmed
reachable via `GET /health` -> `{"status":"ok"}` before starting).

Docs referenced (bundled with the local pi install, under `docs/`):
`docs/sessions.md`, `docs/session-format.md`, `docs/extensions.md`,
`docs/rpc.md`.

---

## Q1 (BLOCKING): does `--fork <ABSOLUTE PATH>` accept a session file outside the child's `--session-dir`?

**Answer: YES — no rejection.** `pi --fork` accepts an absolute path to a
session file that lives in a completely different directory tree than the
child's own `--session-dir`, with zero errors. The §4 fallback (copy +
rewrite header `id`/`parentSession`) is **not needed** — flag-vs-copy
decision is **flag**.

### Setup: real parent session in dirA

```
$ mkdir -p /tmp/pi_spike_a /tmp/pi_spike_b
$ cd /tmp/pi_spike_a && pi --provider gb10-coder --model qwen3-coder-next \
    -p --mode json --session-dir /tmp/pi_spike_a/.pi_sessions/parent \
    "say hi, reply with exactly the word HELLO and nothing else"
```

Output (trimmed to header + final event):

```
{"type":"session","version":3,"id":"019ffbcd-7cca-78be-a9f3-f2b01bcce95f","timestamp":"2026-08-13T15:46:15.882Z","cwd":"/tmp/pi_spike_a"}
...
{"type":"turn_end","message":{...,"content":[{"type":"text","text":"HELLO"}],...},"toolResults":[]}
```

Resulting file (found with `find /tmp/pi_spike_a/.pi_sessions -name "*.jsonl"`):

```
/tmp/pi_spike_a/.pi_sessions/parent/2026-08-13T15-46-15-882Z_019ffbcd-7cca-78be-a9f3-f2b01bcce95f.jsonl
```

Note: passing `--session-dir` explicitly makes pi write the file **directly**
inside that directory (no `--<cwd>--` project-namespacing subfolder) — this
matches how `Backend.Pi.pi_session_dir/1` already invokes it in
`lib/orca_hub/backend/pi.ex`.

### Fork from dirB, using the absolute path, into the child's own `--session-dir`

```
$ PARENT_FILE=/tmp/pi_spike_a/.pi_sessions/parent/2026-08-13T15-46-15-882Z_019ffbcd-7cca-78be-a9f3-f2b01bcce95f.jsonl
$ cd /tmp/pi_spike_b && pi --provider gb10-coder --model qwen3-coder-next \
    --fork "$PARENT_FILE" --session-dir /tmp/pi_spike_b/.pi_sessions/child \
    -p --mode json "reply with exactly the word FORKED and nothing else"
```

**Succeeded, no error.** Header line of the output:

```
{"type":"session","version":3,"id":"019ffbcd-b03f-7176-9b24-6b5e4d311125","timestamp":"2026-08-13T15:46:29.055Z","cwd":"/tmp/pi_spike_b","parentSession":"/tmp/pi_spike_a/.pi_sessions/parent/2026-08-13T15-46-15-882Z_019ffbcd-7cca-78be-a9f3-f2b01bcce95f.jsonl"}
```

- **Does the child dir get its own new session file?** Yes:
  `find /tmp/pi_spike_b/.pi_sessions -type f` ->
  `/tmp/pi_spike_b/.pi_sessions/child/2026-08-13T15-46-29-055Z_019ffbcd-b03f-7176-9b24-6b5e4d311125.jsonl`
  — a brand-new file, in the child's own `--session-dir`, distinct from the
  parent's file/dir entirely.
- **Fresh `id` + `parentSession` header?** Yes, exactly as shown above:
  `id` is a new UUID (`019ffbcd-b03f-...`, differs from parent's
  `019ffbcd-7cca-...`), `parentSession` is the parent's absolute path,
  verbatim.
- **Byte-identical replayed history?** Yes. Diffed the `message`/
  `model_change`/`thinking_level_change` payloads (dropping only the
  session-header line) between parent and child files via a small Python
  script (`json.dumps(entry, sort_keys=True)` per line):

  Parent entries:
  ```
  model_change {"id": "5a1fa877", "modelId": "qwen3-coder-next", "parentId": null, "provider": "gb10-coder", "timestamp": "2026-08-13T15:46:15.953Z", "type": "model_change"}
  thinking_level_change {"id": "55f60d80", "parentId": "5a1fa877", "thinkingLevel": "off", "timestamp": "2026-08-13T15:46:15.953Z", "type": "thinking_level_change"}
  message {"content": [{"text": "say hi, reply with exactly the word HELLO and nothing else", "type": "text"}], "role": "user", "timestamp": 1786635975966}
  message {"api": "openai-completions", "content": [{"text": "HELLO", "type": "text"}], "model": "qwen3-coder-next", "provider": "gb10-coder", "rawStopReason": "stop", "responseId": "chatcmpl-1anu5MnhHDqPikeDHqkNjWRZo1fiBSHt", "role": "assistant", "stopReason": "stop", "timestamp": 1786635976076, "usage": {..."input": 2113, "output": 3,...}}
  ```

  Child's first 4 post-header entries (before its own new turn):
  ```
  model_change {"id": "5a1fa877", "modelId": "qwen3-coder-next", "parentId": null, "provider": "gb10-coder", "timestamp": "2026-08-13T15:46:15.953Z", "type": "model_change"}
  thinking_level_change {"id": "55f60d80", "parentId": "5a1fa877", "thinkingLevel": "off", "timestamp": "2026-08-13T15:46:15.953Z", "type": "thinking_level_change"}
  message {"content": [{"text": "say hi, reply with exactly the word HELLO and nothing else", "type": "text"}], "role": "user", "timestamp": 1786635975966}
  message {"api": "openai-completions", "content": [{"text": "HELLO", "type": "text"}], "model": "qwen3-coder-next", "provider": "gb10-coder", "rawStopReason": "stop", "responseId": "chatcmpl-1anu5MnhHDqPikeDHqkNjWRZo1fiBSHt", "role": "assistant", "stopReason": "stop", "timestamp": 1786635976076, "usage": {..."input": 2113, "output": 3,...}}
  ```
  **Identical, byte for byte** — including entry `id`/`parentId` (tree
  structure preserved), and even the provider's `responseId`. The child then
  appends its own new turn (`message` user "FORKED" prompt, `message`
  assistant "FORKED" reply) as children of the last inherited leaf. Fresh
  turn showed `"cacheRead":65` in its usage — a (small, session was tiny)
  prompt-cache hit on the inherited prefix, consistent with §1's fork
  mechanics.

### Bare session-ID form — is it also accepted, and is the lookup dir-scoped?

Two follow-up runs, both using `--fork <bare-id>` (`019ffbcd-7cca-78be-a9f3-f2b01bcce95f`,
the parent's id, no path):

**Attempt 1** — child's `--session-dir` does NOT contain the parent file:

```
$ cd /tmp/pi_spike_b && pi --provider gb10-coder --model qwen3-coder-next \
    --fork 019ffbcd-7cca-78be-a9f3-f2b01bcce95f \
    --session-dir /tmp/pi_spike_b/.pi_sessions/child2 -p --mode json "reply with the word X"
```
Verbatim error (only line of output, exit non-success):
```
No session found matching '019ffbcd-7cca-78be-a9f3-f2b01bcce95f'
```

**Attempt 2** — child's `--session-dir` IS pointed at the directory containing
the parent file (`/tmp/pi_spike_a/.pi_sessions/parent`):

```
$ cd /tmp/pi_spike_b && pi --provider gb10-coder --model qwen3-coder-next \
    --fork 019ffbcd-7cca-78be-a9f3-f2b01bcce95f \
    --session-dir /tmp/pi_spike_a/.pi_sessions/parent -p --mode json "reply with the word Y"
```
Succeeded — new session `019ffbce-1ae1-7a54-9284-cbcc65dc5313`,
`parentSession` pointing at the same parent file, `"cacheRead":2117` on the
resulting turn (larger hit than attempt with the fresh-cold-cache first
fork above — consistent with the prefix having just been served).

**Conclusion: yes, `--fork` also accepts a bare (partial) session ID, and
that lookup IS scoped to `--session-dir`** — it only searches within the
directory passed to `--session-dir` (default: the per-cwd session dir under
`~/.pi/agent/sessions/` when `--session-dir` is omitted). This matches
`docs/sessions.md`'s `pi --fork <path|id>` line and confirms the id form is
**not usable across `--session-dir` boundaries** — only the **absolute-path**
form is, which is exactly what §4 plans to use (`--fork <parent-session-file>`,
full path).

### Fallback (§4, "if absolute path is REJECTED")

**Not triggered / not needed.** The absolute path was accepted on every
attempt above. `§4`'s decision: **use the plain `--fork <absolute-path>`
flag**, no copy-into-child's-dir workaround required.

---

## Q4: does pi flush entries to the JSONL as they land, or only on exit?

**Answer: flushed as they land, confirmed mid-turn while the process was
still alive.**

Ran a turn designed to take a few seconds and produce multiple entries
(model chose to call its `write` tool rather than stream text directly,
which was even better evidence — it produces a `toolCall`/`toolResult` pair
mid-turn before the final assistant text):

```
$ mkdir -p /tmp/pi_spike_q4d/.pi_sessions/s1
$ cd /tmp/pi_spike_q4d && pi --provider gb10-coder --model qwen3-coder-next \
    -p --mode json --session-dir /tmp/pi_spike_q4d/.pi_sessions/s1 \
    "write the numbers 1 to 150, one per line, nothing else"   # (backgrounded)
```

Polling `wc -l`/`stat -c%s` on the session file every ~300ms while checking
`pgrep -f cli.js` for liveness:

```
t+=300ms  size=2912 lines=7  pi_running=yes
t+=600ms  size=2912 lines=7  pi_running=yes
...
```

and the file's last lines at that mid-run poll already contained (verbatim,
truncated):

```
{"type":"message","id":"3d49242f",...,"message":{"role":"assistant","content":[{"type":"toolCall","id":"1z8L5IqSLsaJ6z4yiWYGQFcFtLBEJN5Z","name":"write",...
{"type":"message","id":"925db7cd",...,"message":{"role":"toolResult","toolCallId":"1z8L5IqSLsaJ6z4yiWYGQFcFtLBEJN5Z","toolName":"write",...
{"type":"message","id":"aa319e3f",...,"message":{"role":"assistant","content":[{"type":"text","text":"Done. Written numbers 1-150 to `/tmp/pi_s...
```

The `toolCall`/`toolResult` pair (and the file growing past its 2299-byte
header-only size to 2912 bytes / 7 lines) was observed **while `pgrep`
still reported the `pi` process alive** — i.e. entries land on disk
progressively during the turn, not batched at process exit. This confirms
Q4: a fork taken from a warm-but-idle parent (or even, for that matter, a
fork attempted mid-turn per §4's "mid-turn forks are consistent but
discouraged" note) reads a JSONL that's current up to the last completed
entry, not stale until the parent process dies.

---

## Q7: does `pi.sendMessage({customType, content}, {deliverAs: "nextTurn"})` at `session_start` write immediately or lazily?

**Answer: LAZILY — materialized only when the next prompt/turn arrives, not
at `session_start` time.** §5.1's idempotence check (walk
`ctx.sessionManager.getEntries()` at `session_start` to see the latest
`orca-identity` entry) must NOT assume the just-sent identity update is
already in that list — it isn't yet, on the same `session_start` call that
sent it.

### Test extension (throwaway, `/tmp`, NOT under `priv/pi/`)

`/tmp/pi_spike_identity_test.ts`:
```ts
export default function (pi: any) {
  pi.on("session_start", async (event: any, ctx: any) => {
    pi.sendMessage(
      { customType: "orca-identity-spike", content: "TEST-IDENTITY-PAYLOAD", display: false },
      { deliverAs: "nextTurn" }
    );
    const entriesRightAfter = ctx.sessionManager.getEntries();
    const found = entriesRightAfter.filter((e: any) => e.type === "custom_message");
    console.error(
      "SPIKE[session_start reason=" + event.reason + "]: entries_after_sendMessage_len=" +
      entriesRightAfter.length + " custom_message_entries=" + JSON.stringify(found)
    );
  });
}
```

### Run (fresh session, no prior history)

```
$ mkdir -p /tmp/pi_spike_q7/.pi_sessions/s1
$ cd /tmp/pi_spike_q7 && pi --provider gb10-coder --model qwen3-coder-next \
    -e /tmp/pi_spike_identity_test.ts -p --mode json \
    --session-dir /tmp/pi_spike_q7/.pi_sessions/s1 "reply with exactly the word OK"
```

stderr (the extension's `console.error`):
```
SPIKE[session_start reason=startup]: entries_after_sendMessage_len=2 custom_message_entries=[]
```

**Right after calling `pi.sendMessage(...)`, in the very same `session_start`
handler invocation, `getEntries()` shows 2 entries (the `model_change` +
`thinking_level_change` pair) and `custom_message_entries` is EMPTY** — the
message has not been written yet.

Resulting JSONL (all entries, types + parentId):
```
session            -                      -
model_change       -                      -
thinking_level_change -                   e63a1046
message (user)     -                      81f33267   "reply with exactly the word OK"
custom_message     orca-identity-spike    7c6adc07   (parent = the user message entry)
message (assistant)-                      1a052cc3   "OK"
```

The `custom_message` entry lands **as a child of the user message**, i.e.
it's inserted only once the next prompt actually arrives and a turn starts
— exactly the "queued for next user prompt" semantics
`docs/extensions.md`'s `pi.sendMessage` doc describes for `deliverAs:
"nextTurn"` ("Queued for next user prompt. Does not interrupt or trigger
anything."), but empirically confirmed here to also mean **not yet
persisted to the JSONL** at queue time.

### Fork case: does `session_start` fire on a `--fork`ed child, and can it see inherited entries?

```
$ PARENT_FILE=/tmp/pi_spike_a/.pi_sessions/parent/2026-08-13T15-46-15-882Z_019ffbcd-7cca-78be-a9f3-f2b01bcce95f.jsonl
$ mkdir -p /tmp/pi_spike_q7fork/.pi_sessions/child
$ cd /tmp/pi_spike_q7fork && pi --provider gb10-coder --model qwen3-coder-next \
    -e /tmp/pi_spike_identity_test.ts --fork "$PARENT_FILE" \
    --session-dir /tmp/pi_spike_q7fork/.pi_sessions/child -p --mode json \
    "reply with exactly the word FORKQ7"
```

stderr:
```
SPIKE[session_start reason=startup]: entries_after_sendMessage_len=4 custom_message_entries=[]
```

**Yes — `session_start` fires on a `--fork`ed child**, and at that point
`getEntries()` already returns **4 entries**: the full inherited
`model_change`/`thinking_level_change`/user-"HELLO"/assistant-"HELLO" chain
from the parent. So the idempotence rule's core mechanism (walk entries at
`session_start`, check the latest `orca-identity` entry's session id) is
viable — the inherited history IS visible synchronously at `session_start`.

**⚠ Doc/naming nuance not covered by `docs/extensions.md`'s lifecycle
diagram:** for a **CLI-level** `--fork` (a fresh process, as OrcaHub's
adapter will always use — `common_args/1` starts a brand-new port), the
fired `event.reason` is `"startup"`, **not `"fork"`**. The docs' `"fork"`
reason (`docs/extensions.md` line ~325: `session_start { reason: "fork",
previousSessionFile }`) only applies to the **interactive** `/fork`/`/clone`
commands switching a *live* session mid-process
(`session_before_fork` -> `session_shutdown` -> `session_start{reason:
"fork"}`). A cold CLI invocation with `--fork <path>` is indistinguishable
from a normal cold start via `event.reason` alone — **the extension must
detect "this is a fork" by checking the session header's `parentSession`
field (or just checking whether the latest identity entry names a
different session id, which is what §5.1 already does) rather than by
`event.reason === "fork"`.**

Final JSONL for the fork run confirms the identity update lands exactly at
the divergence point, per §5.1's design:
```
session / model_change / thinking_level_change   <- inherited (parent's)
message (user, "HELLO" prompt)                    <- inherited (parent's)
message (assistant, "HELLO")                       <- inherited (parent's)
message (user, "reply with exactly FORKQ7")         <- child's new turn
custom_message (orca-identity-spike)                <- inserted here, as child of the new user msg
message (assistant, "FORKQ7")                       <- child's reply
```

---

## Entries-reading API for §5.1's idempotence rule

**`ctx.sessionManager.getEntries()`** — "All entries" (`docs/extensions.md`,
`### ctx.sessionManager`, verbatim: ```ctx.sessionManager.getEntries()
// All entries```). Also available on the same object: `getBranch()`
(current branch), `buildContextEntries()` (active-branch entries with
compaction applied), `getLeafId()` (current leaf entry ID). `getEntries()`
is the right one for §5.1 — it returns the full entry list (not just the
active branch), and — per the fork test above — is populated with the
inherited parent history synchronously by the time `session_start` fires
for a forked child. The idempotence check is: filter for
`e.type === "custom_message" && e.customType === "orca-identity"`, take the
last one (or track a max by tree position), and compare the session id it
names against the current session id.

---

## Recommendations

1. **§4 (flag vs copy): use the flag.** `--fork <absolute-parent-path>
   --session-dir <child's-own-dir>` works exactly as designed — no copy/
   rewrite-header fallback needed. The one thing to encode defensively in
   the adapter: resolve the parent file to an **absolute path** before
   passing it to `--fork` (relative paths were not tested here, and the
   bare-id form is proven `--session-dir`-scoped so it's not usable for the
   cross-directory case §4 needs).

2. **§5.1 (identity idempotence): do NOT assume `pi.sendMessage(...,
   {deliverAs: "nextTurn"})` is durable at the moment it's called.**
   Because the write is lazy (materializes only when the next prompt
   arrives, as a child of that user message — not synchronously, and not
   even necessarily before the *next* `session_start`'s `getEntries()` call
   if a session is closed before any prompt is sent), the extension must
   NOT rely on "I just called sendMessage, so getEntries() next time will
   show it" as its sole guard. Two concrete implications:
   - The idempotence check at `session_start` (walk `getEntries()`, compare
     the latest `orca-identity` entry's session id) is still correct and
     sufficient for the steady-state case (cold reopen / fork), because by
     the time `session_start` fires *again* on a subsequent process launch,
     any previously-queued identity message from a *prior* process's first
     prompt has long since landed on disk (assuming that process got at
     least one prompt — which every real OrcaHub turn does).
   - The one gap `pi_fork_spec.md` §12 Q7 already flagged is real: a
     process that calls `session_start` -> queues the identity update ->
     but is torn down (idle-timeout, crash, kill switch) *before* its first
     prompt ever arrives will leave **no** `orca-identity` entry on disk at
     all for that "session" — the queued message is lost with the process.
     The *next* cold reopen's `session_start` will see the OLD identity
     entry (or none, if this was the fork child's very first process) and,
     per the idempotence rule, correctly re-queue an update since the
     latest entry doesn't match the current session id — so this is
     actually self-healing on the next attempt, not silently stuck. No
     extra "already queued" flag is needed for correctness, but it would
     avoid a harmless duplicate-looking log if `session_start` fires twice
     rapidly (e.g. `resources_discover`/reload) without a turn in between —
     low priority.
   - Do NOT gate the fork-detection branch on `event.reason === "fork"` —
     confirmed above that a CLI `--fork` reports `reason: "startup"`, same
     as any other fresh process. Detect divergence purely from entry
     content (latest `orca-identity` entry's session id vs current id),
     exactly as §5.1 already specifies — this finding just rules out an
     `event.reason`-based shortcut some implementer might otherwise reach
     for.

3. **Q4 is resolved**: no special handling needed for "fork reads a
   warm-but-idle parent's JSONL" — entries are flushed as they land, so the
   file on disk is always current through the last completed entry
   regardless of whether the parent's runner process is still alive.
