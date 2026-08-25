# Unified agent memory across the three harnesses — scoping

**Status:** scoping only. No code changed, nothing committed. Read-only investigation
against the repo at the SHA below, plus read-only probes of the installed CLIs, the
host Postgres, and the GB10 box.

**Author:** OrcaHub worker session (scoping task), 2026-08-24.

**Reading convention used throughout.** Every claim is tagged:

- **[CODE]** — I read it in this repo, path + line cited. Trust it.
- **[BIN]** — I read it out of an installed CLI's bundled JS via `strings`. It is real
  and present in the shipped binary, but it is *not* documented, I did **not** run it,
  and it can change without notice on the next CLI release.
- **[OBS]** — observed by running a read-only command (psql query, `ls`, `curl`).
- **[INFER]** — my reasoning. Not verified. Weigh accordingly.

---

## 0. TL;DR

**Recommendation: Option B (native OrcaHub memory), borrowing mem0's ideas, not its code.**

The single strongest reason is not philosophical, it is a fact about the code:
`SharedPrompts.open_issues_prompt/1` [CODE `lib/orca_hub/backend/shared_prompts.ex:363`]
already does a live DB query at session spawn and splices the result into the system
prompt of all three backends. **Push-recall — the thing the whole design hinges on —
is a solved problem in this codebase with an existing, tested, three-backend
precedent.** Adding a second such fragment is a small, well-understood change. Nothing
about mem0 makes that part easier, and mem0 cannot do it at all: mem0 is a store with a
search API; the pushing is OrcaHub's job either way.

What mem0 would add is a Python service, an HTTP hop, a schema we do not control, and a
scoping model (`user_id`/`agent_id`/`run_id`) strictly weaker than the six-plus
dimensions OrcaHub already has on the `sessions` row for free. What it would buy is
extraction/dedup/conflict-resolution prompts — perhaps two days of prompt engineering
we can lift from their repo and own outright.

**The crux answer (suppression), per harness:**

| Harness | Built-in memory | Can OrcaHub suppress it? |
|---|---|---|
| Claude Code | auto-memory dir + `MEMORY.md` index + pushed recall | **Yes, three ways** — and better, it can be *redirected*. See §3.1. |
| Codex | `[features] memories`, `~/.codex/memories/**` + `memories_1.sqlite` | **Yes** — `-c features.memories=false`, using the override path already in the code. See §3.2. |
| pi | **None of its own.** | Nothing to suppress. See §3.3. |

**The biggest surprise:** OrcaHub *already ships* a unified-memory attempt —
`OrcaHub.MemorySync` [CODE `lib/orca_hub/memory_sync.ex`] — and it is the direct cause
of a pathology the user has already complained about in their own global config. See
§1.3. That is the most important finding in this document, because it is the empirical
argument for why the *store* has to be semantic rather than file-level.

---

## 1. What already exists (this is more than the brief assumed)

### 1.1 The three on-disk stores, and OrcaHub's existing reader/writer

`OrcaHub.AgentMemory` [CODE `lib/orca_hub/agent_memory.ex`] already reads and writes
all three stores, and its moduledoc is an accurate map:

- **Claude Code** — `~/.claude/projects/<slug>/memory/` on the *project's node*, where
  `<slug>` is `project.directory` with every non-alphanumeric char replaced by `-`
  [CODE `agent_memory.ex:66` `slugify/1`]. `MEMORY.md` index + one `*.md` per memory,
  YAML frontmatter `name` / `description` / `metadata.type` [CODE `agent_memory.ex:96-130`].
- **`AGENTS.md` `## Project memory` section** in the project dir — read by Codex and pi
  [CODE `agent_memory.ex:264-350`].
- **Codex native** — `~/.codex/memories/` [CODE `agent_memory.ex:352+`], global to the
  node's OS user, **not** scoped per project. The moduledoc calls this out explicitly
  and it is a real scoping defect, see §6.

The module is deliberately node-local and is meant to be called via `Cluster.rpc/4` so
it runs on the project's owning node [CODE `agent_memory.ex` moduledoc]. All paths are
injectable for tests via `:home_dir` / `:orca_hub, :agent_memory_home`.

### 1.2 Git snapshotting already exists

`OrcaHub.MemoryGit` [CODE `lib/orca_hub/memory_git.ex`] makes `~/.claude/projects` and
`~/.codex/memories` into git repos with Gitea remotes under an `agent-memories` org,
named `<node>-claude` / `<node>-codex`. `~/.claude/projects` is whitelist-`.gitignore`d
to track only `<slug>/memory/**` [CODE `memory_git.ex:39-48`]. Soft-degrade is
load-bearing: missing git, unreachable Gitea, failed push all return `:ok` and log a
rate-limited warning [CODE `memory_git.ex` moduledoc].

`OrcaHub.MemoryGit.Server` [CODE `lib/orca_hub/memory_git/server.ex`] is the per-node
serializing GenServer. **This is the lifecycle hook the brief asked me to find** — see §5.

### 1.3 The existing "unified memory" is a file-level mirror, and it is the cautionary tale

`OrcaHub.MemorySync` [CODE `lib/orca_hub/memory_sync.ex`] is a *mechanical (no LLM)*
bidirectional mirror:

- **Claude → Codex**: every `~/.claude/projects/<slug>/memory/<name>.md` is copied to
  `~/.codex/memories/claude--<slug>--<name>.md` with a provenance HTML comment
  [CODE `memory_sync.ex:118-138`].
- **Codex → Claude**: every native Codex memory file is concatenated wholesale into one
  generated `~/.claude/memories-from-codex.md`, regenerated in full each pass
  [CODE `memory_sync.ex:157-201`], and `~/.claude/CLAUDE.md` is given an `@`-import line
  pointing at it [CODE `memory_sync.ex:203-220`].

Loop prevention is by construction (provenance-tagged files are never sources)
[CODE `memory_sync.ex:22-26`] — that part is well built.

**But look at what it produced.** [OBS] On this node right now:

```
~/.codex/memories:  313 files
        of which:   307 are `claude--*` mirrors written by MemorySync
          native:   6 entries (MEMORY.md, memory_summary.md, raw_memories.md,
                    rollout_summaries/, skills/, extensions/)
```

98% of the Codex memory store is OrcaHub-generated mirror. And the Codex→Claude
direction produced the file the user's own global `CLAUDE.md` now complains about:

> `~/.claude/codex-memory-digest.md`: *"Hand-curated 2026-08-09 from
> `~/.claude/memories-from-codex.md`'s 'General Tips' section, which was previously
> @-imported wholesale (~77KB / ~21k tokens on every session)."*

**This is the empirical case for the whole project.** A file-level mirror with no
extraction, no dedup, and no relevance ranking does not produce shared memory — it
produces 21k tokens of unconditional context tax, which a human then has to hand-curate
back down. Whatever replaces it must be *semantic and top-k*, not *mirrored and
concatenated*. Option A and Option B both clear that bar; the status quo does not.

Second problem with the current design, and it is the conflation the brief asked me to
flag: **`MemorySync` injects accumulated recall into `CLAUDE.md`, which is static
config** [CODE `memory_sync.ex:203-220`, `@import_line "@~/.claude/memories-from-codex.md"`].
`CLAUDE.md` is rules-injected-verbatim-deterministically. Recall is
retrieved-ranked-and-variable. Putting the second inside the first is exactly the
category error to avoid, and it is currently shipped. Any go-forward design should
remove that import line rather than inherit it.

