# Deploys as OrcaHub Jobs — survey + design

Status: **DESIGN ONLY — nothing here is implemented.** Written 2026-09-20 from
a read-only survey. No deploy was run to produce it.

Goal: run project deploys *through* OrcaHub as durable `OrcaHub.Jobs` jobs with
mutual exclusion, starting with OrcaHub's own deploy and generalising to the
user's other projects. The existing deploy scripts keep working **exactly as
they are** — we are WRAPPING them, never rewriting them.

---

## Part 1 — Survey (facts)

### 1.1 The deploy scripts that exist on this host

Three, all in the private `~/homelab/scripts/` repo (not checked into
orca_hub), all `bash` + `set -euo pipefail`, all stdout/stderr-only.

| Project | Script | Deploys | cwd / app repo | Args | Exit | Rough runtime |
|---|---|---|---|---|---|---|
| **orca_hub** | `deploy-orca-hub.sh` (1139 ln) | 6 prod instances: 3 k3s deployments via Flux, `mini`, `gb10` (arm64), local systemd | `cd`s itself to `$ORCA_REPO` (default `/home/zach/orca_hub`, [L309-310]) | 9 flags: `--skip-push/-build/-local/-k3s/-env/-mini/-gb10/-arm64`, `--allow-dirty`, `-h` | `0` ok, `1` abort, `2` unknown flag [L354] | Longest of the three: native 2-arch buildx + up to 3×180 s Flux polls [L924-929] + 2 remote restarts |
| **content-studio** | `deploy-content-studio.sh` (10 steps) | k3s `content-studio` + `content-studio-worker` (version-locked pair) via Flux | `APP_REPO=/home/zach/circus-of-puffins/voice_prompt` [L264] | `[version]` + `--show/--status`, `--major`, `--minor`, `--dry-run`, `--allow-dirty`, `--skip-build` | `0` / `1` via `fatal()` [L341] | Long; build+push 2 images, Flux reconcile, `ROLLOUT_TIMEOUT=300s` [L279] |
| **video-search** | `deploy-video-search.sh` (8+ steps) | k3s `video-transcript-search` via Flux | `APP_REPO=/home/zach/dell/elastic-video-search` [L163] | `[ref]` (default `origin/main`) + `--dry-run`, `--force`, `--skip-build`, `--no-lockfile-rewrite` | `0` / `1` via `fatal()` [L221] | Long; npm build + arch proof |

Properties that matter for wrapping, verified in all three:

- **No script writes a state file.** The contract is genuinely stdout + exit code.
- **No script reads stdin or `/dev/tty` for a decision.** Every `read` hit is
  `IFS= read -r` over a here-string, i.e. line iteration. content-studio has a
  `sleep 10` "Ctrl-C to abort" window [L781-784] — non-interactive-safe, it just
  costs 10 s. **So all three are safe to run headless in a job.**
- **All three share a byte-identical `banner()`** — orca-hub [L360-365],
  content-studio [L326-331], video-search [L209-214]:
  ```
  echo ""; echo "====…===="; echo ">>> $*"; echo "====…===="
  ```
  This is a uniform, zero-cost step marker across every script (see §2.6).
- content-studio and video-search additionally share an identical `fatal()`
  that frames the message in `####…####` on **stderr**.

#### `deploy-orca-hub.sh`: abort vs warn is deliberately non-uniform

This is why we do not flatten its guards into a declarative mask. Dependency
order and failure *severity* are both load-bearing, and the messages carry most
of the value.

**ABORTS (exit 1)** — dirty checkout [L655-661]; empty `LOCK_SHA` [L687-692];
gb10 unreachable for the arm64 leg [L704-709]; buildx builder missing
`linux/arm64` [L715-727]; systemd bootstrap guard [L774-784]; artifact
missing/wrong-arch [L841-864]; homelab manifests already dirty [L900-905]; env
sops decrypt/install [L951-975]; no artifact at local install [L1082-1085].

**WARNS ONLY (deploy continues)** — image-tag prune [L886]; buildx cache prune
[L889,L893]; all three k3s `/api/version` polls [L925-929]; the whole mini stage
[L998-1022]; the whole gb10 stage [L1044-1068].

The gb10 sudoers guard [L764-771] is the canonical example of message value: on
failure it prints the **literal sudoers line to paste**, built from
`GB10_SUDOERS_LINE` [L649]. A boolean gate discards that.

#### Step 7 self-restart

```bash
ssh -o BatchMode=yes localhost "sudo -n systemctl restart $SYSTEMD_UNIT"   # L1098
```
Routed through sshd because the unit sets `NoNewPrivileges=yes`, which blocks
`sudo` from inside the service's own process tree [L1092-1097]. Everything after
that line — status print [L1100] and the entire final summary [L1105-1139] —
**never executes** in an agent-driven deploy. Step 7 is last precisely so that
is harmless.

#### `verify-orca-deploy.sh` (111 ln)

Companion, run **after** the local restart settles. Polls `GET /api/version` on
all six instances, `TIMEOUT_S=120` default. `FAILED=1` → `exit 1`; every
instance is a hard failure, no skip flags [L91-111]. Takes an optional `[sha]`,
defaulting to `git -C $ORCA_REPO rev-parse --short HEAD` [L55].

### 1.2 `OrcaHub.Jobs` — the real API

- **Launch.** `JobSupervisor.start_job/1` [job_supervisor.ex:37] is the only
  entry point that launches. `Jobs.Launcher.launch_main/1` writes the command to
  a durable script file, wraps it in a script that redirects stdout+stderr to a
  log and writes the exit code to a sentinel via write-tmp-then-`rename` (atomic),
  then spawns `setsid sh <wrapper> & echo $! > <pidfile>` so `pid == pgid == sid`
  [launcher.ex:63-101]. The Erlang port only sees a ~instant handshake.
