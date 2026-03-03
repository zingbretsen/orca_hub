defmodule OrcaHubWeb.WebhookController do
  use OrcaHubWeb, :controller

  alias OrcaHub.Triggers

  def create(conn, %{"secret" => secret} = params) do
    trigger = Triggers.get_trigger_by_secret!(secret)

    unless trigger.enabled do
      conn |> put_status(404) |> json(%{error: "not found"})
    else
      payload = Map.drop(params, ["secret"])

      Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
        OrcaHub.TriggerExecutor.execute_webhook(trigger.id, payload)
      end)

      json(conn, %{ok: true, trigger: trigger.name})
    end
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(404) |> json(%{error: "not found"})
  end
end
