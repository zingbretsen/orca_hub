defmodule OrcaHub.MCP.Tools.SessionsForkDeliveryTest do
  @moduledoc """
  The §6 enforcement point in `create_and_start_session/7`: a fork spawn's
  initial prompt is handed to `OrcaHub.ForkGate` instead of being sent with
  `Cluster.send_message`, while EVERY non-fork spawn keeps the delivery path
  it has always had.

  That guardrail is the point of these tests — the fork queue's own behavior
  is covered by `fork_gate_test.exs`/`fork_gate_pi_stub_test.exs`; this file
  only pins which spawns reach the gate at all.

  These exercise the process-global `OrcaHub.ForkGate` (the one in the
  supervision tree), because that is what the tool actually calls. Queues are
  keyed by parent session id and every test creates fresh sessions, so they
  don't collide; `abort/1` in `on_exit` keeps a paused/pending queue from
  leaking past the test that made it.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.MCP.Tools.Sessions, as: SessionsTool
  alias OrcaHub.{ForkGate, Sessions, SessionSupervisor}

  @stub_script Path.expand("../../../support/fixtures/pi_stub_rpc.py", __DIR__)

  setup do
    # The children spawned here run real SessionRunners. Point them at the pi
    # stub so a child's first turn behaves deterministically: without it the
    # runner errors out instantly, which (correctly, per §6's error path)
    # drains the queue before the assertion can see it held.
    refute is_nil(System.find_executable("python3"))
    Application.put_env(:orca_hub, :pi_executable, @stub_script)
    on_exit(fn -> Application.delete_env(:orca_hub, :pi_executable) end)

    dir = Path.join(System.tmp_dir!(), "fork_delivery_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, pi_caller} =
      Sessions.create_session(%{
        directory: dir,
        backend: "pi",
        code_exec: false,
        orchestrator: false
      })

    on_exit(fn -> ForkGate.abort(pi_caller.id) end)

    {:ok, dir: dir, pi_caller: pi_caller, pi_state: %{orca_session_id: pi_caller.id}}
  end

  # "PAUSE_FOR_STEER" makes the pi stub start a turn and never finish it, so
  # the head child stays the queue's active child for the whole test.
  defp fork(state, prompt \\ "PAUSE_FOR_STEER") do
    result =
      SessionsTool.call(
        "start_session",
        %{"prompt" => prompt, "fork_from_parent" => true, "notify_on_completion" => false},
        state
      )

    assert %{"isError" => false, "content" => [%{"text" => text}]} = result
    session_id = Jason.decode!(text)["session_id"]
    on_exit(fn -> stop_if_alive(session_id) end)
    session_id
  end

  defp stop_if_alive(session_id) do
    if SessionSupervisor.session_alive?(session_id),
      do: SessionSupervisor.stop_session(session_id)
  end

  test "a second fork child's first prompt is HELD by the gate, not sent", %{
    pi_state: pi_state,
    pi_caller: pi_caller
  } do
    # Distinct prompts: identical start_session args hash to the same
    # automatic idempotency key, which would dedupe the second spawn into the
    # first rather than producing a sibling.
    first = fork(pi_state, "PAUSE_FOR_STEER")
    second = fork(pi_state, "second child's first prompt")
    refute first == second

    # The head was released (the gate had nothing in flight); the second is
    # queued behind it, so its prompt was never handed to the runner.
    assert %{active_child: active, pending: pending} = ForkGate.status(pi_caller.id)
    assert active == first
    assert pending == [second]

    # ...and stays that way: the head's first turn never completes.
    refute Enum.any?(Sessions.list_messages(second), &(&1.data["type"] == "user"))
  end

  test "a NON-fork spawn never touches the gate", %{dir: dir} do
    {:ok, caller} =
      Sessions.create_session(%{
        directory: dir,
        backend: "pi",
        code_exec: false,
        orchestrator: false
      })

    result =
      SessionsTool.call(
        "start_session",
        %{"prompt" => "hi", "backend" => "pi", "notify_on_completion" => false},
        %{orca_session_id: caller.id}
      )

    assert %{"isError" => false, "content" => [%{"text" => text}]} = result
    child_id = Jason.decode!(text)["session_id"]
    on_exit(fn -> stop_if_alive(child_id) end)

    child = Sessions.get_session!(child_id)
    assert child.forked_from_session_id == nil

    # No queue for the caller, and the child isn't being watched — a non-fork
    # spawn took exactly the pre-existing Cluster.send_message path.
    assert ForkGate.status(caller.id) == nil
    refute Map.has_key?(ForkGate.queues(), caller.id)
  end
end
