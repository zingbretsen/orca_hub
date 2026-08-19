# OrcaHub MCP Tool Parameter Usage Audit

Read-only prod data analysis. Goal: find parameters of OrcaHub's own MCP tools that are
rarely/never used but that agents would plausibly benefit from — the same class of bug
`get_session_tail`'s `full_last_message` turned out to be (documented only in the JSON
schema description, so agents didn't discover it; fixed in commit `5557d83` by naming it
at the truncation point in the tool's own result payload instead).

## Methodology

### Database confirmation

This repo's `.env` points at `orca_hub_dev`, which is stale/misleading (436 sessions). I
connected instead to `orca_hub_prod` on `192.168.1.177:5432` via `docker exec` into the
`postgres` container running on this host (the shared Postgres runs outside k3s, as plain
Docker Compose — see `~/.claude/CLAUDE.md`'s homelab notes), using the same
`DB_USERNAME`/`DB_PASSWORD` from `.env` but overriding `DB_NAME`:

```
docker exec -e PGPASSWORD=... postgres psql -U orca_hub -d orca_hub_prod -c \
  "select current_database(), (select count(*) from sessions), (select count(*) from messages);"
=> orca_hub_prod | 3273 sessions | 761076 messages
```

This matches the known prod baseline (~3265 sessions / 758K messages) from a prior audit,
confirming I was on the real database, not dev. All queries below are read-only
(`SELECT`/`COPY ... TO STDOUT`); nothing was written to prod.

**Window: 30 days** (2026-07-19 through 2026-08-18), 396,823 of the 761,076 total messages.
Message history only goes back to 2026-02-01, so 30 days is a reasonable and representative
slice, not a data-availability compromise.

### Tool inventory (ground truth, from source)

Enumerated every tool from the `list/0` function in each `lib/orca_hub/mcp/tools/*.ex`
category module, cross-checked against `OrcaHub.MCP.Tools.@categories` (the aggregator) to
confirm no category was missed. Result: **43 live tools across 14 categories**, with every
declared `inputSchema.properties` key recorded as that tool's parameter list. (Two files in
the directory, `node_arg.ex` and `result.ex`, are helpers, not tool-defining modules — they
have no `list/0` and aren't in `@categories`.) A handful of names referenced in
`Tools.@regular_session_tools` (`file_feature_request`, `list_feature_requests`,
`get_feature_request`, `append_feature_request_note`, `close_feature_request`) are dead
allowlist entries from the pre-Issues feature-request API and don't correspond to any
current tool — excluded from the inventory, but see the "unknown tool names" note below,
because agents still call some of them (stale muscle memory or stale prompts).

### Where tool calls live, and the code-exec trap

Sessions run in code-exec mode by default (`session.code_exec: true`), which collapses
`tools/list` to exactly one tool, `run_elixir` — every other tool, including all 43 above,
is called from *inside* a `run_elixir` Elixir snippet as `Tools.<name>(%{...})`, not as a
direct `tool_use` block. Confirmed empirically in this window:

| | count |
|---|---:|
| Direct (non-`run_elixir`) `tool_use` blocks for first-party tools | 152 |
| `Tools.<name>(...)` calls found embedded in `run_elixir` code strings | 9,023 |
| **Ratio embedded : direct** | **~59 : 1** |

That's an even bigger undercount than the 18x figure from the prior audit this task cites —
looking only at direct blocks would have missed 98.3% of real usage. All numbers in this
report are direct + embedded combined.

### Extraction approach and coverage (read this before trusting the table)

Direct `tool_use` blocks are plain JSON (`block->'input'`) — trivial, exact, 100% coverage.

Embedded calls are **Elixir source text** inside `block->'input'->>'code'`, so the args are
Elixir map literals (`%{"key" => value, ...}`, occasionally atom-shorthand `%{key: value}`),
not JSON — regex/heuristic extraction, not a parser for a well-defined grammar. I built a
small structural extractor:

1. **Mask pass**: walk the code once, marking every character that's inside a `"..."`
   string, a `"""..."""` heredoc, or a `#` comment as opaque — so brace/paren counting and
   key detection never get confused by punctuation that's just text (e.g. a heartbeat
   message body that happens to contain `{`, `}`, or `"`).
