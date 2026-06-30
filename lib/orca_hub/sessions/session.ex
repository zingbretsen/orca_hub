defmodule OrcaHub.Sessions.Session do
  @moduledoc "Schema for a Claude session."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @foreign_key_type :binary_id

  schema "sessions" do
    field :directory, :string
    field :claude_session_id, :string
    field :title, :string
    field :status, :string, default: "ready"
    field :model, :string
    field :archived_at, :utc_datetime
    field :triggered, :boolean, default: false
    field :priority, :integer, default: 0
    field :runner_node, :string
    field :original_node, :string
    field :orchestrator, :boolean, default: false
    # "Code execution with MCP" mode — collapses this session's MCP
    # tools/list to the meta-tools (run_elixir/search_tools/read_tool) and
    # exposes every other tool as a generated `Tools.*` function. ON by
    # default for new sessions; still opt-OUT per session, and globally
    # killable node-wide via ORCA_DISABLE_CODE_EXEC.
    field :code_exec, :boolean, default: true
    field :parent_session_id, :binary_id
    # nil = inherit global default (streaming unless ORCA_DISABLE_STREAMING set);
    # true/false force the engine for this session
    field :streaming, :boolean

    has_many :messages, OrcaHub.Sessions.Message
    belongs_to :project, OrcaHub.Projects.Project

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :directory,
      :claude_session_id,
      :title,
      :status,
      :model,
      :project_id,
      :archived_at,
      :triggered,
      :priority,
      :runner_node,
      :original_node,
      :orchestrator,
      :code_exec,
      :parent_session_id,
      :streaming
    ])
    |> validate_required([:directory])
    |> validate_inclusion(:status, ~w(ready idle running waiting error compacting))
  end
end
