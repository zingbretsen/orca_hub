defmodule OrcaHub.Cluster.CodeStampTest do
  @moduledoc """
  The per-node "what code am I actually running" stamp.

  Everything here targets `node()` (`:nonode@nohost` under `mix test`);
  `:erpc` handles the local node without distribution, so the real
  read/write path runs rather than a stub.
  """

  use ExUnit.Case, async: false

  alias OrcaHub.Cluster.CodeStamp

  setup do
    CodeStamp.clear()
    on_exit(&CodeStamp.clear/0)
    :ok
  end

  defp iso(binary) do
    {:ok, dt, _} = DateTime.from_iso8601(binary)
    dt
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        generation_id: "gen-1",
        base_sha: "abc123def456",
        dirty: false,
        module_count: 277,
        modules_loaded: 12,
        apply_status: "reconciled"
      },
      overrides
    )
  end

  describe "record/2 and read/1" do
    test "an unstamped node answers nil, not an error and not a build sha" do
      assert {:ok, nil} = CodeStamp.read(node())
      assert CodeStamp.local() == nil
    end

    test "records the generation's identity and both timestamps" do
      assert {:ok, stamp} = CodeStamp.record(node(), attrs())

      assert stamp.generation_id == "gen-1"
      assert stamp.base_sha == "abc123def456"
      assert stamp.dirty == false
      assert stamp.module_count == 277
      assert stamp.modules_loaded == 12
      assert stamp.apply_status == "reconciled"
      assert stamp.reconciled_from == to_string(node())
      assert {:ok, _, _} = DateTime.from_iso8601(stamp.applied_at)
      assert {:ok, _, _} = DateTime.from_iso8601(stamp.verified_at)

      assert {:ok, ^stamp} = CodeStamp.read(node())
      assert CodeStamp.local() == stamp
    end

    test "a zero-push re-verification of the SAME generation keeps applied_at" do
      {:ok, first} = CodeStamp.record(node(), attrs())

      {:ok, second} =
        CodeStamp.record(node(), attrs(%{modules_loaded: 0, apply_status: "in_sync"}))

      assert second.applied_at == first.applied_at
      assert DateTime.compare(iso(second.verified_at), iso(first.verified_at)) in [:gt, :eq]
      assert second.apply_status == "in_sync"
    end

    test "a DIFFERENT generation moves applied_at even when nothing was pushed" do
      {:ok, first} = CodeStamp.record(node(), attrs())

      {:ok, second} =
        CodeStamp.record(
          node(),
          attrs(%{generation_id: "gen-2", base_sha: "999", modules_loaded: 0})
        )

      assert second.base_sha == "999"
      assert second.applied_at != first.applied_at
    end

    test "loading modules again under the same generation moves applied_at" do
      {:ok, first} = CodeStamp.record(node(), attrs(%{modules_loaded: 0}))
      {:ok, second} = CodeStamp.record(node(), attrs(%{modules_loaded: 3}))

      assert DateTime.compare(iso(second.applied_at), iso(first.applied_at)) in [:gt, :eq]
      assert second.modules_loaded == 3
    end

    test "an unreachable node is an error, never a nil stamp" do
      assert {:error, {:unreachable, :nope@nowhere, _}} = CodeStamp.read(:nope@nowhere)
      assert {:error, {:unreachable, :nope@nowhere, _}} = CodeStamp.record(:nope@nowhere, attrs())
    end
  end

  describe "to_json/1" do
    test "no generation renders an explicit image source, never a sha" do
      json = CodeStamp.to_json(nil)

      assert json["source"] == "image"
      assert json["detail"] =~ "no code generation has been applied"
      refute Map.has_key?(json, "base_sha")
      refute Map.has_key?(json, "sha")
    end

    test "a stamp renders with string keys and source=generation" do
      {:ok, stamp} = CodeStamp.record(node(), attrs(%{dirty: true}))
      json = CodeStamp.to_json(stamp)

      assert json["source"] == "generation"
      assert json["base_sha"] == "abc123def456"
      assert json["dirty"] == true
      assert json["apply_status"] == "reconciled"
      # Must stay JSON-encodable — /api/version renders this straight out.
      assert {:ok, _} = Jason.encode(json)
    end
  end

  describe "the remote side touches only OTP" do
    test "the stamp is stored under a plain persistent_term key" do
      {:ok, stamp} = CodeStamp.record(node(), attrs())
      assert :persistent_term.get(CodeStamp.key()) == stamp
    end
  end
end
