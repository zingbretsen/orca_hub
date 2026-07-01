# OrcaHub

Phoenix LiveView app for managing Claude Code sessions via a web UI.

## Development

- `mix phx.server` to start the dev server
- Logs are written to `log/dev.log` — use `tail -f log/dev.log` to monitor

## Architecture

- **SessionRunner** (`lib/orca_hub/session_runner.ex`): GenStatem that manages a Claude CLI session via a port. Sends prompts, parses streaming JSON output, persists messages, and broadcasts events via PubSub.
- **SessionLive.Show** (`lib/orca_hub_web/live/session_live/show.ex`): LiveView for viewing/interacting with a session. Handles message sending, image uploads, and file uploads.
- **MessageComponents** (`lib/orca_hub_web/components/message_components.ex`): Function components for rendering the message feed (user, assistant, tool use, results, system events).
- **OrcaHub.Claude** (`lib/orca_hub/claude/`): Modules for interacting with Claude CLI — builds CLI args (`Config`), parses streaming NDJSON output (`StreamParser`), and fetches usage metrics (`Usage`).

## Common issues

- Database timestamps are `NaiveDateTime` — convert to `DateTime` (with `"Etc/UTC"`) before passing to `DateTime.diff/3` or other `DateTime` functions

## Key patterns

- Messages are stored as flexible maps in a `data` column (no fixed schema for message content)
- File uploads save to the session's working directory so Claude can access them via its Read tool
- Document uploads are saved to the session's working directory for Claude to access
- Index tables use `row_click` with `JS.navigate` to make rows clickable to the show page (no separate View/Edit action links). See projects and issues index pages for examples.
- Sessions are grouped by directory in the index view, sorted by most recently updated
- Title auto-generation uses LLM API (`gpt-4.1-nano` by default, or DataRobot gateway)

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
