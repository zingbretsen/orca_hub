defmodule OrcaHub.AlertSubscriptionsTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.AlertSubscriptions

  defp unique_id, do: Ecto.UUID.generate()

  describe "get_by_orchestrator/1" do
    test "returns nil when no subscription exists" do
      assert AlertSubscriptions.get_by_orchestrator(unique_id()) == nil
    end
  end

  describe "upsert/2" do
    test "creates a new subscription with the given attrs" do
      id = unique_id()
      other_id = unique_id()

      assert {:ok, subscription} =
               AlertSubscriptions.upsert(id, %{
                 watch_children: false,
                 session_ids: [other_id],
                 conditions: %{"churn" => true, "progress_stale" => 20},
                 cooldown_seconds: 300,
                 enabled: true
               })

      assert subscription.orchestrator_session_id == id
      assert subscription.watch_children == false
      assert subscription.session_ids == [other_id]
      assert subscription.conditions == %{"churn" => true, "progress_stale" => 20}
      assert subscription.cooldown_seconds == 300
      assert subscription.enabled == true
    end

    test "fills in schema defaults when attrs are omitted" do
      id = unique_id()

      assert {:ok, subscription} = AlertSubscriptions.upsert(id, %{})

      assert subscription.watch_children == true
      assert subscription.session_ids == []
      assert subscription.conditions == %{}
      assert subscription.cooldown_seconds == 900
      assert subscription.enabled == true
    end

    test "updates the existing row in place — one config per orchestrator" do
      id = unique_id()

      assert {:ok, first} = AlertSubscriptions.upsert(id, %{cooldown_seconds: 600})
      assert {:ok, second} = AlertSubscriptions.upsert(id, %{cooldown_seconds: 120})

      assert first.id == second.id
      assert second.cooldown_seconds == 120

      assert AlertSubscriptions.get_by_orchestrator(id).cooldown_seconds == 120
    end

    test "rejects a negative cooldown" do
      assert {:error, changeset} = AlertSubscriptions.upsert(unique_id(), %{cooldown_seconds: -1})
      assert "must be greater than or equal to 0" in errors_on(changeset).cooldown_seconds
    end
  end

  describe "cancel/1" do
    test "removes an existing subscription and returns :ok" do
      id = unique_id()
      {:ok, _} = AlertSubscriptions.upsert(id, %{})

      assert AlertSubscriptions.cancel(id) == :ok
      assert AlertSubscriptions.get_by_orchestrator(id) == nil
    end

    test "is a no-op when nothing exists for that orchestrator" do
      assert AlertSubscriptions.cancel(unique_id()) == :ok
    end
  end

  describe "list_enabled/0" do
    test "returns only enabled subscriptions" do
      enabled_id = unique_id()
      disabled_id = unique_id()

      {:ok, _} = AlertSubscriptions.upsert(enabled_id, %{enabled: true})
      {:ok, _} = AlertSubscriptions.upsert(disabled_id, %{enabled: false})

      ids = AlertSubscriptions.list_enabled() |> Enum.map(& &1.orchestrator_session_id)

      assert enabled_id in ids
      refute disabled_id in ids
    end
  end
end
