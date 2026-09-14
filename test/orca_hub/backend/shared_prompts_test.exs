defmodule OrcaHub.Backend.SharedPromptsTest do
  use ExUnit.Case, async: true

  alias OrcaHub.Backend.SharedPrompts

  describe "memory_hooks/1" do
    test "prefers the service's own \"hooks\" field when present" do
      assert SharedPrompts.memory_hooks(%{"hooks" => ["a", "b"], "block" => "whatever"}) == [
               "a",
               "b"
             ]
    end

    test "parses \"- [kind] hook — text\" lines out of the block, dropping headers" do
      block = """
      **fact:**
      - [fact] orca_hub: ORCA_API_TOKEN is a single static bearer — description here
      - [fact] pi loads AGENTS.md itself — more description

      **preference:**
      - [preference] qwen3-coder-next spawns SUSPENDED — do not use it
      """

      assert SharedPrompts.memory_hooks(%{"block" => block}) == [
               "orca_hub: ORCA_API_TOKEN is a single static bearer",
               "pi loads AGENTS.md itself",
               "qwen3-coder-next spawns SUSPENDED"
             ]
    end

    test "returns [] for a block with no recognizable hook lines" do
      assert SharedPrompts.memory_hooks(%{"block" => "just some prose, no bullets"}) == []
    end

    test "returns [] when neither hooks nor block is present" do
      assert SharedPrompts.memory_hooks(%{}) == []
    end

    test "derives hooks from the newer \"memories\" array (memory-service c932074) when \"hooks\" is absent" do
      assert SharedPrompts.memory_hooks(%{
               "memories" => [
                 %{"id" => "mem-1", "hook" => "first hook", "kind" => "fact"},
                 %{"id" => "mem-2", "hook" => "second hook", "kind" => "preference"}
               ]
             }) == ["first hook", "second hook"]
    end

    test "prefers the top-level \"hooks\" field over \"memories\" when both are present" do
      assert SharedPrompts.memory_hooks(%{
               "hooks" => ["legacy hook"],
               "memories" => [%{"hook" => "new hook"}]
             }) == ["legacy hook"]
    end
  end

  describe "record_memory_injection/2" do
    setup do
      test_pid = self()

      Process.put(:orca_hub_persist_system_event_fun, fn session_id, event ->
        send(test_pid, {:persisted, session_id, event})
        :ok
      end)

      :ok
    end

    test "carries the \"memories\" array through to the persisted event when present" do
      memories = [
        %{
          "id" => "mem-1",
          "hook" => "first hook",
          "kind" => "fact",
          "review_status" => "approved"
        }
      ]

      SharedPrompts.record_memory_injection("sess-1", %{
        "block" => "- [fact] first hook — detail",
        "memory_ids" => ["mem-1"],
        "memories" => memories,
        "pinned_count" => 1,
        "recalled_count" => 0
      })

      assert_received {:persisted, "sess-1", event}
      assert event["memories"] == memories
      # memory_ids/hooks still populated too — backward compatible with any
      # consumer still reading the older fields.
      assert event["memory_ids"] == ["mem-1"]
      assert event["hooks"] == ["first hook"]
    end

    test "omits the \"memories\" key entirely when the response doesn't have one (older service)" do
      SharedPrompts.record_memory_injection("sess-1", %{
        "block" => "- [fact] first hook — detail",
        "memory_ids" => ["mem-1"],
        "pinned_count" => 1,
        "recalled_count" => 0
      })

      assert_received {:persisted, "sess-1", event}
      refute Map.has_key?(event, "memories")
    end
  end

  # ── context_manifest_prompt/1 ─────────────────────────────────────────
  # Replaces the old glob-and-inline of every .context/*.{md,mmd}: that set
  # is 129,592 bytes in this repo alone (8 docs, 2,353 lines), so once the
  # other fragments were added Claude's single --append-system-prompt argv
  # value crossed Linux's 128 KiB MAX_ARG_STRLEN and every spawn E2BIG'd at
  # Port.open. Only the hand-maintained manifest is read now — one
  # deterministic path, no glob.
  describe "context_manifest_prompt/1" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "shared_prompts_ctx_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(dir, ".context"))
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir, context_dir: Path.join(dir, ".context")}
    end

    test "inlines ONLY manifest.md, never the sibling docs", %{
      dir: dir,
      context_dir: context_dir
    } do
      manifest_marker = "manifest-sentinel-#{System.unique_integer([:positive])}"
      doc_marker = "doc-sentinel-#{System.unique_integer([:positive])}"

      File.write!(Path.join(context_dir, "manifest.md"), "# Map\n\n#{manifest_marker}")
      File.write!(Path.join(context_dir, "architecture.md"), "# Arch\n\n#{doc_marker}")
      File.write!(Path.join(context_dir, "flow.mmd"), "graph TB\n  #{doc_marker}")

      prompt = SharedPrompts.context_manifest_prompt(dir)

      assert prompt == "# Project Context\n\n# Map\n\n#{manifest_marker}"
      refute prompt =~ doc_marker
      refute prompt =~ "## architecture"
    end

    test "returns nil when there is no .context directory" do
      assert SharedPrompts.context_manifest_prompt("/nonexistent-#{System.unique_integer()}") ==
               nil
    end

    test "returns nil for an empty .context directory", %{dir: dir} do
      assert SharedPrompts.context_manifest_prompt(dir) == nil
    end

    test "with docs but no manifest, falls back to a bounded NAME listing, no content", %{
      dir: dir,
      context_dir: context_dir
    } do
      doc_marker = "doc-sentinel-#{System.unique_integer([:positive])}"

      for i <- 1..30 do
        File.write!(
          Path.join(context_dir, "doc-#{String.pad_leading("#{i}", 2, "0")}.md"),
          String.duplicate("#{doc_marker} ", 500)
        )
      end

      prompt = SharedPrompts.context_manifest_prompt(dir)

      assert prompt =~ "# Project Context"
      assert prompt =~ "no `.context/manifest.md` yet"
      assert prompt =~ "- .context/doc-01.md"
      assert prompt =~ "- .context/doc-24.md"
      refute prompt =~ "- .context/doc-25.md"
      assert prompt =~ "and 6 more"
      refute prompt =~ doc_marker
      # 30 docs × ~7 KiB on disk; the fallback stays tiny regardless.
      assert byte_size(prompt) < 2_048
    end

    test "truncates an oversized manifest at the hard cap with a visible marker", %{
      dir: dir,
      context_dir: context_dir
    } do
      cap = SharedPrompts.context_manifest_max_bytes()
      # A 3-BYTE character on purpose: the cap (16_384) is even, so a 2-byte
      # char like "é" would always cut on a code-point boundary and the
      # back-off in safe_binary_prefix/2 would never run. 16_384 is not
      # divisible by 3, so the raw cut lands mid-sequence and the prefix
      # must be walked back one byte to 16_383 to be valid UTF-8.
      content = String.duplicate("€", cap)
      assert byte_size(content) == cap * 3
      refute String.valid?(binary_part(content, 0, cap))
      File.write!(Path.join(context_dir, "manifest.md"), content)

      prompt = SharedPrompts.context_manifest_prompt(dir)

      assert String.valid?(prompt)
      assert prompt =~ "truncated at #{cap} bytes (was #{cap * 3})"
      # The kept body is exactly the walked-back 16_383 bytes: 5_461 whole
      # "€"s, i.e. the back-off dropped the dangling lead byte.
      body =
        prompt
        |> String.replace_prefix("# Project Context\n\n", "")
        |> String.split("\n\n[.context/")
        |> hd()

      assert byte_size(body) == cap - 1
      assert body == String.duplicate("€", div(cap, 3))
      # Header + capped body + a short marker; nowhere near the full file.
      assert byte_size(prompt) < cap + 256
    end
  end

  # The real manifest is what every Claude/Codex session in THIS repo pays
  # for at startup — pin it to its stated budget so it can't quietly drift
  # back toward the doc-set-sized prompt that E2BIG'd spawns.
  describe "this repo's .context/manifest.md" do
    @repo_manifest Path.expand("../../../.context/manifest.md", __DIR__)
    @repo_manifest_budget_bytes 6_144

    test "exists and stays within its ~6 KiB budget" do
      assert File.exists?(@repo_manifest), "#{@repo_manifest} is missing"
      size = File.stat!(@repo_manifest).size

      assert size <= @repo_manifest_budget_bytes,
             ".context/manifest.md is #{size} bytes, over the #{@repo_manifest_budget_bytes}-byte " <>
               "budget — move detail into the other .context/*.md files, keep this a map"
    end

    test "points at every sibling .context doc so none is orphaned" do
      manifest = File.read!(@repo_manifest)

      siblings =
        @repo_manifest
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&(Path.extname(&1) in ~w(.md .mmd) and &1 != "manifest.md"))
        |> Enum.sort()

      assert siblings != []

      for doc <- siblings do
        assert manifest =~ ".context/#{doc}", "manifest.md does not mention .context/#{doc}"
      end
    end
  end
end
