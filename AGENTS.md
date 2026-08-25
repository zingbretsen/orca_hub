This is an application that allows a user to orchestrate agentic sessions across physical nodes and backend harnesses.

## Project guidelines

- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

## Project memory

- This repo uses trunk-based development. Commit directly to `master`; only create branches when explicitly asked.
- `mix test` uses the dev DB by default. Run with DB vars exported and avoid sourcing `.env` wholesale because `ORCA_MODE`/`PHX_SERVER` can break test boot. A single `OrcaHub.TriggersTest` failure around `list_enabled_triggers/0` is a known dev-DB fixture issue, not necessarily a regression.
- Defect issues ship with a failing test tagged `@tag :repro`, issue key first in the test name, in the file where it will permanently live. `mix test` excludes them; run them with `mix test --only repro` (expected red). The fixing commit deletes the tag, converting the repro into a normal regression test.
- Prod topology is hub+agent: the local systemd `orca-hub` service is `ORCA_MODE=agent` on port 4001 with no Repo/UpstreamClient; the only hub/DB is the k3s `orca-hub` pod on `192.168.1.177:4000`. DB-touching RPC and upstream MCP registration should target the k3s hub pod, not the systemd agent.
- Prod deploys auto-run DB migrations on hub pod startup. No manual migration step is needed for normal additive migrations, but review risky migrations before rollout because pod startup will run them.
- Durable rollout requires both the k3s hub image/deployment and the local systemd OTP release. CodeSync or manual hot-loading is not durable across restarts.
- Browser-verify prod LiveView at `http://192.168.1.177:4000`; `http://127.0.0.1:4000` can render with a dead websocket due to origin checks. The agent UI on `:4001` is not intended for hub pages like `/sessions`.
- MCP/code-exec design should use live in-memory tool discovery/filtering and existing dispatch paths. Do not generate on-disk MCP tool files or schema stubs.
- The streaming SessionRunner is the default engine. It uses long-lived Claude CLI ports, has a runtime kill switch and warm-pool cap, and per-session MCP flag changes should auto-evict/reopen warm ports.
- Discord integration runs as a dedicated k3s agent pod (`orca-agent-discord`) with `DISCORD_BOT=true`, fail-closed guild allowlist, auto-provisioned channel/thread projects, and inert-by-default Nostrum via `included_applications`.
- Playwright MCP has a pinned image and heartbeat disabled with `PLAYWRIGHT_MCP_PING_TIMEOUT_MS=0`. For in-cluster browser testing, use the real upstream Playwright tool surface rather than local Chrome.