- **On-disk.** `Jobs.Paths` → `$HOME/.orca_hub/jobs` (override `ORCA_JOBS_DIR`),
  deliberately *not* `/tmp` (the unit sets `PrivateTmp=yes`) and *not* the
  release dir (deploys replace it). Files: `<id>.cmd.sh`, `.wrap.sh`, `.log`,
  `.exit`, `.pid`, plus `.verify.*` twins [paths.ex:48-58].
- **Completion.** `JobWatcher` polls every 5 s (`:job_poll_interval_ms`),
  re-reading the job row fresh each tick. Priority: sentinel → timeout → pid
  gone → sample progress [job_watcher.ex:174-200]. Exit code comes from the
  sentinel file; `finalize/3` writes `status` + `finished_at` and broadcasts
  `{:job_finished, id, status}` on `"job:<id>"`.
- **Statuses.** `running -> verifying -> succeeded | failed | verification_failed
  | timed_out | cancelled`; non-terminal = `running`, `verifying`
  [job.ex:21-22]. `verify_command` runs only if the main command exits 0.
- **Node.** Yes — `runner_node` is a NOT NULL column [create_jobs.exs], set to
  `Atom.to_string(node())` at creation [tools/jobs.ex:284]. All DB access goes
  through `HubRPC` (`get_job`, `create_job`, `update_job`,
  `list_nonterminal_jobs_for_node`, `list_jobs` [hub_rpc.ex:716-727]), so the
  context works identically on hub and agent. Only `cancel_job` routes to the
  job's own node, via `Cluster.rpc/5` [tools/jobs.ex:446-459].
- **Wake.** `start_job(wake_when_done: true)` calls
  `HubRPC.watch_job(session_id, job_id)` → `SessionHeartbeat.watch_job/2`
  [session_heartbeat.ex:146], a one-shot standalone watch. `schedule_heartbeat`
  takes `watch_job_ids` + `wake_on` (`"any"` default / `"all"`) for group
  watches [session_heartbeat.ex:117-120, 1032-1065]. Both fire only on a
  TERMINAL status — `verifying` deliberately does not wake.
- **Per-job cwd/env.** cwd: yes — `directory` column, NOT NULL, from the
  `cwd` arg or the session's directory [tools/jobs.ex:267-277]. **Env: no.**
  There is no per-job env plumbing; `Launcher.job_env/0` applies only the
  node's own scrub policy, with an explicit comment that jobs have no
  `project_id` to extend the allow-list with [launcher.ex:137-149].
- **Hub restart mid-job.** The DETACHED PROCESS is untouched by a BEAM restart;
  only the watcher dies. `JobResumer` re-attaches a watcher at boot to every
  non-terminal job where `runner_node == node()` [job_resumer.ex:91-93]. A job
  whose sentinel appeared while the hub was down is finalized correctly on the
  resumed watcher's first tick.

### 1.3 ⚠ The finding that drives this whole design

**`setsid` does NOT escape the systemd cgroup, so a job launched from the local
systemd instance is killed by `systemctl restart orca-hub` — which is exactly
what the OrcaHub deploy does to itself at step 7.**

Verified empirically on this host (read-only; nothing was restarted):

```
$ cat /proc/self/cgroup                      # this agent session
0::/system.slice/orca-hub.service

$ setsid sleep 40 & ; cat /proc/<child>/cgroup
0::/system.slice/orca-hub.service            # ← STILL in the unit
$ ps -o pid,pgid,sid -p <child>
4147601 4147601 4147601                      # setsid genuinely worked
$ systemctl status orca-hub | grep -c <child>
2                                            # systemd lists it under the unit
```

`setsid` changes session/process-group, not cgroup membership. The installed
unit sets **no `KillMode=`**, so it defaults to `control-group`: stop/restart
SIGTERMs *every* process in the cgroup (then SIGKILL after
`TimeoutStopSec=30`).

Consequence if we naively wrap the deploy in `start_job`: step 7 kills the
deploy job itself. Because a group-kill prevents the wrapper from writing its
sentinel, `JobWatcher` takes the "pid gone, no sentinel" branch and calls
`finalize_crashed` [job_watcher.ex:265-275], marking a **successful deploy as
`failed`** with a misleading "likely OOM-killed" note. That is a false negative
on the one signal the feature exists to provide.

This also means the `OrcaHub.Jobs` moduledoc's claim that a job survives "an
OrcaHub restart/deploy" is **true for a BEAM-level restart and false for a
`systemctl restart` of the local unit**. Worth a follow-up doc fix; out of scope
here.

**The escape, also verified:**

```
$ ssh -o BatchMode=yes localhost 'cat /proc/self/cgroup'
0::/user.slice/user-1000.slice/session-783.scope      # outside the unit

# launched via ssh + setsid, then the ssh connection closed:
$ cat /proc/<child>/cgroup
0::/user.slice/user-1000.slice/session-784.scope      # survived disconnect
$ busctl get-property … KillUserProcesses
b false
```

`systemd-run` exists but is unusable here: `--user` fails (no
`DBUS_SESSION_BUS_ADDRESS`/`XDG_RUNTIME_DIR` inside the service), `Linger=no`,
and `--system` needs root, which `NoNewPrivileges=yes` plus the narrowly-scoped
sudoers drop-in both deny. **`ssh localhost` is the one proven escape — and it
is the same escape `deploy-orca-hub.sh` already uses at L1098.**

### 1.4 Tool surface, project concept, persistence conventions

