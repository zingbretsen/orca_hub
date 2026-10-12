defmodule OrcaHub.ProcessIsolation do
  @moduledoc """
  Gives every agent CLI spawn (claude/codex/pi, any engine) a process tree
  that can be limited and killed as a unit, and kills it whenever its port
  goes away (ORCAHUB3-145/146).

  Before this, a SessionRunner teardown only `Port.close`d the CLI. On
  2026-10-11 two backgrounded `cargo test` trees outlived idle teardown AND
  archive on gb10, reparented to init inside orca-hub.service, and held the
  whole service (every CLI, git, the BEAM) at ~96% memory stall for 11 hours
  with no OOM kill ever.

  ## Two mechanisms, chosen once per node at boot

    * **cgroup** (`OrcaHub.ProcessIsolation.Cgroup`): when the BEAM runs in
      a delegated `beam` subgroup (the unit's `Delegate=yes` +
      `DelegateSubgroup=beam`), each spawn runs in its own leaf under a
      sibling `agents/` cgroup with its own memory.max / memory.swap.max /
      pids.max (`OrcaHub.ProcessIsolation.Limits`), so a runaway is
      OOM-killed inside its leaf instead of throttling the service, and
      teardown is one `cgroup.kill`, which nothing inside can escape.
    * **marker** (`OrcaHub.ProcessIsolation.Marker`): everywhere else (k3s
      pods, a host whose unit hasn't been reinstalled, `bin/test`, macOS),
      teardown kills every process that inherited the spawn's
      `ORCA_AGENT_SPAWN_ID`. Best effort: it can't reach a descendant that
      scrubbed its environment. No limits.

  The marker is set in both modes, and every reap also runs the marker kill,
  so a CLI that failed to enter its leaf (the wrapper's cgroup write is
  fail-open) is still reaped.

  ## Lifecycle of a spawn

  `prepare/1` (runner process, before `Port.open`) registers the spawn id
  in `OrcaHub.ProcessIsolation.Registry`, creates the leaf, and asks this
  server to monitor the runner. `wrap/4` rewrites the spawn so a tiny
  `/bin/sh` wrapper raises the CLI's oom_score_adj (agents die before the
  BEAM in ANY OOM, cgroup or not), joins the leaf, and `exec`s the CLI, so
  the port's os_pid is still the CLI's and SIGINT interrupts keep working.

  `release/2` (runner process, after `Port.close` or the port's exit) hands
  the spawn to this server, which waits out a grace period (the CLI exits on
  stdin EOF by itself), SIGKILLs whatever is left, then removes the leaf
  once it is empty. The runner never waits on any of it: releasing is a cast.

  A runner killed outright (stop_session/archive: SessionRunner doesn't trap
  exits, so `terminate/3` never runs there) is caught by the monitor, and
  its spawns are reaped the same way.

  A periodic sweep (cgroup mode) kills and removes any leaf that is neither
  registered to a live runner nor already being reaped: what a crash of
  this server, or of the whole BEAM, can leave behind.

  start_job jobs, terminals and setup scripts are spawned by the BEAM, not
  by a CLI: they carry no marker, live in `beam/`, and are never touched.
  """

  use GenServer
  require Logger

  alias OrcaHub.ProcessIsolation.{Cgroup, Limits, Marker}

  @registry OrcaHub.ProcessIsolation.Registry
  @mode_key {__MODULE__, :mode}

  @default_reap_grace_ms 3_000
  @default_sweep_interval_ms 60_000
  @default_oom_score_adj 500
  @reap_check_ms 200
  @reap_max_checks 25

  # $1 is the leaf ("" = none), $2 the oom_score_adj ("" = leave it), then
  # the real executable and its argv. Both writes are silent and
  # fail-open: stderr is the port's stdout (stderr_to_stdout), which carries
  # the CLI's own protocol, so a stray shell message would corrupt it, and a
  # failed cgroup join must not cost the user their session (the marker
  # still reaps it). `exec` keeps the os_pid the CLI's.
  @wrapper """
  [ -n "$2" ] && { echo "$2" > /proc/self/oom_score_adj; } 2>/dev/null
  [ -n "$1" ] && { echo $$ > "$1/cgroup.procs"; } 2>/dev/null
  shift 2
  exec "$@"
  """

  @sh "/bin/sh"

  defmodule Spawn do
    @moduledoc "One agent CLI spawn: its id (the leaf name and the marker value) and leaf."
    @enforce_keys [:id, :session_id]
    defstruct [:id, :session_id, :leaf]

    @type t :: %__MODULE__{id: String.t(), session_id: String.t(), leaf: String.t() | nil}
  end

  # ── Runner-side API: runs in the SessionRunner process, never blocks ───

  @doc """
  Sets up one spawn for `session_id`: a fresh id (per spawn, never per
  session, so reaping an old port can never touch its replacement), the
  leaf when cgroups are available, and crash monitoring of the caller.
  Never raises; worst case is a leafless, marker-only spawn.
  """
  @spec prepare(String.t()) :: Spawn.t()
  def prepare(session_id) do
    id = spawn_id(session_id)
    spawn = %Spawn{id: id, session_id: session_id, leaf: create_leaf(id)}
    GenServer.cast(__MODULE__, {:track, spawn, self()})
    spawn
  end

  @doc """
  Rewrites a backend spawn spec to run through the wrapper. Returns
  `{executable, args, env}` for `Port.open/2`.
  """
  @spec wrap(Spawn.t(), String.t(), [String.t() | charlist()], list()) ::
          {String.t(), list(), list()}
  def wrap(%Spawn{} = spawn, executable, args, env) do
    {@sh,
     [
       "-c",
       @wrapper,
       "orca-agent-spawn",
       spawn.leaf || "",
       oom_score_adj_arg(),
       executable | args
     ], env ++ [Marker.env_entry(spawn.id)]}
  end

  @doc """
  Raises what `Port.open({:spawn_executable, path}, _)` would for a missing
  (`:enoent`) or non-executable (`:eacces`) CLI (a directory counts as the
  latter here, where Port.open would only fail at exec). Through the wrapper the
  port itself always opens (`/bin/sh` exists) and a bad path would only
  surface later as a shell's exit 127, losing the runner's "Startup stage:
  Port.open" diagnostics; call this inside that stage instead.
  """
  @spec ensure_executable!(String.t()) :: :ok
  def ensure_executable!(path) do
    import Bitwise

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 -> :ok
      {:ok, _} -> :erlang.error(:eacces)
      {:error, _} -> :erlang.error(:enoent)
    end
  end

  @doc """
  Hands a spawn whose port has been closed (or has exited) to the reaper.
  `grace_ms: 0` when the CLI is already known to be gone. A nil spawn
  (no port was ever opened through `prepare/1`) is a no-op.
  """
  @spec release(Spawn.t() | nil, keyword()) :: :ok
  def release(spawn, opts \\ [])
  def release(nil, _opts), do: :ok

  def release(%Spawn{} = spawn, opts) do
    GenServer.cast(__MODULE__, {:reap, spawn, Keyword.get(opts, :grace_ms, reap_grace_ms())})

    # The reaper owns it from here; the sweep checks the reaper's own list.
    if spawn.leaf, do: safe_unregister(spawn.id)
    :ok
  end

  @doc """
  The node's isolation mode, for diagnostics: `%{mode: :cgroup, agents:,
  controllers:, limits:}` or `%{mode: :marker, reason:}`.
  """
  def status do
    case :persistent_term.get(@mode_key, nil) do
      {:cgroup, tree, limits} ->
        %{mode: :cgroup, agents: tree.agents, controllers: tree.controllers, limits: limits}

      {:marker, reason} ->
        %{mode: :marker, reason: reason}

      nil ->
        %{mode: :marker, reason: "OrcaHub.ProcessIsolation has not started"}
    end
  end

  defp create_leaf(id) do
    case :persistent_term.get(@mode_key, nil) do
      {:cgroup, tree, limits} ->
        # Registered BEFORE the mkdir, so a sweep can never see this leaf
        # unowned.
        with :ok <- register(id),
             {:ok, leaf, warnings} <- Cgroup.create_leaf(tree, id, limits) do
          if warnings != [],
            do: Logger.warning("[process_isolation] leaf #{id}: #{Enum.join(warnings, "; ")}")

          leaf
        else
          {:error, reason} ->
            safe_unregister(id)

            Logger.warning(
              "[process_isolation] no cgroup leaf for spawn #{id} (#{inspect(reason)}); " <>
                "it runs unlimited and is reaped by env marker only"
            )

            nil
        end

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("[process_isolation] prepare failed for #{id}: #{Exception.message(e)}")
      nil
  end

  defp register(id) do
    case Registry.register(@registry, id, nil) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_unregister(id) do
    Registry.unregister(@registry, id)
  rescue
    _ -> :ok
  end

  defp spawn_id(session_id) do
    safe = String.replace(to_string(session_id), ~r/[^A-Za-z0-9_-]/, "_")
    "#{safe}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
  end

  defp oom_score_adj_arg do
    case config(:oom_score_adj, @default_oom_score_adj) do
      adj when is_integer(adj) and adj >= -1000 and adj <= 1000 -> Integer.to_string(adj)
      _ -> ""
    end
  end

  defp reap_grace_ms, do: config(:reap_grace_ms, @default_reap_grace_ms)

  defp config(key, default) do
    :orca_hub |> Application.get_env(:agent_isolation, []) |> Keyword.get(key, default)
  end

  # ── Server ─────────────────────────────────────────────────────────────

  @doc """
  Options (tests): `:name` (default `__MODULE__`; `nil` for an anonymous
  instance), `:mode` (skip detection, e.g. `{:cgroup, tree, limits}` over a
  fake root), `:persist` (default true: publish the mode for `prepare/1`),
  `:sweep_interval_ms`, plus any `:agent_isolation` key.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # So a shutdown runs terminate/2 and kills in-flight reaps immediately.
    Process.flag(:trap_exit, true)

    config = Keyword.merge(Application.get_env(:orca_hub, :agent_isolation, []), opts)
    mode = Keyword.get_lazy(opts, :mode, fn -> detect(config) end)
    if Keyword.get(opts, :persist, true), do: :persistent_term.put(@mode_key, mode)

    state = %{
      mode: mode,
      tracked: %{},
      monitors: %{},
      reaping: %{},
      sweep_interval_ms: Keyword.get(config, :sweep_interval_ms, @default_sweep_interval_ms)
    }

    state = if match?({:cgroup, _, _}, mode), do: sweep(state), else: state
    schedule_sweep(state)
    {:ok, state}
  end

  # Never raises: this runs in init/1 on every node, and a crash loop here
  # would take the whole application down with it.
  defp detect(config) do
    if to_string(Keyword.get(config, :cgroups, "auto")) in ~w(off false 0) do
      Logger.info(
        "[process_isolation] agent cgroups disabled by ORCA_AGENT_CGROUPS; env-marker reaping only"
      )

      {:marker, "disabled by ORCA_AGENT_CGROUPS"}
    else
      detect_cgroup(config)
    end
  rescue
    e ->
      Logger.error(
        "[process_isolation] cgroup detection crashed (#{Exception.message(e)}); " <>
          "env-marker reaping only"
      )

      {:marker, "detection crashed: #{Exception.message(e)}"}
  end

  defp detect_cgroup(config) do
    case Cgroup.detect(subgroup: Keyword.get(config, :subgroup, "beam")) do
      {:ok, tree} ->
        limits = Limits.resolve(config, Cgroup.memory_base(tree))
        warnings = limits.warnings ++ Cgroup.apply_aggregate_limits(tree, limits)

        Logger.info(
          "[process_isolation] agent CLIs run in per-spawn cgroups under #{tree.agents} " <>
            "(controllers: #{Enum.join(tree.controllers, ",")}; per spawn " <>
            "memory.max=#{Limits.format(limits.agent_memory_max)} " <>
            "swap=#{Limits.format(limits.agent_swap_max)} " <>
            "pids=#{Limits.format(limits.agent_pids_max)}; all agents " <>
            "memory.max=#{Limits.format(limits.agents_memory_max)}; beam " <>
            "memory.low=#{Limits.format(limits.beam_memory_low)}; budget " <>
            "#{Limits.format(limits.base || :max)})"
        )

        if warnings != [],
          do: Logger.warning("[process_isolation] #{Enum.join(warnings, "; ")}")

        {:cgroup, tree, limits}

      {:error, reason} ->
        Logger.info(
          "[process_isolation] no delegated cgroup (#{reason}); agent process trees are " <>
            "reaped by env marker only, with no per-session memory limits"
        )

        {:marker, reason}
    end
  end

  @impl true
  def handle_cast({:track, %Spawn{} = spawn, pid}, state) do
    monitors =
      Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)

    {:noreply,
     %{state | monitors: monitors, tracked: Map.put(state.tracked, spawn.id, {spawn, pid})}}
  end

  def handle_cast({:reap, %Spawn{} = spawn, grace_ms}, state) do
    state = untrack(state, spawn.id)
    {:noreply, start_reap(state, spawn, grace_ms)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {gone, tracked} =
      Enum.split_with(state.tracked, fn {_id, {_spawn, owner}} -> owner == pid end)

    state = %{state | tracked: Map.new(tracked), monitors: Map.delete(state.monitors, pid)}

    state =
      Enum.reduce(gone, state, fn {_id, {spawn, _owner}}, acc ->
        start_reap(acc, spawn, reap_grace_ms())
      end)

    {:noreply, state}
  end

  def handle_info({:reap_kill, id}, state) do
    case Map.fetch(state.reaping, id) do
      {:ok, entry} ->
        killed = kill(entry.spawn)

        if killed > 0 do
          Logger.info(
            "[process_isolation] reaped spawn #{id} of session #{entry.spawn.session_id}: " <>
              "SIGKILLed #{killed} leftover process(es)"
          )
        end

        Process.send_after(self(), {:reap_check, id}, @reap_check_ms)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:reap_check, id}, state) do
    case Map.fetch(state.reaping, id) do
      {:ok, entry} -> {:noreply, check_reap(state, id, entry)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    state = if match?({:cgroup, _, _}, state.mode), do: sweep(state), else: state
    schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # On shutdown, finish what is in flight without the grace: those spawns'
  # runners are already gone (SessionSupervisor stops before this server).
  # Never on a crash: a crash restart must not take live sessions with it.
  @impl true
  def terminate(reason, state) do
    if shutdown?(reason) do
      orphaned = for {_id, {spawn, pid}} <- state.tracked, not Process.alive?(pid), do: spawn
      Enum.each(Map.values(state.reaping), &kill(&1.spawn))
      Enum.each(orphaned, &kill/1)
    end

    :ok
  end

  defp shutdown?(:normal), do: true
  defp shutdown?(:shutdown), do: true
  defp shutdown?({:shutdown, _}), do: true
  defp shutdown?(_reason), do: false

  # ── Reaping ────────────────────────────────────────────────────────────

  defp untrack(state, id) do
    case Map.pop(state.tracked, id) do
      {nil, _} ->
        state

      {{_spawn, pid}, tracked} ->
        still_owned? = Enum.any?(tracked, fn {_id, {_s, owner}} -> owner == pid end)

        monitors =
          if still_owned? do
            state.monitors
          else
            {ref, monitors} = Map.pop(state.monitors, pid)
            if ref, do: Process.demonitor(ref, [:flush])
            monitors
          end

        %{state | tracked: tracked, monitors: monitors}
    end
  end

  defp start_reap(state, %Spawn{id: id} = spawn, grace_ms) do
    if Map.has_key?(state.reaping, id) do
      state
    else
      Process.send_after(self(), {:reap_kill, id}, max(grace_ms, 0))
      %{state | reaping: Map.put(state.reaping, id, %{spawn: spawn, checks: 0})}
    end
  end

  # SIGKILL everything left: the whole leaf (atomic, fork-proof) and every
  # process carrying the marker. Returns how many processes were found.
  defp kill(%Spawn{} = spawn) do
    in_leaf =
      if spawn.leaf do
        count = length(Cgroup.procs(spawn.leaf))
        Cgroup.kill(spawn.leaf)
        count
      else
        0
      end

    marked = Marker.find(spawn.id)
    Marker.signal(marked, "KILL")

    # A process in the leaf normally carries the marker too; count it once.
    max(in_leaf, length(marked))
  end

  defp check_reap(state, id, %{spawn: spawn, checks: checks} = entry) do
    leaf_done? =
      case spawn.leaf && Cgroup.populated?(spawn.leaf) do
        nil -> true
        :gone -> true
        true -> false
        false -> remove(state, spawn.leaf) == :ok
      end

    done? = leaf_done? and Marker.find(id) == []

    cond do
      done? ->
        %{state | reaping: Map.delete(state.reaping, id)}

      checks + 1 >= @reap_max_checks ->
        Logger.warning(
          "[process_isolation] spawn #{id} of session #{spawn.session_id} still has " <>
            "processes (or an unremovable leaf) after #{@reap_max_checks} kill attempts; " <>
            "leaving it to the periodic sweep"
        )

        %{state | reaping: Map.delete(state.reaping, id)}

      true ->
        kill(spawn)
        Process.send_after(self(), {:reap_check, id}, @reap_check_ms)
        %{state | reaping: Map.put(state.reaping, id, %{entry | checks: checks + 1})}
    end
  end

  defp remove(%{mode: mode}, leaf), do: remove(mode, leaf)

  defp remove({:cgroup, tree, _limits}, leaf) do
    case Cgroup.remove_leaf(tree, leaf, 3) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("[process_isolation] rmdir #{leaf}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp remove(_mode, _leaf), do: {:error, :no_cgroup_tree}

  # ── Sweep (cgroup mode) ────────────────────────────────────────────────

  # A leaf no live runner has registered and the reaper isn't working on is
  # stale: empty ones are removed, populated ones killed. Conservative by
  # construction: prepare/1 registers before it mkdirs.
  defp sweep(%{mode: {:cgroup, tree, _limits}} = state) do
    do_sweep(state, tree)
  rescue
    e ->
      Logger.warning("[process_isolation] sweep failed: #{Exception.message(e)}")
      state
  end

  defp do_sweep(state, tree) do
    Enum.reduce(Cgroup.list_leaves(tree), state, fn name, acc ->
      leaf = Path.join(tree.agents, name)

      cond do
        Map.has_key?(acc.reaping, name) ->
          acc

        live?(name) ->
          acc

        Cgroup.populated?(leaf) == true ->
          Logger.warning(
            "[process_isolation] sweep: stale agent cgroup #{name} still has " <>
              "#{length(Cgroup.procs(leaf))} process(es) and no live owner; killing it"
          )

          start_reap(acc, %Spawn{id: name, session_id: session_of(name), leaf: leaf}, 0)

        true ->
          if remove(acc, leaf) == :ok,
            do: Logger.info("[process_isolation] sweep: removed empty stale agent cgroup #{name}")

          acc
      end
    end)
  end

  defp live?(name) do
    Registry.lookup(@registry, name) != []
  rescue
    _ -> false
  end

  # Spawn ids are "<session id>-<12 hex>".
  defp session_of(name), do: String.replace(name, ~r/-[0-9a-f]{12}\z/, "")

  defp schedule_sweep(%{mode: {:cgroup, _, _}, sweep_interval_ms: ms})
       when is_integer(ms) and ms > 0,
       do: Process.send_after(self(), :sweep, ms)

  defp schedule_sweep(_state), do: :ok
end
