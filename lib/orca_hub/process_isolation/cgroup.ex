defmodule OrcaHub.ProcessIsolation.Cgroup do
  @moduledoc """
  The cgroup v2 half of `OrcaHub.ProcessIsolation`: finding a delegated
  subtree, laying out `agents/`, and creating, killing and removing one
  leaf per agent CLI spawn.

  The layout, under a unit with `Delegate=yes` + `DelegateSubgroup=beam`
  (systemd/orca-hub.service.template):

      <service>/               orca-hub.service, delegated to the service user
        beam/                  the BEAM, plus what it spawns itself (jobs,
                               terminals, git): memory.low only
        agents/                every agent CLI tree: memory.max, memory.swap.max
          <spawn id>/          one leaf per CLI spawn: memory.max,
                               memory.swap.max, pids.max; cgroup.kill on teardown

  Only used when the BEAM's own cgroup is literally named after the
  configured subgroup (`beam`) and its parent accepts our writes. A dev
  shell, `bin/test`, a k3s pod or a host whose unit predates delegation
  never matches, so nothing here touches a cgroup tree it was not handed.

  Every function takes the cgroupfs root as data (`%Cgroup{}` or the
  `:cgroup_root` option), so tests run against a plain temp dir. The two
  operations a plain dir can't mimic go through the `mkdir`/`rmdir` fields:
  the kernel populates a new cgroup with its control files, and removes one
  that still holds them.
  """

  require Logger

  alias OrcaHub.ProcessIsolation.Limits

  @wanted_controllers ["memory", "pids"]

  defstruct [
    :root,
    :service,
    :beam,
    :agents,
    controllers: [],
    mkdir: &File.mkdir/1,
    rmdir: &File.rmdir/1
  ]

  @type t :: %__MODULE__{
          root: String.t(),
          service: String.t(),
          beam: String.t(),
          agents: String.t(),
          controllers: [String.t()],
          mkdir: (String.t() -> :ok | {:error, term()}),
          rmdir: (String.t() -> :ok | {:error, term()})
        }

  @doc """
  Finds and prepares the delegated subtree. Returns `{:ok, tree}` with
  `agents/` created and `controllers` enabled for it (possibly `[]`: kill
  still works without them, limits don't), or `{:error, reason}` with a
  human-readable reason.

  Options: `:cgroup_root` (`/sys/fs/cgroup`), `:proc_self_cgroup`
  (`/proc/self/cgroup`), `:subgroup` (`"beam"`), `:mkdir`/`:rmdir`, and `:probe`
  (default true): move a throwaway `sh` into a probe leaf, which proves the
  one permission the layout alone doesn't, migrating a process out of
  `beam/`.
  """
  @spec detect(keyword()) :: {:ok, t()} | {:error, String.t()}
  def detect(opts \\ []) do
    root = Keyword.get(opts, :cgroup_root, "/sys/fs/cgroup")
    subgroup = Keyword.get(opts, :subgroup, "beam")
    mkdir_fun = Keyword.get(opts, :mkdir, &File.mkdir/1)

    with {:ok, own} <- own_cgroup(Keyword.get(opts, :proc_self_cgroup, "/proc/self/cgroup")),
         :ok <- check_subgroup(own, subgroup),
         service = Path.join(root, Path.dirname(own)),
         :ok <- check_kill_support(service),
         {:ok, controllers} <- enable_controllers(service, @wanted_controllers),
         agents = Path.join(service, "agents"),
         :ok <- mkdir(mkdir_fun, agents),
         {:ok, controllers} <- enable_controllers(agents, controllers) do
      tree = %__MODULE__{
        root: root,
        service: service,
        beam: Path.join(root, own),
        agents: agents,
        controllers: controllers,
        mkdir: mkdir_fun,
        rmdir: Keyword.get(opts, :rmdir, &File.rmdir/1)
      }

      if Keyword.get(opts, :probe, true), do: probe(tree), else: {:ok, tree}
    end
  end

  # cgroup v2 only: the unified hierarchy is the single `0::<path>` line.
  # Hybrid hosts list v1 controllers too; only the `0::` line matters.
  defp own_cgroup(proc_self_cgroup) do
    case File.read(proc_self_cgroup) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.find_value({:error, "no cgroup v2 entry in #{proc_self_cgroup}"}, fn
          "0::" <> path -> {:ok, path}
          _ -> nil
        end)

      {:error, reason} ->
        {:error, "cannot read #{proc_self_cgroup}: #{:file.format_error(reason)}"}
    end
  end

  defp check_subgroup(own, subgroup) do
    if Path.basename(own) == subgroup and own not in ["/", ""] do
      :ok
    else
      {:error,
       "the BEAM's cgroup #{own} is not a delegated `#{subgroup}` subgroup " <>
         "(the unit has no Delegate=yes + DelegateSubgroup=#{subgroup})"}
    end
  end

  defp check_kill_support(service) do
    if File.exists?(Path.join(service, "cgroup.kill")),
      do: :ok,
      else: {:error, "#{service} has no cgroup.kill (needs Linux >= 5.14)"}
  end

  # Enables whichever of `wanted` the parent offers in `dir`'s
  # subtree_control. Returns the controllers actually enabled. A write
  # refused with EACCES/EPERM means the subtree isn't ours: that is a
  # detection failure, not a degraded mode.
  defp enable_controllers(dir, wanted) do
    available = read_words(Path.join(dir, "cgroup.controllers"))
    enabled = read_words(Path.join(dir, "cgroup.subtree_control"))
    offered = Enum.filter(wanted, &(&1 in available))

    case offered -- enabled do
      [] ->
        {:ok, offered}

      missing ->
        case write(
               Path.join(dir, "cgroup.subtree_control"),
               Enum.map_join(missing, " ", &("+" <> &1))
             ) do
          :ok ->
            {:ok, offered}

          {:error, reason} when reason in [:eacces, :eperm, :erofs] ->
            {:error, "#{dir} is not writable by this user (#{reason}): not delegated"}

          {:error, reason} ->
            Logger.warning(
              "[process_isolation] could not enable #{Enum.join(missing, "+")} in " <>
                "#{dir} (#{inspect(reason)}); agent cgroups will kill but not limit"
            )

            {:ok, offered -- missing}
        end
    end
  end

  defp mkdir(mkdir_fun, dir) do
    case mkdir_fun.(dir) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp probe(tree) do
    leaf = Path.join(tree.agents, "probe-" <> random_suffix())

    with :ok <- mkdir(tree.mkdir, leaf) do
      result =
        try do
          System.cmd("/bin/sh", ["-c", ~S(echo $$ > "$1/cgroup.procs"), "orca-probe", leaf],
            stderr_to_stdout: true
          )
        rescue
          e -> {Exception.message(e), 1}
        end

      remove_leaf(tree, leaf, 10)

      case result do
        {_, 0} ->
          {:ok, tree}

        {output, _} ->
          {:error,
           "cannot move a process into #{tree.agents}: #{String.trim(output)} " <>
             "(cgroup.procs of the delegated unit must be writable)"}
      end
    end
  end

  @doc """
  Applies the aggregate limits: `agents/` memory.max + memory.swap.max and
  the BEAM's memory.low. Best effort, returns the failures as warnings.
  """
  @spec apply_aggregate_limits(t(), Limits.t()) :: [String.t()]
  def apply_aggregate_limits(%__MODULE__{} = tree, %Limits{} = limits) do
    if "memory" in tree.controllers do
      [
        {Path.join(tree.agents, "memory.max"), limits.agents_memory_max},
        {Path.join(tree.agents, "memory.swap.max"), limits.agent_swap_max},
        {Path.join(tree.beam, "memory.low"), limits.beam_memory_low}
      ]
      |> Enum.flat_map(&write_limit/1)
    else
      []
    end
  end

  @doc """
  Creates the leaf for one spawn and applies the per-spawn limits. Returns
  `{:ok, path, warnings}`, or `{:error, reason}` if the leaf itself could
  not be created (the caller then spawns without one).
  """
  @spec create_leaf(t(), String.t(), Limits.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def create_leaf(%__MODULE__{} = tree, id, %Limits{} = limits) do
    leaf = Path.join(tree.agents, id)

    case tree.mkdir.(leaf) do
      :ok ->
        memory =
          if "memory" in tree.controllers,
            do: [
              {Path.join(leaf, "memory.max"), limits.agent_memory_max},
              {Path.join(leaf, "memory.swap.max"), limits.agent_swap_max}
            ],
            else: []

        pids =
          if "pids" in tree.controllers,
            do: [{Path.join(leaf, "pids.max"), limits.agent_pids_max}],
            else: []

        {:ok, leaf, Enum.flat_map(memory ++ pids, &write_limit/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Checked first because an open(O_CREAT) on a control file the kernel
  # didn't create fails with a misleading permission error. memory.swap.max
  # is absent without swap accounting, which isn't worth a warning per spawn.
  defp write_limit({path, value}) do
    cond do
      not File.exists?(path) and Path.basename(path) == "memory.swap.max" ->
        []

      not File.exists?(path) ->
        ["#{path}: missing"]

      true ->
        case write(path, Limits.to_cgroup(value)) do
          :ok -> []
          {:error, reason} -> ["#{path} <- #{Limits.to_cgroup(value)}: #{inspect(reason)}"]
        end
    end
  end

  @doc """
  SIGKILLs everything in the leaf and its descendants, atomically with
  respect to forks (the kernel's cgroup.kill). `:gone` if the leaf no
  longer exists.
  """
  @spec kill(String.t()) :: :ok | :gone | {:error, term()}
  def kill(leaf) do
    case write(Path.join(leaf, "cgroup.kill"), "1") do
      :ok -> :ok
      {:error, :enoent} -> :gone
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether anything (in the leaf or below it) is still running."
  @spec populated?(String.t()) :: boolean() | :gone
  def populated?(leaf) do
    case File.read(Path.join(leaf, "cgroup.events")) do
      {:ok, body} -> Regex.match?(~r/^populated 1$/m, body)
      {:error, _} -> :gone
    end
  end

  @doc "The pids directly in `leaf` (not its sub-cgroups); `[]` if gone."
  @spec procs(String.t()) :: [pos_integer()]
  def procs(leaf) do
    case File.read(Path.join(leaf, "cgroup.procs")) do
      {:ok, body} ->
        for line <- String.split(body, "\n", trim: true),
            {pid, ""} <- [Integer.parse(line)],
            do: pid

      {:error, _} ->
        []
    end
  end

  @doc """
  Removes the leaf, deepest first: an agent can mkdir sub-cgroups inside
  its own leaf, and rmdir refuses a cgroup that still has children. Retries
  `attempts` times on EBUSY, which a just-killed leaf can briefly report.
  """
  @spec remove_leaf(t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def remove_leaf(%__MODULE__{} = tree, leaf, attempts \\ 0) do
    leaf
    |> subdirs()
    |> Enum.each(&remove_leaf(tree, &1, attempts))

    case tree.rmdir.(leaf) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, :ebusy} when attempts > 0 ->
        Process.sleep(20)
        remove_leaf(tree, leaf, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Names of the leaves currently under `agents/`."
  @spec list_leaves(t()) :: [String.t()]
  def list_leaves(%__MODULE__{agents: agents}) do
    case File.ls(agents) do
      {:ok, names} -> names |> Enum.filter(&File.dir?(Path.join(agents, &1))) |> Enum.sort()
      {:error, _} -> []
    end
  end

  @doc """
  The budget a percentage limit is taken of: the service's own memory.max
  when it is a number, else host RAM from `meminfo`, else nil.
  """
  @spec memory_base(t(), String.t()) :: pos_integer() | nil
  def memory_base(%__MODULE__{service: service}, meminfo \\ "/proc/meminfo") do
    with {:ok, body} <- File.read(Path.join(service, "memory.max")),
         {bytes, _} <- Integer.parse(String.trim(body)) do
      bytes
    else
      _ -> mem_total(meminfo)
    end
  end

  @doc "Host RAM in bytes from a `/proc/meminfo`-shaped file, or nil."
  def mem_total(meminfo \\ "/proc/meminfo") do
    with {:ok, body} <- File.read(meminfo),
         [_, kb] <- Regex.run(~r/^MemTotal:\s+(\d+)\s+kB/m, body) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, path = Path.join(dir, name), File.dir?(path), do: path

      {:error, _} ->
        []
    end
  end

  defp read_words(path) do
    case File.read(path) do
      {:ok, body} -> String.split(body)
      {:error, _} -> []
    end
  end

  # cgroupfs files take one write() each; File.write/2 opens with O_TRUNC,
  # which cgroupfs ignores.
  defp write(path, value), do: File.write(path, value)

  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