- **Tools.** `OrcaHub.MCP.Tools` is a thin facade over 16 category modules; each
  exposes `list/0` returning maps with `"name"`, `"description"`,
  `"inputSchema"` (raw JSON Schema), plus `call/3` clauses dispatched by name
  [tools.ex]. Visibility is layered: role filter (`@regular_session_tools`
  allow-list; orchestrators see everything) → conditional Discord tools →
  `OrcaHub.ToolPolicy` (the `sessions.tool_allowlist`/`tool_denylist` columns).
  Triggers mirror the same two columns (`.context/triggers.md` §"Per-trigger
  tool restrictions"; explicit deny-all is `tool_denylist: ["*"]`, deny wins).
  All six Jobs tools are already in `@regular_session_tools`.
- **Projects exist.** `projects` table: `id` (binary_id), `name`, `directory`,
  `node`, `deleted_at`, `env_allowlist`, `commit_trailer`, `key_prefix`
  (globally unique), `issue_counter`. Lookups: `get_project/1`,
  `get_project_by_directory/1`, and `resolve_id/1`, which accepts a full UUID or
  a ≥8-char hex prefix and returns `{:ok, project} | {:error, message}` without
  raising on garbage [projects.ex:46-80]. Node routing:
  `Cluster.project_node_for/1` [cluster.ex:676-681]; `Cluster.rpc/5` already
  refuses an unavailable node rather than falling back [cluster.ex:156-175].
- **Migration style.** `@primary_key {:id, :binary_id, autogenerate: true}`,
  `timestamps()`, explicit `create index`/`create unique_index`, heavy
  explanatory comments. Cross-entity refs that must outlive their creator are
  **plain `:binary_id` fields with no FK** (`jobs.session_id`,
  `Session.parent_session_id`, `Trigger.last_session_id`) — an established
  convention this design follows.
- **No locking primitive exists.** `grep -rniE
  "advisory_lock|pg_try_advisory|acquire_lock|mutex|lease" lib/` → **zero hits**.
  "One deploy at a time" is currently enforced by nobody. Confirmed.
- **Hub/agent.** Hub owns the DB; agents reach it via `HubRPC`/`:erpc`. So the
  lease table lives on the hub and is reached through `HubRPC` like everything
  else, which makes it a genuine cluster-wide mutex for free.

---

## Part 2 — Design

### 2.1 The lease

A **lease with a TTL**, not a lock: the holder can die, and a crashed deploy
must expire rather than wedge the project forever.

```elixir
# priv/repo/migrations/<ts>_create_deploy_leases.exs
create table(:deploy_leases, primary_key: false) do
  add :id,          :binary_id, primary_key: true
  add :target,      :string, null: false   # the mutex KEY — see below
  add :job_id,      :binary_id             # no FK: leases outlive jobs
  add :session_id,  :binary_id             # no FK: who asked
  add :runner_node, :string, null: false
  add :acquired_at, :utc_datetime, null: false
  add :expires_at,  :utc_datetime, null: false
  add :released_at, :utc_datetime          # NULL while held
  add :note,        :string                # e.g. "deploy 01a1b00 --skip-arm64"
  timestamps()
end

# THE mutual-exclusion mechanism. Partial unique index: at most one
# unreleased lease per target, enforced by Postgres, not by application code.
create unique_index(:deploy_leases, [:target],
         where: "released_at IS NULL", name: :deploy_leases_one_live_per_target)
create index(:deploy_leases, [:job_id])
```

**Key = `target`, a short string** (`"orca_hub"`, `"content-studio"`,
`"video-search"`) — the same key as the deploy-registry entry (§2.4).

Not `project_id`: two of the three deployable things (content-studio,
video-search) are not guaranteed to have a `projects` row, the registry key is
what a model actually types, and a deploy is scoped to a *deployment target*,
not to a checkout. Not `directory` either: `deploy-orca-hub.sh` touches two
repos (`$ORCA_REPO` and `$HOMELAB_REPO`), so no single directory names it. We
can still record `project_id` later as metadata if a UI wants it.

**Rules.**

- **acquire** — insert a row with `expires_at = now + ttl`. The partial unique
  index makes a double-acquire a `unique_violation`; catch it and return
  `{:error, :held, current_lease}`. Never read-then-write.
- **steal an expired lease** — one statement, inside the same transaction as the
  insert, so there is no window:
  ```sql
  UPDATE deploy_leases SET released_at = now(), note = note || ' [expired]'
   WHERE target = $1 AND released_at IS NULL AND expires_at < now();
  ```
  Then insert. Loser of a race still hits the unique index and reports held.
  Expiry is a *reaping* operation, never a silent overwrite: the stolen row stays
  in the table with `released_at` set, so the history is auditable.
- **release** — `released_at = now()`, keyed on `id` AND `job_id`, so a stale
  caller cannot release someone else's lease.
- **renew** — bump `expires_at`. Offered in the API but, per §2.2, **not used by
  the OrcaHub target**.
- **effective liveness** — a lease is *held* iff
  `released_at IS NULL AND expires_at > now()`. Callers additionally cross-check
  the linked job's status (§2.2).

### 2.2 Who renews the lease — decision: **nobody. Long fixed TTL + job status.**

The constraint: `deploy-orca-hub.sh` step 7 restarts the local hub. Any in-hub
renewer GenServer dies with it. A renewer would therefore have to live in the
detached job itself (the wrapper shelling back into the DB), which means putting
DB credentials and SQL into the wrapper script — new failure modes, new secret
handling, for a timer.

**Chosen: no renewer.** Two reasons it is safe:

1. **The job row is the real liveness signal, not the timer.** The job is
   durable, `JobResumer` re-attaches a watcher at boot, and the watcher finalizes
   from the on-disk sentinel. So the authoritative question "is a deploy still
   running?" is answered by `job.status ∈ {running, verifying}` — which survives
   the restart *by construction*. The TTL is a **backstop** for the case where
   the job record itself is unreachable or its node is gone, not the primary
   mechanism.
2. **A fixed TTL is honest about the worst case.** Default **`ttl_seconds:
   5400` (90 min)** per target, generously over the observed envelope (2-arch
   native build + 3×180 s Flux polls + two remote restarts). It is a registry
   field, so content-studio/video-search can carry their own.

`in_flight_deploys` therefore reports the *conjunction*, and names the
disagreement when it sees one:

| lease | linked job | reported |
|---|---|---|
| unexpired | non-terminal | `in_flight` |
| unexpired | terminal | `stale_lease` — safe to release; surfaced with a hint |
| expired | non-terminal | `lease_expired_job_running` — **do NOT auto-steal**; refuse and tell the operator |
| expired/released | terminal or absent | not in flight |

That third row is the case a pure-TTL design gets wrong, and the reason the job
cross-check exists.

**Release is driven by job completion, not by the deploy script.** `JobWatcher`
already broadcasts `{:job_finished, job_id, status}` on `"job:<job_id>"`
[job_watcher.ex:322-324]. A small hub-only `OrcaHub.Deploys.LeaseReaper`
subscribes and releases the matching lease. If it misses the broadcast (it died
with the restart), the boot sweep catches it: on hub start, release every
unreleased lease whose `job_id` is terminal, and mark expired ones. Belt and
braces, both cheap.

### 2.3 Escaping the cgroup — decision: **opt-in ssh-localhost launch**

The deploy job MUST outlive `systemctl restart orca-hub` (§1.3). Options:

- **(a) Accept death at step 7 and special-case it.** Rejected: it requires
  teaching `JobWatcher` that "vanished without a sentinel" is sometimes success,
  which is exactly the ambiguity `finalize_crashed` exists to eliminate. It also
  only works for targets that restart the local hub — an accidental
  mis-classification for every other target.
- **(b) Change `Jobs.Launcher` to always launch via ssh.** Rejected: it
  destabilises the general job path (every download, build and test suite) for
  one caller's problem, and adds an sshd dependency to a core primitive.
- **(c) ✅ Per-target opt-in `escape_cgroup: true`, handled in the deploy layer.**

Chosen: (c). The registry entry carries `escape_cgroup: true`, and
`OrcaHub.Deploys` composes the command it hands to `start_job` as:

```sh
ssh -o BatchMode=yes localhost 'cd <dir> && exec <script> <args>'
```

`Jobs.Launcher` is untouched: it still `setsid`s a wrapper in the unit's cgroup,
but that wrapper's child is an `ssh` client whose *remote* end runs in
`user.slice`. Step 7 kills the local ssh client; the real deploy keeps running
and completes.

#### ⚠ The naive form of (c) is BROKEN — and it was, in this doc's first draft

An earlier revision claimed the wrapper's sentinel would record "the ssh
client's exit status", and that `verify_command` would then carry the real
verdict. **Both halves are false.** The wrapper (`sh <wrapper>`) is itself in
`/system.slice/orca-hub.service` — `setsid` did not move it (§1.3) — so the
restart SIGTERMs the wrapper too, and a shell killed by SIGTERM never reaches
the line after its command. `Launcher.wrapper_script/4` has **no `trap` and no
`exec`** [launcher.ex:91-101]; the sentinel write is simply the next line.

Verified, not reasoned (job-shaped replica in a throwaway dir, `sleep`
stand-ins, SIGTERM at t=2s):

```
--- variant: A_plain_group (kill: group) ---      --- variant: B (kill: wrapper only) ---
wrapper pid/pgid/sid: 4157214 4157214 4157214     wrapper pid/pgid/sid: 4157255 …
wrapper still alive?   no                         wrapper still alive?   no
sentinel exists?       NO                         sentinel exists?       NO
sentinel .tmp exists?  no                         sentinel .tmp exists?  no
```

**No sentinel at all — not even the `.tmp`**, under either kill mode. So the
real chain was: no sentinel → `JobResumer` re-attaches → "pid gone, no
sentinel" → `finalize_crashed` → **failed** with the misleading OOM note → and
`verify_command` **never runs**, because verify is gated on the main command
exiting 0 [job_watcher.ex:207-218]. That is the exact false negative §1.3 exists
to prevent, merely relocated from the deploy process to the wrapper.

#### ✅ Chosen resolution: remote side owns log + sentinel, **and `job.pid` is rebound to the remote pid**

Two deploy-layer-only changes, neither touching `Jobs.Launcher` or `JobWatcher`.

**1. The remote (user.slice) half owns the real log and sentinel.** This works
because of a property worth stating explicitly, since it is easy to get
backwards: `PrivateTmp=yes` means the ssh side does **not** share `/tmp`, but it
**does** share `$HOME` — and `Jobs.Paths` deliberately lives at
`$HOME/.orca_hub/jobs`, not `/tmp` [paths.ex:6-34]. Verified:

```
$ echo hi > /tmp/_probe; ssh localhost 'cat /tmp/_probe'
cat: /tmp/_probe: No such file or directory      ← /tmp is PRIVATE
$ ssh localhost 'cat ~/.orca_hub_probe_marker'
home-marker                                      ← $HOME is SHARED
$ ssh localhost 'ls -d ~/.orca_hub/jobs'
/home/zach/.orca_hub/jobs
```

(My first attempt at this experiment used `/tmp` and reported a false negative
— the remote wrote a sentinel the service could not see. Worth remembering: any
experiment crossing this ssh boundary must use `$HOME`.)

The local half then **blocks** on that shared sentinel, so the job does not
finish instantly (the explicit constraint on this resolution). Composed shape:

```sh
ssh -o BatchMode=yes localhost "setsid sh -c '
  echo \$\$ > <jobs_dir>/<id>.remote.pid
  cd <dir> && <script> <args>
  rc=\$?; printf %s \$rc > <id>.exit.tmp; mv <id>.exit.tmp <id>.exit
' </dev/null >'<jobs_dir>/<id>.log' 2>&1 & sleep 0.5"
while [ ! -f '<jobs_dir>/<id>.exit' ] && [ -d /proc/\$REMOTE ]; do sleep 2; done
exit \$(cat '<jobs_dir>/<id>.exit' 2>/dev/null || echo 70)
```

The `[ -d /proc/$REMOTE ]` half of the poll condition stops the local poller
spinning forever if the remote is cancelled and no sentinel is ever written.

**2. Rebind `job.pid`/`job.pgid` to the REMOTE pid** once the remote half has
reported it. This is what closes the race — and there *is* a real race without
it, measured:

```
t=3s   local wrapper alive? YES
t=5s   wrapper alive? no | sentinel? NO  <-- race window: pid-gone + no-sentinel
t=17s  sentinel? YES -> '7'
```

Between the restart and the remote finishing, a resumed watcher would see
pid-gone + no-sentinel and wrongly `finalize_crashed`. Rebinding fixes it
because `/proc` is shared (no PID namespace on this unit) and the remote process
outlives the kill:

```
remote pid        : 4160476
remote visible in /proc from THIS (service-cgroup) shell? YES
remote cgroup     : 0::/user.slice/user-1000.slice/session-791.scope
--- after the kill ---
local wrapper alive?  no
REMOTE pid alive?     YES  <-- watcher pid_alive? TRUE, so NO finalize_crashed
sentinel yet?         no (still deploying - correct)
--- after remote completes ---
REMOTE pid alive?     no
sentinel?             YES -> '0'
log:                  DEPLOY_DONE|
```

The rebind is a plain `HubRPC.update_job(job, %{pid: r, pgid: r})` — the same
mechanism `update_job_progress_metric` already relies on, because `JobWatcher`
re-reads the job row **fresh on every tick** rather than caching it
[job_watcher.ex:6-13]. No watcher IPC, no Launcher change. It also makes
`cancel_job` more correct, not less: it signals `-pgid`, which now names the
remote process group that is actually doing the work.

**Why the alternatives lost.** (i) alone — remote owns the sentinel, no rebind —
leaves the measured race above, and a design that prides itself on honesty
should not ship "in practice the hub boots slower than the remainder of the
deploy". (ii) `trap … TERM` in the composed command *does* fire (verified: it
wrote `143`), but it can only write a **premature, invented** exit code while
the real deploy is still running remotely — it finalizes the job on the wrong
event, which is worse than the bug it fixes. (iii) deploy-specific boot
reconciliation that re-verifies rather than trusting `finalize_crashed` is a
genuine fallback, but it is strictly more machinery than the rebind and it
leaves a window where `deploy_status` reports `failed` for a healthy deploy;
keep it in the back pocket, do not build it now.

