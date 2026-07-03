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

  # Direct state-function tests (GenStatem callback-mode :state_functions makes
  # these plain public functions) — no live runner/port needed.
  describe "update_backend — state handling" do
    defp switch_data(overrides) do
      Map.merge(
        %{
          session_id: Ecto.UUID.generate(),
          directory: "/nonexistent-dir-#{System.unique_integer([:positive])}",
          backend: OrcaHub.Backend.Claude,
          backend_state: %{stale: true},
          claude_session_id: "native-abc",
          model: "opus",
          port: nil
        },
        overrides
      )
    end

    test "idle switch swaps the backend module and drops resume id, model, and backend_state" do
      from = {self(), make_ref()}

      {:keep_state, new_data, actions} =
        SessionRunner.idle({:call, from}, {:update_backend, "codex"}, switch_data(%{}))

      assert new_data.backend == OrcaHub.Backend.Codex
      assert new_data.backend_state == %{}
      assert new_data.claude_session_id == nil
      assert new_data.model == nil
      assert {:reply, ^from, :ok} = List.keyfind(actions, :reply, 0)
    end

    test "switching to the already-active backend is a no-op" do
      from = {self(), make_ref()}
      data = switch_data(%{})

      assert {:keep_state_and_data, [{:reply, ^from, :ok}]} =
               SessionRunner.idle({:call, from}, {:update_backend, "claude"}, data)
    end

    test "mid-turn switch is refused with :busy" do
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :busy}}]} =
               SessionRunner.running({:call, from}, {:update_backend, "codex"}, switch_data(%{}))
    end

    test "update_backend/2 towards a dead runner returns :ok (DB column is source of truth)" do
      assert SessionRunner.update_backend(Ecto.UUID.generate(), "codex") == :ok
    end
  end
end
