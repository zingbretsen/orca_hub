defmodule OrcaHub.Repo.Migrations.AddIssuedToolCallIdsToA2ATasks do
  use Ecto.Migration

  # A2A v2 idempotent-ack precedence (docs/a2a.md "Tool-call loop"): answering
  # ANY tool_call_id ever issued for a task succeeds in any task state,
  # including terminal — only a truly never-issued id is rejected. Unlike
  # `pending_tool_call` (cleared to nil once a call resolves), this is an
  # append-only log of every distinct tool_call_id ever parked for the task,
  # so that membership check survives well past the call's own resolution —
  # see OrcaHub.MCP.ToolCallHolder.A2ATaskHolder.update/2.
  def change do
    alter table(:a2a_tasks) do
      add :issued_tool_call_ids, {:array, :string}, null: false, default: []
    end
  end
end
