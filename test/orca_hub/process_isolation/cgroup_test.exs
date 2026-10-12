defmodule OrcaHub.ProcessIsolation.CgroupTest do
  @moduledoc """
  `OrcaHub.ProcessIsolation.Cgroup` against `OrcaHub.FakeCgroupfs`, a temp
  dir standing in for a delegated cgroup v2 tree. The real kernel mechanics
  (a leaf's memory.max OOM-killing a hog, cgroup.kill reaping an orphan)
  can't run under `bin/test`; they were proven under a transient
  `systemd-run --user -p Delegate=yes -p DelegateSubgroup=beam` unit (see
  the ORCAHUB3-146 commit message).
  """
  use ExUnit.Case, async: true

  alias OrcaHub.FakeCgroupfs
  alias OrcaHub.ProcessIsolation.{Cgroup, Limits}

  @moduletag :tmp_dir

  @gib 1024 * 1024 * 1024

  defp service(opts), do: Path.join(opts[:cgroup_root], "system.slice/orca-hub.service")

  describe "detect/1" do
    test "a delegated `beam` subgroup: enables memory+pids, creates agents/, leaves no probe", %{
      tmp_dir: tmp
    } do
      opts = FakeCgroupfs.build!(tmp)
      service = service(opts)

      assert {:ok, tree} = Cgroup.detect(opts)

      assert tree.service == service
      assert tree.beam == Path.join(service, "beam")
      assert tree.agents == Path.join(service, "agents")
      assert tree.controllers == ["memory", "pids"]
      assert FakeCgroupfs.read(service, "cgroup.subtree_control") == "+memory +pids"
      assert FakeCgroupfs.read(tree.agents, "cgroup.subtree_control") == "+memory +pids"
      # The probe moved a real `sh` into a probe leaf, then removed it.
      assert Cgroup.list_leaves(tree) == []
    end

    test "controllers already enabled are not rewritten", %{tmp_dir: tmp} do
      opts = FakeCgroupfs.build!(tmp)
      File.write!(Path.join(service(opts), "cgroup.subtree_control"), "memory pids")

      assert {:ok, %{controllers: ["memory", "pids"]}} = Cgroup.detect(opts)
      assert FakeCgroupfs.read(service(opts), "cgroup.subtree_control") == "memory pids"
    end

    test "only what the parent offers: no memory controller means kill without limits", %{
      tmp_dir: tmp
    } do
      opts = FakeCgroupfs.build!(tmp, controllers: "cpu pids")
      assert {:ok, %{controllers: ["pids"]}} = Cgroup.detect(opts)
    end

    test "refuses a cgroup that isn't the delegated `beam` subgroup", %{tmp_dir: tmp} do
      # Today's units: the BEAM sits directly in orca-hub.service.
      opts = FakeCgroupfs.build!(tmp, proc_self_cgroup: "0::/system.slice/orca-hub.service\n")
      assert {:error, reason} = Cgroup.detect(opts)
      assert reason =~ "not a delegated `beam` subgroup"
      refute File.exists?(Path.join(service(opts), "agents"))
    end

    test "refuses a k3s pod's namespaced root cgroup", %{tmp_dir: tmp} do
      opts = FakeCgroupfs.build!(tmp, proc_self_cgroup: "0::/\n")
      assert {:error, _} = Cgroup.detect(opts)
    end

    test "refuses cgroup v1 (no unified `0::` line)", %{tmp_dir: tmp} do
      opts = FakeCgroupfs.build!(tmp, proc_self_cgroup: "1:name=systemd:/system.slice/x\n")
      assert {:error, reason} = Cgroup.detect(opts)
      assert reason =~ "no cgroup v2 entry"
    end

    test "refuses a kernel without cgroup.kill", %{tmp_dir: tmp} do
      opts = FakeCgroupfs.build!(tmp)
      File.rm!(Path.join(service(opts), "cgroup.kill"))
      assert {:error, reason} = Cgroup.detect(opts)
      assert reason =~ "5.14"
    end

    test "refuses a subtree this user can't write (not delegated)", %{tmp_dir: tmp} do
      opts = FakeCgroupfs.build!(tmp)
      control = Path.join(service(opts), "cgroup.subtree_control")
      File.chmod!(control, 0o444)
      on_exit(fn -> File.chmod(control, 0o644) end)

      assert {:error, reason} = Cgroup.detect(opts)
      assert reason =~ "not writable"
    end

    test "refuses when no process can be moved into agents/", %{tmp_dir: tmp} do
      opts = FakeCgroupfs.build!(tmp)
      # A probe leaf whose cgroup.procs can't be written stands in for a unit
      # whose own cgroup.procs wasn't chowned to the delegated user.
      mkdir = fn path ->
        with :ok <- FakeCgroupfs.mkdir(path) do
          if String.contains?(Path.basename(path), "probe-"),
            do: File.chmod!(Path.join(path, "cgroup.procs"), 0o444)

          :ok
        end
      end

      assert {:error, reason} = Cgroup.detect(Keyword.put(opts, :mkdir, mkdir))
      assert reason =~ "cannot move a process"
    end
  end

  describe "a detected tree" do
    setup %{tmp_dir: tmp} do
      {:ok, tree} = Cgroup.detect(FakeCgroupfs.build!(tmp))
      %{tree: tree}
    end

    test "apply_aggregate_limits/2 caps agents/ and protects beam/", %{tree: tree} do
      limits = Limits.resolve([], 10 * @gib)

      assert Cgroup.apply_aggregate_limits(tree, limits) == []
      assert FakeCgroupfs.read(tree.agents, "memory.max") == "#{8 * @gib}"
      assert FakeCgroupfs.read(tree.agents, "memory.swap.max") == "0"
      assert FakeCgroupfs.read(tree.beam, "memory.low") == "#{@gib}"
    end

    test "create_leaf/3 applies the per-spawn limits", %{tree: tree} do
      limits = Limits.resolve([agent_memory_max: "2G", agent_pids_max: "100"], 10 * @gib)

      assert {:ok, leaf, []} = Cgroup.create_leaf(tree, "sess-1-aaaaaaaaaaaa", limits)
      assert leaf == Path.join(tree.agents, "sess-1-aaaaaaaaaaaa")
      assert FakeCgroupfs.read(leaf, "memory.max") == "#{2 * @gib}"
      assert FakeCgroupfs.read(leaf, "memory.swap.max") == "0"
      assert FakeCgroupfs.read(leaf, "pids.max") == "100"
      assert Cgroup.list_leaves(tree) == ["sess-1-aaaaaaaaaaaa"]
    end

    test "create_leaf/3 without swap accounting skips memory.swap.max silently", %{tree: tree} do
      mkdir = fn path ->
        with :ok <- FakeCgroupfs.mkdir(path), do: File.rm(Path.join(path, "memory.swap.max"))
      end

      assert {:ok, _leaf, []} =
               Cgroup.create_leaf(
                 %{tree | mkdir: mkdir},
                 "s-bbbbbbbbbbbb",
                 Limits.resolve([], @gib)
               )
    end

    test "create_leaf/3 reports a leaf that can't be created", %{tree: tree} do
      assert {:ok, _, _} = Cgroup.create_leaf(tree, "dup", Limits.resolve([], @gib))
      assert {:error, :eexist} = Cgroup.create_leaf(tree, "dup", Limits.resolve([], @gib))
    end

    test "kill/1, populated?/1 and procs/1", %{tree: tree} do
      {:ok, leaf, _} = Cgroup.create_leaf(tree, "s-cccccccccccc", Limits.resolve([], @gib))
      File.write!(Path.join(leaf, "cgroup.procs"), "101\n202\n")
      FakeCgroupfs.set_populated(leaf, true)

      assert Cgroup.procs(leaf) == [101, 202]
      assert Cgroup.populated?(leaf) == true
      assert Cgroup.kill(leaf) == :ok
      assert FakeCgroupfs.read(leaf, "cgroup.kill") == "1"

      FakeCgroupfs.set_populated(leaf, false)
      assert Cgroup.populated?(leaf) == false

      gone = Path.join(tree.agents, "never-existed")
      assert Cgroup.kill(gone) == :gone
      assert Cgroup.populated?(gone) == :gone
      assert Cgroup.procs(gone) == []
    end

    test "remove_leaf/3 removes sub-cgroups an agent made, deepest first", %{tree: tree} do
      {:ok, leaf, _} = Cgroup.create_leaf(tree, "s-dddddddddddd", Limits.resolve([], @gib))
      :ok = FakeCgroupfs.mkdir(Path.join(leaf, "nested"))
      :ok = FakeCgroupfs.mkdir(Path.join(leaf, "nested/deeper"))

      assert Cgroup.remove_leaf(tree, leaf) == :ok
      refute File.exists?(leaf)
      # Already gone is fine.
      assert Cgroup.remove_leaf(tree, leaf) == :ok
    end

    test "remove_leaf/3 refuses a populated leaf", %{tree: tree} do
      {:ok, leaf, _} = Cgroup.create_leaf(tree, "s-eeeeeeeeeeee", Limits.resolve([], @gib))
      FakeCgroupfs.set_populated(leaf, true)

      assert Cgroup.remove_leaf(tree, leaf) == {:error, :ebusy}
      assert File.dir?(leaf)
    end
  end

  describe "memory_base/2" do
    test "the unit's own memory.max when it has one, else host RAM", %{tmp_dir: tmp} do
      {:ok, tree} = Cgroup.detect(FakeCgroupfs.build!(tmp, service_memory_max: "6442450944\n"))
      assert Cgroup.memory_base(tree) == 6 * @gib

      File.write!(Path.join(tree.service, "memory.max"), "max\n")
      meminfo = Path.join(tmp, "meminfo")
      File.write!(meminfo, "MemTotal:       16303316 kB\nMemFree:  1 kB\n")
      assert Cgroup.memory_base(tree, meminfo) == 16_303_316 * 1024

      assert Cgroup.memory_base(tree, Path.join(tmp, "absent")) == nil
    end
  end
end
