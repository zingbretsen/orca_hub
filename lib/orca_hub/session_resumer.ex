defmodule OrcaHub.SessionResumer do
  @moduledoc """
  Auto-resumes sessions orphaned in `status: "running"` by a node restart
  (typically a deploy). When a node dies mid-turn, the session's runner is
  gone but its DB row is stuck at `running` forever — the user previously
  had to notice and manually re-prompt each one.

  Runs on EVERY node (hub + agent). On boot, after a short delay (so it
  never blocks app startup), each node looks for its OWN non-archived
  `running` sessions (`runner_node == Atom.to_string(node())`). At boot no
  `SessionRunner`s exist yet on this node, so — same reasoning
  `OrcaHub.AgentPresence.cleanup_all_stale/0` uses for stale presence files —
  every such row is provably orphaned. Each orphan gets its runner restarted
  and a "[System] ... continue" message sent through the normal
  `Cluster.send_message/3` path, so lifecycle notifications/parent links/etc.
  all behave exactly as if the user had re-prompted it.

  Rails:
    - Own-node sessions only — the DB query is scoped to this node's name;
      never touches another node's sessions (never-reassign rule).
    - One-shot per boot — this is a single delayed check, not a repeating
      timer. If a resumed session goes on to error again, nothing here
      retries it.
    - `waiting`/`compacting` sessions are never touched (`waiting` means
      blocked on user input by design; the DB query only ever selects
      `running`).
    - Defensive: re-checks `SessionSupervisor.session_alive?/1` per session
      right before resuming, in case this check ever runs late enough for a
      runner to already be alive (e.g. something else already resumed it).
    - Toggle: `ORCA_AUTO_RESUME=false` (`config :orca_hub, :auto_resume`)
      disables the whole feature; default is enabled.
    - Agent nodes need `HubRPC`/hub connectivity up before they can query
      anything — if the hub isn't reachable yet at the scheduled check, the
      check is retried with backoff (bounded, ~5 minutes total) instead of
      crashing or giving up on the first try.
    - Resumes are staggered a few seconds apart so a node with many orphans
      doesn't open a burst of CLI processes all at once.
  """

  use GenServer
  require Logger

  alias OrcaHub.{Cluster, HubRPC, Mode, SessionSupervisor}

  @initial_delay_ms 30_000
  @retry_delay_ms 15_000
  @max_retries 20
  @stagger_ms 5_000

  @continue_message "[System] This node restarted while your turn was in progress " <>
                      "(likely a deploy). Review your recent work and continue where " <>
                      "you left off — if your task was already complete, just re-send " <>
                      "your final report/summary."

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether auto-resume is enabled (`ORCA_AUTO_RESUME=false` to disable, default on)."
  def enabled? do
    Application.get_env(:orca_hub, :auto_resume, true)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      Process.send_after(self(), :check, @initial_delay_ms)
    end

    {:ok, %{retries: 0}}
  end

  @impl true
  def handle_info(:check, state) do
    cond do
      hub_reachable?() ->
        resume_orphans()
        {:noreply, state}

      state.retries < @max_retries ->
        Process.send_after(self(), :check, @retry_delay_ms)
        {:noreply, %{state | retries: state.retries + 1}}

      true ->
        Logger.warning(
          "SessionResumer: giving up, hub still unreachable after #{@max_retries} retries"
        )

        {:noreply, state}
    end
  end

  # -------------------------------------------------------------------
  # Decision logic (pure — no DB/registry access) — kept separate so tests
  # can exercise it directly without a live runner/DB.
  # -------------------------------------------------------------------

  @doc """
  Is this session an orphan we should resume? `alive?` is whatever
  `SessionSupervisor.session_alive?/1` reports for it right now — the
  defensive re-check described in the moduledoc. The DB query this is
  normally paired with already restricts to `status == "running"` on this
  node, but the status check here still guards against a stale/misused
  caller passing something else through.
  """
  def resumable?(%{status: status}, alive?) when is_boolean(alive?) do
    status == "running" and not alive?
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp hub_reachable? do
    if Mode.hub?() do
      true
    else
      Enum.any?(Node.list(), fn n ->
        try do
          :erpc.call(n, Mode, :hub?, [], 5_000)
        catch
          _, _ -> false
        end
      end)
    end
  end

  defp resume_orphans do
    node_name = Atom.to_string(node())

    orphans =
      node_name
      |> HubRPC.list_running_sessions_for_node()
      |> Enum.filter(&resumable?(&1, SessionSupervisor.session_alive?(&1.id)))

    unless orphans == [] do
      Logger.info(
        "SessionResumer: resuming #{length(orphans)} orphaned running session(s) on #{node_name}"
      )
    end

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      orphans
      |> Enum.with_index()
      |> Enum.each(fn {session, index} ->
        if index > 0, do: Process.sleep(@stagger_ms)
        resume_session(session)
      end)
    end)
  end

  @doc false
  def resume_session(session) do
    Logger.info("SessionResumer: resuming orphaned session #{session.id}")

    case Cluster.send_message(node(), session.id, @continue_message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "SessionResumer: failed to resume session #{session.id}: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "SessionResumer: crashed resuming session #{session.id}: " <> Exception.message(e)
      )
  end
end
