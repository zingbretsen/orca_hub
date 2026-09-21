defmodule OrcaHub.CodeGenerationsTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.CodeGenerations
  alias OrcaHub.CodeGenerations.{CodeGeneration, CodeGenerationModule}

  # Synthetic modules, never real OrcaHub ones: these tests store and read
  # back beam binaries, and a fixture built from a real module would make a
  # mistake in the storage layer indistinguishable from a mistake that ships
  # actual code somewhere.
  # The name gets a unique suffix so re-running a setup block compiles a
  # genuinely new module rather than redefining one already in the VM.
  defp entry(name, body) do
    unique = "#{name}.U#{System.unique_integer([:positive])}"
    [{mod, binary}] = Code.compile_string("defmodule #{unique} do #{body} end")
    {:ok, {^mod, md5}} = :beam_lib.md5(binary)
    %{module: mod, binary: binary, md5: md5, path: ~c"fixture.beam"}
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        base_sha: "abc1234",
        erts_version: List.to_string(:erlang.system_info(:version)),
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        elixir_version: System.version(),
        published_by: "test",
        published_from_node: to_string(node())
      },
      overrides
    )
  end

  defp publish!(entries, overrides \\ %{}) do
    {:ok, generation} = CodeGenerations.publish(attrs(overrides), entries)
    generation
  end

  describe "publish/2" do
    test "stores the generation with derived module count and total bytes" do
      entries = [
        entry("CGTest.Publish.A", "def v, do: 1"),
        entry("CGTest.Publish.B", "def v, do: 2")
      ]

      generation = publish!(entries)

      assert generation.module_count == 2
      assert generation.total_bytes == Enum.reduce(entries, 0, &(byte_size(&1.binary) + &2))
      assert generation.status == "pending"
      assert generation.apply_attempts == 0
      refute generation.dirty
    end

    test "stores every module's beam and its COMPILE-TIME md5, not a hash of the file bytes" do
      e = entry("CGTest.Md5.A", "def v, do: 1")
      generation = publish!([e])

      [row] =
        Repo.all(from(m in CodeGenerationModule, where: m.code_generation_id == ^generation.id))

      assert row.module == to_string(e.module)
      assert row.beam == e.binary
      assert row.beam_bytes == byte_size(e.binary)

      # The distinction the whole differential reconcile rests on: the stored
      # md5 is what a remote node reports for loaded code, and is NOT
      # :erlang.md5/1 over the beam file.
      assert row.md5 == :erlang.get_module_info(e.module, :md5)
      refute row.md5 == :erlang.md5(e.binary)
    end

    test "records dirty and the overridden gate reasons verbatim" do
      reasons = [
        %{
          "category" => "defstruct_change",
          "path" => "lib/orca_hub/foo.ex",
          "status" => "modified",
          "message" => "struct shape changed",
          "evidence" => ["+  defstruct [:a, :b]"]
        }
      ]

      generation =
        publish!([entry("CGTest.Dirty.A", "def v, do: 1")], %{
          dirty: true,
          forced_reasons: reasons
        })

      assert generation.dirty
      assert generation.forced_reasons == reasons
    end

    test "chunks large payloads through insert_all without losing any module" do
      entries = for i <- 1..60, do: entry("CGTest.Chunk.M#{i}", "def v, do: #{i}")
      generation = publish!(entries)

      assert generation.module_count == 60
      assert map_size(CodeGenerations.manifest(generation.id)) == 60
    end
  end

  describe "current/0" do
    test "is nil when nothing is published" do
      # The dev DB is shared, so scope the assertion rather than asserting a
      # globally empty table.
      Repo.delete_all(CodeGeneration)
      assert CodeGenerations.current() == nil
    end

    test "returns the newest generation that is neither superseded nor quarantined" do
      Repo.delete_all(CodeGeneration)

      old = publish!([entry("CGTest.Current.A", "def v, do: 1")])
      backdate(old, -60)
      new = publish!([entry("CGTest.Current.B", "def v, do: 2")])

      assert CodeGenerations.current().id == new.id

      {:ok, _} = CodeGenerations.supersede(new, "deploy landed")
      assert CodeGenerations.current().id == old.id

      {:ok, _} = CodeGenerations.quarantine(old, "crashed the hub")
      assert CodeGenerations.current() == nil

      # latest/0 still sees them — it reports, it does not filter.
      assert CodeGenerations.latest().id == new.id
    end
  end

  describe "manifest/1 and fetch_beams/2" do
    setup do
      Repo.delete_all(CodeGeneration)
      a = entry("CGTest.Fetch.A", "def v, do: 1")
      b = entry("CGTest.Fetch.B", "def v, do: 2")
      %{generation: publish!([a, b]), a: a, b: b}
    end

    test "manifest is module name to md5, carrying no beam binaries", %{generation: g, a: a, b: b} do
      manifest = CodeGenerations.manifest(g.id)

      assert manifest == %{to_string(a.module) => a.md5, to_string(b.module) => b.md5}
    end

    test "fetch_beams returns push-shaped entries for a named subset", %{generation: g, a: a} do
      assert [fetched] = CodeGenerations.fetch_beams(g.id, [a.module])

      assert fetched.module == a.module
      assert fetched.binary == a.binary
      assert fetched.md5 == a.md5
      # The path is synthesised: the origin machine's _build path means
      # nothing on the node being reconciled.
      assert is_list(fetched.path)
    end

    test "fetch_beams(:all) returns every module", %{generation: g} do
      assert length(CodeGenerations.fetch_beams(g.id, :all)) == 2
    end

    test "fetch_beams for an unknown module name returns nothing rather than raising", %{
      generation: g
    } do
      assert CodeGenerations.fetch_beams(g.id, [:"CGTest.Fetch.Nope"]) == []
    end
  end

  describe "circuit-breaker bookkeeping" do
    setup do
      Repo.delete_all(CodeGeneration)
      %{generation: publish!([entry("CGTest.Breaker.A", "def v, do: 1")])}
    end

    test "record_apply_attempt increments durably and returns the updated row", %{generation: g} do
      assert CodeGenerations.record_apply_attempt(g).apply_attempts == 1
      # Re-read from the DB: the counter has to survive the process that
      # incremented it dying, which is the whole reason it is written first.
      assert CodeGenerations.get(g.id).apply_attempts == 1

      assert CodeGenerations.record_apply_attempt(g).apply_attempts == 2
      assert CodeGenerations.get(g.id).apply_attempts == 2
    end

    test "mark_healthy flips status and RESETS the apply budget", %{generation: g} do
      CodeGenerations.record_apply_attempt(g)

      assert {:ok, healthy} = CodeGenerations.mark_healthy(g.id)
      assert healthy.status == "healthy"
      assert healthy.apply_attempts == 0
      assert healthy.proven_healthy_at
    end

    test "mark_healthy refuses a generation that is no longer pending", %{generation: g} do
      {:ok, _} = CodeGenerations.quarantine(g, "bad")
      assert {:error, :not_pending} = CodeGenerations.mark_healthy(g.id)
      assert CodeGenerations.get(g.id).status == "quarantined"
    end

    test "quarantine and supersede are distinct terminal states", %{generation: g} do
      {:ok, quarantined} = CodeGenerations.quarantine(g, "crashed on boot")
      assert quarantined.status == "quarantined"
      assert quarantined.notes == "crashed on boot"
      assert quarantined.superseded_at == nil

      other = publish!([entry("CGTest.Breaker.B", "def v, do: 1")])
      {:ok, superseded} = CodeGenerations.supersede(other, "image deploy")
      assert superseded.status == "superseded"
      assert superseded.superseded_at

      assert CodeGeneration.terminal?("quarantined")
      assert CodeGeneration.terminal?("superseded")
      refute CodeGeneration.terminal?("pending")
      refute CodeGeneration.terminal?("healthy")
    end
  end

  describe "prune/1" do
    test "keeps the newest N and never deletes the current generation" do
      Repo.delete_all(CodeGeneration)

      generations =
        for i <- 1..6 do
          g = publish!([entry("CGTest.Prune.M#{i}", "def v, do: #{i}")])
          backdate(g, -100 + i)
          g
        end

      current = CodeGenerations.current()

      assert CodeGenerations.prune(3) == 3

      surviving = Enum.map(CodeGenerations.list(), & &1.id)
      assert length(surviving) == 3
      assert current.id in surviving

      # Module rows cascade with their generation.
      deleted_id = generations |> List.first() |> Map.fetch!(:id)
      assert CodeGenerations.manifest(deleted_id) == %{}
    end
  end

  test "summarize/1 omits the beam binaries so it is safe to log or return" do
    Repo.delete_all(CodeGeneration)
    generation = publish!([entry("CGTest.Summary.A", "def v, do: 1")])

    summary = CodeGenerations.summarize(generation)

    assert summary.base_sha == "abc1234"
    assert summary.module_count == 1
    refute Map.has_key?(summary, :modules)
    refute summary |> inspect() |> String.contains?("FOR1")

    assert CodeGenerations.summarize(nil) == nil
  end

  # Generation ordering is by inserted_at, and several tests need two
  # generations in a known order without sleeping through a real clock tick.
  defp backdate(generation, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)

    Repo.update_all(from(g in CodeGeneration, where: g.id == ^generation.id),
      set: [inserted_at: at]
    )

    at
  end
end
