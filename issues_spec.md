# Issues Spec — Durable Work Items for Agent-Driven Development

**Status:** Design only — nothing in this spec is implemented. Written for a
follow-up implementation worker to build from directly.
**Goal:** Bring back a general-purpose `issues` feature (removed in `3ebb3fe`,
minimally reintroduced only as the feature-request backlog) as a **durable,
agent-usable work item** — narrative history an agent writes as a byproduct of
doing work, not a ticket a human grooms. The feature-request board becomes a
filtered view of the same table (`kind: "feature_request"`) instead of a
separate title-prefix hack.

**Revision v2** (folds in decisions from the 2026-08-06 revision request):
short issue keys are **per-project**, not global (§3.2); the FR tool names
are **migrated and dropped**, not kept as permanent aliases (§8); attempt
summaries are now **frozen at close** alongside commits, same pattern
(§4.3); closed issues are **retroactively amendable** via a
preserve-then-append mechanism, reopening is spec'd, and a new
`superseded_by` link is added (§3.1, §6.4, §11). v1's two "left open" forks
are both resolved and folded inline — there is no more open-fork section.
This revision also fixes several `§N` cross-reference errors found in v1
while rewriting around them (e.g. the dedup carry-over pointer in §2.3 was
pointing at the wrong section) — corrected throughout, not called out
individually.

---

## 1. Motivation and the organizing principle

OrcaHub already has a memory system: every agent session can write durable,
git-synced markdown files with YAML frontmatter
(`~/.claude/projects/<slug>/memory/*.md` for Claude, mirrored by
`OrcaHub.MemorySync` into `~/.codex/memories/`). That system is **normative
and present-tense** — "commit directly to master," "verify with targeted
tests only." Its failure mode is that a rule outlives the reason it existed:
six months from now nobody remembers *why* "always do X," and nobody can
check whether the premise behind it still holds.

Issues are the other half. **Memory instructs; an issue explains.** An issue
is narrative and past-tense: what was broken, what we tried, what landed,
what we were assuming when we started. It is inert once closed — a record,
not a rule.

**This is the spine of the whole design and every section below defers to
it.** An issue must never carry standing guidance ("from now on, always...").
If an issue's `notes`/`resolution` starts accumulating that kind of content,
that content escaped to the wrong system — it belongs in a memory file (with
this issue cited as its `issue:` provenance, §11), not left to rot silently
in a closed issue nobody re-reads. Conversely, a memory file should never
try to hold the "what we tried and why" narrative — that belongs here.

v1 of Issues (removed in `3ebb3fe`) died because the human wasn't using it —
it was a human-facing ticket tracker nobody groomed. This attempt's premise
is different: **the consumer is agents**, and agents already write durable
narrative text via `report_progress`/session final messages/commit
messages — issues just need to be the place that narrative *sticks* instead
of evaporating when a session archives or a context window compacts.

---

## 2. Current state (read before designing further)

### 2.1 `OrcaHub.Issues.Issue` (`lib/orca_hub/issues/issue.ex`)

```
schema "issues" do
  field :title, :string
  field :description, :string
  field :status, :string, default: "open"      # open | in_progress | closed
  field :approaches_tried, :string               # free text, append-only by convention
  field :notes, :string                          # free text, append-only by convention
  belongs_to :project, Project
  timestamps()
end
```

No `kind`, no `plan`/`resolution`/`premise`, no `commits`, no
`created_by_session_id`/`closed_by_session_id`, no keys, no `superseded_by`.
`approaches_tried` and `notes` are both free text with no structural
difference between them today beyond the field name — `append_note/2` in
the context only ever writes to `notes`; nothing in the current code path
writes `approaches_tried` at all.

Also confirmed while re-reading for this revision: `OrcaHub.Projects.Project`
(`lib/orca_hub/projects/project.ex`) has no `key_prefix`/`issue_counter` (or
anything like them) today — fields are `name`, `directory`, `deleted_at`,
`node`, `env_allowlist`, `commit_trailer`. §3.2 adds both as net-new columns.

### 2.2 `OrcaHub.Issues` context (`lib/orca_hub/issues.ex`)

CRUD + `list_open_issues_for_project/1` (`status != "closed"`),
`list_issues_for_project/1`, `list_issues_by_id_prefix/1` (backs short-id
resolution), `append_note/2`, `close_issue/1` (→ `status: "closed"`),
`reopen_issue/1` (→ `status: "open"`, no side effects today). No concept of
sessions, attempts, commits, or supersession anywhere in this module.

### 2.3 `OrcaHub.MCP.Tools.FeatureRequests` (`lib/orca_hub/mcp/tools/feature_requests.ex`)

Five tools: `file_feature_request`, `list_feature_requests`,
`get_feature_request`, `append_feature_request_note`,
`close_feature_request`. All hardcoded to file against
`@orca_hub_directory = "/home/zach/orca_hub"` — this tool is deliberately
"tell the OrcaHub maintainers," not "file an issue in my own project." Agent
identity is `"[agent-fr] "` title prefix, scope-checked on every read/write
(`String.starts_with?(title, @title_prefix)`).

**Dedup** (`find_similar_open_issue/2`): case-insensitive substring or
≥60% word-overlap against OPEN, agent-filed issues in the same project. This
is real, implemented, and works — carry it over (§7).

**Id resolution** (`fetch_agent_issue/1`): accepts a full UUID or an
unambiguous hex prefix (≥8 chars, dashes optional), rejects anything else
with a friendly error before it reaches the DB, disambiguates multiple
prefix matches with an error listing them.

### 2.4 ⚠️ Correction to the brief: "close-requires-evidence" is not
implemented today

The brief says to carry over "title-similarity dedup, and close-requires-evidence"
verbatim from the FR board. I read the actual code: `close_feature_request`'s
`resolution_note` is **optional** —

```elixir
"resolution_note" => %{
  "type" => "string",
  "description" => "Optional note recording how/where this was resolved, e.g. a commit SHA."
},
"required" => ["id"]
```

— and `close_request/3` calls `HubRPC.close_issue/1` unconditionally whether
or not a note was supplied. There is no enforcement anywhere that closing
requires evidence; it's purely a documentation nudge in the tool
description ("Pass a `resolution_note`... to record how it was resolved").
**"Close requires evidence" doesn't exist as code to carry over — it's a
new requirement this spec introduces** (§6.6: `resolution` becomes
`required`). Kept prominent in this revision because it was reiterated as
fact in the original brief and it's still true that the correction stands —
the new required `resolution` field is a genuinely new behavior, not a
restoration of something that existed before.

### 2.5 `sessions.issue_id`

Confirmed via `priv/repo/migrations/20260228022231_create_issues.exs`:

```elixir
alter table(:sessions) do
  add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
end
```

This is a **real DB-level foreign key**, not a plain column — it was never
dropped, just never cast into `OrcaHub.Sessions.Session`'s changeset or
declared as a `belongs_to`. Reviving it is a pure application-layer change
(schema + changeset), **no migration needed** for this column specifically.

Note this is a different convention than `Session.parent_session_id` and
`Trigger.last_session_id`, which the data model doc calls out as
deliberately "plain field, no assoc" (no DB FK at all) — likely to avoid
cascade/lock concerns on the high-churn `sessions` table. `issue_id`
already broke from that convention in the original migration; §3.6 below
recommends the new `created_by_session_id`/`closed_by_session_id` columns
follow `issue_id`'s precedent (real FK) rather than
`parent_session_id`'s, since both are Issue-side references — flagged
as an open judgment call for the implementer, not a hard requirement.

### 2.6 Existing `/issues` UI

`lib/orca_hub_web/live/issue_live/{index,show}.ex`, routed at `/issues` and
`/issues/:id`. Read-only listing + close/reopen buttons. This UI will need
updates to show the new fields (`kind` filter, `key`, `plan`/`resolution`/
`premise`, frozen `commits`/`attempts`, `superseded_by`) — **out of scope
for this spec's tool surface work**, called out as a required follow-up in
§12.

---

## 3. Data model

### 3.1 `issues` table — new columns

