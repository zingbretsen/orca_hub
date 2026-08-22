defmodule OrcaHub.AlertSubscriptions do
  @moduledoc """
  Context for `alert_subscriptions` — ORCAHUB3-44 Phase 2's condition-based
  worker-alert configs. One row per orchestrator session, upserted in place
  by `upsert/2` (mirrors `schedule_heartbeat`'s update-in-place semantics).
  DB-persisted deliberately (unlike `OrcaHub.SessionHeartbeat`'s in-memory
  heartbeats) so a configured watch survives a deploy/restart — see
  `OrcaHub.ChurnSampler` for the evaluator that reads `list_enabled/0` on
  every sweep.
  """

  import Ecto.Query

  alias OrcaHub.Repo
  alias OrcaHub.AlertSubscriptions.AlertSubscription

  @doc "The current config for `orchestrator_session_id`, or nil if none is set."
  def get_by_orchestrator(orchestrator_session_id) do
    Repo.get_by(AlertSubscription, orchestrator_session_id: orchestrator_session_id)
  end

  @doc """
  Create or update `orchestrator_session_id`'s alert subscription in place —
  one config per orchestrator, exactly like `SessionHeartbeat.schedule/4`.
  """
  def upsert(orchestrator_session_id, attrs) do
    attrs = Map.put(attrs, :orchestrator_session_id, orchestrator_session_id)

    case get_by_orchestrator(orchestrator_session_id) do
      nil -> %AlertSubscription{}
      existing -> existing
    end
    |> AlertSubscription.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Removes `orchestrator_session_id`'s alert subscription, if any. Always returns :ok."
  def cancel(orchestrator_session_id) do
    case get_by_orchestrator(orchestrator_session_id) do
      nil ->
        :ok

      subscription ->
        Repo.delete(subscription)
        :ok
    end
  end

  @doc "Every enabled alert subscription — read by `OrcaHub.ChurnSampler` on each sweep."
  def list_enabled do
    Repo.all(from s in AlertSubscription, where: s.enabled == true)
  end
end
