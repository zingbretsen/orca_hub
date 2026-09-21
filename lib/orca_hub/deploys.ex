defmodule OrcaHub.Deploys do
  @moduledoc """
  Orchestration for running a project deploy as a durable `OrcaHub.Jobs` job
  under a mutually-exclusive lease — see `.context/deploy-jobs-design.md`
  §2.2/§2.3/§2.7.

  This module is the only thing that composes a deploy command, takes a
  lease, and launches a job. `OrcaHub.Deploys.Registry` owns *what* may run
  and argument validation; `OrcaHub.Deploys.Leases` owns the mutex;
  `OrcaHub.Deploys.LeaseReaper` owns releasing the lease when the job ends.
  Nothing here touches `OrcaHub.Jobs.Launcher` or `OrcaHub.JobWatcher` — the
  whole cgroup escape below is composed INTO the command string those two
  already know how to run.

  ## Order of operations, and why it is that order

      validate args -> preflight ON THE TARGET NODE -> lease pre-check
        -> create job row -> ACQUIRE LEASE -> rewrite command -> start_job
        -> rebind pid to the remote

  Two rules drive it:

  * **Nothing that can fail cheaply happens after the lease is taken.** A
    typo'd target, a missing script, or an offline node must not hold a
    90-minute mutex (§2.7). Hence the script check runs *before* `acquire`
    — and it runs on the TARGET node, since whether
    `/home/zach/homelab/scripts/deploy-orca-hub.sh` exists is a fact about
    that host, not about whoever called the tool.
  * **Every failure after `acquire` releases the lease.** A failed launch
    that left the lease held would wedge the target until its TTL expired.

  ## Node routing: REFUSE, never re-route

  A deploy is the single most host-specific action in the system (sops keys,
  ssh trust, buildx builder nodes, systemd units). If the target's pinned
  node is unavailable, `start_deploy/2` returns
  `{:error, :node_unavailable, _}` and takes **no lease** — it never falls
  back to the local node. This mirrors `OrcaHub.Cluster.rpc/5`, which
  already refuses rather than falling back, and is a standing product rule,
  not an implementation detail.

  ## The `escape_cgroup` composition (§2.3) — the subtle part

  `deploy-orca-hub.sh` restarts the very systemd unit that launched it. The
  unit's default `KillMode=control-group` SIGTERMs every process in its
  cgroup, and `setsid` does NOT leave a cgroup — so a plainly-launched
  deploy job kills itself at step 7, along with `OrcaHub.Jobs.Launcher`'s
  wrapper, which has no `trap` and therefore never writes its sentinel. The
  measured result is `finalize_crashed` marking a SUCCESSFUL deploy as
  `failed`, with `verify_command` never running (verify is gated on the main
  command exiting 0).

  For a target with `escape_cgroup: true` the command becomes:

  1. a heredoc that writes `<id>.remote.sh` into the shared jobs dir;
  2. `ssh -o BatchMode=yes localhost 'setsid sh <id>.remote.sh …'`, whose
     remote end lands in `user.slice` (`KillUserProcesses=no`) — the one
     escape proven to work here, and the same one the deploy script itself
     uses for its own `sudo systemctl restart`;
  3. a local poll loop that BLOCKS while the remote is alive and no
     sentinel exists, then exits with the remote's own exit code — or the
     reserved `70` when no sentinel was ever written.

  The **remote** half owns `<id>.log` and `<id>.exit`. That works only
  because `PrivateTmp=yes` makes `/tmp` private across the ssh boundary
  while `$HOME` is SHARED — and `OrcaHub.Jobs.Paths` deliberately lives at
  `$HOME/.orca_hub/jobs`. Any experiment here that uses `/tmp` produces a
  false negative; one did, while this was being designed.

  After launch, `job.pid`/`job.pgid` are **rebound to the remote pid**
  (`<id>.remote.pid`). This closes a measured race: between the restart
  killing the local wrapper and the remote finishing, a resumed
  `JobWatcher` would otherwise see pid-gone + no-sentinel and wrongly
  `finalize_crashed`. It works because `/proc` is shared (no PID namespace
  on this unit) and because `JobWatcher` re-reads the job row fresh every
  tick. It also makes `cancel_job` MORE correct: it signals `-pgid`, which
  now names the process group actually doing the work. If the remote pid
  never appears the job is **cancelled and the lease released** rather than
  left silently mis-bound, since an un-rebound job is guaranteed to be
  wrongly `finalize_crashed` at step 7.

  ## What the result fields mean

  `exit_code` is the REMOTE deploy script's own exit code, not ssh's and not
  the wrapper's. `exit_code == 70` is a reserved marker meaning
  "indeterminate — the remote died without writing a sentinel", never a
  script's own status.

  One residual race, worth stating rather than discovering later: when the
  remote dies WITHOUT writing a sentinel, the local half's detection (a 1s
  poll on `/proc/$REMOTE`) is racing `JobWatcher`'s own tick (5s in prod),
  which now sees the REBOUND remote pid gone. If the watcher wins, the job
  is finalized by `finalize_crashed` — same terminal status (`failed`) and a
  more explicit `progress_note`, but no `exit_code: 70`. Losing the race
  therefore costs a diagnostic, never a wrong verdict.
  """

  require Logger

  alias OrcaHub.{Cluster, HubRPC, JobSupervisor, JobWatcher}
  alias OrcaHub.Deploys.{Lease, Leases, Registry}
  alias OrcaHub.Jobs.Paths

  # Reserved "indeterminate" exit code (§2.3): the local poller gave up
  # without a sentinel ever appearing. Deliberately outside the range any of
  # the deploy scripts produce (they exit 0/1/2).
  @indeterminate_exit_code 70

  @default_ssh_host "localhost"

  # The remote writes its pidfile within ~0.5s of the ssh channel opening.
  # 15s is generous; the composed shell script gives up at 20s so the job
  # fails fast on its own even if nobody is polling from the BEAM.
  @remote_pid_timeout_ms 15_000
  @remote_pid_poll_ms 200

  defp remote_pid_timeout_ms,
    do: Application.get_env(:orca_hub, :deploy_remote_pid_timeout_ms, @remote_pid_timeout_ms)

  # `deploy_leases.note` is a plain varchar; keep the argv summary short.
  @lease_note_limit 200

  @doc "PubSub topic the deploy layer announces lease acquisition on."
  def topic, do: "deploys"

  @doc """
  The reserved exit code meaning "no sentinel was ever written" (#{@indeterminate_exit_code}).
  """
  def indeterminate_exit_code, do: @indeterminate_exit_code

  @doc "Path of the remote half's pidfile for `job_id`, alongside the other job files."
  def remote_pid_path(job_id), do: Path.join(Paths.jobs_dir(), "#{job_id}.remote.pid")

  @doc "Path of the generated remote script for `job_id`."
  def remote_script_path(job_id), do: Path.join(Paths.jobs_dir(), "#{job_id}.remote.sh")

  # ── start_deploy ───────────────────────────────────────────────────

  @doc """
  Compose, lease, and launch a deploy for registry key `target`.

  Options:

    * `:flags` — exact flags from the target's `allowed_flags` (default `[]`)
    * `:positional` — the single optional positional (version / git ref)
    * `:session_id` — the session asking, recorded on both job and lease
    * `:note` — free text recorded on the lease
    * `:wake_when_done` — watch the job and wake `:session_id` on a terminal status
    * `:ttl_seconds` — override the target's lease TTL

  Returns `{:ok, result}` where `result` has `:target`, `:config`, `:job`,
  `:lease`, `:argv`, `:command`, `:verify_command`, `:sha` and `:node`, or
  `{:error, reason, details}` with `reason` one of `:unknown_target`,
  `:disallowed_flag`, `:invalid_positional`, `:node_unavailable`,
  `:script_missing`, `:script_not_executable`, `:held`,
  `:lease_expired_job_running`, `:remote_pid_missing`, `:launch_failed`,
  `:job_create_failed` or `:lease_error`.

  Every error path after the lease is acquired releases it again.
  """
  def start_deploy(target, opts \\ [])

  def start_deploy(target, opts) when is_binary(target) do
    with {:ok, config} <- fetch_target(target),
         {:ok, composed} <- compose(target, config, opts),
         {:ok, node} <- resolve_node(config),
         {:ok, info} <- preflight_on(node, config),
         :ok <- check_lease_available(target),
         {:ok, job} <- create_job(target, config, node, composed, info, opts),
         {:ok, lease} <- acquire_lease(target, config, job, composed, opts),
         {:ok, job} <- rewrite_command(job, config, composed, target, lease),
         {:ok, job} <- launch(node, job, target, lease),
         {:ok, job} <- rebind(node, job, config, target, lease) do
      announce(target, job, lease)
      maybe_wake(job, opts)

      {:ok,
       %{
         target: target,
         config: config,
         node: node,
         job: job,
         lease: lease,
         argv: composed.argv,
         command: job.command,
         verify_command: job.verify_command,
         sha: info[:sha]
       }}
    end
  end

  def start_deploy(target, _opts) do
    {:error, :unknown_target, %{target: inspect(target), known_targets: Registry.keys()}}
  end

  defp fetch_target(target) do
    case Registry.fetch(target) do
      {:ok, config} ->
        {:ok, config}

      {:error, :unknown_target} ->
        {:error, :unknown_target, %{target: target, known_targets: Registry.keys()}}
    end
  end

  defp compose(target, config, opts) do
    Registry.build_command(config,
      target: target,
      flags: Keyword.get(opts, :flags) || [],
      positional: Keyword.get(opts, :positional)
    )
  end

  # ── Node resolution — refuse, never re-route ───────────────────────

  defp resolve_node(config) do
    case config[:node] do
      name when is_binary(name) and name != "" ->
        # String.to_atom (not to_existing_atom): a pinned node this BEAM has
        # never seen must be representable as a value so we can REFUSE for
        # it, not raise. Registry values come from code/config, never from
        # tool arguments, so there is no atom-table exposure here.
        {:ok, String.to_atom(name)}

      _ ->
        {:ok, node()}
    end
  end

  @doc """
  Per-node facts `start_deploy/2` needs before it is willing to take a
  lease. Invoked on the TARGET node via `OrcaHub.Cluster.rpc/5` — which is
  also what makes this the node-availability probe.

  Returns `{:ok, %{sha: sha_or_nil}}`, or the script check's own
  `{:error, :script_missing | :script_not_executable, path}`.
  """
  def preflight(config) do
    with :ok <- Registry.check_script(config) do
      {:ok, %{sha: head_sha(config[:directory])}}
    end
  end

  defp preflight_on(node, config) do
    case Cluster.rpc(node, __MODULE__, :preflight, [config]) do
      {:ok, info} ->
        {:ok, info}

      {:error, kind, path} when kind in [:script_missing, :script_not_executable] ->
        {:error, kind,
         %{
           target_node: Atom.to_string(node),
           command: path,
           hint:
             "The target's deploy script is not present/executable on #{node}. No lease was taken."
         }}

      {:error, reason} ->
        {:error, :node_unavailable, node_unavailable_details(node, reason)}

      other ->
        {:error, :node_unavailable, node_unavailable_details(node, other)}
    end
  end

  defp node_unavailable_details(node, reason) do
    %{
      node: Atom.to_string(node),
      error: inspect(reason),
      hint:
        "The deploy target's assigned node is unavailable. OrcaHub never re-routes a " <>
          "deploy to another node — bring the node back or deploy by hand. No lease was taken."
    }
  end

  # `git rev-parse --short HEAD` in the target's checkout, so the verify
  # command is pinned to the commit that is ACTUALLY being deployed rather
  # than to whatever HEAD happens to be an hour later, when the repo may
  # well have moved on. nil (not a failure) when the directory is not a
  # git checkout — the verify script has its own default.
  defp head_sha(directory) when is_binary(directory) do
    case System.cmd("git", ["-C", directory, "rev-parse", "--short", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> presence()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp head_sha(_), do: nil

  # ── Lease pre-check (§2.2's disagreement table) ────────────────────

  # Refuses BEFORE a job row exists for the two cases `acquire/2` alone
  # would get wrong: a live lease whose job is still running (report who
  # holds it), and an EXPIRED lease whose job is still running — which
  # `acquire/2` would silently reap. §2.2: we do not steal from a
  # demonstrably-alive deploy. A stale lease (job already terminal) is
  # released here so the deploy can proceed.
  defp check_lease_available(target) do
    lease = unreleased_lease(target)
    job = lease && lease.job_id && HubRPC.get_job(lease.job_id)

    case classify(lease, job) do
      :free ->
        :ok

      :in_flight ->
        {:error, :held, held_details(target, lease, job)}

      :lease_expired_job_running ->
        {:error, :lease_expired_job_running,
         Map.put(
           held_details(target, lease, job),
           :hint,
           "#{target}'s lease expired but its job (#{lease.job_id}) is still #{job && job.status}. " <>
             "OrcaHub refuses to steal a lease from a live deploy — cancel the job, or renew the lease."
         )}

      state when state in [:stale_lease, :expired] ->
        # Provably finished (or never-linked) — safe to hand the target on.
        HubRPC.release_deploy_lease(lease.id, lease.job_id)
        :ok
    end
  end

  @doc """
  Classify a lease against its job — §2.2's table, the reason the TTL alone
  is not the liveness signal.

  `:free` (no unreleased lease — including an already-released one, which
  holds nothing), `:in_flight` (live lease, live job), `:stale_lease` (live
  lease, terminal job — safe to release), `:lease_expired_job_running`
  (expired lease, LIVE job — must not be stolen), `:expired` (expired
  lease, terminal/unknown job).
  """
  def classify(lease, job, now \\ nil)

  def classify(nil, _job, _now), do: :free

  # A released lease is DONE, not expired — without this clause it would
  # fall through to the expired branch and a released lease over a running
  # job would be reported as :lease_expired_job_running.
  def classify(%Lease{released_at: released_at}, _job, _now) when not is_nil(released_at),
    do: :free

  def classify(%Lease{} = lease, job, now) do
    now = now || DateTime.utc_now()

    case {Lease.held?(lease, now), job_running?(job)} do
      {true, true} -> :in_flight
      {true, false} -> :stale_lease
      {false, true} -> :lease_expired_job_running
      {false, false} -> :expired
    end
  end

  # The jobs table is the authority, so a lease whose job_id is nil or no
  # longer resolvable counts as NOT running — the alternative (assume the
  # worst, refuse) would make an orphaned lease unfixable until its TTL
  # expired, which is the wedge the TTL exists to avoid. Deploys only ever
  # acquires WITH a job_id, so this is the hand-acquired/deleted-row case.
  defp job_running?(nil), do: false
  defp job_running?(%{status: status}), do: status in ["running", "verifying"]

  defp unreleased_lease(target) do
    target
    |> HubRPC.list_deploy_leases_for_target(%{limit: 25})
    |> Enum.find(&is_nil(&1.released_at))
  end

  defp held_details(target, %Lease{} = lease, job) do
    %{
      target: target,
      held_by: %{
        lease_id: lease.id,
        job_id: lease.job_id,
        session_id: lease.session_id,
        runner_node: lease.runner_node,
        acquired_at: lease.acquired_at,
        expires_at: lease.expires_at,
        job_status: job && job.status,
        note: lease.note
      },
      hint:
        "A deploy is already in flight for #{target}. Poll its job; do not start a second one."
    }
  end

  # ── Job row + lease ────────────────────────────────────────────────

  defp create_job(target, config, node, composed, info, opts) do
    attrs = %{
      session_id: opts[:session_id],
      directory: config[:directory],
      runner_node: Atom.to_string(node),
      label: "deploy #{target}",
      command: composed.command,
      verify_command: verify_command(config, info),
      timeout_seconds: config[:timeout_seconds]
    }

    case HubRPC.create_job(attrs) do
      {:ok, job} ->
        {:ok, job}

      {:error, changeset} ->
        {:error, :job_create_failed, %{target: target, errors: inspect(changeset.errors)}}
    end
  end

  # §2.3: `verify_command` carries the real verdict for a target whose exit
  # code the restart can make ambiguous, so it is pinned to the deployed
  # sha. Opt out per target with `verify_sha: false` in config.
  defp verify_command(config, info) do
    sha = info[:sha]

    case presence(config[:verify_command]) do
      nil ->
        nil

      cmd ->
        if Map.get(config, :verify_sha, true) and is_binary(sha) do
          cmd <> " " <> Paths.shq(sha)
        else
          cmd
        end
    end
  end

  defp acquire_lease(target, config, job, composed, opts) do
    attrs = %{
      job_id: job.id,
      session_id: opts[:session_id],
      runner_node: job.runner_node,
      note: lease_note(composed, opts),
      ttl_seconds: opts[:ttl_seconds] || config[:ttl_seconds] || Leases.default_ttl_seconds()
    }

    case HubRPC.acquire_deploy_lease(target, attrs) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, :held, current} ->
        abandon_job(
          job,
          "Lease for #{target} was taken by another deploy before this one launched."
        )

        job = current && current.job_id && HubRPC.get_job(current.job_id)
        {:error, :held, held_details(target, current, job)}

      {:error, changeset} ->
        abandon_job(job, "Could not acquire the deploy lease for #{target}.")
        {:error, :lease_error, %{target: target, errors: inspect(changeset.errors)}}
    end
  end

  defp lease_note(composed, opts) do
    (presence(opts[:note]) || Enum.join(composed.argv, " "))
    |> String.slice(0, @lease_note_limit)
  end

  # The job row exists but no process was ever launched for it. Park it in a
  # TERMINAL status so JobResumer does not later adopt it and so nothing
  # reports it as a running deploy.
  defp abandon_job(job, note) do
    HubRPC.update_job(job, %{
      status: "cancelled",
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
      progress_note: note
    })
  end

  # ── Command rewrite + launch ───────────────────────────────────────

  # Only now, with the job id in hand, can the escape_cgroup wrapper be
  # composed — it names the job's own log/sentinel/pidfile. Nothing has read
  # the row in between (we hold the lease and the process is not launched
  # until the next step), and `JobSupervisor.start_job/1` re-fetches the row
  # from the DB, so the rewritten command is what actually runs.
  defp rewrite_command(job, config, composed, target, lease) do
    if config[:escape_cgroup] do
      command =
        escape_cgroup_command(job.id, composed.command,
          directory: config[:directory],
          ssh_host: Map.get(config, :ssh_host, @default_ssh_host)
        )

      case HubRPC.update_job(job, %{command: command}) do
        {:ok, job} ->
          {:ok, job}

        {:error, changeset} ->
          release_and_fail(job, lease, :launch_failed, %{
            target: target,
            errors: inspect(changeset.errors)
          })
      end
    else
      {:ok, job}
    end
  end

  defp launch(node, job, target, lease) do
    case Cluster.rpc(node, JobSupervisor, :start_job, [job.id]) do
      {:ok, started} ->
        {:ok, started}

      other ->
        release_and_fail(job, lease, :launch_failed, %{
          target: target,
          node: Atom.to_string(node),
          error: inspect(other),
          hint: "The deploy never started; its lease has been released."
        })
    end
  end

  defp rebind(node, job, config, target, lease) do
    timeout = remote_pid_timeout_ms()

    if config[:escape_cgroup] do
      case Cluster.rpc(node, __MODULE__, :await_remote_pid, [job.id, timeout], timeout + 5_000) do
        {:ok, pid} -> apply_rebind(job, pid, target, lease)
        other -> rebind_failed(node, job, target, lease, other)
      end
    else
      {:ok, job}
    end
  end

  defp apply_rebind(job, pid, target, lease) do
    case HubRPC.update_job(job, %{pid: pid, pgid: pid}) do
      {:ok, job} ->
        Logger.info("[Deploys] #{target} job #{job.id} rebound to remote pid #{pid}")
        {:ok, job}

      {:error, changeset} ->
        cancel_job(job)

        release_and_fail(job, lease, :remote_pid_missing, %{
          target: target,
          remote_pid: pid,
          errors: inspect(changeset.errors),
          hint: "Could not rebind the job to its remote pid; the deploy was cancelled."
        })
    end
  end

  # An un-rebound escape_cgroup job is GUARANTEED to be wrongly
  # `finalize_crashed` the moment the deploy restarts the unit, so leaving it
  # running would manufacture the exact false negative this feature exists to
  # prevent. Cancel loudly instead.
  defp rebind_failed(node, job, target, lease, reason) do
    Logger.error(
      "[Deploys] #{target} job #{job.id}: remote pid never appeared (#{inspect(reason)}) — cancelling"
    )

    cancel_job(job)

    release_and_fail(job, lease, :remote_pid_missing, %{
      target: target,
      node: Atom.to_string(node),
      job_id: job.id,
      remote_pid_path: remote_pid_path(job.id),
      error: inspect(reason),
      hint:
        "The ssh/remote half never reported a pid, so the job could not be rebound to it. " <>
          "An un-rebound deploy job is wrongly marked failed the moment the deploy restarts " <>
          "this host, so the job was cancelled and the lease released. Check sshd/BatchMode " <>
          "access to the target host and retry."
    })
  end

  defp cancel_job(job) do
    node = Cluster.runner_node_for(job)
    Cluster.rpc(node, JobSupervisor, :cancel_job, [job.id])
  rescue
    _ -> :ok
  end

  defp release_and_fail(job, lease, reason, details) do
    HubRPC.release_deploy_lease(lease.id, lease.job_id)
    {:error, reason, Map.put(details, :job_id, job.id)}
  end

  # ── Post-launch bookkeeping ────────────────────────────────────────

  # Cluster-wide PubSub, so a deploy started from an agent node still
  # reaches the hub-only LeaseReaper without this module needing to know
  # which node that is.
  defp announce(target, job, lease) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      topic(),
      {:deploy_lease_acquired, job.id, lease.id, target}
    )
  end

  defp maybe_wake(job, opts) do
    if opts[:wake_when_done] == true and job.session_id do
      HubRPC.watch_job(job.session_id, job.id)
    end

    :ok
  end

  # ── Remote pid ─────────────────────────────────────────────────────

  @doc """
  Poll `<id>.remote.pid` until the remote half reports its pid, up to
  `timeout_ms`. Runs ON the job's node (the file lives in that node's jobs
  dir), so it is invoked via `OrcaHub.Cluster.rpc/5`.
  """
  def await_remote_pid(job_id, timeout_ms \\ @remote_pid_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_remote_pid(remote_pid_path(job_id), deadline)
  end

  defp do_await_remote_pid(path, deadline) do
    case read_pid(path) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@remote_pid_poll_ms)
          do_await_remote_pid(path, deadline)
        end
    end
  end

  defp read_pid(path) do
    with {:ok, content} <- File.read(path),
         {pid, _rest} <- content |> String.trim() |> Integer.parse(),
         true <- pid > 0 do
      {:ok, pid}
    else
      _ -> :error
    end
  end

  # ── escape_cgroup command composition ──────────────────────────────

  @doc """
  Compose the `escape_cgroup: true` command for `job_id` (§2.3).

  `inner_command` is the already-shell-quoted deploy invocation from
  `OrcaHub.Deploys.Registry.build_command/2`. Options: `:directory` (the
  remote `cd` target) and `:ssh_host` (default `#{@default_ssh_host}`).

  Pure — takes no lease, touches no DB, writes nothing. The returned string
  is what `OrcaHub.Jobs.Launcher` persists as the job's `<id>.cmd.sh` and
  runs with stdout/stderr already pointed at `<id>.log`.

  Layout of the returned script:

    * a quoted heredoc writes `<id>.remote.sh` — quoted so the deploy
      command inside is passed through VERBATIM, with no expansion by the
      local shell (a third level of quoting is exactly how this kind of
      composition goes wrong);
    * `ssh … 'setsid sh <id>.remote.sh < /dev/null > <id>.log 2>&1 & sleep 0.5'`
      — the redirect lives in the ssh command line, not inside the remote
      script, so the long-lived remote process never inherits ssh's stdout
      and ssh cannot hang waiting for it to close;
    * a bounded wait for `<id>.remote.pid`, then the blocking poll
      `[ ! -f <sentinel> ] && [ -d /proc/$REMOTE ]` — the `/proc` half is
      what stops the poller spinning forever when the remote is cancelled
      without ever writing a sentinel;
    * `exit` with the remote's own code, or `#{@indeterminate_exit_code}`
      when no sentinel was written.
  """
  def escape_cgroup_command(job_id, inner_command, opts \\ []) do
    directory = Keyword.get(opts, :directory) || Paths.jobs_dir()
    ssh_host = Keyword.get(opts, :ssh_host) || @default_ssh_host

    remote_sh = remote_script_path(job_id)
    pidfile = remote_pid_path(job_id)
    sentinel = Paths.sentinel_path(job_id)
    log = Paths.log_path(job_id)

    remote_script = """
    echo $$ > #{Paths.shq(pidfile)}
    cd #{Paths.shq(directory)} || exit #{@indeterminate_exit_code}
    #{inner_command}
    rc=$?
    printf '%s' "$rc" > #{Paths.shq(sentinel <> ".tmp")}
    mv #{Paths.shq(sentinel <> ".tmp")} #{Paths.shq(sentinel)}
    """

    remote_launch =
      "setsid sh #{Paths.shq(remote_sh)} < /dev/null > #{Paths.shq(log)} 2>&1 & sleep 0.5"

    """
    # OrcaHub deploy job #{job_id} — escape_cgroup (.context/deploy-jobs-design.md §2.3).
    # The REMOTE half (user.slice, via ssh) owns the log and the exit sentinel;
    # this local half only blocks on them so the job does not finish instantly,
    # and is expected to be SIGTERMed by the deploy's own `systemctl restart`.
    ORCA_REMOTE_SH=#{Paths.shq(remote_sh)}
    ORCA_PIDFILE=#{Paths.shq(pidfile)}
    ORCA_SENTINEL=#{Paths.shq(sentinel)}

    rm -f "$ORCA_REMOTE_SH" "$ORCA_PIDFILE" "$ORCA_SENTINEL"

    cat > "$ORCA_REMOTE_SH" <<'ORCA_REMOTE_EOF'
    #{String.trim_trailing(remote_script)}
    ORCA_REMOTE_EOF

    ssh -o BatchMode=yes #{ssh_host} #{Paths.shq(remote_launch)} < /dev/null

    # Bounded wait for the remote to report its pid (20s; the BEAM-side
    # rebind gives up sooner and cancels, this is the standalone backstop).
    ORCA_REMOTE=
    ORCA_TRIES=0
    while [ -z "$ORCA_REMOTE" ] && [ "$ORCA_TRIES" -lt 100 ]; do
      if [ -s "$ORCA_PIDFILE" ]; then
        ORCA_REMOTE=$(cat "$ORCA_PIDFILE")
      else
        sleep 0.2
      fi
      ORCA_TRIES=$((ORCA_TRIES + 1))
    done

    # 1s, not a leisurely poll: once the remote dies WITHOUT a sentinel this
    # loop's exit is racing JobWatcher's own tick, which sees the (rebound)
    # remote pid gone and would finalize_crashed instead of reporting 70.
    while [ ! -f "$ORCA_SENTINEL" ] && [ -n "$ORCA_REMOTE" ] && [ -d "/proc/$ORCA_REMOTE" ]; do
      sleep 1
    done

    if [ -f "$ORCA_SENTINEL" ]; then
      ORCA_RC=$(cat "$ORCA_SENTINEL")
    else
      ORCA_RC=#{@indeterminate_exit_code}
    fi
    case "$ORCA_RC" in
      '' | *[!0-9]*) ORCA_RC=#{@indeterminate_exit_code} ;;
    esac
    exit "$ORCA_RC"
    """
  end

  # ── In-flight reporting (§2.2's conjunction) ───────────────────────

  @doc """
  Every target that currently has an unreleased lease, classified against
  its job per `classify/3`. `target` filters to one key.

  Each entry: `:target`, `:state`, `:lease`, `:job`, `:seconds_remaining`.
  `:expired` entries (expired lease, terminal/unknown job) are included —
  they are not in flight, but they ARE unreleased, which is exactly what a
  sweep or an operator needs to see.
  """
  def in_flight(target \\ nil) do
    now = DateTime.utc_now()

    target
    |> sweepable_targets()
    |> Enum.flat_map(fn t ->
      case unreleased_lease(t) do
        nil ->
          []

        lease ->
          job = lease.job_id && HubRPC.get_job(lease.job_id)

          [
            %{
              target: t,
              state: classify(lease, job, now),
              lease: lease,
              job: job,
              seconds_remaining: max(DateTime.diff(lease.expires_at, now), 0)
            }
          ]
      end
    end)
  end

  # Registry keys cover every target this module can ever lease; live-lease
  # targets are unioned in so a target dropped from the registry mid-flight
  # is still reconciled rather than orphaned.
  #
  # KNOWN GAP, CONSCIOUSLY ACCEPTED — written down so it is not an accident
  # somebody rediscovers. A lease is enumerable here only via its target,
  # because `OrcaHub.Deploys.Leases` exposes no "every unreleased lease"
  # query: `list_live/0` deliberately excludes EXPIRED ones. So an
  # unreleased-AND-expired lease whose target is no longer in the registry
  # is in neither set and nothing ever visits it.
  #
  # Accepted because the practical impact is small on three counts: every
  # lease `start_deploy/2` takes names a registry target; an expired lease
  # for a target still IN the registry IS visited; and such a row is
  # already excluded from `list_live/0`, so it blocks nothing — if the
  # target ever comes back, `Leases.acquire/2` reaps it in the same
  # transaction as the new insert. The cost is a stale audit row, not a
  # wedged target.
  #
  # To close it properly: a `list_unreleased/0` on the lease context (Piece
  # 1's file) plus a `HubRPC` entry, then sweep rows instead of targets.
  defp sweepable_targets(nil) do
    (Registry.keys() ++ Enum.map(HubRPC.list_live_deploy_leases(), & &1.target))
    |> Enum.uniq()
  end

  defp sweepable_targets(target) when is_binary(target), do: [target]

  @doc "PubSub topic for a deploy's job — the same topic `OrcaHub.JobWatcher` broadcasts on."
  def job_topic(job_id), do: JobWatcher.topic(job_id)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
