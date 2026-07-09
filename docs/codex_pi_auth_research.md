# Codex + pi auth wiring — research findings (2026-07-09)

Status: research only, nothing implemented. Companion to `backend_abstraction_spec.md`
and `backend_install_update_research.md`. PVC-widening direction below is **decided**,
not proposed.

## 1. Existing Claude login flow (template to mirror)

Modules: `OrcaHub.LoginRunner` (`lib/orca_hub/login_runner.ex`), singleton child of
`OrcaHub.LoginSupervisor` (DynamicSupervisor, started on every node in
`application.ex`); `OrcaHub.NodeCredentials` (DB-backed, hub-only); `Cluster.login_node/1`,
`submit_login_code/2`, `cancel_login/1` (`cluster.ex:457-463`); UI in
`SettingsLive.Index` (`index.ex` / `index.html.heex`).

Sequence:
1. Settings page lists cluster nodes with a "Log in" button per node (`Cluster.node_info/0`).
2. Click → LiveView subscribes to PubSub `"node_login:<node>"`, calls
   `Cluster.login_node(node)` → `Cluster.rpc(node, LoginRunner, :start_login, [])`.
   **The login process is spawned on the target node itself**, not the hub — this is
   the node-targeting mechanism (Erlang distribution via `Cluster.rpc`/`:erpc`).
3. `LoginRunner.init/1` opens a `Port` via `script -qc` (same PTY pattern as
   `SessionRunner`/`TerminalRunner`) running `claude setup-token`, PTY forced wide
   (`stty cols 400 rows 50`), 5-minute timeout timer armed.
4. Output streamed: buffered, ANSI-stripped, broadcast as `{:login_output, text}` on
   the per-node PubSub topic (auto-distributes cross-cluster via `:pg`, so the hub's
   LiveView receives it even though the process runs remotely).
5. URL scrape: regex for `https://...claude.com/...` → broadcast `{:login_url, url}` +
   `{:login_status, :awaiting_code}`. UI renders a clickable link.
6. Code entry: UI form → `Cluster.submit_login_code(node, code)` → RPC →
   `LoginRunner.submit_code/1` writes `code <> "\r"` to the port's stdin.
7. Token capture: regex for `sk-ant-oat\d+-...` in output. On match, GenServer stops,
   calls `HubRPC.put_node_token(node, token)` — **persists to Postgres
   (`node_credentials` table), not to a file** — and broadcasts `{:login_done, :success}`.
   The raw token is never broadcast to the LiveView, only the success signal.
8. Consumption: `NodeCredentials.token_env/1` produces a `CLAUDE_CODE_OAUTH_TOKEN` env
   var injected by `backend/claude.ex:138` whenever a session port is spawned — so
   Claude auth does **not** depend on `~/.claude/credentials.json` persisting on disk
   at all. That's why Claude's flow never needed a PVC-mount concern in the first place.
9. UI states (modal, keyed on `@login_status`): default/running/awaiting_code (URL +
   code form + live output pane), `:success` (green alert, Close button),
   `:error` (red alert). Escape/X → `cancel_login` → RPC → `GenServer.stop/2`.

**Key difference for codex/pi**: Claude sidesteps file persistence entirely via
DB-backed token storage + env-var re-injection. Codex/pi don't have an equivalent
scrape target as clean as `sk-ant-oat...` for pi (no such token format) and codex's
ChatGPT-OAuth path can't be reduced to a single bearer string the way Claude's is —
hence the decision to widen the PVC mount so `auth.json` itself persists, rather than
extending the DB-scrape pattern to two more backends.

## 2. Codex login methods

codex-cli 0.142.5 on this host. `~/.codex/auth.json` top-level keys observed:
`OPENAI_API_KEY`, `auth_mode`, `last_refresh`, `tokens` (nested: `access_token`,
`id_token`, `refresh_token`, `account_id`). Current host is in `auth_mode: "chatgpt"`.
`~/.codex/config.toml` has no auth fields.

