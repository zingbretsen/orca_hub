defmodule OrcaHub.BackendTest do
  @moduledoc """
  Coverage for `OrcaHub.Backend.resolve/1`, `available/0`, `capabilities_for/1`,
  and `models_for/1` (backend_abstraction_spec.md §4/§7/§8/§12.2). Phase 1
  landed Claude only; Phase 2 registers Codex; Phase 3 adds the
  capability/model lookup helpers the UI branches on; the pi adapter adds a
  third backend and the first `mcp: false` capability row exercised here.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Backend
  alias OrcaHub.Backend.Capabilities

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

    test "resolves \"pi\" to Backend.Pi" do
      assert Backend.resolve("pi") == OrcaHub.Backend.Pi
    end

    test "raises loudly on garbage input instead of silently falling back" do
      assert_raise RuntimeError, ~r/unknown backend/i, fn ->
        Backend.resolve("not-a-real-backend")
      end
    end
  end

  describe "available/0" do
    test "returns Claude, Codex, and pi" do
      assert Backend.available() == [
               {"claude", "Claude"},
               {"codex", "Codex"},
               {"pi", "Pi"}
             ]
    end
  end

  describe "capabilities_for/1" do
    test "nil backend resolves to Claude's capabilities (legacy/pre-column rows)" do
      assert Backend.capabilities_for(nil) == OrcaHub.Backend.Claude.capabilities()
    end

    test "\"claude\" resolves to Claude's capabilities" do
      caps = Backend.capabilities_for("claude")
      assert %Capabilities{} = caps
      assert caps.usage == true
      assert caps.plan_mode == true
      assert caps.ask_user_question == true
      assert caps.mcp == true
    end

    test "\"codex\" resolves to Codex's capabilities" do
      caps = Backend.capabilities_for("codex")
      assert caps.usage == false
      assert caps.plan_mode == false
      assert caps.ask_user_question == false
      assert caps.mcp == true
    end

    test "\"pi\" resolves to pi's capabilities (mcp: false is the distinguishing gap)" do
      caps = Backend.capabilities_for("pi")
      assert caps.usage == false
      assert caps.plan_mode == false
      assert caps.ask_user_question == false
      assert caps.mcp == false
      assert caps.resume == true
      assert caps.streaming == true
    end

    test "accepts anything with a :backend key (a session-shaped map/struct)" do
      assert Backend.capabilities_for(%{backend: "codex"}).usage == false
      assert Backend.capabilities_for(%{backend: "pi"}).mcp == false
      assert Backend.capabilities_for(%{backend: nil}) == OrcaHub.Backend.Claude.capabilities()
    end

    test "never raises on nil, even though resolve/1 still raises on garbage strings" do
      assert Backend.capabilities_for(nil)

      assert_raise RuntimeError, ~r/unknown backend/i, fn ->
        Backend.capabilities_for("not-a-real-backend")
      end
    end
  end

  describe "models_for/1" do
    test "returns Claude's exact model list" do
      assert Backend.models_for("claude") == OrcaHub.Backend.Claude.models()
      assert Backend.models_for(nil) == OrcaHub.Backend.Claude.models()
    end

    test "returns Codex's default model list (passthrough ids, not an enum)" do
      models = Backend.models_for("codex")
      assert models == OrcaHub.Backend.Codex.models()
      assert Enum.all?(models, fn {id, label} -> is_binary(id) and is_binary(label) end)
    end

    test "returns pi's default model list (passthrough provider/id strings)" do
      models = Backend.models_for("pi")
      assert models == OrcaHub.Backend.Pi.models()
      assert Enum.all?(models, fn {id, label} -> is_binary(id) and is_binary(label) end)
    end

    test "accepts a session-shaped map" do
      assert Backend.models_for(%{backend: "codex"}) == OrcaHub.Backend.Codex.models()
      assert Backend.models_for(%{backend: "pi"}) == OrcaHub.Backend.Pi.models()
    end
  end

  describe "installed_backends/0 and available_on/1 — node-scoped picker filtering" do
    test "installed_backends is the subset of available whose CLI resolves locally" do
      installed = Backend.installed_backends()

      assert Enum.all?(installed, &(&1 in Backend.available()))
      # This host has the claude CLI (the test suite itself runs under it).
      assert {"claude", "Claude"} in installed
    end

    test "available_on the local node matches installed_backends (cached)" do
      OrcaHub.Backend.Cache.invalidate({:available_on, node()})
      assert Backend.available_on(node()) == Backend.installed_backends()
      # A string node name resolves the same way.
      assert Backend.available_on(Atom.to_string(node())) == Backend.installed_backends()
    end

    test "an unreachable node degrades to Claude-only rather than raising" do
      assert Backend.available_on(:"nonexistent@nowhere.invalid") == [{"claude", "Claude"}]
    end

    test "a garbage node string falls back to the local node" do
      OrcaHub.Backend.Cache.invalidate({:available_on, node()})
      assert Backend.available_on("not even an existing atom !") == Backend.installed_backends()
    end
  end

  describe "models_for/2 — node-scoped model lists" do
    test "static backends answer through the cache unchanged" do
      OrcaHub.Backend.Cache.invalidate({:models_for, "codex", node()})
      assert Backend.models_for("codex", node()) == OrcaHub.Backend.Codex.models()
    end

    test "an unreachable node degrades to [] (free-text entry still works)" do
      assert Backend.models_for("codex", :"nonexistent@nowhere.invalid") == []
    end
  end
end
