defmodule OrcaHub.BackendInstaller do
  @moduledoc """
  Per-node install/update for the three agent-CLI backends (claude, codex,
  pi), driving the Nodes page's "Backends" card. Every function here runs ON
  THE TARGET NODE — callers invoke it via `OrcaHub.Cluster.rpc/4-5` from a
  LiveView, exactly like `OrcaHub.NodeConfig`.

  Validated mechanics (full sourcing in `docs/backend_install_update_research.md`):

    * **claude** — update via `claude update` (atomic versioned-dir/symlink
      swap, safe under concurrent sessions). Fresh install via the official
      `curl -fsSL https://claude.ai/install.sh | bash`. There is no reliable
      read-only "latest version" check, so `latest_version` is always `nil`
      for claude — the update action is treated as cheap/idempotent instead.
    * **codex** — NEVER `codex update` (openai/codex#24035 misdetects
      npm-managed installs). Both install and update run
      `npm install -g @openai/codex@latest`. Latest-version check:
      `npm view @openai/codex version`.
    * **pi** — update via `pi update` (its own maintained self-updater — the
      opposite choice from codex, made deliberately: pi's self-update path is
      actively fixed upstream, codex's is not). Fresh install:
      `npm install -g @earendil-works/pi-coding-agent@latest`. Latest-version
      check: `npm view @earendil-works/pi-coding-agent version`.
    * codex/pi require `npm` in PATH on the target node. When absent (e.g.
      the k3s pods, whose image has no Node.js), `status/0` reports
      `action: :unavailable` with a reason explaining an image rebuild is
      needed — never attempted anyway.
    * Kubernetes pods (`KUBERNETES_SERVICE_HOST` set) get claude
      install/update allowed, but `status/0` reports `ephemeral?: true` — the
      binary lives in the container's writable layer, not the PVC, so it
      reverts on the next pod restart/reschedule. The UI must surface this.
    * No sudo, ever — everything runs as the app user, matching how these
      CLIs are already installed on every node in this cluster.

  ## Headless smoke test (Stage A, done once against this host)

  Before wiring the UI, `claude update` and `pi update` were run directly on
  this host with stdin closed (`< /dev/null`, no TTY) to confirm neither
  blocks waiting for input. Both completed cleanly with exit code 0 and no
  special env needed (no `CI=1` or similar) — `claude update` performed a
  real update (2.1.202 → 2.1.205); `pi update` reported already-current and
  exited immediately. `OrcaHub.BackendInstaller.Job` reproduces the same
  stdin state for every command (`sh -c "<cmd> < /dev/null"`) — an Erlang
  port's stdin is otherwise a silent-but-open pipe, not an immediate EOF like
  a redirect from `/dev/null`, which is a meaningfully different state than
  what was smoke-tested.

  ## API contract for Stage B (update-all fan-out on `NodeLive.Index`)

  * `status/0` — per-node snapshot (see below), call via
    `Cluster.rpc(node, __MODULE__, :status, [], 12_000)` (status runs the
    three backends' checks concurrently, but pad the RPC timeout above the
    default 10s — see the module's internal timeouts).
  * `run/2` (or `run/3` with opts) — call via
    `Cluster.rpc(node, __MODULE__, :run, [backend, action])`. Returns `:ok`
    once the job has started (fire-and-forget from here), or
    `{:error, :already_running}` if a job for that `{node, backend}` is
    already in flight. Fan-out just needs to call this once per
    `{node, backend}` pair whose `status/0` action isn't `:unavailable`.
  * Progress/completion is PubSub-only — subscribe to `topic(node)` for every
    node you fanned out to (do this BEFORE calling `run/2`, same
    connect-before-act ordering `NodeLive.Show` uses) and fold in:
      * `{:installer_output, backend, chunk}` — raw stdout+stderr binary chunk
      * `{:installer_done, backend, {:ok, new_version} | {:error, reason}}`
        — `reason` is an exit code (integer), `:timeout`, `:not_found`, or
        `:invalid_action`
  * `running?/1` / `running_backends/0` — reflect in-flight jobs on this node
    (Registry-backed, not PubSub) — useful for a page (re)mount to restore
    spinner state without waiting for the next broadcast.

  ## Status shape

  `status/0` returns one map per `OrcaHub.NodeConfig.backends/0` entry:

      %{
        backend: :claude | :codex | :pi,
        installed?: boolean,
        version: String.t() | nil,
        latest_version: String.t() | nil,
        npm_available?: boolean,
        ephemeral?: boolean,
        action: :install | :update | :unavailable,
        unavailable_reason: String.t() | nil
      }
  """

  alias OrcaHub.NodeConfig

  @npm_packages %{codex: "@openai/codex", pi: "@earendil-works/pi-coding-agent"}

  # Fixed, non-interpolated shell commands per {backend, action} — the ONLY
  # commands this module will ever execute. Overridable via
  # `:orca_hub, :backend_installer_commands` for tests (fast fake commands
  # like `echo`/`false` instead of real installers).
  @commands %{
    {:claude, :install} => "curl -fsSL https://claude.ai/install.sh | bash",
    {:claude, :update} => "claude update",
    {:codex, :install} => "npm install -g @openai/codex@latest",
    {:codex, :update} => "npm install -g @openai/codex@latest",
    {:pi, :install} => "npm install -g @earendil-works/pi-coding-agent@latest",
    {:pi, :update} => "pi update"
  }

  # `--version`/`npm view` are quick, read-only, non-interactive commands —
  # generous but bounded timeouts so a hung/slow node can't wedge status/0.
  @version_timeout 3_000
  @npm_timeout 4_000
  @status_task_timeout 9_000

  @doc "The PubSub topic a backend-installer job on `node` broadcasts to."
  @spec topic(node | String.t()) :: String.t()
  def topic(node), do: "backend_installer:#{node}"

  @doc """
  Per-backend install/update status for this node — see moduledoc. Runs the
  three backends' checks concurrently; a backend whose checks somehow exceed
  the internal per-task safety timeout is dropped from the result rather than
  hanging the whole call.
  """
  @spec status() :: [map]
  def status do
    NodeConfig.backends()
    |> Task.async_stream(&backend_status/1, timeout: @status_task_timeout, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, result} -> [result]
      {:exit, _reason} -> []
    end)
  end

  @doc """
  Starts an install/update job for `backend` on THIS node (see moduledoc for
  the Cluster.rpc call shape). Returns `:ok` once started, or
  `{:error, :already_running}` if a job for this backend is already in
  flight on this node. `opts` (arity-3) are passed through to the job — only
  `:timeout` is meaningful today (test seam to shrink the default 10-minute
  kill timeout).
  """
  @spec run(atom, :install | :update, keyword) :: :ok | {:error, term}
  def run(backend, action, opts \\ [])
      when backend in [:claude, :codex, :pi] and action in [:install, :update] do
    child_opts = Keyword.merge(opts, backend: backend, action: action)

    case DynamicSupervisor.start_child(
           OrcaHub.BackendInstallerSupervisor,
           {OrcaHub.BackendInstaller.Job, child_opts}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :already_running}
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :start_failed}
    end
  end

  @doc "Whether an install/update job for `backend` is currently running on this node."
  @spec running?(atom) :: boolean
  def running?(backend), do: Registry.lookup(OrcaHub.BackendInstallerRegistry, backend) != []

  @doc "The subset of `OrcaHub.NodeConfig.backends/0` with a job currently running on this node."
  @spec running_backends() :: [atom]
  def running_backends, do: Enum.filter(NodeConfig.backends(), &running?/1)

  @doc false
  @spec command_for(atom, :install | :update) :: {:ok, String.t()} | :error
  def command_for(backend, action) do
    Map.fetch(commands(), {backend, action})
  end

  @doc """
  Best-effort installed version for `backend` on this node (`<cli>
  --version`, parsed defensively). `nil` when the CLI isn't installed, the
  command fails/times out, or the version can't be parsed out of the output.
  """
  @spec fetch_version(atom) :: String.t() | nil
  def fetch_version(backend) do
    exe = executable_override(backend) || Atom.to_string(backend)

    case exec(exe, ["--version"], @version_timeout) do
      {:ok, output, 0} -> parse_version(output)
      _ -> nil
    end
  end

  @doc "Whether `npm` is resolvable in PATH on this node."
  @spec npm_available?() :: boolean
  def npm_available?, do: System.find_executable(npm_executable()) != nil

  @doc "Whether this node is running inside a Kubernetes pod (claude installs there are ephemeral)."
  @spec kubernetes_pod?() :: boolean
  def kubernetes_pod?, do: System.get_env("KUBERNETES_SERVICE_HOST") != nil

  @doc "Extracts the first `x.y.z` version token from raw CLI/npm output, or `nil`."
  @spec parse_version(String.t() | nil) :: String.t() | nil
  def parse_version(text) when is_binary(text) do
    case Regex.run(~r/\d+\.\d+\.\d+/, text) do
      [version] -> version
      nil -> nil
    end
  end

  def parse_version(_), do: nil

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp backend_status(backend) do
    installed? = NodeConfig.cli_installed?(backend)
    npm_avail? = npm_available?()

    %{
      backend: backend,
      installed?: installed?,
      version: if(installed?, do: fetch_version(backend), else: nil),
      latest_version: latest_version(backend, npm_avail?),
      npm_available?: npm_avail?,
      ephemeral?: kubernetes_pod?()
    }
    |> Map.merge(action_for(backend, installed?, npm_avail?))
  end

  defp action_for(:claude, installed?, _npm_available?) do
    %{action: if(installed?, do: :update, else: :install), unavailable_reason: nil}
  end

  defp action_for(backend, installed?, npm_available?) when backend in [:codex, :pi] do
    if npm_available? do
      %{action: if(installed?, do: :update, else: :install), unavailable_reason: nil}
    else
      %{
        action: :unavailable,
        unavailable_reason: "npm not available on this node (requires image rebuild)"
      }
    end
  end

  # No documented read-only "latest" check exists for claude (see moduledoc).
  defp latest_version(:claude, _npm_available?), do: nil

  defp latest_version(backend, npm_available?) when backend in [:codex, :pi] do
    if npm_available? do
      pkg = Map.fetch!(@npm_packages, backend)

      case exec(npm_executable(), ["view", pkg, "version"], @npm_timeout) do
        {:ok, output, 0} -> parse_version(output)
        _ -> nil
      end
    end
  end

  defp commands, do: Application.get_env(:orca_hub, :backend_installer_commands, @commands)

  defp npm_executable, do: Application.get_env(:orca_hub, :npm_executable, "npm")

  defp executable_override(:claude), do: Application.get_env(:orca_hub, :claude_executable)
  defp executable_override(:codex), do: Application.get_env(:orca_hub, :codex_executable)
  defp executable_override(:pi), do: Application.get_env(:orca_hub, :pi_executable)

  # Synchronous, bounded-time exec for the quick read-only checks (--version,
  # npm view) — NOT used for install/update jobs, which stream incrementally
  # via a raw Port in OrcaHub.BackendInstaller.Job instead. Killing the Task
  # on timeout closes the port it owns, which SIGTERMs the child (Unix).
  defp exec(exe, args, timeout_ms) do
    task = Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {:ok, output, status}
      {:exit, _reason} -> {:error, :not_found}
      nil -> {:error, :timeout}
    end
  end
end