---

## 2. The seams — where the system prompt is composed, per backend

The architectural claim in the brief — *"every harness has only two memory mechanisms:
text injected at session start, and tools the agent can call; OrcaHub owns both seams"* —
**holds, with one important refinement for pi.**

Every backend implements `system_prompt/1` from the `OrcaHub.Backend` behaviour, and
all three compose from the shared fragment library
`OrcaHub.Backend.SharedPrompts` [CODE `lib/orca_hub/backend/shared_prompts.ex`].

### 2.1 Claude — `--append-system-prompt`, fully dynamic

- `Backend.Claude.system_prompt/1` [CODE `lib/orca_hub/backend/claude.ex:286-330`]
  builds a list of fragments and joins with `\n\n`.
- It is passed as the `:system_prompt` opt at [CODE `claude.ex:98` (streaming)] and
  [CODE `claude.ex:121` (one-shot)], which `Claude.Config.build_args/2` renders as
  `--append-system-prompt <text>` [CODE `lib/orca_hub/claude/config.ex:60`].
- **Splice point for recall:** one more entry in the list at `claude.ex:306-325`.
  Directly alongside `SharedPrompts.open_issues_prompt(ctx.session_id)` at
  [CODE `claude.ex:324`], which is already a live DB query.

### 2.2 Codex — leading message on the first turn, fully dynamic

- `Backend.Codex.system_prompt/1` [CODE `lib/orca_hub/backend/codex.ex:700-719`].
- Codex has no system-prompt flag; capability is `system_prompt: :leading_message`
  [CODE `codex.ex:58`]. It is prepended to the first user turn exactly once, guarded by
  a `system_prompt_sent` flag [CODE `codex.ex:438-445` `with_system_prefix/3`].
- **Splice point for recall:** one more entry at `codex.ex:703-716`, again next to the
  existing `SharedPrompts.open_issues_prompt(ctx.session_id)` [CODE `codex.ex:716`].
- **Caveat [CODE]:** because it rides the first turn, Codex recall is retrieved once per
  *port open*, not per turn. Same as its open-issues hook. Fine for v1.

### 2.3 pi — **system prompt is byte-frozen; recall must go through the env-var/extension seam**

This is the one place the brief's model needs correcting, and it is well documented in
the code.

`Backend.Pi.system_prompt/1` [CODE `lib/orca_hub/backend/pi.ex:1209-1222`] is
deliberately **a pure function of `(orchestrator, code_exec, commit_trailer)`** — three
flags, no per-session bytes. The reasoning [CODE `pi.ex:1171-1206`]:

> *"This string is `--append-system-prompt`'s value, i.e. byte 0 of the prompt. A forked
> child only gets its cheap warm resume if its inherited prefix is byte-identical to the
> parent's, and the serving layer matches longest-common-prefix from byte 0 — so ONE
> differing byte here discards cache reuse of the entire prefix (~26s cold prefill
> instead of ~2s, plus it craters every co-tenant on the shared llama-server)."*

It is pinned by a test: `"system_prompt/1 — byte determinism"` in
`test/orca_hub/backend/pi_test.exs` [CODE `pi.ex:1204-1206`].

**Putting retrieved memories in pi's system prompt would break forking and tank the
GB10 box.** Do not do it. Note the code already recognised `open_issues_prompt` as
exactly this hazard and moved it out [CODE `pi.ex:1189-1191`]:

> *"`SharedPrompts.open_issues_prompt/1` — a LIVE DB query, so it varied per session AND
> per moment; it was already busting same-session prefix caching on every cold reopen."*

**The correct pi seam already exists and is purpose-built for this.** Per-session
dynamic content is delivered via the `ORCA_IDENTITY` env var
[CODE `pi.ex:1279-1295` `orca_identity_json/1`] and consumed by the pi extension
`priv/pi/orca-identity.ts`, which appends it as a `custom_message` session entry at
`session_start`. From that file's header:

> *"`custom_message` is the right entry type: 'Custom messages participate in LLM
> context'. `pi.appendEntry()` does NOT — it is explicitly TUI-only and never reaches
> the model. … Env is invisible to the KV cache, so this whole payload varying per child
> costs nothing."*

**Splice point for pi recall:** add a `"memories"` key to the `orca_identity_json/1`
payload [CODE `pi.ex:1285-1293`] and one more `parts.push(...)` in
`renderIdentity()` [CODE `priv/pi/orca-identity.ts`, the loop over
`payload.commit_trailer / issue_trailer / open_issues`]. That loop already iterates a
list of optional fragments — adding a fourth is a one-line change. Alternatively a
separate `ORCA_MEMORY` var + extension, if we want independent lifecycle.

**[INFER]** A separate extension is probably cleaner: identity is idempotent-per-session
(the whole point of its `previous === sessionId` no-op rule), whereas recall may want to
refresh more than once. Worth a decision, not a blocker.

### 2.4 Verdict on the architectural claim

**Confirmed, with the pi refinement.** OrcaHub owns prompt composition for all three
backends through one shared fragment module, and it owns the MCP server. A memory layer
can live entirely behind those two seams. The harnesses never need to learn about it.

One caveat worth stating plainly: **`system_prompt/1` for Claude and Codex is
byte-pinned by golden fixtures** [CODE `pi.ex:1204-1206` references
`test/support/fixtures/prompt_goldens/`]. Adding a fragment means regenerating those
goldens. That is routine, not a risk, but it is a real step.

---

## 3. The suppression question (the crux)

Framing first, because it changes the answer. There are three postures available, not
two:

1. **Suppress** — turn the harness's built-in memory off entirely. OrcaHub's pushed
   blob is the only recall the model sees.
2. **Redirect** — leave the built-in machinery running, but point it at a directory or
   store that OrcaHub materializes from the shared store. The harness keeps working
   exactly as it does today; OrcaHub becomes the source of truth underneath it.
3. **Coexist** — leave it alone, add pushed recall alongside. Two memory systems, both
   live. This is the status quo plus a new one, and it is the worst option — it is how
   we got the 21k-token digest problem in §1.3.

**Recommendation: redirect for Claude, suppress for Codex, nothing needed for pi.**
Reasoning per harness below.

### 3.1 Claude Code — three suppression levers and a redirect lever, all real

This is the harness with the most built-in memory machinery, and — surprisingly — the
most control surface. Everything in this subsection is **[BIN]**: read out of the
bundled JS of `claude` **2.1.241** at
`/home/zach/.local/share/claude/versions/2.1.241`. **I did not execute any of it.**
Treat every switch here as "present in the shipped binary and needs a 20-minute live
confirmation before we build on it."

**Suppression levers, in the order the code checks them** [BIN, from the enable-check
function]:

```js
function Zy(){ if(N5()) return false; return joi(); }
function joi(){
  if(Cd()) return false;
  let e = process.env.CLAUDE_CODE_DISABLE_AUTO_MEMORY;
  if(Vn(e)) return false;            // Vn = truthy: "1","true","yes","on"
  if(Gp(e)) return true;
  if(q.CLAUDE_CODE_SIMPLE) return false;
  ...
  let t = Qo();
  if(t.autoMemoryEnabled !== undefined) return t.autoMemoryEnabled;
  return true;                        // default ON
}
```

