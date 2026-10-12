defmodule OrcaHub.FakeCgroupfs do
  @moduledoc """
  A plain temp directory standing in for a cgroup v2 tree, for
  `OrcaHub.ProcessIsolation.Cgroup` tests: `bin/test` never runs in a
  delegated cgroup, so the module's root path is injected instead.

  The two things a plain directory can't do the way cgroupfs does are
  passed in as the module's `:mkdir`/`:rmdir` functions: `mkdir/1` fills a
  new cgroup with its control files, and `rmdir/1` removes one that holds
  them, refusing with `:ebusy` while `cgroup.events` says it is populated
  or it still has child cgroups.
  """

  @doc """
  Builds `<tmp>/system.slice/orca-hub.service/beam` plus a
  `/proc/self/cgroup` stand-in naming it. Returns the detect/1 options.
  Options: `:proc_self_cgroup` (that stand-in's contents), `:controllers`
  (the service's cgroup.controllers), `:service_memory_max`.
  """
  def build!(tmp, opts \\ []) do
    root = Path.join(tmp, "cgroupfs")
    service = Path.join(root, "system.slice/orca-hub.service")
    File.mkdir_p!(Path.dirname(service))
    :ok = mkdir(service)

    File.write!(
      Path.join(service, "cgroup.controllers"),
      Keyword.get(opts, :controllers, "cpu io memory pids")
    )

    File.write!(
      Path.join(service, "memory.max"),
      Keyword.get(opts, :service_memory_max, "6442450944\n")
    )

    :ok = mkdir(Path.join(service, "beam"))

    proc_self_cgroup = Path.join(tmp, "proc-self-cgroup")

    File.write!(
      proc_self_cgroup,
      Keyword.get(opts, :proc_self_cgroup, "0::/system.slice/orca-hub.service/beam\n")
    )

    [
      cgroup_root: root,
      proc_self_cgroup: proc_self_cgroup,
      mkdir: &mkdir/1,
      rmdir: &rmdir/1
    ]
  end

  @control_files [
    {"cgroup.procs", ""},
    {"cgroup.events", "populated 0\nfrozen 0\n"},
    {"cgroup.kill", ""},
    {"cgroup.controllers", "memory pids"},
    {"cgroup.subtree_control", ""},
    {"memory.max", "max\n"},
    {"memory.swap.max", "max\n"},
    {"memory.low", "0\n"},
    {"pids.max", "max\n"}
  ]

  def mkdir(path) do
    with :ok <- File.mkdir(path) do
      Enum.each(@control_files, fn {name, body} -> File.write!(Path.join(path, name), body) end)
    end
  end

  def rmdir(path) do
    cond do
      not File.dir?(path) -> {:error, :enoent}
      populated?(path) -> {:error, :ebusy}
      Enum.any?(File.ls!(path), &File.dir?(Path.join(path, &1))) -> {:error, :ebusy}
      true -> File.rm_rf!(path) && :ok
    end
  end

  def set_populated(path, populated?) do
    File.write!(
      Path.join(path, "cgroup.events"),
      "populated #{if populated?, do: 1, else: 0}\nfrozen 0\n"
    )
  end

  def read(path, file), do: File.read!(Path.join(path, file))

  defp populated?(path) do
    case File.read(Path.join(path, "cgroup.events")) do
      {:ok, body} -> body =~ ~r/^populated 1$/m
      _ -> false
    end
  end
end
