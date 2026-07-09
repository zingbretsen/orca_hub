defmodule OrcaHub.BackendInstaller.Job do
  @moduledoc """
  One-shot GenServer that runs a single install/update command for one
  backend on THIS node, streaming combined stdout/stderr via PubSub.

  Started (at most once per backend on a given node, enforced via
  `OrcaHub.BackendInstallerRegistry`) by `OrcaHub.BackendInstaller.run/3`
  under `OrcaHub.BackendInstallerSupervisor`. Broadcasts on
  `OrcaHub.BackendInstaller.topic(node())`:

    * `{:installer_output, node, backend, chunk}` — a raw stdout/stderr chunk (binary)
    * `{:installer_done, node, backend, {:ok, new_version} | {:error, reason}}` —
      `reason` is an exit code (integer), `:timeout`, `:not_found`, or
      `:invalid_action`

  `node` is always `node()` (this job only ever runs on the node it reports
  for) — it's included so a subscriber fanned out across multiple nodes'
  topics (Stage B's Nodes-index "update all backends" sweep) can tell which
  node a message came from; the plain PubSub message itself carries no topic
  information.

  Every command runs as `sh -c "<cmd> < /dev/null"`. The explicit
  `< /dev/null` matters: an Erlang port's stdin is an open-but-silent pipe by
  default, not an immediate EOF — a meaningfully different state than the
  `< /dev/null` redirect Stage A's headless smoke test actually verified
  `claude update`/`pi update` complete under. This reproduces that exact
  state for every command, including the ones not individually smoke-tested
  (npm installs/updates, which are well-established non-interactive
  commands, and the `curl | bash` installer, whose stdin is already
  connected to `curl`'s stdout regardless of the outer redirect).

  Concurrency note (`docs/backend_install_update_research.md`): npm writes
  package files in place, unlike claude's atomic versioned-dir swap — so
  there's a narrow window where a brand-new codex/pi session spawning mid
  npm-update could read a partially-written file. Accepted risk, not fixed
  here (same category of risk as any live software update).
  """

  use GenServer
  require Logger

  alias OrcaHub.BackendInstaller

  @default_timeout :timer.minutes(10)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :backend)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    backend = Keyword.fetch!(opts, :backend)
    GenServer.start_link(__MODULE__, opts, name: via(backend))
  end

  def via(backend), do: {:via, Registry, {OrcaHub.BackendInstallerRegistry, backend}}

  @impl true
  def init(opts) do
    backend = Keyword.fetch!(opts, :backend)
    action = Keyword.fetch!(opts, :action)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case {BackendInstaller.command_for(backend, action), System.find_executable("sh")} do
      {{:ok, cmd}, sh} when is_binary(sh) ->
        port = open_port(sh, cmd)
        timer = Process.send_after(self(), :job_timeout, timeout)
        {:ok, %{backend: backend, port: port, timer: timer}}

      {:error, _} ->
        broadcast({:installer_done, node(), backend, {:error, :invalid_action}})
        :ignore

      {{:ok, _cmd}, nil} ->
        broadcast({:installer_done, node(), backend, {:error, :not_found}})
        :ignore
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    broadcast({:installer_output, node(), state.backend, data})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    result =
      if status == 0,
        do: {:ok, BackendInstaller.fetch_version(state.backend)},
        else: {:error, status}

    broadcast({:installer_done, node(), state.backend, result})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(:job_timeout, state) do
    close_port(state.port)
    broadcast({:installer_done, node(), state.backend, {:error, :timeout}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if timer = Map.get(state, :timer), do: Process.cancel_timer(timer)
    close_port(Map.get(state, :port))
    :ok
  end

  defp open_port(sh, cmd) do
    Port.open(
      {:spawn_executable, sh},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-c", cmd <> " < /dev/null"]},
        {:cd, String.to_charlist(System.user_home() || System.tmp_dir() || "/tmp")},
        {:env, OrcaHub.Env.sanitized_env()}
      ]
    )
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    # Already closed (child exited first) — harmless during teardown.
    ArgumentError -> :ok
  end

  defp broadcast(msg) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, BackendInstaller.topic(node()), msg)
  end
end
