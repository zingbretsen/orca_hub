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

  ## The parent is child zero (§6, widened after the 2026-08-14 live smoke)

  Sibling-vs-sibling serialization is NOT sufficient on its own, because
  `fork_from_parent` forks the CALLER: at the instant `start_session`
  returns, the parent is BY CONSTRUCTION mid-turn — it has emitted a tool
  call and still has to consume the tool result and produce a final message.
  That next parent LLM call is routed straight back onto the slot holding
  the prefix the child needs (measured: `selected slot by LCP similarity,
  f_sim_best = 0.994`) and holds it for the rest of the turn. A child
  arriving ~1.6s later finds that slot busy, falls back to `selected slot by
  LRU` onto a slot holding nothing relevant, and pays a FULL cold prefill.
  Measured 3/3 parents on gb10: `cache_read_input_tokens` exactly 0,
  25.7-32.0s — the very "strictly worse than a plain spawn" outcome §1.1
  exists to exclude. The parent's slot freed ~4s AFTER the child had already
  finished cold-prefilling.

  So the FIRST child of a fan-out has one additional precondition: the
  parent's own in-flight turn must have ENDED. Verified before implementing,
  same box, same model, parent process not mid-turn: the child's first turn
  reprocessed **20 fresh tokens against `cacheRead 31,813`** in 4.97s, and
  llama-server picked `selected slot by LCP similarity, f_sim_best = 0.999`
  — the parent's own slot — with no intervening task switch. (That also
  answers the smoke report's open question: the prefix does NOT need to be
  written to the host prompt cache first; slot-resident is enough.)

  Mechanically the parent is just **child zero** in the same chain, watched
  through the same aggregate-topic subscription, with the same four
  turn-ending signals and the same `release_timeout_ms` backstop. Once its
  turn is seen to end, the queue is marked `parent_turn: :clear` and every
  later sibling is gated by siblings alone, exactly as before. A parent that
  is idle, `ready`, torn down, cold, or simply gone at enqueue time clears
  the check immediately and adds ZERO latency — file-level fork needs no
  live parent runner, and a non-running parent is not holding a slot.

  The cost is honest: the gate waits for the parent's ENTIRE current turn,
  not just the tool call that spawned the fork. An orchestrator that forks
  and then runs five more minutes of tool calls holds its children for five
  minutes. That is inherent to the API shape (the caller is always mid-turn);
  the pi orchestrator prompt therefore advises making fork spawns the LAST
  action of a turn.

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

  ## Failure handling (all three of §6's cases, plus delivery itself)

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
    * **Parent's turn errors, or never ends** — the parent-as-child-zero wait
      honours the same four turn-ending signals as any child, so a CRASHING
      parent (`cli_error` / `{:status, :error}`) releases the first child
      immediately rather than stranding the whole fan-out behind a dead
      turn. A parent that simply hangs is covered by the SAME
      `release_timeout_ms` knob (not a second timeout mechanism), which
      releases anyway and emits a `fork_gate_parent_timeout` warning on both
      topics.
    * **Node restart** — gate state is per-node and IN-MEMORY, by design. A
      restart drops the queue, and `SessionResumer`-recovered children send
      their pending prompts unserialized. This is deliberately not made
      durable: the serialized regime is only worth enforcing for a
      contiguous fan-out, and a queue resurrected minutes later is fanning
      out against a prefix the host-memory cache has very likely already
      evicted anyway. §6.1's per-fork miss detection is what turns that from
      a silent regression into a visible one.
    * **Delivery of the first prompt itself fails** (`release/2`'s off-process
      `Task` gets an `{:error, reason}` back from `deliver.(...)`, e.g. the
      runner vanished between admission and the `Cluster.send_message` call
      actually landing) — this is orthogonal to §6's three first-TURN cases
      above, since the child's first turn never even started. The next child
      is released immediately, and a `fork_gate_deliver_failed` warning is
      emitted on BOTH the parent's and the child's session topics (same
      persist-on-child/broadcast-on-parent split as every other warning here)
      — otherwise a fork child left prompt-less in its pre-turn state would be
      visible only in a server log, not to the orchestrator watching the
      parent.

  ## §6.1 cache-miss detection

  Before releasing the next child, the gate inspects the completed child's
  first `result`. **Amendment (post-ship): the comparison is FIRST-RESPONSE-
  ONLY, not the turn-summed usage.** `Backend.Pi.accumulate_usage/1` folds
  pi's per-response `usage.cacheRead`/`usage.input` into the synthesized
  `result` as `cache_read_input_tokens` / `input_tokens` — but that sum spans
  every assistant response in the turn, and a forked child's first turn
  running a long tool loop legitimately grows later responses' inputs (each
  tool result appends to the prompt). Only the FIRST response's prompt is
  exactly `[shared system prompt + inherited history + identity entry +
  first prompt]` — the prefix this check actually means to test — so a tool
  loop could inflate the summed `input_tokens` past the threshold with zero
  relationship to whether the inherited prefix was served from cache,
  false-positiving into a spurious pause. `Backend.Pi.agent_end_result/2`
  additionally surfaces `first_response_usage` (`input_tokens` /
  `cache_read_input_tokens` from just the first assistant response) on the
  same `result` event, additive alongside the unchanged accumulated `usage`
  fields (other code and the UI read those). The gate reads
  `first_response_usage` when present, falling back to `usage` for events
  that don't carry it (e.g. non-pi test payloads).

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
  Snapshot of one parent's queue:
  `%{active_child, pending, paused, waiting_on_parent_turn}`, or `nil` when
  this parent has nothing in flight.
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
       # parent_id => %{pending: [entry], active_child: child_id | nil,
       #                paused: nil | map, parent_turn: :unchecked | :clear | map}
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

        # Nothing left to release, so a pending parent-turn hold is dead
        # weight — cancel its timer rather than leaving it to fire into an
        # already-dropped queue.
        case queue.parent_turn do
          %{timer_ref: ref} -> cancel_timer(ref)
          _ -> :ok
        end

        state =
          state
          |> put_queue(parent_id, %{queue | pending: [], paused: nil, parent_turn: :clear})
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
    state =
      case Map.fetch(state.watching, session_id) do
        :error -> state
        {:ok, watch} -> handle_child_payload(state, session_id, watch, payload)
      end

    # ...and independently, the same id may be a PARENT whose in-flight turn
    # a fan-out is waiting on. A session can be both at once (a fork child
    # that itself fans out), so these are two lookups, not two branches.
    {:noreply, handle_parent_payload(state, session_id, payload)}
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

  def handle_info({:parent_wait_timeout, parent_id}, state) do
    case Map.fetch(state.queues, parent_id) do
      {:ok, %{parent_turn: %{} = hold} = queue} ->
        held_child_id = queue.pending |> List.first() |> then(&(&1 && &1.child_id))

        Logger.warning(
          "[fork gate] parent #{parent_id}'s in-flight turn did not end within " <>
            "#{ServingProfile.release_timeout_ms()}ms — releasing its first forked child anyway"
        )

        message =
          "Fork gate: parent session #{parent_id}'s own in-flight turn did not end within " <>
            "#{div(ServingProfile.release_timeout_ms(), 60_000)} minutes. Releasing the first " <>
            "forked child anyway — its first turn may cold-prefill, because the parent is " <>
            "still holding the slot that caches the inherited prefix (pi_fork_spec.md §6)."

        event = %{
          "type" => "system",
          "subtype" => "fork_gate_parent_timeout",
          "child_session_id" => held_child_id,
          "parent_session_id" => parent_id,
          "timeout_ms" => ServingProfile.release_timeout_ms(),
          "message" => message
        }

        if held_child_id, do: emit_warning(held_child_id, event, persist: true)
        emit_warning(parent_id, event, persist: false)

        {:noreply, clear_parent_turn(state, parent_id, hold)}

      _ ->
        {:noreply, state}
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

        message =
          "Fork gate: delivery of child session #{child_id}'s first prompt failed " <>
            "(#{inspect(reason)}). Releasing the next forked sibling anyway — this child was " <>
            "never prompted and stays in its pre-turn state until you send it a message " <>
            "yourself (pi_fork_spec.md §6)."

        event = %{
          "type" => "system",
          "subtype" => "fork_gate_deliver_failed",
          "child_session_id" => child_id,
          "parent_session_id" => watch.parent_id,
          "reason" => inspect(reason),
          "message" => message
        }

        emit_warning(child_id, event, persist: true)
        emit_warning(watch.parent_id, event, persist: false)

        {:noreply, complete_child(state, child_id, watch, :deliver_failed)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Queue mechanics ──────────────────────────────────────────────────

  defp queue_for(state, parent_id) do
    Map.get(state.queues, parent_id, %{
      pending: [],
      active_child: nil,
      paused: nil,
      parent_turn: :unchecked
    })
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
        case await_parent_turn(state, parent_id, queue) do
          {:clear, state} ->
            queue = queue_for(state, parent_id)

            state
            |> put_queue(parent_id, %{queue | pending: rest, active_child: entry.child_id})
            |> release(entry, true)

          {:holding, state} ->
            state
        end

      _ ->
        prune_queue(state, parent_id)
    end
  end

  # ── Parent-as-child-zero (§6) ────────────────────────────────────────
  # The additional precondition on the FIRST release of a fan-out: the
  # parent's own in-flight turn must have ended, or the child's request
  # races it for the one slot holding the prefix and loses (moduledoc,
  # "The parent is child zero"). Once cleared it stays cleared, so siblings
  # 2..N are gated by siblings alone, exactly as before.
  defp await_parent_turn(state, _parent_id, %{parent_turn: :clear}), do: {:clear, state}

  # Already holding: the timer and the subscription are live, nothing to do.
  defp await_parent_turn(state, _parent_id, %{parent_turn: %{}}), do: {:holding, state}

  defp await_parent_turn(state, parent_id, queue) do
    # SUBSCRIBE BEFORE READING the status, never the other way round.
    # `SessionRunner` persists a status change and only then broadcasts it,
    # so a parent that still reads "running" here cannot have already
    # published the turn-ending payload we're about to wait for.
    state = ensure_subscribed(state)

    if parent_turn_in_flight?(parent_id) do
      timer_ref =
        Process.send_after(
          self(),
          {:parent_wait_timeout, parent_id},
          ServingProfile.release_timeout_ms()
        )

      Logger.debug(
        "[fork gate] holding the first fork child of parent #{parent_id} until its " <>
          "in-flight turn ends"
      )

      {:holding, put_queue(state, parent_id, %{queue | parent_turn: %{timer_ref: timer_ref}})}
    else
      {:clear, put_queue(state, parent_id, %{queue | parent_turn: :clear})}
    end
  end

  # Only `running`/`compacting` are unambiguously mid-turn. Everything else —
  # idle, ready, waiting, error, a torn-down or never-started runner, a row
  # that no longer exists — means nothing is holding a slot, so the child is
  # released with ZERO added latency. Fails OPEN (release) on any lookup
  # error, matching this module's other best-effort HubRPC calls: a DB blip
  # must not strand a fan-out that a plain `send_message` would have run.
  defp parent_turn_in_flight?(parent_id) do
    case HubRPC.get_session(parent_id) do
      %{status: status} -> status in ["running", "compacting"]
      _ -> false
    end
  rescue
    error ->
      Logger.warning(
        "[fork gate] could not read parent #{parent_id}'s status, releasing anyway: " <>
          Exception.format(:error, error)
      )

      false
  catch
    :exit, reason ->
      Logger.warning(
        "[fork gate] could not read parent #{parent_id}'s status, releasing anyway: " <>
          inspect(reason)
      )

      false
  end

  # The parent's turn ended (or was declared over by the timeout): drop the
  # hold and let the queue advance.
  defp clear_parent_turn(state, parent_id, %{timer_ref: timer_ref}) do
    cancel_timer(timer_ref)
    queue = queue_for(state, parent_id)

    state
    |> put_queue(parent_id, %{queue | parent_turn: :clear})
    |> maybe_release(parent_id)
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

  # Parent-as-child-zero: the same four turn-ending signals a child is
  # judged by (§6's error path included, so a parent whose turn CRASHES
  # releases the fan-out instead of stranding it behind a dead turn).
  defp handle_parent_payload(state, parent_id, payload) do
    case Map.fetch(state.queues, parent_id) do
      {:ok, %{parent_turn: %{} = hold}} ->
        if turn_ended?(payload) do
          Logger.debug("[fork gate] parent #{parent_id}'s turn ended — releasing its first fork")
          clear_parent_turn(state, parent_id, hold)
        else
          state
        end

      _ ->
        state
    end
  end

  defp turn_ended?({:event, %{"type" => "result"}}), do: true
  defp turn_ended?({:event, %{"type" => "cli_error"}}), do: true
  defp turn_ended?({:status, :error}), do: true
  defp turn_ended?({:status, :idle}), do: true
  defp turn_ended?(_payload), do: false

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
    # First-response-only (amendment, §6.1 doc above): prefer the
    # first-response-scoped usage pi.ex now surfaces; fall back to the
    # turn-summed `usage` for events that don't carry it.
    usage = event["first_response_usage"] || event["usage"] || %{}
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
      paused: queue.paused,
      # Distinct from `paused`: nothing went wrong, the queue is simply
      # holding its first child until the parent's own turn ends (§6).
      waiting_on_parent_turn: is_map(queue.parent_turn)
    }
  end
end
