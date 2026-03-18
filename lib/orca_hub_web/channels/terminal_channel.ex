defmodule OrcaHubWeb.TerminalChannel do
  use Phoenix.Channel
  require Logger

  alias OrcaHub.TerminalRunner

  @impl true
  def join("terminal:" <> terminal_id, _params, socket) do
    # Subscribe to the TerminalRunner's broadcast topic.
    # We use "term_output:" prefix to avoid collision with the Phoenix
    # Channel's internal PubSub subscription on "terminal:" topic.
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "term_output:#{terminal_id}")

    scrollback =
      case Registry.lookup(OrcaHub.TerminalRegistry, terminal_id) do
        [{_pid, _}] ->
          TerminalRunner.get_scrollback(terminal_id)

        [] ->
          <<>>
      end

    {:ok, %{scrollback: Base.encode64(scrollback)},
     assign(socket, :terminal_id, terminal_id)}
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        TerminalRunner.write(socket.assigns.terminal_id, bytes)

      :error ->
        Logger.warning("Invalid base64 input for terminal #{socket.assigns.terminal_id}")
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    TerminalRunner.resize(socket.assigns.terminal_id, cols, rows)
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
end
