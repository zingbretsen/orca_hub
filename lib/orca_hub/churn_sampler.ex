defmodule OrcaHub.ChurnSampler do
  @moduledoc """
  Periodic churn sampling GenServer for ORCAHUB3-44.

  Runs only on hub nodes (registered in `Application.hub_children/1` next to
  `OrcaHub.SessionHeartbeat`) and samples every non-archived `status:
  "running"` session every 120 seconds, computing churn metrics via
  `OrcaHub.Sessions.Churn.assess/4` and persisting them to the
  `churn_samples` table.

  ## Sample structure

  Each sample captures:
    - Activity metrics from `Sessions.activity_metadata/1` (tool call counts)
    - Commit info from `Sessions.git_head_info/1`, deduped by
      `{runner_node, directory}` exactly like
      `SessionHeartbeat.Digest.fetch_last_commits/1` — one `git log` per
      distinct working directory, not one per session
    - Session progress state (progress_updated_at)
    - Churn assessment from `Sessions.Churn.assess/4`

  ## Telemetry hook (ORCAHUB3-36)

  Emits `[:orca_hub, :churn, :sample]` per sample with:
    - measurements: churn metric values (tool_calls_15m, distinct_tools_15m, etc.)
    - metadata: %{session_id: id, churn_suspected: bool}

  This allows Grafana exporters to hook into this event and export metrics.

  ## Error handling

  `run_sweep/1` wraps the whole sweep in `rescue`/log so a single bad
  session can never crash the GenServer — a failed sweep just logs and
  produces no samples, rather than taking down the timer loop.
  """

  use GenServer
  require Logger

  alias OrcaHub.{Cluster, Sessions, Sessions.Churn}

  @interval_seconds 120
  @prune_days 14

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a manual sweep on the running GenServer - used by one-off audits.
  Returns `{:ok, samples}` with the list of samples created.
  """
  def sweep do
    GenServer.call(__MODULE__, :sweep)
  end

  @doc """
  Runs one churn-sampling sweep against an explicit list of session structs
  (or, given `nil`, every non-archived `status: "running"` session) and
  returns `{:ok, samples}`. Persists a row per sample, emits telemetry per
  sample, and prunes samples older than #{@prune_days} days.

  A plain function rather than a GenServer call so tests can pass a fixed
  session list without picking up whatever else happens to be "running" in
  the shared dev DB, and without needing to start a second instance of the
  singleton GenServer. Never raises — a bad session or a DB error is logged
  and yields `{:ok, []}` instead of crashing the caller.
  """
  def run_sweep(sessions \\ nil) do
    sessions = sessions || Sessions.list_running_sessions()

    if Enum.empty?(sessions) do
      {:ok, []}
    else
      do_sweep(sessions)
    end
  rescue
    e ->
      Logger.error("Churn sampler: sweep failed - #{Exception.format(:error, e, __STACKTRACE__)}")
      {:ok, []}
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:ok, samples} = run_sweep()
    {:reply, {:ok, samples}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_sweep()
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp schedule_tick do
    Process.send_after(self(), :tick, @interval_seconds * 1000)
  end

  defp do_sweep(sessions) do
    session_ids = Enum.map(sessions, & &1.id)
    activity_map = Sessions.activity_metadata(session_ids)
    commit_info_map = fetch_all_commit_info(sessions)

    samples =
      Enum.map(sessions, fn session ->
        activity = Map.get(activity_map, session.id, %{})
        commit_info = Map.get(commit_info_map, session.id)
        churn_result = Churn.assess(activity, session, commit_info)

        %{
          session_id: session.id,
          sampled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          session_status: session.status,
          tool_calls_15m: Map.get(churn_result, :tool_calls_15m),
          tool_calls_30m: Map.get(churn_result, :tool_calls_30m),
          distinct_tools_15m: Map.get(churn_result, :distinct_tools_15m),
          distinct_tools_30m: Map.get(churn_result, :distinct_tools_30m),
          repetition_ratio_15m: Map.get(churn_result, :repetition_ratio_15m),
          repetition_ratio_30m: Map.get(churn_result, :repetition_ratio_30m),
          minutes_since_progress_update: Map.get(churn_result, :minutes_since_progress_update),
          minutes_since_last_commit: Map.get(churn_result, :minutes_since_last_commit),
          churn_suspected: Map.get(churn_result, :churn_suspected, false)
        }
      end)

    {count, _} = Sessions.insert_churn_samples(samples)
    Logger.info("Churn sampler: persisted #{count} samples")

    Enum.each(samples, &emit_sample_telemetry/1)

    {pruned, _} = Sessions.prune_churn_samples(@prune_days)
    Logger.info("Churn sampler: pruned #{pruned} samples older than #{@prune_days} days")

    {:ok, samples}
  end

  # Dedupes by {runner_node, directory} so sessions sharing a working
  # directory only trigger one `git log` per directory — mirrors
  # `SessionHeartbeat.Digest.fetch_last_commits/1` /
  # `MCP.Tools.Sessions.fetch_last_commits/1`.
  defp fetch_all_commit_info(sessions) do
    tagged =
      Enum.map(sessions, fn s ->
        {s.id, Cluster.runner_node_for(s) || node(), s.directory}
      end)

    commit_by_pair =
      tagged
      |> Enum.map(fn {_id, node, dir} -> {node, dir} end)
      |> Enum.uniq()
      |> Map.new(fn {node, dir} -> {{node, dir}, fetch_last_commit(node, dir)} end)

    Map.new(tagged, fn {id, node, dir} -> {id, commit_by_pair[{node, dir}]} end)
  end

  defp fetch_last_commit(node, directory) do
    case Cluster.rpc(node, Sessions, :git_head_info, [directory]) do
      %{} = info -> info
      _ -> nil
    end
  end

  defp emit_sample_telemetry(sample) do
    measurements = %{
      tool_calls_15m: sample.tool_calls_15m || 0,
      tool_calls_30m: sample.tool_calls_30m || 0,
      distinct_tools_15m: sample.distinct_tools_15m || 0,
      distinct_tools_30m: sample.distinct_tools_30m || 0,
      repetition_ratio_15m: sample.repetition_ratio_15m || 0.0,
      repetition_ratio_30m: sample.repetition_ratio_30m || 0.0,
      minutes_since_progress_update: sample.minutes_since_progress_update || 0,
      minutes_since_last_commit: sample.minutes_since_last_commit || 0
    }

    metadata = %{
      session_id: sample.session_id,
      churn_suspected: sample.churn_suspected
    }

    :telemetry.execute([:orca_hub, :churn, :sample], measurements, metadata)
  end
end