2. **Call-site pass**: regex-find `Tools.<name>(` and `Tools.try_call("<name>", ...)` /
   `Tools.call("<name>", ...)` (347 of the 9,023 calls used the dispatch form — worth
   handling, not a rounding error), gated to real-code positions only, then walk forward
   tracking paren depth (skipping masked spans verbatim) to find the matching close-paren.
3. **Key extraction**: for each call's argument text, if it starts with `%{`, walk it
   structurally — expect a key, expect `=>` or `:`, skip the value (balanced
   brackets/braces/parens, masked spans consumed verbatim without descending into them),
   repeat until the map's own closing `}`. This only ever records **top-level** keys, so a
   key inside a nested map value (e.g. `update_artifact_data`'s `data` argument) is never
   miscounted as a top-level parameter.

   The one bug worth flagging because it would have been easy to ship silently: my first
   version gated key-detection on "is this position unmasked", but a map key's own quote
   characters are marked exactly the same as a value's string content by the mask (both are
   string literals) — so that check zeroed out *every* real key, including required ones. I
   caught it because `send_message_to_session`'s `session_id`/`message` — both `required` in
   the schema — showed ~1.6% "usage" before the fix. **If a required field on a table below
   isn't reading ~100%, don't trust the row above it either** — that was my own tripwire and
   I'm leaving the reasoning here so it can be someone else's too.

**Coverage** (parsed as a literal map / empty map, vs. total calls found for known tools):

| | found | parsed | coverage |
|---|---:|---:|---:|
| Embedded (`run_elixir`) | 9,023 | 8,050 | 89.2% |
| Direct | 152 | 152 | 100% |
| **Combined** | **9,175** | **8,202** | **89.4%** |

The unparsed 10.6% is calls where the argument wasn't a literal map — most commonly a
variable built earlier in the same snippet (`args = %{...}; Tools.foo(args)`) or a value
piped through another function. Per the brief's instruction, **these are treated as
unknown, not as "params absent"** — they're simply excluded from both the denominator
("parsed" column) and the per-parameter counts, so they can't inflate or deflate any
usage percentage. All "used%" figures below are `count / parsed`, never `count / found`.

A secondary sanity signal: 15 tool names appeared in embedded calls that aren't in the
current inventory at all — almost entirely either meta-calls (`schema`, `search`, `list` —
discovery, not tool calls, ~320 total) or a third-party upstream MCP server
(`playwright__browser_*`, ~580 total, out of scope per the brief) or drift from the
removed feature-request API (`list_feature_requests`, 13 calls — stale prompt/muscle
memory, not a current-schema parameter problem).

---

## Full table

Sorted by call volume (descending), then usage% (ascending) within each tool — so the
highest-volume, least-used parameters surface first.

