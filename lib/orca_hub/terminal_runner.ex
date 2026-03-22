defmodule OrcaHub.TerminalRunner do
  @moduledoc """
  GenServer that manages a PTY shell process for a terminal.

  Opens a PTY via `script -qc /bin/bash /dev/null`, reads output,
  and broadcasts it via PubSub. Input is written via Port.command/2.
  """
  use GenServer
  require Logger

  alias OrcaHub.HubRPC

  @scrollback_size 64 * 1024

  # API

  def start_link(opts) do
    terminal_id = Keyword.fetch!(opts, :terminal_id)
    GenServer.start_link(__MODULE__, opts, name: via(terminal_id))
  end

  def via(terminal_id), do: {:via, Registry, {OrcaHub.TerminalRegistry, terminal_id}}

  def write(terminal_id, data) do
    GenServer.cast(via(terminal_id), {:write, data})
  end

  def resize(terminal_id, cols, rows) do
    GenServer.cast(via(terminal_id), {:resize, cols, rows})
  end

  def get_scrollback(terminal_id) do
    GenServer.call(via(terminal_id), :get_scrollback)
  end

  def stop(terminal_id) do
    GenServer.stop(via(terminal_id), :normal)
  end

  # Callbacks

  @impl true
  def init(opts) do
    terminal_id = Keyword.fetch!(opts, :terminal_id)

    case HubRPC.get_terminal(terminal_id) do
      nil ->
        Logger.warning("Terminal #{terminal_id} not found in database, stopping runner")
        {:stop, :normal}

      terminal ->
        init_terminal(terminal_id, terminal)
    end
  end

  defp init_terminal(terminal_id, terminal) do
    HubRPC.update_terminal(terminal, %{
      status: "running",
      runner_node: Atom.to_string(node())
    })

    port = open_pty(terminal)

    broadcast(terminal_id, {:terminal_status, :running})

    {:ok,
     %{
       terminal_id: terminal_id,
       port: port,
       directory: terminal.directory,
       shell: terminal.shell || "/bin/bash",
       cols: terminal.cols || 120,
       rows: terminal.rows || 40,
       scrollback: <<>>
     }}
  end

  @impl true
  def handle_cast({:write, data}, %{port: port} = state) do
    Port.command(port, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    # Update stored size — actual PTY resize requires ioctl which
    # is non-trivial with the `script` wrapper. For now we store
    # the size and it takes effect on next terminal restart.
    terminal = HubRPC.get_terminal!(state.terminal_id)
    HubRPC.update_terminal(terminal, %{cols: cols, rows: rows})
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_call(:get_scrollback, _from, state) do
    {:reply, state.scrollback, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    broadcast(state.terminal_id, {:terminal_output, data})

    scrollback = truncate_scrollback(state.scrollback <> data, @scrollback_size)

    {:noreply, %{state | scrollback: scrollback}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.info("Terminal #{state.terminal_id} exited with code #{code}")

    case HubRPC.get_terminal(state.terminal_id) do
      nil -> :ok
      terminal -> HubRPC.update_terminal(terminal, %{status: "dead"})
    end

    broadcast(state.terminal_id, {:terminal_exit, code})

    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    case HubRPC.get_terminal(state.terminal_id) do
      nil -> :ok
      terminal -> HubRPC.update_terminal(terminal, %{status: "stopped", runner_node: nil})
    end

    broadcast(state.terminal_id, {:terminal_status, :stopped})
    :ok
  end

  # Private

  defp open_pty(terminal) do
    script_path = System.find_executable("script") || raise "script executable not found"
    shell = terminal.shell || "/bin/bash"
    directory = terminal.directory
    cols = terminal.cols || 120
    rows = terminal.rows || 40

    File.mkdir_p!(directory)

    script_args =
      case :os.type() do
        {:unix, :darwin} ->
          ["-q", "/dev/null", shell]

        _ ->
          ["-qc", shell, "/dev/null"]
      end

    Port.open(
      {:spawn_executable, script_path},
      [:binary, :exit_status,
       {:args, script_args},
       {:cd, directory},
       {:env, [
         {~c"TERM", ~c"xterm-256color"},
         {~c"COLUMNS", ~c"#{cols}"},
         {~c"LINES", ~c"#{rows}"}
       ]}]
    )
  end

  defp broadcast(terminal_id, payload) do
    # Use "term_output:" prefix for per-terminal broadcasts to avoid
    # colliding with Phoenix Channel's internal PubSub on "terminal:" topic
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "term_output:#{terminal_id}", payload)
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "terminals", {terminal_id, payload})
  end

  defp truncate_scrollback(data, max_size) when byte_size(data) > max_size do
    skip = byte_size(data) - max_size
    binary_part(data, skip, max_size)
  end

  defp truncate_scrollback(data, _max_size), do: data
end
