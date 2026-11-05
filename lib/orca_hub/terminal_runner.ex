defmodule OrcaHub.TerminalRunner do
  @moduledoc """
  GenServer that manages a PTY shell process for a terminal.

  Opens a PTY via `script -qc <shell> /dev/null`, reads output,
  and broadcasts it via PubSub. Input is written via Port.command/2.

  ## Teardown

  The PTY is spawned through `OrcaHub.ProcessIsolation`, exactly like an
  agent CLI: its own cgroup leaf where the unit delegates one, an inherited
  env marker always. Every way a runner ends kills the shell's whole process
  tree, not just the port:

    * stop (`TerminalSupervisor.stop_terminal/1`, node shutdown): the runner
      traps exits, so `terminate/2` runs. It closes the port, SIGKILLs
      `script`'s process group (which hangs up the pty, so the shell gets
      SIGHUP) and hands the spawn to the reaper, which kills whatever is left
      (a foreground job, a `nohup`ed one).
    * the row is deleted: `Terminals.delete_terminal/1` broadcasts on the
      runner's control topic, and a periodic row check covers a delete the
      broadcast missed. The runner stops itself the same way.
    * the shell exits (`exit`, Ctrl+D): one `{:terminal_exit, code}`
      broadcast, status `"dead"`, and the shell's leftovers are reaped.
    * the runner crashes: `terminate/2` runs for a callback crash. A brutal
      kill skips it, but ProcessIsolation monitors the runner and reaps the
      spawn anyway.

  Before this, teardown was a bare `Port.close/1`: a shell at an idle prompt
  exited on the stdin EOF, but one running a foreground job, and every
  `nohup`ed job, outlived the terminal.
  """
  use GenServer
  require Logger

  alias OrcaHub.{HubRPC, OSProcess, ProcessIsolation}

  @scrollback_size 64 * 1024

  # How often a running terminal confirms its row still exists (the
  # fallback for a delete whose control broadcast it missed).
  @row_check_ms 60_000

  # The reaper's grace after a stop: the shell gets SIGHUP from the pty
  # hangup and normally exits (saving its history) well inside this.
  @stop_reap_grace_ms 500

  # API

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    terminal_id = Keyword.fetch!(opts, :terminal_id)
    GenServer.start_link(__MODULE__, opts, name: via(terminal_id))
  end

  def via(terminal_id), do: {:via, Registry, {OrcaHub.TerminalRegistry, terminal_id}}

  @doc "The topic `Terminals.delete_terminal/1` tells a still-running runner on."
  def control_topic(terminal_id), do: "term_control:#{terminal_id}"

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
    # So a supervisor stop (stop_terminal, node shutdown) runs terminate/2,
    # which is what kills the shell's process tree.
    Process.flag(:trap_exit, true)

    terminal_id = Keyword.fetch!(opts, :terminal_id)

    case HubRPC.get_terminal(terminal_id) do
      nil ->
        Logger.warning("Terminal #{terminal_id} not found in database, stopping runner")
        {:stop, :normal}

      terminal ->
        init_terminal(terminal_id, terminal, opts)
    end
  end

  defp init_terminal(terminal_id, terminal, opts) do
    {port, os_pid, spawn} = open_pty(terminal)

    HubRPC.update_terminal(terminal, %{
      status: "running",
      runner_node: Atom.to_string(node())
    })

    Phoenix.PubSub.subscribe(OrcaHub.PubSub, control_topic(terminal_id))
    row_check_ms = Keyword.get(opts, :row_check_ms, @row_check_ms)
    schedule_row_check(row_check_ms)

    broadcast(terminal_id, {:terminal_status, :running})

    {:ok,
     %{
       terminal_id: terminal_id,
       port: port,
       os_pid: os_pid,
       spawn: spawn,
       directory: terminal.directory,
       shell: terminal.shell || "/bin/bash",
       cols: terminal.cols || 120,
       rows: terminal.rows || 40,
       scrollback: <<>>,
       row_check_ms: row_check_ms,
       # true once the row's final status is written and broadcast, so
       # terminate/2 never overwrites "dead" with "stopped" or broadcasts twice.
       finalized: false
     }}
  end

  @impl true
  def handle_cast({:write, data}, %{port: port} = state) when not is_nil(port) do
    Port.command(port, data)
    {:noreply, state}
  end

  def handle_cast({:write, _data}, state), do: {:noreply, state}

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

    # The shell is gone; reap whatever it left behind (a `nohup`ed job).
    ProcessIsolation.release(state.spawn)
    write_status(state.terminal_id, %{status: "dead"})
    broadcast(state.terminal_id, {:terminal_exit, code})

    {:stop, :normal, %{state | port: nil, spawn: nil, finalized: true}}
  end

  def handle_info({:terminal_deleted, terminal_id}, %{terminal_id: terminal_id} = state) do
    Logger.info("Terminal #{terminal_id} was deleted, stopping its runner")
    {:stop, {:shutdown, :deleted}, state}
  end

  def handle_info(:row_check, state) do
    case safe_hub(fn -> HubRPC.get_terminal(state.terminal_id) end) do
      nil ->
        Logger.info("Terminal #{state.terminal_id} row is gone, stopping its runner")
        {:stop, {:shutdown, :deleted}, state}

      _terminal_or_hub_error ->
        schedule_row_check(state.row_check_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    state = kill_tree(state, @stop_reap_grace_ms)
    finalize(state, final_status(reason))
    :ok
  end

  # Private

  # The shell's whole tree, never just the pipe. `script` is the port's
  # os_pid (ProcessIsolation's wrapper `exec`s it) and leads its own process
  # group (erl_child_setup setsid()s every port child): killing that group
  # closes the pty master, so the kernel hangs up the shell's session with
  # SIGHUP. The reaper then kills anything that ignored it, by cgroup leaf
  # or env marker.
  defp kill_tree(%{port: nil} = state, grace_ms) do
    ProcessIsolation.release(state.spawn, grace_ms: grace_ms)
    %{state | spawn: nil}
  end

  defp kill_tree(state, grace_ms) do
    try do
      Port.close(state.port)
    rescue
      # Port.close/1 raises ArgumentError when the port is already closed.
      ArgumentError -> :ok
    end

    if is_integer(state.os_pid), do: OSProcess.signal_group(state.os_pid, "KILL")

    kill_tree(%{state | port: nil}, grace_ms)
  end

  defp final_status({:shutdown, :deleted}), do: :deleted
  defp final_status(reason) when reason in [:normal, :shutdown], do: :stopped
  defp final_status({:shutdown, _}), do: :stopped
  defp final_status(_crash), do: :dead

  defp finalize(%{finalized: true}, _status), do: :ok

  defp finalize(state, :deleted) do
    broadcast(state.terminal_id, {:terminal_status, :deleted})
  end

  defp finalize(state, status) do
    write_status(state.terminal_id, %{status: Atom.to_string(status)})
    broadcast(state.terminal_id, {:terminal_status, status})
  end

  # Teardown must never crash on the way out: the hub can be unreachable (an
  # agent node shutting down) or the row already gone.
  defp write_status(terminal_id, attrs) do
    safe_hub(fn ->
      case HubRPC.get_terminal(terminal_id) do
        nil -> :ok
        terminal -> HubRPC.update_terminal(terminal, attrs)
      end
    end)
  end

  defp safe_hub(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp schedule_row_check(ms) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :row_check, ms)

  defp schedule_row_check(_ms), do: :ok

  # Returns `{port, os_pid, spawn}`. A spawn whose port never opened is
  # released here, like SessionRunner.open_backend_port/3.
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

        # -e: exit with the shell's own status, not script's 0.
        _ ->
          ["-qec", shell, "/dev/null"]
      end

    env =
      terminal_env(
        [
          {~c"TERM", ~c"xterm-256color"},
          {~c"COLUMNS", ~c"#{cols}"},
          {~c"LINES", ~c"#{rows}"}
        ],
        terminal.project_id
      )

    spawn = ProcessIsolation.prepare("terminal-#{terminal.id}")

    try do
      {executable, args, env} = ProcessIsolation.wrap(spawn, script_path, script_args, env)

      port =
        Port.open(
          {:spawn_executable, executable},
          [:binary, :exit_status, {:args, args}, {:cd, directory}, {:env, env}]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {port, os_pid, spawn}
    rescue
      e ->
        ProcessIsolation.release(spawn, grace_ms: 0)
        reraise e, __STACKTRACE__
    end
  end

  # Same per-node scrub policy as agent-CLI sessions (OrcaHub.Backend.Claude/
  # Codex/Pi) — a web terminal on a node running untrusted-triggered sessions
  # shouldn't expose pod/host secrets any more than the agent CLI does.
  # `project_id` (nil-able — a terminal isn't required to belong to a
  # project) feeds the same node+project env_allowlist extension the agent
  # backends use (Stage 2).
  defp terminal_env(extra, project_id) do
    if OrcaHub.NodePolicy.scrub_session_env?() do
      OrcaHub.Env.strict_env(extra, OrcaHub.NodePolicy.extra_env_allowlist(project_id))
    else
      OrcaHub.Env.sanitized_env(extra)
    end
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
