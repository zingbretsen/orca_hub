defmodule OrcaHubWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel bridging the browser xterm.js terminal and the
  `OrcaHub.TerminalRunner` PTY process. Forwards keystrokes and resize
  events to the runner (routed across nodes via `OrcaHub.Cluster`) and
  streams PTY output, exit, and status events back to the client.

  The runner can stop at any moment (the shell exits, Stop, Delete, idle
  teardown) while this channel stays joined, so every call into it is
  guarded: a dead runner costs the client its scrollback or a keystroke,
  never the channel.
  """
  use Phoenix.Channel
  require Logger

  alias OrcaHub.{Cluster, HubRPC, TerminalRunner}

  @impl true
  def join("terminal:" <> rest, _params, socket) do
    # `rest` is either a bare terminal id or `<terminal_id>:<client_ref>` —
    # the client_ref makes the topic unique per hook instance so that two
    # hooks for the same terminal (e.g. desktop panel + CSS-hidden mobile
    # modal) don't join an identical topic and knock each other's channel
    # closed. Terminal ids are UUIDs (no colons), so splitting on the first
    # colon is unambiguous.
    terminal_id = rest |> String.split(":", parts: 2) |> List.first()

    # One database (hub); HubRPC resolves to it from any node, no fan-out needed.
    case guarded(fn -> HubRPC.get_terminal(terminal_id) end) do
      %OrcaHub.Terminals.Terminal{} = terminal ->
        # Subscribe to the TerminalRunner's broadcast topic before reading
        # the scrollback, so no output falls between the two. The
        # "term_output:" prefix avoids colliding with the Phoenix Channel's
        # internal PubSub subscription on the "terminal:" topic.
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal_id}")
        runner_node = Cluster.runner_node_for(terminal)

        {:ok, %{scrollback: Base.encode64(attach(runner_node, terminal_id))},
         socket
         |> assign(:terminal_id, terminal_id)
         |> assign(:runner_node, runner_node)}

      nil ->
        {:error, %{reason: "not_found"}}

      {:error, _reason} ->
        {:error, %{reason: "unavailable"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        runner_rpc(socket, :write, [bytes])

      :error ->
        Logger.warning("Invalid base64 input for terminal #{socket.assigns.terminal_id}")
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) do
    runner_rpc(socket, :resize, [cols, rows])
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:terminal_output, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info({:terminal_exit, code}, socket) do
    push(socket, "exit", %{code: code})
    {:noreply, socket}
  end

  def handle_info({:terminal_status, status}, socket) do
    # A restarted runner starts with no clients; this channel stays joined
    # across the restart, so it attaches to the new one.
    if status == :running, do: attach(socket.assigns.runner_node, socket.assigns.terminal_id)

    push(socket, "status", %{status: to_string(status)})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Registers this channel with the runner (which monitors it: a terminal
  # with a viewer is never idle-stopped) and returns its scrollback. Empty
  # when no runner is alive (or it stopped between the lookup and the call,
  # or its node is unreachable).
  defp attach(runner_node, terminal_id) do
    case guarded(fn ->
           Cluster.rpc(runner_node, TerminalRunner, :attach, [terminal_id, self()])
         end) do
      {:ok, data} when is_binary(data) -> data
      _ -> <<>>
    end
  end

  defp runner_rpc(socket, fun, args) do
    guarded(fn ->
      Cluster.rpc(socket.assigns.runner_node, TerminalRunner, fun, [
        socket.assigns.terminal_id | args
      ])
    end)
  end

  # A GenServer.call to a runner that just stopped exits with :noproc
  # locally and raises an ErlangError through :erpc; neither may take the
  # channel down.
  defp guarded(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end
end
