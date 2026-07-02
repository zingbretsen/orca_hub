defmodule OrcaHub.BackendTest do
  @moduledoc """
  Coverage for `OrcaHub.Backend.resolve/1` and `available/0`
  (backend_abstraction_spec.md §4/§8). Phase 1 landed Claude only; Phase 2
  registers Codex.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Backend

  describe "resolve/1" do
    test "resolves \"claude\" to Backend.Claude" do
      assert Backend.resolve("claude") == OrcaHub.Backend.Claude
    end

    test "resolves nil to Backend.Claude (pre-column-default rows/paths)" do
      assert Backend.resolve(nil) == OrcaHub.Backend.Claude
    end

    test "resolves \"codex\" to Backend.Codex" do
      assert Backend.resolve("codex") == OrcaHub.Backend.Codex
    end

    test "raises loudly on garbage input instead of silently falling back" do
      assert_raise RuntimeError, ~r/unknown backend/i, fn ->
        Backend.resolve("not-a-real-backend")
      end
    end
  end

  describe "available/0" do
    test "returns Claude and Codex in Phase 2" do
      assert Backend.available() == [{"claude", "Claude"}, {"codex", "Codex"}]
    end
  end
end