| Tool | Param | Calls | Parsed | Cov% | Used | Used% |
|---|---|---:|---:|---:|---:|---:|
| send_message_to_session | sender_session_id | 2202 | 2202 | 100.0% | 2 | 0.1% |
| send_message_to_session | delivery | 2202 | 2202 | 100.0% | 4 | 0.2% |
| send_message_to_session | session_id | 2202 | 2202 | 100.0% | 2202 | 100.0% |
| send_message_to_session | message | 2202 | 2202 | 100.0% | 2202 | 100.0% |
| get_session_tail | include_last_message | 2114 | 2114 | 100.0% | 0 | 0.0% |
| get_session_tail | tool_call_limit | 2114 | 2114 | 100.0% | 193 | 9.1% |
| get_session_tail | full_last_message | 2114 | 2114 | 100.0% | 360 | 17.0% |
| get_session_tail | session_id | 2114 | 2114 | 100.0% | 2114 | 100.0% |
| start_session | orchestrator | 850 | 849 | 99.9% | 6 | 0.7% |
| start_session | fork_from_parent | 850 | 849 | 99.9% | 7 | 0.8% |
| start_session | issue_id | 850 | 849 | 99.9% | 9 | 1.1% |
| start_session | project_id | 850 | 849 | 99.9% | 16 | 1.9% |
| start_session | node | 850 | 849 | 99.9% | 17 | 2.0% |
| start_session | notify_on_completion | 850 | 849 | 99.9% | 17 | 2.0% |
| start_session | backend | 850 | 849 | 99.9% | 90 | 10.6% |
| start_session | idempotency_key | 850 | 849 | 99.9% | 109 | 12.8% |
| start_session | model | 850 | 849 | 99.9% | 742 | 87.4% |
| start_session | directory | 850 | 849 | 99.9% | 812 | 95.6% |
| start_session | title | 850 | 849 | 99.9% | 841 | 99.1% |
| start_session | prompt | 850 | 849 | 99.9% | 849 | 100.0% |
| archive_session | session_id | 825 | 825 | 100.0% | 825 | 100.0% |
| schedule_heartbeat | wake_on | 807 | 807 | 100.0% | 0 | 0.0% |
| schedule_heartbeat | watch_job_ids | 807 | 807 | 100.0% | 3 | 0.4% |
| schedule_heartbeat | watch_session_ids | 807 | 807 | 100.0% | 44 | 5.5% |
| schedule_heartbeat | interval_minutes | 807 | 807 | 100.0% | 50 | 6.2% |
| schedule_heartbeat | only_if_changed | 807 | 807 | 100.0% | 52 | 6.4% |
| schedule_heartbeat | watch_children | 807 | 807 | 100.0% | 723 | 89.6% |
| schedule_heartbeat | interval_seconds | 807 | 807 | 100.0% | 757 | 93.8% |
| schedule_heartbeat | message | 807 | 807 | 100.0% | 806 | 99.9% |
| cancel_heartbeat | session_id | 394 | 394 | 100.0% | 0 | 0.0% |
| report_progress | title | 359 | 359 | 100.0% | 214 | 59.6% |
| report_progress | phase | 359 | 359 | 100.0% | 359 | 100.0% |
| report_progress | note | 359 | 359 | 100.0% | 359 | 100.0% |
| search_sessions | archived_only | 224 | 224 | 100.0% | 0 | 0.0% |
| search_sessions | parent_session_id | 224 | 224 | 100.0% | 6 | 2.7% |
| search_sessions | include_activity | 224 | 224 | 100.0% | 21 | 9.4% |
| search_sessions | query | 224 | 224 | 100.0% | 22 | 9.8% |
| search_sessions | directory | 224 | 224 | 100.0% | 23 | 10.3% |
| search_sessions | session_id | 224 | 224 | 100.0% | 23 | 10.3% |
| search_sessions | include_archived | 224 | 224 | 100.0% | 28 | 12.5% |
| search_sessions | status | 224 | 224 | 100.0% | 29 | 12.9% |
| search_sessions | all_projects | 224 | 224 | 100.0% | 36 | 16.1% |
| search_sessions | limit | 224 | 224 | 100.0% | 58 | 25.9% |
| save_artifact | mode | 84 | 84 | 100.0% | 29 | 34.5% |
| save_artifact | open | 84 | 84 | 100.0% | 65 | 77.4% |
| save_artifact | kind | 84 | 84 | 100.0% | 83 | 98.8% |
| save_artifact | name | 84 | 84 | 100.0% | 84 | 100.0% |
| save_artifact | content | 84 | 84 | 100.0% | 84 | 100.0% |
| screenshot_artifact | artifact_id | 61 | 61 | 100.0% | 11 | 18.0% |
| screenshot_artifact | viewports | 61 | 61 | 100.0% | 35 | 57.4% |
| screenshot_artifact | name | 61 | 61 | 100.0% | 50 | 82.0% |
| check_job | job_id | 50 | 50 | 100.0% | 50 | 100.0% |
| get_artifact | artifact_id | 46 | 46 | 100.0% | 11 | 23.9% |
| get_artifact | name | 46 | 46 | 100.0% | 34 | 73.9% |
| append_issue_note | id | 32 | 32 | 100.0% | 29 | 90.6% |
| append_issue_note | note | 32 | 32 | 100.0% | 32 | 100.0% |
| start_job | verify_command | 18 | 18 | 100.0% | 1 | 5.6% |
| start_job | progress_path | 18 | 18 | 100.0% | 1 | 5.6% |
| start_job | progress_expect_bytes | 18 | 18 | 100.0% | 1 | 5.6% |
| start_job | progress_command | 18 | 18 | 100.0% | 2 | 11.1% |
| start_job | wake_when_done | 18 | 18 | 100.0% | 6 | 33.3% |
| start_job | cwd | 18 | 18 | 100.0% | 16 | 88.9% |
| start_job | timeout_seconds | 18 | 18 | 100.0% | 16 | 88.9% |
| start_job | command | 18 | 18 | 100.0% | 18 | 100.0% |
| start_job | label | 18 | 18 | 100.0% | 18 | 100.0% |
| update_artifact_data | artifact_id | 17 | 17 | 100.0% | 1 | 5.9% |
| update_artifact_data | name | 17 | 17 | 100.0% | 16 | 94.1% |
| update_artifact_data | data | 17 | 17 | 100.0% | 17 | 100.0% |
| create_issue | plan | 15 | 15 | 100.0% | 0 | 0.0% |
| create_issue | premise | 15 | 15 | 100.0% | 7 | 46.7% |
| create_issue | directory | 15 | 15 | 100.0% | 8 | 53.3% |
| create_issue | kind | 15 | 15 | 100.0% | 11 | 73.3% |
| create_issue | title | 15 | 15 | 100.0% | 15 | 100.0% |
| create_issue | description | 15 | 15 | 100.0% | 15 | 100.0% |
| get_issue | id | 15 | 15 | 100.0% | 15 | 100.0% |
| list_issues | mine | 13 | 13 | 100.0% | 0 | 0.0% |
| list_issues | all_projects | 13 | 13 | 100.0% | 2 | 15.4% |
| list_issues | query | 13 | 13 | 100.0% | 2 | 15.4% |
| list_issues | limit | 13 | 13 | 100.0% | 4 | 30.8% |
| list_issues | status | 13 | 13 | 100.0% | 5 | 38.5% |
| list_issues | kind | 13 | 13 | 100.0% | 9 | 69.2% |
| list_issues | directory | 13 | 13 | 100.0% | 9 | 69.2% |
| close_issue | superseded_by | 8 | 8 | 100.0% | 0 | 0.0% |
| close_issue | outcome | 8 | 8 | 100.0% | 5 | 62.5% |
| close_issue | resolution | 8 | 8 | 100.0% | 5 | 62.5% |
| close_issue | id | 8 | 8 | 100.0% | 8 | 100.0% |
| open_file | line | 6 | 6 | 100.0% | 0 | 0.0% |
| git_probe | node | 6 | 6 | 100.0% | 0 | 0.0% |
| git_probe | path | 6 | 6 | 100.0% | 0 | 0.0% |
| git_probe | commit | 6 | 6 | 100.0% | 0 | 0.0% |
| git_probe | limit | 6 | 6 | 100.0% | 1 | 16.7% |
| git_probe | from_sha | 6 | 6 | 100.0% | 2 | 33.3% |
| git_probe | to_sha | 6 | 6 | 100.0% | 2 | 33.3% |
| git_probe | action | 6 | 6 | 100.0% | 5 | 83.3% |
| open_file | file_path | 6 | 6 | 100.0% | 6 | 100.0% |
| git_probe | directory | 6 | 6 | 100.0% | 6 | 100.0% |
| phx_send_to_agent | timeout | 4 | 4 | 100.0% | 0 | 0.0% |
| phx_send_to_agent | context_id | 4 | 4 | 100.0% | 1 | 25.0% |
| phx_send_to_agent | wait | 4 | 4 | 100.0% | 2 | 50.0% |
| phx_send_to_agent | agent_id | 4 | 4 | 100.0% | 4 | 100.0% |
| phx_send_to_agent | message | 4 | 4 | 100.0% | 4 | 100.0% |
| open_artifact | artifact_id | 3 | 3 | 100.0% | 0 | 0.0% |
| send_discord_message | file_paths | 3 | 3 | 100.0% | 0 | 0.0% |
| list_jobs | mine | 3 | 3 | 100.0% | 0 | 0.0% |
| list_jobs | status | 3 | 3 | 100.0% | 0 | 0.0% |
| list_jobs | limit | 3 | 3 | 100.0% | 0 | 0.0% |
| open_artifact | mode | 3 | 3 | 100.0% | 2 | 66.7% |
| fork_queue | parent_session_id | 3 | 3 | 100.0% | 2 | 66.7% |
| open_artifact | name | 3 | 3 | 100.0% | 3 | 100.0% |
| send_discord_message | message | 3 | 3 | 100.0% | 3 | 100.0% |
| send_discord_message | reply_to_message_id | 3 | 3 | 100.0% | 3 | 100.0% |
| fork_queue | action | 3 | 3 | 100.0% | 3 | 100.0% |
| phx_get_task | agent_id | 3 | 3 | 100.0% | 3 | 100.0% |
| phx_get_task | task_id | 3 | 3 | 100.0% | 3 | 100.0% |
| phx_list_agents | query | 2 | 2 | 100.0% | 0 | 0.0% |
| cancel_job | job_id | 2 | 2 | 100.0% | 2 | 100.0% |
| wait_for_job | max_wait_seconds | 1 | 1 | 100.0% | 0 | 0.0% |
| send_notification | click_url | 1 | 1 | 100.0% | 0 | 0.0% |
| create_scheduled_trigger | hour | 1 | 1 | 100.0% | 0 | 0.0% |
| create_scheduled_trigger | minute | 1 | 1 | 100.0% | 0 | 0.0% |
| create_scheduled_trigger | day_of_week | 1 | 1 | 100.0% | 0 | 0.0% |
| create_scheduled_trigger | cron_expression | 1 | 1 | 100.0% | 0 | 0.0% |
| create_scheduled_trigger | directory | 1 | 1 | 100.0% | 0 | 0.0% |
| create_scheduled_trigger | reuse_session | 1 | 1 | 100.0% | 0 | 0.0% |
| wait_for_job | job_id | 1 | 1 | 100.0% | 1 | 100.0% |
| send_notification | message | 1 | 1 | 100.0% | 1 | 100.0% |
| send_notification | title | 1 | 1 | 100.0% | 1 | 100.0% |
| send_notification | priority | 1 | 1 | 100.0% | 1 | 100.0% |
| send_notification | markdown | 1 | 1 | 100.0% | 1 | 100.0% |
| create_scheduled_trigger | name | 1 | 1 | 100.0% | 1 | 100.0% |
| create_scheduled_trigger | prompt | 1 | 1 | 100.0% | 1 | 100.0% |
| create_scheduled_trigger | schedule | 1 | 1 | 100.0% | 1 | 100.0% |
| create_scheduled_trigger | project_id | 1 | 1 | 100.0% | 1 | 100.0% |
| create_scheduled_trigger | archive_on_complete | 1 | 1 | 100.0% | 1 | 100.0% |

