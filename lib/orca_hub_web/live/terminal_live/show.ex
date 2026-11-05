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
       exit_code: nil,
       page_title: terminal.name
     )}
  end

  @impl true
  def handle_event("start_terminal", _params, socket) do
    terminal = socket.assigns.terminal
    n = socket.assigns.runner_node

    case Cluster.start_terminal(n, terminal.id) do
      {:ok, _pid} ->
        {:noreply, refresh_terminal(socket)}

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
    {:noreply, refresh_terminal(socket)}
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
  def handle_event("terminal_exited", params, socket) do
    code = if is_integer(params["code"]), do: params["code"]
    {:noreply, socket |> assign(exit_code: code) |> refresh_terminal()}
  end

  def handle_event("terminal_status_changed", _params, socket) do
    {:noreply, refresh_terminal(socket)}
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
        refresh_terminal(socket)

      {:error, reason} ->
        put_flash(socket, :error, "Failed to restart: #{inspect(reason)}")
    end
  end

  # A row deleted while this page is open (from the index, another tab)
  # sends the user back to the list instead of crashing on the re-read.
  defp refresh_terminal(socket) do
    current = socket.assigns.terminal

    case get_terminal_safe(socket.assigns.runner_node, current.id, current) do
      :deleted ->
        socket
        |> put_flash(:info, "Terminal #{current.name} was deleted.")
        |> push_navigate(to: ~p"/terminals")

      %{status: "running"} = terminal ->
        assign(socket, terminal: terminal, exit_code: nil)

      terminal ->
        assign(socket, terminal: terminal)
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
  rescue
    Ecto.NoResultsError -> :deleted
  end

  # The hub+agent topology has ONE database — HubRPC.get_terminal!/1 already
  # resolves to it directly regardless of which node calls it, so fanning
  # this out to every connected node and waiting for the slowest to answer
  # (or time out, up to `fan_out`'s timeout + 2s) was pure overhead with a
  # latent multi-second stall risk, not something the single-DB topology
  # needs. See perf_audit_admin_pages.md §2b. runner_node routing for a
  # remote-owned terminal is unaffected: it's derived below from the
  # terminal's own `runner_node` field via Cluster.runner_node_for/1, not
  # from which node happened to answer the fan-out.
  defp find_terminal!(id), do: HubRPC.get_terminal!(id)
end