| Column | Type | Notes |
|---|---|---|
| `kind` | `string`, not null, default `"task"` | `"task"` \| `"feature_request"`. Replaces the `[agent-fr] ` title-prefix hack entirely. |
| `key_number` | `integer`, nullable | Per-project sequence number — `key_number` combined with the owning project's `key_prefix` renders the human-facing key, e.g. `ORCA-142`. See §3.2. |
| `plan` | `text`, nullable | Mutable, orchestrator-owned. The one field designed to be *rewritten in place* as understanding changes — see §10 (resume hook). |
| `resolution` | `text`, nullable until close | Written once, at `close_issue` time; may be **amended** afterward (§6.4) but the prior value is always preserved, never silently overwritten. Narrative of what actually happened, for both `resolved` and `abandoned` outcomes (§6.6). |
| `premise` | `text`, nullable | The assumption that makes this issue worth doing. Deliberately a **separate field from `resolution`**, not folded in — see §3.1.1. Also amendable post-close under the same preserve-then-append rule as `resolution`. |
| `commits` | `{:array, :map}` (jsonb), default `[]` | Frozen at close only. `[{hash, short_hash, subject, author, date}]` — same shape `Sessions.list_session_commits/2` already returns, reused verbatim so no new serialization format exists. Empty while open (derived live instead, §4). Cleared back to `[]` on reopen (§3.5.1). |
| `attempts` | `{:array, :map}` (jsonb), default `[]` | **New in this revision.** Frozen at close only, alongside `commits` — a compact `[{session_id, status, outcome}]` summary of every linked attempt session (§4.3). Empty while open (the live, richer projection is used instead — see §3.5 and §6.3). Cleared back to `[]` on reopen. |
| `created_by_session_id` | `binary_id`, FK → `sessions.id`, `on_delete: :nilify_all` | Set once, at creation. The orchestrator-facing identity link (§3.4) — orchestrators touch many issues and can't use `has_many` ownership. |
| `closed_by_session_id` | `binary_id`, FK → `sessions.id`, `on_delete: :nilify_all` | Set at close. Cleared on reopen (prior value preserved in the auto-note, §3.5.1). |
| `closed_at` | `utc_datetime`, nullable | **New in this revision**, added beyond what was literally asked for a specific reason: `updated_at` (from `timestamps()`) gets bumped by *any* later write, including a post-close amendment (§6.4) — so it can no longer answer "when did this actually close" once amendments/reopens exist. `closed_at` is a dedicated marker, set only by `close_issue`, cleared only by reopen. This is exactly the "what was known AT CLOSE vs. added later" distinction the human asked this feature to protect, and `updated_at` alone can't provide it once amendment exists. |
| `superseded_by_issue_id` | `binary_id`, self-referential FK → `issues.id`, `on_delete: :nilify_all` | **New in this revision.** "Replaced by ORCA-201" — structured and queryable rather than buried in `resolution` prose. See §3.1.2 and §11. Settable via `update_issue` or `close_issue` (§6.4/§6.6), regardless of the issue's own status — you might discover the superseding issue mid-investigation, before you've even closed this one. |

`status` validation gains a fourth value: `~w(open in_progress closed abandoned)`.
`closed` and `abandoned` are both terminal — every "must be open" check
(`list_open_issues_for_project`, dedup scope, `update_issue`'s status
guard in §6.4) treats them identically as "not open."

`title`, `description`, `approaches_tried`, `notes`, `project_id` are
unchanged.

#### 3.1.1 Why `premise` is separate from `resolution`

Decision, stated explicitly per the brief: `premise` must be independently
queryable so a memory audit can ask "for every standing rule that cites an
issue, does that issue's premise still hold?" without needing to parse it
back out of a `resolution` blob that also contains unrelated narrative
about *how* the work got done. `premise` answers "why did this matter,"
`resolution` answers "what happened." They can (and often will) diverge —
an issue can be `abandoned` specifically *because* its premise turned out
to be false, which is itself the whole point of writing `premise` down.

#### 3.1.2 Why `superseded_by` is a structured field, not prose

