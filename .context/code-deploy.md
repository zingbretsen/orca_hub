# Code deploy: the two paths

OrcaHub ships code two ways. Both are real, they are not alternatives to
each other, and picking the wrong one is the failure mode this subsystem
exists to prevent.

| | Full release deploy | Hot code generation |
|---|---|---|
| Driver | `~/homelab/scripts/deploy-orca-hub.sh` | `OrcaHub.Cluster.CodePush` |
| Unit | multi-arch image + OTP releases | compiled `:orca_hub` beams |
| Cost | multi-minute build, restarts all six instances, kills in-flight sessions | seconds, disturbs nothing |
| Covers | everything | module code only |

**The slow path is the ONLY path** for dependency changes (`mix.lock`,
`mix.exs`), compile-time/app config, migrations, supervision-tree changes,
frontend assets, release plumbing, anything `HotLoadGate` refuses, and the
deploy machinery itself. It is also how the hot-deploy machinery reaches a
node in the first place. The fast path replaces a module's code and nothing
else; everything above reaches *beyond* module code.

Source of truth is the moduledocs — they carry the reasoning, this file is
the map:

- `lib/orca_hub/cluster/code_sync.ex` — beam-level primitives
- `lib/orca_hub/cluster/code_push.ex` — the reconciliation loop (hub-only GenServer)
- `lib/orca_hub/cluster/beam_transport.ex` — CodePush's view of CodeSync
- `lib/orca_hub/cluster/hot_load_gate.ex` — the refuse-if-unsure diff classifier
- `lib/orca_hub/cluster/code_stamp.ex` — what a node is ACTUALLY running
- `lib/orca_hub/cluster/fleet_status.ex` — the drift view
- `lib/orca_hub/code_generations.ex` (+ `code_generations/`) — persistence
- `lib/orca_hub/code_generations/provenance.ex` — who published a row, and
  whether an applying node trusts it

## Topology: the hub is the only fan-out origin

The cluster is a STAR (`-kernel connect_all false`): the hub sees every
agent, each agent sees only the hub. `Node.list/0` on an agent is the hub,
not the fleet, so an agent *cannot* fan out even if it tried. A publish
therefore has two halves: the node that owns a checkout collects the payload
locally (`CodePush.collect_payload/1`) and hands it to the hub; the hub
publishes it and pushes.

## Generations, not pushes

The hub holds a durable **desired code generation** (`code_generations` +
`code_generation_modules`, per-module rows so a reconcile moves only what
differs rather than ~7.6 MiB per node). Every node is reconciled *toward*
it. That reframing is the design: a node that was powered off for a week, a
laptop that is only sometimes on, a pod that just restarted — all converge
without anyone running anything.

Reconcile triggers:

- **hub boot** — the hub comes up on its IMAGE's code, reads the stored
  generation and applies it to ITSELF before touching any agent. This is
  what makes the image a floor rather than the truth.
- **`nodeup`** — `:net_kernel.monitor_nodes/2`, after a settle delay
  (distribution comes up well before the remote `:orca_hub` app has started).
- **on demand** — `reconcile_all/0` / `reconcile_node/1`.

A single GenServer on the hub is the only thing that publishes or applies,
which makes two concurrent hot deploys impossible BY CONSTRUCTION. **Do not
add a lock** — if one feels necessary, serialization has leaked out of that
process and belongs back inside it.

A reconcile must never DOWNGRADE a node: the slow path still ships real
images, so the fleet can legitimately be newer than the stored generation.
Nodes report `BuildInfo.built_at/0` (truthful across hot loads precisely
because `BuildInfo` is excluded from every payload); a node whose image is
newer is skipped, and if the HUB's image is newer the whole reconcile is
abandoned and the generation reported `:stale`. Superseding it is an
explicit operator action (`supersede/1`), never inferred.

## Publish provenance: the row itself has to be trusted

The ERTS/compile-provenance checks below prove the BEAMS are what they claim.
A separate question is whether the generation ROW should be acted on at all,
and nothing in the beams answers it.

