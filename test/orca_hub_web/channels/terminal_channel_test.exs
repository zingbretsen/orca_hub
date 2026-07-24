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
  end
end
