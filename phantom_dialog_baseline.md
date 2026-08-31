# Phantom pi-dialog baseline (pre-deploy)

Snapshot taken 2026-08-31 against `orca_hub_prod` (host `192.168.1.177`), inside a
single `REPEATABLE READ` transaction so all counts below are mutually consistent
despite prod being live (one of the phantom sessions found, `a44bfa83-...`, was
mid-turn and became `running` while these queries were being developed).

**This does not claim the phantom defect is fixed** — the fix (persisting
resolution events on more clearing paths) has not deployed yet. This is the
BASELINE a post-deploy re-run should be compared against, using the reusable
query in §5.

## Predicate under measurement

Mirrors `OrcaHub.Sessions.pending_pi_ui_request/1`
(`lib/orca_hub/sessions.ex:593-601`): take the session's most recent
`pi_ui_request` event (by `messages.inserted_at` desc); it's a "phantom" if no
`pi_ui_response` event anywhere in that session's history carries the same
`id`. Order/timing of the response relative to the request doesn't matter to
the predicate — only same-id existence.

## 1. Total sessions with a pi_ui_request, and how many are phantom

- Sessions with at least one `pi_ui_request` event: **31**
- Of those, phantom right now (per the predicate above): **19**

That's ~61% of all sessions that ever showed a pi dialog still showing an
unanswered one by this reconstruction — but see §2, most of that mass is long
idle/archived sessions, not live blast radius.

## 2. Split by session state

By archived/non-archived:

| archived? | phantom sessions |
|---|---|
| archived (`archived_at` set) | 18 |
| **non-archived** | **1** |

By `status`:

| status | phantom sessions |
|---|---|
| idle | 18 |
| running | 1 |

**The number that matters — non-archived sessions currently showing a
phantom dialog: 1.** That's session `a44bfa83-e4b9-4ddb-865d-9ced11141d77`
(backend `pi`, created 2026-08-31 12:46:05 UTC, status `running` at snapshot
time — i.e. live, still in-flight as this baseline was taken).

## 3. Batch sub-case (distinct phantom source)

Sessions where ≥2 `pi_ui_request` events land within ~1 second of each other
AND the session has fewer total `pi_ui_response` events than `pi_ui_request`
events (one response resolving several near-simultaneous sibling dialogs,
leaving the rest permanently unmatched):

**1 session**: `32536398-ff29-4d0f-a4d1-d76f6da7dafd` — 3 requests, 1 response.

Note this session is **not** in the 19 counted in §1/§2: its *latest*
request did get answered, so `pending_pi_ui_request/1` sees it as clean. The
2 unanswered earlier siblings are invisible to that predicate entirely — a
second, non-overlapping phantom source undercounted by the "latest only"
reconstruction. Combined distinct phantom-affected session count (§1 ∪ §3):
**20**.

## 4. Age distribution of the 19 phantom sessions (§1/§2)

- Oldest: session created **2026-08-12 12:40:03 UTC** (19 days old at
  snapshot time)
- Newest: session created **2026-08-31 12:46:05 UTC** (the live `running`
  one from §2 — 0 days old)
- Created in the last 7 days (>= 2026-08-24): **3 sessions**

Full listing (session id, session `inserted_at`, `archived_at`, `status`,
backend — all `pi`):

| session_id | created | archived_at | status |
|---|---|---|---|
| 8f79a464-f73b-4539-8934-491aa5b2cc2c | 2026-08-12 12:40:03 | 2026-08-26 23:46:22 | idle |
| 218a3d60-cef8-423a-9134-393adecbf909 | 2026-08-14 13:36:40 | 2026-08-14 13:56:48 | idle |
| 22a1f836-2b13-4b92-aeb2-0200c05d16ac | 2026-08-15 21:22:56 | 2026-08-16 12:15:54 | idle |
| c69defcd-c92e-4c02-ada4-e0b344539b68 | 2026-08-18 00:56:47 | 2026-08-18 01:05:54 | idle |
| 996a90f0-0bd4-464a-902f-a3329530e886 | 2026-08-18 02:01:33 | 2026-08-18 03:25:25 | idle |
| 33497601-93a5-4ae7-ab32-03e076116b14 | 2026-08-18 02:01:33 | 2026-08-18 02:55:55 | idle |
| 1a31bb16-a537-4d2d-bc0e-bb43f1461749 | 2026-08-18 03:25:25 | 2026-08-18 03:42:05 | idle |
| c4b37713-2d8b-43ec-a5ce-12b9ffad5119 | 2026-08-18 11:42:21 | 2026-08-18 12:18:18 | idle |
| 3f01257e-263a-446f-ab2e-e5587531d853 | 2026-08-18 23:58:28 | 2026-08-19 00:29:27 | idle |
| b82ef853-b623-4f84-bdb4-0b1cba9b26f4 | 2026-08-19 00:31:25 | 2026-08-19 01:02:23 | idle |
| efd81fd1-e03f-4a35-9f8c-7d5b05e3b649 | 2026-08-19 00:45:06 | 2026-08-23 11:40:31 | idle |
| 99ee7c3f-8ce3-4a54-b95c-5f01896d0df2 | 2026-08-19 01:26:29 | 2026-08-19 02:48:00 | idle |
| 0815c0a7-52a3-485b-a044-aee5c5e67fe4 | 2026-08-22 19:07:50 | 2026-08-22 19:52:58 | idle |
| d5d67dfa-44bd-4b38-8cd0-640286d2cdb1 | 2026-08-22 20:17:29 | 2026-08-22 21:16:55 | idle |
| d57aa863-626b-4d7f-b832-408a6ca91ff0 | 2026-08-23 02:28:53 | 2026-08-23 02:48:17 | idle |
| ed26c592-a0ca-4ac1-b6f3-128c46c3fed4 | 2026-08-23 11:53:59 | 2026-08-23 12:22:27 | idle |
| 398ad807-5a64-40fa-aa78-fe723118fcfe | 2026-08-29 13:05:17 | 2026-08-29 15:44:05 | idle |
| 6738fba4-c69e-42ad-ae2b-300fc0972a59 | 2026-08-30 22:04:28 | 2026-08-30 23:15:40 | idle |
| a44bfa83-e4b9-4ddb-865d-9ced11141d77 | 2026-08-31 12:46:05 | (none) | running |

