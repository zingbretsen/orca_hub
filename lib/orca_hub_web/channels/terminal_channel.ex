defmodule OrcaHubWeb.TerminalChannel do
  use Phoenix.Channel
  require Logger

  alias OrcaHub.{Cluster, HubRPC, TerminalRunner}

  @impl true
  def join("terminal:" <> terminal_id, _params, socket) do
    # Subscribe to the TerminalRunner's broadcast topic.
    # We use "term_output:" prefix to avoid collision with the Phoenix
    # Channel's internal PubSub subscription on "terminal:" topic.
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal_id}")

    terminal = find_terminal!(terminal_id)
    runner_node = Cluster.runner_node_for(terminal)

    scrollback =
      if Cluster.terminal_alive?(runner_node, terminal_id) do
        Cluster.rpc(runner_node, TerminalRunner, :get_scrollback, [terminal_id])
      else
        <<>>
      end

    {:ok, %{scrollback: Base.encode64(scrollback)},
     socket
     |> assign(:terminal_id, terminal_id)
     |> assign(:runner_node, runner_node)}
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        Cluster.rpc(socket.assigns.runner_node, TerminalRunner, :write, [socket.assigns.terminal_id, bytes])

      :error ->
        Logger.warning("Invalid base64 input for terminal #{socket.assigns.terminal_id}")
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Cluster.rpc(socket.assigns.runner_node, TerminalRunner, :resize, [socket.assigns.terminal_id, cols, rows])
    {:noreply, socket}
  end

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
    push(socket, "status", %{status: to_string(status)})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp find_terminal!(id) do
    results = Cluster.fan_out(HubRPC, :get_terminal, [id])

    case Enum.find(results, fn {_n, t} -> t != nil end) do
      {_n, terminal} -> terminal
      nil -> raise Ecto.NoResultsError, queryable: OrcaHub.Terminals.Terminal
    end
  end
end