#### What `status` / `exit_code` / `verify_*` MEAN for an `escape_cgroup: true` target

This is the contract `deploy_status` must report truthfully:

| Field | Meaning | Trustworthy? |
|---|---|---|
| `status` | Normal ladder. `running` spans the whole deploy *including* the hub restart. | **Yes** |
| `exit_code` | The **remote deploy script's own** exit code, written by the remote half into the shared sentinel. Not the ssh client's, not the wrapper's. | **Yes** — this is the correction; the previous draft wrongly said otherwise |
| `exit_code == 70` | Sentinel absent when the local poller gave up — remote died without writing. Reserved marker meaning "indeterminate", not a script exit code. | Yes, as a signal |
| `verify_exit_code` | `verify-orca-deploy.sh`'s exit: 0 = all six instances on the new SHA. Runs only if `exit_code == 0`. | **Yes** |
| `status == succeeded` | Deploy exited 0 **and** all six instances confirmed the SHA. | **Yes** |
| `status == failed` | Deploy itself exited non-zero. | Yes |
| `status == verification_failed` | Deploy exited 0 but ≥1 instance is not on the new SHA. The common real-world case (a slow gb10 or Flux reconcile). | Yes |

Caveat that remains, stated plainly: a deploy exiting 0 can still have had a
**non-fatal** mini/gb10/k3s-poll failure (§1.1 — six warn-only paths). That is
why `deploy_status` surfaces `warnings[]` separately (§2.6) and why
`verify_command` is not optional for this target.

