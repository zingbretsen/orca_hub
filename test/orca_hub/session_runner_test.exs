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

  # spec §12.8 — toggle_plan_mode/1's cold-queue fallback. Direct state-function
  # tests, same posture as "update_backend — state handling" above: the
  # :ready/:error/cold-:idle/:running refusal-or-queue decision needs no live
  # port, so it's covered here; the warm-:idle Port.command write path is
  # covered end-to-end by PiStubIntegrationTest instead (needs a real port).
  describe "toggle_plan_mode — plan-mode pending queue (spec §12.8)" do
    # queue_plan_mode_toggle/2 checks function_exported?(data.backend,
    # encode_toggle_plan_mode, 1) — Erlang's function_exported?/3 requires the
    # module to already be LOADED and does NOT autoload it (unlike calling
    # one of its functions, which is what makes this reliable in the full
    # suite / a real runner that's already called Backend.Pi.spawn_spec/2
    # etc.). Force both modules loaded so this file passes standalone too.
    setup do
      Code.ensure_loaded!(OrcaHub.Backend.Pi)
      Code.ensure_loaded!(OrcaHub.Backend.Claude)
      :ok
    end

    defp plan_data(overrides) do
      Map.merge(
        %{
          session_id: Ecto.UUID.generate(),
          directory: "/nonexistent-dir-#{System.unique_integer([:positive])}",
          backend: OrcaHub.Backend.Pi,
          backend_state: %{},
          plan_mode_pending: false,
          engine: :streaming,
          port: nil
        },
        overrides
      )
    end

    test ":ready queues (flips plan_mode_pending) and replies :ok" do
      from = {self(), make_ref()}

      assert {:keep_state, new_data, [{:reply, ^from, :ok}]} =
               SessionRunner.ready({:call, from}, :toggle_plan_mode, plan_data(%{}))

      assert new_data.plan_mode_pending == true
    end

    test "toggling again while queued just flips it back off" do
      from = {self(), make_ref()}
      data = plan_data(%{plan_mode_pending: true})

      assert {:keep_state, new_data, [{:reply, ^from, :ok}]} =
               SessionRunner.ready({:call, from}, :toggle_plan_mode, data)

      assert new_data.plan_mode_pending == false
    end

    test "cold :idle (no warm port) also queues, same as :ready" do
      from = {self(), make_ref()}

      assert {:keep_state, new_data, [{:reply, ^from, :ok}]} =
               SessionRunner.idle({:call, from}, :toggle_plan_mode, plan_data(%{port: nil}))

      assert new_data.plan_mode_pending == true
    end

    test ":error also queues" do
      from = {self(), make_ref()}

      assert {:keep_state, new_data, [{:reply, ^from, :ok}]} =
               SessionRunner.error({:call, from}, :toggle_plan_mode, plan_data(%{}))

      assert new_data.plan_mode_pending == true
    end

    test ":running is the only state that still refuses outright — a turn is in flight" do
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               SessionRunner.running({:call, from}, :toggle_plan_mode, plan_data(%{}))
    end

    test "a backend with no toggle mechanism replies :unsupported instead of queuing" do
      from = {self(), make_ref()}
      data = plan_data(%{backend: OrcaHub.Backend.Claude})

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :unsupported}}]} =
               SessionRunner.ready({:call, from}, :toggle_plan_mode, data)
    end
  end

  # spec §12.8 — compact_session/1's narrower gating: unlike toggle_plan_mode/1
  # above, EVERY non-warm-:idle state refuses (no cold-queue fallback —
  # compaction mid-turn is the backend's own business, a cold session has
  # nothing to compact). The warm-:idle Port.command dispatch success path is
  # covered end-to-end by PiStubIntegrationTest (needs a real port).
  describe "compact_session — state handling (spec §12.8)" do
    test ":ready refuses — nothing warm to compact" do
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               SessionRunner.ready({:call, from}, :compact_session, plan_data(%{}))
    end

    test "cold :idle (no warm port) refuses" do
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               SessionRunner.idle({:call, from}, :compact_session, plan_data(%{port: nil}))
    end

    test ":running refuses — compaction mid-turn is the backend's own business" do
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               SessionRunner.running({:call, from}, :compact_session, plan_data(%{}))
    end

    test ":error refuses" do
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               SessionRunner.error({:call, from}, :compact_session, plan_data(%{}))
    end
  end
end
