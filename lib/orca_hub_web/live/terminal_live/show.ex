defmodule OrcaHubWeb.TerminalLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    terminal = find_terminal!(id)
    n = Cluster.runner_node_for(terminal)

    {:ok,
     socket
     |> assign(
       terminal: terminal,
       runner_node: n,
       page_title: terminal.name
     )}
  end

  @impl true
  def handle_event("start_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = socket.assigns.runner_node

    case Cluster.start_terminal(n, terminal.id) do
      {:ok, _pid} ->
        terminal = Cluster.get_terminal!(n, terminal.id)
        {:noreply, assign(socket, terminal: terminal)}

      {:error, {:already_started, _}} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = socket.assigns.runner_node
    Cluster.stop_terminal(n, terminal.id)
    {:noreply, assign(socket, terminal: get_terminal_safe(n, terminal.id, terminal))}
  end

  def handle_event("restart_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = socket.assigns.runner_node

    if terminal.status == "running" do
      # Stop, then give the PTY a moment to release before starting again.
      # Non-blocking: continue in the :restart_terminal handle_info clause.
      Cluster.stop_terminal(n, terminal.id)
      Process.send_after(self(), :restart_terminal, 200)
      {:noreply, socket}
    else
      {:noreply, start_terminal_for_restart(socket)}
    end
  end

  # These events come from the JS hook via pushEvent when the
  # Channel receives exit/status messages from the TerminalRunner
  def handle_event("terminal_exited", _params, socket) do
    n = socket.assigns.runner_node
    current = socket.assigns.terminal
    {:noreply, assign(socket, terminal: get_terminal_safe(n, current.id, current))}
  end

  def handle_event("terminal_status_changed", _params, socket) do
    n = socket.assigns.runner_node
    current = socket.assigns.terminal
    {:noreply, assign(socket, terminal: get_terminal_safe(n, current.id, current))}
  end

  @impl true
  def handle_info(:restart_terminal, socket) do
    {:noreply, start_terminal_for_restart(socket)}
  end

  defp start_terminal_for_restart(socket) do
    terminal = socket.assigns.terminal
    n = socket.assigns.runner_node

    case Cluster.start_terminal(n, terminal.id) do
      {:ok, _pid} ->
        assign(socket, terminal: Cluster.get_terminal!(n, terminal.id))

      {:error, reason} ->
        put_flash(socket, :error, "Failed to restart: #{inspect(reason)}")
    end
  end

  # Cluster.get_terminal!/2 refuses ({:error, ...}) rather than raising when
  # `n` is offline/unassigned — fall back to the terminal we already have
  # rather than assigning the error tuple as @terminal (which would crash
  # every field access in the template).
  defp get_terminal_safe(n, terminal_id, fallback) do
    case Cluster.get_terminal!(n, terminal_id) do
      %OrcaHub.Terminals.Terminal{} = terminal -> terminal
      _ -> fallback
    end
  end

  defp find_terminal!(id) do
    # Fan out to find the terminal across all hub DBs
    results = Cluster.fan_out(HubRPC, :get_terminal, [id])

    case Enum.find(results, fn {_n, t} -> t != nil end) do
      {_n, terminal} -> terminal
      nil -> raise Ecto.NoResultsError, queryable: OrcaHub.Terminals.Terminal
    end
  end
end