```elixir
verify_command: "/home/zach/homelab/scripts/verify-orca-deploy.sh <sha>"
```

Targets that do not restart their own host (content-studio, video-search) set
`escape_cgroup: false`, take the plain `Launcher` path unchanged, and none of
the above applies to them.

### 2.4 The deploy registry — decision: **checked-in map, overridable by config**

Options weighed: a DB table (migration + context + UI for a 3-row table that
changes roughly never — over-engineering, and it puts host-specific private-repo
paths in the database); pure `config/runtime.exs` from env (awkward to express a
struct-per-target); a checked-in map.

**Chosen:** a checked-in default map in `OrcaHub.Deploys.Registry`, deep-merged
with `Application.get_env(:orca_hub, :deploy_targets, %{})` — so the three known
targets ship in code and a fourth can be added in config **without a code
change**, satisfying the stated bar.

```elixir
%{
  "orca_hub" => %{
    name: "OrcaHub",
    command: "/home/zach/homelab/scripts/deploy-orca-hub.sh",
    directory: "/home/zach/orca_hub",
    node: "debian@192.168.1.177",   # pinned; never re-routed. SEE NOTE BELOW.
    allowed_flags: ~w(--skip-push --skip-build --skip-local --skip-k3s
                      --skip-env --skip-mini --skip-gb10 --skip-arm64
                      --allow-dirty),
    positional: :none,
    escape_cgroup: true,            # §2.3 — restarts its own hub at step 7
    ttl_seconds: 5400,
    timeout_seconds: 5400,
    verify_command: "/home/zach/homelab/scripts/verify-orca-deploy.sh"
  },
  "content-studio" => %{ …, directory: "/home/zach/circus-of-puffins/voice_prompt",
    allowed_flags: ~w(--show --status --major --minor --dry-run --allow-dirty --skip-build),
    positional: :version, escape_cgroup: false, ttl_seconds: 2700 },
  "video-search" => %{ …, directory: "/home/zach/dell/elastic-video-search",
    allowed_flags: ~w(--dry-run --force --skip-build --no-lockfile-rewrite),
    positional: :ref, escape_cgroup: false, ttl_seconds: 2700 }
}
```

