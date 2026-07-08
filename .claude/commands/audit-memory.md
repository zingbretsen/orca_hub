---
description: Audit and refresh this project's Claude Code memory, cross-checking AGENTS.md and Codex memories for duplicates/staleness.
---

Audit the persistent memory for the current project. This command is
project-agnostic — everything below resolves relative to the current
working directory (the project root), not to any specific repo.

## 1. Resolve the memory directory

Compute the Claude Code project slug: take the current working directory's
absolute path and replace every character that is not `[A-Za-z0-9]` with
`-`. The memory directory is:

```
~/.claude/projects/<slug>/memory/
```

It contains `MEMORY.md` (an index — one line per memory file) plus one
`*.md` file per memory, each with YAML frontmatter (`name`, `description`,
`metadata.type`) and optional `[[name]]` links to other memory files by
their `name:` slug.

If the directory or `MEMORY.md` doesn't exist, say so and stop — there's
nothing to audit.

## 2. Index integrity check

- Every `*.md` file in the memory directory (other than `MEMORY.md` itself)
  must have exactly one corresponding line in `MEMORY.md`.
  - Flag memory files with **no** index line (orphaned — not discoverable).
  - Flag index lines whose target file is **missing** (dangling entries).
- For every `[[name]]` link found inside memory file bodies, confirm a
  memory file exists whose frontmatter `name:` matches. Unresolved links
  are worth flagging in your summary but are not errors — don't block on
  them.

Fix what you can mechanically: remove dangling index lines for files that
no longer exist, add missing index lines for orphaned files (inferring the
one-line hook from the file's `description:` frontmatter).

## 3. Staleness audit

For each memory file, read its content and verify its claims against
current reality:

- If it names a file path, function, module, flag, env var, or URL, check
  that it still exists (grep the codebase, check `git log`/`git blame` for
  renames/removals, or fetch the URL if it's load-bearing to the claim).
- If it describes a decision, incident, or state ("we're mid-migration",
  "X is broken", "waiting on Y"), check whether it's still current — e.g.
  via recent commits or by asking about anything ambiguous.
- Classify each memory as one of:
  - **keep** — still accurate, no changes needed.
  - **update** — partially stale; the core lesson holds but specifics
    (paths, names, flags) have drifted. Edit the file in place.
  - **delete** — fully obsolete, superseded, or no longer relevant. Delete
    the memory file AND remove its line from `MEMORY.md`.

Apply the updates and deletions directly (edit/delete the `*.md` files and
keep `MEMORY.md` in sync). Don't ask for confirmation per-memory; this is a
routine maintenance pass.

Produce a summary table at the end of this step:

| Memory | Verdict | Why |
|---|---|---|
| `name.md` | keep / update / delete | one-line reason |

## 4. Cross-agent check

Read the `## Project memory` section of this repo's `AGENTS.md` (if the
file or section doesn't exist, skip this step and note that in your final
report).

- Compare each bullet there against what you just found in Claude's
  memory directory. Flag (in your summary) any bullets that:
  - **duplicate** a Claude memory (same fact, redundant across agents —
    note it, but don't delete from `AGENTS.md` just for being a duplicate;
    it's checked into the repo and read by other agents/tools too).
  - **contradict** a Claude memory or the current codebase state.
  - **are stale** by the same staleness criteria as step 3.
- Fix stale or contradictory `AGENTS.md` bullets directly (edit the file).
  Since `AGENTS.md` is checked into the repo, commit these edits as part
  of your normal workflow (don't leave them uncommitted).

Also check whether `~/.codex/memories/` exists on this machine (Codex's
built-in memories feature, off by default — most Codex guidance instead
lives in `AGENTS.md`). If that directory exists and has files, list them
in your report for manual review — don't attempt to reconcile them
automatically, just surface them.

## 5. Final report

Summarize:
- The memory directory audited (path).
- The staleness table from step 3.
- Any orphaned/dangling index entries fixed.
- Any `AGENTS.md` bullets fixed, with a short diff description.
- Any `~/.codex/memories/` files found for manual review.
- Anything you flagged but deliberately left alone (e.g. unresolved
  `[[links]]`, ambiguous duplicates) and why.
