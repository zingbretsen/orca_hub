defmodule OrcaHub.SessionResumerTest do
  @moduledoc """
  Coverage for issue 1465163f — auto-resuming sessions orphaned in
  `status: "running"` by a node restart. `resumable?/2` and
  `Sessions.list_running_sessions_for_node/1` are pure/query-level and
  tested directly. `resume_session/1` (the `@doc false` test seam, mirrors
  `SessionRunner.deliver_parent_notification/2`'s pattern) is tested against
  a real DB-backed session with the `claude` executable stubbed out —
  same `claude_stub_noop.sh` fixture `SessionRunnerLifecycleNotifyTest`
  uses — so it never touches the network, just reads/discards stdin until
  the port closes.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{SessionResumer, SessionSupervisor, Sessions}

  @claude_stub Path.expand("../support/fixtures/claude_stub_noop.sh", __DIR__)

  describe "resumable?/2 — pure decision logic" do
    test "a running session with no live runner is resumable" do
      assert SessionResumer.resumable?(%{status: "running"}, false)
    end

    test "a running session with an already-live runner is NOT resumable (defensive re-check)" do
      refute SessionResumer.resumable?(%{status: "running"}, true)
    end

    test "waiting/compacting/idle/error/ready sessions are never resumable regardless of alive?" do
      for status <- ~w(waiting compacting idle error ready) do
        refute SessionResumer.resumable?(%{status: status}, false)
        refute SessionResumer.resumable?(%{status: status}, true)
      end
    end
  end

  describe "enabled?/0 — ORCA_AUTO_RESUME toggle" do
    test "defaults to enabled when unset" do
      assert SessionResumer.enabled?()
    end

    test "reads the :auto_resume application env" do
      Application.put_env(:orca_hub, :auto_resume, false)
      on_exit(fn -> Application.delete_env(:orca_hub, :auto_resume) end)

      refute SessionResumer.enabled?()
    end
  end

  describe "Sessions.list_running_sessions_for_node/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "resumer-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "only returns non-archived running sessions owned by this node", %{dir: dir} do
      this_node = Atom.to_string(node())

      {:ok, orphan} =
        Sessions.create_session(%{directory: dir, status: "running", runner_node: this_node})

      {:ok, _other_node} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          runner_node: "not-this-node@nowhere"
        })

      {:ok, _idle} =
        Sessions.create_session(%{directory: dir, status: "idle", runner_node: this_node})

      {:ok, _waiting} =
        Sessions.create_session(%{directory: dir, status: "waiting", runner_node: this_node})

      {:ok, archived} =
        Sessions.create_session(%{directory: dir, status: "running", runner_node: this_node})

      {:ok, _} = Sessions.archive_session(archived)

      result = Sessions.list_running_sessions_for_node(this_node)

      assert Enum.map(result, & &1.id) == [orphan.id]
    end
  end

  describe "resume_session/1 — integration (stubbed CLI)" do
    setup do
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)

      dir =
        Path.join(System.tmp_dir!(), "resumer-integration-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, dir: dir}
    end

    defp stop_if_alive(session_id) do
      if SessionSupervisor.session_alive?(session_id) do
        SessionSupervisor.stop_session(session_id)
      end
    end

    defp message_text(message) do
      get_in(message.data, ["message", "content", Access.at(0), "text"])
    end

    defp wait_for_message(session_id, pattern, timeout_ms \\ 2000) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      poll_for_message(session_id, pattern, deadline)
    end

    defp poll_for_message(session_id, pattern, deadline) do
      match =
        session_id
        |> Sessions.list_messages()
        |> Enum.find(fn m -> (message_text(m) || "") =~ pattern end)

      cond do
        match ->
          match

        System.monotonic_time(:millisecond) > deadline ->
          nil

        true ->
          Process.sleep(20)
          poll_for_message(session_id, pattern, deadline)
      end
    end

    test "starts the runner and sends the system continue message", %{dir: dir} do
      {:ok, session} =
        Sessions.create_session(%{
          directory: dir,
          status: "running",
          runner_node: Atom.to_string(node())
        })

      on_exit(fn -> stop_if_alive(session.id) end)

      assert SessionResumer.resume_session(session) == :ok

      assert SessionSupervisor.session_alive?(session.id)

      message = wait_for_message(session.id, ~r/^\[System\] This node restarted/)
      refute is_nil(message), "expected a [System] continue message to be persisted"
    end
  end
end