**NOTE on `node` — the implementer must resolve this, not copy it.** The
registry stores an Erlang node name as a string, matched against
`jobs.runner_node` (`Atom.to_string(node())`). An earlier draft of this doc
guessed `"orca@debian"`, which is **wrong**. The real local node is
`debian@192.168.1.177`, built by `rel/env.sh.eex:11-13` from the `NODE_NAME` env
var in `/home/zach/orca-hub-releases/.env` (only the `RELEASE_NODE_BASENAME`
fallback path produces an `orca@…` name, and this host does not use it). So:
**resolve each target's node from the live system at implementation time**
(`Node.self()` on the target host, or that host's `NODE_NAME`) and treat any
node string written in this document as illustrative. A wrong value here does
not silently misroute — `Cluster.rpc/5` refuses an unknown node — but it does
produce a confusing `node_unavailable` refusal for a healthy host.

`allowed_flags` is an **exact-match allow-list**, not a parser. Anything not in
the list is refused before launch — this is argument validation against shell
injection, not a re-modelling of the script's semantics. The single optional
positional is validated by shape (`^[0-9]+\.[0-9]+\.[0-9]+$` for `:version`,
`^[A-Za-z0-9._/-]+$` for `:ref`) and every piece is shell-quoted via
`Jobs.Paths.shq/1`.

### 2.5 Tool surface

Three tools in a new `OrcaHub.MCP.Tools.Deploys`, registered in `@categories`.
**Orchestrator-only** — deliberately NOT added to `@regular_session_tools`; a
worker session should not be able to start a production deploy. Per-session and
per-trigger `ToolPolicy` then applies on top for free.

#### `start_deploy`

```json
{"type":"object",
 "properties":{
   "target":{"type":"string","description":"Registry key, e.g. \"orca_hub\". Use list_deploy_targets."},
   "flags":{"type":"array","items":{"type":"string"},"description":"Exact flags from the target's allowed_flags."},
   "version":{"type":"string","description":"Optional positional (version or git ref) if the target takes one."},
   "wake_when_done":{"type":"boolean"},
   "note":{"type":"string"}},
 "required":["target"]}
```

Success:
```json
{"ok":true,"target":"orca_hub","job_id":"…","lease_id":"…",
 "status":"running","runner_node":"orca@debian",
 "command":"/home/zach/homelab/scripts/deploy-orca-hub.sh --skip-arm64",
 "expires_at":"2026-09-20T18:12:00Z","log_path":"/home/zach/.orca_hub/jobs/….log",
 "verify_command":"/home/zach/homelab/scripts/verify-orca-deploy.sh",
 "note":"Deploy launched detached. This target restarts its own host at step 7, so the job's EXIT CODE is not authoritative — verify_command decides succeeded vs verification_failed. Poll deploy_status."}
```

Refusal (the important shape — never a bare error string):
```json
{"ok":false,"reason":"held","target":"orca_hub",
 "held_by":{"job_id":"…","session_id":"…","acquired_at":"…","expires_at":"…",
            "job_status":"running","note":"deploy 01a1b00"},
 "hint":"A deploy is already in flight for orca_hub. Poll deploy_status with this job_id; do not start a second one."}
```
Other `reason`s: `unknown_target`, `disallowed_flag` (with `allowed_flags`
echoed), `invalid_positional`, `node_unavailable`, `lease_expired_job_running`.

#### `in_flight_deploys`

`{"target": "<optional filter>"}` → the discoverability answer:
```json
{"count":1,"deploys":[
  {"target":"orca_hub","state":"in_flight","job_id":"…","session_id":"…",
   "runner_node":"orca@debian","acquired_at":"…","expires_at":"…",
   "seconds_remaining":3812,"job_status":"running",
   "current_step":">>> Step 3/7 — Updating k3s manifests for Flux"}]}
```

#### `deploy_status`

`{"job_id": "…", "log_tail_bytes": 4000}` → the structured feedback:
```json
{"target":"orca_hub","job_id":"…","status":"verification_failed",
 "exit_code":0,"verify_exit_code":1,"runner_node":"orca@debian",
 "started_at":"…","finished_at":"…","duration_seconds":1284,
 "steps_seen":["Step 1/7 — Pushing current branch to origin",
               "Step 2/7 — Building image + extracting release artifact(s) (linux/amd64,linux/arm64)",
               "Step 3/7 — Updating k3s manifests for Flux",
               "Step 4/7 — Installing per-host env files (sops-decrypt)",
               "Step 5/7 — Installing release on mini + restarting its systemd service",
               "Step 6/7 — Installing arm64 release on gb10 + restarting its systemd service",
               "Step 7/7 — Installing release locally + restarting systemd service: orca-hub"],
 "last_step":"Step 7/7 — Installing release locally + restarting systemd service: orca-hub",
 "skipped_steps":[],
 "errors":["  FAIL: gb10 (zach@192.168.1.77, …) still reports sha='4dc631d' after 120s (want 01a1b00)"],
 "warnings":["WARNING: gb10 did not report sha=01a1b00 after restart — check it manually."],
 "log_tail":"…last 4000 bytes…",
 "verify_log_tail":"…",
 "lease":{"state":"released","released_at":"…"},
 "hint":"verify_command failed: one or more instances are not on the new SHA. Read errors[] and verify_log_tail; re-run verify-orca-deploy.sh once the instance settles."}
```

No new `cancel` tool — the existing `cancel_job` already reaches the right node,
and the `LeaseReaper` releases the lease on the resulting `cancelled` broadcast.

### 2.6 Structured feedback — the honest answer

**We get "which step failed" from: exit code + a regex over the log + the last N
log lines. Nothing more. And that requires ZERO changes to the scripts.**

It works better than it sounds only because of one lucky fact established in
§1.1: all three scripts share a byte-identical `banner()`. So a single parser
covers every target, today and for any future script that copies the same
helper:

- **Steps** — `^>>> (.+)$` over the log, in order. `steps_seen` is that list;
  `last_step` is its final element. For `deploy-orca-hub.sh` this yields
  `Step N/7 — …`, which is genuinely "which step it got to".
- **Skipped** — `^--- SKIPPED: (.+) ---$` [orca-hub L367-370, content-studio L796].
- **Errors** — lines matching `^(ERROR|FATAL|  FAIL):`, plus lines framed by the
  `####…####` block that `fatal()` emits on stderr. Captured because the
  wrapper already merges stderr into the one log (`> log 2>&1`,
  [launcher.ex:96]).
- **Warnings** — `^WARNING:` / `^  TIMEOUT:`. These matter *specifically* because
  the mini/gb10/k3s-poll failures are non-fatal: a deploy can exit **0** with a
  failed gb10 stage. Surfacing `warnings[]` separately is what stops a model
  reading "exit 0" as "everything worked".

Limits, stated plainly:

- `last_step` is **the step it reached, not necessarily the step that failed**.
  Under `set -e` they usually coincide; a `WARNING`-only failure inside a
  completed step does not.
- For the OrcaHub target the exit code is unreliable after step 7 (§2.3). This
  is why `verify_command` carries the real verdict.
- The log tail is bytes, not lines — `check_job`'s existing `tail/1`
  [tools/jobs.ex:380-399] seeks to `size - 4000`, so the first line may be
  truncated mid-way. Parsing runs over the **whole** log, not the tail; only
  `log_tail` is truncated.

**What we would have to add to the scripts to do better: a machine-readable
sentinel** — one line per step boundary, e.g.
`echo "##ORCA-STEP {\"n\":3,\"of\":7,\"name\":\"…\",\"status\":\"begin\"}"` inside
`banner()`, and a `##ORCA-RESULT {…}` line in an `EXIT` trap carrying the
per-stage `MINI_OK`/`GB10_OK` booleans the summary already computes
[L1122-1133]. **Recommendation: do NOT do this now.** It edits three files in a
private repo we were told to leave alone, to replace a regex that already works,
and the `EXIT`-trap half cannot fire for the OrcaHub target anyway — step 7 kills
the process before any trap runs. Revisit only if the regex proves insufficient
in practice.

### 2.7 Failure and edge cases

| Case | Behaviour |
|---|---|
| **Hub restarts mid-deploy** (the normal OrcaHub path) | The LOCAL wrapper + ssh client are killed with the cgroup (§1.3, measured); the REMOTE half in `user.slice` is untouched and keeps deploying. Because `job.pid` was rebound to the remote pid (§2.3), the watcher resumed by `JobResumer` sees `pid_alive? == true` and does **not** `finalize_crashed`. When the remote finishes it writes the true log + sentinel into shared `$HOME`; the next tick reads the real exit code and launches `verify_command`. Lease survives — it is a DB row, and the TTL covers the whole window. Boot sweep reconciles anything the `LeaseReaper` missed while dead. |
| **Job killed** (`cancel_job`, timeout, OOM) | `JobWatcher` finalizes `cancelled`/`timed_out`/`failed`; `LeaseReaper` releases on the broadcast. Note a group-kill means no sentinel, which `JobWatcher` already handles by confirming the process is gone [job_watcher.ex:32-39]. |
| **Lease expires while the deploy is still running** | `in_flight_deploys` reports `lease_expired_job_running`. **We refuse to steal**, because the job is demonstrably alive. Surfaced with the job id so an operator can extend (`renew`) or cancel. This is the one case where TTL alone would be actively wrong. |
| **Two sessions race `start_deploy`** | Both attempt the insert; Postgres' partial unique index lets exactly one win. The loser gets `{"ok":false,"reason":"held", …}` naming the holder. No read-then-write anywhere. |
| **Deploy started from an agent node** | Allowed, but the job is created with `runner_node` = the **target's pinned node**, and launch is routed via `Cluster.rpc(node, JobSupervisor, :start_job, [id])` — same pattern `cancel_job` already uses. The lease lives on the hub (DB) either way, so exclusion is cluster-wide regardless of where the tool was called. |
| **Target's node is offline** | **Refuse.** `{"ok":false,"reason":"node_unavailable","node":"orca@debian","hint":"The deploy target's assigned node is unavailable. OrcaHub never re-routes a deploy to another node — bring the node back or deploy by hand."} ` NEVER fall back to the local node: a deploy is the single most host-specific action in the system (sops keys, ssh trust, buildx nodes, systemd units). `Cluster.rpc/5` already refuses rather than falling back [cluster.ex:156-175]. |
| **Registry target whose script is missing** | Checked at acquire time (`File.exists?` + executable) and refused as `unknown_target`/`script_missing` **before** the lease is taken, so a typo cannot hold the mutex. |
| **Stale lease, job already terminal** | `stale_lease`; `start_deploy` releases it and proceeds, since the job is provably finished. |

### 2.8 Implementation plan — 4 reviewable pieces, disjoint file ownership

Pieces 1 and 2 are fully parallel. 3 depends on both. 4 depends on 3.

**Piece 1 — Lease core.** Owns: `priv/repo/migrations/<ts>_create_deploy_leases.exs`,
`lib/orca_hub/deploys/lease.ex`, `lib/orca_hub/deploys/leases.ex`, and the
`# Deploy leases` block appended to `lib/orca_hub/hub_rpc.ex`.
Tests (`test/orca_hub/deploys/leases_test.exs`): acquire succeeds on a free
target; second acquire returns `{:error, :held, _}`; **concurrent acquire — N
`Task`s, exactly one winner** (mirroring `issues_key_allocation_test.exs`'s
existing concurrency pattern); expired lease is stolen and the old row is
retained with `released_at` set; release is a no-op for a non-matching `job_id`;
`list_live/0` excludes released and expired.

**Piece 2 — Registry + log parser.** Owns:
`lib/orca_hub/deploys/registry.ex`, `lib/orca_hub/deploys/log_parser.ex`.
No DB, no lease, pure functions — reviewable in isolation.
Tests: config override deep-merges over the default map; every unknown flag is
rejected and every allowed flag accepted; positional shape validation; shell
metacharacters in a positional cannot escape quoting. Parser tests run against
**fixture logs captured verbatim from the real scripts' banner format** (not
invented), asserting `steps_seen` ordering, `skipped_steps`, `errors`,
`warnings`, and the "exit 0 but gb10 WARNING" case specifically.

