defmodule OrcaHub.SessionHeartbeat do
  @moduledoc """
  Manages periodic heartbeat messages for sessions.

  Sessions can schedule heartbeats via MCP tools. The heartbeat sends
  a configurable message to the session at a regular interval. This is
  useful for orchestrator sessions that need to periodically wake up
  and check on sub-tasks or external events.

  Heartbeats are ephemeral (in-memory only) and automatically cancelled
  when the session is archived or deleted.

  State is `%{heartbeats: %{session_id => entry}, lifecycle_snapshots: %{session_id => snapshot}}`:
  `heartbeats` is the scheduled-timer state described above; `lifecycle_snapshots`
  is an unrelated small cache used by `lifecycle_snapshot_changed?/2` (see its doc)
  to de-dupe `SessionRunner`'s automatic "[Session lifecycle] ... is now idle"
  parent notifications — colocated here only because it reuses this module's
  `Digest.changed?/2` and needs the same hub-authoritative, cross-node-reachable
  home (this GenServer is hub-only; agent nodes reach it via `HubRPC.call/3`).
  """
  use GenServer
  require Logger

  alias OrcaHub.Cluster
  alias OrcaHub.SessionHeartbeat.Digest

  @min_interval_seconds 30

  # Statuses `send_heartbeat/2` will deliver to immediately.
  @deliverable_statuses ["idle", "ready", "error", "waiting"]

  # Status broadcasts (atoms, as put on the "sessions" PubSub topic - see
  # `SessionRunner.broadcast/2` and `Sessions.archive_session/1`) that mark a
  # turn having ended - a good moment to flush a queued heartbeat delivery.
  @turn_end_statuses [:idle, :ready, :error, :waiting]

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedule a heartbeat for a session. Idempotent - updates existing heartbeat
  (also resets any `only_if_changed` change-tracking state and any pending
  queued-while-running delivery from a prior schedule).

  `opts` (all optional):
    - `:watch_session_ids` - session ids to auto-digest into each fire
    - `:watch_children` - also auto-digest the caller's non-archived children,
      resolved fresh at fire time
    - `:only_if_changed` - skip delivering a fire when nothing watched changed
      since the previous fire (no-op when there's no watch list)

  Returns :ok on success, {:error, reason} on failure.
  """
  def schedule(session_id, interval_seconds, message, opts \\ %{}) do
    GenServer.call(__MODULE__, {:schedule, session_id, interval_seconds, message, opts})
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

  @doc """
  Whether `snapshot` (a `{status, progress_phase, progress_note}` tuple)
  differs from the last snapshot recorded for `session_id` via this same
  function. Always records `snapshot` as the new baseline regardless of the
  answer - the same "level-triggered" semantics `only_if_changed` heartbeats
  use (`Digest.changed?/2`), so repeated "nothing new" checks keep
  suppressing until something genuinely changes, and the very next call
  after a real change goes back to suppressing again.

  Used by `SessionRunner`'s automatic `[Session lifecycle]` idle notification
  (ORCAHUB3-26 item 5) to gate on real content instead of firing on every
  running->idle transition. Deliberately excludes message/activity timestamps
  from the compared snapshot: unlike a heartbeat watching an unrelated
  session over a timer (where "no new messages in N minutes" is itself
  meaningful), a completed turn on THIS session always produces at least one
  new message, so including that dimension here would make the check never
  suppress anything.
  """
  def lifecycle_snapshot_changed?(session_id, snapshot) do
    GenServer.call(__MODULE__, {:lifecycle_snapshot_changed?, session_id, snapshot})
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Subscribe to session events to auto-cancel on archive/delete and to
    # flush queued heartbeat deliveries at turn end.
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    {:ok, %{heartbeats: %{}, lifecycle_snapshots: %{}}}
  end

  @impl true
  def handle_call({:schedule, session_id, interval_seconds, message, opts}, _from, state) do
    if interval_seconds < @min_interval_seconds do
      {:reply, {:error, "Interval must be at least #{@min_interval_seconds} seconds"}, state}
    else
      # Cancel existing timer if any
      heartbeats = cancel_timer(state.heartbeats, session_id)

      interval_ms = interval_seconds * 1000
      timer_ref = Process.send_after(self(), {:heartbeat, session_id}, interval_ms)

      new_entry = %{
        interval_seconds: interval_seconds,
        interval_ms: interval_ms,
        message: message,
        timer_ref: timer_ref,
        scheduled_at: DateTime.utc_now(),
        watch_session_ids: Map.get(opts, :watch_session_ids, []),
        watch_children: Map.get(opts, :watch_children, false),
        only_if_changed: Map.get(opts, :only_if_changed, false),
        last_snapshot: nil,
        pending_delivery: nil
      }

      Logger.info("Scheduled heartbeat for session #{session_id}: every #{interval_seconds}s")

      {:reply, :ok, %{state | heartbeats: Map.put(heartbeats, session_id, new_entry)}}
    end
  end

  @impl true
  def handle_call({:cancel, session_id}, _from, state) do
    if Map.has_key?(state.heartbeats, session_id) do
      heartbeats = state.heartbeats |> cancel_timer(session_id) |> Map.delete(session_id)
      Logger.info("Cancelled heartbeat for session #{session_id}")
      {:reply, :ok, %{state | heartbeats: heartbeats}}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get, session_id}, _from, state) do
    case Map.get(state.heartbeats, session_id) do
      nil -> {:reply, nil, state}
      entry -> {:reply, Map.drop(entry, [:timer_ref, :last_snapshot]), state}
    end
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    result =
      Enum.map(state.heartbeats, fn {id, entry} ->
        {id, Map.drop(entry, [:timer_ref, :last_snapshot])}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:lifecycle_snapshot_changed?, session_id, snapshot}, _from, state) do
    prior = Map.get(state.lifecycle_snapshots, session_id)
    changed? = Digest.changed?(prior, snapshot)
    lifecycle_snapshots = Map.put(state.lifecycle_snapshots, session_id, snapshot)

    {:reply, changed?, %{state | lifecycle_snapshots: lifecycle_snapshots}}
  end

  @impl true
  def handle_info({:heartbeat, session_id}, state) do
    case Map.get(state.heartbeats, session_id) do
      nil ->
        # Heartbeat was cancelled
        {:noreply, state}

      %{interval_ms: interval_ms} = entry ->
        %{deliver?: deliver?, message: full_message, snapshot: snapshot} =
          build_fire(session_id, entry)

        entry =
          if deliver? do
            case send_heartbeat(session_id, full_message) do
              {:queued, queued_status} ->
                %{
                  entry
                  | pending_delivery: %{message: full_message, queued_status: queued_status}
                }

              _delivered_or_dropped ->
                %{entry | pending_delivery: nil}
            end
          else
            Logger.debug(
              "Skipping heartbeat for session #{session_id} (only_if_changed: no watched changes)"
            )

            entry
          end

        # Schedule next heartbeat
        timer_ref = Process.send_after(self(), {:heartbeat, session_id}, interval_ms)
        new_entry = %{entry | timer_ref: timer_ref, last_snapshot: snapshot}

        {:noreply, %{state | heartbeats: Map.put(state.heartbeats, session_id, new_entry)}}
    end
  end

  # Status broadcasts on the "sessions" PubSub topic - `{session_id, {:status,
  # atom}}`, from `SessionRunner.broadcast/2` and `Sessions.archive_session/1`/
  # `delete_session/1`. Handles auto-cancelling on archive/delete (item 4) and
  # flushing a heartbeat queued while the session was running (item 2).
  @impl true
  def handle_info({session_id, {:status, status}}, state) do
    handle_status_broadcast(session_id, status, state)
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:auto_cancel, session_id}, state) do
    if Map.has_key?(state.heartbeats, session_id) do
      Logger.info("Auto-cancelling heartbeat for missing session #{session_id}")
      {:noreply, drop_session(state, session_id)}
    else
      {:noreply, state}
    end
  end

  @doc false
  # Resolves the watch digest and delivery decision for one fire, given the
  # session's stored heartbeat entry. Pulled out of handle_info/2 so the
  # decision logic is testable without driving the GenServer's real timer.
  def build_fire(session_id, entry) do
    {digest, snapshot} =
      Digest.build(session_id, entry[:watch_session_ids] || [], entry[:watch_children] || false)

    deliver? =
      not (entry[:only_if_changed] || false) or snapshot == %{} or
        Digest.changed?(entry[:last_snapshot], snapshot)

    full_message = if digest, do: entry.message <> digest, else: entry.message

    %{deliver?: deliver?, message: full_message, snapshot: snapshot}
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp handle_status_broadcast(session_id, status, state) when status in [:archived, :deleted] do
    if Map.has_key?(state.heartbeats, session_id) do
      Logger.info("Auto-cancelling heartbeat for #{status} session #{session_id}")
      {:noreply, drop_session(state, session_id)}
    else
      {:noreply, state}
    end
  end

  defp handle_status_broadcast(session_id, status, state) when status in @turn_end_statuses do
    case Map.get(state.heartbeats, session_id) do
      %{pending_delivery: pending} = entry when not is_nil(pending) ->
        flush_pending_delivery(session_id, pending)
        new_entry = %{entry | pending_delivery: nil}
        {:noreply, %{state | heartbeats: Map.put(state.heartbeats, session_id, new_entry)}}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_status_broadcast(_session_id, _status, state), do: {:noreply, state}

  defp drop_session(state, session_id) do
    heartbeats = state.heartbeats |> cancel_timer(session_id) |> Map.delete(session_id)
    lifecycle_snapshots = Map.delete(state.lifecycle_snapshots, session_id)
    %{state | heartbeats: heartbeats, lifecycle_snapshots: lifecycle_snapshots}
  end

  defp cancel_timer(heartbeats, session_id) do
    case Map.get(heartbeats, session_id) do
      %{timer_ref: ref} when is_reference(ref) ->
        Process.cancel_timer(ref)
        heartbeats

      _ ->
        heartbeats
    end
  end

  # Delivers immediately when the session can receive messages right now;
  # otherwise queues (returns `{:queued, status}`) rather than dropping the
  # fire - a wake to a `:running` session must never interrupt the in-flight
  # turn (see item 2/FR 53f5b223: an unexplained mid-tool-call interrupt led
  # a worker to conclude the orchestrator was fabricating instructions).
  # Queued deliveries are flushed by `handle_status_broadcast/3` once the
  # session's status broadcasts back into a deliverable one.
  defp send_heartbeat(session_id, message) do
    case Cluster.find_session(session_id) do
      {node, session} ->
        cond do
          not is_nil(session.archived_at) ->
            # Session was archived, cancel heartbeat
            GenServer.cast(self(), {:auto_cancel, session_id})
            :dropped

          session.status in @deliverable_statuses ->
            deliver_now(node, session_id, session, message)
            :delivered

          true ->
            Logger.info(
              "Queuing heartbeat for session #{session_id} until turn end (status: #{session.status})"
            )

            {:queued, session.status}
        end

      nil ->
        Logger.warning("Heartbeat target session #{session_id} not found, cancelling")
        GenServer.cast(self(), {:auto_cancel, session_id})
        :dropped
    end
  end

  defp deliver_now(node, session_id, session, message) do
    Logger.info("Sending heartbeat to session #{session_id}")

    # Start the runner if not alive
    unless Cluster.session_alive?(node, session_id) do
      Cluster.start_session(node, session_id, session)
    end

    case Cluster.send_message(node, session_id, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Heartbeat to session #{session_id} failed: #{inspect(reason)}")
    end
  end

  # Re-checks the session fresh (status may have moved on again, or the
  # session may have been archived in the interim - archival already drops
  # `pending_delivery` via `drop_session/2`, but this guards the ordering
  # race defensively) before delivering a queued heartbeat, annotating it so
  # the session understands why an unprompted message just arrived (item 2).
  defp flush_pending_delivery(session_id, %{message: message, queued_status: queued_status}) do
    case Cluster.find_session(session_id) do
      {node, session} ->
        if is_nil(session.archived_at) do
          Logger.info(
            "Delivering queued heartbeat for session #{session_id} now that its turn ended " <>
              "(was queued while status: #{queued_status})"
          )

          deliver_now(node, session_id, session, annotate_queued_message(message, queued_status))
        end

      nil ->
        :ok
    end
  end

  defp annotate_queued_message(message, queued_status) do
    "[Heartbeat - delivered late]\n\nThis heartbeat fired while your session was " <>
      "\"#{queued_status}\", so it couldn't be delivered without interrupting that turn. " <>
      "It was queued and is being delivered now that the turn has ended.\n\n" <> message
  end
end
