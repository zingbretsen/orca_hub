defmodule OrcaHubWeb.WebhookController do
  use OrcaHubWeb, :controller
  require Logger

  alias OrcaHub.{Cluster, HubRPC, TriggerExecutor}

  def create(conn, %{"secret" => secret} = params) do
    case HubRPC.call(OrcaHub.Triggers, :get_trigger_by_secret, [secret]) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not found"})

      %{enabled: false} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      trigger ->
        payload = Map.drop(params, ["secret"])

        runner_node =
          if trigger.project, do: Cluster.project_node_for(trigger.project), else: node()

        Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
          case Cluster.rpc(runner_node, TriggerExecutor, :execute_webhook, [trigger.id, payload]) do
            {:error, {:node_unavailable, _}} = error ->
              Logger.warning(
                "Webhook trigger #{trigger.name} (#{trigger.id}) skipped: " <>
                  "node #{inspect(runner_node)} is not currently connected"
              )

              error

            other ->
              other
          end
        end)

        json(conn, %{ok: true, trigger: trigger.name})
    end
  end
end