**Piece 3 — Orchestration + reaper.** Owns: `lib/orca_hub/deploys.ex`,
`lib/orca_hub/deploys/lease_reaper.ex`, and the one-line child addition to
`lib/orca_hub/application.ex` (hub-only). Composes command + `escape_cgroup`
wrapper, routes `start_job` to the pinned node, wires `verify_command`.

**Scope grew with §2.3's resolution** — this piece now also owns the
**remote-half composition and the pid rebind**, which is the subtlest code in
the whole design and deserves the most review attention:
- compose the `ssh … setsid …` remote half so that the REMOTE side writes
  `<id>.log` and `<id>.exit` into `Jobs.Paths.jobs_dir/0` (shared `$HOME`,
  never `/tmp` — §2.3), and `<id>.remote.pid` alongside them;
- the local half blocks on `[ ! -f sentinel ] && [ -d /proc/$REMOTE ]`;
- after launch, read `<id>.remote.pid` (bounded poll, a few seconds) and
  `HubRPC.update_job(job, %{pid: r, pgid: r})`. **If the remote pid never
  appears, do not leave the job silently mis-bound** — cancel and report, since
  an un-rebound job will be wrongly `finalize_crashed` at step 7.

Tests: command composition for both `escape_cgroup` values (assert the exact
string, including `ssh -o BatchMode=yes localhost`); refusal on an unavailable
node **asserting no lease was taken**; reaper releases on a simulated
`{:job_finished, …}` broadcast; boot sweep releases leases whose job is terminal
and flags `lease_expired_job_running`. Plus, for the new scope — and these
should be real process tests, not mocks, since paper reasoning is exactly what
got §2.3 wrong the first time: the rebind actually lands in the job row; a
SIGTERM to the local wrapper's process group leaves the remote alive and the
job non-terminal; the remote's true exit code (use a distinctive non-zero
value) reaches `exit_code` after the local half is killed; the missing-sentinel
path yields the reserved `70`. Use `sleep`/`echo` stand-ins in a temp
`ORCA_JOBS_DIR` — **never a real deploy script.**