**Tools with zero calls at all** (direct + embedded) in the window: `provision_database`,
`list_discord_attachments`, `fetch_discord_attachments`, `update_issue`,
`update_job_progress_metric`, `stat_paths`, `disk_free`, `create_webhook_trigger`. These are
whole-tool disuse, not a parameter question, and mostly explainable (Discord attachment
tools only matter for Discord-bridged sessions; `create_webhook_trigger` vs. the much more
common `create_scheduled_trigger`; `stat_paths`/`disk_free` are narrow probes). Flagged for
awareness, not analyzed further — out of this audit's scope.

---

## Top candidates: is there evidence agents *needed* it?

Ranked by volume × strength of evidence. Three "leave it alone" verdicts are included
deliberately — a low number alone isn't a finding, and manufacturing recommendations to
fill the ranking would defeat the point of the audit.

### 1. `get_session_tail.tool_call_limit` — 9.1% used (193/2114) — **RECOMMEND: advertise in payload**

This is structurally the *same* bug `full_last_message` had, on a sibling parameter of the
same tool, that the recent fix (`5557d83`) didn't touch — that fix addressed only the text
truncation, not the tool-call-list truncation. `get_session_tail` scans a session's last 50
assistant messages (`@tail_scan_limit`) and returns only the last `tool_call_limit`
(default 10) `tool_use` blocks found in that window — silently. Nothing in the result
tells the caller whether 10 was everything available or a hard cut.

