defmodule OrcaHubWeb.TerminalLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    terminal = find_terminal!(id)
    n = Cluster.runner_node_for(terminal)

    # Status and exit events for every terminal (never output); see
    # TerminalRunner.broadcast/2. Without this a stop, an idle teardown or
    # an exit while no xterm was mounted would never reach this page.
    if connected?(socket), do: Phoenix.PubSub.subscribe(OrcaHub.PubSub, "terminals")

    {:ok,
     socket
     |> assign(
       terminal: terminal,
       runner_node: n,
       exit_code: nil,
       page_title: terminal.name
     )
     |> assign_status()}
  end

  @impl true
  def handle_event("start_terminal", _params, socket) do
    {:noreply, start(socket, "Failed to start")}
  end

  def handle_event("stop_terminal", _params, socket) do
    case Cluster.stop_terminal(socket.assigns.runner_node, socket.assigns.terminal.id) do
      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, Cluster.terminal_stop_error_message(reason))
         |> refresh_terminal()}

      _stopped_or_reconciled ->
        {:noreply, refresh_terminal(socket)}
    end
  end

  # The stop is synchronous (the old runner and its shell are gone when it
  # returns), so the start can follow immediately.
  def handle_event("restart_terminal", _params, socket) do
    case Cluster.stop_terminal(socket.assigns.runner_node, socket.assigns.terminal.id) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Cluster.terminal_stop_error_message(reason))}

      _stopped_or_not_running ->
        {:noreply, start(socket, "Failed to restart")}
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
  def handle_info({id, {:terminal_exit, code}}, %{assigns: %{terminal: %{id: id}}} = socket) do
    {:noreply, socket |> assign(exit_code: code) |> refresh_terminal()}
  end

  def handle_info({id, {:terminal_status, _status}}, %{assigns: %{terminal: %{id: id}}} = socket) do
    {:noreply, refresh_terminal(socket)}
  end

  def handle_info(_other_terminal_event, socket), do: {:noreply, socket}

  defp start(socket, failure) do
    case Cluster.start_terminal(socket.assigns.runner_node, socket.assigns.terminal.id) do
      {:ok, _pid} ->
        refresh_terminal(socket)

      {:error, {:already_started, _}} ->
        refresh_terminal(socket)

      {:error, reason} ->
        message = Cluster.terminal_node_error_message(reason) || "#{failure}: #{inspect(reason)}"
        put_flash(socket, :error, message)
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

      terminal ->
        socket |> assign(terminal: terminal) |> assign_status()
    end
  end

  # @status is what the page shows and branches on: a live runner wins over
  # the row, so a row left "running" by a node restart shows "dead" with a
  # Start button instead of a Stop that hits nothing.
  defp assign_status(socket) do
    %{terminal: terminal, runner_node: n} = socket.assigns
    liveness = Map.get(Cluster.terminal_liveness([{n, terminal}]), terminal.id, :unknown)
    status = Cluster.terminal_display_status(terminal, liveness)

    socket
    |> assign(status: status, node_unreachable: liveness == :unknown)
    |> then(fn s -> if status == "running", do: assign(s, exit_code: nil), else: s end)
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
