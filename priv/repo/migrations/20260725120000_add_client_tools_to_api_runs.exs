defmodule OrcaHub.Repo.Migrations.AddClientToolsToApiRuns do
  use Ecto.Migration

  # AG-UI-style client-defined ("frontend") tools (docs/api.md): the caller
  # supplies tool definitions on run creation (`client_tools`); when the
  # agent calls one, the call is parked on the run (`pending_tool_call`) with
  # status `awaiting_tool_result` until the caller POSTs the result back to
  # `/api/v1/runs/:id/tool_result`.
  def change do
    alter table(:api_runs) do
      add :client_tools, {:array, :map}
      add :pending_tool_call, :map
    end
  end
end
