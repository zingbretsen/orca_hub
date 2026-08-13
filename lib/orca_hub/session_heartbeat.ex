defmodule OrcaHub.SessionHeartbeat do
  @moduledoc """
  Manages periodic heartbeat messages for sessions.

  Sessions can schedule heartbeats via MCP tools. The heartbeat sends
  a configurable message to the session at a regular interval. This is
  useful for orchestrator sessions that need to periodically wake up
  and check on sub-tasks or external events.

  Heartbeats are ephemeral (in-memory only) and automatically cancelled
  when the session is archived or deleted.

  ## `send_message_to_session` `:queue` delivery (ORCAHUB3-29)

  `deliver_or_queue/2` backs `Cluster.send_message/4`'s `:queue` delivery
  mode — the third standalone "pending, keyed independently, flushed at
  turn end" feature alongside `pending_delivery` (heartbeats) and
  `job_watches` above, tracked in `message_queue`. Unlike a heartbeat fire
  (which drops/auto-cancels against an archived or vanished target — there's
  nothing left to ping), a `:queue`-delivered message always still WANTS
  delivery, so it's held (accumulating, not replacing, since multiple
  messages can queue behind the same busy turn) and flushed, annotated,
  once the turn ends. A turn that never ends would otherwise queue forever
  — `@queue_escalate_ms` after the first message in a batch queues, an
  escalation timer forces the whole batch through as a real `:interrupt`
  delivery instead, so `:queue` trades "might wait" for "might wait
  indefinitely," never the latter alone.

  ## Job wakes (ORCAHUB3-26 item 1)

  A heartbeat's timer is a backstop, not the only way to fire. `schedule/4`
  accepts `:watch_job_ids`/`:wake_on` so a scheduled heartbeat can also wake
  EARLY the moment a watched `OrcaHub.Jobs` job reaches a terminal status
  (`succeeded`/`failed`/`verification_failed`/`timed_out`/`cancelled` — a job
  passing through `verifying` does NOT wake anything; see `OrcaHub.Jobs`'s
  verify-before-terminal invariant). `watch_job/2` is the standalone
  equivalent for `start_job`'s `wake_when_done` — it works WITHOUT a
  heartbeat ever being scheduled, tracked independently per job_id so
  multiple simultaneous `wake_when_done` jobs on one session each resolve on
  their own rather than clobbering each other. Both paths subscribe to
  `OrcaHub.JobWatcher.topic/1` and both re-use `send_heartbeat/2`/
  `flush_pending_delivery/2` — a wake to a `:running` session queues and
  flushes at turn end exactly like a timer fire, never a second delivery
  mechanism.

  State is `%{heartbeats: %{session_id => entry}, lifecycle_snapshots: %{session_id => snapshot}, job_watches: %{job_id => watch}, subscribed_job_ids: MapSet.t()}`:
  `heartbeats` is the scheduled-timer state described above (entries also
  carry `watch_job_ids`/`wake_on`/`job_results` for the job-wake feature);
  `lifecycle_snapshots` is an unrelated small cache used by
  `lifecycle_snapshot_changed?/2` (see its doc) to de-dupe `SessionRunner`'s
  automatic "[Session lifecycle] ... is now idle" parent notifications —
  colocated here only because it reuses this module's `Digest.changed?/2`
  and needs the same hub-authoritative, cross-node-reachable home (this
  GenServer is hub-only; agent nodes reach it via `HubRPC.call/3`);
  `job_watches` holds the standalone (non-timer) `watch_job/2` watches, keyed
  by job_id so each resolves independently; `subscribed_job_ids` de-dupes
  `Phoenix.PubSub.subscribe/2` calls against a job's topic.
  """
  use GenServer
  require Logger

  alias OrcaHub.{Backend, Cluster, Jobs, JobWatcher}
  alias OrcaHub.SessionHeartbeat.Digest

  @min_interval_seconds 30

  # deliver_message_now/3's bounded retry count (initial attempt + 2 retries)
  # for the check-then-act race documented on that function: no artificial
  # delay between attempts, because each retry re-runs Cluster.send_message's
  # own fresh aliveness check + restart-if-needed (deliver_message/3's
  # `ensure_started`), which is exactly what heals the race - not a matter of
  # waiting for something to settle. Bounded so a session that's genuinely,
  # persistently gone (not just mid-teardown) fails fast instead of retrying
  # forever.
  @delivery_max_attempts 3

  # Statuses `send_heartbeat/2` (and `deliver_or_queue/2`) will deliver to
  # immediately.
  @deliverable_statuses ["idle", "ready", "error", "waiting"]

  # ORCAHUB3-29 escape hatch: how long a `:queue`-delivered message batch may
  # sit waiting on a still-running turn before it's force-delivered as a real
  # `:interrupt` instead of queuing forever. Matches SessionRunner's own
  # @idle_timeout_ms (15 min) - "generous enough that a normal turn finishes
  # first" is the same bar that constant was picked against.
  @queue_escalate_ms 15 * 60 * 1000

  # Status broadcasts (atoms, as put on the "sessions" PubSub topic - see
  # `SessionRunner.broadcast/2` and `Sessions.archive_session/1`) that mark a
  # turn having ended - a good moment to flush a queued heartbeat delivery.
  @turn_end_statuses [:idle, :ready, :error, :waiting]

  # Job statuses that count as "finished" for wake purposes - anything NOT
  # in `Jobs.Job.nonterminal_statuses/0` (running/verifying). A job mid
  # verify_command must not wake anything - see OrcaHub.Jobs moduledoc.
  defp job_terminal?(status), do: status not in Jobs.Job.nonterminal_statuses()

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
    - `:watch_job_ids` - `OrcaHub.Jobs` job ids to wake EARLY for, on top of
      the normal timer (which keeps firing as the backstop). A job passing
      through `verifying` does not count - only a terminal status does.
    - `:wake_on` - `"any"` (default; fire as soon as ONE watched job reaches
      a terminal status) or `"all"` (fire once every watched job has). Either
      way this is a ONE-SHOT early wake: once it fires, the watch list is
      cleared and the timer resets to a fresh full interval - it does not
      re-arm for a later reschedule of the same jobs.

  Returns :ok on success, {:error, reason} on failure.
  """
  def schedule(session_id, interval_seconds, message, opts \\ %{}) do
    GenServer.call(__MODULE__, {:schedule, session_id, interval_seconds, message, opts})
  end

  @doc """
  Standalone job wake, independent of `schedule/4` - the backing call for
  `start_job`'s `wake_when_done`. Works with NO heartbeat ever scheduled for
  `session_id`: requiring one first is exactly the ceremony that makes
  agents skip it. Each `job_id` resolves on its own (tracked separately, not
  merged into a shared any/all watch list), so multiple simultaneous
  `wake_when_done` jobs on the same session each deliver independently
  rather than the first one finishing silently cancelling the others.

  Delivery goes through the same queue-while-running/flush-at-turn-end path
  as a timer heartbeat. Idempotent per job_id - a second call while the
  first is still pending just replaces it (there is exactly one thing to
  say about a job: how it finished).
  """
  def watch_job(session_id, job_id) do
    GenServer.call(__MODULE__, {:watch_job, session_id, job_id})
  end

  @doc """
  Delivers `message` to `session_id` under ORCAHUB3-29's `:queue` semantics
  (backs `Cluster.send_message/4`'s `:queue` mode) — never interrupts.

  Delivers immediately (via `Cluster.send_message/4`'s `:interrupt` mode,
  which is a no-op distinction once nothing is actually running) if the
  session is archived, isn't currently mid-turn, or its backend can steer
  (`Backend.capabilities_for/1`'s `steering` flag - pi only, today - covers
  "lands mid-turn, cancels nothing", so there's no destructive cost left to
  avoid by waiting). Otherwise the message is appended to a per-session
  queue and flushed, annotated, once the turn ends (see the moduledoc); a
  turn that never ends escalates to a forced `:interrupt` delivery after
  `@queue_escalate_ms` instead of queuing forever.

  Returns `:ok | {:error, :not_found} | {:error, reason} | {:queued, status}`.
  """
  def deliver_or_queue(session_id, message) do
    GenServer.call(__MODULE__, {:deliver_or_queue, session_id, message})
  end

  @doc false
  # Test seam (mirrors get/1's role for heartbeats): inspects the raw
  # message_queue entry for session_id without going through the
  # deliver/flush machinery. Lets tests grab `escalate_ref` to simulate an
  # escalation firing early instead of waiting out @queue_escalate_ms.
  def peek_message_queue(session_id) do
    GenServer.call(__MODULE__, {:peek_message_queue, session_id})
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

    {:ok,
     %{
       heartbeats: %{},
       lifecycle_snapshots: %{},
       job_watches: %{},
       subscribed_job_ids: MapSet.new(),
       message_queue: %{}
     }}
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
      watch_job_ids = Map.get(opts, :watch_job_ids, [])

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
        pending_delivery: nil,
        watch_job_ids: watch_job_ids,
        wake_on: Map.get(opts, :wake_on, "any"),
        job_results: %{}
      }

      Logger.info("Scheduled heartbeat for session #{session_id}: every #{interval_seconds}s")

      state = %{state | heartbeats: Map.put(heartbeats, session_id, new_entry)}
      state = ingest_job_ids(session_id, watch_job_ids, state)

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:deliver_or_queue, session_id, message}, _from, state) do
    case Cluster.find_session(session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {node, session} ->
        cond do
          # Unlike a heartbeat (which drops + auto-cancels against an
          # archived target - see send_heartbeat/2), a directed message
          # still wants delivery: send_message_to_session's contract is
          # that messaging an archived session auto-unarchives it (see
          # SessionRunner's start_running/start_streaming), so route it
          # through immediately rather than queuing behind a turn that, by
          # definition, isn't the live one anymore.
          not is_nil(session.archived_at) ->
            {:reply, deliver_message_now(node, session_id, message), state}

          session.status in @deliverable_statuses ->
            {:reply, deliver_message_now(node, session_id, message), state}

          Backend.capabilities_for(session).steering ->
            {:reply, deliver_message_now(node, session_id, message), state}

          true ->
            {:reply, {:queued, session.status},
             enqueue_message(state, session_id, message, session.status)}
        end
    end
  end

  @impl true
  def handle_call({:peek_message_queue, session_id}, _from, state) do
    {:reply, Map.get(state.message_queue, session_id), state}
  end

  @impl true
  def handle_call({:watch_job, session_id, job_id}, _from, state) do
    state = subscribe_job(job_id, state)

    watch = %{session_id: session_id, pending_delivery: nil}
    state = %{state | job_watches: Map.put(state.job_watches, job_id, watch)}

    state =
      case Jobs.get_job(job_id) do
        %{status: status} = job ->
          if job_terminal?(status),
            do: apply_standalone_job_watch(state, job_id, job),
            else: state

        nil ->
          state
      end

    {:reply, :ok, state}
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
      entry -> {:reply, Map.drop(entry, [:timer_ref, :last_snapshot, :job_results]), state}
    end
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    result =
      Enum.map(state.heartbeats, fn {id, entry} ->
        {id, Map.drop(entry, [:timer_ref, :last_snapshot, :job_results])}
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

  # `OrcaHub.JobWatcher.broadcast_finished/1` - a job we're watching (via
  # `watch_job_ids`/`wake_on` or standalone `watch_job/2`) just reached a
  # terminal status. Re-fetches the job row for its exit code(s)/label since
  # the broadcast itself only carries the status. A job we were never asked
  # to watch (already resolved, or this process restarted mid-watch) is a
  # harmless no-op on both paths below.
  @impl true
  def handle_info({:job_finished, job_id, _status}, state) do
    state = unsubscribe_job(job_id, state)

    state =
      case Jobs.get_job(job_id) do
        nil ->
          state

        job ->
          state
          |> apply_job_result_to_all_watchers(job_id, job)
          |> apply_standalone_job_watch(job_id, job)
      end

    {:noreply, state}
  end

  # ORCAHUB3-29 escape hatch: the turn a queued message batch was waiting on
  # hasn't ended @queue_escalate_ms after the FIRST message in the batch was
  # queued. Force it through as a real :interrupt instead of queuing
  # forever. `ref` guards against a stale timer: if the batch already
  # flushed normally (flush_message_queue/2 cancels the timer, but
  # Process.cancel_timer/1 can't retract a message already in this
  # process's mailbox) or was replaced, the entry is gone or has a
  # different ref, and this is a silent no-op.
  @impl true
  def handle_info({:queue_escalate, session_id, ref}, state) do
    case Map.get(state.message_queue, session_id) do
      %{escalate_ref: ^ref} = entry ->
        Logger.warning(
          "Escalating #{length(entry.messages)} queued message(s) for session #{session_id} " <>
            "to :interrupt delivery - turn did not end within #{@queue_escalate_ms}ms of " <>
            "queuing (see ORCAHUB3-29)"
        )

        deliver_queued_messages(session_id, entry, :escalated_after_timeout)
        {:noreply, %{state | message_queue: Map.delete(state.message_queue, session_id)}}

      _ ->
        {:noreply, state}
    end
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
    # drop_session/2 itself is a safe no-op against any of these three maps
    # missing session_id - the has_key? guard here is purely to skip the log
    # line (and the pointless map churn) when there's truly nothing to drop.
    # A message_queue-only session (queued while running, no heartbeat ever
    # scheduled) must still be checked here, or its entry - and escalate
    # timer - would leak forever: unlike an archived/deleted TARGET at
    # delivery time (deliver_or_queue/2's own archived check routes that
    # case through immediate delivery instead), this is the sender-side
    # session itself going away mid-queue, so there's nothing left to
    # deliver to.
    if Map.has_key?(state.heartbeats, session_id) or
         Map.has_key?(state.message_queue, session_id) do
      Logger.info("Auto-cancelling heartbeat/queued messages for #{status} session #{session_id}")
      {:noreply, drop_session(state, session_id)}
    else
      {:noreply, state}
    end
  end

  defp handle_status_broadcast(session_id, status, state) when status in @turn_end_statuses do
    state =
      state
      |> flush_heartbeat_pending(session_id)
      |> flush_standalone_job_watches(session_id)
      |> flush_message_queue(session_id)

    {:noreply, state}
  end

  defp handle_status_broadcast(_session_id, _status, state), do: {:noreply, state}

  defp flush_heartbeat_pending(state, session_id) do
    case Map.get(state.heartbeats, session_id) do
      %{pending_delivery: pending} = entry when not is_nil(pending) ->
        flush_pending_delivery(session_id, pending)
        new_entry = %{entry | pending_delivery: nil}
        %{state | heartbeats: Map.put(state.heartbeats, session_id, new_entry)}

      _ ->
        state
    end
  end

  # Standalone `watch_job/2` watches are one-shot: flush whichever of THIS
  # session's watches are queued, then drop them (a delivered job wake has
  # nothing left to say). Watches still waiting on their job (pending_delivery
  # still nil) are untouched - a turn ending is not evidence their job is done.
  defp flush_standalone_job_watches(state, session_id) do
    {to_flush, remaining} =
      Enum.split_with(state.job_watches, fn {_job_id, w} ->
        w.session_id == session_id and not is_nil(w.pending_delivery)
      end)

    Enum.each(to_flush, fn {_job_id, w} ->
      flush_pending_delivery(session_id, w.pending_delivery)
    end)

    %{state | job_watches: Map.new(remaining)}
  end

  defp drop_session(state, session_id) do
    heartbeats = state.heartbeats |> cancel_timer(session_id) |> Map.delete(session_id)
    lifecycle_snapshots = Map.delete(state.lifecycle_snapshots, session_id)

    job_watches =
      state.job_watches
      |> Enum.reject(fn {_job_id, w} -> w.session_id == session_id end)
      |> Map.new()

    case Map.get(state.message_queue, session_id) do
      nil -> :ok
      entry -> cancel_escalate(entry)
    end

    %{
      state
      | heartbeats: heartbeats,
        lifecycle_snapshots: lifecycle_snapshots,
        job_watches: job_watches,
        message_queue: Map.delete(state.message_queue, session_id)
    }
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

    # `Cluster.send_message/4` already re-checks aliveness/restarts before
    # its own GenStatem.call, but that's a check-then-act gap, not a lock -
    # the target can still die in the window between the check and the call
    # actually landing (e.g. torn down by whoever spawned this delivery,
    # same class of race its own moduledoc calls out for the not-alive-yet
    # case). A delivery is already documented as best-effort elsewhere in
    # this module (queued/dropped are both normal outcomes) - losing this
    # one to a losing race must not crash the singleton GenServer and take
    # every OTHER session's heartbeats down with it.
    #
    # :interrupt (not :queue): send_heartbeat/2's caller already decided
    # delivery is safe right now (deliverable status, or this IS the
    # post-flush delivery) - routing back through :queue here would either
    # double-queue or just be a no-op-but-wasteful re-check.
    try do
      case Cluster.send_message(node, session_id, message, :interrupt) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Heartbeat to session #{session_id} failed: #{inspect(reason)}")
      end
    catch
      kind, reason ->
        Logger.warning(
          "Heartbeat to session #{session_id} failed (target exited mid-delivery): " <>
            "#{kind} #{inspect(reason)}"
        )
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

  # -------------------------------------------------------------------
  # send_message_to_session :queue delivery (ORCAHUB3-29)
  # -------------------------------------------------------------------

  # "Deliver now" branches of deliver_or_queue/2 already decided delivery is
  # safe (idle-ish status, steerable backend, or an archived target that
  # should auto-unarchive) - :interrupt here just means "now, unconditionally"
  # via the normal path; it's a no-op distinction whenever nothing is
  # actually running. Must NOT be :queue - that would loop back into this
  # same module and either double-queue or (once already queued) no-op.
  #
  # The target runner can go away DURING this call - idle teardown,
  # warm-pool eviction, a kill-switch downgrade, or a caller stopping it -
  # and `SessionRunner.send_message/2`'s `GenStatem.call` surfaces that as a
  # raised GenError (remote) or a process EXIT (local), not a return value.
  # Letting either escape kills THIS GenServer, which owns the whole node's
  # queued-message and heartbeat state, and a few of those in a row exceeds
  # the supervisor's restart intensity and takes the node down with it. A
  # vanished target is an ordinary delivery failure, so report it as one -
  # but not without first retrying: this is a pure check-then-act race (the
  # target was alive a moment ago), not evidence the session is actually
  # unreachable, and `deliver_with_retry/5` below self-heals it by simply
  # trying again (see @delivery_max_attempts). This function is only called
  # from `deliver_or_queue/2`'s synchronous `GenServer.call` handler, so a
  # final `{:error, :delivery_failed}` propagates straight back to the
  # ORIGINAL caller as the call's reply - the caller sees the failure and
  # owns any further retry decision; nothing is queued in this GenServer's
  # own state at this point (unlike the busy-turn branch, which is a
  # different code path entirely - see `enqueue_message/4`).
  defp deliver_message_now(node, session_id, message) do
    deliver_with_retry(node, session_id, message, @delivery_max_attempts, &Cluster.send_message/4)
  end

  @doc false
  # Pulled out of deliver_message_now/3 (same "testable without the real
  # race" motivation as build_fire/2 above) so the retry-then-succeed and
  # retry-then-give-up paths can be pinned deterministically: tests inject a
  # `send_fn` stub that raises/exits a controlled number of times instead of
  # depending on a genuine, timing-dependent teardown race. An ordinary
  # `{:error, reason}` return (e.g. ORCA_MODE=agent's owning node genuinely
  # refusing) is passed through unchanged, exactly as before this retry was
  # added; retrying a deliberate refusal would just be wasted attempts
  # against an outcome that won't change. A raised exception or process EXIT
  # only retries when `retry_decision/1` classifies the reason as
  # UNAMBIGUOUSLY not-delivered (see its doc) - `{:timeout, _}` and anything
  # else is treated as possibly-already-delivered and given up on
  # immediately, never retried.
  def deliver_with_retry(node, session_id, message, attempts_left, send_fn) do
    case send_fn.(node, session_id, message, :interrupt) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    e ->
      {safe?, reason_text} = retry_decision(e)
      continue_or_stop(node, session_id, message, attempts_left, send_fn, safe?, reason_text)
  catch
    :exit, reason ->
      {safe?, reason_text} = retry_decision(reason)
      continue_or_stop(node, session_id, message, attempts_left, send_fn, safe?, reason_text)
  end

  # Classifies a caught failure as safe to retry (the target definitely
  # never received/finished processing the message) or not (`{safe?,
  # human-readable reason text}`).
  #
  # `GenStatem.call/3` monitors the target BEFORE sending the request; if the
  # target is already gone, or dies mid-call, the caller sees a `:DOWN`
  # carrying the target's actual exit reason - and since message order from
  # one sender to one receiver is preserved by the BEAM, that `:DOWN` cannot
  # arrive after a reply the target already sent (though a mid-callback
  # death after partial side effects but before any reply remains a narrow
  # accepted window - see the module's failure-handling notes). So
  # `:noproc` (never existed / already gone), `:normal`/`:shutdown`/
  # `{:shutdown, _}` (exited cleanly mid-call, e.g. idle teardown or a
  # kill-switch downgrade racing this exact delivery) are genuinely
  # "definitely not delivered" - retrying is safe.
  #
  # `{:timeout, _}` is the opposite: the call's OWN timeout fired, which says
  # NOTHING about whether the target already received and started (or even
  # finished) processing the message before the timeout won the race -
  # that's a real possibility with `:interrupt` semantics landing mid-turn.
  # Retrying an ambiguous outcome can double-deliver (a duplicate prompt
  # interrupting the session) - this exact failure class (retrying instead
  # of treating an ambiguous outcome as possibly-already-succeeded) is what
  # caused the duplicate fork-child-spawn incident (see project memory
  # project-duplicate-child-spawns-rca). Anything not explicitly recognized
  # gets the same treatment as `{:timeout, _}` - give up rather than guess.
  # inspect/1, not `GenStatem.GenError`'s own `Exception.message/1` - that
  # callback interpolates the raw reason with `"#{reason}"`, which raises
  # `Protocol.UndefinedError` for a tuple reason (exactly the `{:timeout,
  # _}` shape this function exists to classify), producing a confusing
  # fallback wall of text in the log instead of the actual reason.
  defp retry_decision(%GenStatem.GenError{reason: reason}),
    do: {safe_to_retry?(reason), "GenStatem call failed: " <> inspect(reason)}

  defp retry_decision(reason) when is_exception(reason),
    do: {false, Exception.message(reason)}

  defp retry_decision(reason), do: {safe_to_retry?(reason), inspect(reason)}

  # Unwraps the classic `gen`-style `{reason, {Mod, Fun, Args}}` exit shape,
  # in case a raw (non-GenStatem-mediated) `:exit` ever reaches the outer
  # `catch` with that older wrapping intact.
  defp safe_to_retry?({reason, {_mod, _fun, _args}}), do: safe_to_retry?(reason)
  defp safe_to_retry?(:noproc), do: true
  defp safe_to_retry?(:normal), do: true
  defp safe_to_retry?(:shutdown), do: true
  defp safe_to_retry?({:shutdown, _}), do: true
  defp safe_to_retry?(_), do: false

  defp continue_or_stop(node, session_id, message, attempts_left, send_fn, true, reason_text)
       when attempts_left > 1 do
    Logger.warning(
      "[heartbeat] delivery to session #{session_id} failed (#{reason_text}) - retrying, " <>
        "#{attempts_left - 1} attempt(s) left"
    )

    deliver_with_retry(node, session_id, message, attempts_left - 1, send_fn)
  end

  defp continue_or_stop(_node, session_id, _message, _attempts_left, _send_fn, true, reason_text) do
    Logger.warning(
      "[heartbeat] delivery to session #{session_id} failed after " <>
        "#{@delivery_max_attempts} attempt(s), giving up: #{reason_text}"
    )

    {:error, :delivery_failed}
  end

  defp continue_or_stop(_node, session_id, _message, _attempts_left, _send_fn, false, reason_text) do
    Logger.warning(
      "[heartbeat] delivery to session #{session_id} failed with an ambiguous outcome - NOT " <>
        "retrying, since the target may already have received it (#{reason_text})"
    )

    {:error, :delivery_failed}
  end

  # Appends to an existing batch (never replaces - see moduledoc: multiple
  # messages queued behind the same busy turn must ALL be delivered, unlike
  # a heartbeat's single-slot pending_delivery) or starts a new one and arms
  # its escalation timer. The timer is anchored to the FIRST message in a
  # batch, not reset by later arrivals, so a chatty sender can't push the
  # deadline out indefinitely.
  defp enqueue_message(state, session_id, message, queued_status) do
    case Map.get(state.message_queue, session_id) do
      nil ->
        ref = make_ref()
        Process.send_after(self(), {:queue_escalate, session_id, ref}, @queue_escalate_ms)

        entry = %{
          messages: [message],
          queued_status: queued_status,
          queued_at: DateTime.utc_now(),
          escalate_ref: ref
        }

        %{state | message_queue: Map.put(state.message_queue, session_id, entry)}

      entry ->
        entry = %{entry | messages: entry.messages ++ [message]}
        %{state | message_queue: Map.put(state.message_queue, session_id, entry)}
    end
  end

  defp flush_message_queue(state, session_id) do
    case Map.get(state.message_queue, session_id) do
      nil ->
        state

      entry ->
        cancel_escalate(entry)
        deliver_queued_messages(session_id, entry, :turn_ended)
        %{state | message_queue: Map.delete(state.message_queue, session_id)}
    end
  end

  defp cancel_escalate(%{escalate_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  # Re-checks the session fresh (mirrors flush_pending_delivery/2's own
  # re-check comment) before delivering a queued batch, annotating it so the
  # agent understands why an unprompted message just arrived - see
  # ORCAHUB3-29 item 1 / FR 53f5b223. `delivered_because` distinguishes a
  # normal turn-end flush from a forced escalation, since only the latter
  # may actually be cancelling live work and needs to say so.
  defp deliver_queued_messages(session_id, entry, delivered_because) do
    case Cluster.find_session(session_id) do
      {node, session} ->
        if is_nil(session.archived_at) do
          combined = Enum.join(entry.messages, "\n\n\n")

          annotated =
            annotate_queued_send_message(combined, entry.queued_status, delivered_because)

          Logger.info(
            "Delivering #{length(entry.messages)} queued message(s) for session #{session_id} " <>
              "(#{delivered_because}, was queued while status: #{entry.queued_status})"
          )

          try do
            case Cluster.send_message(node, session_id, annotated, :interrupt) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "Queued message delivery to session #{session_id} failed: #{inspect(reason)}"
                )
            end
          catch
            kind, reason ->
              Logger.warning(
                "Queued message delivery to session #{session_id} failed (target exited " <>
                  "mid-delivery): #{kind} #{inspect(reason)}"
              )
          end
        end

      nil ->
        :ok
    end
  end

  defp annotate_queued_send_message(combined, queued_status, :turn_ended) do
    "[Message delivery note]\n\nThis message was sent with queued delivery while your " <>
      "session was \"#{queued_status}\", so it waited rather than interrupting your " <>
      "in-progress turn. It's being delivered now that your turn has ended.\n\n" <> combined
  end

  defp annotate_queued_send_message(combined, queued_status, :escalated_after_timeout) do
    "[Message delivery note - escalated]\n\nThis message was queued while your session " <>
      "was \"#{queued_status}\", but your turn did not end within " <>
      "#{div(@queue_escalate_ms, 60_000)} minutes, so it has been delivered now by " <>
      "interrupting your in-progress work instead of waiting indefinitely. If a tool " <>
      "call was cancelled as a result, its output may be missing or incomplete - this " <>
      "is expected, not a system malfunction.\n\n" <> combined
  end

  # -------------------------------------------------------------------
  # Job wakes (ORCAHUB3-26 item 1)
  # -------------------------------------------------------------------

  defp subscribe_job(job_id, state) do
    if MapSet.member?(state.subscribed_job_ids, job_id) do
      state
    else
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, JobWatcher.topic(job_id))
      %{state | subscribed_job_ids: MapSet.put(state.subscribed_job_ids, job_id)}
    end
  end

  defp unsubscribe_job(job_id, state) do
    Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, JobWatcher.topic(job_id))
    %{state | subscribed_job_ids: MapSet.delete(state.subscribed_job_ids, job_id)}
  end

  # Subscribes to every newly-scheduled watch_job_id and, for any that's
  # ALREADY terminal (the job finished in the gap between it starting and
  # this schedule/4 call), resolves it immediately rather than waiting on a
  # broadcast that job's watcher already sent (and will never send again).
  defp ingest_job_ids(session_id, job_ids, state) do
    Enum.reduce(job_ids, state, fn job_id, state ->
      state = subscribe_job(job_id, state)

      case Jobs.get_job(job_id) do
        %{status: status} = job ->
          if job_terminal?(status),
            do: apply_job_result(state, session_id, job_id, job),
            else: state

        nil ->
          state
      end
    end)
  end

  # Group watch (schedule_heartbeat's watch_job_ids/wake_on): folds `job`'s
  # result into every heartbeat entry currently watching `job_id`.
  defp apply_job_result_to_all_watchers(state, job_id, job) do
    state.heartbeats
    |> Enum.filter(fn {_session_id, entry} -> job_id in (entry.watch_job_ids || []) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reduce(state, fn session_id, state ->
      apply_job_result(state, session_id, job_id, job)
    end)
  end

  defp apply_job_result(state, session_id, job_id, job) do
    case Map.get(state.heartbeats, session_id) do
      %{watch_job_ids: watch_ids} = entry when watch_ids != [] ->
        if job_id in watch_ids do
          results = Map.put(entry.job_results, job_id, job_result_view(job))
          remaining = List.delete(watch_ids, job_id)

          if wake_condition_met?(entry.wake_on, remaining) do
            deliver_job_wake(state, session_id, entry, results)
          else
            new_entry = %{entry | watch_job_ids: remaining, job_results: results}
            %{state | heartbeats: Map.put(state.heartbeats, session_id, new_entry)}
          end
        else
          state
        end

      _ ->
        state
    end
  end

  defp wake_condition_met?("all", remaining_job_ids), do: remaining_job_ids == []
  defp wake_condition_met?(_any, _remaining_job_ids), do: true

  # Delivers (or queues) the early wake and resets the entry: watch list and
  # accumulated results clear (one-shot), and the timer restarts at a fresh
  # full interval so the backstop doesn't fire again moments later on top of
  # this early wake.
  defp deliver_job_wake(state, session_id, entry, results) do
    message = full_wake_message(entry.message, results)

    if is_reference(entry.timer_ref), do: Process.cancel_timer(entry.timer_ref)
    timer_ref = Process.send_after(self(), {:heartbeat, session_id}, entry.interval_ms)

    pending_delivery =
      case send_heartbeat(session_id, message) do
        {:queued, queued_status} -> %{message: message, queued_status: queued_status}
        _delivered_or_dropped -> nil
      end

    new_entry = %{
      entry
      | watch_job_ids: [],
        job_results: %{},
        timer_ref: timer_ref,
        pending_delivery: pending_delivery
    }

    %{state | heartbeats: Map.put(state.heartbeats, session_id, new_entry)}
  end

  # Standalone `watch_job/2` watch: independent of any heartbeat entry, keyed
  # by job_id so simultaneous wake_when_done jobs on one session don't
  # clobber each other. No-op if nothing is watching `job_id` (already
  # resolved, or a process restart lost the watch - the job itself is
  # unaffected either way, only the wake is missed).
  defp apply_standalone_job_watch(state, job_id, job) do
    case Map.get(state.job_watches, job_id) do
      nil ->
        state

      %{session_id: session_id} ->
        message = full_wake_message(nil, %{job_id => job_result_view(job)})

        case send_heartbeat(session_id, message) do
          {:queued, queued_status} ->
            watch = %{
              session_id: session_id,
              pending_delivery: %{message: message, queued_status: queued_status}
            }

            %{state | job_watches: Map.put(state.job_watches, job_id, watch)}

          _delivered_or_dropped ->
            %{state | job_watches: Map.delete(state.job_watches, job_id)}
        end
    end
  end

  defp job_result_view(job) do
    %{
      status: job.status,
      exit_code: job.exit_code,
      verify_exit_code: job.verify_exit_code,
      label: job.label
    }
  end

  defp full_wake_message(nil, results), do: job_wake_digest(results)
  defp full_wake_message(base_message, results), do: base_message <> job_wake_digest(results)

  defp job_wake_digest(results) do
    lines =
      results |> Enum.map(fn {job_id, r} -> format_job_result(job_id, r) end) |> Enum.join("\n")

    "\n\n[Job wake] #{map_size(results)} watched job(s) reached a terminal status:\n" <> lines
  end

  defp format_job_result(job_id, %{status: status} = r) do
    name = if present?(r.label), do: "#{r.label} (#{job_id})", else: job_id
    "- #{name}: status=#{status}#{format_exit(r)}"
  end

  defp format_exit(%{verify_exit_code: nil, exit_code: exit_code}), do: ", exit_code=#{exit_code}"

  defp format_exit(%{verify_exit_code: verify_exit_code, exit_code: exit_code}),
    do: ", exit_code=#{exit_code}, verify_exit_code=#{verify_exit_code}"

  defp present?(str), do: is_binary(str) and String.trim(str) != ""
end
