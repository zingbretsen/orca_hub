# OrcaHub

Phoenix LiveView app for managing Claude Code sessions via a web UI.

## Development

- `mix phx.server` to start the dev server
- Logs are written to `log/dev.log` — use `tail -f log/dev.log` to monitor

## Testing

- **Use `bin/test`** — a wrapper that scrubs `.env`'s `ORCA_MODE`/`PORT` (which break tests) and `CLUSTER_*` (which leak into distributed state), passes `DB_*` from `.env`, and forwards all arguments to `mix test`.
  - The long form is what the script does, for reference:
    ```
    export $(grep -E "^DB_" .env | xargs) && env -u PHX_SERVER -u ORCA_MODE -u PORT -u CLUSTER_NODES -u CLUSTER_DNS_QUERY mix test
    ```
- Distributed tests are excluded by default — run them separately: `mix test --only distributed`
- Repro tests are excluded by default too. A defect issue ships with a test that FAILS in the current unfixed state — executable proof the defect is real, and a free regression test once fixed. Tag it `@tag :repro`, start the test name with the issue key (e.g. `test "ORCAHUB3-24: an artifact with no data does not pre-seed a truthy window.ORCA_DATA"`), and put it in the file where it will permanently live — not a quarantine dir. Run them on demand with `mix test --only repro`; they are EXPECTED to be red, that is the point, so never add one to the flake list.
- **The fixing commit removes the `@tag :repro` line in the same commit as the fix**, silently converting the repro into a normal regression test. A `:repro` tag left on a fixed defect means the test stops running.
- Confirmed known flake: `OrcaHub.TriggersTest "list_enabled_triggers/0"` (shared dev-DB leftover state). Two others flake intermittently across *repeated* runs under shared-dev-DB isolation gaps rather than every run — `NodeLive.IndexTest "load_nodes issues the same number of queries…"` and `PiStubIntegrationTest "a genuine turn error tears down the warm port…"` (being fixed at root separately as of 2026-08-09). Anything else failing is real — investigate, don't retry-until-green.
- Tests run against the shared dev DB, not an isolated test DB — hub-boot GenServers write real rows; this is expected.
- Don't trust this doc's flake list as-is before a deploy gate — establish the baseline empirically by running the full suite yourself (ideally more than once) against the SHA you're about to ship, since this file can silently drift out of date (it did for weeks before being corrected 2026-08-09), and a single clean run isn't guaranteed given the intermittent flakes above.
- 2026-08-13/14 observation: four consecutive full-suite runs (2×2316 tests @ `4dc631d`, 2×2325 tests @ `340489a`) each produced exactly ONE failure — the known `TriggersTest` flake above. The other two listed intermittents (`NodeLive.IndexTest`, `PiStubIntegrationTest`) did not occur in any of the four. Four runs isn't proof they're fixed — keep running the baseline yourself per the advice above, don't drop them from the list on this evidence alone.

## Architecture

- **SessionRunner** (`lib/orca_hub/session_runner.ex`): GenStatem that manages an agent-CLI session via a port. Sends prompts, parses streaming JSON output, persists messages, and broadcasts events via PubSub. Delegates every CLI-specific concern (spawn args, stdin framing, event normalization) to `data.backend`.
- **OrcaHub.Backend** (`lib/orca_hub/backend.ex`, `backend/claude.ex`, `backend/codex.ex`): behaviour + adapters for pluggable agent CLIs (Claude, Codex — see `backend_abstraction_spec.md`). Each session persists its backend in the `sessions.backend` column, resolved once at runner init. Non-Claude backends normalize their native output into Claude's `stream-json` event shape so persistence/rendering stay backend-agnostic. A `Capabilities` struct per backend (`usage`, `mcp`, `plan_mode`, `ask_user_question`, …) gates UI chrome and model lists — the UI branches on capability fields, never on the backend name string. Codex auth is env-based (`OPENAI_API_KEY`, or a prior `codex login`) rather than the node-login flow Claude uses.
- **SessionLive.Show** (`lib/orca_hub_web/live/session_live/show.ex`): LiveView for viewing/interacting with a session. Handles message sending, image uploads, file uploads, and capability-gated chrome (usage panel, plan mode, AskUserQuestion, MCP toggles, model picker) via `Backend.capabilities_for/1`.
- **MessageComponents** (`lib/orca_hub_web/components/message_components.ex`): Function components for rendering the message feed (user, assistant, tool use, results, system events). Backend-agnostic — every backend normalizes onto Claude's existing tool names (Bash/Write/Edit/mcp__*/WebSearch/TodoWrite), so no per-backend rendering code exists.
- **OrcaHub.Claude** (`lib/orca_hub/claude/`): Modules for interacting with Claude CLI — builds CLI args (`Config`), parses streaming NDJSON output (`StreamParser`), and fetches usage metrics (`Usage`).

