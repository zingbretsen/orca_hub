# Global agent-CLI config catalog (Nodes page) — research findings

Validated 2026-07-09 against: this host (`zach`, laptop/dev), k3s pods
`orca-hub` and `orca-agent-discord` (namespace `lab`, both `HOME=/home/orca`),
official docs (code.claude.com, developers.openai.com/codex,
github.com/badlogic/pi-mono), and `lib/orca_hub/backend/pi.ex`.

**Key prod finding:** the k3s pods only have the Claude CLI installed
(`/home/orca/.local/bin/claude`, v2.1.195). No `codex` or `pi` binary exists
in either pod, and no `~/.codex` or `~/.pi` directory exists. The Nodes page
must treat "CLI not installed on this node" as a normal, common state for
Codex/pi — not an error — for every node, not just these two.

Both pods' `~/.claude/` also contain two files not part of the documented
schema: `policy-limits.json` and `remote-settings.json`. The latter is
documented (server-managed settings cache, see
https://code.claude.com/docs/en/server-managed-settings) — it's a
client-side cache of org policy pulled from claude.ai, gets silently
overwritten, and should NOT be offered for user editing. `policy-limits.json`
has no public documentation; treat it the same way (internal client state,
exclude from the catalog / show read-only if shown at all).

---

## Claude Code — `~/.claude/`

| # | Path | Kind | Format | Purpose | Create template | Safe to edit live? |
|---|------|------|--------|---------|------------------|---------------------|
| 1 | `CLAUDE.md` | file | markdown | User-level instructions/preferences applied to every project (loads after managed policy, before project `CLAUDE.md`) | `# Personal instructions\n\n- \n` | Yes — but only picked up at next session start (project-root `CLAUDE.md` also re-reads after `/compact`; this global one behaves the same) |
| 2 | `settings.json` | file | JSON | Global user settings: model, permissions, env, hooks, plugins, `autoMemoryEnabled`/`autoMemoryDirectory`, etc. Lowest-precedence settings layer (managed > CLI args > local > project > **user**) | `{\n  "$schema": "https://json.schemastore.org/claude-code-settings.json"\n}\n` | Mostly yes — settings files are watched and hot-reload; `model`/`outputStyle` need a restart |
| 3 | `settings.local.json` | file | JSON | Personal per-machine overrides, one layer above `settings.json` (below project/local project settings) | same skeleton as above | Same as settings.json |
| 4 | `keybindings.json` | file | JSON | Custom keyboard shortcuts (`bindings` array, per-context) | `{\n  "$schema": "https://json.schemastore.org/claude-code-keybindings.json",\n  "bindings": []\n}\n` | Yes — auto-reloads, no restart needed |
| 5 | `agents/` | dir | markdown + YAML frontmatter, one file per subagent | User-level custom subagents (available in every project); overridden by a same-named project subagent | new file: `---\nname: my-agent\ndescription: When to use this subagent.\ntools: Read, Grep, Glob\n---\n\nSystem prompt for the subagent.\n` | Editing an existing file: yes. Creating the **directory** for the first time needs a Claude Code restart to be detected. |
| 6 | `skills/` | dir | one subdir per skill, `<name>/SKILL.md` (+ optional supporting files) | User-level skills / slash commands (`/name`), auto-invoked or manual | `---\ndescription: When Claude should use this skill.\n---\n\nInstructions for Claude.\n` at `skills/<name>/SKILL.md` | Editing existing skill files: yes, live change detection. First-ever creation of the top-level `skills/` dir needs a restart. |
| 7 | `commands/` | dir | flat `.md` files, one per command, same frontmatter as skills | Legacy pre-skills custom slash commands; still fully supported, but skills are now recommended (skills support supporting files; if a skill and command share a name, the skill wins) | `---\ndescription: What this command does.\n---\n\nInstructions.\n` | Same live-reload behavior as skills |
| 8 | `rules/` | dir | flat `.md` files, optional `paths:` frontmatter for path-scoping | User-level rules applied to every project (loaded before project `.claude/rules/`) | `# Topic\n\n- Rule 1\n- Rule 2\n` | Same as CLAUDE.md — picked up at next load |

**Secret/exclude — never surface for editing:**
- `.credentials.json` — OAuth/session credentials (chmod 600 on both hosts observed)
- `remote-settings.json` — org policy cache, silently overwritten, not user-editable
- `policy-limits.json` — undocumented internal client state, exclude
- `mcp-needs-auth-cache.json`, `.last-cleanup`, `.last-update-result.json`, `stats-cache.json`, `history.jsonl` — internal CLI bookkeeping, not config
- `projects/<slug>/memory/` — this IS the OrcaHub/Claude Code **auto-memory** store, but it's per-project (keyed by a git-repo slug), not a single global file — out of scope for a "global config" catalog; treat it as a separate future feature if ever surfaced
- `plugins/`, `sessions/`, `session-env/`, `shell-snapshots/`, `file-history/`, `debug/`, `cache/`, `backups/`, `downloads/`, `paste-cache/`, `tasks/` — CLI-managed runtime/cache state, not hand-edited config

Confirmed absent on this dev host at inspection time: `agents/`, `skills/`,
`commands/` (contrary to the task's starting assumption that `commands/` had
already been observed — it had not, on this host, right now). This is a good
sign the "assume none may exist" design premise is correct — even a daily-use
dev machine has none of the optional dirs populated.

Sources: https://code.claude.com/docs/en/settings ,
https://code.claude.com/docs/en/memory ,
https://code.claude.com/docs/en/sub-agents ,
https://code.claude.com/docs/en/skills ,
https://code.claude.com/docs/en/keybindings ,
https://code.claude.com/docs/en/server-managed-settings

---

## Codex — `~/.codex/` (CODEX_HOME)

| # | Path | Kind | Format | Purpose | Create template | Safe to edit live? |
|---|------|------|--------|---------|------------------|---------------------|
| 1 | `config.toml` | file | TOML | Primary user config: model, approval policy, sandbox, MCP servers, per-project trust (`[projects."<path>"]`), profiles, `[features]` flags | `# Codex config — see https://developers.openai.com/codex/config-reference\n` | Yes to edit; new/changed values apply on next session start (verify — not proven mid-session-live) |
| 2 | `AGENTS.md` | file | markdown | Global default instructions read every session (Codex's equivalent of Claude's `CLAUDE.md`) | `# Instructions\n\n- \n` | Yes, next session |
| 3 | `AGENTS.override.md` | file | markdown | When present, **replaces** `AGENTS.md` entirely for that session rather than merging — surface this nuance in the UI (e.g. a warning if both exist) | same skeleton as AGENTS.md | Yes, next session |
| 4 | `rules/` | dir | markdown files | User-level rules applied across all projects (not observed on either host — docs-only, unverified live) | `# Topic\n\n- Rule\n` | Unverified — treat like AGENTS.md |
| 5 | `prompts/` | dir | flat `.md` files, filename → `/prompts:<name>` slash command, optional frontmatter (`description`, `argument-hint`) + placeholders (`$1`, `$ARGUMENTS`, `$FILE`) | Custom prompt-based slash commands. **OpenAI has deprecated this in favor of skills** — still functional, worth a "deprecated" note in the UI | `---\ndescription: What this does.\n---\n\nPrompt body with $ARGUMENTS.\n` | Yes |
| 6 | `skills/` | dir | one subdir per skill, `<name>/SKILL.md` with `name`/`description` frontmatter | Personal skills, available across all projects | `---\nname: my-skill\ndescription: When Codex should use this.\n---\n\nInstructions.\n` at `skills/<name>/SKILL.md` | Yes, Codex detects changes automatically (restart if it doesn't pick up) |

**Important nuance on `skills/`:** both hosts/pods that had Codex installed
showed `~/.codex/skills/.system/` populated with Codex-bundled system skills
(`plugin-creator`, `openai-docs`, `imagegen`, `skill-installer`,
`skill-creator` — each with its own `SKILL.md`, `scripts/`, `assets/`,
`agents/`, `references/`). This `.system/` subdirectory is Codex-managed and
should be **excluded from Create/Edit** (or shown strictly read-only) — it's
not user content. Real personal skills live as siblings directly under
`~/.codex/skills/<name>/`, not inside `.system/`.

**Secret/exclude:**
- `auth.json` — OpenAI API key / OAuth session (chmod 600 observed)
- `installation_id`, `version.json`, `.personality_migration`, `history.jsonl`, `models_cache.json` — internal bookkeeping
- `goals_1.sqlite*`, `logs_2.sqlite`, `state_5.sqlite*` — internal SQLite state (WAL/SHM included), not config
- `memories/` (incl. `memories/extensions/ad_hoc/instructions.md`) and `memories_1.sqlite` — this is Codex's own **auto-memory** feature (`[features] memories = true` in `config.toml`), analogous to Claude's per-project auto-memory. Same reasoning as Claude: out of scope for the static global-config catalog.
- `sessions/`, `shell_snapshots/`, `log/`, `cache/`, `.tmp/`, `tmp/` — runtime/cache state

Sources: https://developers.openai.com/codex/config-reference ,
https://developers.openai.com/codex/config-basic ,
https://developers.openai.com/codex/custom-prompts ,
https://developers.openai.com/codex/skills

---

## pi (`@earendil-works/pi-coding-agent`) — `~/.pi/agent/`

Confirmed against the repo's own adapter (`lib/orca_hub/backend/pi.ex`) and
pi's own docs (`packages/coding-agent/docs/settings.md` in
github.com/badlogic/pi-mono, mirrored at earendil-works/pi). The global
config root is genuinely `~/.pi/agent/`, not `~/.pi/` — confirmed live on
this host.

| # | Path | Kind | Format | Purpose | Create template | Safe to edit live? |
|---|------|------|--------|---------|------------------|---------------------|
| 1 | `settings.json` | file | JSON | Core config: `defaultProvider`, `defaultModel`, `defaultThinkingLevel`, `defaultProjectTrust`, plus UI/telemetry/network/retry/session-storage settings | `{}` (all fields optional) | Yes |
| 2 | `SYSTEM.md` | file | markdown | Replaces pi's default system prompt entirely (global; project-local `.pi/SYSTEM.md` overrides this) | `# System prompt\n\n` | Not observed live on either host — treat like other prompt files, next-session pickup |
| 3 | `extensions/` | dir | `.ts` (or `.js`) files, one pi `ExtensionAPI` module each | Custom tools/hooks loaded at session start. **This host already has one real file here**: `extensions/claude-memories.ts`, an OrcaHub-authored bridge that surfaces Claude Code's per-project auto-memory `MEMORY.md` into pi sessions (read-only, checked into this repo at `scripts/pi-extensions/claude-memories.ts`) | N/A — these are code, not data; a sensible "create" affordance is a boilerplate `ExtensionAPI` module, not an empty file | Executable code — treat edits as higher-risk than data files; changes apply on next pi session start |
| 4 | `skills/` | dir | one subdir per skill, `<name>/SKILL.md` | Personal skills (not observed populated on this host) | same as Codex skills template | Yes |
| 5 | `prompts/` | dir | prompt template files | Personal prompt templates (not observed populated) | simple markdown template | Yes |
| 6 | `themes/` | dir | theme definition files | Custom TUI themes (not observed populated; low priority to surface first) | N/A | Yes |
| 7 | `trust.json` | file | JSON | Stores which project directories the user has approved (`--approve`) to run project-local `.pi/` skills/prompts/extensions | N/A — generated by pi itself | **Not a secret, but security-sensitive**: hand-editing can silently mark an untrusted project directory as trusted, bypassing pi's trust prompt. Recommend read-only display, or an explicit warning if editing is allowed. |

**Secret/exclude:**
- `auth.json` — provider credentials (Fireworks/OpenAI/Anthropic/etc API keys or OAuth), chmod 600 observed, confirmed by `lib/orca_hub/backend/pi.ex` moduledoc as the file pi reads unconditionally from `$HOME`
- `bin/` — vendored helper binaries (e.g. `fd`), not config
- `sessions/` — per-session transcripts (`--session-dir`), not global config
- `npm/` (per pi docs; not present on this host) — user-scoped npm package cache for installed extension/skill packages, not hand-edited

Sources: https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/settings.md ,
`lib/orca_hub/backend/pi.ex` (this repo)

---

## Cross-cutting implementation notes

- **Every backend can be absent on a node.** Neither `codex` nor `pi` is
  installed on either k3s pod today — only Claude is. The Nodes page's
  per-node, per-backend section must degrade gracefully (e.g. "Codex is not
  installed on this node" / offer to create the dir anyway vs. hide it) —
  don't assume all three CLIs coexist.
- **Three secret files to hard-blocklist, one per backend:**
  `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.pi/agent/auth.json`.
  All three were chmod 600 on every host/pod inspected. The implementation
  should refuse to read or display these paths even if asked, not just hide
  them from the catalog UI.
- **One quasi-secret to flag with a warning, not a hard block:** pi's
  `~/.pi/agent/trust.json` — not credentials, but editing it can silently
  grant a project trust it shouldn't have.
- **Auto-memory dirs are a deliberate scope exclusion** for both Claude
  (`~/.claude/projects/<slug>/memory/`) and Codex (`~/.codex/memories/`) —
  both are per-project, not truly global, and are a distinct existing/planned
  feature area, not part of this "global config file" catalog.
- **`.system`-style vendor-owned subdirectories** (Codex's
  `~/.codex/skills/.system/`) should be excluded from user Create/Edit even
  though they live inside a directory this catalog otherwise treats as
  editable — check for a leading dot or a vendor marker file
  (`.codex-system-skills.marker` was present) before offering edit affordances
  on directory contents, not just on top-level catalog entries.
