defmodule OrcaHub.Triggers do
  import Ecto.Query
  alias OrcaHub.{Repo, Triggers.Trigger}

  def list_triggers do
    Repo.all(from t in Trigger, order_by: [asc: t.name], preload: [:project])
  end

  def list_triggers_for_project(project_id) do
    Repo.all(from t in Trigger, where: t.project_id == ^project_id, order_by: [asc: t.name])
  end

  def list_enabled_triggers do
    Repo.all(from t in Trigger, where: t.enabled == true, preload: [:project])
  end

  def get_trigger!(id), do: Repo.get!(Trigger, id) |> Repo.preload(:project)

  def get_trigger_by_secret!(secret) do
    Repo.get_by!(Trigger, webhook_secret: secret) |> Repo.preload(:project)
  end

  def create_trigger(attrs) do
    result =
      %Trigger{}
      |> Trigger.changeset(attrs)
      |> Repo.insert()

    with {:ok, trigger} <- result do
      trigger = Repo.preload(trigger, :project)

      if trigger.type == "scheduled" && trigger.enabled do
        OrcaHub.Scheduler.schedule_trigger(trigger)
      end
    end

    result
  end

  def update_trigger(%Trigger{} = trigger, attrs) do
    result =
      trigger
      |> Trigger.changeset(attrs)
      |> Repo.update()

    with {:ok, updated} <- result do
      OrcaHub.Scheduler.unschedule_trigger(updated.id)
      updated = Repo.preload(updated, :project)

      if updated.type == "scheduled" && updated.enabled do
        OrcaHub.Scheduler.schedule_trigger(updated)
      end
    end

    result
  end

  def delete_trigger(%Trigger{} = trigger) do
    OrcaHub.Scheduler.unschedule_trigger(trigger.id)
    Repo.delete(trigger)
  end

  def change_trigger(%Trigger{} = trigger, attrs \\ %{}) do
    Trigger.changeset(trigger, attrs)
  end
end