Same reasoning as §3.1.1, one level further: "this was replaced by
ORCA-201" is the single highest-value thing a future reader can learn from
a closed issue, and it's exactly the kind of fact that gets buried and lost
if it's only ever mentioned in passing inside a `resolution` paragraph. A
real FK means `get_issue` can resolve and surface it as a first-class
`{id, key, title, status}` summary (§6.3) rather than requiring a reader to
notice a stray mention and go hunting — and it's what makes the memory-audit
walk in §11 ("does the cited issue's premise still hold, and if not, did it
get superseded by something whose premise *does*") a single extra hop
instead of a text-search.

### 3.2 Per-project short keys (`ORCA-142`)

**Resolved in this revision: keys are per-project, not global.** The
original recommendation in this spec's first draft was global sequencing,
on the grounds that a per-project key would "break" if an issue moved
projects. That objection doesn't hold: **the key is an immutable
identifier assigned once at creation, not a derived/live property of
`project_id`.** `ORCA-142` stays `ORCA-142` even if `project_id` is later
changed (there's no code path that does this today, but nothing prevents
it either) — a prefix that no longer matches its current project is an
acceptable, expected historical artifact, same as a GitHub PR number
staying stable across a repo transfer.

**Per-node keying was also considered and rejected.** Recorded here so it
isn't re-litigated later: nodes are routing infrastructure, not a semantic
domain an issue belongs to, and node names are **mutable** — the GB10 node
was recently renamed `gb10@192.168.1.76` → `.77` in prod. Keying a durable,
citable artifact on a mutable infra identifier is precisely the failure
mode `superseded_by` and `key_number` are trying to avoid elsewhere in this
spec. It also buys nothing technically: allocation is centralized on the
hub regardless of which scheme is chosen (below), so per-node keying isn't
solving a distributed-counter problem that per-project keying doesn't
already solve equally well.

#### 3.2.1 Schema

```elixir
alter table(:projects) do
  add :issue_counter, :integer, null: false, default: 0
  add :key_prefix, :string
end
create unique_index(:projects, [:key_prefix])
```

`key_prefix`: uppercase letters/digits, 2–10 chars, **must start with a
letter**. The "starts with a letter" rule isn't cosmetic — it's what keeps
a rendered key like `ORCA-142` structurally distinct from a hex UUID
prefix (`bbdce095-4e41-...`) during id resolution (§3.2.4), since a UUID
segment is never letter-then-digits shaped in that way once `a-f`-only hex
is excluded from the prefix's *first* character requirement in practice
(real project names essentially always contain a letter outside `a-f`).

#### 3.2.2 Allocation — atomic, race-free, centralized by construction

```elixir
{1, [key_number]} =
  from(p in Project, where: p.id == ^project_id, select: p.issue_counter)
  |> Repo.update_all(inc: [issue_counter: 1])
```

**Correction (found during implementation):** an earlier draft of this
snippet used `returning: [:issue_counter]` on the `Repo.update_all/3` call
instead. On this Ecto/ecto_sql version that option is silently a no-op for
`update_all` — the second element of the returned tuple is `nil` unless the
query itself carries a `select`, unlike `insert`/`delete` where `returning:`
does work. The `select: p.issue_counter` form above is what actually gets
the post-increment value back; corrected in place so a future reader
doesn't reintroduce the no-op form. See `OrcaHub.Issues.allocate_key_number/1`
for the shipped version of this query.

This is Postgres row-level locking doing the work — no dynamic DDL, no
`MAX(key_number) + 1` retry loop, no separate sequence object to manage.
**The hub owns the only DB** (agent nodes create issues via `HubRPC`, same
as sessions) — allocation is centralized by construction, so there is no
distributed-counter problem to solve here at all, which is the concrete
technical reason per-node keying (above) has no upside: centralization
already happens regardless of which dimension the key is scoped to.

Recommend wrapping the increment + the `Issue` insert in one
`Repo.transaction`/`Ecto.Multi` — a changeset validation failure on the
insert then rolls back the increment too, so gaps mostly don't occur from
that path. **Gaps are still acceptable if they occur** — say so plainly
rather than engineering around it: a `key_number` is an identifier, not an
accounting ledger, and nothing downstream (dedup, resolution, the trailer)
assumes contiguity. If a future maintainer instead implements this as two
separate, non-transactional steps for simplicity, a validation failure
after a successful increment will permanently burn that number — that's a
deliberately acceptable outcome, not a bug to chase.

#### 3.2.3 Backfilling `key_prefix` for existing projects

Auto-derivation alone is insufficient, by the human's own example: `orca_hub`
and `orca-artifacts` both naturally derive to `ORCA`. One-time migration
backfill, deterministic and reproducible:

```sql
-- 1. Derive a raw candidate per project (strip non-alnum, uppercase, truncate).
-- 2. Process in a stable order (e.g. inserted_at ASC) so the same input
--    always produces the same output if re-run against a fresh copy of prod data.
-- 3. First project to claim a candidate prefix wins it unmodified; every
--    later project whose candidate collides gets a numeric suffix appended
--    (ORCA, then ORCA2, ORCA3, ...) until unique.
```

This is a one-time, honestly-a-bit-ugly backfill (`ORCA2`, `ORCA3` are not
great keys) — accepted as such because it only has to run once against a
small, known table (projects), and any project whose auto-derived prefix
looks bad can be manually renamed by the human after the fact (a simple
`UPDATE projects SET key_prefix = ...` — the unique index is the only
constraint, existing issue keys are unaffected since they only store
`key_number`, not a denormalized prefix string).

**Collision handling at project creation, going forward, is NOT the same
mechanism.** For a *new* project, silently minting `ORCA2` is a worse user
experience than just asking — project creation is rare and deliberate
(unlike issue creation, which needs to be silent/automatic). Recommend
`create_project` gain an optional `key_prefix` argument with a
live-validated **suggestion** pre-filled from the name (checked for
uniqueness at input time, editable before submit) rather than a blind
auto-suffix — the same UX pattern GitHub/Linear/Jira use for their own
project-key pickers. If no explicit prefix is given and the derived
suggestion collides, `create_project` should error asking for an explicit
one rather than silently minting a numbered variant.

#### 3.2.4 Id resolution — three forms, in order

Every tool that accepts an issue id (`get_issue`, `update_issue`,
`append_issue_note`, `close_issue`, `start_session`'s `issue_id` arg) tries,
in order:

1. **Full UUID** — exact match on `issues.id` (unchanged from today).
2. **Rendered key** (`^[A-Za-z][A-Za-z0-9]{1,9}-[0-9]+$`) — split into
   `{prefix, number}`, resolve `prefix` case-insensitively against a real
   `projects.key_prefix`, then look up `issues` by `(project_id,
   key_number)`. **Only matches if a project with that exact prefix
   actually exists** — this existence check, combined with `key_prefix`
   requiring a leading letter (§3.2.1), is what keeps this pattern from
   ever colliding with a hex UUID prefix that happens to contain a dash.
3. **Hex prefix** (≥8 chars, dashes optional) — unchanged fallback from
   today's `fetch_agent_issue_by_prefix/1`, disambiguated the same way
   (error listing all matches if ambiguous).

Note the rendered key is **globally resolvable without knowing which
project it belongs to** even though the *counter* is per-project — because
`key_prefix` itself is globally unique (§3.2.1's unique index), `ORCA-142`
unambiguously identifies one issue system-wide, the same way a raw UUID
does. Per-project scoping only affects how the *number* is allocated, not
how the rendered key is looked up.

#### 3.2.5 The trailer

`OrcaHub-Issue: ORCA-142` — confirmed as the concrete form (§5), key
preferred over UUID as the taught/example form in all prompt-facing text,
since that's the whole point of adopting keys. UUID resolution stays valid
and unremoved (§3.2.4 form 1) — nothing about this deprecates raw ids, it
just stops teaching them as the primary form.

### 3.3 `sessions` — revive `issue_id`

Add to `OrcaHub.Sessions.Session`:

```elixir
field :issue_id, :binary_id
belongs_to :issue, OrcaHub.Issues.Issue, define_field: false
```

(`define_field: false` since the FK column is a plain `binary_id` reference,
not the primary key type declaration pattern used elsewhere in this schema —
match whatever convention `parent_session_id`'s sibling fields use if one
already exists; if none does, a plain `field :issue_id, :binary_id` with no
`belongs_to` at all is equally valid and matches how `parent_session_id`
itself is handled — **flagging this as an implementation detail the
implementer should just pick, not something the spec needs to nail down**.)

Add `:issue_id` to the changeset's `cast/2` list. **Read the relationship
as "this session is an ATTEMPT at this issue,"** not ownership — a session
can be linked to at most one issue at a time, but an issue can have many
attempt sessions across its lifetime (retries, follow-ups, a worker spawned
specifically to continue where a prior attempt left off).

### 3.4 Cardinality and why orchestrators need their own fields

Decision (already made, documented here with rationale): `issue.id
has_many sessions via sessions.issue_id`. This works cleanly for **worker**
sessions — a worker doing focused, bounded work naturally has zero or one
issue it's attempting. It does **not** work for **orchestrators** —
an orchestrator routinely touches many issues in one session (files three,
closes one, updates the plan on a fourth) and has no single "the issue I'm
attempting." Hence `created_by_session_id`/`closed_by_session_id`: identity
markers ("who filed/closed this"), not attempt links. An orchestrator is
never expected to set its own `session.issue_id`.

### 3.5 What "attempt" means — deliberately NOT a new table

This is the most important design call in this spec and it is **not**
explicitly settled by the brief, so it's called out here as a decision made
during design, not dictated. Two designs were considered:

**A. A separate `issue_attempts` table**, written to explicitly (or via a
`SessionRunner` hook) at some point in a session's life.

**B. No new table at all — an "attempt" is a query-time projection over
`sessions where issue_id = ?`.** Everything the brief lists as the
foundation — "session final assistant message, terminal status
(idle/error), and commits" — is *already* durably persisted with **zero
new write path**: `session.status` already transitions to `idle`/`error`
via `SessionRunner`'s existing state machine, the final assistant message
already lives in the `messages` table (same data `get_session_tail`
already reads), and commits are already derivable via
`Sessions.list_session_commits/2`. `get_issue` (§6.3) assembles the
"attempts" array live, the same way `search_sessions`'s
`include_activity` option computes activity metadata live rather than
maintaining a running counter.

**This spec chooses B while open**, and adds a close-time freeze on top of
it in this revision (§4.3) — the human's own call, made independently of
the human's decision on §3.4's original open/not-open question, which
stays unchanged. Rationale for B: it's the design that best satisfies "the
attempt record's foundation must be involuntary... zero compliance
dependency" — there is *nothing to forget to call*, because nothing needs
to be called. A worker that never touches an issue-related tool still
produces a complete attempt record the moment it goes idle or errors,
purely as a side effect of existing SessionRunner/message-persistence
behavior. It also means `report_progress` calls become free enrichment
rather than a separate write path: since `progress_phase`/`progress_note`
already land on the `sessions` row, they show up in the live attempt
projection automatically. A worker that calls `report_progress` three times
(the 73%-of-adopters median, per the brief's data) gets a richer attempt
record; a worker that never calls it still gets status + final message +
commits. **This is exactly the "must not be load-bearing" property the
brief asks for, achieved for free rather than engineered.**

Tradeoff, stated honestly: assembling attempts live means `get_issue` does
a fan-out (one `list_session_commits` git-log subprocess per attempt
session, plus a `get_session_tail`-equivalent read per attempt) rather than
one row read, **while the issue is open**. This is fine for `get_issue` (an
explicit, human/agent-paced tool call) but would be **too expensive to run
on every cold session spawn** — which is exactly why the resume hook (§10)
does *not* reuse this mechanism and instead reads bare issue rows only. See
§13 (risks) for a cap recommendation if an issue accumulates an unusually
large number of attempts. §4.3 explains why the close-time freeze doesn't
undermine this design — it's not a reversal, it's a durability guarantee
layered on top for exactly the moment the live projection stops being
trustworthy (once sessions/messages start getting pruned).

**If this choice turns out to be wrong** (e.g. because sessions get pruned
more aggressively than expected, or because git-log fan-out proves too slow
in practice), the fallback is a `Task.Supervisor`-based fire-and-forget
append at the same hook `maybe_notify_parent/3` already uses
(`session_runner.ex` ~line 909-940, fired at every `running → idle/error`
transition) — mirroring `MemoryGit.snapshot`'s existing idle-hook pattern.
Flagging this alternative explicitly per instructions, since the brief's
literal wording ("auto-appended on session end") reads more naturally as
a write-time hook than the read-time projection this spec actually
proposes for the *open* state.

#### 3.5.1 Reopen: resets the frozen snapshot, doesn't destroy its history

A closed/abandoned issue's `commits`/`attempts`/`resolution`/`closed_at`/
`closed_by_session_id` are all frozen-at-close state. Reopening
(`update_issue(id, status: "open")` from a currently closed/abandoned
status — see §6.4) means real work is very likely about to resume, which
means that frozen snapshot is about to become **incomplete**, not just
stale — new attempts will land, new commits will happen, and the live
projection (§3.5, plan B) takes back over. So on reopen:

1. **Before clearing anything**, auto-append a note (via the same
   mechanism `append_issue_note` already provides) preserving what's about
   to be cleared — this is the same "preserve, don't destroy" principle
   §6.4's amendment mechanism uses, applied here too, so a reopen never
   silently loses the historical record of "this is what we believed was
   true the first time we closed it":

   ```
   [reopened <timestamp>, session <session_id>]
   Previously closed as <outcome> by session <closed_by_session_id> at <closed_at>.
   Resolution at close:
   <prior resolution text>
   Frozen at that close — N commit(s): <short_hash: subject, ...>
   M attempt(s): <session_id: status — outcome, ...>
   ```

2. Clear `commits`, `attempts`, `resolution`, `closed_at`,
   `closed_by_session_id` back to `[]`/`nil`. `superseded_by_issue_id` is
   **not** cleared by reopen — if this issue was marked superseded and is
   now reopened anyway (e.g. the "superseding" issue turned out not to
   fully cover it), that's a deliberate human/agent call to make
   separately via `update_issue`, not an automatic side effect.
3. Set `status: "open"` (not `"in_progress"` — matches today's
   `reopen_issue/1` behavior unchanged).

The frozen snapshot isn't lost — it's now permanently readable in `notes`,
just no longer sitting in the "current" fields, which is the correct place
for it once it's stale.

### 3.6 FK convention: `issue_id` vs `parent_session_id`

Noted in §2.5: the codebase has two competing precedents for
session-linkage columns — `issue_id` (already a real DB FK,
`on_delete: :nilify_all`) and `parent_session_id`/`Trigger.last_session_id`
(deliberately plain fields, no FK, per `.context/data-model.md`). This spec
recommends `created_by_session_id`/`closed_by_session_id` follow
`issue_id`'s precedent (real FK, nilify on delete) since both are
Issue-side references to a session, not session-to-session references —
but this is a judgment call, not dictated by the brief, and worth a second
look from whoever picked the plain-field convention originally in case
there's a reason (write-path lock contention on `sessions`?) this spec
isn't aware of.

---

## 4. Commits and attempt summaries: derive live while open, freeze at close

### 4.1 Why

`Sessions.list_session_commits/2` is a live `git log --all
--grep=OrcaHub-Session:<id> --max-count=50` walk against the session's
working directory. It's accurate right now, but it is **not durable**: a
force-push, a repo migration, or the directory simply not existing anymore
two years from now all silently return `[]`. Likewise, once
sessions/messages are ever pruned, the live-attempts projection (§3.5)
loses its source data too — the only surviving record of what was
attempted would be whatever prose the closing agent happened to write into
`resolution`, and that's not a record anyone should have to depend on for
completeness (a rushed or confabulated `resolution` shouldn't be the only
thing standing between "we know what happened" and "we don't").

An issue is meant to outlive individual sessions and possibly outlive the
repo's current git history shape — so its permanent record can't be "run
this shell command again and hope," and can't be "trust the narrative was
thorough" either. Deriving live while the issue is open (cheap, always
current, no extra storage) and freezing a compact, structured snapshot of
**both** commits and attempts at close (durable, self-contained, and —
critically — independent of narrative quality) gets all of these
properties without paying for any of them the wrong way round.

### 4.2 Close-time derivation algorithm — commits

`close_issue` computes `commits` server-side — **there is no `commits`
argument in the tool schema**, so an agent cannot hand-type SHAs (the
literal failure mode the brief calls out: "agents skip or hallucinate
SHAs"). Algorithm, to live in `OrcaHub.Issues`:

```
def derive_commits(%Issue{} = issue) do
  project = ...            # issue.project (has :directory)
  attempts = ...           # Repo.all(from s in Session, where: s.issue_id == ^issue.id)

  issue_trailer_commits =
    Sessions.git_log_by_grep(project.directory, "OrcaHub-Issue: #{issue.key}")
    # same System.cmd shape as list_session_commits, just a different --grep;
    # grep BOTH the rendered key and the raw UUID form, since either may
    # appear in history depending on when the commit was made — see §3.2.5.

  attempt_commits =
    attempts
    |> Enum.flat_map(&Sessions.list_session_commits(&1.directory, &1.id))

  (issue_trailer_commits ++ attempt_commits)
  |> Enum.uniq_by(& &1.hash)
  |> Enum.sort_by(& &1.date)
end
```

This is the **same union** used for the retroactive/fallback query — see
§5.1. Note `list_session_commits` uses each **attempt's own** `directory`
(which can differ from the project's `directory` if `start_session`'s
`directory` override was used), not the project directory — the
issue-trailer grep uses the project directory since that's the one stable
"home" a project-scoped issue has.

`--max-count=50` risk and the commit-trailer-disabled-project risk are
both covered in §13.

### 4.3 Close-time derivation algorithm — attempt summaries (new this revision)

Same pattern, applied to `attempts` instead of `commits`, per the human's
explicit call in this revision: **freezing must not depend on narrative
quality.** If sessions/messages are later pruned, `resolution` prose is the
*only* thing that would otherwise survive — and prose quality varies with
how careful the closing agent was. A compact, structured, automatically
derived attempt summary survives regardless.

```
def derive_attempt_summary(%Issue{} = issue) do
  Repo.all(from s in Session, where: s.issue_id == ^issue.id, order_by: s.inserted_at)
  |> Enum.map(fn session ->
    %{
      session_id: session.id,
      status: session.status,
      outcome: one_line_outcome(session)   # first line of last assistant text,
                                            # truncated ~150 chars; "(no final message)" if empty
    }
  end)
end
```

Deliberately **compact** — one line per attempt (`session_id`, terminal
`status`, one-line `outcome`), not a transcript, not per-attempt commit
detail (that's already covered by the issue-level frozen `commits` array,
§4.2 — duplicating it per-attempt here would bloat the frozen record for
no reader benefit). Called from `close_issue` at the same moment
`derive_commits/1` is, and stored into the new `attempts` column (§3.1)
alongside `commits`.

**Response-shape note:** `get_issue`'s JSON key is `"attempts"` in both
states, but its *source and richness* differ deliberately — while open, it's
the rich live projection from §3.5 (full `last_assistant_text`, nested
per-attempt `commits`, `progress_phase`/`note`); once closed, it's this
compact frozen triple, read straight from the DB column with no fan-out.
This is a different open→closed transition than `commits` (which goes
empty→populated, not rich→compact) — called out explicitly so the two
don't get assumed to behave identically. See §6.3.

---

## 5. `OrcaHub-Issue` commit trailer

Add alongside the existing `OrcaHub-Session` trailer
(`SharedPrompts.commit_trailer_prompt/1`, injected per-project via
`SessionRunner`'s `commit_trailer?/2` toggle, fail-open). New fragment,
`SharedPrompts.issue_commit_trailer_prompt/1`, emitted only when
`commit_trailer?/2` is true **and** the session has `issue_id` set:

> When making a commit that addresses this session's linked issue
> (`<issue-key>`), also add:
>
> `OrcaHub-Issue: <issue-key>`
>
> as its own trailer line, alongside (not instead of) the `OrcaHub-Session`
> trailer. If a single commit addresses more than one open issue, add one
> `OrcaHub-Issue:` line per issue — trailers repeat.

Two reasons this exists as a second, independent trailer rather than being
derived purely from the session link:

1. **Commit → issue becomes the primary link**, not something inferred
   two hops away through `OrcaHub-Session` → session → `issue_id`. A commit
   can cite an issue directly even from a session with no `issue_id` set at
   all (an agent that discovered a relevant issue mid-task via
   `list_issues`/`get_issue` but wasn't spawned against it).
2. **Repeated trailers support N:1 commit-to-issue** (one commit fixing two
   related issues at once) — `OrcaHub-Session` is 1:1 by construction (a
   commit is made by exactly one session), but there's no reason a commit
   can't close out multiple issues.

Worth stating: an agent can cite `OrcaHub-Issue: <key>` on any commit
regardless of `session.issue_id`, the same way any agent can already
reference a feature-request id in a `resolution_note` by convention today.
The prompt fragment above is the *load-bearing, automatic* case (session
linked at spawn time); a general one-line mention in `SharedPrompts`'
worker-practices bullet list covers the opportunistic case.

### 5.1 Retroactive/fallback query

If a commit exists that references an issue only via `OrcaHub-Issue:` (no
session link at all — work done outside any session, or a session whose
`issue_id` was never set) — or, conversely, an attempt session's commit
that was never tagged `OrcaHub-Issue:` at all, only `OrcaHub-Session:` — the
full reconstruction is the **same union `derive_commits/1` already runs**
(§4.2): grep the project directory for `OrcaHub-Issue: <key-or-id>` UNION
`list_session_commits` for every attempt session (via `sessions where
issue_id = ?`), dedupe by hash. This isn't a separate mechanism — it's
usable both as `close_issue`'s live derivation *and*, independently, as a
one-off backfill script for reconstructing which issue(s) an already-merged
stray commit belongs to, the same way this whole feature was itself
reintroduced once already (`3ebb3fe` → the minimal FR-board reintroduction)
after being deleted.

---

## 6. Tool surface

Six MCP tools, replacing the five `FeatureRequests` tools outright
(mapping and migration plan in §8 — **resolved this revision: migrate, no
permanent aliases**): `create_issue`, `list_issues`, `get_issue`,
`update_issue`, `append_issue_note`, `close_issue`.

Shared `id` description across `get_issue`/`update_issue`/
`append_issue_note`/`close_issue` (carrying forward the existing
prefix-match UX from `FeatureRequests`, now also accepting the per-project
key from §3.2):

> The issue's id — its short key (e.g. `ORCA-142`, shown in `/issues` URLs
> and session messages), a full UUID, or an unambiguous UUID hex prefix
> (≥8 hex chars, dashes optional).

### 6.1 `create_issue`

```jsonc
{
  "name": "create_issue",
  "description": "File a durable work item — a task against your own project, or (kind: \"feature_request\") a platform-friction report against OrcaHub itself. Unlike a memory rule, an issue is a NARRATIVE, not standing guidance — record what's broken/being asked and why it matters, not a rule to follow going forward. Light dedup: if an open issue with a similar title already exists in the same project+kind, no new issue is created — the existing one is returned instead; use append_issue_note on it.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "Short summary, written like a commit subject line — specific enough that the dedup check won't confuse it with something else."
      },
      "description": {
        "type": "string",
        "description": "What's broken, what's being asked, or what you're proposing — and why it matters right now. Written so someone can understand what prompted this without you in the room."
      },
      "kind": {
        "type": "string",
        "enum": ["task", "feature_request"],
        "description": "\"task\" (default) for work against your own project. \"feature_request\" for platform friction filed against OrcaHub itself — a missing tool, an awkward workflow, a confusing error."
      },
      "premise": {
        "type": "string",
        "description": "The assumption you're operating under that makes this worth doing — what do you believe is true right now that, if it stopped being true, would make this moot? This gets checked later, so write it for someone auditing a rule that might one day cite this issue."
      },
      "plan": {
        "type": "string",
        "description": "Your current intended approach, in your own words. Optional at file time — set or update it later with update_issue as your understanding develops."
      },
      "directory": {
        "type": "string",
        "description": "Which project to file this against. Defaults to your own project. Pass an absolute path belonging to a DIFFERENT registered project to file against that project instead (this is how feature_request issues target the OrcaHub codebase from any calling session)."
      }
    },
    "required": ["title", "description"]
  }
}
```

`created_by_session_id` is set from `state.orca_session_id`, never an
argument (same pattern as `report_progress`'s implicit session identity).
`kind` defaults to `"task"` when omitted — a caller has to opt into
`feature_request` deliberately, not the other way round. The issue's `key`
(§3.2) is allocated as part of this call and returned in the result
alongside `id`.

### 6.2 `list_issues`

```jsonc
{
  "name": "list_issues",
  "description": "List issues. Defaults to open issues in your own project, across both kinds, newest first. Check this (or the dedup check inside create_issue) before filing — if something similar is already tracked, append_issue_note on it instead of creating a duplicate.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "status": { "type": "string", "description": "\"open\" (default), \"in_progress\", \"closed\", \"abandoned\", or \"all\"." },
      "kind": { "type": "string", "description": "\"task\", \"feature_request\", or \"all\" (default)." },
      "directory": { "type": "string", "description": "Project to list issues for. Defaults to your own project." },
      "all_projects": { "type": "boolean", "description": "List across every project instead of one. Default: false." },
      "mine": { "type": "boolean", "description": "Only issues YOU (this session) created. Useful after a compaction or a long idle gap to re-orient without waiting on the automatic reminder. Default: false." },
      "query": { "type": "string", "description": "Optional case-insensitive title substring filter." },
      "limit": { "type": "integer", "description": "Default 50." }
    }
  }
}
```

Returns `{"count": n, "issues": [{id, key, title, kind, status, project,
inserted_at}, ...]}` — summary shape, same as `list_feature_requests`
today plus `kind` and the new `key`.

### 6.3 `get_issue`

```jsonc
{
  "name": "get_issue",
  "description": "Fetch an issue's full record. While open/in_progress, also returns \"attempts\" — a live summary of every session linked to this issue (via start_session's issue_id) showing what each one did: final status, last message, self-reported progress, and commits. This is the raw material to read BEFORE closing an issue — see close_issue. If this issue has been superseded, the response points straight at what replaced it.",
  "inputSchema": {
    "type": "object",
    "properties": { "id": { "type": "string", "description": "<shared id description>" } },
    "required": ["id"]
  }
}
```

Response shape:

```jsonc
{
  "id": "...", "key": "ORCA-142", "title": "...", "kind": "task", "status": "in_progress",
  "description": "...", "premise": "...", "plan": "...",
  "approaches_tried": "...", "notes": "...",
  "project": "...", "created_by_session_id": "...",
  "resolution": null, "closed_at": null, "closed_by_session_id": null,
  "superseded_by": null,   // or {"id": "...", "key": "ORCA-201", "title": "...", "status": "closed"} once set
  "commits": [],           // populated only once closed (§4.2)
  "attempts": [             // RICH + LIVE while open (§3.5); COMPACT + FROZEN once closed (§4.3)
    {
      "session_id": "...", "status": "idle",
      "last_assistant_text": "... (truncated ~2KB, same cap as get_session_tail)",
      "progress_phase": "implementing", "progress_note": "...",
      "commits": [{"hash": "...", "short_hash": "...", "subject": "...", "author": "...", "date": "..."}],
      "started_at": "...", "updated_at": "..."
    }
  ]
}
```

Once closed, `attempts` shrinks to the frozen form: `[{"session_id": "...",
"status": "idle", "outcome": "..."}]` — no live fan-out, straight DB read.

Cap the *live* `attempts` fan-out (most recent N in full detail, older ones
as a bare `{session_id, status}` list) — see §13 for why. The frozen form
needs no cap (it's already compact by construction).

### 6.4 `update_issue`

```jsonc
{
  "name": "update_issue",
  "description": "Update an issue's fields. On an open/in_progress issue: edit title/description/kind/plan/premise, or move it to \"in_progress\". Setting status to \"open\" on a closed/abandoned issue REOPENS it — the frozen commits/attempts/resolution are archived into notes first, then cleared, since real work resuming means they're about to go stale. Cannot set status to closed/abandoned here; use close_issue for that. On an already-closed/abandoned issue, resolution/premise can still be AMENDED (the prior value is preserved in notes first, never silently overwritten) — this is how retroactive corrections like \"this turned out to be wrong\" get recorded without destroying what was known at the time it closed.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "<shared id description>" },
      "title": { "type": "string" },
      "description": { "type": "string" },
      "kind": { "type": "string", "enum": ["task", "feature_request"] },
      "status": {
        "type": "string",
        "enum": ["open", "in_progress"],
        "description": "Cannot be used to close or abandon an issue — see close_issue. Setting \"open\" from a currently closed/abandoned status is how you reopen one."
      },
      "plan": { "type": "string", "description": "Your current intended approach. This OVERWRITES the existing plan, it doesn't append — write the whole current plan, not a diff." },
      "premise": { "type": "string", "description": "The assumption behind this issue. On an open issue this just updates it. On a closed/abandoned issue, the PRIOR premise is preserved in notes before the new one is applied — you're amending the record, not rewriting history." },
      "resolution": {
        "type": "string",
        "description": "Only settable on an already-closed/abandoned issue (close_issue sets it the first time) — use this to amend the resolution once new information surfaces, e.g. \"this turned out to be wrong\" or \"superseded by ORCA-201.\" The prior resolution is preserved in notes before the new one is applied."
      },
      "superseded_by": {
        "type": "string",
        "description": "Mark this issue as replaced by another one — pass the superseding issue's id/key. Use this when you discover a newer issue already covers what this one was about; it's often the single highest-value thing you can add to a closed issue, since it tells a future reader exactly where the current thinking moved to. Works regardless of this issue's own status. Does not itself change status."
      }
    },
    "required": ["id"]
  }
}
```

At least one field besides `id` required (same pattern as
`report_progress`'s "at least one of phase/title" guard).

**Reopen semantics** (status: closed/abandoned → `"open"`): triggers the
archive-then-clear sequence spelled out in §3.5.1. A status change between
`open` and `in_progress` (in either direction) is a plain field update with
no side effects — there's nothing frozen to clear yet.

**Amendment semantics** (`resolution`/`premise` changed on an issue that's
*already* closed/abandoned, with no accompanying `status: "open"` in the
same call — i.e. amending without reopening): before applying the new
value, auto-append a note (via the same mechanism `append_issue_note`
provides) preserving the old one:

```
[amended <timestamp>, session <session_id>]
Prior resolution:
<old resolution text>
```

(If both `resolution` and `premise` change in the same call, one combined
note covers both, to avoid near-duplicate timestamped notes piling up.)

`resolution` is **rejected** if the issue is currently open/in_progress —
that's `close_issue`'s exclusive first-write path (§6.6); `update_issue`
only ever amends an existing one.

### 6.5 `append_issue_note`

Unchanged in shape from `append_feature_request_note` — `id` + `note`,
both required, appended to `notes` with the same provenance stamp
(`— via append_issue_note. Session: ..., Node: ..., Date: ...`) the FR
tool already writes. **Always works regardless of status** — it already
does today (no status check anywhere in the current code path), and this
revision doesn't add one: append-only is exactly the property that makes
it safe to also be the underlying mechanism §6.4's amendment/reopen
archiving reuses.

### 6.6 `close_issue` — the read-back flow

```jsonc
{
  "name": "close_issue",
  "description": "Close an issue with outcome \"resolved\" (the work landed) or \"abandoned\" (stopping without finishing — still requires a resolution explaining why; an abandoned issue with a real narrative is more valuable than a resolved one with none). Commits and a compact attempt summary are derived and frozen automatically from linked attempts and the OrcaHub-Issue commit trailer — you cannot pass them by hand. Call this with ONLY id first: it returns the harvested attempt evidence (same shape as get_issue's \"attempts\") WITHOUT closing anything. Synthesize resolution from THAT evidence, not from your own memory of the work (your context may have been compacted since you started) — then call close_issue again with outcome and resolution to actually close it. To close as abandoned because a newer issue already covers this, pass superseded_by in the same call.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "description": "<shared id description>" },
      "outcome": { "type": "string", "enum": ["resolved", "abandoned"], "description": "Omit on the first call to get the harvested evidence without closing." },
      "resolution": {
        "type": "string",
        "description": "What actually happened — not what you planned to happen. If outcome is \"abandoned\", explain what made this not worth finishing and what that implies for anyone who reopens it later. Required together with outcome to actually close."
      },
      "superseded_by": {
        "type": "string",
        "description": "Optional: the id/key of the issue that replaces this one. Common when closing as \"abandoned\" because you found this is already covered elsewhere — sets the same structured link update_issue's superseded_by does."
      }
    },
    "required": ["id"]
  }
}
```

**Two-mode behavior**, implementing "close_issue must read the harvested
record back to the orchestrator as raw material to synthesize from"
without needing a second tool name:

- `close_issue(id: "...")` — `outcome`/`resolution` both omitted → returns
  the same `attempts` array `get_issue` would (the *live* rich form, since
  the issue isn't closed yet), plus an explicit instruction string, and
  **does not close the issue**.
- `close_issue(id: "...", outcome: "...", resolution: "...")` — closes it:
  computes `commits` (§4.2) and `attempts` (§4.3), sets `status` to
  `closed`/`abandoned` per `outcome`, stamps `closed_by_session_id` and
  `closed_at`, stores `resolution`, and — if `superseded_by` was passed —
  sets `superseded_by_issue_id`.

This is a prompt-level contract, not a technically enforced one — nothing
stops an agent from confabulating a `resolution` on the very first call
without ever reading the attempts. The mechanism's value is that the
*natural failure mode* (agent forgets `outcome`/`resolution`, or calls
`close_issue(id)` out of habit expecting an error) now **teaches the
correct workflow** via its own tool response instead of just failing.
Reinforce it in `SharedPrompts`' worker/orchestrator practices bullets:
"read `get_issue` (or the first `close_issue` call) before writing
`resolution` — don't synthesize from memory."

---

## 7. Dedup (carried over from the FR board)

Identical algorithm to today's `find_similar_open_issue`/`similar_title?`
(§2.3), generalized: scope changes from "agent-filed issues in this
project" (matched via title prefix) to **"open issues in this project with
the same `kind`"** (matched via the real `kind` column — no more prefix
stripping, since `kind` replaces the prefix entirely). Same
case-insensitive-substring-or-≥60%-word-overlap heuristic, unchanged.

Flagged risk: the 60% threshold was tuned against FR-board titles, which
share a fairly uniform phrasing style. General `task`-kind titles ("fix
login bug") are shorter and more generic and may produce more false-positive
dedup collisions once this opens up beyond the FR board. Not solved here —
watch it post-rollout, retune per-`kind` if it becomes a problem (§13).

---

## 8. FR board collapse — resolved: migrate, no permanent aliases

`kind: "feature_request"` is a strict superset of what
`OrcaHub.MCP.Tools.FeatureRequests` does today. Mapping:

| Old tool | New equivalent |
|---|---|
| `file_feature_request(title, description, category)` | `create_issue(kind: "feature_request", directory: "/home/zach/orca_hub", title, description)` — `category` has no direct equivalent; fold it into `description` or drop it (it was always freetext and unused for filtering). |
| `list_feature_requests(status)` | `list_issues(kind: "feature_request", directory: "/home/zach/orca_hub", status)` |
| `get_feature_request(id)` | `get_issue(id)` (drop the agent-filed/`[agent-fr]` scope check — every issue is now equally "real," `kind` is just a filter, not an access boundary) |
| `append_feature_request_note(id, note)` | `append_issue_note(id, note)` |
| `close_feature_request(id, resolution_note)` | `close_issue(id, outcome: "resolved", resolution: resolution_note or a shim default — see below)` |

`@orca_hub_directory` hardcoding is preserved as the alias's implicit
`directory` — that behavior (always file against OrcaHub itself regardless
of caller) is a deliberate, useful property worth keeping for the specific
"tell the maintainers" use case, distinct from `create_issue`'s general
default of "your own project."

**Resolved this revision (previously left open): migrate the prompts and
drop the old tool names — do not keep them as permanent aliases.** Reason
this direction was preferred over keeping aliases: `SharedPrompts.
orchestration_practices_block/1` already threads four FR-specific reference
variables through both the code-exec and non-code-exec
`orchestrator_prompt/3` variants; keeping the old names alive would mean
growing parallel general-issue variants alongside them rather than
collapsing onto one set — directly working against the stated goal that
"the FR board becomes a filtered view," not a permanently separate second
surface next to it.

**Migration mechanics:**

1. `SharedPrompts` references swap to `create_issue(kind: "feature_request",
   ...)` / `list_issues(kind: "feature_request", ...)` / etc. throughout.
2. Ship a **short-lived compatibility shim**: the five old tool names stay
   registered for one deploy cycle, each a thin wrapper delegating to the
   new handler with `kind` forced to `"feature_request"` (description
   prefixed `"[deprecated — use create_issue/list_issues/... instead]"`).
   The `close_feature_request → close_issue` mapping needs a fallback
   default resolution text for the case where the old, optional
   `resolution_note` is omitted (new `resolution` is required, §6.6) —
   e.g. `"Closed via deprecated close_feature_request with no resolution
   note provided."` — an accepted wrinkle of a short-lived compat layer,
   not worth designing around further.
3. **Removal condition** (this was the missing piece in v1): remove the
   shim once a full deploy cycle has passed since the rename shipped,
   verified by a grep of prod session logs for zero calls to the old tool
   names over that window (the same method used for the July 2026
   tool-error audit). If that kind of log audit isn't convenient to run,
   a fixed **two-week** window is sufficient on its own — this is a fully
   internal tool surface with no external, version-pinned consumers, so
   there's no meaningful compatibility tail to protect beyond covering any
   session that was warm at rename time and hasn't yet had a cold respawn
   (§10.2 explains why that matters: a warm port's tool list doesn't
   refresh until its next cold spawn).

---

## 9. `start_session(issue_id:)` — the primary link

New optional arg on `mcp/tools/sessions.ex`'s `start_session`:

```jsonc
"issue_id": {
  "type": "string",
  "description": "Link the new session to an issue as an attempt at it (session.issue_id) — the primary way issues get worked. Same id format as get_issue (key, UUID, or UUID prefix). If the issue is currently \"open\", it's automatically moved to \"in_progress\" (best-effort, non-blocking)."
}
```

This is the design's central bet, backed directly by the prod data in the
brief: **90% of session titles come from `start_session(title:)`, only
~3% (29/899) from mid-flight `report_progress(title:)`.** Orchestrators
reliably supply context *at spawn time*; workers unreliably remember to
report back mid-flight. `issue_id` follows the same shape as `title` for
exactly that reason — it's the free, proven, spawn-time path, not one more
thing a worker has to remember to call.

`open → in_progress` auto-transition on link: best-effort (log and swallow
on failure, same defensive pattern `maybe_record_interaction/3` already
uses for `SessionInteraction` edges) — this write should never be allowed
to block or fail the actual session spawn.

---

## 10. The resume hook — the highest-value piece

Without this, issues rot exactly like v1 did: written once, never
re-surfaced, forgotten the moment a session's context gets summarized.
This is the mechanism that makes a plan **survive compaction** — the whole
point.

### 10.1 Proposed mechanism

New `SharedPrompts.open_issues_prompt/1` fragment, assembled alongside the
existing `context_files_prompt/1`/`commit_trailer_prompt/1` fragments at
system-prompt build time. Queries issues where `created_by_session_id ==
session.id` and `status in [open, in_progress]`, renders compactly:

```
# Your Open Issues

- [ORCA-142] <title> (in_progress) — plan: <plan, or "(none set)">
- [ORCA-118] <title> (open) — plan: (none set)
```

One indexed query (`created_by_session_id`), no git-log fan-out — cheap
enough to run on every cold spawn. This is deliberately **not** the
`get_issue`-style live-attempts projection (§3.5) — that fan-out is too
expensive to run unconditionally on every session init; an orchestrator
that wants attempt detail calls `get_issue` explicitly once it's oriented.

If any listed issue has `superseded_by` set despite still being technically
open (an edge case, since `superseded_by` is settable regardless of
status, §3.1), surface that too — it's a strong signal the issue should
just be closed, and cheap to include since it's a plain column on the same
row being queried.

### 10.2 A gap, stated honestly

`SessionRunner`'s own code comment (near `commit_trailer?/2`) already
establishes: *"a warm streaming port's system prompt is already baked, so
toggling the project setting only affects the next cold spawn."* This
applies equally here. The resume-hook fragment above reliably fires on:

- a brand-new session spawned against an issue,
- any session whose warm port was torn down and reopened (`idle_teardown`
  after 15 min, `evict_warm` under `WarmPool` pressure, a kill-switch
  `downgrade`, or a deploy/restart) — i.e. genuine "session resumed"
  per the lifecycle doc.

It does **not** reliably fire the instant an in-place, CLI-native
compaction happens *inside* an already-warm port that never gets torn
down — under the current architecture, that port's system prompt was
baked at its last cold spawn and nothing re-sends it mid-port. I could not
confirm from the code read so far whether any backend adapter (pi's
compaction-event surfacing, per the backend spec, is the most promising
lead) already re-primes context after such an event. **This is an
explicitly flagged gap, not solved by this spec** — recommend the
implementer spike whether that hook already exists before building
anything new for it; if it doesn't, treat "inject immediately after an
in-place mid-port compaction" as a fast-follow, not a v1 blocker. The
cold-spawn/resume path alone already covers the dominant real case (a
fresh session picking up an issue, or a long-idle orchestrator waking back
up from an evicted/torn-down port) — which is most of what "survive
compaction" means in how orchestrators actually get used.

### 10.3 Self-serve fallback

`list_issues(mine: true)` (§6.2) is the manual escape hatch for the
gap in §10.2 — the same relationship `search_sessions` already has to
missed lifecycle notifications: the automatic path is primary, the
explicit tool call is the fallback when an orchestrator suspects it's
missing something.

---

## 11. Memory citation — the payoff use case

Confirmed by reading `project-unified-memory.md` and `memory_git.ex`/
`memory_sync.ex`: OrcaHub's own agent-memory system (`OrcaHub.MemoryGit` +
`OrcaHub.MemorySync`) treats each backend's **native** memory files as
canonical — for Claude, exactly the YAML-frontmatter markdown files this
very session is writing (`name`/`description`/`metadata: {type, ...}`).
OrcaHub's app code does not generate or parse these files' content; it
only snapshots/mirrors them.

Proposal: add an **optional** `issue:` key under `metadata` in that
frontmatter convention — `metadata: {type: feedback, issue: "ORCA-142"}` —
citing the issue whose `resolution`/`premise` explains *why* a memory rule
exists. This is **not an OrcaHub application feature** — there's no code
to write for it beyond a prompt-level convention (a bullet added wherever
agents are already told how to write memory files, instructing them to
cite an `issue:` when a rule originated from working/closing one). The
payoff:

- "Why does this rule exist?" becomes one hop: read the memory file's
  `issue:` citation, call `get_issue(id)`, read `premise`/`resolution`.
- **The walk doesn't have to stop at one issue.** If the cited issue has
  `superseded_by` set (§3.1.2), the audit continues to the superseding
  issue — that's very likely where the current premise/resolution actually
  lives now, and `get_issue` surfaces `superseded_by` as a resolved
  `{id, key, title, status}` summary specifically so this is one more cheap
  hop, not a second search.
- A memory audit (e.g. the `audit-memory` skill already available in this
  environment, or the existing weekly `.context`-docs-audit trigger
  pattern) can mechanically walk every memory file's `issue:` citation and
  flag ones whose cited issue's `premise` field looks stale, contradicted
  by its own `resolution`, or superseded — a check that's impossible today
  because there's nothing to cite.

This section documents *how the two systems interlock*, per the brief's
explicit ask — it is not itself a deliverable of this spec. The only thing
this spec's implementation needs to provide for it to work at all is
**stable, citable issue ids** — which is exactly what §3.2's key mechanism
provides.

---

## 12. Migration plan

Two Ecto migrations (or one file with clearly separated steps) — `projects`
first since `issues`' backfill depends on it existing:

```elixir
# 1. Projects: key_prefix + issue_counter
alter table(:projects) do
  add :issue_counter, :integer, null: false, default: 0
  add :key_prefix, :string
end

# Deterministic backfill (§3.2.3): derive a candidate per project (strip
# non-alnum, uppercase, truncate to <=10 chars), processed in inserted_at
# order; first claim wins, later collisions get a numeric suffix appended.
# (Simplest to implement as an Elixir `execute/2` step using Repo.all/
# Repo.update rather than raw SQL, since the collision-avoidance loop is
# awkward in pure SQL — acceptable for a one-time migration.)

create unique_index(:projects, [:key_prefix])
```

```elixir
# 2. Issues: kind/plan/resolution/premise/commits/attempts/created_by/
#    closed_by/closed_at/superseded_by/key_number
alter table(:issues) do
  add :kind, :string, null: false, default: "task"
  add :plan, :text
  add :resolution, :text
  add :premise, :text
  add :commits, {:array, :map}, default: []
  add :attempts, {:array, :map}, default: []
  add :created_by_session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
  add :closed_by_session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
  add :closed_at, :utc_datetime
  add :superseded_by_issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
  add :key_number, :integer
end

# One-time backfill: existing rows still carry the "[agent-fr] " prefix hack.
execute """
UPDATE issues
SET kind = 'feature_request',
    title = regexp_replace(title, '^\[agent-fr\] ', '')
WHERE title LIKE '[agent-fr] %'
""", ""

# Backfill key_number per project, ordered by inserted_at, then sync each
# project's issue_counter so future allocations continue from the right
# place instead of restarting at 1 and colliding.
execute """
UPDATE issues i
SET key_number = sub.rn
FROM (
  SELECT id, ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY inserted_at) AS rn
  FROM issues
  WHERE project_id IS NOT NULL
) sub
WHERE i.id = sub.id
""", ""

execute """
UPDATE projects p
SET issue_counter = COALESCE(
  (SELECT MAX(key_number) FROM issues i WHERE i.project_id = p.id), 0
)
""", ""

create unique_index(:issues, [:project_id, :key_number])
```

**Edge case, flagged rather than silently handled:** `Issue.changeset`
today only `validate_required([:title])` — `project_id` is **not**
required, so it's possible (if unlikely in practice) for an orphan issue
with `project_id: nil` to already exist. Such a row can't get a
`key_number` (no project to scope the counter to) and is left with
`key_number: NULL` indefinitely — recommend a pre-migration check
(`SELECT count(*) FROM issues WHERE project_id IS NULL`) before running
this in prod; if any exist, decide by hand whether to assign them to a
project or leave them keyless (id-resolution still falls back to raw
UUID/hex-prefix for a keyless issue either way, §3.2.4).

`sessions.issue_id`: **no migration** — column and FK already exist
(§2.5); only the `Session` schema/changeset need updating (application
code only).

`Issue.changeset`'s `validate_inclusion(:status, ...)` gains `"abandoned"`.
`cast/2` gains every new field.

Not part of this migration, but required as a follow-up before this is
genuinely usable: **`IssueLive.Index`/`Show` need updating** to show
`kind` (filterable), `key`, `plan`/`premise`/`resolution`, frozen
`commits`/`attempts`, and `superseded_by` — plus the live `attempts` list
while open. The current UI will still *render* post-migration (nothing
breaks), it just won't show any of the new fields — flagged explicitly as
scope not covered by "tool surface" work.

---

## 13. Anti-goals

Explicit, because the shape of this feature is easy to accidentally grow
into something it isn't:

- **No assignment-as-ownership.** `created_by_session_id`/
  `closed_by_session_id` are provenance, not a queue a session "owns" and
  is responsible for. Any session can attempt any open issue.
- **No priority field.** Nothing here ranks issues against each other.
- **No dependency graph.** An issue doesn't block another issue in any
  structural sense — `superseded_by` (§3.1.2) is a narrow, deliberate
  exception (it's provenance about a closed issue's fate, not a live
  blocking relationship), not a general precedent for adding more
  relationship types. If one issue genuinely depends on another in the
  "can't start until" sense, that belongs in `description`/`plan` prose,
  not a new FK.
- **No sprints, no milestones, no due dates.**
- **No status beyond `open` / `in_progress` / `closed` / `abandoned`.**
  Four values, no more — reopening (§3.5.1) moves an issue back through
  these same four states, it doesn't add a fifth.

If a future change makes this look more like Jira, it's wrong. The right
mental model is **closer to an ADR log written by whoever did the work**
than a ticket tracker — every field exists to answer "what happened and
why," never "who's responsible and when is it due." This is a direct
consequence of §1's organizing principle: a human-groomed queue is what
killed v1, and the fields above are exactly the kind of thing a queue
needs and a narrative log doesn't. Retroactive amendment (§6.4) doesn't
weaken this — an amendment is itself just another dated log entry, the
same way an ADR gets a "superseded" note rather than being edited in
place.

---

## 14. Risks

1. **Stale open issues poisoning the resume hook (§10).** An issue that's
   actually dead/superseded but never formally closed will keep showing up
   in every cold-spawn system prompt forever, training orchestrators to
   skim past the block — the same alert-fatigue failure mode that kills
   most "reminder" systems. Mitigation *not built here*: a periodic
   hygiene pass (piggybacking on the existing weekly `.context`-docs-audit
   trigger pattern, or the deep-dream reconcile job from
   `project-unified-memory.md`) flagging issues open >N days with zero new
   attempts as close/abandon candidates — surfaced for a human/orchestrator
   to act on, never auto-closed (auto-closing would just be a different
   flavor of silently losing context).

2. **The per-project `commit_trailer` toggle silently yields empty commit
   lists.** `SessionRunner.commit_trailer?/2` fails *open* (defaults true)
   but can be explicitly turned off per project. If it's off, no session
   ever emits `OrcaHub-Session`/`OrcaHub-Issue` trailers, so `close_issue`'s
   derived `commits` (§4.2) will be silently `[]` even for real, shipped
   work — with no error surfaced anywhere today. Mitigation: `close_issue`
   should check `commit_trailer?(project_id)` and, if it's false and the
   derived commit list is empty, return an explicit warning in the close
   response: *"this project has commit trailers disabled — commits could
   not be auto-derived; mention the relevant commit in `resolution` by hand
   if this issue's work landed."*

3. **`--max-count=50` is lossy for long-running issues.**
   `list_session_commits`'s hardcoded cap is fine for a single session's
   own attempt, but the *union* across many attempts plus the issue-trailer
   grep (§4.2) can plausibly exceed 50 for an issue with a long history of
   small commits. Recommend either raising the cap specifically for the
   close-time snapshot (a one-time freeze, not a hot path — 500 is cheap)
   or, at minimum, flagging in the close response when any individual
   source query returned *exactly* 50 results (an ambiguous "was this
   truncated?" signal) so the closing agent knows to sanity-check before
   trusting the frozen list as complete.

4. **Frozen commits must be self-contained, not just a SHA.** A repo can
   be rewritten (force-push, history rewrite) after an issue closes; a
   bare hash would silently dangle. This is already handled by storing
   `subject`/`author`/`date` alongside `hash`/`short_hash` (§3.1) — noting
   it here as *why* that denormalization matters, not as an unsolved risk.

5. **`get_issue`'s live `attempts` fan-out cost.** N git-log subprocess
   spawns for an issue with N attempts is fine at normal scale but could
   get slow (or look like a minor DoS vector) if an issue somehow
   accumulates an unusually large number of linked sessions (e.g. a
   misbehaving orchestrator loop spawning many workers all against one
   `issue_id`). Recommend capping full-detail fan-out to the most recent
   ~20 attempts, with older ones listed by `{session_id, status}` only —
   mirroring the existing `@list_cap`/tail-truncation patterns already
   used elsewhere in this codebase. Note this risk is scoped to the *open*
   state only — once closed, `attempts` is a flat DB read (§4.3), so this
   cost has a hard cap on an issue's total lifetime exposure regardless of
   how many attempts it eventually accumulates.

6. **Dedup threshold may not generalize from FR titles to general task
   titles** — already flagged in §7.

7. **`approaches_tried` may become partially redundant** with the new
   live/frozen `attempts` view once this ships, since attempts already
   show what each session did. Not removed here (the brief keeps it as an
   existing field new columns are added alongside), but worth watching
   whether it naturally falls out of use in favor of the automatic view.

8. **Amendment/reopen notes can bloat `notes` over many cycles.** Every
   reopen and every post-close amendment auto-appends a note (§3.5.1,
   §6.4) — an issue that gets reopened and re-closed repeatedly
   accumulates an ever-longer `notes` field, all of it useful archaeology
   but none of it prunable without losing the "what was known when"
   guarantee that's the whole point. Not solved here; if it becomes a
   real problem, a structured history array (rather than prose notes)
   would be the fix, but that's more machinery than this spec's stated
   scope justifies for a first version — flagged as a considered-and-
   deferred alternative, not an oversight.

9. **`key_prefix` collision handling at project creation depends on a UX
   step (§3.2.3) this spec doesn't fully own** — `create_project`'s flow
   (CLI tool, web form, or both) needs to actually surface the
   uniqueness-checked suggestion/override described there; if that UX
   isn't built carefully, the fallback is an opaque uniqueness-constraint
   error on project creation, which is a worse experience than what this
   spec intends.

10. **`superseded_by_issue_id` cycles are not prevented beyond trivial
    self-reference.** A simple `validate_change` guard
    (`superseded_by_issue_id != id`) is cheap and worth having; a genuine
    A→B→A cycle across two different issues is not detected or blocked by
    anything in this design. Given the anti-goals in §13 (no dependency
    graph, deliberately minimal machinery), this is an accepted gap rather
    than something to build cycle-detection for — a cycle here is a
    human/agent authoring mistake, not a state the system needs to be
    robust against structurally.

---

## 15. Implementation checklist (for the follow-up worker)

1. Migrations (§12) — `projects.key_prefix`/`issue_counter` + backfill;
   `issues`' new columns + backfill (`kind`, `key_number`, `attempts`,
   `superseded_by_issue_id`, `closed_at`, etc.) + `abandoned` status value.
2. `Project`/`Issue`/`Session` schema + changeset updates (§3), including
   the `superseded_by_issue_id != id` guard (§14, risk 10).
3. `OrcaHub.Issues` context: `create_issue`/`update_issue` growing new
   fields, atomic key allocation (§3.2.2), `derive_commits/1` (§4.2),
   `derive_attempt_summary/1` (§4.3), the reopen archive-then-clear
   sequence (§3.5.1), the amendment archive-then-apply sequence (§6.4),
   live-attempts-assembly helper for `get_issue` (§3.5/§6.3), dedup
   generalized to `(project_id, kind)` (§7).
4. New MCP tool module (`OrcaHub.MCP.Tools.Issues`?) implementing the six
   tools in §6, replacing `FeatureRequests` with the short-lived compat
   shim described in §8.
5. `start_session`'s `issue_id` arg + auto `open → in_progress` (§9).
6. `SharedPrompts`: `open_issues_prompt/1` (§10.1),
   `issue_commit_trailer_prompt/1` (§5), FR-reference variables in
   `orchestration_practices_block/1` migrated to the general-issue tool
   names per §8.
7. `create_project`'s `key_prefix` suggestion/override UX (§3.2.3) —
   needed for §14 risk 9 not to become the default outcome.
8. `IssueLive.Index`/`Show` UI updates (§2.6/§12) — separate, lower-priority
   follow-up.
9. Targeted tests: dedup scoping, `close_issue`'s two-mode behavior,
   `derive_commits/1`'s union+dedupe-by-sha, `derive_attempt_summary/1`,
   the `open → in_progress` auto-transition, reopen's archive-then-clear
   behavior, amendment's archive-then-apply behavior, key allocation
   race/uniqueness, id resolution across all three forms (§3.2.4),
   prompt-content tests for the two new `SharedPrompts` fragments
   (matching the existing pattern in
   `test/orca_hub/backend/{claude,pi}_test.exs`).
