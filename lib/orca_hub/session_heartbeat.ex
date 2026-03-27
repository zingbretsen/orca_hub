defmodule OrcaHub.SessionHeartbeat do
  @moduledoc """
  Manages periodic heartbeat messages for sessions.

  Sessions can schedule heartbeats via MCP tools. The heartbeat sends
  a configurable message to the session at a regular interval. This is
  useful for orchestrator sessions that need to periodically wake up
  and check on sub-tasks or external events.

  Heartbeats are ephemeral (in-memory only) and automatically cancelled
  when the session is archived or deleted.
  """
  use GenServer
  require Logger

  alias OrcaHub.Cluster

  @min_interval_seconds 30

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedule a heartbeat for a session. Idempotent - updates existing heartbeat.

  Returns :ok on success, {:error, reason} on failure.
  """
  def schedule(session_id, interval_seconds, message) do
    GenServer.call(__MODULE__, {:schedule, session_id, interval_seconds, message})
  end

  @doc """
  Cancel a session's heartbeat.
  """
  def cancel(session_id) do
    GenServer.call(__MODULE__, {:cancel, session_id})
  end

  @doc """
  Get heartbeat info for a session. Returns nil if not scheduled.
  """
  def get(session_id) do
    GenServer.call(__MODULE__, {:get, session_id})
  end

  @doc """
  List all active heartbeats. Returns a list of {session_id, info} tuples.
  """
  def list_all do
    GenServer.call(__MODULE__, :list_all)
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Subscribe to session events to auto-cancel on archive
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:schedule, session_id, interval_seconds, message}, _from, state) do
    if interval_seconds < @min_interval_seconds do
      {:reply, {:error, "Interval must be at least #{@min_interval_seconds} seconds"}, state}
    else
      # Cancel existing timer if any
      state = cancel_timer(state, session_id)

      interval_ms = interval_seconds * 1000
      timer_ref = Process.send_after(self(), {:heartbeat, session_id}, interval_ms)

      new_entry = %{
        interval_seconds: interval_seconds,
        interval_ms: interval_ms,
        message: message,
        timer_ref: timer_ref,
        scheduled_at: DateTime.utc_now()
      }

      Logger.info("Scheduled heartbeat for session #{session_id}: every #{interval_seconds}s")
      {:reply, :ok, Map.put(state, session_id, new_entry)}
    end
  end

  @impl true
  def handle_call({:cancel, session_id}, _from, state) do
    if Map.has_key?(state, session_id) do
      state = cancel_timer(state, session_id)
      Logger.info("Cancelled heartbeat for session #{session_id}")
      {:reply, :ok, Map.delete(state, session_id)}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get, session_id}, _from, state) do
    case Map.get(state, session_id) do
      nil -> {:reply, nil, state}
      entry -> {:reply, Map.drop(entry, [:timer_ref]), state}
    end
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    result =
      Enum.map(state, fn {id, entry} ->
        {id, Map.drop(entry, [:timer_ref])}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_info({:heartbeat, session_id}, state) do
    case Map.get(state, session_id) do
      nil ->
        # Heartbeat was cancelled
        {:noreply, state}

      %{interval_ms: interval_ms, message: message} = entry ->
        # Send the heartbeat message
        send_heartbeat(session_id, message)

        # Schedule next heartbeat
        timer_ref = Process.send_after(self(), {:heartbeat, session_id}, interval_ms)
        new_entry = %{entry | timer_ref: timer_ref}

        {:noreply, Map.put(state, session_id, new_entry)}
    end
  end

  # Auto-cancel heartbeats when sessions are archived
  @impl true
  def handle_info({:session_archived, session_id}, state) do
    if Map.has_key?(state, session_id) do
      Logger.info("Auto-cancelling heartbeat for archived session #{session_id}")
      state = cancel_timer(state, session_id)
      {:noreply, Map.delete(state, session_id)}
    else
      {:noreply, state}
    end
  end

  # Auto-cancel heartbeats when sessions are deleted
  @impl true
  def handle_info({:session_deleted, session_id}, state) do
    if Map.has_key?(state, session_id) do
      Logger.info("Auto-cancelling heartbeat for deleted session #{session_id}")
      state = cancel_timer(state, session_id)
      {:noreply, Map.delete(state, session_id)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:auto_cancel, session_id}, state) do
    if Map.has_key?(state, session_id) do
      Logger.info("Auto-cancelling heartbeat for missing session #{session_id}")
      state = cancel_timer(state, session_id)
      {:noreply, Map.delete(state, session_id)}
    else
      {:noreply, state}
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp cancel_timer(state, session_id) do
    case Map.get(state, session_id) do
      %{timer_ref: ref} when is_reference(ref) ->
        Process.cancel_timer(ref)
        state

      _ ->
        state
    end
  end

  defp send_heartbeat(session_id, message) do
    case Cluster.find_session(session_id) do
      {node, session} ->
        if is_nil(session.archived_at) do
          # Only send if session is in a state that can receive messages
          if session.status in ["idle", "ready", "error", "waiting"] do
            Logger.info("Sending heartbeat to session #{session_id}")

            # Start the runner if not alive
            unless Cluster.session_alive?(node, session_id) do
              Cluster.start_session(node, session_id, session)
            end

            Cluster.send_message(node, session_id, message)
          else
            Logger.debug(
              "Skipping heartbeat for session #{session_id} (status: #{session.status})"
            )
          end
        else
          # Session was archived, cancel heartbeat
          GenServer.cast(self(), {:auto_cancel, session_id})
        end

      nil ->
        Logger.warning("Heartbeat target session #{session_id} not found, cancelling")
        GenServer.cast(self(), {:auto_cancel, session_id})
    end
  end
end
