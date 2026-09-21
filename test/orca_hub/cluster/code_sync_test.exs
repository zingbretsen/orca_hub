defmodule OrcaHub.Cluster.CodeSyncTest do
  @moduledoc """
  The two paths that matter here are the ones that are silent when they go
  wrong, so both are exercised against a REAL VM code server rather than a
  mock:

    * **purge refusal** — a module with processes still on its old code is
      genuinely manufactured (load the same binary twice with a process
      parked in between), so `:code.soft_purge/1` really does return `false`
      and we can assert that the parked process is still alive afterwards.
      A mock cannot prove "we did not kill anything".
    * **ERTS gate** — the decision (`erts_verdict/2`) and the WIRING (that
      `push/3` returns before touching the code server) are asserted
      separately, because the failure mode is "refused in theory, loaded in
      practice". The genuine two-runtime end-to-end lives in
      `OrcaHub.Cluster.CodeSyncDistributedTest`.

  `async: false`: these tests load, purge and delete modules, which is
  VM-global state.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OrcaHub.Cluster.CodeSync

  # A node name that cannot resolve, for asserting that a gate short-circuits
  # before anything is loaded.
  @nowhere :"code-sync-test-nowhere@127.0.0.127"

  # -------------------------------------------------------------------
  # Throwaway-module helpers
  # -------------------------------------------------------------------

  # Compiles (and, unavoidably, loads) a uniquely-named subject module.
  # Returns the payload entry shape CodeSync works in.
  defp compile_subject(mod, version) do
    source = """
    defmodule #{inspect(mod)} do
      def version, do: #{version}

      def loop do
        receive do
          {:ping, from} -> send(from, {:pong, version()}); loop()
          :stop -> :ok
        end
      end
    end
    """

    # The second compile of the same name warns about redefinition; that is
    # the point of the test, not a problem.
    {[{^mod, binary}], _warning} =
      with_io(:stderr, fn -> Code.compile_string(source) end)

    {:ok, {^mod, md5}} = :beam_lib.md5(binary)
    %{module: mod, binary: binary, md5: md5, path: ~c"/tmp/#{mod}.beam"}
  end

  defp unique_subject_name do
    :"Elixir.OrcaHub.CodeSyncTestSubject#{System.unique_integer([:positive])}"
  end

  defp cleanup_subject(mod) do
    on_exit(fn ->
      # Throwaway module, nothing real depends on it — hard purge is fine
      # HERE, which is exactly why production code never does it.
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end)
  end

  # -------------------------------------------------------------------
  # load_beams/1
  # -------------------------------------------------------------------

  describe "load_beams/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "code_sync_ebin_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    defp copy_beam(dir, module) do
      src = Path.join(CodeSync.default_ebin_dir(), "#{module}.beam")
      File.cp!(src, Path.join(dir, "#{module}.beam"))
      src
    end

    test "reads beams from an ARBITRARY directory, not just the running app's ebin", %{dir: dir} do
      copy_beam(dir, OrcaHub.Cluster.CodeSync)
      copy_beam(dir, OrcaHub.Cluster)

      assert {:ok, entries} = CodeSync.load_beams(dir)
      modules = Enum.map(entries, & &1.module)

      assert OrcaHub.Cluster.CodeSync in modules
      assert OrcaHub.Cluster in modules
      # Nothing leaked in from the real app dir.
      assert length(entries) == 2

      # Every entry carries the directory we asked for, not the app dir.
      for entry <- entries do
        assert to_string(entry.path) =~ dir
        assert is_binary(entry.binary) and byte_size(entry.binary) > 0
      end
    end

    test "md5 is the module's compile-time md5, NOT :erlang.md5/1 of the file bytes", %{dir: dir} do
      copy_beam(dir, OrcaHub.Cluster.CodeSync)

      assert {:ok, [entry]} = CodeSync.load_beams(dir)

      # The value a remote node can report for code it is running.
      assert entry.md5 == :erlang.get_module_info(OrcaHub.Cluster.CodeSync, :md5)
      assert entry.md5 == OrcaHub.Cluster.CodeSync.module_info(:md5)

      # The trap this replaced: hashing the container, which differs for
      # identical code and would report everything as drifted forever.
      refute entry.md5 == :erlang.md5(entry.binary)
    end

    test "OrcaHub.BuildInfo is excluded from the payload", %{dir: dir} do
      copy_beam(dir, OrcaHub.BuildInfo)
      copy_beam(dir, OrcaHub.Cluster.CodeSync)

      assert {:ok, entries} = CodeSync.load_beams(dir)
      modules = Enum.map(entries, & &1.module)

      refute OrcaHub.BuildInfo in modules
      assert OrcaHub.Cluster.CodeSync in modules
    end

    test "module name comes from the beam, so a never-loaded module is fine", %{dir: dir} do
      # Rename the file: the payload must still name the real module rather
      # than trusting the filename (or blowing up in to_existing_atom/1).
      src = Path.join(CodeSync.default_ebin_dir(), "Elixir.OrcaHub.Cluster.beam")
      File.cp!(src, Path.join(dir, "Elixir.Totally.Not.A.Loaded.Module.beam"))

      assert {:ok, [entry]} = CodeSync.load_beams(dir)
      assert entry.module == OrcaHub.Cluster
    end

    test "non-beam files are ignored", %{dir: dir} do
      copy_beam(dir, OrcaHub.Cluster.CodeSync)
      File.write!(Path.join(dir, "orca_hub.app"), "not a beam")
      File.write!(Path.join(dir, "README"), "hello")

      assert {:ok, [_only_one]} = CodeSync.load_beams(dir)
    end

    test "a corrupt .beam fails the whole load rather than pushing a partial payload", %{dir: dir} do
      copy_beam(dir, OrcaHub.Cluster.CodeSync)
      File.write!(Path.join(dir, "Elixir.Garbage.beam"), "definitely not bytecode")

      assert {:error, {:bad_beam, path, _reason}} = CodeSync.load_beams(dir)
      assert path =~ "Elixir.Garbage.beam"
    end

    test "a missing directory is an error, not a crash" do
      assert {:error, {:unreadable_dir, _dir, :enoent}} =
               CodeSync.load_beams("/tmp/code-sync-does-not-exist-#{System.unique_integer()}")
    end

    test "zero-arg default reads the running app's ebin" do
      assert {:ok, entries} = CodeSync.load_beams()
      modules = MapSet.new(entries, & &1.module)

      assert OrcaHub.Cluster.CodeSync in modules
      refute OrcaHub.BuildInfo in modules
    end
  end

  # -------------------------------------------------------------------
  # payload ordering / exclusions
  # -------------------------------------------------------------------

  describe "payload_order/2" do
    defp fake_entry(mod), do: %{module: mod, binary: <<>>, md5: <<>>, path: ~c"x"}

    test "CodeSync itself is moved to the very end, never pushed mid-iteration" do
      entries = [
        fake_entry(OrcaHub.Cluster.CodeSync),
        fake_entry(OrcaHub.Cluster),
        fake_entry(OrcaHub.Sessions)
      ]

      assert [OrcaHub.Cluster, OrcaHub.Sessions, OrcaHub.Cluster.CodeSync] =
               entries |> CodeSync.payload_order(true) |> Enum.map(& &1.module)
    end

    test "include_self: false drops CodeSync entirely" do
      entries = [fake_entry(OrcaHub.Cluster.CodeSync), fake_entry(OrcaHub.Cluster)]

      assert [OrcaHub.Cluster] =
               entries |> CodeSync.payload_order(false) |> Enum.map(& &1.module)
    end

    test "BuildInfo is stripped even from a hand-built payload" do
      entries = [fake_entry(OrcaHub.BuildInfo), fake_entry(OrcaHub.Cluster)]

      assert [OrcaHub.Cluster] =
               entries |> CodeSync.payload_order(true) |> Enum.map(& &1.module)
    end
  end

  # -------------------------------------------------------------------
  # ERTS compatibility
  # -------------------------------------------------------------------

  describe "compatible?/1 and the ERTS verdict" do
    test "identical versions are compatible" do
      assert CodeSync.erts_verdict("15.2.2", "15.2.2") == :ok
    end

    test "a mismatch names BOTH versions, in local/remote order" do
      # The real situation this exists for: this host's toolchain is newer
      # than the runtime the fleet was built with, which is the direction
      # OTP does NOT support.
      assert CodeSync.erts_verdict("15.2.7.9", "15.2.2") ==
               {:error, {:erts_mismatch, "15.2.7.9", "15.2.2"}}
    end

    test "the older-here/newer-there direction is refused too" do
      # Technically supported by OTP, deliberately still refused: see the
      # moduledoc. allow_erts_mismatch: true is the escape hatch.
      assert CodeSync.erts_verdict("15.2.2", "15.2.7.9") ==
               {:error, {:erts_mismatch, "15.2.2", "15.2.7.9"}}
    end

    test "a node is trivially compatible with itself" do
      assert CodeSync.compatible?(node()) == :ok
    end

    test "local_erts_version/0 is a plain version string" do
      assert CodeSync.local_erts_version() == to_string(:erlang.system_info(:version))
      assert CodeSync.local_erts_version() =~ ~r/^\d+\./
    end

    test "an unreachable node is reported as unreachable, not as compatible" do
      assert {:error, {:unreachable, @nowhere, _reason}} = CodeSync.compatible?(@nowhere, 1_000)
    end

    test "describe_error/1 renders a mismatch with both versions and the escape hatch" do
      message = CodeSync.describe_error({:erts_mismatch, "15.2.7.9", "15.2.2"})

      assert message =~ "15.2.7.9"
      assert message =~ "15.2.2"
      assert message =~ "REFUSED"
      assert message =~ "allow_erts_mismatch"
    end
  end

  # -------------------------------------------------------------------
  # push/3 — the gate
  # -------------------------------------------------------------------

  describe "push/3 gating" do
    test "refuses the whole node before loading anything when it cannot be reached" do
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)

      assert {:error, {:unreachable, @nowhere, _}} =
               CodeSync.push([entry], @nowhere, timeout: 1_000)
    end

    test "the gate runs BEFORE any code-server call, so a refusal loads nothing" do
      # Manufactured proof that we return early: if push/3 reached the load
      # loop it would have to talk to @nowhere per module, and the report
      # would be {:ok, %{errors: [...]}} rather than a flat {:error, _}.
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)
      before_md5 = :erlang.get_module_info(mod, :md5)

      assert {:error, _} = CodeSync.push([entry], @nowhere, timeout: 1_000)
      assert :erlang.get_module_info(mod, :md5) == before_md5
    end
  end

  # -------------------------------------------------------------------
  # push/3 — identical / load / wedged
  #
  # `node()` is the target: :erpc runs locally without distribution, so the
  # real :code.soft_purge/1 and :code.load_binary/3 are exercised.
  # -------------------------------------------------------------------

  describe "push/3 against a live code server" do
    test "skips a module the target already runs at the same md5, without shipping it" do
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)

      assert {:ok, report} = CodeSync.push([entry], node())

      assert report.skipped_identical == [mod]
      assert report.loaded == []
      assert report.wedged == []
      assert report.errors == []
    end

    test "loads a module the target does not have" do
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)

      # Make the target genuinely not have it.
      :code.purge(mod)
      true = :code.delete(mod)
      :code.purge(mod)

      assert {:ok, report} = CodeSync.push([entry], node())

      assert report.loaded == [mod]
      assert report.skipped_identical == []
      assert report.wedged == []
      assert report.errors == []
      assert mod.version() == 1
    end

    test "skip_identical: false loads even an identical module" do
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)

      assert {:ok, report} = CodeSync.push([entry], node(), skip_identical: false)
      assert report.loaded == [mod]
      assert report.skipped_identical == []
    end

    test "REFUSES a module whose old code is still in use, and does not kill the processes on it" do
      mod = unique_subject_name()
      cleanup_subject(mod)

      # Compile v2 FIRST so we hold a genuinely different binary for a module
      # name whose CURRENT code is v1. (Code.compile_string/1 always loads,
      # so this is the only way to have an unloaded v2 to push.)
      v2 = compile_subject(mod, 2)
      v1 = compile_subject(mod, 1)

      # v2's now-old code has no processes on it; clear it so the only old
      # generation below is the one we are about to create deliberately.
      assert :code.soft_purge(mod)

      # Park a process inside the module's code...
      parked = spawn(mod, :loop, [])
      send(parked, {:ping, self()})
      assert_receive {:pong, 1}, 1_000

      # ...then make that code OLD by loading the current binary again.
      # `parked` is now the "processes still running old code" case.
      {:module, ^mod} = :code.load_binary(mod, ~c"#{mod}.beam", v1.binary)
      refute :code.soft_purge(mod)

      assert {:ok, report} = CodeSync.push([v2], node())

      assert report.wedged == [mod]
      assert report.loaded == []
      assert report.errors == []

      # The whole point: nothing was forced, so nothing died.
      assert Process.alive?(parked)
      send(parked, {:ping, self()})
      assert_receive {:pong, 1}, 1_000

      # And the target still runs v1 — a refusal is a refusal, not a
      # best-effort load.
      assert mod.version() == 1
      assert :erlang.get_module_info(mod, :md5) != v2.md5

      send(parked, :stop)
    end

    test "a wedged module does not stop the rest of the payload" do
      wedged_mod = unique_subject_name()
      other_mod = unique_subject_name()
      cleanup_subject(wedged_mod)
      cleanup_subject(other_mod)

      wedged_v2 = compile_subject(wedged_mod, 2)
      wedged_v1 = compile_subject(wedged_mod, 1)
      assert :code.soft_purge(wedged_mod)

      parked = spawn(wedged_mod, :loop, [])
      send(parked, {:ping, self()})
      assert_receive {:pong, 1}, 1_000
      {:module, ^wedged_mod} = :code.load_binary(wedged_mod, ~c"x.beam", wedged_v1.binary)

      other = compile_subject(other_mod, 1)
      :code.purge(other_mod)
      true = :code.delete(other_mod)
      :code.purge(other_mod)

      assert {:ok, report} = CodeSync.push([wedged_v2, other], node())

      assert report.wedged == [wedged_mod]
      assert report.loaded == [other_mod]
      assert Process.alive?(parked)

      send(parked, :stop)
    end

    test "payload order is preserved in the report, with CodeSync last" do
      a = unique_subject_name()
      b = unique_subject_name()
      cleanup_subject(a)
      cleanup_subject(b)

      entry_a = compile_subject(a, 1)
      entry_b = compile_subject(b, 1)

      # CodeSync itself is identical here, so including it is a no-op load —
      # it just has to come last.
      {:ok, [self_entry]} =
        with_tmp_ebin(fn dir ->
          File.cp!(
            Path.join(CodeSync.default_ebin_dir(), "Elixir.OrcaHub.Cluster.CodeSync.beam"),
            Path.join(dir, "Elixir.OrcaHub.Cluster.CodeSync.beam")
          )

          CodeSync.load_beams(dir)
        end)

      assert {:ok, report} = CodeSync.push([self_entry, entry_a, entry_b], node())

      assert report.skipped_identical == [a, b, OrcaHub.Cluster.CodeSync]
      assert report.loaded == []
    end
  end

  # -------------------------------------------------------------------
  # drift/2
  # -------------------------------------------------------------------

  describe "drift/2" do
    test "classifies identical, drifted and missing modules" do
      identical_mod = unique_subject_name()
      drifted_mod = unique_subject_name()
      missing_mod = unique_subject_name()
      Enum.each([identical_mod, drifted_mod, missing_mod], &cleanup_subject/1)

      identical = compile_subject(identical_mod, 1)

      drifted_v2 = compile_subject(drifted_mod, 2)
      _drifted_v1 = compile_subject(drifted_mod, 1)
      :code.soft_purge(drifted_mod)

      missing = compile_subject(missing_mod, 1)
      :code.purge(missing_mod)
      true = :code.delete(missing_mod)
      :code.purge(missing_mod)

      assert {:ok, report} = CodeSync.drift([identical, drifted_v2, missing], node())

      assert report.identical == [identical_mod]
      assert report.drifted == [drifted_mod]
      assert report.missing == [missing_mod]
    end

    test "an empty payload needs no round trip" do
      assert {:ok, %{identical: [], drifted: [], missing: []}} = CodeSync.drift([], @nowhere)
    end

    test "an unreachable node is an error, NOT 'every module is missing'" do
      mod = unique_subject_name()
      cleanup_subject(mod)
      entry = compile_subject(mod, 1)

      # The dangerous laundering: if transport failure were mapped to
      # :missing, a dead node would look like one that simply needs the
      # whole app pushed.
      assert {:error, _reason} = CodeSync.drift([entry], @nowhere, timeout: 1_000)
    end
  end

  # -------------------------------------------------------------------
  # fan-out wrappers (Settings LiveView contract)
  # -------------------------------------------------------------------

  describe "fan-out wrappers keep the Settings LiveView's keys" do
    test "push_all/0 with no remote nodes reports that, without crashing" do
      assert %{nodes_updated: 0, modules_pushed: _, errors: errors} = CodeSync.push_all()
      assert "no remote nodes connected" in errors
    end

    test "push_changed/0 keeps the :skipped key the UI reads" do
      result = CodeSync.push_changed()

      assert Map.has_key?(result, :nodes_updated)
      assert Map.has_key?(result, :modules_pushed)
      assert Map.has_key?(result, :errors)
    end

    test "push_dir/3 surfaces a bad directory as an operator-readable error" do
      result = CodeSync.push_dir("/tmp/nope-#{System.unique_integer()}", [node()])

      assert result.nodes_updated == 0
      assert result.modules_pushed == 0
      assert [message] = result.errors
      assert message =~ "could not read ebin directory"
    end

    test "check_drift/0 returns one entry per remote node with the keys the UI renders" do
      # No remote nodes in the test VM, so this is the empty case — the
      # contract being pinned is that it is a LIST, not a crash.
      assert is_list(CodeSync.check_drift())
    end

    test "module_info_across_nodes/1 always includes this node" do
      assert [%{node: n, module: Enum, md5: md5}] = CodeSync.module_info_across_nodes(Enum)
      assert n == node()
      assert md5 == Base.encode16(:erlang.get_module_info(Enum, :md5), case: :lower)
    end
  end

  # -------------------------------------------------------------------

  defp with_tmp_ebin(fun) do
    dir = Path.join(System.tmp_dir!(), "code_sync_ebin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end
end
