defmodule OrcaHub.MCP.Tools.Projects do
  @moduledoc """
  MCP tool exposing registered projects (id, name, directory, node) so an
  agent can resolve a project UUID for tools that require one —
  `create_scheduled_trigger`/`create_webhook_trigger` (see
  `OrcaHub.MCP.Tools.Triggers`) previously required a `project_id` with
  nothing on the MCP tool surface to look one up (FR 3e2828bc).
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC}

  def list do
    [
      %{
        "name" => "list_projects",
        "description" =>
          "List every registered (non-deleted) project: id, name, directory, and node. " <>
            "Use this to look up a project's UUID — e.g. for create_scheduled_trigger/" <>
            "create_webhook_trigger's project_id parameter (both also accept a `directory` " <>
            "argument as a shortcut instead).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      }
    ]
  end

  def call("list_projects", _args, _state) do
    projects =
      HubRPC.list_projects()
      |> Enum.map(fn project ->
        %{
          id: project.id,
          name: project.name,
          directory: project.directory,
          node: Cluster.node_name(project.node || node())
        }
      end)

    text(Jason.encode!(projects))
  end
end
