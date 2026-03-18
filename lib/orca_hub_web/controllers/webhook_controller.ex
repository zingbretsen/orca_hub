defmodule OrcaHubWeb.WebhookController do
  use OrcaHubWeb, :controller

  alias OrcaHub.{Cluster, HubRPC, TriggerExecutor}

  def create(conn, %{"secret" => secret} = params) do
    case HubRPC.call(OrcaHub.Triggers, :get_trigger_by_secret, [secret]) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not found"})

      %{enabled: false} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      trigger ->
        payload = Map.drop(params, ["secret"])
        runner_node = if trigger.project, do: Cluster.project_node_for(trigger.project), else: node()

        Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
          Cluster.rpc(runner_node, TriggerExecutor, :execute_webhook, [trigger.id, payload])
        end)

        json(conn, %{ok: true, trigger: trigger.name})
    end
  end
end
