defmodule OrcaHub.ForkGate do
  @moduledoc """
  Serializes forked pi children's FIRST turns, and detects when one of them
  missed the prompt cache anyway (pi_fork_spec.md §6 / §6.1).

  ## Why this is a correctness mechanism, not an optimization

  Measured on the gb10 llama-server (§1): N CONCURRENT same-prefix first
  turns get 1 warm hit + N−1 FULL cold prefills — checkpoints are slot-local,
  and firing while a sibling is still *generating* also cold-prefills. Under
  §1.1's ship gate ("no caching, no forking"), a fork that cold-prefills its
  inherited history is strictly worse than a plain spawn: it pays full
  prefill for possibly-useless tokens AND craters every co-tenant on a shared
  public endpoint. So the regime has to be ENFORCED, not recommended —
  orchestrator prompt guidance is explicitly not a shippable version of this.

  ## The rule

  A forked child's first prompt is not sent by the spawn path. The child is
  CREATED immediately (ids/links/UI exist) and its prompt is handed here;
  this GenServer owns delivery. **Child N+1's first prompt goes out only
  after child N's first `result` event lands.** "Prefill finished" is NOT
  sufficient (verified §1) — the granularity is a full turn. After its first
  turn each child has its own slot-resident state and needs no further
  coordination, so it is dropped from the gate entirely.

  One FIFO per PARENT session id. Different parents' fan-outs don't gate each
  other (they have different prefixes, so they don't contend for the same
  checkpoint) — only siblings of one parent do.

  Releases are back-to-back with zero think time, which is also what bounds
  §6's other mandate: the parent-idle → last-fork-first-turn window stays a
  function of the work itself, not of orchestrator diligence.

  ## Observing turn completion

  The gate watches the same events `SessionLive.Show` consumes, but
  subscribes to the aggregate `"sessions"` topic rather than per-child
  `"session:<id>"` topics: `SessionRunner.broadcast/2` publishes every payload
  to BOTH, and only the aggregate one carries the session id
  (`{session_id, payload}`) — a bare `"session:<id>"` payload can't be
  attributed when several children are in flight for different parents. The
  subscription is lazy: taken on the first watched child, dropped when
  nothing is being watched, so a node that never forks pays nothing.

  Turn-ending signals, in the order they can arrive:

    * `{:event, %{"type" => "result"}}` — the real signal, and the only one
      carrying the usage numbers §6.1 needs.
    * `{:event, %{"type" => "cli_error"}}` / `{:status, :error}` — the turn
      ended badly; release the next child immediately (§6's error path).
    * `{:status, :idle}` — backstop only. A clean turn always broadcasts
      `result` first, so this fires only if the runner reached idle without
      one (e.g. an interrupted/empty turn); it releases the next child but
      can't run miss detection.

  ## Failure handling (all three of §6's cases)

    * **Child errors mid-first-turn** — an error event ends the turn, so the
      next child is released immediately. The errored child is dropped from
      the gate; a later re-prompt of it does NOT go back through the gate,
      because its first turn is over (a re-prompt of a child whose first turn
      never completed is still gated — it is still the queue's active child
      until `result`/error/timeout).
    * **Child hangs mid-first-turn** — a per-child release timeout
      (`ServingProfile.release_timeout_ms/0`, ~10 min) releases the next child
      and emits a `fork_gate_timeout` warning on BOTH the parent's and the
      child's session topics.
    * **Node restart** — gate state is per-node and IN-MEMORY, by design. A
      restart drops the queue, and `SessionResumer`-recovered children send
      their pending prompts unserialized. This is deliberately not made
      durable: the serialized regime is only worth enforcing for a
      contiguous fan-out, and a queue resurrected minutes later is fanning
      out against a prefix the host-memory cache has very likely already
      evicted anyway. §6.1's per-fork miss detection is what turns that from
      a silent regression into a visible one.

  ## §6.1 cache-miss detection

  Before releasing the next child, the gate inspects the completed child's
  first `result`. `Backend.Pi.accumulate_usage/1` already folds pi's
  per-response `usage.cacheRead`/`usage.input` into it as
  `cache_read_input_tokens` / `input_tokens`; in §1's experiments these
  exactly matched the server's own counters.

    * **Hit** — `cache_read_input_tokens` ≈ parent context size, fresh
      `input_tokens` in the tens.
    * **Miss** — fresh `input_tokens` ≈ parent context size: the child just
      paid full prefill.

  Threshold: `input_tokens > miss_threshold_ratio * parent_context_tokens`
  (0.25 by default), chosen so checkpoint-granularity partial hits (≤8k
  reprocess on this hybrid arch, §1) don't false-positive. `parent_context_tokens`
  comes from the parent's latest `pi_session_stats` `context_usage.tokens`
  via `Sessions.last_context_tokens/1`; when it is unknown (the parent has no
  stats yet) detection is SKIPPED rather than guessed at.

  > Known limitation: `input_tokens` on the synthesized `result` is summed
  > across every assistant response in the turn, so a first turn with a very
  > long tool loop accumulates fresh tokens and can trip the threshold
  > without a genuine cold prefill. The check is deliberately single-sided
  > anyway (a real miss's later rounds DO report large `cache_read`, so
  > requiring low `cache_read` would mask real misses). A false positive
  > costs a warning plus a pause the orchestrator can resume — the safe
  > direction under §1.1.

  On a detected miss the gate: emits a `fork_cache_miss` warning on the
  parent's and child's session topics, annotates the child's synthetic
  `forked_from` marker (§8), and — `ServingProfile.pause_on_miss?/0`, default
  ON — PAUSES the remaining fan-out and notifies the orchestrator with a
  `[Session lifecycle]` message rather than serially paying full prefill for
  every remaining sibling against an evicted prefix. The orchestrator resumes
  (accepting cold cost) or aborts via the `fork_queue` MCP tool.

  ## Serving-profile isolation (§9)

  Serialization, the miss threshold, the release timeout and §7's KV budget
  are llama.cpp-specific and live in `OrcaHub.ForkGate.ServingProfile`. With
  `serialize_first_turns: false` (the `:vllm` profile — its automatic prefix
  caching shares KV blocks across concurrent requests) the gate becomes a
  pass-through that still delivers every first prompt immediately and still
  runs miss detection as a cheap assertion; no fork code changes.
  """

  use GenServer
  require Logger

  alias OrcaHub.{Cluster, HubRPC}
  alias OrcaHub.ForkGate.ServingProfile

  @sessions_topic "sessions"

  # ── Client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hands a forked child's FIRST prompt to the gate instead of sending it.

  Returns `:ok` once the prompt is queued (or delivered, when this parent has
  no child in flight). Never blocks on delivery — the actual
  `Cluster.send_message` runs in a supervised Task.

  Options:

    * `:runner_node` (required) — the node the child runs on. A fork child is
      same-node with its parent (§3), so this is also the parent's node.
    * `:parent_context_tokens` — the parent's last known context size, for
      §6.1. `nil` (the default) skips miss detection for this child.
    * `:server` — target gate process, for tests.
  """
  def enqueue_first_turn(parent_id, child_id, prompt, opts \\ [])
      when is_binary(parent_id) and is_binary(child_id) do
    entry = %{
      parent_id: parent_id,
      child_id: child_id,
      prompt: prompt,
      runner_node: Keyword.get(opts, :runner_node, node()),
      parent_context_tokens: Keyword.get(opts, :parent_context_tokens)
    }

    GenServer.call(server(opts), {:enqueue, entry})
  end

  @doc """
  Resumes a fan-out paused by §6.1's miss detection: releases the next
  pending child immediately, accepting that it may pay a cold prefill.
  """
  def resume(parent_id, opts \\ []) when is_binary(parent_id),
    do: GenServer.call(server(opts), {:resume, parent_id})

  @doc """
  Drops every still-pending first prompt for `parent_id`. The child sessions
  themselves are untouched — they stay created and un-prompted, so the caller
  can prompt (or archive) them by hand. Returns the dropped child ids.
  """
  def abort(parent_id, opts \\ []) when is_binary(parent_id),
    do: GenServer.call(server(opts), {:abort, parent_id})

  @doc """
  Snapshot of one parent's queue: `%{active_child, pending, paused}`, or
  `nil` when this parent has nothing in flight.
  """
  def status(parent_id, opts \\ []) when is_binary(parent_id),
    do: GenServer.call(server(opts), {:status, parent_id})

  @doc "Snapshot of every parent queue currently held on this node."
  def queues(opts \\ []), do: GenServer.call(server(opts), :queues)

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  # ── Server ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       # parent_id => %{pending: [entry], active_child: child_id | nil, paused: nil | map}
       queues: %{},
       # child_id => %{parent_id, parent_context_tokens, timer_ref, gating?}
       watching: %{},
       subscribed?: false,
       deliver: Keyword.get(opts, :deliver, &default_deliver/3),
       notify: Keyword.get(opts, :notify, &default_notify/2)
     }}
  end

  @impl true
  def handle_call({:enqueue, entry}, _from, state) do
    if ServingProfile.serialize_first_turns?() do
      queue = queue_for(state, entry.parent_id)
      queue = %{queue | pending: queue.pending ++ [entry]}

      state =
        state
        |> put_queue(entry.parent_id, queue)
        |> maybe_release(entry.parent_id)

      {:reply, :ok, state}
    else
      # §9: serialization off (vLLM profile) — deliver immediately, but still
      # watch the first turn so miss detection keeps working as an assertion.
      {:reply, :ok, release(state, entry, false)}
    end
  end

  def handle_call({:resume, parent_id}, _from, state) do
    case Map.fetch(state.queues, parent_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, queue} ->
        state = state |> put_queue(parent_id, %{queue | paused: nil}) |> maybe_release(parent_id)
        {:reply, {:ok, snapshot(state.queues[parent_id])}, state}
    end
  end

  def handle_call({:abort, parent_id}, _from, state) do
    case Map.fetch(state.queues, parent_id) do
      :error ->
        {:reply, {:ok, []}, state}

      {:ok, queue} ->
        dropped = Enum.map(queue.pending, & &1.child_id)

        state =
          state
          |> put_queue(parent_id, %{queue | pending: [], paused: nil})
          |> prune_queue(parent_id)

        {:reply, {:ok, dropped}, state}
    end
  end

  def handle_call({:status, parent_id}, _from, state) do
    {:reply, snapshot(state.queues[parent_id]), state}
  end

  def handle_call(:queues, _from, state) do
    {:reply, Map.new(state.queues, fn {parent_id, q} -> {parent_id, snapshot(q)} end), state}
  end

  @impl true
  # Aggregate "sessions" topic: {session_id, payload}. Anything about a
  # session we're not watching is not ours — ignore it cheaply.
  def handle_info({session_id, payload}, state) when is_binary(session_id) do
    case Map.fetch(state.watching, session_id) do
      :error -> {:noreply, state}
      {:ok, watch} -> {:noreply, handle_child_payload(state, session_id, watch, payload)}
    end
  end

  def handle_info({:release_timeout, child_id}, state) do
    case Map.fetch(state.watching, child_id) do
      :error ->
        {:noreply, state}

      {:ok, watch} ->
        Logger.warning(
          "[fork gate] child #{child_id} first turn did not complete within " <>
            "#{ServingProfile.release_timeout_ms()}ms — releasing the next sibling anyway"
        )

        message =
          "Fork gate: child session #{child_id}'s first turn did not complete within " <>
            "#{div(ServingProfile.release_timeout_ms(), 60_000)} minutes. Releasing the next " <>
            "forked sibling anyway — its first turn may cold-prefill (pi_fork_spec.md §6)."

        event = %{
          "type" => "system",
          "subtype" => "fork_gate_timeout",
          "child_session_id" => child_id,
          "parent_session_id" => watch.parent_id,
          "timeout_ms" => ServingProfile.release_timeout_ms(),
          "message" => message
        }

        emit_warning(child_id, event, persist: true)
        emit_warning(watch.parent_id, event, persist: false)

        {:noreply, complete_child(state, child_id, watch, :timeout)}
    end
  end

  def handle_info({:deliver_failed, child_id, reason}, state) do
    case Map.fetch(state.watching, child_id) do
      :error ->
        {:noreply, state}

      {:ok, watch} ->
        Logger.warning(
          "[fork gate] failed to deliver the first prompt to fork child #{child_id}: " <>
            inspect(reason)
        )

        {:noreply, complete_child(state, child_id, watch, :deliver_failed)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Queue mechanics ──────────────────────────────────────────────────

  defp queue_for(state, parent_id) do
    Map.get(state.queues, parent_id, %{pending: [], active_child: nil, paused: nil})
  end

  defp put_queue(state, parent_id, queue),
    do: %{state | queues: Map.put(state.queues, parent_id, queue)}

  # A queue with nothing in flight, nothing pending and no pause to report is
  # just bookkeeping — drop it (and the "sessions" subscription with it, if
  # this was the last one).
  defp prune_queue(state, parent_id) do
    case Map.fetch(state.queues, parent_id) do
      {:ok, %{pending: [], active_child: nil, paused: nil}} ->
        maybe_unsubscribe(%{state | queues: Map.delete(state.queues, parent_id)})

      _ ->
        state
    end
  end

  defp maybe_release(state, parent_id) do
    case Map.fetch(state.queues, parent_id) do
      {:ok, %{active_child: nil, paused: nil, pending: [entry | rest]} = queue} ->
        state
        |> put_queue(parent_id, %{queue | pending: rest, active_child: entry.child_id})
        |> release(entry, true)

      _ ->
        prune_queue(state, parent_id)
    end
  end

  # Registers the child as watched BEFORE delivery is attempted, so no
  # turn-ending event can arrive before we're listening for it. Delivery
  # itself runs off-process: `Cluster.send_message` reaches a GenStatem on a
  # possibly-busy runner, and the gate must never be blocked by one child's
  # slow delivery while other parents' fan-outs wait behind it.
  defp release(state, entry, gating?) do
    timer_ref =
      Process.send_after(
        self(),
        {:release_timeout, entry.child_id},
        ServingProfile.release_timeout_ms()
      )

    watch = %{
      parent_id: entry.parent_id,
      parent_context_tokens: entry.parent_context_tokens,
      timer_ref: timer_ref,
      gating?: gating?
    }

    state = ensure_subscribed(%{state | watching: Map.put(state.watching, entry.child_id, watch)})

    gate = self()
    deliver = state.deliver

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      case deliver.(entry.runner_node, entry.child_id, entry.prompt) do
        {:error, reason} -> send(gate, {:deliver_failed, entry.child_id, reason})
        _ok -> :ok
      end
    end)

    state
  end

  defp default_deliver(runner_node, child_id, prompt) do
    Cluster.send_message(runner_node, child_id, prompt, :queue)
  end

  # ── Child event handling ─────────────────────────────────────────────

  defp handle_child_payload(state, child_id, watch, {:event, %{"type" => "result"} = event}) do
    state
    |> check_cache_hit(child_id, watch, event)
    |> complete_child(child_id, watch, :result)
  end

  defp handle_child_payload(state, child_id, watch, {:event, %{"type" => "cli_error"}}),
    do: complete_child(state, child_id, watch, :error)

  defp handle_child_payload(state, child_id, watch, {:status, :error}),
    do: complete_child(state, child_id, watch, :error)

  # Backstop only — a clean turn broadcasts `result` first, at which point the
  # child is no longer watched and this never runs.
  defp handle_child_payload(state, child_id, watch, {:status, :idle}),
    do: complete_child(state, child_id, watch, :idle)

  defp handle_child_payload(state, _child_id, _watch, _payload), do: state

  # Drops the child from the gate and lets its parent's queue advance. The
  # child is independent from here on: a later re-prompt of it does NOT come
  # back through the gate, because its first turn is over.
  defp complete_child(state, child_id, watch, reason) do
    cancel_timer(watch.timer_ref)
    state = %{state | watching: Map.delete(state.watching, child_id)}

    Logger.debug("[fork gate] child #{child_id} first turn ended (#{reason})")

    if watch.gating? do
      queue = queue_for(state, watch.parent_id)

      state
      |> put_queue(watch.parent_id, %{queue | active_child: nil})
      |> maybe_release(watch.parent_id)
    else
      maybe_unsubscribe(state)
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # ── §6.1 cache-miss detection ────────────────────────────────────────

  defp check_cache_hit(state, child_id, %{parent_context_tokens: parent_tokens} = watch, event)
       when is_number(parent_tokens) and parent_tokens > 0 do
    usage = event["usage"] || %{}
    fresh = usage["input_tokens"] || 0
    cache_read = usage["cache_read_input_tokens"] || 0
    ratio = ServingProfile.miss_threshold_ratio()

    if fresh > ratio * parent_tokens do
      report_miss(state, child_id, watch, fresh, cache_read, parent_tokens, ratio)
    else
      state
    end
  end

  # Parent context size unknown (no pi_session_stats yet) — skip rather than
  # guess: a fabricated baseline would produce fabricated misses.
  defp check_cache_hit(state, _child_id, _watch, _event), do: state

  defp report_miss(state, child_id, watch, fresh, cache_read, parent_tokens, ratio) do
    pending =
      state |> queue_for(watch.parent_id) |> Map.fetch!(:pending) |> Enum.map(& &1.child_id)

    # Nothing left to pause (this was the last sibling) is not a pause — a
    # `paused` flag with an empty queue would just be un-prunable bookkeeping
    # and a pointless interrupt for the orchestrator. The warning still fires.
    pause? = ServingProfile.pause_on_miss?() and watch.gating? and pending != []

    message =
      "Fork cache MISS: child session #{child_id}'s first turn reprocessed #{fresh} fresh " <>
        "input tokens against a parent context of #{parent_tokens} " <>
        "(cache_read #{cache_read}; threshold #{round(ratio * 100)}%). The inherited prefix " <>
        "was NOT served from the prompt cache — this fork cost a full cold prefill " <>
        "(pi_fork_spec.md §6.1)." <>
        if(pause?, do: " Remaining forked siblings are PAUSED.", else: "")

    event = %{
      "type" => "system",
      "subtype" => "fork_cache_miss",
      "child_session_id" => child_id,
      "parent_session_id" => watch.parent_id,
      "parent_context_tokens" => parent_tokens,
      "input_tokens" => fresh,
      "cache_read_input_tokens" => cache_read,
      "threshold_ratio" => ratio,
      "paused" => pause?,
      "message" => message
    }

    Logger.warning("[fork gate] #{message}")

    emit_warning(child_id, event, persist: true)
    emit_warning(watch.parent_id, event, persist: false)
    annotate_fork_marker(child_id, fresh, cache_read, parent_tokens)

    if pause? do
      queue = queue_for(state, watch.parent_id)

      state.notify.(
        watch.parent_id,
        pause_message(watch.parent_id, child_id, fresh, parent_tokens, pending)
      )

      put_queue(state, watch.parent_id, %{
        queue
        | paused: %{reason: :cache_miss, child_id: child_id}
      })
    else
      state
    end
  end

  defp pause_message(parent_id, child_id, fresh, parent_tokens, pending) do
    "[Session lifecycle] Fork fan-out PAUSED for parent session #{parent_id}: child " <>
      "#{child_id}'s first turn was a prompt-cache MISS (#{fresh} fresh input tokens against " <>
      "a #{parent_tokens}-token parent context), so the inherited prefix is no longer cached " <>
      "and every remaining sibling would pay a full cold prefill (pi_fork_spec.md §6.1). " <>
      "#{length(pending)} forked child session(s) are created but un-prompted: " <>
      "#{Enum.join(pending, ", ")}. Call the fork_queue tool with action \"resume\" to send " <>
      "them anyway (accepting the cold cost), or action \"abort\" to drop the queue — aborted " <>
      "children stay created and idle, so you can prompt or archive them yourself."
  end

  # Persist on the CHILD (it is the child's own first turn, and a feed entry
  # that survives reload is the honest record); broadcast-only on the parent,
  # whose durable signal is the [Session lifecycle] message instead. Both are
  # best-effort — a warning that fails to render must never take down the
  # gate or strand the rest of the fan-out.
  defp emit_warning(session_id, event, opts) do
    if Keyword.get(opts, :persist, false) do
      HubRPC.create_message(%{session_id: session_id, data: event})
    end

    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", {:event, event})
    :ok
  rescue
    error ->
      Logger.warning(
        "[fork gate] failed to emit warning on session #{session_id}: " <>
          Exception.format(:error, error)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[fork gate] failed to emit warning on session #{session_id}: " <> inspect(reason)
      )

      :ok
  end

  # §6.1/§8: stamp the outcome onto the child's synthetic `forked_from`
  # marker, so the fork's cache behavior is visible at the top of its feed
  # rather than only in a warning that scrolls away.
  defp annotate_fork_marker(child_id, fresh, cache_read, parent_tokens) do
    HubRPC.annotate_fork_marker(child_id, %{
      "cache_miss" => true,
      "first_turn_input_tokens" => fresh,
      "first_turn_cache_read_tokens" => cache_read,
      "parent_context_tokens" => parent_tokens
    })

    :ok
  rescue
    error ->
      Logger.warning(
        "[fork gate] failed to annotate fork marker for #{child_id}: " <>
          Exception.format(:error, error)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[fork gate] failed to annotate fork marker for #{child_id}: " <> inspect(reason)
      )

      :ok
  end

  # Same delivery posture as SessionRunner's own parent lifecycle ping:
  # :queue (this is not urgent enough to interrupt the orchestrator's own
  # in-flight turn) and fire-and-forget, never blocking the gate.
  defp default_notify(parent_id, message) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      case Cluster.find_session(parent_id) do
        nil ->
          :ok

        {node, parent} ->
          Cluster.send_message(node, parent.id, message, :queue)
      end
    end)

    :ok
  end

  # ── PubSub subscription (lazy) ───────────────────────────────────────

  defp ensure_subscribed(%{subscribed?: true} = state), do: state

  defp ensure_subscribed(state) do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, @sessions_topic)
    %{state | subscribed?: true}
  end

  defp maybe_unsubscribe(%{subscribed?: false} = state), do: state

  defp maybe_unsubscribe(%{watching: watching} = state) when map_size(watching) > 0, do: state

  defp maybe_unsubscribe(state) do
    if state.queues == %{} do
      Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, @sessions_topic)
      %{state | subscribed?: false}
    else
      state
    end
  end

  defp snapshot(nil), do: nil

  defp snapshot(queue) do
    %{
      active_child: queue.active_child,
      pending: Enum.map(queue.pending, & &1.child_id),
      paused: queue.paused
    }
  end
end
