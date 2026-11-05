defmodule OrcaHubWeb.TerminalChannelTest do
  @moduledoc """
  Coverage for the duplicate-join fix: two hooks for the same terminal
  (desktop panel + CSS-hidden mobile modal) must join distinct topics —
  `terminal:<id>:<client_ref>` — rather than colliding on `terminal:<id>`
  and knocking each other's channel closed. Also covers the plain
  unsuffixed topic for backward compatibility (fullscreen `TerminalLive.Show`).
  """
  # async: false — TerminalChannel.join/3 resolves the terminal via
  # Cluster.fan_out, which calls :erpc.call/5 even for the local node; the
  # spawned erpc process needs the shared sandbox connection async: true
  # (per-test manual ownership) doesn't extend to.
  use OrcaHub.DataCase, async: false

  import Phoenix.ChannelTest

  alias OrcaHub.{Projects, Terminals}
  alias OrcaHubWeb.{TerminalChannel, UserSocket}

  @endpoint OrcaHubWeb.Endpoint

  setup do
    dir =
      Path.join(System.tmp_dir!(), "terminal_channel_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "terminal-channel-test-#{System.unique_integer([:positive])}",
        directory: dir,
        node: to_string(node())
      })

    {:ok, terminal} =
      Terminals.create_terminal(%{name: "t1", directory: dir, project_id: project.id})

    {:ok, terminal: terminal}
  end

  describe "join/3" do
    test "plain unsuffixed topic still joins (backward compatible)", %{terminal: terminal} do
      {:ok, reply, socket} =
        subscribe_and_join(
          socket(UserSocket, nil, %{}),
          TerminalChannel,
          "terminal:#{terminal.id}",
          %{}
        )

      assert %{scrollback: _} = reply
      assert socket.assigns.terminal_id == terminal.id
    end

    test "suffixed client-ref topic joins and parses the terminal id", %{terminal: terminal} do
      {:ok, reply, socket} =
        subscribe_and_join(
          socket(UserSocket, nil, %{}),
          TerminalChannel,
          "terminal:#{terminal.id}:client-a",
          %{}
        )

      assert %{scrollback: _} = reply
      assert socket.assigns.terminal_id == terminal.id
    end

    test "two joins from the same socket with different client refs both stay joined and both receive a broadcast",
         %{terminal: terminal} do
      socket = socket(UserSocket, nil, %{})

      {:ok, _reply, socket1} =
        subscribe_and_join(socket, TerminalChannel, "terminal:#{terminal.id}:client-a", %{})

      {:ok, _reply2, socket2} =
        subscribe_and_join(socket, TerminalChannel, "terminal:#{terminal.id}:client-b", %{})

      assert Process.alive?(socket1.channel_pid)
      assert Process.alive?(socket2.channel_pid)
      refute socket1.channel_pid == socket2.channel_pid

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "term_output:#{terminal.id}",
        {:terminal_output, "hi"}
      )

      encoded = Base.encode64("hi")
      assert_push "output", %{data: ^encoded}
      assert_push "output", %{data: ^encoded}

      assert Process.alive?(socket1.channel_pid)
      assert Process.alive?(socket2.channel_pid)
    end

    test "a deleted terminal is refused, not crashed on", %{terminal: terminal} do
      {:ok, _} = Terminals.delete_terminal(terminal)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(
                 socket(UserSocket, nil, %{}),
                 TerminalChannel,
                 "terminal:#{terminal.id}:client-a",
                 %{}
               )
    end
  end

  describe "with a live runner" do
    if System.find_executable("script") && match?({:unix, :linux}, :os.type()) do
      setup %{terminal: terminal} do
        {:ok, pid} = OrcaHub.TerminalSupervisor.start_terminal(terminal.id)
        on_exit(fn -> OrcaHub.TerminalSupervisor.stop_terminal(terminal.id) end)
        {:ok, runner: pid}
      end

      test "join attaches the channel to the runner; leaving detaches it", %{
        terminal: terminal,
        runner: runner
      } do
        {:ok, _reply, socket} =
          subscribe_and_join(
            socket(UserSocket, nil, %{}),
            TerminalChannel,
            "terminal:#{terminal.id}:client-a",
            %{}
          )

        channel = socket.channel_pid
        assert Map.has_key?(:sys.get_state(runner).clients, channel)

        Process.unlink(channel)
        ref = Process.monitor(channel)
        close(socket)
        assert_receive {:DOWN, ^ref, _, _, _}

        assert eventually(fn -> not Map.has_key?(:sys.get_state(runner).clients, channel) end)
      end

      test "input to a runner that has stopped does not take the channel down", %{
        terminal: terminal
      } do
        {:ok, _reply, socket} =
          subscribe_and_join(
            socket(UserSocket, nil, %{}),
            TerminalChannel,
            "terminal:#{terminal.id}:client-a",
            %{}
          )

        :ok = OrcaHub.TerminalSupervisor.stop_terminal(terminal.id)
        push(socket, "input", %{"data" => Base.encode64("ls\n")})
        push(socket, "resize", %{"cols" => 100, "rows" => 30})
        ref = push(socket, "ping-unknown", %{})

        refute_reply ref, _
        assert Process.alive?(socket.channel_pid)
      end
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> false
    end
  end
end
