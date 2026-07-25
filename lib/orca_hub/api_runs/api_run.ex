defmodule OrcaHub.ApiRuns.ApiRun do
  @moduledoc "Schema for an Agent Runs API run (docs/api.md)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_runs" do
    field :status, :string, default: "running"
    field :result, :map
    field :result_text, :string
    field :error, :string
    field :result_schema, :map
    field :timeout_seconds, :integer, default: 3600
    field :validation_attempts, :integer, default: 0
    field :max_validation_attempts, :integer, default: 3
    field :baseline_message_count, :integer, default: 0
    # AG-UI-style client-defined ("frontend") tools (docs/api.md): tool
    # definitions supplied by the caller at run creation, and the
    # currently-outstanding call (if any) waiting on a caller-posted result.
    field :client_tools, {:array, :map}
    field :pending_tool_call, :map

    belongs_to :session, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(api_run, attrs) do
    api_run
    |> cast(attrs, [
      :session_id,
      :status,
      :result,
      :result_text,
      :error,
      :result_schema,
      :timeout_seconds,
      :validation_attempts,
      :max_validation_attempts,
      :baseline_message_count,
      :client_tools,
      :pending_tool_call
    ])
    |> validate_required([:session_id])
    |> validate_inclusion(:status, ~w(running completed failed timed_out awaiting_tool_result))
    |> foreign_key_constraint(:session_id)
  end
end