| Method | Command | Interactive? | Writes | Headless (SSH) | Pod via `kubectl exec` | Notes |
|---|---|---|---|---|---|---|
| Browser OAuth | `codex login` | Yes, opens browser, listens `localhost:1455` | `auth_mode`, `tokens` | Only with port-forward tunnel | Not viable | Default ChatGPT-plan method |
| API key via stdin | `printenv OPENAI_API_KEY \| codex login --with-api-key` | No | `OPENAI_API_KEY`, `auth_mode` | Works | **Viable** | Simplest headless path |
| Access token via stdin | `... \| codex login --with-access-token` | No | `tokens.*` | Works if token available | Viable | Reuses a token minted elsewhere |
| Device-code auth (beta) | `codex login --device-auth` | Semi-interactive — CLI prints URL+code, approved from **any** device's browser | `auth_mode: chatgpt`, `tokens` | **Viable — documented workaround** | **Viable via exec** | Requires "device code" enabled in ChatGPT security settings first |
| Copy `auth.json` | manual file copy | No | N/A | Trivial | Trivial via `kubectl cp` | Docs list this as a supported headless workaround |
| `OPENAI_API_KEY` env, no login | just set env var | No | none | Works | Works, no PV needed | No `codex login` step required for pure API-key auth |

Precedence (no formal doc statement; established via `openai/codex` issues #15151,
#3286, #5212): **`OPENAI_API_KEY` env var wins over a ChatGPT OAuth `auth.json`** —
this has caused real user-facing bugs (silent override → misleading 401). Recommended
practice: pick exactly one auth source per pod, don't mix.

ChatGPT-plan auth requires OAuth (browser or device-auth) — no way to get plan
credits via API key alone. API-key auth is the only path usable with zero
interactivity (CI/automation-grade).

**Recommendation**: for a pod with the widened `~/.codex` PVC, one-time bootstrap via
`codex login --device-auth` through `kubectl exec` (approved from any browser) gives
full ChatGPT-plan auth durably; or `--with-api-key` for pure API-key mode. Either way,
**do not** also set a bare `OPENAI_API_KEY` env var on that pod if OAuth/device-auth
was used — it will shadow the persisted login (see Risks).

## 3. pi provider key mechanics

pi 0.80.3, backend is `@earendil-works/pi-coding-agent` / `pi-ai`.

**Env vars per provider** (from `pi-ai`'s `env-api-keys.js`): `anthropic` →
`ANTHROPIC_OAUTH_TOKEN` (checked first) or `ANTHROPIC_API_KEY`; `openai` →
`OPENAI_API_KEY`; `google` → `GEMINI_API_KEY`; `fireworks` → `FIREWORKS_API_KEY`;
`together` → `TOGETHER_API_KEY`; `openrouter` → `OPENROUTER_API_KEY`; `mistral` →
`MISTRAL_API_KEY`; `groq` → `GROQ_API_KEY`; `cerebras` → `CEREBRAS_API_KEY`; `xai` →
`XAI_API_KEY`; `deepseek` → `DEEPSEEK_API_KEY`; plus a long tail (nvidia, azure,
minimax, moonshot, huggingface, github-copilot, zai, kimi, cloudflare, vercel-ai-gateway,
opencode, xiaomi, ant-ling, amazon-bedrock via AWS creds). Full list in agent transcript
if needed for the UI's provider dropdown.

**`~/.pi/agent/auth.json` schema** — top-level object keyed by provider id:
```json
{ "<providerId>": { "type": "api_key", "key": "<secret>" } }
```
(oauth-type entries also possible: `{"type":"oauth","access":...,"refresh":...,"expires":...}`).
File mode `0600`, parent dir `0700`. This host has exactly one entry, `"fireworks"`
(`type: "api_key"`, value not inspected). `~/.pi/agent/settings.json` holds
non-secret defaults (`defaultProvider`, `defaultModel`) — currently `fireworks` /
`accounts/fireworks/models/minimax-m2p7`.

**CLI affordances**: `pi --help` only exposes `install/remove/uninstall/update/list/config`
— no `pi auth`/`pi login`/`pi keys` subcommand exists in 0.80.3. `--api-key <key>` is a
**runtime-only override**, never persisted. The only way to durably set a key today is
the interactive in-session `/login` slash command (TUI). **No headless/non-interactive
CLI path to write `auth.json` exists.**

**Precedence** (from `AuthStorage.getApiKey()` / `pi-ai`'s `envApiKeyAuth().resolve()`):
runtime override → **stored `auth.json` key** → stored OAuth token → env var last.
**`auth.json` wins over the env var** (opposite of codex's env-wins behavior — the two
backends are inconsistent here, worth flagging in the UI copy).

**OrcaHub `backend/pi.ex` today**: no hardcoded provider — model passed through as an
opaque `"provider/model"` string, or omitted to let pi fall back to `settings.json`'s
default. `models/0` shells `pi --list-models`, which only enumerates providers that
already have credentials in `auth.json`. So the existing model picker is entirely
downstream of whatever's in that file already (currently just Fireworks on this host).

**Recommendation**: since there's no CLI/RPC to drive non-interactively, **OrcaHub
should write `auth.json` directly** — read-merge-write (only touching the target
provider's key), mode `0600`, mirroring `AuthStorage.persistProviderChange`. Simple,
stable, low risk given all current entries are `api_key` type (no concurrent
OAuth-refresh writer to race against, for now).

## 4. Pod persistence — decided: widen PVC mounts (concrete spec)

Both `~/homelab/k3s/apps/orca-hub.yaml` and `orca-agent-discord.yaml` use one
dedicated PVC per CLI-home mount, no `subPath`, no explicit `storageClassName`
(defaults to cluster default): `orca-hub-claude` → `/home/orca/.claude` (and
independently, `orca-agent-discord-claude` → `/home/orca/.claude` in the other
manifest — the two pods do **not** share a PVC). `docs/backend_install_update_research.md`
(~lines 153-164) already flagged this exact gap as open work.

**Image-bake check (verified live via `kubectl exec`, both pods)**: neither
`/home/orca/.codex` nor `/home/orca/.pi` exists in either running pod today — nothing
pre-baked, nothing runtime-created yet either. Dockerfile only does
`npm install -g @openai/codex@latest @earendil-works/pi-coding-agent@latest`, no
`RUN codex ...`/`RUN pi ...` build step. **Zero shadow/overwrite risk** from mounting
fresh empty PVCs at these paths.

**StorageClass**: `local-path` (Rancher local-path-provisioner), same as the existing
`-claude` PVCs — node-local hostPath-backed, binds to whichever node the pod first
schedules on, RWO only, capacity requests unenforced/soft. No new operational concern;
both Deployments are already effectively pinned to one node via the existing claude PVC.

**Recommended concrete edit — PVC-per-path, mirroring the existing convention exactly**
(no `subPath` precedent anywhere in these manifests; introducing one now would be a
stylistic departure with no real benefit since quota isn't enforced anyway). Add
`orca-hub-codex` + `orca-hub-pi` PVCs (and mirrored `orca-agent-discord-codex` /
`orca-agent-discord-pi` in the other file):

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: orca-hub-codex
  namespace: lab
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: orca-hub-pi
  namespace: lab
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

Deployment `volumeMounts` addition:
```yaml
            - name: codex-data
              mountPath: /home/orca/.codex
            - name: pi-data
              mountPath: /home/orca/.pi
```

Deployment `volumes` addition:
```yaml
        - name: codex-data
          persistentVolumeClaim:
            claimName: orca-hub-codex
        - name: pi-data
          persistentVolumeClaim:
            claimName: orca-hub-pi
```

Same three additions in `orca-agent-discord.yaml` with `orca-agent-discord-` prefixed
PVC names. No other structural change needed (`envFrom`, probes, resources untouched).

**Env-var fallback (only where file persistence can't apply)**: existing Secret
`orca-hub-secrets` (`envFrom: secretRef`, whole-secret injection into both pods
already) has an `OPENAI_API_KEY` key already present and already live in both
containers — almost certainly the title-gen LLM API key per CLAUDE.md. **This is a
direct collision risk with codex** (see Risks below), not a reason to prefer env
injection generally now that PVC widening is decided.

## 5. Security / UI placement

`NodeConfig` (`lib/orca_hub/node_config.ex:305-309`) hard-blocklists `codex: ["auth.json"]`
and `pi: ["auth.json"]` (plus Claude's `.credentials.json`) — checked in
`resolve_path/3` (`:466-472`) before catalog lookup, and `validate_relative_path/1`
additionally rejects any path segment starting with `.`, so no crafted path can reach
these files through the generic config/skills browser. **Any new login/key-write
module must stay outside this path entirely** — don't add `auth.json` to the catalog
or special-case it through `NodeConfig`; use dedicated, narrow functions instead:
- Codex: a `LoginRunner`-style module driving `codex login --device-auth` (or
  `--with-api-key` with a pasted key piped to stdin) via Port, same PTY pattern as
  Claude's flow, node-targeted via `Cluster.rpc`. Because the widened PVC now makes
  `~/.codex/auth.json` durable, **no DB-scrape-and-store step is needed** — simpler
  than Claude's flow, just let the CLI write its own file. A narrow "is this node
  logged in" check can read `auth_mode`/presence of `tokens`/`OPENAI_API_KEY` keys
  (key names only, never values) for the UI badge.
- pi: no PTY/process needed at all — a small node-targeted RPC function that does
  read-merge-write on `auth.json` (provider id + key in, `0600` mode out). UI: a
  provider dropdown + password-masked input, write-only (submit → store → clear
  field), with a "configured" badge per provider derived from **top-level key names
  only** (never the secret value) — same narrow-read principle as codex above.

**UI placement recommendation**: mirror Claude's placement exactly — Settings page,
per-node section, since the login flow is fundamentally node-targeted (the CLI process
and its config files live on that specific node/pod). This is also the intuitive place
for pi's provider-keys, since the file is genuinely node-local (each pod's PVC is
independent) — no reason to diverge from the existing per-node Settings-page pattern
for either feature.

## 6. Open risks / decisions needed

- **`OPENAI_API_KEY` collision**: the Secret's existing `OPENAI_API_KEY` (title-gen)
  is injected into every pod already. If a pod's codex is set up via ChatGPT
  OAuth/device-auth (durable `auth.json` on the new PVC), that same ambient env var
  will **silently override** the OAuth login per codex's documented env-wins
  precedence (issues #15151/#3286) — misleading 401s or wrong-account behavior. Needs
  a decision: either keep codex on pure API-key auth site-wide (accept env var, skip
  OAuth), or explicitly unset/rename the env var codex sees vs. the one title-gen uses
  (they may need to be different values anyway — same name, different concern).
- **Device-auth prerequisite**: requires "device code" enabled in ChatGPT account
  security settings first — a one-time manual account-level step outside the app.
- **No pi key validation**: no non-interactive pi command to test a key before saving;
  a typo'd key won't surface until a session actually fails. Consider a post-save
  `pi --list-models` (or similar) sanity check.
- **pi/codex precedence inconsistency**: pi's `auth.json` wins over env vars; codex's
  env var wins over `auth.json`. Worth calling out in UI copy so users don't assume
  symmetric behavior between the two "Update all backends" style features.
- **systemd host** (per memory: local systemd `orca-hub` runs `ORCA_MODE=agent`) has a
  normal, non-ephemeral filesystem — no PVC-equivalent concern there; codex/pi homes
  just persist normally. This whole PVC-widening question is k3s-pod-specific.
- **File-write concurrency**: pi's own OAuth-refresh path (if a provider is ever
  `type: oauth`) could race with OrcaHub's read-merge-write. Low risk today since this
  host's only entry is `api_key` type, but worth a comment if/when Anthropic
  OAuth-via-pi is ever wired up.
