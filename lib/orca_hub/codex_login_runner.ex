defmodule OrcaHub.CodexLoginRunner do
  @moduledoc """
  GenServer that logs a node into codex from the web UI. Sibling to
  `OrcaHub.LoginRunner` (Claude's flow) rather than a generalization of it —
  see `docs/codex_pi_auth_research.md` §2 and the module doc below for why.

  Two independent modes, both node-targeted via `Cluster.rpc` (the process
  runs ON THE TARGET NODE, same mechanism as `LoginRunner`):

    * **`:device_auth`** (primary, ChatGPT-plan) — runs `codex login
      --device-auth` under a PTY (`script -qc`, same pattern as
      `LoginRunner`/`SessionRunner`/`TerminalRunner`). The CLI prints a
      verification URL and a short user code; the user approves from ANY
      browser (there is nothing to paste back into OrcaHub — unlike
      Claude's flow, there's no "submit code" step at all). Success is
      detected by the process exiting `0` after a code was printed. Codex
      writes its own `~/.codex/auth.json` — this module never scrapes or
      stores a credential, it only drives the CLI and reports status.
    * **`:api_key`** (fallback, non-interactive) — runs `codex login
      --with-api-key` and pipes the key to it over stdin. Deliberately NOT
      run under a PTY: `script -qc` allocates a pty, and a pty's line
      discipline echoes writes made to its master back into the very output
      stream we broadcast to the LiveView — which would leak the key into
      `{:codex_login_output, ...}` PubSub payloads. A plain (non-PTY) port
      has no such echo. The key is further isolated from the child's argv
      (never visible via `ps`) by having an outer shell `read` the line
      itself and pipe it onward to `codex` — see `api_key_cmd/1`. The key is
      written once, then dropped from process state immediately.

  **Why a sibling module, not a generalized `LoginRunner`**: Claude's flow
  has exactly one interactive step (paste a code) and finishes by scraping a
  token and persisting it to Postgres (`NodeCredentials`) — a very different
  shape from `:device_auth` (no code submission at all, success = exit
  code, no DB write — codex's own `auth.json` is the store) and from
  `:api_key` (no PTY, a secret piped over stdin that must never be echoed).
  Bending `LoginRunner` to cover three fundamentally different completion
  signals (token regex vs. exit code vs. exit code) and two fundamentally
  different port flavors (PTY vs. plain pipe) would have made it harder to
  audit for the one property that matters most here — that a secret never
  reaches a broadcast payload — so this stays a separate, narrowly-scoped
  module instead.

  Output/lifecycle events broadcast on `codex_login:<node>` via PubSub
  (distinct topic from Claude's `node_login:<node>` so the two flows never
  collide), auto-distributing cross-cluster via `:pg` exactly like
  `LoginRunner`.

  Singleton per node (named `__MODULE__`), started under the same
  `LoginSupervisor` DynamicSupervisor Claude's flow uses.
  """

  use GenServer
  require Logger

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
  Start (or restart) the device-auth login flow on THIS node. Intended to be
  invoked via `Cluster.rpc(target_node, OrcaHub.CodexLoginRunner, :start_device_auth, [])`.
  """
  def start_device_auth do
    restart_with(mode: :device_auth)
  end

  @doc """
  Start (or restart) the API-key login flow on THIS node, piping `key` to
  `codex login --with-api-key`. Intended to be invoked via
  `Cluster.rpc(target_node, OrcaHub.CodexLoginRunner, :start_api_key, [key])`.

  `key` crosses the wire as an RPC argument (unavoidable, same as
  `LoginRunner.submit_code/1`'s pasted code) but is never logged, never
  broadcast, and is dropped from this process's state as soon as it's
  written to the child's stdin.
  """
  def start_api_key(key) when is_binary(key) and key != "" do
    restart_with(mode: :api_key, key: key)
  end

  defp restart_with(opts) do
    case DynamicSupervisor.start_child(OrcaHub.LoginSupervisor, {__MODULE__, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        DynamicSupervisor.terminate_child(OrcaHub.LoginSupervisor, pid)
        DynamicSupervisor.start_child(OrcaHub.LoginSupervisor, {__MODULE__, opts})

      other ->
        other
    end
  end

  @doc "Cancel an in-progress codex login flow on this node."
  def cancel do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # ── Callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    mode = Keyword.fetch!(opts, :mode)
    port = open_port(mode, opts)
    timer = Process.send_after(self(), :login_timeout, @timeout)

    broadcast({:codex_login_status, :running})

    state = %{
      mode: mode,
      port: port,
      buffer: <<>>,
      url: nil,
      code: nil,
      timer: timer,
      done: false
    }

    # API-key mode: write the key immediately, then drop it from state so it
    # doesn't linger in this process's memory for the life of the flow.
    state =
      case Keyword.fetch(opts, :key) do
        {:ok, key} ->
          Port.command(port, key <> "\n")
          state

        :error ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, mode: :device_auth} = state) do
    buffer = state.buffer <> data
    cleaned = strip_ansi(buffer)

    broadcast({:codex_login_output, cleaned})

    state = %{state | buffer: buffer}
    state = maybe_broadcast_url_and_code(state, cleaned)

    {:noreply, state}
  end

  def handle_info({port, {:data, data}}, %{port: port, mode: :api_key} = state) do
    # Never broadcast raw output in api_key mode — the key is piped over
    # this same port's stdin (see moduledoc); even though it's never echoed
    # under a non-PTY port, we still avoid surfacing raw child output here
    # as defense in depth.
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    if state.done do
      {:stop, :normal, %{state | port: nil}}
    else
      state = %{state | port: nil}

      if code == 0 do
        broadcast({:codex_login_done, :success})
      else
        broadcast({:codex_login_done, {:error, "codex login exited (code #{code})"}})
      end

      {:stop, :normal, %{state | done: true}}
    end
  end

  def handle_info(:login_timeout, state) do
    broadcast({:codex_login_done, {:error, "timed out waiting for login (5 min)"}})
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    close_port(state.port)
    :ok
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp maybe_broadcast_url_and_code(state, cleaned) do
    state
    |> maybe_broadcast_url(cleaned)
    |> maybe_broadcast_code(cleaned)
  end

  defp maybe_broadcast_url(%{url: nil} = state, cleaned) do
    case scrape_url(cleaned) do
      nil ->
        state

      url ->
        broadcast({:codex_login_url, url})
        %{state | url: url}
    end
  end

  defp maybe_broadcast_url(state, _cleaned), do: state

  defp maybe_broadcast_code(%{code: nil} = state, cleaned) do
    case scrape_code(cleaned) do
      nil ->
        state

      code ->
        broadcast({:codex_login_code, code})
        broadcast({:codex_login_status, :awaiting_approval})
        %{state | code: code}
    end
  end

  defp maybe_broadcast_code(state, _cleaned), do: state

  defp open_port(:device_auth, _opts) do
    script_path = System.find_executable("script") || raise "script executable not found in PATH"
    codex_path = codex_executable!()
    cwd = System.user_home() || System.tmp_dir() || "/tmp"

    cmd = "stty cols 400 rows 50; exec #{codex_path} login --device-auth"

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

  defp open_port(:api_key, _opts) do
    sh_path = System.find_executable("sh") || raise "sh executable not found in PATH"
    codex_path = codex_executable!()
    cwd = System.user_home() || System.tmp_dir() || "/tmp"

    # No PTY here (see moduledoc) — a plain pipe never echoes what's written
    # to it back into the output stream. The outer shell reads the key off
    # its own stdin into a variable and pipes THAT to codex, so the key
    # never appears in any process's argv (`ps` is safe) and codex's own
    # stdin is cleanly EOF'd the moment the inner `printf` exits.
    cmd =
      ~s(IFS= read -r codex_key; printf '%s' "$codex_key" | #{codex_path} login --with-api-key 2>&1)

    Port.open(
      {:spawn_executable, sh_path},
      [
        :binary,
        :exit_status,
        {:args, ["-c", cmd]},
        {:cd, cwd},
        {:env, OrcaHub.Env.sanitized_env()}
      ]
    )
  end

  # `:orca_hub, :codex_executable` mirrors `Backend.Codex`'s own test seam —
  # unset in dev/prod, falls through to PATH lookup.
  defp codex_executable! do
    Application.get_env(:orca_hub, :codex_executable) ||
      System.find_executable("codex") ||
      raise "codex executable not found in PATH (install: npm install -g @openai/codex)"
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp broadcast(payload) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "codex_login:#{node()}", payload)
  end

  # ── Output parsing (public for testing) ────────────────────────────────
  #
  # Deliberately duplicated from LoginRunner rather than shared — both are
  # small, pure, and tied to nothing Claude-specific, but keeping them
  # separate means neither module has to worry about the other's callers
  # when tuning a regex.

  @doc "Strip ANSI/VT escape sequences and carriage returns, keep newlines."
  def strip_ansi(text) do
    text
    |> String.replace(~r/\x1b\[[0-9;?>=!]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/, "")
    |> String.replace(~r/\x1b[78=>]/, "")
    |> String.replace(~r/\x1b[()][0-9A-Za-z]/, "")
    |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f]/, "")
  end

  @doc "Scrape the device-auth verification URL from cleaned output, or `nil`."
  def scrape_url(cleaned) do
    case Regex.run(~r{https://\S+}, cleaned) do
      [url | _] -> url |> String.trim_trailing(".") |> String.trim()
      nil -> nil
    end
  end

  @doc """
  Scrape the device-auth user code from cleaned output, or `nil`. Codex's
  exact device-auth output format wasn't captured in research (only that it
  "prints URL+code" — `docs/codex_pi_auth_research.md` §2) — this covers the
  standard OAuth device-flow code shape (RFC 8628 groups, e.g. `WDJB-MJHT`)
  plus a `code: XXXX` fallback for other phrasings.
  """
  def scrape_code(cleaned) do
    case Regex.run(~r/\b[A-Z0-9]{4}-[A-Z0-9]{4}\b/, cleaned) do
      [code | _] ->
        code

      nil ->
        case Regex.run(~r/code[:\s]+([A-Za-z0-9-]{4,12})/i, cleaned) do
          [_, code] -> code
          nil -> nil
        end
    end
  end
end
