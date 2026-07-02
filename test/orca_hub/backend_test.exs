defmodule OrcaHub.BackendTest do
  @moduledoc """
  Phase 1 coverage for `OrcaHub.Backend.resolve/1` and `available/0`
  (backend_abstraction_spec.md §4/§8).
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

    test "raises loudly on an unregistered backend instead of silently falling back" do
      assert_raise RuntimeError, ~r/unknown backend/i, fn ->
        Backend.resolve("codex")
      end
    end

    test "raises loudly on garbage input" do
      assert_raise RuntimeError, fn ->
        Backend.resolve("not-a-real-backend")
      end
    end
  end

  describe "available/0" do
    test "returns only Claude in Phase 1" do
      assert Backend.available() == [{"claude", "Claude"}]
    end
  end
end