## Common issues

- Timestamp field types vary per column (`:naive_datetime` vs `:utc_datetime` — check the schema, don't assume); convert `NaiveDateTime` with `DateTime.from_naive!(x, "Etc/UTC")` before `DateTime` arithmetic, and pattern-match both when a field's provenance is mixed
- Never sort/compare `%NaiveDateTime{}`/`%DateTime{}` structs with a bare `Enum.sort_by/2`, `Enum.sort/1`, `Enum.min_by/2`, `Enum.max_by/2`, `<`/`<=`/`>`/`>=`, etc. — Erlang's default term ordering compares struct fields ALPHABETICALLY (`microsecond` sorts before `minute`/`month`/`second`/`year`), not chronologically, so it silently scrambles any two timestamps sharing an `hour`. Always pass an explicit comparator: `Enum.sort_by(list, & &1.updated_at, {:desc, NaiveDateTime})` / `{:asc, DateTime}`, or `NaiveDateTime.compare/2` in a custom sorter fn. This caused the 2026-08-08 windowed-feed out-of-order/dropped-reply incident (`Sessions.list_messages_window/2`) — search for this bug class with `grep -rnE "Enum\.(sort_by|sort|min_by|max_by|min|max)\(" lib/` and inspect every hit touching a timestamp field.

## Key patterns

- Messages are stored as flexible maps in a `data` column (no fixed schema for message content)
- File uploads save to the session's working directory so Claude can access them via its Read tool
- Document uploads are saved to the session's working directory for Claude to access
- Index tables use `row_click` with `JS.navigate` to make rows clickable to the show page (no separate View/Edit action links). See projects and issues index pages for examples.
- Sessions are grouped by directory in the index view, sorted by most recently updated
- Session titles are agent-managed, not LLM-generated: orchestrators pass `title` to `start_session`, workers self-title via `report_progress`'s `title` arg (persists across turns, unlike `phase`/`note`). If neither ever sets one, `SessionRunner` falls back to a dumb truncation of the first prompt's first line at turn end.
- Archiving a session (`archive_session`, default `extract_memories: true`) auto-dispatches `OrcaHub.MemoryExtraction` for orchestrators and root/human-driven sessions (child workers are skipped by default — override per-session with `memory_extract`, or force it on demand with the orchestrator-only `extract_memories` tool). A cheap background session reviews new transcript since the last extraction and calls `remember`/`update_memory`, then posts a summary into the source session's feed. Pass `extract_memories: false` to archive without triggering it.
- Which memories were loaded into a session is visible, not just injected silently: every `<orca-memory>` prepend (Claude/Codex first turn) or `ORCA_MEMORY` env build (pi, at port-open) persists a `memory_injected` system event (`Sessions.persist_system_event/2`) with `memory_ids`/hooks/pinned+recalled counts/the raw block. It renders collapsed in the feed and aggregates into a header "Memories" panel (`Sessions.list_memory_injected_events/1`); the leading block is stripped from the user bubble's display text since the event already shows it. Hooks link to `MEMORY_SERVICE_PUBLIC_URL/memories/<id>` when that env var is configured.
- Two hub-scheduled triggers (`OrcaHub.MemoryReview`, upserted idempotently on boot by `TriggerLoader`) run automated memory REVIEW passes — nightly consolidation (`memory-consolidate-nightly`, merges clear near-duplicates and flags importance inflation/contradictions) and weekly verification (`memory-verify-weekly`, checks concrete claims via grep/git/curl and batch-verifies or flags). Both propose only: `merge_memories`/`flag_memory`/`verify_memories`, never `retire_memory` or a text rewrite of an existing memory — humans still decide. Both triggers set `memory_extract: false` so the passes never memory-extract themselves.

## Deployment

There are SIX prod instances; a full deploy updates all of them:

1. **k3s deployments `orca-hub`, `orca-agent-discord`, `orca-agent-dell`** (namespace
   `lab`) — share one Docker image from `registry.lab.ingbretsenhome.com`, built as a
   real multi-arch (`linux/amd64,linux/arm64`) manifest list even though nothing
   schedules an arm64 pod today.
2. **`mini`** — a standalone host (same physical k3s cluster node, but runs its own
   OTP release + systemd unit outside k3s).
3. **`gb10`** (`192.168.1.77`, the aarch64 GB10 box) — also a standalone agent, same
   `/home/zach/orca-hub-releases/<sha>/` + `current` symlink convention as `mini` and
   local, but needs a NATIVE aarch64 OTP release rather than the amd64 one.
4. **Local systemd service `orca-hub`** — runs an OTP release installed under
   `/home/zach/orca-hub-releases/<sha>/` (symlink-flipped into place), NOT a
   `_build/prod/rel/orca_hub` local `mix release` build.

### Canonical deploy: `~/homelab/scripts/deploy-orca-hub.sh`

The canonical deploy script is a LOCAL/PRIVATE script that lives in the homelab
repo at `~/homelab/scripts/deploy-orca-hub.sh` — it is intentionally NOT checked
into this repo (`scripts/deploy.sh` is gitignored here as a guard against
accidental re-add). **Read the script itself before trusting a summary of it —
this section has been wrong before, more than once — and re-check it before
briefing a deploy worker rather than reusing a stale mental model.**

It builds from this checkout (`ORCA_REPO`, default `/home/zach/orca_hub`) with a
**NATIVE multi-arch build, every deploy**: a persistent two-node `docker buildx`
builder named `orca` — this host builds `linux/amd64` on its own node, `gb10`
builds `linux/arm64` natively on its own node over an ssh docker context, no QEMU.
The builder is created once and reused forever (recreating it would destroy each
node's BuildKit cache); each node's cache stays warm independently across deploys,
with no cross-arch cache for one arch to poison the other. Exactly TWO
`docker buildx build` invocations against that one builder per deploy:

1. the runtime image, `--platform linux/amd64,linux/arm64 --push`, assembling ONE
   multi-arch manifest list (SHA-tagged + `:latest`) for k3s;
2. the same compiled release, `--target artifact --platform linux/amd64,linux/arm64
   --output type=local`, a multi-platform local export that writes PER-PLATFORM
   subdirectories (`linux_amd64/`, `linux_arm64/`) rather than one flat release
   dir — consumed by local + `mini` (amd64) and `gb10` (arm64).

Each extracted artifact gets a hard `file`-based architecture assertion before
anything is installed — added after two real cache-poisoning incidents on the old
single-shared-cache builder (2026-07-31: an amd64 build silently served as arm64;
2026-08-02: the reverse, an arm64-poisoned amd64 image shipped to every instance
that existed then). The native per-arch nodes make that failure mode structurally
impossible now, but the assertions stay as a cheap belt-and-suspenders check.

Before any of the seven steps below run, three guards abort the whole deploy on
failure: the checkout-dirty guard (`git status --porcelain`, `--allow-dirty` to
skip); a `gb10`-reachable + buildx-arm64-platform-support guard (`--skip-arm64` to
skip and build amd64-only instead); and a systemd bootstrap guard confirming
local/`mini`/`gb10` (whichever aren't skipped) all `ExecStart` from
`orca-hub-releases/current`, and that `mini`/`gb10` both carry the NOPASSWD
sudoers rule needed to restart non-interactively over ssh — `gb10` needed a
one-time bootstrap for that rule (the same scope `mini` already had); the guard
prints the exact setup command if it's missing rather than hanging or failing
deep inside a later step.

In order (seven steps):

1. `git push` the deployed commit to origin.
2. The two `buildx` builds above, plus the architecture assertions.
3. Prune stale local image tags + cap both builders' BuildKit caches; commit the
   new image tag into this repo's k3s manifests and push — **Flux (GitOps) notices
   the commit and rolls all three k3s deployments itself.** This script never runs
   `kubectl rollout restart`, and a direct `kubectl edit` against a Flux-managed
   resource gets silently reverted within ~5 minutes (see the `homelab-flux-gitops`
   skill). Polls each k3s instance's `/api/version` to confirm the rollout landed.
4. Install per-host env files (local + `mini`; `gb10` manages its own `.env`
   separately, out of scope here) — the ONE step besides the dirty-checkout guard
   that ABORTS the whole deploy on failure, since starting a service against a
   stale/missing env is worse than a hard stop.
5. Install the artifact on `mini` over ssh, restart its systemd service. A failure
   here is a WARNING, not an abort — a remote, lower-stakes target.
6. Install the arm64 artifact on `gb10` over ssh, restart its systemd service. Same
   WARNING-not-abort philosophy as `mini`. (Different from an arm64 BUILD failure
   in step 2 above, which always aborts the whole deploy — silently shipping
   amd64-only bits under a SHA tag that claims multi-arch is worse than refusing.)
7. Install the artifact locally, restart `orca-hub` — **runs LAST**, since a deploy
   driven from inside the local `orca-hub` process kills the script's own process
   tree the moment this restart fires. The script now performs the `no_new_privs`
   ssh escape (see below) itself for this step, so a worker driving the script by
   hand doesn't need to route around it manually.

Flags: `--skip-push`, `--skip-build`, `--skip-local`, `--skip-k3s`, `--skip-env`,
`--skip-mini`, `--skip-gb10`, `--skip-arm64`, `--allow-dirty`, `-h`/`--help`.
**The old opt-in `--arm64` flag is GONE — passing it is now a fatal "Unknown flag"
error.** arm64/`gb10` are ON by default: `--skip-arm64` builds `linux/amd64` only
(no arm64 artifact at all, no `gb10` install, single-platform image), while
`--skip-gb10` still builds the arm64 artifact but skips installing it on `gb10`
specifically. There is still no `--skip-release` flag (no separate release-build
step exists to skip). Run `~/homelab/scripts/deploy-orca-hub.sh --help` for the
full current text — it's generated straight from the script's own header comment,
so it can't drift from the flags above the way this doc can.

Because the local systemd restart can kill the deploying session before it can
verify itself, `~/homelab/scripts/verify-orca-deploy.sh [sha]` is the companion
script to run afterward (by hand, or from another session) — it polls
`GET /api/version` on all SIX instances — local systemd, `mini`, `gb10`, and all
three k3s instances — and confirms each reports the target SHA, treating a
missed/mismatched `gb10` as a hard failure (exit 1) exactly like every other
instance (no skip flag), so a clean "all instances confirmed" now genuinely
does cover `gb10` too. It also
**lives in the homelab repo, not this one** — a worker told to "verify the
deploy" who only searches this repo won't find it and may hand-roll a worse check
instead. Per-instance endpoints it polls: local systemd, `mini`, and `gb10` all
on port `4001` (`mini`/`gb10` polled over ssh, since they're LAN hosts); the
k3s hub pod via the Authelia-fronted ingress
(`https://orca.lab.ingbretsenhome.com/api/version`, since it runs on the pod
network with no LAN host IP); the k3s `orca-agent-discord`/`orca-agent-dell`
pods (no Service/Ingress) via `kubectl exec` + curl against their own
pod-local ports `4010`/`4020`.

**Passwordless sudo requirement:** the deploy script's mini/gb10/local restart
steps all run `sudo systemctl restart orca-hub` over a non-interactive session.
To avoid a password prompt, each host needs the sudoers drop-in at
`/etc/sudoers.d/orca-hub` (root:root, mode 0440) — a reference copy lives at
`scripts/orca-hub.sudoers` with install instructions in its header. It grants
`zach` NOPASSWD for `start`/`stop`/`status`/`restart` of the `orca-hub` unit
ONLY — **it does NOT cover `systemctl is-active`**, which still prompts for a
password; hitting that can look exactly like the ssh escape below is broken when
it's really just an uncovered subcommand (a worker hit this and misdiagnosed it
on 2026-08-14). Validate after installing with `sudo visudo -cf
/etc/sudoers.d/orca-hub`. **The drop-in alone is not sufficient from an agent
session running inside the orca-hub release itself** — that process tree runs
with `no_new_privs`, which blocks `sudo` even with a valid NOPASSWD entry. The
confirmed-working escape is routing through sshd instead: `ssh localhost 'sudo
-n systemctl restart orca-hub'` — the deploy script itself now does exactly this
for its own local-restart step (step 7 above), so this mainly matters if you're
restarting the service by hand from inside a session rather than via the script.
`mini` and `gb10` need the identical NOPASSWD scope (same drop-in content) so the
deploy script can restart them non-interactively over ssh too.

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

### Routine dependency upgrades

There are TWO entry points, and running only the first is how CVEs get missed:

1. **`mix hex.outdated`** — version drift, DIRECT deps only. Its **"Update not
   possible"** status does NOT mean incompatible — it means the version is
   outside the requirement in `mix.exs`, so it needs a requirement bump to even
   be considered. Run `mix hex.outdated <dep>` to see the requirement AND which
   packages constrain it; that table is how you find the real blocker in a chain.
2. **`mix hex.audit`** — retired packages and security advisories, across the
   WHOLE tree including transitive deps. **Run this every time.**

`hex.outdated` says nothing about vulnerabilities and never lists a transitive
dep, so a stale transitive pin can sit on a known CVE forever while the report
reads "all up to date" — which is exactly what happened on 2026-09-11: the
outdated report was clean apart from three trivial patches, while `hex.audit`
showed two HIGH advisories (mint 1.9.3 memory/CPU-exhaustion DoS, cowlib 2.17.1
HPACK/QPACK DoS). Neither is a direct dep; both were fixed just by
`mix deps.update mint cowlib gun`, since nothing had ever forced them forward.
`mix deps.get` prints the same warnings as a side effect, so a "Found packages
with security advisories" line in ordinary output is never noise — stop and read
it.

**Where the changelogs live.** Check `mix hex.info <dep>` FIRST — it often prints
a `Changelog:` link already pinned to the release tag (dotenvy does), which beats
guessing a raw path. Otherwise nearly every Elixir dep keeps a `CHANGELOG.md` at
its repo root, and `raw.githubusercontent.com/<org>/<repo>/<main|master>/CHANGELOG.md`
is the fastest way to read it. Repo URL also comes from `mix hex.info <dep>`.
Confirmed paths for this project's deps:

| Dep | Changelog |
|---|---|
| phoenix | **use the `v1.8` branch, not `main`** — `github.com/phoenixframework/phoenix/blob/v1.8/CHANGELOG.md`. `main`'s CHANGELOG covers only the next minor and just points at the release branch, so 1.8.x patch entries are invisible there. |
| phoenix_live_view | `phoenix-live-view.hexdocs.pm/<version>/changelog.html` (hexdocs 301-redirects to this host) |
| phoenix_live_dashboard / phoenix_live_reload / tailwind / esbuild | `github.com/phoenixframework/<dep>` /CHANGELOG.md |
| ecto, ecto_sql | `github.com/elixir-ecto/<dep>` /CHANGELOG.md (ecto is `master`, not `main`) |
| bandit | `github.com/mtrudel/bandit` /CHANGELOG.md |
| req | `github.com/wojtekmach/req` /CHANGELOG.md |
| swoosh | `github.com/swoosh/swoosh` /CHANGELOG.md |
| ex_json_schema | **no changelog** — diff tags instead: `gh api repos/jonasschmidt/ex_json_schema/compare/v<old>...v<new> --jq '.commits[].commit.message'` |
| dns_cluster | `github.com/phoenixframework/dns_cluster` /CHANGELOG.md, but **it lags** — the file stopped at 0.2.0 while 0.3.0 was published. Use the tag diff. |
| telemetry_metrics, phoenix_pubsub | `github.com/beam-telemetry/telemetry_metrics`, `github.com/phoenixframework/phoenix_pubsub` /CHANGELOG.md |
| mint | `github.com/elixir-mint/mint` /CHANGELOG.md |
| dotenvy | `mix hex.info dotenvy` prints a tag-pinned `Changelog:` link |
| dialyxir | GitHub **Releases**, not a changelog file — and its 1.x tags have NO `v` prefix (`1.4.8`, not `v1.4.8`), so `compare/v1.4.7...v1.4.8` 404s |

That `gh api .../compare/v<old>...v<new>` trick is the general fallback for any
dep with no changelog and no GitHub Releases. Reach for it whenever a changelog
lookup comes back EMPTY rather than concluding "no notable changes" — an absent
entry usually means the changelog lags the release, not that the release was
trivial. Two confirmed cases: `req` (main's CHANGELOG was on 0.8.0-rc and had no
0.7.4 entry, which turned out to be three `put_params` fixes) and `dns_cluster`
(no 0.3.0 entry at all). The same trap in a different shape is `phoenix`, whose
`main` changelog silently omits every 1.8.x patch — see the table above.

**Gotchas learned the hard way (2026-08-14 run):**

- **`mix deps.update <dep>` cascades.** It re-resolves transitive deps too and
  will opportunistically pull unrelated packages forward — updating `swoosh`
  silently dragged `req` 0.5→0.7 along. Always read the `Upgraded:` block it
  prints. To hold something back while you update its neighbours, temporarily
  tighten its `mix.exs` requirement (e.g. `~> 0.5` -> `~> 0.5.17`), re-resolve,
  then restore the requirement — the lock keeps the pinned version.
- **One capped dep can freeze a whole chain.** `ex_json_schema` 0.10.2 required
  `decimal ~> 2.0`, which capped `decimal`, which blocked `ecto` 3.14 (wants
  `decimal ~> 3.0`), which blocked `ecto_sql` 3.14. Nothing in `hex.outdated`
  points at the culprit — `mix hex.outdated decimal` did, via its constraint
  table. When a dep "should" be updatable but resolution refuses, walk that table.
- **Other agents share this worktree, `_build`, and the git index.** Commit
  dependency files by explicit path (`git commit -o mix.exs mix.lock -m ...`) so
  you never sweep a sibling's staged work into your commit, and expect a
  `Waiting for lock on the build directory` pause. A `mix.lock` change forces a
  full dep recompile for everyone — tell active sessions (`.agents/`, or
  `search_sessions` by directory) before you land one.
- **Attribute failures carefully.** Establish a full-suite baseline BEFORE
  upgrading. A sibling editing a test file mid-run produced a failure that looked
  like the upgrade's fault; re-running that file alone cleared it.

**An upgrade isn't done until a clean PROD resolution succeeds.** A green
`mix test` proves nothing here: it runs against the already-populated dev
`deps/` and never re-resolves, so a lock that can't actually resolve still
passes locally and then fails the docker build at `mix deps.get --only prod`.
Prove it from a pristine tree with its own empty `deps/`/`_build/`:

```
rm -rf /tmp/prod-proof && mkdir -p /tmp/prod-proof
git archive HEAD | tar -x -C /tmp/prod-proof
cd /tmp/prod-proof && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile
```

`git archive` (not a copy) keeps the shared worktree's `deps/` untouched, so
this can't disturb sibling sessions. If that passes but the build still fails,
the lock is fine and the culprit is the Dockerfile's `--mount=type=cache`
`deps/` — the tell is an "Unchecked dependencies" version that appears nowhere
in `mix.lock` (it's the previous deploy's pin, carried over). Fix that on the
buildx node, not in the lockfile.

**A dep's version jump is not the same as YOUR exposure — check whether it's
even live.** `dns_cluster` 0.2 -> 0.3 looked like a 0.x breaking-position bump,
but `DNS_CLUSTER_QUERY` is set NOWHERE (not the k3s manifest, not the systemd
unit, not `.env`), so `Application.get_env(:orca_hub, :dns_cluster_query) ||
:ignore` makes DNSCluster `:ignore` on all six instances — compiled in, never
started. Clustering is really libcluster (`CLUSTER_NODES`/`CLUSTER_DNS_QUERY`)
plus `NodeDialer`. The flip side: when a dep is inert in dev AND prod, neither
the suite nor the boot smoke covers it, so verify the changed path directly —
here, starting a `DNSCluster` by hand with a live query and a short `:interval`
and confirming it survives several poll ticks.

**Verifying the app actually boots.** The test suite uses `ConnTest`/
`LiveViewTest`, which bypass the HTTP adapter entirely — so it does NOT cover
bandit / thousand_island / websock_adapter / plug. After upgrading any of those,
smoke-test the real socket. `config/dev.exs` clobbers shell env from `.env`
(see the mix-task env note), so override in-process rather than editing `.env`:

```
mix run --no-start --eval '
  Application.put_env(:orca_hub, :mode, :hub)   # OrcaHub.Mode reads app env, not ORCA_MODE, at runtime
  ep = Application.get_env(:orca_hub, OrcaHubWeb.Endpoint)
  Application.put_env(:orca_hub, OrcaHubWeb.Endpoint,
    Keyword.merge(ep, http: [ip: {127,0,0,1}, port: 4099], server: true,
                  watchers: [], code_reloader: false))   # watchers: [] or esbuild/tailwind --watch hangs
  {:ok, _} = Application.ensure_all_started(:orca_hub)
  Process.sleep(4000)
  {:ok, r} = Req.get("http://127.0.0.1:4099/api/version", retry: false)
  IO.inspect({r.status, r.body})'
```

Use a port other than 4001 — the local systemd agent holds that. For the
WebSocket path, open a raw `:gen_tcp` connection to `/live/websocket?vsn=2.0.0`
with the `Upgrade: websocket` / `Sec-WebSocket-Key` headers and assert
`101 Switching Protocols`.

**OPEN SECURITY ITEM — earmark is retired and unfixable (found 2026-09-11).**
`mix hex.audit` flags `earmark` 1.4.49 as RETIRED ("no longer maintained,
migrate to MDEx") and VULNERABLE — EEF-CVE-2026-48591, stored XSS via
unescaped HTML attribute values in `Earmark.Transform`. There is no fixed
version and there never will be; upgrading cannot resolve it.

Verified exploitable against our real render path
(`OrcaHubWeb.Markdown.render/2`, which ends in `Earmark.transform/1` +
`Phoenix.HTML.raw/1`): the markdown `[click](https://example.com "x" onerror=
"alert(1)")` renders as `<a ... title="x" onerror="alert(1)">`.

**The bigger finding sitting underneath it:** earmark also passes RAW HTML
through by default, so `<script>alert(1)</script>` in any rendered markdown
reaches the page verbatim. That is independent of the CVE and strictly worse
than it. There is no HTML sanitizer anywhere in the tree. The message feed
(`message_components.ex`, `session_live/show.html.heex`) renders assistant
text and tool results this way into the MAIN document — not the sandboxed
artifact iframe — so any content we display is script-injection capable:
LLM output, WebFetch results, Discord messages, and inbound email bodies.
Authelia does not help; the attacker is the content, the victim is the
authenticated viewer. (The artifact export path in `artifacts/render.ex`
also uses this renderer, but lands inside the `sandbox="allow-scripts"`
iframe, which is a deliberate, already-accepted boundary.)

**Do not treat "migrate to MDEx" as an obvious win.** Hex's own retirement
notice recommends it, but `mix hex.audit` rates mdex 0.11.6 WORSE than the
thing it replaces: six advisories including a HIGH (EEF-CVE-2026-53426,
atom-table exhaustion DoS via JSON `parse_document`), plus unbounded native
memory leak, uncontrolled recursion crashing the BEAM on deeply nested
markdown, and its own XSS via an unescaped code-fence attribute. We know
this because a stale mdex lock entry was sitting in mix.lock unused and
showed up in the audit (removed in 3ae1a40). If MDEx is chosen anyway, pin
a version whose advisories have been checked, and note it brings a Rust NIF
(rustler_precompiled) into a currently pure-Elixir build.

Raised with the user 2026-09-11. NOT fixed unilaterally: every remedy —
swapping the engine, or escaping/sanitizing before `raw/1` — changes what
agent output is allowed to render, which is a product decision rather than a
dependency bump. Do not silently "upgrade past" this item on a future run;
there is nothing to upgrade to.

**Still deferred, re-checked 2026-09-11: phoenix_live_view 1.1 -> 1.2**
(1.1.33 vs 1.2.11, unchanged for three weeks; raised with the user
2026-08-14, 2026-08-21 and 2026-08-28, still not decided — do not keep
re-deriving the analysis below, just re-raise it). Everything else is current. 1.2 needs `mix.exs`
`~> 1.1.0` -> `~> 1.2` and carries real breaking changes: the
`Phoenix.Component` global-attribute list was realigned to MDN and the removed
attributes are NOT enumerated in the changelog (fix per-site with
`attr :rest, :global, include: ~w(...)`); `:colocated_js` config is deprecated in
favour of `:colocated_assets` (we consume colocated hooks via
`phoenix-colocated/orca_hub` in `assets/js/app.js`); and `:test_warnings` now
warns by default for `phx-change` forms without an `id` (~49 such sites here).
Staying on the latest 1.1.x is a supported position — don't take 1.2 as part of a
routine patch sweep. It wants its own change: bump, audit every `:global` site,
then verify the main pages in a browser, since the risky failure mode (a silently
dropped global attribute) is invisible to the test suite.
