defmodule OrcaHub.ForkGateTest do
  @moduledoc """
  pi_fork_spec.md §6/§6.1 — the mandatory first-turn gate and its cache-miss
  detection, driven against a REAL `OrcaHub.ForkGate` process with real
  PubSub traffic. The child sessions are real DB rows (so the warning events
  and the §8 marker annotation actually persist), but their turns are
  simulated by broadcasting exactly the payloads `SessionRunner.broadcast/2`
  publishes on the aggregate "sessions" topic — no pi binary, no port, and
  therefore no timing flake in the ordering assertions.

  Delivery and orchestrator-notification are injected (`:deliver` / `:notify`)
  so "who got released, and when" is observable as a plain message to the
  test process instead of inferred from a side effect.
  """

  # async: false — a named GenServer plus PubSub broadcasts from the test
  # process into it; needs the DB sandbox in SHARED mode so the gate process
  # can persist warning events. Also flips global fork-profile app env.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{ForkGate, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "fork_gate_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    parent = create_session(dir)
    children = for _ <- 1..3, do: create_session(dir)

    on_exit(fn -> Application.delete_env(:orca_hub, :fork_serving_profile_overrides) end)

    {:ok, dir: dir, parent: parent, children: children}
  end

  defp create_session(dir) do
    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        backend: "pi",
        code_exec: false,
        orchestrator: false
      })

    session
  end

  defp profile(overrides) do
    Application.put_env(:orca_hub, :fork_serving_profile_overrides, overrides)
  end

  defp start_gate(_context) do
    test = self()

    name = :"fork_gate_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(
        {ForkGate,
         name: name,
         deliver: fn node, child_id, prompt ->
           send(test, {:delivered, child_id, prompt, node})
           :ok
         end,
         notify: fn parent_id, message ->
           send(test, {:notified, parent_id, message})
           :ok
         end}
      )

    name
  end

  defp enqueue(gate, parent, child, opts \\ []) do
    ForkGate.enqueue_first_turn(
      parent.id,
      child.id,
      "first prompt for #{child.id}",
      Keyword.merge([server: gate, runner_node: node()], opts)
    )
  end

  # Same shape as start_gate/1, but delivery to `failing_child_id` fails
  # (as the off-process Task in ForkGate.release/2 does on a real
  # Cluster.send_message error) instead of succeeding.
  defp start_gate_with_failing_child(failing_child_id) do
    test = self()

    name = :"fork_gate_test_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(
        {ForkGate,
         name: name,
         deliver: fn node, child_id, prompt ->
           if child_id == failing_child_id do
             {:error, :noproc}
           else
             send(test, {:delivered, child_id, prompt, node})
             :ok
           end
         end,
         notify: fn parent_id, message ->
           send(test, {:notified, parent_id, message})
           :ok
         end}
      )

    name
  end

  # Exactly the payload SessionRunner.broadcast/2 publishes for a completed
  # streaming turn, on the aggregate topic the gate listens to.
  defp finish_turn(child, usage) do
    broadcast(child, {:event, %{"type" => "result", "is_error" => false, "usage" => usage}})
  end

  defp broadcast(child, payload) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {child.id, payload})
  end

  # A cache HIT (§6.1): the whole inherited prefix came from cache, only a
  # handful of fresh tokens were reprocessed.
  defp hit_usage(parent_tokens),
    do: %{
      "input_tokens" => 18,
      "output_tokens" => 40,
      "cache_read_input_tokens" => parent_tokens
    }

  # ── §6: first-turn serialization ─────────────────────────────────────

  describe "first-turn serialization" do
    setup [:start_gate_ctx]

    test "a 3-child fan-out releases each first prompt strictly after the prior sibling's first result",
         %{gate: gate, parent: parent, children: [c1, c2, c3]} do
      for child <- [c1, c2, c3], do: assert(enqueue(gate, parent, child) == :ok)

      # Only the head goes out; the other two are held.
      assert_receive {:delivered, id1, prompt1, _node}
      assert id1 == c1.id
      assert prompt1 == "first prompt for #{c1.id}"
      refute_receive {:delivered, _, _, _}, 100

      assert %{active_child: active, pending: pending} = ForkGate.status(parent.id, server: gate)
      assert active == c1.id
      assert pending == [c2.id, c3.id]

      # Child 1's first turn completes -> and only then does child 2 go out.
      finish_turn(c1, hit_usage(20_000))
      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
      refute_receive {:delivered, _, _, _}, 100

      finish_turn(c2, hit_usage(20_000))
      assert_receive {:delivered, id3, _, _}
      assert id3 == c3.id

      # After the last child's first turn the parent's queue is gone
      # entirely — each child is independent from here on.
      finish_turn(c3, hit_usage(20_000))
      assert eventually(fn -> ForkGate.status(parent.id, server: gate) == nil end)
    end

    test "different parents' fan-outs do not gate each other", %{
      gate: gate,
      dir: dir,
      parent: parent_a,
      children: [c1, c2, _]
    } do
      parent_b = create_session(dir)

      assert enqueue(gate, parent_a, c1) == :ok
      assert enqueue(gate, parent_b, c2) == :ok

      # Both heads go out immediately — they have different prefixes, so they
      # don't contend for the same checkpoint.
      assert_receive {:delivered, id_a, _, _}
      assert_receive {:delivered, id_b, _, _}
      assert Enum.sort([id_a, id_b]) == Enum.sort([c1.id, c2.id])
    end

    test "a first turn that ERRORS releases the next sibling immediately", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok

      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id
      refute_receive {:delivered, _, _, _}, 100

      # An error event ends the turn just as a `result` does (§6).
      broadcast(c1, {:status, :error})

      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "a cli_error event also ends the first turn", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok
      assert_receive {:delivered, _, _, _}

      broadcast(c1, {:event, %{"type" => "cli_error", "exit_code" => 1, "message" => "boom"}})

      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "a HUNG first turn releases the next sibling on the timeout and warns on both topics",
         %{gate: gate, parent: parent, children: [c1, c2, _]} do
      profile(%{release_timeout_ms: 120})

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{parent.id}")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok
      assert_receive {:delivered, _, _, _}

      # c1 never completes its turn — the per-child release timeout fires.
      assert_receive {:event, %{"subtype" => "fork_gate_timeout"} = child_warning}, 1_000
      assert child_warning["child_session_id"] == c1.id
      assert child_warning["parent_session_id"] == parent.id

      assert_receive {:event, %{"subtype" => "fork_gate_timeout"}}, 1_000

      assert_receive {:delivered, id2, _, _}, 1_000
      assert id2 == c2.id
    end

    test "a later re-prompt of a completed child does NOT go back through the gate", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok
      assert_receive {:delivered, _, _, _}

      finish_turn(c1, hit_usage(20_000))
      assert_receive {:delivered, _, _, _}

      # c1's first turn is over, so it is no longer watched: a second `result`
      # for it must not advance the queue a second time (which would release
      # a third child while c2 is still mid-first-turn).
      finish_turn(c1, hit_usage(20_000))
      refute_receive {:delivered, _, _, _}, 100

      assert %{active_child: active} = ForkGate.status(parent.id, server: gate)
      assert active == c2.id
    end

    test "abort drops every pending first prompt without delivering or deleting anything", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, c3]
    } do
      for child <- [c1, c2, c3], do: enqueue(gate, parent, child)
      assert_receive {:delivered, _, _, _}

      assert {:ok, dropped} = ForkGate.abort(parent.id, server: gate)
      assert dropped == [c2.id, c3.id]

      finish_turn(c1, hit_usage(20_000))
      refute_receive {:delivered, _, _, _}, 100

      # The sessions themselves are untouched — abort only drops prompts.
      assert Sessions.get_session!(c2.id).id == c2.id
    end
  end

  # ── delivery failure ({:deliver_failed}) ─────────────────────────────
  # No `setup [:start_gate_ctx]` here — this describe starts its own gate
  # per test (with a failing deliver fn for one child), so the shared
  # default-deliver gate the other describes use would just be an unused,
  # ID-colliding second `start_supervised({ForkGate, ...})` call.

  describe "delivery failure" do
    test "a FAILED delivery warns on both topics and releases the next sibling", %{
      parent: parent,
      children: [c1, c2, _]
    } do
      gate = start_gate_with_failing_child(c1.id)

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{parent.id}")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok

      # c1's first prompt never reached the runner — the gate is told via
      # {:deliver_failed, ...} rather than a turn-ending event.
      assert_receive {:event, %{"subtype" => "fork_gate_deliver_failed"} = child_warning}, 1_000
      assert child_warning["child_session_id"] == c1.id
      assert child_warning["parent_session_id"] == parent.id
      assert child_warning["reason"] =~ "noproc"

      # ...on BOTH topics (the parent's copy).
      assert_receive {:event, %{"subtype" => "fork_gate_deliver_failed"}}, 1_000

      # c1 is dropped from the gate and the next sibling is released anyway —
      # a failed delivery must not stall the rest of the fan-out.
      assert_receive {:delivered, id2, _, _}, 1_000
      assert id2 == c2.id

      # The warning is persisted on the child's own feed, not just broadcast.
      assert Enum.any?(
               Sessions.list_messages(c1.id),
               &(&1.data["subtype"] == "fork_gate_deliver_failed")
             )
    end
  end

  # ── §6.1: cache-miss detection ───────────────────────────────────────

  describe "cache-miss detection" do
    setup [:start_gate_ctx]

    test "a first result reporting full-prefill-sized input_tokens warns, annotates, and PAUSES the fan-out",
         %{gate: gate, parent: parent, children: [c1, c2, c3]} do
      marker = fork_marker(c1, parent, 20_000)

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{parent.id}")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      for child <- [c1, c2, c3],
          do: enqueue(gate, parent, child, parent_context_tokens: 20_000)

      assert_receive {:delivered, _, _, _}

      # The child paid a full cold prefill: fresh input ≈ the parent's context.
      finish_turn(c1, %{
        "input_tokens" => 20_100,
        "output_tokens" => 40,
        "cache_read_input_tokens" => 0
      })

      assert_receive {:event, %{"subtype" => "fork_cache_miss"} = warning}, 1_000
      assert warning["child_session_id"] == c1.id
      assert warning["parent_session_id"] == parent.id
      assert warning["input_tokens"] == 20_100
      assert warning["parent_context_tokens"] == 20_000
      assert warning["paused"] == true
      assert warning["message"] =~ "MISS"

      # ...on BOTH topics (the parent's copy).
      assert_receive {:event, %{"subtype" => "fork_cache_miss"}}, 1_000

      # The orchestrator is told, with an actionable next step.
      assert_receive {:notified, parent_id, message}, 1_000
      assert parent_id == parent.id
      assert message =~ "[Session lifecycle]"
      assert message =~ "PAUSED"
      assert message =~ "fork_queue"

      # ...and the rest of the fan-out is held rather than serially paying
      # full prefill against an evicted prefix.
      refute_receive {:delivered, _, _, _}, 200

      assert %{paused: %{reason: :cache_miss}, pending: pending} =
               ForkGate.status(parent.id, server: gate)

      assert pending == [c2.id, c3.id]

      # The §8 marker carries the outcome.
      assert eventually(fn ->
               data = reload_message(c1, marker).data
               data["cache_miss"] == true and data["first_turn_input_tokens"] == 20_100
             end)

      # The warning is persisted on the child's own feed, not just broadcast.
      assert Enum.any?(Sessions.list_messages(c1.id), &(&1.data["subtype"] == "fork_cache_miss"))

      # Resuming releases the next child, accepting the cold cost.
      assert {:ok, _} = ForkGate.resume(parent.id, server: gate)
      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "a checkpoint-granularity PARTIAL hit does not false-positive", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      enqueue(gate, parent, c1, parent_context_tokens: 100_000)
      enqueue(gate, parent, c2, parent_context_tokens: 100_000)
      assert_receive {:delivered, _, _, _}

      # Worst-case reprocess on this hybrid arch is ~8k tokens (§1) — 8% of a
      # 100k parent, well under the 25% threshold.
      finish_turn(c1, %{
        "input_tokens" => 8_000,
        "output_tokens" => 50,
        "cache_read_input_tokens" => 92_000
      })

      refute_receive {:event, %{"subtype" => "fork_cache_miss"}}, 200
      refute_receive {:notified, _, _}, 100

      # ...and the queue keeps flowing.
      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "a tool loop's SUMMED input_tokens would breach the threshold but a clean FIRST response is not flagged",
         %{gate: gate, parent: parent, children: [c1, c2, _]} do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      enqueue(gate, parent, c1, parent_context_tokens: 20_000)
      enqueue(gate, parent, c2, parent_context_tokens: 20_000)
      assert_receive {:delivered, _, _, _}

      # A first turn with a long tool loop: the turn-SUMMED input_tokens
      # (what `Backend.Pi.accumulate_usage/1` reports) breaches the 25%
      # threshold on its own (12,000 > 0.25 * 20,000)...
      broadcast(
        c1,
        {:event,
         %{
           "type" => "result",
           "is_error" => false,
           "usage" => %{
             "input_tokens" => 12_000,
             "output_tokens" => 400,
             "cache_read_input_tokens" => 20_000
           },
           # ...but the FIRST response of the turn — the only one whose
           # prompt prefix is exactly the inherited prefix §6.1 means to
           # check — was a clean cache hit.
           "first_response_usage" => %{
             "input_tokens" => 18,
             "cache_read_input_tokens" => 20_000
           }
         }}
      )

      refute_receive {:event, %{"subtype" => "fork_cache_miss"}}, 200
      refute_receive {:notified, _, _}, 100

      # ...and the queue keeps flowing rather than pausing on a phantom miss.
      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "detection is SKIPPED (not guessed) when the parent's context size is unknown", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      enqueue(gate, parent, c1, parent_context_tokens: nil)
      enqueue(gate, parent, c2, parent_context_tokens: nil)
      assert_receive {:delivered, _, _, _}

      finish_turn(c1, %{
        "input_tokens" => 999_999,
        "output_tokens" => 5,
        "cache_read_input_tokens" => 0
      })

      refute_receive {:event, %{"subtype" => "fork_cache_miss"}}, 200
      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "a miss on the LAST sibling warns without pausing an empty queue", %{
      gate: gate,
      parent: parent,
      children: [c1, _, _]
    } do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")
      enqueue(gate, parent, c1, parent_context_tokens: 20_000)
      assert_receive {:delivered, _, _, _}

      finish_turn(c1, %{
        "input_tokens" => 20_000,
        "output_tokens" => 5,
        "cache_read_input_tokens" => 0
      })

      assert_receive {:event, %{"subtype" => "fork_cache_miss"} = warning}, 1_000
      assert warning["paused"] == false
      refute_receive {:notified, _, _}, 100
      assert eventually(fn -> ForkGate.status(parent.id, server: gate) == nil end)
    end
  end

  # ── §6: the parent is child zero ─────────────────────────────────────
  # `fork_from_parent` forks the CALLER, so at spawn time the parent is
  # normally mid-turn and holding the one slot that caches the prefix the
  # child needs. Releasing then makes llama-server LRU-fall-back the child
  # onto a cold slot: measured 3/3 parents at `cache_read_input_tokens` = 0,
  # 25.7-32.0s. So the FIRST child additionally waits for the parent's own
  # turn to end.

  describe "parent-turn precondition" do
    setup [:start_gate_ctx]

    test "a parent that is NOT mid-turn releases the first child immediately", %{
      gate: gate,
      parent: parent,
      children: [c1, _, _]
    } do
      running(parent, "idle")

      assert enqueue(gate, parent, c1) == :ok

      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id

      assert %{active_child: active, waiting_on_parent_turn: waiting} =
               ForkGate.status(parent.id, server: gate)

      assert active == c1.id
      refute waiting
    end

    test "a torn-down/unknown parent does not block the fan-out (file-level fork needs no live parent)",
         %{gate: gate, children: [c1, _, _]} do
      # A parent id with no row at all — the §12 Q4 case: the gate must not
      # require a live parent runner.
      assert ForkGate.enqueue_first_turn(
               Ecto.UUID.generate(),
               c1.id,
               "first prompt",
               server: gate,
               runner_node: node()
             ) == :ok

      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id
    end

    test "a parent that IS mid-turn holds the first child until its own result lands", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      running(parent)

      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok

      # Nothing goes out: the parent's in-flight turn still owns the slot.
      refute_receive {:delivered, _, _, _}, 200

      assert %{active_child: nil, pending: pending, waiting_on_parent_turn: true} =
               ForkGate.status(parent.id, server: gate)

      assert pending == [c1.id, c2.id]

      # The parent's OWN turn ends -> and only then does the head go out.
      finish_turn(parent, hit_usage(20_000))

      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id
      refute_receive {:delivered, _, _, _}, 100

      # ...and the sibling chain then runs exactly as before, unchanged.
      finish_turn(c1, hit_usage(20_000))
      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
    end

    test "the parent is only waited on ONCE — later siblings are not re-gated on it", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      running(parent)
      assert enqueue(gate, parent, c1) == :ok
      assert enqueue(gate, parent, c2) == :ok

      finish_turn(parent, hit_usage(20_000))
      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id

      # The parent starts a NEW turn (a queued follow-up, a heartbeat, an
      # operator message) while the fan-out is still draining. That must not
      # re-arm the hold: by now the child's own state is slot-resident.
      broadcast(parent, {:status, :running})
      finish_turn(c1, hit_usage(20_000))

      assert_receive {:delivered, id2, _, _}
      assert id2 == c2.id
      refute ForkGate.status(parent.id, server: gate).waiting_on_parent_turn
    end

    test "a parent whose turn CRASHES releases the first child instead of stranding the fan-out",
         %{gate: gate, parent: parent, children: [c1, _, _]} do
      running(parent)
      assert enqueue(gate, parent, c1) == :ok
      refute_receive {:delivered, _, _, _}, 200

      broadcast(parent, {:status, :error})

      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id
    end

    test "a parent cli_error also ends the wait", %{
      gate: gate,
      parent: parent,
      children: [c1, _, _]
    } do
      running(parent)
      assert enqueue(gate, parent, c1) == :ok
      refute_receive {:delivered, _, _, _}, 200

      broadcast(parent, {:event, %{"type" => "cli_error", "exit_code" => 1, "message" => "boom"}})

      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id
    end

    test "a parent turn that HANGS releases on the SAME release timeout and warns on both topics",
         %{gate: gate, parent: parent, children: [c1, _, _]} do
      # Deliberately the same `release_timeout_ms` knob the per-child hang
      # backstop uses — one timeout mechanism, not two (§6).
      profile(%{release_timeout_ms: 120})
      running(parent)

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{parent.id}")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      assert enqueue(gate, parent, c1) == :ok
      refute_receive {:delivered, _, _, _}, 100

      # The parent's turn never ends — the hold is broken anyway, loudly.
      assert_receive {:event, %{"subtype" => "fork_gate_parent_timeout"} = warning}, 1_000
      assert warning["parent_session_id"] == parent.id
      assert warning["child_session_id"] == c1.id
      assert warning["timeout_ms"] == 120
      assert warning["message"] =~ "may cold-prefill"

      # ...on BOTH topics (the parent's broadcast-only copy).
      assert_receive {:event, %{"subtype" => "fork_gate_parent_timeout"}}, 1_000

      assert_receive {:delivered, id1, _, _}, 1_000
      assert id1 == c1.id

      # Persisted on the held child's own feed, like every other gate warning.
      assert eventually(fn ->
               Enum.any?(
                 Sessions.list_messages(c1.id),
                 &(&1.data["subtype"] == "fork_gate_parent_timeout")
               )
             end)
    end

    test "abort clears a parent-turn hold without leaving the queue behind", %{
      gate: gate,
      parent: parent,
      children: [c1, c2, _]
    } do
      running(parent)
      for child <- [c1, c2], do: enqueue(gate, parent, child)
      refute_receive {:delivered, _, _, _}, 200

      assert {:ok, dropped} = ForkGate.abort(parent.id, server: gate)
      assert dropped == [c1.id, c2.id]

      # The parent's turn ending afterwards must not resurrect anything.
      finish_turn(parent, hit_usage(20_000))
      refute_receive {:delivered, _, _, _}, 200
      assert ForkGate.status(parent.id, server: gate) == nil
    end

    test "with serialization off (vLLM) the parent's turn is not waited on at all", %{
      gate: gate,
      parent: parent,
      children: [c1, _, _]
    } do
      profile(%{serialize_first_turns: false})
      running(parent)

      assert enqueue(gate, parent, c1) == :ok

      # §9: the whole serialization half — parent included — is off by
      # configuration alone, no fork-code change.
      assert_receive {:delivered, id1, _, _}
      assert id1 == c1.id
    end
  end

  # ── §9: serving-profile isolation ────────────────────────────────────

  describe "serving profile" do
    setup [:start_gate_ctx]

    test "with serialization disabled every first prompt goes out immediately, but misses are still detected",
         %{gate: gate, parent: parent, children: [c1, c2, c3]} do
      profile(%{serialize_first_turns: false, pause_on_miss: false})
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

      for child <- [c1, c2, c3],
          do: enqueue(gate, parent, child, parent_context_tokens: 20_000)

      # All three go out without waiting on each other (vLLM shares cached
      # prefix blocks across concurrent requests — §9).
      delivered =
        for _ <- 1..3 do
          assert_receive {:delivered, id, _, _}
          id
        end

      assert Enum.sort(delivered) == Enum.sort([c1.id, c2.id, c3.id])
      assert ForkGate.status(parent.id, server: gate) == nil

      # Miss detection still runs as a cheap assertion.
      finish_turn(c1, %{
        "input_tokens" => 20_000,
        "output_tokens" => 5,
        "cache_read_input_tokens" => 0
      })

      assert_receive {:event, %{"subtype" => "fork_cache_miss"} = warning}, 1_000
      assert warning["paused"] == false
    end
  end

  describe "OrcaHub.ForkGate.ServingProfile" do
    alias OrcaHub.ForkGate.ServingProfile

    test "defaults to the llama.cpp posture the spec measured against" do
      Application.delete_env(:orca_hub, :fork_serving_profile)
      assert ServingProfile.name() == :llama_cpp
      assert ServingProfile.serialize_first_turns?()
      assert ServingProfile.pause_on_miss?()
      assert ServingProfile.miss_threshold_ratio() == 0.25
      assert ServingProfile.kv_budget() == 262_144
    end

    test "the vllm profile turns serialization off by configuration alone" do
      Application.put_env(:orca_hub, :fork_serving_profile, :vllm)
      on_exit(fn -> Application.delete_env(:orca_hub, :fork_serving_profile) end)

      refute ServingProfile.serialize_first_turns?()
      refute ServingProfile.pause_on_miss?()
      # Miss detection survives the cutover (§9: "a cheap assertion").
      assert ServingProfile.miss_threshold_ratio() == 0.25
    end

    test "an unknown profile name falls back to the default rather than crashing a spawn" do
      Application.put_env(:orca_hub, :fork_serving_profile, "not-a-real-engine")
      on_exit(fn -> Application.delete_env(:orca_hub, :fork_serving_profile) end)

      assert ServingProfile.name() == :llama_cpp
    end

    test "individual knobs are overridable without swapping the whole profile" do
      Application.put_env(:orca_hub, :fork_serving_profile_overrides, %{
        miss_threshold_ratio: 0.5,
        release_timeout_ms: 1_000
      })

      assert ServingProfile.miss_threshold_ratio() == 0.5
      assert ServingProfile.release_timeout_ms() == 1_000
      # ...and the un-overridden knobs keep their profile defaults.
      assert ServingProfile.serialize_first_turns?()
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp start_gate_ctx(context), do: {:ok, gate: start_gate(context)}

  # The §8 synthetic marker `OrcaHub.MCP.Tools.Sessions` creates at fork-spawn
  # time — what §6.1 annotates with the observed cache outcome.
  defp fork_marker(child, parent, inherited_tokens) do
    {:ok, message} =
      Sessions.create_message(%{
        session_id: child.id,
        data: %{
          "type" => "system",
          "subtype" => "forked_from",
          "parent_session_id" => parent.id,
          "inherited_tokens" => inherited_tokens
        }
      })

    message
  end

  # Puts the parent in the state `fork_from_parent` actually finds it in: the
  # caller is blocked on its own `start_session` tool call, so its row says
  # "running" until that turn produces a result.
  defp running(session, status \\ "running") do
    {:ok, updated} = Sessions.update_session(session, %{status: status})
    updated
  end

  defp reload_message(session, message) do
    session.id |> Sessions.list_messages() |> Enum.find(&(&1.id == message.id))
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
