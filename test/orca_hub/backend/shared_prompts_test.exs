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
end