**Piece 4 — Tool surface.** Owns: `lib/orca_hub/mcp/tools/deploys.ex`, the
`Deploys` entries in `@categories`/alias in `lib/orca_hub/mcp/tools.ex`, and
`test/orca_hub/mcp/tools/deploys_test.exs`.
Tests (following `test/orca_hub/mcp/tools/jobs_test.exs`): each tool's JSON
schema is well-formed and `required` is honoured; result shapes match §2.5
exactly; `start_deploy` is absent from a non-orchestrator `Tools.list/1` and
present for an orchestrator; a `ToolPolicy` denial refuses it.

**Only Piece 3 touches a shared file (`application.ex`) and only Piece 4 touches
`tools.ex` — one owner each, so parallel workers cannot collide.** No piece
modifies `jobs.ex`, `job_watcher.ex`, `launcher.ex`, or anything in `~/homelab`.

### 2.9 What we should NOT build

1. **Do not turn the deploy scripts' guards into a declarative mask.** Settled,
   and §1.1 re-confirms why: the guards are dependency-ordered, deliberately
   non-uniform in severity (9 abort, 6 warn-only), and their *messages* are the
   product — the gb10 guard prints the literal sudoers line to paste
   [L764-771]. A boolean gate discards ordering, severity and message.
2. **Do not add `##ORCA-STEP` instrumentation to the scripts** (§2.6). The
   shared `banner()` regex already works; the `EXIT`-trap half cannot fire for
   the OrcaHub target anyway.
3. **Do not build a `deploy_targets` DB table.** Three rows that change roughly
   never, no lifecycle, no UI requirement — and it would put host-specific
   private-repo paths in the database. A checked-in map plus a config override
   meets the "add one more without a code change" bar.
4. **Do not build a lease-renewer GenServer** (§2.2). It dies with the very
   restart it exists to survive, and the durable job row already answers the
   liveness question better than a timer can.
5. **Do not change `Jobs.Launcher` to always launch via ssh** (§2.3). One
   caller's cgroup problem should not destabilise every download, build and test
   suite that uses jobs, nor add an sshd dependency to a core primitive.
6. **Do not build a deploy QUEUE.** Refusing a second deploy with a clear
   "held by job X" is correct; silently queueing one behind a 90-minute lease
   invites a deploy firing long after its commit is stale — and the queued
   caller has no way to reconsider.
7. **Do not auto-retry a failed deploy.** Every script is explicitly designed for
   an operator to re-run with `--skip-*` flags after reading the failure. An
   automatic retry would re-run the expensive, already-succeeded stages and could
   re-push images. Report and stop.
8. **Do not let `start_deploy` pass arbitrary argv.** Exact-match allow-list only
   (§2.4) — this is a production-deploy trigger reachable by an LLM.

### 2.10 Follow-up worth filing separately

`OrcaHub.Jobs`' moduledoc claims a job survives "an OrcaHub restart/deploy"
[jobs.ex:12-13, and the `start_job` tool description, tools/jobs.ex:35-36]. Per
§1.3 that is **false for a `systemctl restart` of the local unit** — the default
`KillMode=control-group` takes setsid'd jobs with it. The claim holds for a
BEAM-level restart. Worth correcting in the moduledoc and the tool description
so callers do not over-trust it; a separate change from this design.