1. **`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`** (env var). Truthy values are
   `"1" | "true" | "yes" | "on"` [BIN, `Vn()`]. **This is the cleanest lever for
   OrcaHub** — OrcaHub already fully controls the child process env
   [CODE `claude.ex:105` `session_env(...)`].
2. **`autoMemoryEnabled: false`** (settings.json key). Its own self-description in the
   settings schema [BIN]: *"Enable auto-memory for this project. When false, Claude will
   not read from or write to the auto-memory directory."* That is a precise, unambiguous
   answer to the brief's question.
3. **`--bare`** (documented CLI flag; `claude --help` says it skips *"hooks, LSP, plugin
   sync, attribution, auto-memory, background prefetches, keychain reads, and CLAUDE.md
   auto-discovery"*). **Do not use this.** It is far too blunt — it also forces auth to
   `ANTHROPIC_API_KEY`/`apiKeyHelper` only, and OrcaHub authenticates per-node via OAuth
   token [CODE `claude.ex:105` `node_oauth_env()`]. It would break every session.

**The redirect lever, which I think is the actually interesting one:**

4. **`autoMemoryDirectory`** (settings.json key). Self-description [BIN]: *"Custom
   directory path for auto-memory storage. Supports ~/ pre[fix]"*. This lets OrcaHub
   point a session's auto-memory at a directory OrcaHub owns and materializes.

5. **`CLAUDE_MEMORY_STORES`** (env var, JSON array). The descriptor schema [BIN]:

   ```
   { path, mode: "rw"|"ro", scope: "user"|"team", mount,
     promptIndex, skillsDirs, promptIndexMaxBytes }
   ```

   Three fields here matter a great deal: **`mode: "ro"`** (a store the agent can read
   but not write), **`promptIndex`** (the file whose contents get injected at session
   start — i.e. the `MEMORY.md`-index mechanism, made configurable per store), and
   **`promptIndexMaxBytes`** (a budget cap on exactly the context-tax failure mode from
   §1.3). Setting the env var is itself one of the two things that enable this code path
   [BIN: `wjr()` returns `!!process.env.CLAUDE_MEMORY_STORES?.trim()`]; the other is a
   server-side GrowthBook flag `tengu_moth_copse`.

   **[INFER, flagged as uncertain]** This looks purpose-built for exactly what we want —
   a read-only, OrcaHub-generated, size-capped store pushed at session start through
   Claude's own native mechanism. But it is undocumented, partly feature-flagged
   server-side, and I have not run it. **Do not architect around it without a live
   spike.** If it works it is the nicest possible answer for the Claude harness; if it
   does not, levers 1/2/4 are sufficient.

6. **A first-party remote memory API.** `CLAUDE_CODE_MEMORY_API_BASE_URL` and
   `CLAUDE_CODE_MEMORY_API_TOKEN` [BIN] drive a REST client against `/memories` and
   `/memories/export` [BIN], with entries shaped
   `{id, path, content_sha256, content_size_bytes, size_bytes, updated_at}`, optimistic
   concurrency via `expected_content_sha256`, and 409-on-conflict [BIN]. OrcaHub *could*
   implement this contract and become Claude's memory backend natively.

   **I recommend against it.** It is (a) undocumented and internal, (b) *path/content*
   shaped — a file sync protocol, not a semantic query protocol, so it gives us no
   top-k push, and (c) Claude-only, which defeats the entire point of a *unified* layer.
   Recorded here because it is genuinely relevant prior art and someone will otherwise
   find it later and wonder if it was considered.

**Answer to the brief's specific question** — *"Can OrcaHub suppress it, or is the
practical move to have OrcaHub GENERATE MEMORY.md so the built-in keeps working but is
no longer the source of truth? Is there a flag/setting/env var, or is it prompt-level
only?"*

**It is not prompt-level only. There are real env vars and real settings keys.** And
both of the brief's proposed moves are available. My recommendation is the **generate**
option, for a reason the brief anticipated: Claude's built-in memory is not just an
injected index — it also does *pushed recall via system-reminders* mid-session, which
OrcaHub cannot replicate through `--append-system-prompt` (that fires once at spawn).
Keeping the built-in machinery alive and feeding it OrcaHub-owned content preserves that
mid-session recall for free. Suppressing it throws it away.

Concretely: set `autoMemoryDirectory` (or `CLAUDE_MEMORY_STORES` with `mode: "ro"`) to a
per-project directory OrcaHub materializes from the shared store, exactly the way
`SkillSync`/`PiConfigSync` already materialize hub-DB rows onto each node's disk
[CODE `lib/orca_hub/pi_config_sync.ex`, `lib/orca_hub/skill_sync.ex`]. That pattern is
established, tested, and has an on-disk ownership manifest so deleted rows get removed
rather than orphaned.

**[INFER]** One risk to note honestly: if the built-in keeps *writing*, we have two
writers to reconcile. `mode: "ro"` would solve that if it works; otherwise the write
path becomes "let it write, then ingest its writes on the idle hook" — which is fine,
and is arguably a *feature* (it means Claude's own extraction does work for us).

### 3.2 Codex — one clean lever, already reachable through existing code

**Codex's built-in memory is ON right now.** [OBS] `~/.codex/config.toml` contains:

```toml
[features]
memories = true
```

[OBS] The store is `~/.codex/memories/` plus a SQLite index `~/.codex/memories_1.sqlite`
(139KB). The markdown side has the canonical trio `MEMORY.md` / `memory_summary.md` /
`raw_memories.md`, plus `rollout_summaries/`, `skills/`, `extensions/`
[CODE `agent_memory.ex:356-360` documents exactly this layout].

**Correction to the brief's framing.** The brief describes *"Zach's `~/.codex/memories`
rollout-summary pipeline (auto-regenerated by a sync process — find out where that lives
and what triggers it)."* I looked for that sync process and **it does not exist as a
Zach-authored job**:

- [OBS] `crontab -l` — empty.
- [OBS] `systemctl --user list-timers` — empty.
- [OBS] No matching scripts in `~/homelab/scripts` or `~/bin`.

**The regeneration is Codex's own built-in `[features] memories` consolidation**, which
runs inside the `codex` process itself. `rollout_summaries/` is Codex's native artifact,
not a homegrown pipeline. This matters for scoping: there is nothing of Zach's to port,
only a vendor feature to turn off.

**The suppression lever.** `Backend.Codex` already layers per-session config via `-c`
root-level overrides rather than writing to disk [CODE `codex.ex:172-187`
`mcp_config_args/1`]:

```elixir
["-c", "mcp_servers.orca.url=#{inspect(url)}",
 "-c", ~s(mcp_servers.orca.default_tools_approval_mode="auto")]
```

The moduledoc records that this mechanism was spike-verified against codex-cli 0.142.5
for both `app-server` and `exec`, that it does not persist back to
`~/.codex/config.toml`, and that concurrent sessions with different values do not
cross-talk [CODE `codex.ex:671-685`]. [OBS] Installed version is now **0.146.0**.

So **`-c features.memories=false`** slots into the existing `mcp_config_args/1` list as
one more pair of elements. That is a two-line change, on a mechanism this codebase has
already spiked. **[INFER]** I have not run it — I am inferring that a `features.*` key
is settable via `-c` the same way `mcp_servers.*` is, since `-c` is documented as
*root-level* config override. Worth 10 minutes of confirmation, low risk.

Note the history here [CODE `codex.ex:672-680`]: OrcaHub *used to* materialize a
per-session `CODEX_HOME` and that was deliberately removed, precisely because it hid the
user's real `~/.codex/config.toml` — including `features.memories` — from every session.
So the codebase has already thought about this exact knob and chose to stop hiding it.
Turning it off explicitly via `-c` is the compatible move; bringing back `CODEX_HOME`
is not.

**Recommendation for Codex: suppress.** Unlike Claude, Codex's memory is
**global to the OS user, not per project** [CODE `agent_memory.ex:361-364`]:

> *"**These memories are GLOBAL to the node's current OS user, not scoped to any one
> project** — every project routed to the same node shares (and can edit/delete) the
> same Codex memory files."*

That is a scoping defect we should not preserve, so there is nothing worth redirecting
*into*. Suppress it, ingest the existing content once (§7), and serve Codex the same
pushed blob the other two get.

### 3.3 pi — nothing to suppress; it already borrows Claude's

**pi has no memory system of its own.** [CODE `agent_memory.ex:41-42`]:
*"pi has no memory store of its own — it reads AGENTS.md and, via an extension, the
Claude MEMORY.md index."* I confirmed this independently:

- [OBS] `pi --help` has no memory-related flags.
- [OBS] `~/.pi/agent/` contains `auth.json`, `bin`, `extensions`, `models.json`,
  `models-store.json`, `sessions`, `settings.json`, `skills` — **no memory directory**.

The "via an extension" part is real and is the single most useful artifact I found for
this project. [OBS] `~/.pi/agent/extensions/claude-memories.ts` (56 lines), with a
reference copy checked into this repo at
[CODE `scripts/pi-extensions/claude-memories.ts`]. It:

1. hooks `session_start`,
2. computes Claude's project slug with the *same* `cwd.replace(/[^A-Za-z0-9]/g, "-")`
   rule OrcaHub uses [CODE `agent_memory.ex:66`],
3. reads `~/.claude/projects/<slug>/memory/MEMORY.md`,
4. pushes it as a `custom_message` with `display:false`,
   `{deliverAs: "nextTurn"}`.

**That is a working, in-production implementation of exactly the push-recall mechanism
this whole project needs, for the hardest of the three harnesses.** It also happens to
demonstrate the index-push/body-pull hybrid: it injects only the index and tells the
model to `read` individual files when a line looks relevant.

**Recommendation for pi: nothing to suppress.** Replace `claude-memories.ts` with a
memory extension fed by OrcaHub, delivered through the fan-out that already exists:
`OrcaHub.PiConfigSync` materializes hub-DB `pi_config_entries` rows of kind
`"extension"` into `~/.pi/agent/extensions/<name>.ts` on every node
[CODE `lib/orca_hub/pi_config_sync.ex:99-101`]. So shipping a pi memory extension is a
DB row, not a deploy.

### 3.4 Static config vs. recall — where the codebase conflates them

The brief asked me to flag this. Three places:

1. **`MemorySync` @-imports accumulated recall into `~/.claude/CLAUDE.md`**
   [CODE `memory_sync.ex:203-220`]. This is the clearest conflation and the one that
   caused observable harm (§1.3). **Should be removed** by any go-forward design.
2. **The `AGENTS.md` `## Project memory` section** [CODE `agent_memory.ex:264-350`].
   `AGENTS.md` is checked-in static config; a `## Project memory` section inside it is
   accumulated recall living in a config file, in git, injected verbatim. This one is
   more defensible (it is small, human-curated, and project-scoped) but it *is* the same
   category mix. **[INFER]** I would migrate its contents into the store and leave the
   section as a stub, rather than keep two sources.
3. **`context_files_prompt/1`** [CODE `shared_prompts.ex:320-339`] inlines all of
   `<directory>/.context/*.{md,mmd}` verbatim into the prompt. This is *correctly*
   static config, not recall — I flag it only because it is the single largest prompt
   fragment and pi already had to drop it for context-budget reasons
   [CODE `pi.ex:1167-1170`]. It is evidence that the prompt budget is already tight, which
   constrains how big a recall blob we can afford (§4.3).

**Not conflated, correctly:** `CLAUDE.md`, `AGENTS.md` proper, and `.context/*` are
static config and should stay verbatim-injected and out of any vector store. The scope of
this project is only the *accumulated recall* tier.

---

## 4. Push vs. pull recall

**The brief's design point is correct, and — importantly — it is already proven in this
codebase three times over.** Push is not speculative here.

### 4.1 Push already works, with a live precedent per backend

`SharedPrompts.open_issues_prompt/1` [CODE `shared_prompts.ex:361-368`]:

```elixir
def open_issues_prompt(nil), do: nil

def open_issues_prompt(session_id) do
  case HubRPC.list_open_issues_created_by(session_id) do
    [] -> nil
    issues -> "# Your Open Issues\n\n" <> Enum.map_join(issues, "\n", &open_issue_line/1)
  end
end
```

That is: **a live, indexed DB query, executed at prompt-composition time, whose result is
spliced into the system prompt, returning `nil` to omit the section entirely when there
is nothing to say.** It is structurally identical to what top-k memory recall needs. It is
wired into all three backends [CODE `claude.ex:324`, `codex.ex:716`, `pi.ex:1292`].

Its own docstring even anticipates the cost question [CODE `shared_prompts.ex:341-359`]:
*"One indexed query … NOT the `get_issue`-style live-attempts fan-out (§3.5) — cheap
enough to run on every cold session spawn."* Same budget reasoning applies to a
vector top-k.

The `nil`-to-omit convention matters and should be copied: **a session with no relevant
memories should pay zero tokens**, not a "no memories found" header.

### 4.2 What pushing would actually take, per backend

| Backend | Change | Size |
|---|---|---|
| Claude | one entry in the `parts` list [CODE `claude.ex:306-325`] | ~2 lines + golden regen |
| Codex | one entry in the list [CODE `codex.ex:703-716`] | ~2 lines + golden regen |
| pi | **not** the system prompt — one key in `orca_identity_json/1` [CODE `pi.ex:1285-1293`] + one `parts.push` in the extension, or a sibling `ORCA_MEMORY` extension | ~4 lines + a `pi_config_entries` row |

Plus one new `SharedPrompts.memories_prompt/1`-style function. **That is the entire push
path.** It is genuinely small — which is the strongest argument that the hard part of
this project is the *store and the extraction*, not the injection.

### 4.3 Constraints on the pushed blob

1. **Token budget is already tight.** pi had to drop `context_files_prompt/1` entirely
   because inlining `.context/*` *"was blowing up pi sessions' context budget at
   startup"* [CODE `pi.ex:1167-1170`]. And §1.3's 21k-token digest is the same failure in
   the memory domain. **The pushed blob needs a hard byte cap** — note that Claude's own
   store descriptor has `promptIndexMaxBytes` for precisely this [BIN].
2. **pi's blob must not enter the system prompt** (§2.3). Non-negotiable — it breaks
   forking.
3. **Push fires at cold spawn only.** For Claude/Codex the system prompt is baked at port
   open; a warm streaming port keeps its prompt across turns. The codebase already
   documents this class of staleness for the per-project `commit_trailer` flag
   [CODE `projects/project.ex`: *"Resolved once at SessionRunner init, so toggling this
   only affects the NEXT cold spawn (a warm streaming port already baked its system
   prompt)"*] and for the open-issues hook [CODE `shared_prompts.ex:349-355`].
   **[INFER]** For memory this is acceptable: a session's relevant memories do not change
   much within one warm port's lifetime, and the pull tool (below) covers the gap.

### 4.4 Push *and* pull, not push *or* pull

Push is necessary but should not be exclusive. A `memory_search` tool is still worth
having for the mid-session "I need to look something up" case that push-at-spawn cannot
serve. The brief's point stands — it must not be the *primary* mechanism — but as a
secondary it is cheap.

Adding it is mechanical: `OrcaHub.MCP.Tools` dispatches to a `@categories` list of modules
each exposing `list/0` and `call/3` [CODE `lib/orca_hub/mcp/tools.ex:53-65, 104-146`]. A
new `Tools.Memory` module is one list entry. In code-exec mode (the default,
`session.code_exec` defaults to `true` [CODE `sessions/session.ex`]) it is automatically
reachable as `Tools.memory_search(...)` inside `run_elixir` with no extra work.

**[INFER]** One caution from this repo's own hard-won experience — the memory
`project-tool-flag-advertising` records that *"Agents ignore schema descriptions;
advertise flags in the RESULT payload."* Applied here: the pushed blob should itself say
"more memories exist, call `memory_search` to find them", rather than relying on the tool
description to get read.

---

## 5. Write path

### 5.1 The lifecycle hook exists and is exactly the right shape

`OrcaHub.MemoryGit.Server.snapshot_session_async/1` is called from **three** clean
idle-transition sites in `SessionRunner`:

- [CODE `lib/orca_hub/session_runner.ex:864`] — one-shot port exit, `db_status == "idle"`
- [CODE `lib/orca_hub/session_runner.ex:1622`] — one-shot, no pending prompts
- [CODE `lib/orca_hub/session_runner.ex:1753`] — streaming turn end, `db_status == "idle"`

And the server itself is already built with the right properties
[CODE `lib/orca_hub/memory_git/server.ex`]:

> *"`snapshot_session_async/1` is the entry point `SessionRunner` calls on every clean
> idle transition. It is fire-and-forget by design: the real work runs inside an
> unsupervised `Task.Supervisor` child that then makes a (serializing) call into this
> GenServer, so a slow or failing git pass can never block or crash the idle transition
> that triggered it."*

**A post-session extraction job wants precisely these properties** — serialized per node,
fire-and-forget, never blocking the turn, `enabled?/0`-gated so tests do not fire it. This
is the single best piece of existing infrastructure for this project. An extraction pass
either joins `do_run_pass/2` [CODE `memory_git/server.ex:80-107`] or gets a sibling
GenServer built on the same pattern.

**[INFER]** I lean sibling rather than joining `do_run_pass/2`: extraction makes an LLM
call and can take seconds-to-minutes, whereas the git pass is `commit-if-dirty` and
fast. Sharing one mailbox would let a slow extraction stall snapshots. Same pattern,
separate process.

**One caution [CODE].** The hook fires on **every** clean idle transition — i.e. every
turn end, not every session end. A per-turn LLM extraction call would be expensive and
noisy. Needs either debouncing, a "session has been idle N minutes" gate, or a
dirty-since-last-extraction check. The `Jobs` subsystem
[CODE `lib/orca_hub/jobs.ex`, `.context/supervision-tree.md`] is the natural home if
extraction should survive teardown.

### 5.2 Transcripts are retained, in full, and are query-ready

[CODE `lib/orca_hub/sessions/message.ex`] — one row per event, flexible `data` map, FK to
session, `naive_datetime_usec` timestamps.

[OBS] Production scale, queried against `orca_hub_prod` on the host Postgres:

```
messages:       813,647 rows
sessions:         3,420   (claude 3292 / pi 117 / codex 11)
database size:    1792 MB
```

[CODE] There is **no message pruning**. The only `delete_all` in the sessions context is
`prune_churn_samples/1` [CODE `lib/orca_hub/sessions.ex:1473-1480`], which touches a
different table. Sessions are only *soft*-archived (`archived_at`)
[CODE `sessions.ex:96` `archive_session/1`].

**So yes — OrcaHub retains full transcripts suitable for post-hoc extraction, forever,
in the same Postgres a memory store would live in.** Read helpers already exist:
`list_messages/1` [CODE `sessions.ex:289`] and the keyset-paginated
`list_messages_window/2` [CODE `sessions.ex:341`], backed by a dedicated index
[CODE `priv/repo/migrations/20260806234500_add_messages_session_keyset_index.exs`].

This is a significant asset. It means **phase 1 does not need to wait for new sessions** —
there are 813k messages of existing transcript to extract from, and extraction can be
backfilled offline at whatever pace the LLM budget allows.

### 5.3 The two write paths, restated

1. **Explicit, agent-initiated** — a `memory_write`/`memory_save` MCP tool in a new
   `Tools.Memory` category (§4.4). Cheap, precise, and it is how the current Claude
   auto-memory already behaves (the agent decides what is worth keeping).
2. **Implicit, post-hoc extraction** — off the idle hook (§5.1), reading the transcript
   (§5.2), calling an LLM to extract/dedup/merge. This is the part mem0 would otherwise
   provide and the part that needs the most care.

**[INFER]** Phase 1 should ship (1) only. It delivers the unified store, the push path,
and the migration, with zero LLM dependency and zero new failure modes. (2) is where all
the risk lives and it should be a separate, later, independently-revertible phase.

### 5.4 The LLM dependency for extraction is currently unresolved

The brief assumes extraction LLM calls go to *"the LOCAL model already serving on the
GB10 box (qwen3-coder-next, 192.168.1.77, OpenAI-compatible endpoint — verify the actual
endpoint/port before relying on it)."*

**I could not verify a live endpoint.** [OBS] From this host:

```
192.168.1.77:8080/v1/models  -> connection refused
192.168.1.77:8000/v1/models  -> 404   (something HTTP is listening; it is
                                       not an OpenAI-compatible model server —
                                       /v1/models, /models, /health, and
                                       /v1/chat/completions all return 404)
192.168.1.77:11434,1234,5000,30000,4001 -> refused
```

[OBS] There is also no GB10 provider configured in the hub DB: `pi_config_entries` has
**zero** rows of kind `provider`. [CODE] The only GB10 references in the codebase are
comments in `fork_gate.ex` and `mcp/tools/sessions.ex` recording measurements taken
against *"the gb10 llama-server"* — so such a server demonstrably existed at some point,
but is not reachable from here now on any standard port.

**This is a real, unresolved dependency for Option A** (mem0 requires an LLM call on
*every write* for fact extraction/dedup) and a softer one for Option B (which can defer
LLM extraction to a later phase entirely — see §5.3). It is worth confirming directly on
the box before either option is costed. **[INFER]** Most likely explanations are
"bound to localhost on gb10" or "not currently running"; I did not ssh in to check, as
that was outside the read-only-investigation scope I set myself.

---

## 6. Scoping keys

### 6.1 What OrcaHub already knows, for free

This is where Option B's advantage is most concrete. Every dimension below is an existing
indexed column, available at prompt-composition time with no new plumbing.

On `sessions` [CODE `lib/orca_hub/sessions/session.ex`]:
`directory`, `project_id`, `runner_node`, `original_node`, `backend`, `model`,
`orchestrator`, `parent_session_id`, `forked_from_session_id`, `issue_id`, `trigger_id`,
`code_exec`, `triggered`, `archived_at`.

On `projects` [CODE `lib/orca_hub/projects/project.ex`]:
`name`, `directory`, `node`, `key_prefix`, `deleted_at`.

**Compare mem0's native scoping: `user_id` / `agent_id` / `run_id`.** Three opaque
strings. To express "memories from worker sessions on this project, excluding forks,
written by a pi backend" you would have to encode that into those three fields by
convention and then filter client-side. **The brief's suspicion is correct: mem0's
scoping model is strictly weaker than what OrcaHub has for free**, and it is weaker in a
way that is annoying rather than fatal — you can always jam structure into
`agent_id` strings, you just lose the ability to query it relationally.

### 6.2 Proposed tiers

**[INFER]** — this is design, not an observation:

| Tier | Key | Example | Why |
|---|---|---|---|
| **global** | none | "always add the OrcaHub-Session trailer" | Rare. Overlaps heavily with static config — be suspicious of anything landing here; it probably belongs in `CLAUDE.md`. |
| **user** | (implicit — single-tenant) | "prefers targeted tests over full suite" | OrcaHub is effectively single-user today. Model the column now, do not build multi-tenancy. |
| **project** | `project_id` | "TriggersTest is a known flake" | **The main tier.** Matches how memories are actually written today. |
| **directory** | `directory` | — | **[INFER]** Probably redundant with `project_id`; `directory` is the *de facto* key today only because the on-disk stores are path-slug-addressed. Prefer `project_id`. |

Cross-cutting **facets** rather than tiers — store as columns, filter at recall:
`backend` (a pi-specific quirk should not be recalled into a Claude session),
`orchestrator` (orchestrator lessons vs. worker lessons are genuinely different — this
codebase already splits its *prompts* on exactly this axis
[CODE `shared_prompts.ex:408-506` `worker_practices_prompt/2` vs
`orchestrator_prompt/3`]), and `node` where a fact is node-local.

### 6.3 What the existing schema makes easy vs. hard

**Easy:**
- Everything in §6.1 is one join from a session id. The `ctx` map at prompt-composition
  time already carries `session_id`, `directory`, `project_id`, `orchestrator`,
  `code_exec`, `issue_key` [CODE `claude.ex:286-325`].
- A `memories` table with `project_id` FK follows the same pattern as `artifacts`
  [CODE `lib/orca_hub/artifacts.ex`] and `issues` — both are project-scoped with
  session provenance recorded as a plain `session_id` field.
- The hub/agent split is already solved: `HubRPC` proxies DB ops from agent nodes
  [CODE `lib/orca_hub/hub_rpc.ex`], and `open_issues_prompt/1` already calls through it
  from prompt composition [CODE `shared_prompts.ex:364`]. **A DB-backed memory store
  works on agent nodes on day one; a node-local file store does not.**

**Hard / needs a decision:**
- **`git repo` is not a column.** The brief lists it as something OrcaHub knows; I could
  not find it on either schema. It is derivable by shelling out in the project directory,
  but note this repo's own recorded lesson (`project-page-load-perf-2026-08`:
  *"recurring bug class = sync shell-out in mount/3"*). **Do not shell out to git during
  prompt composition.** Use `project_id`.
- **Codex's current memories have no project scope at all** (§3.2) — so migrating them
  (§7) requires assigning a scope that does not exist in the source data.
- **pgvector is not installed.** See §8.3.

---

## 7. Migration

### 7.1 What exists to migrate

[OBS] On this node:

```
~/.claude/projects/*/memory/     — per-project, frontmattered, wikilinked.
                                   The orca_hub project alone has 97 memories
                                   indexed in MEMORY.md.
~/.codex/memories/               — 313 files, of which 307 are `claude--*`
                                   mirrors generated by MemorySync (§1.3).
                                   Only 6 native entries.
```

**The mirror count is the migration plan's biggest simplification.** 98% of the Codex
store is a derived copy of the Claude store. **Migrating Claude's memories migrates
essentially everything**, and the `claude--*` mirrors should be *deleted*, not imported —
importing them would duplicate every Claude memory. They are trivially identifiable:
`MemorySync` prefixes every mirror with `<!-- orca-sync` [CODE `memory_sync.ex:35`] and
names them `claude--*` [CODE `memory_sync.ex:36`], and OrcaHub already has the predicate
`provenance_tagged?/1` [CODE `memory_sync.ex:226-228`].

The 6 genuinely-native Codex entries (`MEMORY.md`, `memory_summary.md`,
`raw_memories.md`, `rollout_summaries/`, `skills/`, `extensions/`) are Codex's own
consolidation artifacts. **[INFER]** `raw_memories.md` and `rollout_summaries/` are
per-thread task logs — the user's own curation note in
`~/.claude/codex-memory-digest.md` says they deliberately dropped *"per-thread task logs
and stale/environment-specific trivia"* when hand-curating. That is a strong signal:
import `memory_summary.md`'s durable bullets, drop the rollout logs.

### 7.2 Is the existing frontmatter format worth keeping as the native schema?

**Yes for the fields; no for the storage.** Concretely:

Keep as **columns**:
- `name` (kebab-case slug) — natural unique-per-project key.
- `description` — one-line summary, and its stated purpose is literally
  *"used to decide relevance during recall"*. That is a ready-made field to embed for
  retrieval, distinct from the body. Genuinely well-designed for this.
- `metadata.type` ∈ `user | feedback | project | reference` — a small, closed, *already
  populated* taxonomy. Cheap to keep, useful as a recall facet (e.g. always push
  `feedback`, retrieve `reference` on demand).
- body markdown.

Keep as a **relation**, not text:
- `[[wikilink]]` cross-references. Currently free text parsed by nobody
  [CODE `agent_memory.ex` parses `name`/`description`/`type` only — **there is no
  wikilink parsing anywhere in the codebase**]. The convention's own instruction says a
  link to a not-yet-existing memory is fine — *"it marks something worth writing later,
  not an error"* — so a `memory_links` table needs to tolerate dangling targets, exactly
  like `MEMORY.md` already tolerates `dangling` index entries
  [CODE `agent_memory.ex:131-137`].

**[INFER]** Graph traversal over those links is a cheap, high-value retrieval boost:
retrieve top-k by embedding, then pull in 1-hop neighbours. That is most of what mem0's
paid-tier graph memory offers, over data we already have, in one recursive CTE. Worth
noting since "graph memory is gated to mem0's paid tier" was called out in the brief as
an Option A limitation — **Option B gets a useful subset of it for free.**

**Do not keep:** the `MEMORY.md` index-file-as-source-of-truth. It should become a
*generated artifact* (§3.1's redirect target), regenerated from the store — which
conveniently also fixes the `orphaned`/`dangling` drift the current code has to defend
against [CODE `agent_memory.ex:131-137`].

### 7.3 Import mechanics

**[INFER]**, but low-risk:

1. `AgentMemory.list_claude_memories/2` [CODE `agent_memory.ex:80-140`] already returns
   exactly the parsed shape needed (`filename`, `name`, `description`, `type`,
   `content`) — the importer is a `Cluster.rpc` fan-out over projects calling an existing
   function. **The reader is already written.**
2. Per-node fan-out is required (memories live on the project's owning node, and
   `AgentMemory` is explicitly designed to be called via `Cluster.rpc/4`
   [CODE `agent_memory.ex` moduledoc]). This means gb10/mini/dell each hold memories that
   need collecting.
3. Idempotency: key on `(project_id, name)` so a re-run updates rather than duplicates.
4. Embeddings can be backfilled lazily — import text first, embed after.

**Migration is genuinely low-risk** because the source data is small (hundreds of files,
not hundreds of thousands), well-structured, already parsed by existing tested code, and
— critically — **git-backed with Gitea remotes** [CODE `memory_git.ex`], so a botched
import is recoverable.

---

## 8. Recommendation

### 8.1 The call: Option B, native to OrcaHub

I agree with the stated prior, and the code strengthens rather than weakens it. The
reasoning, ordered by how much weight I put on it:

**1. Push-recall is the whole ballgame, and mem0 does not help with it.**
The design succeeds or fails on whether retrieved memories reach the model without the
agent having to ask. That work happens entirely inside `SharedPrompts` and the three
`system_prompt/1` implementations — OrcaHub code either way. mem0 would be a store
behind an HTTP call in the middle of `open_issues_prompt`-shaped code. **Option A does
not remove a single line of the hard part; it adds a network hop to it.**

**2. Interop is not a differentiator, and the brief is right that it is not.** OrcaHub is
already an MCP server with a category-based tool registry
[CODE `lib/orca_hub/mcp/tools.ex:53-65`]. A `Tools.Memory` category is reachable by
Cursor/Claude Desktop/anything else exactly as mem0's would be. This one is settled.

**3. Scoping is strictly better in B, and it is free** (§6.1). mem0's
`user_id`/`agent_id`/`run_id` would require encoding OrcaHub's dozen-plus real dimensions
into three opaque strings, losing relational query in the process.

**4. The hub/agent topology actively punishes an external service.** Agent nodes have no
DB access and proxy everything through `HubRPC` [CODE `lib/orca_hub/hub_rpc.ex`,
`.context/clustering.md`]. A Postgres-backed store inherits that plumbing for free and
works on gb10/mini/dell on day one. A mem0 service becomes a second thing that must be
reachable, and `MCP.UpstreamClient` — the existing external-service pattern — is
**hub-only** [`.context/clustering.md`], so an agent-node session could not reach mem0
without new routing.

**5. `pi`'s byte-determinism constraint (§2.3) needs bespoke handling regardless.** No
external memory service knows or cares that pi's prompt prefix must be byte-stable. That
integration is custom work in `Backend.Pi` under either option.

**6. Option A has an unresolved hard dependency today** (§5.4): mem0 requires an LLM call
on every write, and I could not reach an OpenAI-compatible endpoint on GB10. Option B can
ship phase 1 with **no LLM dependency at all**.

**What Option A genuinely buys**, stated fairly: mem0's extraction/dedup/conflict
prompts are real, non-trivial, and battle-tested, and rebuilding them is the one place
Option B pays a real cost. My counter is that (a) their prompts are readable and
borrowable — the *ideas* transfer without the service, and (b) §5.3 defers that whole
problem out of phase 1 anyway.

**The honest case against my own recommendation:** if the extraction quality turns out to
be the entire value of the system, then B means we own an LLM-prompt-engineering problem
we could have rented. That is a real risk and it is why §8.5 lists it as the primary
mind-changer.

### 8.2 Effort estimate

Rough, and I would treat the phase-3 number as the least trustworthy.

| | Option A (mem0) | Option B (native) |
|---|---|---|
| Store + schema | ~1d (deploy, wire DB) | ~2-3d (migration, Ecto schemas, embeddings) |
| Ops footprint | **ongoing** — a Python service on the k3s/Flux path, its own image, its own failure mode | **none new** — same Repo, same migrations, same deploy |
| Push path (3 backends) | ~2-3d | ~2-3d *(identical work)* |
| MCP tools | ~1d | ~1d *(identical work)* |
| Extraction logic | ~0 (provided) | ~3-5d (borrowed prompts + eval loop) |
| Suppression/redirect wiring | ~2d | ~2d *(identical work)* |
| Migration/import | ~2d + schema-shape impedance | ~1-2d (reader already exists, §7.3) |
| LLM endpoint dependency | **blocking** (§5.4) | deferrable to phase 3 |

Net: **A ≈ 9-11d + a permanent service; B ≈ 11-16d and nothing new to operate.** The
gap is smaller than it looks because 6 of those days are the same work either way, and B's
extra days are front-loaded into things we would want to own regardless.

### 8.3 Biggest risks

1. **pgvector is not installed, and installing it needs superuser.** [OBS] The extension
   is *available* (`vector` 0.8.2) but not installed in either `orca_hub_dev` or
   `orca_hub_prod`, and [OBS] the `orca_hub` role is **not** a superuser. [OBS] I read
   `vector.control` and it has **no `trusted = true`** line — so `CREATE EXTENSION vector`
   as `orca_hub` will fail. This is a one-time `docker exec postgres psql -U postgres`
   step against the host Compose Postgres, but it is a **prerequisite for both options**
   and it is outside Flux/GitOps. Easy to overlook and it will block phase 2.
2. **Prompt-golden churn.** Claude and Codex prompts are byte-pinned by fixtures
   [CODE `test/support/fixtures/prompt_goldens/{claude,codex}.txt`]. Every prompt change
   regenerates them. Routine, but it makes prompt changes noisy in review.
3. **pi fork-cache regression.** The single highest-consequence mistake available here is
   putting recall in pi's system prompt (§2.3). It would be silent — no test failure,
   just 26s prefills and a cratered llama-server. The `"system_prompt/1 — byte
   determinism"` test guards it; **anyone touching this must not weaken that test.**
4. **Context-budget regression** (§4.3). We are replacing a system that already
   over-injected by 21k tokens. Without a hard byte cap we rebuild the same problem with
   better technology.
5. **Two writers during redirect** (§3.1). If Claude's built-in keeps writing while
   OrcaHub owns the store, reconciliation is needed. Mitigated by `mode: "ro"` **if**
   `CLAUDE_MEMORY_STORES` works as read [BIN, unverified].
6. **All Claude levers are [BIN], not documented.** They can change on any CLI release —
   and this deployment auto-updates the CLI. Whatever we pick needs a startup assertion
   or a smoke test, not silent trust.
7. **Extraction cost/quality** (§8.1) — the main argument for A.

### 8.4 Phased path

Each phase delivers standalone value and is independently revertible.

**Phase 0 — de-risk (≈1 day, no production change).**
Confirm the [BIN] findings by running them: does `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`
actually disable it; does `autoMemoryDirectory` relocate the store; does
`CLAUDE_MEMORY_STORES` with `mode:"ro"` + `promptIndex` work outside the GrowthBook flag;
does `-c features.memories=false` take on codex 0.146.0. Also: `CREATE EXTENSION vector`
as superuser on the dev DB, and settle the GB10 endpoint question (§5.4).
**This phase is cheap and it converts the six biggest unknowns in this document into
facts.** Do not skip it.

**Phase 1 — the store + explicit writes + push, no LLM (≈4-6 days).**
`memories` table (+ `memory_links`), Ecto schemas, `Tools.Memory` MCP category with
`memory_write`/`memory_search`, importer for existing content (§7.3), and the pushed
recall fragment on all three backends with a hard byte cap. Embeddings optional — start
with `pg_trgm`/full-text if that defers the pgvector prerequisite.
**Value delivered:** one store, cross-harness, replacing the file mirror. **`MemorySync`
can be deleted here** — that alone recovers the 21k-token tax (§1.3).

**Phase 2 — redirect the harnesses (≈3-4 days).**
Generate Claude's `MEMORY.md`/auto-memory directory from the store (§3.1), suppress
Codex's built-in (§3.2), replace `claude-memories.ts` with a store-fed pi extension
shipped as a `pi_config_entries` row (§3.3). Remove the `CLAUDE.md` @-import (§3.4).
**Value delivered:** the store becomes the single source of truth; built-in machinery
still works, now fed by us.

**Phase 3 — post-hoc extraction (≈3-5 days, gated on an LLM endpoint).**
Sibling GenServer off the idle hook (§5.1), reading transcripts (§5.2), with
mem0-inspired extract/dedup/conflict prompts. Backfill over the existing 813k messages.
**This is the only phase that needs the GB10 endpoint, and the only one where the
A-vs-B choice would have materially changed the work.**

### 8.5 What would change my mind

Honestly stated — these are not rhetorical:

1. **If Phase 0 shows extraction quality is the whole product.** If a spike shows naive
   extraction produces junk and mem0's produces gold, the calculus flips: rent it, keep
   OrcaHub as the push layer in front. **This is the most likely mind-changer.**
2. **If multi-tenancy becomes real.** mem0's `user_id` model is weak for us *because* we
   are single-user; with real tenants its scoping is a head start rather than a downgrade.
3. **If mem0 turns out to run acceptably as a sidecar with no LLM on the write path**
   (deterministic/embedding-only dedup mode). That removes both the GB10 dependency and
   most of the operational objection.
4. **If pgvector cannot be installed on the host Postgres.** That is a shared,
   deliberately-outside-k3s database [global CLAUDE.md]. If a superuser extension install
   is refused, Option B's store needs a different home and mem0-with-its-own-DB becomes
   comparatively more attractive.
5. **If someone wants memory shared with non-OrcaHub tooling that already speaks mem0.**
   No evidence of that today.

What would *not* change my mind: interop (§8.1 item 2), and "mem0 is faster to stand up"
(§8.2 — the gap is ~6 shared days either way, and A's ongoing ops cost is permanent).

---

## 9. Things that surprised me / contradict the brief's framing

Collected here so they are not buried:

1. **OrcaHub already has a unified memory system** — `MemorySync` (§1.3). The brief
   framed this as greenfield. It is not: it is a *replacement*, and the incumbent's
   observable failure mode (21k tokens of unconditional context tax, hand-curated back
   down by the user) is the strongest available argument for the semantic approach.
2. **307 of 313 files in `~/.codex/memories` are OrcaHub-generated mirrors.** The Codex
   store is 98% derived data. This simplifies migration enormously (§7.1).
3. **pi's system prompt is byte-frozen and recall must not go there** (§2.3). This
   directly contradicts the brief's uniform "inject into the prompt it already builds"
   model for one of three harnesses. The correct pi seam (`ORCA_IDENTITY` + extension)
   exists and is documented, but it is a different seam.
4. **The Codex "rollout-summary pipeline" is not Zach's** (§3.2) — no cron, no timer, no
   script. It is Codex's own `[features] memories` consolidation. There is nothing to
   port, only a vendor feature to disable.
5. **Claude Code has far more control surface than expected** (§3.1): a documented-ish
   `autoMemoryEnabled` settings key, an `autoMemoryDirectory` *redirect*, a
   `CLAUDE_MEMORY_STORES` mount system with `mode:"ro"` + `promptIndex` +
   `promptIndexMaxBytes`, and an entire first-party remote `/memories` REST API. The
   brief asked "is there a flag, or is it prompt-level only?" — the answer is emphatically
   the former.
6. **pi already ships a working push-recall extension** (`claude-memories.ts`, §3.3) that
   reads Claude's `MEMORY.md` and injects it as a `custom_message`. The hardest harness
   already has a proof of concept in production.
7. **pgvector is not actually installed** (§8.3) and cannot be installed by the app's own
   DB role. The brief treated "existing Postgres already has pgvector" as settled; the
   *image* has it, the *database* does not.
8. **The GB10 endpoint is not reachable** (§5.4). The brief said "verify before relying
   on it" — verified, and it did not answer on any standard port.
9. **`open_issues_prompt/1` is a complete working precedent for push-recall** (§4.1) —
   live DB query, spliced into all three backends, with a `nil`-to-omit convention worth
   copying. The riskiest-sounding part of the design is the part that is already proven.

---

## Appendix: verification log

Commands run (all read-only):

- `psql` via `docker exec postgres` against `orca_hub_dev` / `orca_hub_prod`: row counts,
  `pg_extension`, `pg_available_extensions`, DB size, session backend/model breakdown,
  `pi_config_entries` provider rows.
- `docker exec postgres cat .../extension/vector.control` — checked for `trusted`.
- `strings` over `/home/zach/.local/share/claude/versions/2.1.241` — memory env vars,
  settings keys, store descriptor schema, `/memories` REST client. **Static read only;
  nothing executed.**
- `claude --help`, `claude --version` (2.1.241); `codex --version` (0.146.0);
  `pi --help`.
- `cat ~/.codex/config.toml`; `ls ~/.codex`, `~/.codex/memories`, `~/.pi/agent`,
  `~/.pi/agent/extensions`.
- `crontab -l`, `systemctl --user list-timers` — both empty.
- `curl` against `192.168.1.77` ports 8080/8000/11434/1234/5000/30000/4001.
- Repo reads: `lib/orca_hub/backend/{shared_prompts,claude,codex,pi}.ex`,
  `lib/orca_hub/{agent_memory,memory_sync,memory_git}.ex`,
  `lib/orca_hub/memory_git/server.ex`, `lib/orca_hub/claude/config.ex`,
  `lib/orca_hub/mcp/tools.ex`, `lib/orca_hub/sessions/{session,message}.ex`,
  `lib/orca_hub/projects/project.ex`, `priv/pi/orca-identity.ts`,
  `~/.pi/agent/extensions/claude-memories.ts`.

**Not verified / open:**

- Every [BIN] Claude lever — read from the binary, never executed (Phase 0 item).
- `-c features.memories=false` on codex 0.146.0 — inferred from the `-c` mechanism.
- GB10 LLM endpoint — not reachable from this host; did not ssh in.
- `CREATE EXTENSION vector` — not attempted (would have been a write).
- mem0's actual API/schema — not investigated; Option A is costed from the brief's
  description plus this repo's constraints, not from mem0's source.
