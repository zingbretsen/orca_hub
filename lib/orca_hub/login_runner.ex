defmodule OrcaHub.LoginRunner do
  @moduledoc """
  GenServer that logs a node into Claude Code from the web UI.

  Runs `claude setup-token` under a PTY (`script -qc`, the same pattern as
  `TerminalRunner`/`SessionRunner`). `setup-token` walks an OAuth flow: on a
  headless host (where the localhost callback can't bind) it falls back to
  printing an authorize URL and a "paste the code here" prompt, then prints a
  long-lived OAuth token to stdout. We scrape the URL (a convenience), accept
  the pasted code, capture the final token, and persist it keyed by node
  (`OrcaHub.NodeCredentials`) so it can be injected into `claude` sessions.

  `setup-token` is a full ANSI/ink TUI, not plain text. We force a wide PTY
  (`stty cols 400`) so the URL and token don't hard-wrap, strip ANSI escapes
  server-side, and broadcast the cleaned text so the LiveView can render it in
  a plain `<pre>`.

  Singleton per node (named `__MODULE__`); started under `LoginSupervisor`.
  Output and lifecycle events are broadcast on `node_login:<node>` via PubSub,
  which auto-distributes across the cluster so a hub LiveView sees events from
  an agent node.

  Security: the captured token is a long-lived secret. It is never logged and
  never broadcast — only a `:success` signal is. The raw stream is broadcast
  for visibility, but the token only appears after the user pastes their code,
  at which point we stop streaming and finish.
  """

  use GenServer
  require Logger

  alias OrcaHub.HubRPC

  # 5 minutes — the user has to open the URL, authorize, and paste a code.
  @timeout 5 * 60 * 1000

  # ── API ───────────────────────────────────────────────────────────────

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start (or restart) the login flow on THIS node. Intended to be invoked via
  `Cluster.rpc(target_node, OrcaHub.LoginRunner, :start_login, [])`.
  """
  def start_login do
    case DynamicSupervisor.start_child(OrcaHub.LoginSupervisor, __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # A previous attempt is still alive — tear it down and start fresh.
        DynamicSupervisor.terminate_child(OrcaHub.LoginSupervisor, pid)
        DynamicSupervisor.start_child(OrcaHub.LoginSupervisor, __MODULE__)

      other ->
        other
    end
  end

  @doc "Write the pasted OAuth code to the running flow's stdin."
  def submit_code(code) when is_binary(code) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, {:submit_code, code})
    end
  end

  @doc "Cancel an in-progress login flow on this node."
  def cancel do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # ── Callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    port = open_pty()
    timer = Process.send_after(self(), :login_timeout, @timeout)

    broadcast({:login_status, :running})

    {:ok,
     %{
       port: port,
       buffer: <<>>,
       url: nil,
       timer: timer,
       done: false
     }}
  end

  @impl true
  def handle_cast({:submit_code, code}, %{port: port} = state) when not is_nil(port) do
    # `setup-token` is an ink TUI. If the code and a trailing "\r" arrive in
    # the same stdin write, ink treats it as a paste and the "\r" never
    # registers as an Enter keypress — the field fills but doesn't submit
    # until a second write arrives. Write the code and the Enter as two
    # separate port writes, a beat apart, so ink sees a real keypress.
    Port.command(port, String.trim(code))
    Process.send_after(self(), :press_enter, 150)
    {:noreply, state}
  end

  def handle_cast({:submit_code, _code}, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    cleaned = strip_ansi(buffer)

    broadcast({:login_output, cleaned})

    state = %{state | buffer: buffer}
    state = maybe_broadcast_url(state, cleaned)

    case scrape_token(cleaned) do
      nil -> {:noreply, state}
      token -> {:stop, :normal, finish_success(state, token)}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    if state.done do
      {:stop, :normal, %{state | port: nil}}
    else
      # Exited without us scraping a token — last chance from final output.
      case scrape_token(strip_ansi(state.buffer)) do
        nil ->
          broadcast({:login_done, {:error, "claude setup-token exited (code #{code})"}})
          {:stop, :normal, %{state | port: nil}}

        token ->
          {:stop, :normal, finish_success(%{state | port: nil}, token)}
      end
    end
  end

  def handle_info(:login_timeout, state) do
    broadcast({:login_done, {:error, "timed out waiting for login (5 min)"}})
    {:stop, :normal, state}
  end

  def handle_info(:press_enter, %{port: port} = state) when not is_nil(port) do
    Port.command(port, "\r")
    {:noreply, state}
  end

  def handle_info(:press_enter, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    close_port(state.port)
    :ok
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp finish_success(state, token) do
    node_name = Atom.to_string(node())

    case HubRPC.put_node_token(node_name, token) do
      {:ok, _} ->
        broadcast({:login_done, :success})

      {:error, reason} ->
        Logger.error("Failed to persist node token for #{node_name}: #{inspect(reason)}")
        broadcast({:login_done, {:error, "captured token but failed to persist it"}})
    end

    close_port(state.port)
    %{state | done: true, port: nil}
  end

  defp maybe_broadcast_url(%{url: nil} = state, cleaned) do
    case scrape_url(cleaned) do
      nil ->
        state

      url ->
        broadcast({:login_url, url})
        broadcast({:login_status, :awaiting_code})
        %{state | url: url}
    end
  end

  defp maybe_broadcast_url(state, _cleaned), do: state

  defp open_pty do
    script_path = System.find_executable("script") || raise "script executable not found in PATH"
    claude_path = System.find_executable("claude") || raise "claude executable not found in PATH"
    cwd = System.user_home() || System.tmp_dir() || "/tmp"

    # Force a wide PTY so the authorize URL / token don't hard-wrap (ink reads
    # the winsize ioctl, not COLUMNS), then launch setup-token.
    cmd = "stty cols 400 rows 50; exec #{claude_path} setup-token"

    script_args =
      case :os.type() do
        {:unix, :darwin} -> ["-q", "/dev/null", "/bin/sh", "-c", cmd]
        _ -> ["-qc", cmd, "/dev/null"]
      end

    Port.open(
      {:spawn_executable, script_path},
      [
        :binary,
        :exit_status,
        {:args, script_args},
        {:cd, cwd},
        {:env,
         OrcaHub.Env.sanitized_env([
           {~c"TERM", ~c"xterm-256color"},
           {~c"COLUMNS", ~c"400"},
           {~c"LINES", ~c"50"}
         ])}
      ]
    )
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    # Already closed (PTY exited first) — harmless during teardown.
    ArgumentError -> :ok
  end

  defp broadcast(payload) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "node_login:#{node()}", payload)
  end

  # ── Output parsing (public for testing) ───────────────────────────────

  @doc """
  Strip ANSI/VT escape sequences and carriage returns from raw PTY output so it
  can be rendered as plain text. Keeps newlines.
  """
  def strip_ansi(text) do
    text
    # CSI sequences: ESC [ ... final-byte  (covers ?25h, 2G, 1A, >0q, m, r, c)
    |> String.replace(~r/\x1b\[[0-9;?>=!]*[ -\/]*[@-~]/, "")
    # OSC sequences: ESC ] ... BEL  or  ESC ] ... ST
    |> String.replace(~r/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/, "")
    # Save/restore cursor and charset selection: ESC 7, ESC 8, ESC ( B, etc.
    |> String.replace(~r/\x1b[78=>]/, "")
    |> String.replace(~r/\x1b[()][0-9A-Za-z]/, "")
    # Stray control chars (keep \n and \t)
    |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f]/, "")
  end

  @doc "Scrape the OAuth authorize URL from cleaned output, or `nil`."
  def scrape_url(cleaned) do
    case Regex.run(~r{https://\S*claude\.com/\S+}, cleaned) do
      [url | _] -> String.trim_trailing(url, ".")
      nil -> nil
    end
  end

  @doc """
  Scrape the long-lived OAuth token from cleaned output, or `nil`.

  Claude Code OAuth tokens use the `sk-ant-oat<NN>-` prefix.
  """
  def scrape_token(cleaned) do
    case Regex.run(~r/sk-ant-oat\d+-[A-Za-z0-9_-]+/, cleaned) do
      [token | _] -> token
      nil -> nil
    end
  end
end
