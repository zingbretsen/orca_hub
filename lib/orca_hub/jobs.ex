defmodule OrcaHub.Jobs do
  @moduledoc """
  Context for the Jobs subsystem (ORCAHUB3-25): durable records of
  detached, OS-level background processes.

  ## Why this exists

  Long-running work launched as a child of the agent CLI process dies with
  it — 15-minute idle teardown (`SessionRunner`), `Streaming.WarmPool` LRU
  eviction, a runtime kill-switch downgrade, an OrcaHub restart/deploy, or
  even a graceful `send_message_to_session` interrupt. A job fixes this by
  never depending on OrcaHub staying up: the OS process is always launched
  fully DETACHED (`OrcaHub.Jobs.Launcher` — new session via `setsid`, own
  process group, stdout+stderr to a durable log file, exit code written to a
  durable sentinel file via an atomic rename), and this `jobs` table is the
  durable record of it. The BEAM only ever OBSERVES a job via a disposable
  per-node `OrcaHub.JobWatcher` (`OrcaHub.JobSupervisor`) that polls the
  sentinel/pid/declared progress metric on an interval and writes what it
  sees back into this table — no class of job depends on any particular
  watcher process, or even the BEAM itself, surviving.

  On boot, `OrcaHub.JobResumer` re-attaches watchers to every non-terminal
  job this node owns (`runner_node == node()`), exactly mirroring
  `OrcaHub.SessionResumer`'s treatment of orphaned `running` sessions — the
  detached process was never touched by the restart, only the watcher was.

  ## Two design invariants (from real field-report incidents — see the
  motivating issue, ORCAHUB3-25, for the full write-ups)

  - **The job declares its progress metric; OrcaHub never infers one.** A
    worker that switched from a single curl to 8 ranged curls left a
    `.partial` file frozen at 1.67GB while real progress accumulated across
    `.part0`-`.part7` — any generic watcher would have reported a healthy
    46GB download as dead. `progress_kind`/`progress_path`/
    `progress_expect_bytes`/`progress_command` are declarable AND
    re-declarable mid-flight (`update_job_progress_metric` MCP tool) for
    exactly this reason — see `OrcaHub.Jobs.Progress`.
  - **OrcaHub never adjudicates "stalled."** It surfaces
    `progress_updated_at` age; the calling agent judges whether that's
    healthy or not for the work it declared.

  ## Status ladder

  `running -> verifying -> succeeded | failed | verification_failed |
  timed_out | cancelled`. `verifying` is only entered when the main command
  exits 0 AND a `verify_command` was given — verification lives INSIDE the
  job so a consumer woken on "done" gets a VERIFIED artifact by
  construction, never a merely-present one. See `OrcaHub.Jobs.Job`'s
  moduledoc for how `pid`/`pgid`/`exit_code`/`verify_exit_code` map across
  phases.

  ## Routing

  Jobs are routed by `runner_node`, exactly like sessions/terminals — all DB
  access from a job-owning node goes through `OrcaHub.HubRPC`, never a
  direct `OrcaHub.Repo` call, so this context works identically whether
  called from the hub or an agent node.
  """

  import Ecto.Query
  alias OrcaHub.{Repo, Jobs.Job}

  def get_job(id), do: Repo.get(Job, id)
  def get_job!(id), do: Repo.get!(Job, id)

  def create_job(attrs) do
    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert()
  end

  def update_job(%Job{} = job, attrs) do
    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Non-terminal jobs owned by `node_name` (a string, matching `runner_node`)
  — the query `OrcaHub.JobResumer` uses on boot to find jobs whose watcher
  died with this node and needs re-attaching.
  """
  def list_nonterminal_jobs_for_node(node_name) do
    Repo.all(
      from j in Job,
        where: j.runner_node == ^node_name and j.status in ^Job.nonterminal_statuses()
    )
  end

  @doc """
  List jobs, most recently updated first, optionally filtered by
  `session_id` and/or `status`, capped at `limit` (default 50, max 200).
  """
  def list_jobs(opts \\ %{}) do
    limit = opts |> Map.get(:limit, 50) |> normalize_limit()

    Job
    |> maybe_filter_session(opts[:session_id])
    |> maybe_filter_status(opts[:status])
    |> order_by(desc: :updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_session(query, nil), do: query
  defp maybe_filter_session(query, session_id), do: where(query, [j], j.session_id == ^session_id)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [j], j.status == ^status)

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 200)
  defp normalize_limit(_), do: 50
end
