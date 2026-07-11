defmodule OrcaHub.Issues.Issue do
  @moduledoc """
  Schema for an issue.

  The full Issues feature (UI, routes, session linkage) was removed in
  `3ebb3fe` — this schema is a minimal reintroduction backing the
  `file_feature_request` MCP tool (`OrcaHub.MCP.Tools.FeatureRequests`).
  The `issues` table and `sessions.issue_id` column were left in place by
  that removal, so no migration is needed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "issues" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :approaches_tried, :string
    field :notes, :string

    belongs_to :project, OrcaHub.Projects.Project, type: :binary_id

    timestamps()
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :status, :project_id, :approaches_tried, :notes])
    |> validate_required([:title])
    |> validate_inclusion(:status, ~w(open in_progress closed))
  end
end