All 19 are backend `pi`, consistent with `pending_question/1`'s dialog
reconstruction being pi-only (`lib/orca_hub/sessions.ex:622-638`).

## 5. Reusable post-deploy query

Run this after the fix deploys, replacing `<DEPLOY_TS>` with the deploy
timestamp (UTC), to see whether NEW phantoms stop forming among sessions
created after the fix landed. A non-zero count here means the fix did not
close the gap for at least one clearing path.

```sql
WITH latest_req AS (
  SELECT DISTINCT ON (session_id) session_id, data->>'id' AS req_id, inserted_at AS req_inserted_at
  FROM messages
  WHERE data->>'type' = 'pi_ui_request'
  ORDER BY session_id, inserted_at DESC, id DESC
),
phantom AS (
  SELECT lr.session_id, lr.req_id, lr.req_inserted_at
  FROM latest_req lr
  WHERE NOT EXISTS (
    SELECT 1 FROM messages m2
    WHERE m2.session_id = lr.session_id
      AND m2.data->>'type' = 'pi_ui_response'
      AND m2.data->>'id' = lr.req_id
  )
)
SELECT s.id, s.inserted_at, s.archived_at, s.status
FROM phantom p
JOIN sessions s ON s.id = p.session_id
WHERE s.inserted_at >= '<DEPLOY_TS>'::timestamp
ORDER BY s.inserted_at ASC;
```

And the batch sub-case (§3), same post-deploy scoping:

```sql
WITH req AS (
  SELECT session_id, inserted_at,
         LAG(inserted_at) OVER (PARTITION BY session_id ORDER BY inserted_at) AS prev_inserted_at
  FROM messages
  WHERE data->>'type' = 'pi_ui_request'
),
close_pairs AS (
  SELECT DISTINCT session_id
  FROM req
  WHERE prev_inserted_at IS NOT NULL
    AND (inserted_at - prev_inserted_at) <= interval '1 second'
),
counts AS (
  SELECT session_id,
    COUNT(*) FILTER (WHERE data->>'type' = 'pi_ui_request') AS req_count,
    COUNT(*) FILTER (WHERE data->>'type' = 'pi_ui_response') AS resp_count
  FROM messages
  WHERE data->>'type' IN ('pi_ui_request','pi_ui_response')
  GROUP BY session_id
)
SELECT cp.session_id, c.req_count, c.resp_count
FROM close_pairs cp
JOIN counts c ON c.session_id = cp.session_id
JOIN sessions s ON s.id = cp.session_id
WHERE c.resp_count < c.req_count
  AND s.inserted_at >= '<DEPLOY_TS>'::timestamp;
```

Both queries did a full scan of `messages` (861,588 rows at snapshot time,
no index on `data->>'type'`) — each took long enough to blow Postgrex's
default 15s connection-checkout timeout when run back-to-back without an
explicit `timeout:` override. Use a generous `timeout:` (60s+) if re-running
via `Postgrex.query!/4` directly, or plain `psql` which has no such client
timeout.

## What I could not determine

- Whether any of the 18 archived phantom sessions were ever actually
  *displayed* to a user with the stale dialog (vs. archived before anyone
  looked again) — the predicate only tells us the data shape, not viewer
  exposure. Not derivable from `messages`/`sessions` alone.
- Root cause per-session (which specific clearing path produced each
  phantom) — out of scope for a count-only baseline; would need per-session
  message-history inspection.

## Task 1 note (commit ancestry, reported for context)

At HEAD `d859057` (2026-08-31), all four of `1da7fd7`, `53e615b`, `dd23ce5`,
`ef06f18` are ancestors (`git merge-base --is-ancestor` exit 0 for all four).
