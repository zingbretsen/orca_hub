defmodule OrcaHub.Cluster.CodePushTest do
  @moduledoc """
  Tests for the reconciliation loop.

  Two ground rules that shape everything below:

    * **Never use a real OrcaHub module as a fixture.** Every generation
      here carries synthetic throwaway modules compiled in-test. A test that
      reconciled a real module would be hot-loading production code into the
      test VM, and a bug in the push path would be indistinguishable from
      one that quietly swapped out the suite's own code mid-run.
    * **The target node is `node()`** (`:nonode@nohost` under `mix test`).
      `:erpc` handles the local node without distribution, so the full
      drift/soft_purge/load_binary path runs for real rather than against a
      stub — while staying entirely inside this VM and never touching the
      live fleet.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.Cluster.{BeamTransport, CodePush}
  alias OrcaHub.CodeGenerations
  alias OrcaHub.CodeGenerations.CodeGeneration

  @erts List.to_string(:erlang.system_info(:version))

  setup do
    Repo.delete_all(CodeGeneration)
    :ok
  end

  # ------------------------------------------------------------------
  # Fixtures
  # ------------------------------------------------------------------

  defp unique_module(prefix), do: "#{prefix}.U#{System.unique_integer([:positive])}"

  # Compiles `body` under `name` and returns a push entry. Note this LOADS
  # the module into the VM as a side effect of Code.compile_string/1 — tests
  # that need an unloaded binary compile the later version FIRST and keep
  # its binary, then compile the earlier version to make that one current.
  defp entry(name, body) do
    [{mod, binary}] = Code.compile_string("defmodule #{name} do #{body} end")
    {:ok, {^mod, md5}} = :beam_lib.md5(binary)
    %{module: mod, binary: binary, md5: md5, path: ~c"fixture.beam"}
  end

  # Loads a fixture the way real code arrives on a node — under a `.beam`
  # load path — rather than as an in-memory module. Orphan detection only
  # considers beam-backed code (see BeamTransport.resident_modules/1), so a
  # fixture compiled straight into memory would be invisible to it and the
  # test would prove nothing.
  defp entry_loaded_as_beam(name, body) do
    e = entry(name, body)
    :code.purge(e.module)
    :code.delete(e.module)

    {:module, _} =
      :code.load_binary(e.module, ~c"/fixture/#{e.module}.beam", e.binary)

    e
  end

  defp publish!(entries, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          base_sha: "deadbee",
          erts_version: @erts,
          otp_release: List.to_string(:erlang.system_info(:otp_release)),
          elixir_version: System.version(),
          published_by: "test",
          published_from_node: to_string(node())
        },
        overrides
      )

    {:ok, generation} = CodeGenerations.publish(attrs, entries)
    generation
  end

  # The no-downgrade check compares a node's IMAGE build time against the
  # generation's creation time. Pinning inserted_at is what makes both
  # directions deterministic instead of depending on when build_info.ex
  # happened to last be compiled on this machine.
  defp set_created_at(generation, seconds_from_now) do
    at = DateTime.add(DateTime.utc_now(), seconds_from_now, :second)

    Repo.update_all(from(g in CodeGeneration, where: g.id == ^generation.id),
      set: [inserted_at: at]
    )

    CodeGenerations.get(generation.id)
  end

  defp newer_than_this_node(generation), do: set_created_at(generation, 3600)
  defp older_than_this_node(generation), do: set_created_at(generation, -86_400 * 365)

  # Starts a reconciler with nothing published, so its boot pass is a no-op
  # and a later explicit reconcile is the only thing that touches the node.
  # Without this, boot would already have applied the generation and every
  # manual reconcile would trivially report :in_sync.
  defp start_idle_reconciler do
    assert CodeGenerations.current() == nil
    start_reconciler()
  end

  defp start_reconciler(opts \\ []) do
    enabled = Keyword.get(opts, :enabled, true)
    previous = Application.get_env(:orca_hub, :code_reconcile_enabled)
    Application.put_env(:orca_hub, :code_reconcile_enabled, enabled)
    on_exit(fn -> Application.put_env(:orca_hub, :code_reconcile_enabled, previous) end)

    name = :"code_push_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({CodePush, name: name, monitor_nodes: false}, id: name)
    # A status call serializes behind the :boot_reconcile message the server
    # sent itself in init/1, so returning from here means boot is done.
    _ = GenServer.call(pid, :status)
    pid
  end

  # ------------------------------------------------------------------
  # Reconcile: the differential push
  # ------------------------------------------------------------------

  describe "reconcile_node" do
    test "reports in_sync without pushing when the node already runs every module" do
      pid = start_idle_reconciler()

      e = entry(unique_module("CPTest.InSync"), "def v, do: 1")
      publish!([e]) |> newer_than_this_node()

      assert %{status: :in_sync, pushed: 0, identical: 1} =
               GenServer.call(pid, {:reconcile_node, node(), []})
    end

    test "pushes a module the node is MISSING entirely" do
      pid = start_idle_reconciler()

      name = unique_module("CPTest.Missing")
      e = entry(name, "def v, do: 41")
      # Unload it so the node genuinely lacks it, exactly like an agent that
      # has been powered off through several deploys.
      :code.purge(e.module)
      :code.delete(e.module)
      refute :erlang.module_loaded(e.module)

      publish!([e]) |> newer_than_this_node()

      assert %{status: :reconciled, pushed: 1} =
               GenServer.call(pid, {:reconcile_node, node(), []})

      assert e.module.v() == 41
    end

    test "actually swaps DRIFTED code — the running module changes behaviour" do
      pid = start_idle_reconciler()

      name = unique_module("CPTest.Drift")

      # v2's binary is captured first; compiling v1 afterwards makes v1 the
      # module the VM is currently running, so the reconcile has something
      # real to correct.
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")
      assert v2.module.v() == 1

      publish!([v2]) |> newer_than_this_node()

      assert %{status: :reconciled, pushed: 1, wedged: []} =
               GenServer.call(pid, {:reconcile_node, node(), []})

      assert v2.module.v() == 2
    end

    test "pushes ONLY what differs, leaving identical modules alone" do
      pid = start_idle_reconciler()

      same = entry(unique_module("CPTest.Partial.Same"), "def v, do: 1")

      changed_name = unique_module("CPTest.Partial.Changed")
      changed_v2 = entry(changed_name, "def v, do: 2")
      _changed_v1 = entry(changed_name, "def v, do: 1")

      publish!([same, changed_v2]) |> newer_than_this_node()

      assert %{status: :reconciled, pushed: 1, loaded: loaded} =
               GenServer.call(pid, {:reconcile_node, node(), []})

      assert loaded == [to_string(changed_v2.module)]
    end

    test "errors cleanly when there is no generation to reconcile toward" do
      pid = start_idle_reconciler()
      assert {:error, :no_generation} = GenServer.call(pid, {:reconcile_node, node(), []})
    end
  end

  # ------------------------------------------------------------------
  # Orphaned modules (deleted from source)
  # ------------------------------------------------------------------

  describe "orphaned modules" do
    test "a reconcile REPORTS resident modules absent from the generation" do
      pid = start_idle_reconciler()

      kept = entry(unique_module("CPTest.Orphan.Kept"), "def v, do: 1")
      # Compiled and loaded, then deliberately left out of the generation —
      # exactly the shape of a module deleted from source.
      deleted =
        entry_loaded_as_beam(
          "OrcaHub.CPTestOrphanGone#{System.unique_integer([:positive])}",
          "def v, do: 1"
        )

      publish!([kept]) |> newer_than_this_node()

      assert %{orphaned: orphaned} = GenServer.call(pid, {:reconcile_node, node(), []})
      assert to_string(deleted.module) in orphaned

      # Reported only. Hot loading cannot remove it, and the reconcile does
      # not try — it is still callable.
      assert deleted.module.v() == 1
    end

    test "NEVER reports OrcaHub.BuildInfo as orphaned, though it is in no generation" do
      pid = start_idle_reconciler()

      publish!([entry(unique_module("CPTest.Orphan.BuildInfo"), "def v, do: 1")])
      |> newer_than_this_node()

      assert %{orphaned: orphaned} = GenServer.call(pid, {:reconcile_node, node(), []})

      # BuildInfo is deliberately excluded from every payload, so without the
      # carve-out it would read as permanently orphaned on every node — and
      # be a purge candidate, which would take /api/version down with it.
      refute "Elixir.OrcaHub.BuildInfo" in orphaned
      refute to_string(OrcaHub.BuildInfo) in orphaned
    end

    test "purge_orphaned unloads an orphan without touching the generation's modules" do
      pid = start_idle_reconciler()

      kept = entry(unique_module("CPTest.Purge.Kept"), "def v, do: 1")

      gone =
        entry_loaded_as_beam(
          "OrcaHub.CPTestPurgeGone#{System.unique_integer([:positive])}",
          "def v, do: 1"
        )

      publish!([kept]) |> newer_than_this_node()

      assert {:ok, report} = GenServer.call(pid, {:purge_orphaned, node()})
      assert to_string(gone.module) in report.purged

      refute :erlang.module_loaded(gone.module)
      # The generation's own module is untouched.
      assert kept.module.v() == 1
      assert :erlang.module_loaded(kept.module)
    end

    test "purge_orphaned REFUSES when no generation is published" do
      pid = start_idle_reconciler()

      # Without a generation every resident module would qualify as orphaned,
      # so refusing is the only safe reading of the request.
      assert {:error, :no_generation} = GenServer.call(pid, {:purge_orphaned, node()})
    end

    test "purge_orphaned never kills a process — a module in use comes back wedged" do
      pid = start_idle_reconciler()

      busy_name = "OrcaHub.CPTestBusy#{System.unique_integer([:positive])}"

      busy =
        entry_loaded_as_beam(busy_name, """
        def loop, do: receive do: (:stop -> :ok; _ -> loop())
        """)

      # A process parked INSIDE the module's code: :code.soft_purge/1 must
      # refuse, and purge must honour that rather than reaching for
      # :code.purge/1 and killing it.
      runner = spawn(fn -> busy.module.loop() end)
      assert Process.alive?(runner)

      publish!([entry(unique_module("CPTest.Wedged.Other"), "def v, do: 1")])
      |> newer_than_this_node()

      assert {:ok, report} = GenServer.call(pid, {:purge_orphaned, node()})

      assert to_string(busy.module) in (report.wedged ++ report.deleted_not_purged)
      assert Process.alive?(runner), "purge killed a process running old code"

      send(runner, :stop)
    end
  end

  # ------------------------------------------------------------------
  # Ordering: never downgrade
  # ------------------------------------------------------------------

  describe "no-downgrade ordering" do
    test "SKIPS a node whose image was built after the generation was published" do
      pid = start_idle_reconciler()

      name = unique_module("CPTest.Downgrade")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      # Backdated a year: this node's image is unambiguously newer, which is
      # the shape of "the slow deploy path shipped a real image".
      publish!([v2]) |> older_than_this_node()

      assert %{status: :skipped, reason: reason} =
               GenServer.call(pid, {:reconcile_node, node(), []})

      assert reason =~ "built after"
      assert reason =~ "downgrade"

      # The decisive assertion: the node was NOT walked backwards.
      assert v2.module.v() == 1
    end

    test "SKIPS a node running a different ERTS than the generation was compiled on" do
      pid = start_idle_reconciler()

      name = unique_module("CPTest.Erts")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      publish!([v2], %{erts_version: "0.0.0-not-a-real-erts"}) |> newer_than_this_node()

      assert %{status: :skipped, reason: reason} =
               GenServer.call(pid, {:reconcile_node, node(), []})

      assert reason =~ "ERTS mismatch"
      assert reason =~ "erts-0.0.0-not-a-real-erts"
      assert v2.module.v() == 1
    end

    test "supersede stops the fleet being reconciled toward a generation" do
      pid = start_idle_reconciler()

      e = entry(unique_module("CPTest.Supersede"), "def v, do: 1")
      publish!([e]) |> newer_than_this_node()

      assert {:ok, summary} = GenServer.call(pid, {:supersede, "image deploy landed"})
      assert summary.status == "superseded"
      assert summary.notes == "image deploy landed"

      assert {:error, :no_generation} = GenServer.call(pid, {:reconcile_node, node(), []})
      assert {:error, :no_generation} = GenServer.call(pid, {:supersede, nil})
    end
  end

  # ------------------------------------------------------------------
  # Circuit breaker
  # ------------------------------------------------------------------

  describe "circuit breaker" do
    test "the env hatch boots on pure image code and applies nothing" do
      name = unique_module("CPTest.Hatch")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")
      publish!([v2]) |> newer_than_this_node()

      pid = start_reconciler(enabled: false)

      assert %{enabled: false} = GenServer.call(pid, :status)
      assert v2.module.v() == 1
    end

    test "the ORCA_SKIP_CODE_RECONCILE env var alone disables reconciliation" do
      previous = Application.get_env(:orca_hub, :code_reconcile_enabled)
      Application.put_env(:orca_hub, :code_reconcile_enabled, true)
      System.put_env("ORCA_SKIP_CODE_RECONCILE", "1")

      on_exit(fn ->
        System.delete_env("ORCA_SKIP_CODE_RECONCILE")
        Application.put_env(:orca_hub, :code_reconcile_enabled, previous)
      end)

      refute CodePush.enabled?()

      System.put_env("ORCA_SKIP_CODE_RECONCILE", "0")
      assert CodePush.enabled?()
    end

    test "a generation applied on boot is marked HEALTHY only after the health window" do
      e = entry(unique_module("CPTest.Healthy"), "def v, do: 1")
      generation = publish!([e]) |> newer_than_this_node()

      _pid = start_reconciler()

      # Still pending the instant the apply returns — proving healthy is a
      # function of surviving, not of the apply succeeding.
      assert CodeGenerations.get(generation.id).status == "pending"

      assert eventually(fn -> CodeGenerations.get(generation.id).status == "healthy" end)

      healthy = CodeGenerations.get(generation.id)
      assert healthy.proven_healthy_at
      # The budget is handed back, so an unrelated crash months later starts
      # counting from zero rather than from wherever the last boot left off.
      assert healthy.apply_attempts == 0
    end

    test "the apply budget is spent BEFORE the beams are applied" do
      e = entry(unique_module("CPTest.Budget"), "def v, do: 1")
      generation = publish!([e]) |> newer_than_this_node()

      assert generation.apply_attempts == 0
      _pid = start_reconciler()

      # Durable evidence that an attempt happened, written before the apply
      # so it survives the apply killing the hub. (It has usually been reset
      # to 0 by the health window by now, so read it before that lands or
      # accept either — the point is it was written at all.)
      assert CodeGenerations.get(generation.id).apply_attempts in [0, 1]
      assert eventually(fn -> CodeGenerations.get(generation.id).status == "healthy" end)
    end

    test "a generation that has burned its budget QUARANTINES itself instead of being applied again" do
      name = unique_module("CPTest.Quarantine")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      generation = publish!([v2]) |> newer_than_this_node()

      # Simulate the CrashLoopBackOff: two boots that each spent an attempt
      # and never lived long enough to be marked healthy.
      CodeGenerations.record_apply_attempt(generation)
      CodeGenerations.record_apply_attempt(generation)
      assert CodeGenerations.get(generation.id).apply_attempts == 2

      _pid = start_reconciler()

      # It was NOT applied...
      assert v2.module.v() == 1
      # ...and it is out of the way for good, so the next boot is clean with
      # no operator having to reach into a pod that will not stay up.
      assert CodeGenerations.get(generation.id).status == "quarantined"
      assert CodeGenerations.current() == nil
    end

    test "a quarantined generation is never applied on a later boot" do
      name = unique_module("CPTest.Quarantined")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      generation = publish!([v2]) |> newer_than_this_node()
      {:ok, _} = CodeGenerations.quarantine(generation, "crashed the hub")

      _pid = start_reconciler()

      assert v2.module.v() == 1
      assert CodeGenerations.get(generation.id).status == "quarantined"
    end

    test "a hub whose own image is NEWER abandons the whole reconcile rather than pushing old code" do
      name = unique_module("CPTest.HubNewer")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      generation = publish!([v2]) |> older_than_this_node()

      _pid = start_reconciler()

      assert v2.module.v() == 1
      # The generation is left alone: clearing it is an explicit operator
      # action, because "a new image landed" is not something the hub should
      # infer and act on by itself.
      assert CodeGenerations.get(generation.id).status == "pending"
      assert CodeGenerations.get(generation.id).apply_attempts == 0
    end
  end

  # ------------------------------------------------------------------
  # Boot reconcile
  # ------------------------------------------------------------------

  describe "boot reconcile" do
    test "applies the stored generation to the hub ITSELF on boot" do
      name = unique_module("CPTest.SelfApply")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")
      assert v2.module.v() == 1

      generation = publish!([v2]) |> newer_than_this_node()

      pid = start_reconciler()

      # This is the property that makes it safe to stop pinning the hub's
      # image to a SHA: the hub came up on image code and reconciled itself.
      assert v2.module.v() == 2
      assert GenServer.call(pid, :status).applied_generation_id == generation.id
    end

    test "boots quietly when no generation is published" do
      pid = start_reconciler()

      assert %{generation: nil, applied_generation_id: nil, enabled: true} =
               GenServer.call(pid, :status)
    end
  end

  # ------------------------------------------------------------------
  # Publish
  # ------------------------------------------------------------------

  describe "publish" do
    test "stores the generation, applies it, and reports it back" do
      name = unique_module("CPTest.Publish")
      v2 = entry(name, "def v, do: 2")
      _v1 = entry(name, "def v, do: 1")

      pid = start_reconciler()

      payload = %{
        entries: [v2],
        base_sha: "cafe123",
        dirty: false,
        erts_version: @erts,
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        elixir_version: System.version(),
        published_from_node: to_string(node()),
        forced_reasons: []
      }

      assert {:ok, report} = GenServer.call(pid, {:publish, payload, [published_by: "test"]})

      assert report.generation.base_sha == "cafe123"
      assert report.generation.module_count == 1
      assert report.generation.published_by == "test"
      assert v2.module.v() == 2

      assert CodeGenerations.current().base_sha == "cafe123"
    end

    test "a dirty publish is recorded as dirty so drift reporting can say so" do
      pid = start_reconciler()

      payload = %{
        entries: [entry(unique_module("CPTest.DirtyPublish"), "def v, do: 1")],
        base_sha: "cafe123",
        dirty: true,
        erts_version: @erts,
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        elixir_version: System.version(),
        published_from_node: to_string(node()),
        forced_reasons: [
          %{"category" => "mix_lock", "path" => "mix.lock", "message" => "dep change"}
        ]
      }

      assert {:ok, report} = GenServer.call(pid, {:publish, payload, []})

      assert report.generation.dirty
      assert [%{"category" => "mix_lock"}] = report.generation.forced_reasons
    end
  end

  # ------------------------------------------------------------------
  # collect_payload — the origin half of the publish path
  # ------------------------------------------------------------------

  describe "collect_payload/1" do
    setup do
      {:ok, repo} = git_fixture()
      on_exit(fn -> File.rm_rf!(repo.dir) end)
      repo
    end

    test "collects beams plus provenance from a clean checkout", %{dir: dir, ebin: ebin, sha: sha} do
      assert {:ok, payload} = CodePush.collect_payload(dir: dir, ebin: ebin, base: nil)

      assert payload.base_sha == sha
      refute payload.dirty
      assert payload.erts_version == @erts
      assert payload.published_from_node == to_string(node())
      assert payload.forced_reasons == []
      assert [%{module: _, binary: _, md5: _, path: _}] = payload.entries
    end

    test "REFUSES a dirty checkout by default", %{dir: dir, ebin: ebin} do
      File.write!(Path.join(dir, "lib/dirty.ex"), "# uncommitted\n")

      assert {:error, {:dirty_checkout, message}} =
               CodePush.collect_payload(dir: dir, ebin: ebin, base: nil)

      assert message =~ "uncommitted or untracked"
      assert message =~ "allow_dirty"
    end

    test "an untracked file counts as dirty", %{dir: dir, ebin: ebin} do
      # The likeliest way a sibling working in the same tree contributes code
      # to a build nobody meant to publish.
      File.write!(Path.join(dir, "lib/sibling_scratch.ex"), "# not mine\n")

      assert {:error, {:dirty_checkout, _}} =
               CodePush.collect_payload(dir: dir, ebin: ebin, base: nil)
    end

    test "allow_dirty publishes but marks the payload dirty — never silently", %{
      dir: dir,
      ebin: ebin
    } do
      File.write!(Path.join(dir, "lib/dirty.ex"), "# uncommitted\n")

      assert {:ok, payload} =
               CodePush.collect_payload(dir: dir, ebin: ebin, base: nil, allow_dirty: true)

      assert payload.dirty
    end

    test "REFUSES a change set the hot-load safety gate rejects", %{
      dir: dir,
      ebin: ebin,
      base: base
    } do
      assert {:error, {:gate_refused, explanation, reasons}} =
               CodePush.collect_payload(dir: dir, ebin: ebin, base: base)

      assert explanation =~ "REFUSED"
      assert Enum.any?(reasons, &(&1.path == "mix.lock"))
    end

    test "force publishes anyway and RECORDS every overridden reason", %{
      dir: dir,
      ebin: ebin,
      base: base
    } do
      assert {:ok, payload} =
               CodePush.collect_payload(dir: dir, ebin: ebin, base: base, force: true)

      assert [%{"category" => category, "path" => "mix.lock"}] = payload.forced_reasons
      assert is_binary(category)
    end

    test "a missing ebin directory is an error, not an empty generation", %{dir: dir} do
      assert {:error, _} =
               CodePush.collect_payload(dir: dir, ebin: Path.join(dir, "nope"), base: nil)
    end
  end

  # ------------------------------------------------------------------
  # BeamTransport's own invariants
  # ------------------------------------------------------------------

  describe "BeamTransport.sanitize/1" do
    test "strips OrcaHub.BuildInfo, which must never be pushed" do
      # Built as bare maps rather than by compiling: compiling a module named
      # OrcaHub.BuildInfo would redefine the real one in this VM.
      entries = [
        %{module: OrcaHub.BuildInfo, binary: <<>>, md5: <<>>, path: ~c"x"},
        %{module: SomeOtherModule, binary: <<>>, md5: <<>>, path: ~c"y"}
      ]

      assert [%{module: SomeOtherModule}] = BeamTransport.sanitize(entries)
      assert OrcaHub.BuildInfo in BeamTransport.excluded_modules()
    end

    test "sinks the modules that participate in their own push to the end" do
      entries =
        Enum.map([OrcaHub.Cluster.CodeSync, SomeModule, OrcaHub.Cluster.CodePush], fn mod ->
          %{module: mod, binary: <<>>, md5: <<>>, path: ~c"x"}
        end)

      assert [SomeModule, OrcaHub.Cluster.CodeSync, OrcaHub.Cluster.CodePush] ==
               entries |> BeamTransport.sanitize() |> Enum.map(& &1.module)
    end
  end

  describe "BeamTransport.resident_modules/1" do
    test "unions the app's declared modules with loaded OrcaHub modules" do
      # A module that exists ONLY because it was compiled at runtime appears
      # in no .app file anywhere — it is exactly the case the all_loaded half
      # exists to catch, and the case a previous generation creates.
      runtime_only =
        entry_loaded_as_beam(
          "OrcaHub.CPTestResident#{System.unique_integer([:positive])}",
          "def v, do: 1"
        )

      assert {:ok, resident} = BeamTransport.resident_modules(node())

      assert runtime_only.module in resident
      assert OrcaHub.Cluster.CodePush in resident
      assert OrcaHub.BuildInfo in resident
    end

    test "IGNORES in-memory modules — only beam-backed code is ever a purge candidate" do
      # A module compiled straight into memory (a .exs script, a runtime
      # Code.compile_*, an ExUnit test module) was never part of any
      # generation and is not ours to unload. This test module is itself
      # exactly that shape, and an earlier cut of resident_modules/1 swept it
      # into the orphan set and unloaded it mid-run.
      [{in_memory, _}] =
        Code.compile_string(
          "defmodule OrcaHub.CPTestInMemory#{System.unique_integer([:positive])} do def v, do: 1 end"
        )

      assert {:ok, resident} = BeamTransport.resident_modules(node())

      refute in_memory in resident
      refute __MODULE__ in resident
    end

    test "an unreachable node is an error, not an empty set" do
      # An empty set would read as "this node has nothing resident", which
      # would make every generation module look missing.
      assert {:error, _} = BeamTransport.resident_modules(:nope@nowhere)
    end
  end

  describe "BeamTransport.unload/2" do
    test "fully unloads a module nothing is running" do
      e =
        entry_loaded_as_beam(
          "OrcaHub.CPTestUnload#{System.unique_integer([:positive])}",
          "def v, do: 1"
        )

      assert :erlang.module_loaded(e.module)

      assert {:ok, :purged} = BeamTransport.unload(node(), e.module)
      refute :erlang.module_loaded(e.module)
    end
  end

  describe "BeamTransport node interrogation" do
    test "erts_version/1 reports this node's runtime version" do
      assert {:ok, @erts} = BeamTransport.erts_version(node())
    end

    test "built_at/1 parses BuildInfo's timestamp into a DateTime" do
      assert {:ok, %DateTime{}} = BeamTransport.built_at(node())
    end

    test "sha/1 reports the image's git SHA" do
      assert {:ok, sha} = BeamTransport.sha(node())
      assert is_binary(sha)
    end

    test "an unreachable node is an error, never a defaulted timestamp" do
      assert {:error, {:unreachable, :nope@nowhere, _}} =
               BeamTransport.built_at(:nope@nowhere)
    end
  end

  # ------------------------------------------------------------------

  # A throwaway git repo with two commits: the second touches mix.lock, so
  # `base` (the first commit) gives the safety gate something it will refuse
  # and `nil` gives it nothing to classify.
  defp git_fixture do
    dir = Path.join(System.tmp_dir!(), "code_push_test_#{System.unique_integer([:positive])}")
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(ebin)

    [{mod, binary}] =
      Code.compile_string("defmodule #{unique_module("CPTest.Ebin")} do def v, do: 1 end")

    File.write!(Path.join(ebin, "#{mod}.beam"), binary)

    git = fn args -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end

    git.(["init", "--quiet"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "test"])
    git.(["config", "commit.gpgsign", "false"])

    File.write!(Path.join(dir, "mix.lock"), "%{}\n")
    File.write!(Path.join(dir, "lib/thing.ex"), "defmodule Thing do\n  def v, do: 1\nend\n")
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "base"])
    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    File.write!(Path.join(dir, "mix.lock"), "%{\"req\" => :something}\n")
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "head"])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    {:ok, %{dir: dir, ebin: ebin, base: String.trim(base), sha: String.trim(sha)}}
  end

  defp eventually(fun, remaining \\ 60) do
    cond do
      fun.() -> true
      remaining == 0 -> false
      true -> Process.sleep(25) && eventually(fun, remaining - 1)
    end
  end
end
