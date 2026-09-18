# OrcaHub — project operating manifest

Hand-maintained map of the codebase plus the invariants that bite. Keep it
under 6 KiB: it is the ONLY `.context/` file inlined into Claude/Codex
startup prompts (`SharedPrompts.context_manifest_prompt/1`). The detailed
docs it points at stay on disk — `Read` them on demand, never inline them.

## Topic map (read the file when the task touches the area)

- `.context/architecture.md` — module map: web layer (LiveViews, MCP.Plug,
  API controllers), core contexts, backends, streaming/WarmPool, CodeExec,
  files/artifacts, Discord/email bridges, data-flow summary.
- `.context/session-lifecycle.md` — SessionRunner GenStatem states
  (`ready/idle/running/error`; `waiting`/`compacting` are overlaid statuses),
  idle teardown, evict_warm, kill-switch downgrade, rebake on flag change.
- `.context/message-flow.md` — engine resolution (kill switch > session
  column > node env > streaming), one-shot vs streaming sequences, backend
  spawn/normalize call order, interrupt/steer/queue semantics.
- `.context/data-model.md` — ER diagram + per-table notes (issues/attempts,
  files/shares, jobs, api runs/A2A tasks, churn samples, api tokens, chunks).
- `.context/supervision-tree.md` — hub vs agent children, registries,
  hub-only GenServers (schedulers, sweeps, syncs), Discord children.
- `.context/clustering.md` — hub+agent topology, HubRPC/erpc, node routing,
  NodePolicy (isolation, env scrub), discovery, what agents cannot do.
- `.context/triggers.md` — scheduled/webhook/email triggers, executor flow,
  reuse_session, archive_on_complete, per-trigger tool restrictions.
- `.context/terminals.md` — PTY terminals, PubSub topics, multi-client
  pairing, cluster routing.
- `.context/voice-mode.md` — voice mode phases 1-2b: capture/VAD/ASR pipeline,
  the OVS1 wire contract, ASRConfig, browser traps, asset packaging, assistant
  deltas, streaming TTS, the global voice bar.
- Specs at repo root: `backend_abstraction_spec.md`, `issues_spec.md`,
  `pi_fork_spec.md`, `docs/api.md` (Agent Runs API).

## Key invariants

- **Backends are pluggable behind `OrcaHub.Backend`** (claude/codex/pi).
  SessionRunner never branches on a backend name; UI and runner branch on
  the `Capabilities` struct. Non-Claude backends normalize onto Claude's
  stream-json event shape and tool names, so rendering is backend-agnostic.
- **System prompt delivery differs per backend**: Claude = one
  `--append-system-prompt` argv value; Codex = leading message on the first
  turn; pi = flags-only prompt + `ORCA_IDENTITY`/`ORCA_MEMORY` env. Linux
  caps ANY single argv/env string at 128 KiB (`MAX_ARG_STRLEN`, E2BIG);
  `SessionRunner.check_spawn_spec_sizes!/2` fails loudly before
  `Port.open`. Never grow a prompt fragment without checking that guard.
- **pi's prompt must be a pure function of its flags** (prefix caching for
  forks); per-session bytes ride `ORCA_IDENTITY`. Claude/Codex prompts are
  byte-pinned by goldens in `test/support/fixtures/prompt_goldens/` —
  regenerate only for intentional prompt changes.
- **Hub owns the DB.** Agent nodes reach it only through `HubRPC` (erpc).
  Never re-route a session/trigger/terminal to another node when its
  assigned node is offline — surface "node unavailable" and skip.
- **Timestamps**: column types vary (`naive_datetime` vs `utc_datetime`);
  never sort/compare timestamp structs with bare `Enum.sort_by`/`<` — pass
  `{:asc, DateTime}` style comparators or `NaiveDateTime.compare/2`.
- **Messages are flexible maps** in `messages.data`; uploads land in the
  session's working directory so the agent can `Read` them.
- **MCP surface is one `run_elixir` tool** (code-exec mode); every OrcaHub
  and upstream tool is a `Tools.*` function inside it. CLI-native
  ScheduleWakeup/subagent/messaging tools die with the warm port — use
  `schedule_heartbeat`, `start_session`, `send_message_to_session`.
- **Memory lives in the memory service only** (`remember`/`recall`); every
  injection persists a `memory_injected` system event. Archiving a root or
  orchestrator session auto-dispatches memory extraction.
- **Artifacts render in `<iframe sandbox="allow-scripts">`** — never
  `allow-same-origin`, never server-rendered HEEx. The sandbox attribute is
  the security boundary; this decision is settled.
- **Markdown rendering is unsanitized** (earmark, retired, raw HTML passes
  through) — a known open security item; do not "fix" by swapping engines
  without a product decision.
- **Issues are durable work items**: `commits`/`attempts` are frozen at
  close; call `close_issue` with only `id` first to harvest evidence. Defect
  issues ship a `@tag :repro` test that the fixing commit un-tags.
- **Git is shared with sibling sessions**: commit by explicit path
  (`git commit -o`), never `add -A`/reset/stash others' work; scope
  `mix format` to touched files; run tests via `bin/test`.
- **Voice mode is client-VAD'd and refuses rather than works around**: the
  vad-web settings are non-default and load-bearing, the draft is sent with
  `:queue` (never `:interrupt`), and the channel refuses a join (one voice
  owner, node unavailable) instead of re-routing. The voice bar is STICKY in
  the app header, so every internal link must live-navigate (`<.link
  navigate>`) or the mic/channel dies. See `.context/voice-mode.md`.
- **Six prod instances** (3 k3s deployments via Flux GitOps, `mini`,
  `gb10` arm64, local systemd); deploy only through
  `~/homelab/scripts/deploy-orca-hub.sh`, verify with
  `verify-orca-deploy.sh`. Never `kubectl edit` Flux-managed resources.