Evidence of unmet need: across all sessions active in the window, **86.3%** have *more than
10* `tool_use` blocks in their last 50 assistant messages (median 24, max 51) — i.e. for the
large majority of sessions a get_session_tail peek could plausibly be hitting, the default
cap is truncating real information, with zero signal that it happened.

```sql
-- sessions_considered=1035, sessions_over_10=893 (86.3%), median=24, max=51
```

Caveat on evidence strength: this is a global proxy (session-level, not per-call — I did
not reconstruct the exact 50-message window at each individual call's timestamp), so it's
weaker than the direct "42.8% of responses truncated" signature for `full_last_message`.
But the structural parallel to an already-confirmed, already-fixed bug on the very same
tool is strong enough to act on. **Recommendation**: when `recent_tool_calls` is capped,
add `tool_calls_truncated: true` (mirroring the text truncation marker's phrasing) noting
`tool_call_limit` by name, the same fix pattern already applied to `full_last_message`.

### 2. `check_job` poll-looping vs. `wait_for_job`/`wake_when_done` — **RECOMMEND: advertise `wait_for_job` in `check_job`'s own result when non-terminal**

Not a single low-usage parameter — a load-bearing call-sequence pattern that two
parameters (`start_job.wake_when_done`, 33.3% used, and `wait_for_job` as a whole tool,
used **once** in 30 days) exist specifically to prevent, per its own description: *"Exists
so you stop hand-rolling `until ...; sleep` loops... for anything longer, poll with
check_job instead of burning turns here."*

Evidence: 50 `check_job` calls in the window collapse to only **7 distinct job ids** — one
job was checked **25 times in under 3 minutes** (15:55:39–15:58:41, spaced ~3–8s apart, one
check per turn). That's the textbook case `wait_for_job` was built for, and it wasn't used.

Nuance that changed my framing mid-investigation: I initially assumed the fix was "advertise
`wake_when_done` more" — but the *start_job* call for that same job (15:55:28, 11s before the
poll loop started) **did** pass `wake_when_done: true`. `wake_when_done` delivers via the
queue-while-running/flush-at-turn-end mechanism, same as a heartbeat — it can only notify the
agent once its *current* turn ends. An agent that wants to keep actively working within one
continuous turn (not yield/go idle) gets no benefit from it and falls back to synchronous
polling — which is exactly what `wait_for_job` (block up to 120s, return early on terminal
status) is *for*, and it went unused. So the real gap isn't discoverability of
`wake_when_done` (used 33% of the time, reasonably) — it's `check_job`'s result payload,
when status is still `running`/`verifying`, never mentioning that `wait_for_job` exists as
the same-turn alternative to calling `check_job` again immediately.

### 3. `send_message_to_session.idempotency_key`-equivalent risk — **VERDICT: leave alone (already mitigated)**

The brief's own illustrative example is "idempotency_key on spawn/send tools, where you can
see duplicate spawns." `start_session.idempotency_key` is explicit in only 12.8% of calls
(109/850) — looks like a candidate at first glance. But `start_session` computes an
**automatic** idempotency key even when none is passed (hash of caller session + MCP
request id + prompt/title/directory/model/backend/orchestrator, 15-minute window — see
`sessions.ex` `auto_idempotency_key/3`), specifically to catch transport-level replays the
model never intended. I searched for evidence this safety net is actually needed: zero
`start_session` results with `already_exists: true` (in any of the JSON/Elixir-inspect
formats a result could appear as) anywhere in the 30-day window — not one caught replay,
explicit or automatic. This matches project memory (`project-duplicate-child-spawns-rca.md`)
that this problem was already root-caused and fixed. Low *explicit* param usage here is not
evidence of an unmet need — the mechanism doesn't require the param to work.
**No recommendation** — this is a case where the illustrative example, checked, came back
clean.

### 4. `send_message_to_session.delivery` (interrupt) — 0.2% used (4/2202) — **VERDICT: leave alone (working as designed)**

`delivery: "interrupt"` is described at length directly in the tool's own top-level
description (not buried in a rarely-read schema field the way `full_last_message` was), so
this isn't a discoverability gap in the first place. Checked for a hidden cost anyway: of
the queued sends in the window, **33** eventually needed the automatic 15-minute
escalate-to-interrupt fallback (`"[Message delivery note - escalated]"` in message text) —
about 1/day, and each one cost up to a 15-minute delivery delay the sender didn't choose.
That's a real but modest cost, and the tool description already explains the tradeoff
("costs at most one turn's delay... auto-escalates... if that takes too long"). Not worth
a payload change for ~1 event/day already covered by an automatic safety net.
**No recommendation.**

### 5. `schedule_heartbeat.wake_on` — 0.0% used (0/807) — **VERDICT: leave alone (correctly follows its parent)**

`wake_on` only has an effect when `watch_job_ids` is also set ("No effect without
watch_job_ids" — schema description), and `watch_job_ids` itself is used in only 0.4% of
calls (3/807) — consistent with the broader low `start_job`/job-watching adoption seen in
finding #2. `wake_on` tracking its rarely-used parent 1:1 is exactly correct behavior, not
a bug. If job-watching adoption improves as a result of finding #2's fix, `wake_on` usage
should rise proportionally on its own — no separate action needed.

### 6. `start_session.backend` — 10.6% used (90/850) — **secondary note, not a discoverability finding**

Project memory records explicit prior guidance to prefer `backend: "pi"` /
`model: "gb10-coder/qwen3-coder-next"` for spawned workers over the Sonnet default. At
10.6% explicit usage this guidance doesn't look consistently followed — but the schema
already documents `backend` fully (it's not hidden), so this reads as a **prompt-adherence
question, not a payload-discoverability one**, and is out of this audit's frame (parameter
visibility) even though the raw number looks similar to the other candidates. Flagged for
whoever owns orchestration prompt guidance, not acted on here.

### 7. `search_sessions.include_activity` — 9.4% used (21/224) — **VERDICT: weak evidence, low priority**

Illustrative pattern from the brief: "a param that would collapse N calls into 1." In
principle, a `search_sessions` call *not* passing `include_activity: true`, followed by
several individual `get_session_tail` calls on the results, is exactly that pattern. I
looked for it: 94.8% of `get_session_tail` calls target a **literal** session id (not a
variable derived from a prior search result in the same snippet), which weighs against a
common "search-then-loop" chaining pattern — most `get_session_tail` targets look like ids
an agent already knew from earlier context, not ones just discovered via search. Volume is
also modest (224 calls). Worth revisiting if `search_sessions` volume grows, not urgent now.

### 8. `report_progress.title` — 59.6% used (214/359) — **VERDICT: healthy, no finding**

Included to show the table wasn't cherry-picked for zeros: at 59.6% this is a normal,
reasonably-adopted optional parameter — the one genuinely-required field, `phase`, sits at
100% (well, effectively — `phase` OR `title` is required; both together explain the split).
No action needed.

---

## Secondary: CLI-native tools (informational only — we can't change these schemas)

Per the brief's scope, this is secondary and brief. The one param the brief specifically
flagged as worth checking, `Read`'s `offset`/`limit` on large files, turned out **not** to
be a discoverability problem: of 8,649 direct `Read` calls in the window (CLI-native tools
are always direct blocks — code-exec doesn't wrap them — so this figure needs no embedded
correction), `limit` is used on 48.0% of calls and `offset` on 46.0%. That's healthy,
frequent usage, not a hidden/unused parameter. Nothing else jumped out in the CLI-native
surface worth a schema-we-can't-change note; no further action recommended here.

---

## Summary of recommendations

| Candidate | Verdict |
|---|---|
| `get_session_tail.tool_call_limit` | **Advertise in payload** — add a truncation marker naming the param, same pattern as the `full_last_message` fix |
| `check_job` (non-terminal result) | **Advertise `wait_for_job` in the result** when status is running/verifying, to break the observed poll-loop pattern |
| `start_session.idempotency_key` | Leave alone — auto-key already mitigates; zero caught replays in 30d |
| `send_message_to_session.delivery` | Leave alone — working as designed, cost is small (~1 escalation/day) and already documented |
| `schedule_heartbeat.wake_on` | Leave alone — correctly tracks its rarely-used parent `watch_job_ids` |
| `start_session.backend` | Not a payload-discoverability issue — prompt-adherence question, flagged for a different owner |
| `search_sessions.include_activity` | Weak evidence, low volume — revisit later, no action now |
| `Read.offset`/`limit` (CLI-native, secondary) | Already healthy usage (46–48%) — no finding |
