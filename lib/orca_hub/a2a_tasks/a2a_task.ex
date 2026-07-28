defmodule OrcaHub.A2ATasks.A2ATask do
  @moduledoc """
  Schema for an inbound A2A (Agent2Agent) task (docs/a2a.md) — one row per
  `message/send` call, mapping to exactly one OrcaHub session turn.

  `id` doubles as the A2A `task.id`; `session_id` doubles as `task.contextId`
  (one OrcaHub session == one A2A "conversation"/context).
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
      :timeout_seconds
    ])
    |> validate_required([:session_id])
    |> validate_inclusion(:status, ~w(submitted working completed failed canceled))
    |> foreign_key_constraint(:session_id)
  end
end
