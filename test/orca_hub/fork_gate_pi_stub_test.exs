defmodule OrcaHub.ForkGatePiStubTest do
  @moduledoc """
  pi_fork_spec.md §11.4/§11.5 at the stub level: a fork fan-out driven through
  the REAL `OrcaHub.ForkGate`, the REAL `Cluster.send_message` delivery path,
  and REAL `OrcaHub.SessionRunner` processes talking to
  `test/support/fixtures/pi_stub_rpc.py` — so the gate's assumptions about
  what `SessionRunner.broadcast/2` publishes (and when) are checked against
  the actual broadcaster rather than against hand-written payloads.

  `fork_gate_test.exs` is the fine-grained unit coverage (error/timeout
  release, pause/resume, profile switching, marker annotation) against
  synthesized payloads. This file is the wiring check.

  Ordering is asserted on the ORDER of the collected event stream rather than
  by `refute_receive` at a point in time: the stub turn completes in
  milliseconds, so "child 2 hasn't started yet" is inherently racy to assert
  by absence, while "child 2's first turn started AFTER child 1's result
  landed" is exactly the §6 invariant and is race-free.
  """

  # async: false — real SessionRunners under the shared SessionSupervisor
  # (needs the DB sandbox in SHARED mode) plus the global :pi_executable seam.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{ForkGate, Sessions, SessionSupervisor}

  @stub_script Path.expand("../support/fixtures/pi_stub_rpc.py", __DIR__)

  setup do
    refute is_nil(System.find_executable("python3")),
           "python3 not found — required to run the pi --mode rpc stub fixture"

    Application.put_env(:orca_hub, :pi_executable, @stub_script)
    on_exit(fn -> Application.delete_env(:orca_hub, :pi_executable) end)
    on_exit(fn -> Application.delete_env(:orca_hub, :fork_serving_profile_overrides) end)

    dir = Path.join(System.tmp_dir!(), "fork_gate_stub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    parent = create_session(dir)
    children = for _ <- 1..3, do: create_session(dir)

    test = self()

    gate_name = :"fork_gate_stub_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(
        {ForkGate,
         name: gate_name,
         notify: fn parent_id, message ->
           send(test, {:notified, parent_id, message})
           :ok
         end}
      )

    on_exit(fn ->
      for session <- [parent | children] do
        if SessionSupervisor.session_alive?(session.id) do
          SessionSupervisor.stop_session(session.id)
        end
      end
    end)

    {:ok, gate: gate_name, parent: parent, children: children}
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

  # Mirrors the real spawn path: the child row exists and its runner is
  # started, but the FIRST PROMPT is handed to the gate instead of sent.
  defp fan_out(gate, parent, children, opts) do
    for child <- children do
      {:ok, _pid} = SessionSupervisor.start_session(child.id)

      :ok =
        ForkGate.enqueue_first_turn(
          parent.id,
          child.id,
          "say hi",
          Keyword.merge([server: gate, runner_node: node()], opts)
        )
    end
  end

  # Collects `{session_id, payload}` off the aggregate topic until every id in
  # `awaiting` has produced a `result`, or the deadline passes. Returns them
  # in arrival order.
  defp collect(awaiting, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(MapSet.new(awaiting), deadline, [])
  end

  defp do_collect(awaiting, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if MapSet.size(awaiting) == 0 or remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {id, {:event, %{"type" => "result"}} = payload} when is_binary(id) ->
          do_collect(MapSet.delete(awaiting, id), deadline, [{id, payload} | acc])

        {id, payload} when is_binary(id) ->
          do_collect(awaiting, deadline, [{id, payload} | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp index_of(stream, id, matcher) do
    Enum.find_index(stream, fn
      {^id, payload} -> matcher.(payload)
      _ -> false
    end)
  end

  defp turn_started(stream, id), do: index_of(stream, id, &match?({:status, :running}, &1))

  defp turn_result(stream, id),
    do: index_of(stream, id, &match?({:event, %{"type" => "result"}}, &1))

  test "a 3-child fan-out releases each first prompt strictly after the prior sibling's first result",
       %{gate: gate, parent: parent, children: [c1, c2, c3] = children} do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")

    # No parent context size -> §6.1 detection is skipped, so this test is
    # purely about §6's ordering.
    fan_out(gate, parent, children, parent_context_tokens: nil)

    stream = collect(Enum.map(children, & &1.id))

    for child <- children do
      assert turn_result(stream, child.id),
             "child #{child.id} never completed a first turn: #{inspect(stream)}"
    end

    # The §6 invariant: a sibling's first turn only STARTS after the previous
    # sibling's first turn has RESULTED — not merely after it was prefilled.
    assert turn_started(stream, c2.id) > turn_result(stream, c1.id)
    assert turn_started(stream, c3.id) > turn_result(stream, c2.id)

    # ...and once the last child is done, the gate is holding nothing.
    assert ForkGate.status(parent.id, server: gate) == nil
  end

  test "a first turn whose usage reports a full-prefill-sized input warns and pauses the fan-out",
       %{gate: gate, parent: parent, children: [c1, c2, _] = children} do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

    # The stub's turn runs a tool-call loop: first response input_tokens: 100
    # (bash toolCall), second response input_tokens: 30 (text). §6.1 is
    # FIRST-RESPONSE-ONLY, so the check sees just the 100 — against a
    # 100-token parent context that is >25% either way — a cold prefill of
    # the inherited prefix.
    fan_out(gate, parent, Enum.take(children, 2), parent_context_tokens: 100)

    assert_receive {:event, %{"subtype" => "fork_cache_miss"} = warning}, 15_000
    assert warning["child_session_id"] == c1.id
    assert warning["input_tokens"] == 100
    assert warning["paused"] == true

    assert_receive {:notified, parent_id, message}, 5_000
    assert parent_id == parent.id
    assert message =~ "PAUSED"

    assert %{paused: %{reason: :cache_miss}, pending: [pending_id]} =
             ForkGate.status(parent.id, server: gate)

    assert pending_id == c2.id

    # A session that was never prompted produces no `result` of its own — the
    # paused sibling really did not pay a cold prefill.
    refute Enum.any?(Sessions.list_messages(c2.id), &(&1.data["type"] == "result"))
  end

  test "a first turn whose usage reports a cache hit keeps the queue flowing", %{
    gate: gate,
    parent: parent,
    children: [c1, c2, _] = children
  } do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{c1.id}")

    # The FIRST response's 100 fresh tokens against a 100k-token parent
    # context is 0.1% — the inherited prefix was served from cache.
    fan_out(gate, parent, Enum.take(children, 2), parent_context_tokens: 100_000)

    stream = collect([c1.id, c2.id])

    refute_received {:event, %{"subtype" => "fork_cache_miss"}}
    assert turn_result(stream, c2.id), "the second child was never released: #{inspect(stream)}"
    assert turn_started(stream, c2.id) > turn_result(stream, c1.id)
  end
end
