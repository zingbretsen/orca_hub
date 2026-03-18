defmodule OrcaHubWeb.TerminalLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    terminal = HubRPC.get_terminal!(id)

    {:ok,
     socket
     |> assign(
       terminal: terminal,
       page_title: terminal.name
     )}
  end

  @impl true
  def handle_event("start_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = runner_node(terminal)

    case Cluster.start_terminal(n, terminal.id) do
      {:ok, _pid} ->
        terminal = HubRPC.get_terminal!(terminal.id)
        {:noreply, assign(socket, terminal: terminal)}

      {:error, {:already_started, _}} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = runner_node(terminal)
    Cluster.stop_terminal(n, terminal.id)
    terminal = HubRPC.get_terminal!(terminal.id)
    {:noreply, assign(socket, terminal: terminal)}
  end

  def handle_event("restart_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = runner_node(terminal)

    if terminal.status == "running" do
      Cluster.stop_terminal(n, terminal.id)
      Process.sleep(200)
    end

    case Cluster.start_terminal(n, terminal.id) do
      {:ok, _pid} ->
        terminal = HubRPC.get_terminal!(terminal.id)
        {:noreply, assign(socket, terminal: terminal)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restart: #{inspect(reason)}")}
    end
  end

  # These events come from the JS hook via pushEvent when the
  # Channel receives exit/status messages from the TerminalRunner
  def handle_event("terminal_exited", _params, socket) do
    terminal = HubRPC.get_terminal!(socket.assigns.terminal.id)
    {:noreply, assign(socket, terminal: terminal)}
  end

  def handle_event("terminal_status_changed", _params, socket) do
    terminal = HubRPC.get_terminal!(socket.assigns.terminal.id)
    {:noreply, assign(socket, terminal: terminal)}
  end

  defp runner_node(terminal) do
    Cluster.runner_node_for(terminal)
  end
end
