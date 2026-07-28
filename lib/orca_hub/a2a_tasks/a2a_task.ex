defmodule OrcaHub.A2ATasks.A2ATask do
  @moduledoc """
  Schema for an inbound A2A (Agent2Agent) task (docs/a2a.md) — one row per
  `message/send` call, mapping to exactly one OrcaHub session turn.

  `id` doubles as the A2A `task.id`; `session_id` doubles as `task.contextId`
  (one OrcaHub session == one A2A "conversation"/context).

  v2 (docs/a2a.md "v2: client tools + structured results") adds
  `client_tools`/`result_schema`/`max_validation_attempts` (declared once at
  session creation, copy-forward inherited by every later task in the same
  conversation — see `OrcaHub.A2ATasks.create_task/1`) and the per-task
  `pending_tool_call`/`validation_attempts`/`result` columns backing the
  `"input-required"` tool-call-parking loop and schema-validated results —
  mirrors `OrcaHub.ApiRuns.ApiRun`'s identical columns; see
  `OrcaHub.MCP.ToolCallHolder.A2ATaskHolder`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "a2a_tasks" do
    field :status, :string, default: "submitted"
    field :error, :string
    field :result_text, :string
    field :baseline_message_count, :integer, default: 0
    field :timeout_seconds, :integer, default: 3600

    # AG-UI-style client-defined ("frontend") tools + schema-validated
    # results (docs/a2a.md v2) — declared once, inherited across the
    # conversation's later tasks (see OrcaHub.A2ATasks.create_task/1).
    field :client_tools, {:array, :map}
    field :result_schema, :map
    field :max_validation_attempts, :integer, default: 3
    # Per-task: how many corrective retries this task's own turn has used,
    # the currently-outstanding client-tool call (if any) awaiting a
    # caller-posted result, and the final validated structured result.
    field :validation_attempts, :integer, default: 0
    field :pending_tool_call, :map
    field :result, :map
    # Append-only log of every distinct tool_call_id ever parked for this
    # task — backs the idempotent-ack precedence rule (see the migration).
    field :issued_tool_call_ids, {:array, :string}, default: []

    belongs_to :session, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :session_id,
      :status,
      :error,
      :result_text,
      :baseline_message_count,
      :timeout_seconds,
      :client_tools,
      :result_schema,
      :max_validation_attempts,
      :validation_attempts,
      :pending_tool_call,
      :result,
      :issued_tool_call_ids
    ])
    |> validate_required([:session_id])
    |> validate_inclusion(:status, ~w(submitted working input-required completed failed canceled))
    |> foreign_key_constraint(:session_id)
  end
end
