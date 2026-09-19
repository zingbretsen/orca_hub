defmodule OrcaHub.ChurnSampler do
  @moduledoc """
  Periodic churn sampling GenServer for ORCAHUB3-44.

  Runs only on hub nodes (registered in `Application.hub_children/1` next to
  `OrcaHub.SessionHeartbeat`) and samples every non-archived `status:
  "running"` session every 120 seconds, computing churn metrics via
  `OrcaHub.Sessions.Churn.assess/5` and persisting them to the
  `churn_samples` table.

  ## Sample structure

  Each sample captures:
    - Activity metrics from `Sessions.activity_metadata/1` (tool call counts)
    - Commit info from `Sessions.git_head_info/1`, deduped by
      `{runner_node, directory}` exactly like
      `SessionHeartbeat.Digest.fetch_last_commits/1` — one `git log` per
      distinct working directory, not one per session
    - Session progress state (progress_updated_at)
    - File-surgery evidence from `Sessions.FileSurgery.fetch_many/2` (see
      below) and, for a session that has some, what
      `Sessions.SurgeryAlertPolicy` would decide about alerting on it
    - Churn assessment from `Sessions.Churn.assess/5`

  ## File surgery: the observability gap this sampler used to have (ORCAHUB3-66)

  Until 2026-09-19 `run_sweep/1` called `Churn.assess/3` — the arity-3 form,
  in which `file_surgery` takes its `nil` default — so **this sampler never
  computed file surgery at all**, and `churn_samples` never carried a
  qualitative detection. `churn_suspected` was true 0 times in 1,480 samples
  over the same weeks in which 229 file-surgery alerts were delivered from
  `AlertEvaluator`, which was the only caller that passed evidence.

  **Every `churn_samples` row written before that date has a void
  `churn_suspected`** — see `OrcaHub.Sessions.ChurnSample`'s moduledoc for the
  full warning and for how to identify those rows (`file_surgery_suspected IS
  NULL`, not a date filter).

  It now computes evidence with the BATCHED `FileSurgery.fetch_many/2` — one
  query for the whole sweep, not one per session — and passes it explicitly to
  `Churn.assess/5`. `Churn.assess_with_detail/4` would do the same job but
  issues an N+1 of single `FileSurgery.fetch/2` calls, which is the wrong
  shape for a job that runs every 120s over every running session.

  The `SurgeryAlertPolicy` decision is recorded too, and it is the reason the
  migration exists: ORCAHUB3-66 suppresses ~31% of file-surgery alerts, and a
  suppressed alert would otherwise leave NO TRACE ANYWHERE, since the only
  record of an alert has always been the DELIVERED message. Only a session
  that actually has evidence pays for that decision (it costs a
  `ChurnDetail.fetch/1` and, when D6 does not already decide, a `git ls-files`
  on the session's own node), so the common no-detection case adds nothing
  beyond the one batched query.

  ## Telemetry hook (ORCAHUB3-36)

  Emits `[:orca_hub, :churn, :sample]` per sample with:
    - measurements: churn metric values (tool_calls_15m, distinct_tools_15m, etc.)
    - metadata: `%{session_id:, churn_suspected:, file_surgery_suspected:,
      file_surgery_kind:, surgery_alert_decision:}`

  The last three are ORCAHUB3-66 additions. An exporter written against the
  old two-key metadata keeps working; one that wants to chart suppression
  rate can group on `surgery_alert_decision`.

  This allows Grafana exporters to hook into this event and export metrics.

  ## Error handling

  `run_sweep/1` wraps the whole sweep in `rescue`/log so a single bad
  session can never crash the GenServer — a failed sweep just logs and
  produces no samples, rather than taking down the timer loop.

  ## Worker alerts (ORCAHUB3-44 Phase 2)

  Right after each sampling pass (both the timer-driven `handle_info(:tick,
  _)` and the manual `sweep/0` call), `evaluate_and_deliver_alerts/3` runs
  as a bolted-on second step — it does NOT change `run_sweep/1`'s own
  signature or return value, so every existing sampling test/caller is
  unaffected. It reads every enabled `OrcaHub.AlertSubscriptions` row,
  evaluates conditions against each one's freshly-resolved watched set via
  `OrcaHub.ChurnSampler.AlertEvaluator.evaluate/3` (a delivery-free, directly
  testable module), delivers any resulting alerts through
  `OrcaHub.SessionHeartbeat.deliver_or_queue/2` (the same `:queue` delivery
  path `send_message_to_session` uses), and persists the returned
  rising-edge/cooldown tracking map in this GenServer's own process state
  (`:alert_edge_state`) for the next tick.

  That edge-tracking state is deliberately NOT persisted to disk (only the
  subscription CONFIG is, in the `alert_subscriptions` table) — a deploy or
  crash restart resets it to empty, so at most one already-true condition
  can re-alert immediately after a restart instead of waiting out its
  cooldown. Acceptable per the issue: false negatives (a missed alert)
  would be a real gap, but one extra advisory alert after a restart is not.
  """

  use GenServer
  require Logger

  alias OrcaHub.{Cluster, SessionHeartbeat, Sessions, Sessions.Churn}
  alias OrcaHub.ChurnSampler.AlertEvaluator
  alias OrcaHub.Sessions.{ChurnDetail, FileSurgery, SurgeryAlertPolicy}

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

  @doc """
  Evaluates every enabled `OrcaHub.AlertSubscriptions` row (via
  `AlertEvaluator.evaluate/3`) and delivers any resulting alerts through
  `OrcaHub.SessionHeartbeat.deliver_or_queue/2`. Returns `{:ok, alerts,
  new_edge_state}` — `alerts` is the same list `AlertEvaluator.evaluate/3`
  returns (for callers/tests that want to inspect what fired), and
  `new_edge_state` is what the caller should keep and pass back in on the
  next call.

  A plain function (not a GenServer call) for the same reason `run_sweep/1`
  is: tests drive it directly against fabricated subscriptions/edge_state,
  and the real periodic loop (`handle_info(:tick, _)`/`handle_call(:sweep,
  _)`) threads its own process-state `:alert_edge_state` through it. Never
  raises — a bad subscription or delivery failure is logged and yields
  `{:ok, [], edge_state}` (edge_state unchanged) rather than crashing the
  singleton GenServer and taking every other subscription's alerting down
  with it.

  That `rescue` returning edge_state UNCHANGED cuts two ways. For a
  TRANSIENT failure it's protective: a condition that went true during a
  failed tick isn't recorded as true, so its rising edge survives and
  fires on the next successful tick — no missed edges. For a PERSISTENT
  failure it is the opposite: every tick fails, edge state never
  advances, and NOTHING EVER FIRES AGAIN, indefinitely, with a log line
  as the only trace.

  That outage is undetectable by observation, because "no alerts" is this
  system's historical baseline (`churn_samples.churn_suspected` has been
  true 0 times in 1480 samples, and only 3 `[Worker alert]` messages have
  ever been delivered — see `churn_signal_mining.md`). There is no
  anomaly for an operator to notice.

  Therefore EVERY contributor to `AlertEvaluator.evaluate/3` must fail
  closed to a neutral value LOCALLY. Do not rely on this outer rescue —
  it does not degrade alerting, it silently ends it. `deliver_alert/1`
  already has its own rescue, so single-delivery failures are contained;
  the gap is specifically inside `evaluate/3` and whatever it calls.
  """
  def evaluate_and_deliver_alerts(edge_state \\ %{}) do
    {alerts, new_edge_state} = AlertEvaluator.evaluate(nil, DateTime.utc_now(), edge_state)
    Enum.each(alerts, &deliver_alert/1)
    {:ok, alerts, new_edge_state}
  rescue
    e ->
      Logger.error(
        "Churn sampler: alert evaluation failed - #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:ok, [], edge_state}
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{alert_edge_state: %{}}}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:ok, samples} = run_sweep()
    {:ok, _alerts, new_edge_state} = evaluate_and_deliver_alerts(state.alert_edge_state)
    {:reply, {:ok, samples}, %{state | alert_edge_state: new_edge_state}}
  end

  @impl true
  def handle_info(:tick, state) do
    run_sweep()
    {:ok, _alerts, new_edge_state} = evaluate_and_deliver_alerts(state.alert_edge_state)
    schedule_tick()
    {:noreply, %{state | alert_edge_state: new_edge_state}}
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
    file_surgery_map = fetch_all_file_surgery(session_ids)

    samples =
      Enum.map(sessions, fn session ->
        activity = Map.get(activity_map, session.id, %{})
        commit_info = Map.get(commit_info_map, session.id)
        file_surgery = Map.get(file_surgery_map, session.id)

        churn_result =
          Churn.assess(activity, session, commit_info, DateTime.utc_now(), file_surgery)

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
          churn_suspected: Map.get(churn_result, :churn_suspected, false),
          file_surgery_suspected: Map.get(churn_result, :file_surgery_suspected, false),
          file_surgery_kind: file_surgery_kind(file_surgery),
          file_surgery_path: file_surgery_path(file_surgery),
          surgery_alert_decision: surgery_alert_decision(session, file_surgery)
        }
      end)

    {count, _} = Sessions.insert_churn_samples(samples)
    Logger.info("Churn sampler: persisted #{count} samples")

    Enum.each(samples, &emit_sample_telemetry/1)

    {pruned, _} = Sessions.prune_churn_samples(@prune_days)
    Logger.info("Churn sampler: pruned #{pruned} samples older than #{@prune_days} days")

    {:ok, samples}
  end

  # ONE query for the whole sweep — `fetch_many/2` is the batched shape, and
  # at a 120s cadence over every running session an N+1 of `FileSurgery.fetch/2`
  # (which is what `Churn.assess_with_detail/4` would give us) is not
  # affordable. The 10-minute window matches AlertEvaluator's, so the
  # sampler and the alert path are looking at the same evidence.
  #
  # Never raises: `fetch_many/2` rescues internally and guarantees a key per
  # requested id, so a DB failure degrades to "no evidence anywhere" rather
  # than losing the entire sweep to `run_sweep/1`'s outer rescue.
  defp fetch_all_file_surgery(session_ids) do
    FileSurgery.fetch_many(session_ids, window_minutes: 10)
  end

  # `FileSurgery` evidence carries `:kind` as an ATOM (`:write_to_tracked`,
  # `:programmatic_write`, …) and `Sessions.insert_churn_samples/1` uses
  # `insert_all`, which dumps values straight through the schema's field types
  # with NO casting — an atom in a `:string` column raises `Ecto.ChangeError`
  # and, via `run_sweep/1`'s outer rescue, discards the entire sweep. Convert
  # here, not at the schema.
  defp file_surgery_kind(%{kind: kind}) when is_atom(kind) and not is_nil(kind),
    do: Atom.to_string(kind)

  defp file_surgery_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp file_surgery_kind(_evidence), do: nil

  defp file_surgery_path(%{path: path}) when is_binary(path), do: path
  defp file_surgery_path(_evidence), do: nil

  # What `SurgeryAlertPolicy` WOULD decide about alerting on this detection,
  # persisted so a suppressed detection leaves a durable trace. This sampler
  # does not deliver alerts (`AlertEvaluator` does, and re-derives its own
  # decision there) — this column is the record, not the mechanism.
  #
  # Encoding, matching the schema's moduledoc:
  #   nil            -> not evaluated
  #   "alert"        -> policy would deliver
  #   "suppress:..." -> policy would suppress, with `decide/2`'s reason
  #
  # `nil` is returned for a session with no evidence (there is nothing to
  # decide about) AND on the failure path. Those two are still tellable apart
  # in the row, because `file_surgery_suspected` is `true` only in the second
  # case — a detection with a nil decision means the decision itself failed.
  defp surgery_alert_decision(_session, nil), do: nil

  defp surgery_alert_decision(session, evidence) do
    case SurgeryAlertPolicy.decide_for_session(session, evidence, ChurnDetail.fetch(session.id)) do
      :alert -> "alert"
      {:suppress, reason} -> "suppress:#{reason}"
      _ -> nil
    end
  rescue
    e ->
      # Fail closed to "not recorded" for THIS session only. The outer rescue
      # in `run_sweep/1` would discard the whole sweep, which is a far worse
      # trade for an observability field.
      Logger.warning(
        "Churn sampler: surgery alert decision failed for session #{session.id} - " <>
          Exception.message(e)
      )

      nil
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

  # Best-effort: a delivery failure to one orchestrator must never stop the
  # rest of this tick's alerts from going out, and must never crash this
  # singleton GenServer.
  defp deliver_alert(%{orchestrator_session_id: session_id, message: message} = alert) do
    case SessionHeartbeat.deliver_or_queue(session_id, message) do
      {:error, reason} ->
        Logger.warning(
          "Churn sampler: alert delivery to session #{session_id} failed " <>
            "(condition: #{alert.condition}): #{inspect(reason)}"
        )

      _ok_or_queued ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "Churn sampler: alert delivery to session #{session_id} raised - " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
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
      churn_suspected: sample.churn_suspected,
      file_surgery_suspected: sample.file_surgery_suspected,
      file_surgery_kind: sample.file_surgery_kind,
      surgery_alert_decision: sample.surgery_alert_decision
    }

    :telemetry.execute([:orca_hub, :churn, :sample], measurements, metadata)
  end
end
