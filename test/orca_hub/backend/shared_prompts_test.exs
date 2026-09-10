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
  end
end
