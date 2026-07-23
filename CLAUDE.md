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
- Exactly ONE known flake: `OrcaHub.TriggersTest "list_enabled_triggers/0"` (shared dev-DB leftover state). Anything else failing is real — investigate, don't retry-until-green.
- Tests run against the shared dev DB, not an isolated test DB — hub-boot GenServers write real rows; this is expected.

## Architecture

- **SessionRunner** (`lib/orca_hub/session_runner.ex`): GenStatem that manages an agent-CLI session via a port. Sends prompts, parses streaming JSON output, persists messages, and broadcasts events via PubSub. Delegates every CLI-specific concern (spawn args, stdin framing, event normalization) to `data.backend`.
- **OrcaHub.Backend** (`lib/orca_hub/backend.ex`, `backend/claude.ex`, `backend/codex.ex`): behaviour + adapters for pluggable agent CLIs (Claude, Codex — see `backend_abstraction_spec.md`). Each session persists its backend in the `sessions.backend` column, resolved once at runner init. Non-Claude backends normalize their native output into Claude's `stream-json` event shape so persistence/rendering stay backend-agnostic. A `Capabilities` struct per backend (`usage`, `mcp`, `plan_mode`, `ask_user_question`, …) gates UI chrome and model lists — the UI branches on capability fields, never on the backend name string. Codex auth is env-based (`OPENAI_API_KEY`, or a prior `codex login`) rather than the node-login flow Claude uses.
- **SessionLive.Show** (`lib/orca_hub_web/live/session_live/show.ex`): LiveView for viewing/interacting with a session. Handles message sending, image uploads, file uploads, and capability-gated chrome (usage panel, plan mode, AskUserQuestion, MCP toggles, model picker) via `Backend.capabilities_for/1`.
- **MessageComponents** (`lib/orca_hub_web/components/message_components.ex`): Function components for rendering the message feed (user, assistant, tool use, results, system events). Backend-agnostic — every backend normalizes onto Claude's existing tool names (Bash/Write/Edit/mcp__*/WebSearch/TodoWrite), so no per-backend rendering code exists.
- **OrcaHub.Claude** (`lib/orca_hub/claude/`): Modules for interacting with Claude CLI — builds CLI args (`Config`), parses streaming NDJSON output (`StreamParser`), and fetches usage metrics (`Usage`).

## Common issues

- Database timestamps are `NaiveDateTime` — convert to `DateTime` (with `"Etc/UTC"`) before passing to `DateTime.diff/3` or other `DateTime` functions

## Key patterns

- Messages are stored as flexible maps in a `data` column (no fixed schema for message content)
- File uploads save to the session's working directory so Claude can access them via its Read tool
- Document uploads are saved to the session's working directory for Claude to access
- Index tables use `row_click` with `JS.navigate` to make rows clickable to the show page (no separate View/Edit action links). See projects and issues index pages for examples.
- Sessions are grouped by directory in the index view, sorted by most recently updated
- Session titles are agent-managed, not LLM-generated: orchestrators pass `title` to `start_session`, workers self-title via `report_progress`'s `title` arg (persists across turns, unlike `phase`/`note`). If neither ever sets one, `SessionRunner` falls back to a dumb truncation of the first prompt's first line at turn end.

## Deployment

There are TWO prod instances; a full deploy updates both:

1. **Local systemd service `orca-hub`** — runs an OTP release from
   `_build/prod/rel/orca_hub`. Updating it = build a prod release, then
   `sudo systemctl restart orca-hub`.
2. **k3s deployments `orca-hub` and `orca-agent-discord`** (namespace `lab`) —
   both run the same Docker image from `registry.lab.ingbretsenhome.com`.

### Canonical deploy: `~/homelab/scripts/deploy-orca-hub.sh`

The canonical deploy script is a LOCAL/PRIVATE script that lives in the homelab
repo at `~/homelab/scripts/deploy-orca-hub.sh` — it is intentionally NOT checked
into this repo (`scripts/deploy.sh` is gitignored here as a guard against
accidental re-add). It builds from this checkout (`ORCA_REPO`, default
`/home/zach/orca_hub`) and runs, in order:

1. `git push` the deployed commit to origin.
2. Build local prod OTP release (`mix deps.get --only prod`, `mix assets.deploy`,
   `mix release --overwrite`).
3. Build + push the Docker image, then `kubectl rollout restart` BOTH k3s
   deployments (`orca-hub` and `orca-agent-discord`) — they share the one image.
4. `sudo systemctl restart orca-hub`.

Flags let you target one instance: `--skip-k3s` (local release + systemd only),
`--skip-local --skip-release` (k3s image roll only), `--skip-release`,
`--skip-local`, `--skip-push`. Run `~/homelab/scripts/deploy-orca-hub.sh --help`
for details.

**Passwordless sudo requirement:** the systemd step runs `sudo systemctl restart orca-hub`.
To avoid a password prompt, install the sudoers drop-in at
`/etc/sudoers.d/orca-hub` (root:root, mode 0440). A reference copy lives at
`scripts/orca-hub.sudoers` with install instructions in its header; it grants
`zach` NOPASSWD for start/stop/status/restart of the `orca-hub` unit only.
Validate after installing with `sudo visudo -cf /etc/sudoers.d/orca-hub`.

### k3s reference

- Deployment manifests live in `~/homelab/k3s/apps/orca-hub.yaml`, NOT in `k8s/` (which is a generic/standalone reference)
- Secrets are in `~/homelab/k3s/secrets/orca-hub-secrets.yaml`
- Two deployments in the `lab` namespace: `orca-hub` (DB-owning hub) and `orca-agent-discord` (Discord agent); both run the same image
- Image registry: `registry.lab.ingbretsenhome.com`
- Ingress: `orca.lab.ingbretsenhome.com` (HTTPS via Traefik, Authelia forward-auth)
- Manual deploy (reference): `docker build -t registry.lab.ingbretsenhome.com/orca-hub:latest . && docker push registry.lab.ingbretsenhome.com/orca-hub:latest && kubectl rollout restart deployment/orca-hub deployment/orca-agent-discord -n lab`

## Dependencies

- Phoenix LiveView ~> 1.1
- Req for HTTP requests
- DaisyUI/Tailwind for styling
