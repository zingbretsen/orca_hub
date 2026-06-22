defmodule OrcaHub.SessionRunnerTest do
  use ExUnit.Case, async: true

  alias OrcaHub.SessionRunner

  describe "build_system_prompt/1 — AskUserQuestion guidance" do
    test "is present for non-orchestrator sessions" do
      prompt =
        SessionRunner.build_system_prompt(%{
          orchestrator: false,
          session_id: "abc",
          directory: "/nonexistent-dir-#{System.unique_integer([:positive])}"
        })

      assert prompt =~ "AskUserQuestion"
      assert prompt =~ "automatic placeholder tool result"
      assert prompt =~ "stop and end your turn"
      assert prompt =~ "separate follow-up message"
    end

    test "is absent for orchestrator sessions (they lack the AskUserQuestion tool)" do
      prompt =
        SessionRunner.build_system_prompt(%{
          orchestrator: true,
          session_id: "abc",
          directory: "/nonexistent-dir-#{System.unique_integer([:positive])}"
        })

      refute prompt =~ "automatic placeholder tool result"
    end
  end
end
