defmodule OrcaHub.Cluster.FleetStatusTest do
  @moduledoc """
  The fleet drift view.

  Same two ground rules as `OrcaHub.Cluster.CodePushTest`: never use a real
  OrcaHub module as a fixture, and the only target node is `node()`
  (`:nonode@nohost` under `mix test`), which `:erpc` serves without
  distribution.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.Cluster.{CodeStamp, CodeSync, FleetStatus}
  alias OrcaHub.CodeGenerations
  alias OrcaHub.CodeGenerations.CodeGeneration

  @erts List.to_string(:erlang.system_info(:version))

  setup do
    Repo.delete_all(CodeGeneration)
    CodeStamp.clear()
    on_exit(&CodeStamp.clear/0)
    :ok
  end

  defp unique_module(prefix), do: "#{prefix}.U#{System.unique_integer([:positive])}"

  defp entry(name, body) do
    [{mod, binary}] = Code.compile_string("defmodule #{name} do #{body} end")
    {:ok, {^mod, md5}} = :beam_lib.md5(binary)
    %{module: mod, binary: binary, md5: md5, path: ~c"fixture.beam"}
  end

  defp publish!(entries) do
    {:ok, generation} =
      CodeGenerations.publish(
        %{
          base_sha: "feedface1234",
          erts_version: @erts,
          published_by: "test",
          published_from_node: to_string(node())
        },
        entries
      )

    generation
  end

  defp row_for(report, target \\ node()),
    do: Enum.find(report.nodes, &(&1.node == target))

  # ------------------------------------------------------------------
  # The two shas
  # ------------------------------------------------------------------

  describe "the two shas are kept apart" do
    test "a node with no stamp reports its build sha and NO code sha" do
      publish!([entry(unique_module("FSTest.NoStamp"), "def v, do: 1")])

      row = row_for(FleetStatus.report())

      assert row.build_sha == OrcaHub.BuildInfo.sha()
      # The whole point: no fallback to the build sha.
      assert row.code == nil
      assert row.code_error == nil
    end

    test "a stamped node reports the generation it is running, separately" do
      publish!([entry(unique_module("FSTest.Stamped"), "def v, do: 1")])

      {:ok, _} =
        CodeStamp.record(node(), %{
          generation_id: "gen-x",
          base_sha: "deadbeefcafe",
          dirty: true,
          module_count: 1,
          modules_loaded: 1,
          apply_status: "reconciled"
        })

      row = row_for(FleetStatus.report())

      assert row.build_sha == OrcaHub.BuildInfo.sha()
      assert row.code.base_sha == "deadbeefcafe"
      assert row.code.dirty == true
      refute row.code.base_sha == row.build_sha
    end
  end

  # ------------------------------------------------------------------
  # The comparison basis
  # ------------------------------------------------------------------

  describe "basis" do
    test "with a generation published, drift is measured against it" do
      publish!([entry(unique_module("FSTest.Basis"), "def v, do: 1")])

      report = FleetStatus.report()

      assert report.basis.kind == :generation
      assert report.basis.label =~ "feedface1234"
      assert report.generation.base_sha == "feedface1234"
      assert report.total_checked == 1
    end

    test "a dirty generation says so in the basis label" do
      {:ok, _} =
        CodeGenerations.publish(
          %{base_sha: "beefbeef", erts_version: @erts, dirty: true},
          [entry(unique_module("FSTest.Dirty"), "def v, do: 1")]
        )

      assert FleetStatus.report().basis.label =~ "(dirty)"
    end

    test "a generation this node will REFUSE says so in the basis label" do
      # The drift it describes is still worth seeing, but the label must not
      # let an operator read it as the thing the fleet is converging on —
      # see OrcaHub.CodeGenerations.Provenance.
      previous = Application.fetch_env(:orca_hub, :trust_test_code_generations)
      Application.put_env(:orca_hub, :trust_test_code_generations, false)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:orca_hub, :trust_test_code_generations, value)
          :error -> Application.delete_env(:orca_hub, :trust_test_code_generations)
        end
      end)

      publish!([entry(unique_module("FSTest.Untrusted"), "def v, do: 1")])

      report = FleetStatus.report()

      assert report.basis.kind == :generation
      assert report.basis.label =~ "REFUSED, untrusted publish provenance"
      refute report.generation.provenance_trusted
    end

    test "with nothing published it falls back to this node's build, and names it" do
      report = FleetStatus.report(ebin: CodeSync.default_ebin_dir())

      assert report.basis.kind == :local_ebin
      assert report.basis.label =~ "no generation published"
      assert report.generation == nil
      assert report.total_checked > 0
    end
  end

  # ------------------------------------------------------------------
  # Drift categories
  # ------------------------------------------------------------------

  describe "drift categories" do
    test "a module running identical code is counted identical, and needs no push" do
      publish!([entry(unique_module("FSTest.Same"), "def v, do: 1")])

      row = row_for(FleetStatus.report())

      assert row.identical == 1
      assert row.drifted == []
      assert row.absent == []
      assert row.not_loaded == []
      # Not :out_of_date — nothing here needs pushing. (In this VM the whole
      # real app is resident and the generation holds one fixture, so every
      # OrcaHub module reads as orphaned; that is the truthful answer for a
      # one-module generation and is asserted on its own below.)
      refute row.status == :out_of_date
    end

    test "a module whose running md5 differs is DRIFTED and the node is out of date" do
      name = unique_module("FSTest.Drifted")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      publish!([v2])

      row = row_for(FleetStatus.report())

      assert row.drifted == [v2.module]
      assert row.status == :out_of_date
    end

    test "a module the node has never had is ABSENT, not merely 'missing'" do
      e = entry(unique_module("FSTest.Absent"), "def v, do: 1")
      :code.purge(e.module)
      :code.delete(e.module)
      refute :erlang.module_loaded(e.module)

      publish!([e])

      row = row_for(FleetStatus.report())

      # Compiled in memory and then deleted: :code.which/1 has no path for
      # it anywhere, which is exactly the "genuinely not on this node" case.
      assert row.absent == [e.module]
      assert row.not_loaded == []
      assert row.unknown == []
      assert row.missing_classified?
      assert row.status == :out_of_date
    end

    test "a module present in the code path but not loaded is NOT_LOADED, not absent" do
      # The distinction the md5 probe cannot make on its own: this module is
      # sitting in an ebin dir the node can reach, so a release in embedded
      # mode would load it on demand — reporting it as 'absent' would send an
      # operator chasing a push that isn't needed.
      dir = Path.join(System.tmp_dir!(), "fleet_status_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      e = entry(unique_module("FSTest.NotLoaded"), "def v, do: 1")
      File.write!(Path.join(dir, "#{e.module}.beam"), e.binary)
      :code.purge(e.module)
      :code.delete(e.module)
      true = :code.add_pathz(to_charlist(dir))
      on_exit(fn -> :code.del_path(to_charlist(dir)) end)

      refute :erlang.module_loaded(e.module)
      publish!([e])

      row = row_for(FleetStatus.report())

      assert row.not_loaded == [e.module]
      assert row.absent == []
      assert row.missing_classified?
      # And NOT out of date: the node has the code and will load it on
      # demand. See the dedicated test below.
      refute row.status == :out_of_date
    end

    test "not_loaded is NOT out-of-date: a node with only unloaded modules is healthy" do
      # The regression this pins: `not_loaded` used to be summed into
      # `drifted` + `absent`, so a freshly deployed, perfectly healthy node
      # rendered OUT OF DATE purely for not having demanded most of
      # Mix.Tasks.*/Inspect.* into memory yet (253 of 289 measured on a real
      # idle node; a node serving traffic on the identical image reported
      # zero). Nothing about that state is fixable by a push.
      dir = Path.join(System.tmp_dir!(), "fleet_status_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # Many unloaded modules, zero drifted, zero absent — the shape of an
      # idle embedded release.
      unloaded =
        for _ <- 1..25 do
          e = entry(unique_module("FSTest.Healthy"), "def v, do: 1")
          File.write!(Path.join(dir, "#{e.module}.beam"), e.binary)
          :code.purge(e.module)
          :code.delete(e.module)
          refute :erlang.module_loaded(e.module)
          e
        end

      true = :code.add_pathz(to_charlist(dir))
      on_exit(fn -> :code.del_path(to_charlist(dir)) end)

      publish!(unloaded)

      row = row_for(FleetStatus.report())

      assert length(row.not_loaded) == 25
      assert row.drifted == []
      assert row.absent == []
      assert row.unknown == []
      assert row.identical == 0
      assert row.missing_classified?

      # HEALTHY. (Every real OrcaHub module is resident and absent from this
      # 25-module generation, so the truthful verdict here is :orphans_only
      # — the point is that it is not :out_of_date, and that the verdict does
      # not move when not_loaded grows.)
      refute row.status == :out_of_date
      assert row.status in [:in_sync, :orphans_only]
    end

    test "a resident module absent from the generation is ORPHANED" do
      # Must live under the OrcaHub namespace: resident_modules/1 only counts
      # `Elixir.OrcaHub*` code, since purging anything else was never ours to
      # do. A fixture outside it would be invisible and prove nothing.
      orphan = entry(unique_module("OrcaHub.FSTest.Orphan"), "def v, do: 1")
      :code.purge(orphan.module)
      :code.delete(orphan.module)
      {:module, _} = :code.load_binary(orphan.module, ~c"/fixture/orphan.beam", orphan.binary)

      publish!([entry(unique_module("FSTest.Kept"), "def v, do: 1")])

      row = row_for(FleetStatus.report())

      assert orphan.module in row.orphaned
      # Orphans alone are not "out of date" — nothing needs pushing, the
      # remedy is an explicit purge.
      assert row.status == :orphans_only
      assert row.drifted == [] and row.absent == [] and row.not_loaded == []
    end

    test "OrcaHub.BuildInfo is never reported as an orphan" do
      publish!([entry(unique_module("FSTest.NoBuildInfo"), "def v, do: 1")])

      refute OrcaHub.BuildInfo in row_for(FleetStatus.report()).orphaned
    end
  end

  # ------------------------------------------------------------------
  # Uncertainty
  # ------------------------------------------------------------------

  describe "unreachable nodes" do
    test "a node that cannot be asked is a row carrying an error, not a silent omission" do
      publish!([entry(unique_module("FSTest.Unreachable"), "def v, do: 1")])

      entries = [%{module: FSTestNotAModule, md5: <<0>>}]
      row = FleetStatus.node_report(:gone@nowhere, entries, nil)

      assert row.status == :unreachable
      assert row.error =~ "REFUSED"
      assert row.build_sha == nil
      assert row.build_sha_error
      assert row.code == nil
      assert row.code_error
    end
  end

  describe "code_locations/3" do
    test "classifies absent, not-loaded and never laundered transport failures" do
      assert {:ok, %{}} == CodeSync.code_locations(node(), [])

      assert {:ok, %{ThisModuleDoesNotExistAnywhere: :absent}} ==
               CodeSync.code_locations(node(), [:ThisModuleDoesNotExistAnywhere])

      # A transport failure stays a transport failure. Laundering it into
      # :absent would report a whole unreachable node as "missing every
      # module", which is the exact confusion this function exists to end.
      assert {:error, :noconnection} = CodeSync.code_locations(:gone@nowhere, [Enum])
    end
  end
end
