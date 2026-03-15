defmodule OrcaHubWeb.WebhookController do
  use OrcaHubWeb, :controller

  alias OrcaHub.{Cluster, Triggers, TriggerExecutor}

  def create(conn, %{"secret" => secret} = params) do
    case find_trigger_by_secret(secret) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {_node, trigger} when not trigger.enabled ->
        conn |> put_status(404) |> json(%{error: "not found"})

      {trigger_node, trigger} ->
        payload = Map.drop(params, ["secret"])

        Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
          Cluster.rpc(trigger_node, TriggerExecutor, :execute_webhook, [trigger.id, payload])
        end)

        json(conn, %{ok: true, trigger: trigger.name})
    end
  end

  defp find_trigger_by_secret(secret) do
    Cluster.fan_out(Triggers, :get_trigger_by_secret, [secret])
    |> Enum.find(fn {_node, result} -> result != nil end)
  end
end