The local systemd production instance and `bin/test` read the SAME database
here (`DB_NAME=orca_hub_dev`). `mix test` publishes generations for real —
`code_push_test.exs` legitimately exercises the publish path with SYNTHETIC
modules compiled in-test — and those rows normally die with the Ecto sandbox
transaction. Rows have been observed escaping it (a GenServer tick landing in
an `async: false` test's shared-sandbox window). `:code_reconcile_enabled`
false keeps the TEST node inert; it says nothing about what a production hub
does with a row the suite left behind, and those beams are fabricated.

So `CodeGenerations.publish/2` stamps every row with
`Provenance.current/0` — `"<format>:<runtime>:<compile env>"`, e.g.
`"1:release:prod"` or `"1:mix:test"`. The env half is captured at COMPILE
time (`@compile_env Mix.env()`), so code compiled by `mix test` says `test`
and cannot say anything else; the field is set on the STRUCT and never cast,
so no attrs map can claim a provenance the publishing code does not have.

Trust is an ALLOWLIST (`prod`, `dev`) and it FAILS CLOSED: a `nil` marker —
every row predating the column — and any marker this version cannot parse are
refusals, not grandfathered passes. `dev` is trusted and `test` is not
because a dev publish is someone typing `publish_code_generation`, while a
test publish is an automatic side effect of running the suite.

Enforced at exactly two points, which between them cover every apply path:
`breaker_decision/1` (boot — refuses BEFORE spending apply budget, and
QUARANTINEs, so `current/0` stops reporting a target nothing will load) and
`reconcile_one/3` (the single funnel for boot fan-out, `nodeup`, on-demand
reconciles and post-publish fan-out — reports `:refused` per node).
`purge_orphaned/1` refuses too, for a sharper reason: "orphaned" means
"absent from the generation", so purging against a test generation would
unload every real module on the node. Refusals log at ERROR and show up in
`code_generation_status` and the fleet basis label.

The test bypass is `config :orca_hub, :trust_test_code_generations, true` in
`config/test.exs` ONLY. It is read by whoever is APPLYING, so it cannot
travel with the row — production never sets it.

## Circuit breaker

The sharpest risk: a bad generation that crashes the hub on boot produces a
CrashLoopBackOff whose remedy lives inside the thing that will not stay up.
Two independent escapes:

1. **`ORCA_SKIP_CODE_RECONCILE=1`** — boots on pure image code, applies
   nothing, ever. An environment variable and not a DB flag on purpose: a DB
   flag would live behind the database a crashing hub may not reach.
2. **The apply budget**, needing no operator at all. A generation is
   `pending` until the hub has applied it AND stayed alive for the health
   window, then `healthy`. `apply_attempts` is incremented and COMMITTED
   *before* the beams are applied — a counter that only advanced on success
   would record zero attempts in exactly the scenario it exists for. Each
   boot spends one unit of a small budget; a generation that crashes the hub
   exhausts it within a couple of restarts and `quarantine`s itself, after
   which the hub boots clean. Marking healthy resets the counter rather than
   latching, because a generation healthy on one image need not be healthy
   on the next.

The budget errs toward giving up: two unrelated crashes inside the health
window quarantine a good generation. Cost of being wrong that way is one
slow deploy; the other way is a hub that cannot boot.

## What the beams have to prove

**ERTS gate.** OTP guarantees bytecode from an OLDER compiler runs on a
NEWER runtime, not the reverse. `CodeSync.compatible?/1` requires exact
equality of `:erlang.system_info(:version)`, here vs target. At RECONCILE
time that is the wrong pair — the beams come from a stored generation
compiled on a machine that may be long gone, on a toolchain the hub itself
may no longer run. So `CodePush` compares the GENERATION's recorded ERTS
against the target and then passes `allow_erts_mismatch: true`. The two go
together; skipping the local check without the generation check is a real
hole.

**Compile provenance.** A payload is only ever the output of a compile this
code performed or verified. `collect_payload/1` runs `MIX_ENV=prod mix
compile` in the checkout rather than trusting `_build/prod`, because Mix's
manifest tracks the OTP RELEASE (`"27"`), not the full ERTS version — a host
drifting between two 27.x patches keeps the same release, so `mix compile`
does nothing and the tree stays a mix of two toolchains while looking freshly
built. Nothing else can see that: `compatible?/1` compares live runtimes, and
a `.beam` carries no ERTS stamp. What it DOES carry is its `compile_info`
chunk, so every beam must name the same Erlang compiler, and that compiler
must be the publishing runtime's; a mismatch escalates ONCE to
`mix compile --force` automatically (the day this matters is the day nobody
knows to pass a flag) and refuses if still heterogeneous.

**`compile_info`'s `:version` is the COMPILER application's version, not
ERTS.** Two OTP patch releases can ship the same compiler, so the check can
pass on a genuinely mixed tree. It is a VERIFIER, not a proof — the real
guarantee is the compile; this catches the case where the compile silently
did nothing. The surviving version is recorded on the generation as
`compiler_version`.

**Dirty checkouts** are refused unless `allow_dirty`, which records
`dirty: true` on the generation forever. Untracked files count.

## `soft_purge` refusal and the two-version limit

The BEAM keeps at most TWO versions of a module (current + old). Loading a
third kills every process still on the oldest. `:code.soft_purge/1` returns
`false` and does NOTHING when processes still run the old code, so a `false`
REFUSES that module and reports it `wedged`. `:code.purge/1` — which kills
those processes — is never called, not even as a fallback. A wedged module
does not stop the rest of the payload.

Modules that are never pushed, or pushed last:

- `OrcaHub.BuildInfo` — excluded from every payload. Its `@sha`/`@built_at`
  are baked from the COMPILING machine's git state; pushing it would make
  `/api/version` report the compiler's HEAD, breaking the one signal the
  deploy script verifies with — and would let a generation forge the evidence
  used to decide whether to apply it.
- `CodeSync` / `CodePush` are sunk to the END of every payload
  (`BeamTransport.sanitize/1`): swapping the pusher's own code mid-iteration
  is how you get half a push under one version and half under another.

Differencing uses the module's COMPILE-TIME md5
(`:erlang.get_module_info(mod, :md5)` / `:beam_lib.md5/1`), NOT `:erlang.md5`
over the file bytes — the latter hashes the container (debug info, docs,
padding) and differs for identical code, reporting everything as drifted.

## The gate: refuse if unsure

`HotLoadGate.classify/2` is PURE — it takes a change list (path, optional
unified diff, status) and returns `{:ok, :hot_loadable}` / `{:refuse, reasons}`
/ `{:forced, reasons}`. A forced verdict still carries every reason, and a
forced publish records them on the generation; neither override is silent.

The default is ALLOW, deliberately: for the bulk of this codebase — a changed
function body, a new function, a `.heex` template, a whole new module —
replacing the code IS the entire change. The refuse list enumerates the
specific ways a change reaches beyond module code. Categories, in report
order: `dependency_change` (`mix.lock`), `build_config` (`mix.exs`),
`app_config` (`config/*.exs`), `migration` (`priv/repo/migrations/`),
`frontend_asset` (`assets/`, `priv/static/`), `supervision_tree`,
`defstruct_change`, `build_info`, `release_plumbing`, `missing_diff`.

`missing_diff` matters: an `.ex`/`.exs` change arriving without diff text is
REFUSED rather than waved through, because categories 6 and 7 need the diff
body. `require_diff: false` downgrades that and disables those two checks.

### The `defstruct` trap (category 7)

The subtle one, and the main reason the gate is worth having. Hot loading
swaps a module's CODE; it does not touch the TERMS already held by running
processes. A GenServer holding `%State{a: 1}` keeps exactly that map across
the load. If the new code adds field `b`, the next message hits a
`Map.fetch!`/pattern match/`%{state | b: ...}` against a shape that is not
there and the process crashes.

The supervisor then restarts it with a correctly-shaped fresh state, so the
system "heals" — which is exactly what makes this dangerous. The fleet looks
fine. What is gone is whatever that process held: a mid-turn session's runner
state, a warm port, a pending queue. Invisible to any health check you would
think to run. So any added, removed or modified `defstruct` line refuses.

The correct way to ship a struct change to a running node is an OTP release
upgrade with `code_change/3` — which is precisely what pushing bare beams is
not.

## Reporting: drift, stamps, and the two shas

`CodeSync.drift/3` returns three categories against a payload: `missing`
(the node has not loaded it), `drifted` (running md5 differs), `identical`.
A reconcile adds a fourth, `orphaned` — modules a node still carries that the
generation does not contain. Hot loading cannot un-load anything, so a module
deleted from source stays resident and callable forever. Refusing the hot
path on deletions was considered and rejected (refactors delete modules
constantly); removal is an explicit, destructive operator action,
`purge_orphaned/1`, which never kills a process to do it. `BuildInfo` is
excluded from the orphan set since it is in no generation by design.

`missing` is three answers, not one. The md5 probe raises both for a module
the node never heard of and for one merely not loaded yet, so
`FleetStatus` re-probes with `:code.which/1` (`CodeSync.code_locations/3`)
and lands each in exactly one of `absent` (`:non_existing` there),
`not_loaded` (in the code path, not loaded), or `unknown` (the probe could
not say — including `:preloaded`/`:cover_compiled`, and a failed probe, which
also sets `missing_classified?` false so the UI renders uncertainty rather
than a confident zero).

`FleetStatus.report/1` names its comparison basis instead of assuming it:
`:generation` when one is published, `:local_ebin` otherwise. It shows TWO
shas per node and never conflates them — the **build sha**
(`BuildInfo.sha/0`, the image it booted from) and the **live code sha**
(`CodeStamp`, the generation actually applied). A node can be on the right
build sha and still drifted, or on an old image and perfectly in sync.

`CodeStamp` lives in `:persistent_term` on the node it describes, and the two
properties that follow are both wanted: it **survives code loading**
(VM-global, not module state) and it **does NOT survive a restart** — a
restarted node boots from its image and really is running image code again
until the hub reconciles it, which happens within seconds. A stamp that
outlived the VM would claim a generation the node had already lost.

`/api/version` reports both: `sha`/`built_at` (image; frozen shape, both
deploy scripts `grep -o '"sha":"[^"]*"'`) plus `code_sha` and a `code`
object. With nothing applied `code_sha` is `null` and `code.source` is
`"image"` — it deliberately does NOT fall back to echoing `sha`, since
distinguishing those two states is the entire point of the field.

`GET /api/drain` answers "is anything in flight on this node right now?" for
the deploy script's pre-restart check. 200 when the question was answered,
503 when it could NOT be — an unanswerable check is a refusal, never a green
light. `?ignore=<uuid>,<uuid>` drops session ids from the counts, so an
agent-driven deploy running inside a session on the host it is restarting
does not forever refuse to restart itself.

Operator surface: MCP `publish_code_generation`, `code_generation_status`,
`supersede_code_generation`, `purge_orphaned_modules` (orchestrator-only),
plus the Settings page drift view.

## Two known limits

1. **The deploy machinery takes the slow path.** `CodeSync`/`CodePush` are
   pushed LAST precisely because the pusher is executing its own code while
   it pushes, which is also the case most likely to come back `wedged`
   against the two-version rule rather than `loaded`. Ship a change to the
   hot-deploy machinery itself with a full deploy.
2. **A schema change with NO migration escapes the gate.** The `defstruct`
   rule cannot see a struct generated by a macro — most importantly an Ecto
   `schema do ... end` block. In practice an Ecto field change ships with a
   migration and the gate refuses on migrations; the residual hole is a
   change with no migration at all (`field ..., virtual: true` is the
   clearest example). It would pass the gate, hot-load fine, and crash any
   long-lived process holding an old-shaped struct on its next message.
   Detecting it means understanding the macro, not grepping a diff. Use the
   slow path.

Two smaller, deliberate gaps: a DELETED `lib/**.ex` is classified by content
rules only (the module stays resident remotely — see `orphaned` above), and
the payload is ALWAYS a full compiled ebin rather than a hand-picked module
list. That last one is not an efficiency choice: a module attribute read at
COMPILE time by other modules needs its CONSUMERS recompiled, which the gate
cannot see from a one-file diff. `mix compile` recompiles the dependents,
their md5s change, and the md5 diff picks them up. Deriving the payload from
the git diff instead would look like an obvious optimisation, pass every
test, and silently ship a module whose callers still hold the old inlined
constant.
