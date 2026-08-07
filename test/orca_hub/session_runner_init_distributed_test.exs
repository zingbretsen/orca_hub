defmodule OrcaHub.SessionRunnerInitDistributedTest do
  @moduledoc """
  Split out of session_runner_init_test.exs (same reasoning as
  cluster_distributed_test.exs): reproducing "db node predates a function"
  requires the test VM to become a real distributed Erlang node, which is
  process-wide state that races with unrelated async tests — see that
  module's moduledoc for the two-pass `mix test` / `mix test --only
  distributed` split this file relies on.

  Covers the agent -> hub direction of the mixed-version-cluster hazard
  a92cd11 fixed for the hub -> agent direction (SessionLive.Show.
  load_runner_status/3): `SessionRunner.init/1` calls
  `HubRPC.list_messages_window/2` (new alongside 9ddb4bf's bounded-tail
  change) via `db_call/3`, which — unlike `Cluster.rpc/5` — does a raw
  `:erpc.call` and does NOT convert `:undef` into a tagged error tuple. Left
  unhandled, a db node that hasn't been redeployed with that function yet
  would crash `init/1`, refusing to start every session on this runner node
  until the db node's release catches up.
  """
  use OrcaHub.DataCase, async: false

  @moduletag :distributed

  alias OrcaHub.{SessionRunner, Sessions}

  describe "init/1 — db node that predates list_messages_window/2" do
    setup do
      # Same as cluster_distributed_test.exs's setup: ClusterNodeTracker
      # writes to the DB (from its own process, outside this test's Ecto
      # sandbox checkout) whenever a real :nodeup fires.
      Supervisor.terminate_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker)
      on_exit(fn -> Supervisor.restart_child(OrcaHub.Supervisor, OrcaHub.ClusterNodeTracker) end)

      unless Node.alive?() do
        {:ok, hostname} = :inet.gethostname()
        {:ok, _pid} = Node.start(:"session_runner_init_test@#{hostname}", :shortnames)
      end

      {:ok, peer_pid, peer_node} =
        :peer.start_link(%{
          name: :"session_runner_init_peer_#{System.unique_integer([:positive])}"
        })

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # Give the bare peer JUST enough to compile/run plain Elixir source
      # (its own Elixir/compiler/logger — NOT orca_hub's or any dep's ebin,
      # so the real OrcaHub.HubRPC is never reachable there) so we can
      # define a stand-in OrcaHub.HubRPC module that answers everything
      # SessionRunner.init/1 needs EXCEPT list_messages_window/2 — the same
      # "connected node running an older release" shape as
      # cluster_distributed_test.exs's bare peer, just with enough on it to
      # simulate a specific missing function instead of a totally absent
      # module.
      support_paths =
        :code.get_path()
        |> Enum.filter(fn p ->
          s = to_string(p)

          String.contains?(s, "/lib/elixir/ebin") or String.contains?(s, "/lib/logger/ebin") or
            String.contains?(s, "/lib/compiler-") or String.contains?(s, "/lib/eex/ebin")
        end)

      :erpc.call(peer_node, :code, :add_paths, [support_paths])
      {:ok, _} = :erpc.call(peer_node, Application, :ensure_all_started, [:elixir])

      fake_hub_rpc = """
      defmodule OrcaHub.HubRPC do
        def list_messages(_session_id) do
          [
            %{
              data: %{
                "type" => "assistant",
                "message" => %{"content" => [%{"type" => "text", "text" => "legacy path"}]}
              },
              inserted_at: ~N[2026-01-01 00:00:00]
            }
          ]
        end

        def get_run_by_session_id(_session_id), do: nil
        def get_a2a_task_by_session_id(_session_id), do: nil
        def update_session(_session, _attrs), do: :ok
      end
      """

      [{OrcaHub.HubRPC, _binary}] =
        :erpc.call(peer_node, Code, :compile_string, [fake_hub_rpc])

      dir =
        Path.join(
          System.tmp_dir!(),
          "runner_init_distributed_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # No project/issue — commit_trailer?/2 and issue_key/2 short-circuit on
      # nil without a db_call, so the fake peer only needs to answer the
      # handful of functions stubbed above.
      {:ok, session} = Sessions.create_session(%{directory: dir, backend: "claude"})

      %{peer_node: peer_node, session: session}
    end

    test "falls back to list_messages/1 instead of crashing init/1", %{
      peer_node: peer_node,
      session: session
    } do
      assert {:ok, :idle, data} =
               SessionRunner.init(
                 session_id: session.id,
                 session_data: session,
                 db_node: peer_node
               )

      assert [%{"message" => %{"content" => [%{"text" => "legacy path"}]}}] = data.messages
    end
  end
end
