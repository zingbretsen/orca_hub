# OrcaHub

Phoenix LiveView app for managing Claude Code sessions via a web UI.

## Development

- `mix phx.server` to start the dev server
- Logs are written to `log/dev.log` — use `tail -f log/dev.log` to monitor

## Testing

- Canonical invocation (the `.env`'s `ORCA_MODE`/`PORT` break tests; `CLUSTER_*` leak into distributed state):
  ```
  export $(grep -E "^DB_" .env | xargs) && env -u PHX_SERVER -u ORCA_MODE -u PORT -u CLUSTER_NODES -u CLUSTER_DNS_QUERY mix test
  ```
- Distributed tests are excluded by default — run them separately: `mix test --only distributed`
- Confirmed known flake: `OrcaHub.TriggersTest "list_enabled_triggers/0"` (shared dev-DB leftover state). Two others flake intermittently across *repeated* runs under shared-dev-DB isolation gaps rather than every run — `NodeLive.IndexTest "load_nodes issues the same number of queries…"` and `PiStubIntegrationTest "a genuine turn error tears down the warm port…"` (being fixed at root separately as of 2026-08-09). Anything else failing is real — investigate, don't retry-until-green.
- Tests run against the shared dev DB, not an isolated test DB — hub-boot GenServers write real rows; this is expected.
- Don't trust this doc's flake list as-is before a deploy gate — establish the baseline empirically by running the full suite yourself (ideally more than once) against the SHA you're about to ship, since this file can silently drift out of date (it did for weeks before being corrected 2026-08-09), and a single clean run isn't guaranteed given the intermittent flakes above.

## Architecture

- **SessionRunner** (`lib/orca_hub/session_runner.ex`): GenStatem that manages an agent-CLI session via a port. Sends prompts, parses streaming JSON output, persists messages, and broadcasts events via PubSub. Delegates every CLI-specific concern (spawn args, stdin framing, event normalization) to `data.backend`.
- **OrcaHub.Backend** (`lib/orca_hub/backend.ex`, `backend/claude.ex`, `backend/codex.ex`): behaviour + adapters for pluggable agent CLIs (Claude, Codex — see `backend_abstraction_spec.md`). Each session persists its backend in the `sessions.backend` column, resolved once at runner init. Non-Claude backends normalize their native output into Claude's `stream-json` event shape so persistence/rendering stay backend-agnostic. A `Capabilities` struct per backend (`usage`, `mcp`, `plan_mode`, `ask_user_question`, …) gates UI chrome and model lists — the UI branches on capability fields, never on the backend name string. Codex auth is env-based (`OPENAI_API_KEY`, or a prior `codex login`) rather than the node-login flow Claude uses.
- **SessionLive.Show** (`lib/orca_hub_web/live/session_live/show.ex`): LiveView for viewing/interacting with a session. Handles message sending, image uploads, file uploads, and capability-gated chrome (usage panel, plan mode, AskUserQuestion, MCP toggles, model picker) via `Backend.capabilities_for/1`.
- **MessageComponents** (`lib/orca_hub_web/components/message_components.ex`): Function components for rendering the message feed (user, assistant, tool use, results, system events). Backend-agnostic — every backend normalizes onto Claude's existing tool names (Bash/Write/Edit/mcp__*/WebSearch/TodoWrite), so no per-backend rendering code exists.
- **OrcaHub.Claude** (`lib/orca_hub/claude/`): Modules for interacting with Claude CLI — builds CLI args (`Config`), parses streaming NDJSON output (`StreamParser`), and fetches usage metrics (`Usage`).

## Common issues

- Database timestamps are `NaiveDateTime` — convert to `DateTime` (with `"Etc/UTC"`) before passing to `DateTime.diff/3` or other `DateTime` functions
- Never sort/compare `%NaiveDateTime{}`/`%DateTime{}` structs with a bare `Enum.sort_by/2`, `Enum.sort/1`, `Enum.min_by/2`, `Enum.max_by/2`, `<`/`<=`/`>`/`>=`, etc. — Erlang's default term ordering compares struct fields ALPHABETICALLY (`microsecond` sorts before `minute`/`month`/`second`/`year`), not chronologically, so it silently scrambles any two timestamps sharing an `hour`. Always pass an explicit comparator: `Enum.sort_by(list, & &1.updated_at, {:desc, NaiveDateTime})` / `{:asc, DateTime}`, or `NaiveDateTime.compare/2` in a custom sorter fn. This caused the 2026-08-08 windowed-feed out-of-order/dropped-reply incident (`Sessions.list_messages_window/2`) — search for this bug class with `grep -rnE "Enum\.(sort_by|sort|min_by|max_by|min|max)\(" lib/` and inspect every hit touching a timestamp field.

## Key patterns

- Messages are stored as flexible maps in a `data` column (no fixed schema for message content)
- File uploads save to the session's working directory so Claude can access them via its Read tool
- Document uploads are saved to the session's working directory for Claude to access
- Index tables use `row_click` with `JS.navigate` to make rows clickable to the show page (no separate View/Edit action links). See projects and issues index pages for examples.
- Sessions are grouped by directory in the index view, sorted by most recently updated
- Session titles are agent-managed, not LLM-generated: orchestrators pass `title` to `start_session`, workers self-title via `report_progress`'s `title` arg (persists across turns, unlike `phase`/`note`). If neither ever sets one, `SessionRunner` falls back to a dumb truncation of the first prompt's first line at turn end.

## Deployment

There are FIVE prod instances; a full deploy updates all of them:

1. **k3s deployments `orca-hub`, `orca-agent-discord`, `orca-agent-dell`** (namespace
   `lab`) — share one Docker image from `registry.lab.ingbretsenhome.com`.
2. **`mini`** — a standalone host (same physical k3s cluster node, but runs its own
   OTP release + systemd unit outside k3s).
3. **Local systemd service `orca-hub`** — runs an OTP release installed under
   `/home/zach/orca-hub-releases/<sha>/` (symlink-flipped into place), NOT a
   `_build/prod/rel/orca_hub` local `mix release` build.

### Canonical deploy: `~/homelab/scripts/deploy-orca-hub.sh`

The canonical deploy script is a LOCAL/PRIVATE script that lives in the homelab
repo at `~/homelab/scripts/deploy-orca-hub.sh` — it is intentionally NOT checked
into this repo (`scripts/deploy.sh` is gitignored here as a guard against
accidental re-add). **Read the script itself before trusting a summary of it —
this section has been wrong before.** It builds from this checkout (`ORCA_REPO`,
default `/home/zach/orca_hub`) with **one build step**: a single multi-stage
`docker build` (builder → `artifact` | `runtime`) that produces both the SHA-tagged
runtime image (for k3s) and the extracted release directory (for local + `mini`) —
there is no separate local `mix release`. In order:

1. Guard: abort if the checkout is dirty (`git status --porcelain`, which includes
   untracked files) unless `--allow-dirty` is passed.
2. `git push` the deployed commit to origin.
3. The one `docker build` (+ extracted artifact).
4. Push the SHA-tagged image, then commit the new image tag into this repo's k3s
   manifests and push — **Flux (GitOps) notices the commit and rolls all three k3s
   deployments itself.** This script never runs `kubectl rollout restart`, and a
   direct `kubectl edit` against a Flux-managed resource gets silently reverted
   within ~5 minutes (see the `homelab-flux-gitops` skill).
5. Install the artifact on `mini` over ssh, restart its systemd service.
6. Install the artifact locally, `sudo systemctl restart orca-hub` — **runs LAST**,
   since a deploy driven from inside the local `orca-hub` process kills the script's
   own process tree the moment this restart fires.

Flags: `--skip-push`, `--skip-build`, `--skip-local`, `--skip-k3s`, `--skip-env`,
`--skip-mini`, `--allow-dirty`, `--arm64` (extra GB10/aarch64 artifact pass, off by
default, `--no-cache` by default — see the script header for why). **There is no
`--skip-release` flag** (no separate release-build step exists to skip). Run
`~/homelab/scripts/deploy-orca-hub.sh --help` for details.

Because the local systemd restart can kill the deploying session before it can
verify itself, `~/homelab/scripts/verify-orca-deploy.sh [sha]` is the companion
script to run afterward (by hand, or from another session) — it polls
`GET /api/version` on every instance and confirms each reports the target SHA.
**It lives in the homelab repo, not this one** — a worker told to "verify the
deploy" who only searches this repo won't find it and may hand-roll a worse
check instead. If it's genuinely unavailable, the manual fallback is the same
`/api/version` endpoint per instance: local systemd and `mini` on port `4001`,
the k3s hub pod on `4000`, and the k3s `orca-agent-discord`/`orca-agent-dell`
agent pods on `4010`/`4020` respectively (typically via port-forward).

**Passwordless sudo requirement:** the systemd step runs `sudo systemctl restart orca-hub`.
To avoid a password prompt, install the sudoers drop-in at
`/etc/sudoers.d/orca-hub` (root:root, mode 0440). A reference copy lives at
`scripts/orca-hub.sudoers` with install instructions in its header; it grants
`zach` NOPASSWD for start/stop/status/restart of the `orca-hub` unit only.
Validate after installing with `sudo visudo -cf /etc/sudoers.d/orca-hub`.
**This alone is not sufficient from an agent session running inside the
orca-hub release itself** — that process tree runs with `no_new_privs`, which
blocks `sudo` even with a valid NOPASSWD entry. The confirmed-working escape
is routing through sshd instead: `ssh localhost 'sudo -n systemctl restart
orca-hub'`.

### k3s reference

- Deployment manifests live in `~/homelab/k3s/apps/orca-hub.yaml`, NOT in `k8s/` (which is a generic/standalone reference)
- Secrets are in `~/homelab/k3s/secrets/orca-hub-secrets.yaml`
- Three deployments in the `lab` namespace share the one image: `orca-hub` (DB-owning hub), `orca-agent-discord` (Discord agent), `orca-agent-dell`
- Image registry: `registry.lab.ingbretsenhome.com`
- Ingress: `orca.lab.ingbretsenhome.com` (HTTPS via Traefik, Authelia forward-auth)
- Rollout is GitOps-driven (Flux), not a manual `kubectl` step — see the `homelab-flux-gitops` skill before touching any manifest by hand.

## Dependencies

- Phoenix LiveView ~> 1.1
- Req for HTTP requests
- DaisyUI/Tailwind for styling
