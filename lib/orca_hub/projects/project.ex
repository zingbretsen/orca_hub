defmodule OrcaHub.Projects.Project do
  @moduledoc "Schema for a project."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :directory, :string
    field :deleted_at, :utc_datetime
    field :node, :string
    # Extension to OrcaHub.Env's strict_env/2 base allow-list, combined with
    # the owning node's own env_allowlist — see
    # OrcaHub.NodePolicy.extra_env_allowlist/1. Only relevant when the node
    # also has scrub_session_env enabled. Same entry grammar as
    # OrcaHub.ClusterNodes.ClusterNode#env_allowlist (exact name or NAME*).
    field :env_allowlist, {:array, :string}, default: []
    # Whether sessions under this project are instructed to append the
    # OrcaHub-Session git trailer to commits — see
    # OrcaHub.Backend.SharedPrompts.commit_trailer_prompt/1. Resolved once at
    # SessionRunner init, so toggling this only affects the NEXT cold spawn
    # (a warm streaming port already baked its system prompt).
    field :commit_trailer, :boolean, default: true
    # Per-project issue-key namespace, e.g. "ORCA" renders keys like
    # "ORCA-142" (issues_spec.md §3.2). Uppercase letters/digits, 2-10
    # chars, must start with a letter — globally unique. Nullable: a
    # project created before this column existed (or created without an
    # explicit prefix) simply can't mint short keys yet.
    field :key_prefix, :string
    # Atomically incremented (Repo.update_all/2, row-level locking — see
    # OrcaHub.Issues.create_issue/1) to allocate each new issue's
    # `key_number` within this project. Gaps are acceptable (§3.2.2); this
    # is an identifier source, not an accounting ledger.
    field :issue_counter, :integer, default: 0

    has_many :sessions, OrcaHub.Sessions.Session

    timestamps()
  end

  @key_prefix_regex ~r/^[A-Z][A-Z0-9]{1,9}$/

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :directory,
      :deleted_at,
      :node,
      :env_allowlist,
      :commit_trailer,
      :key_prefix,
      :issue_counter
    ])
    |> validate_required([:name, :directory])
    |> OrcaHub.ClusterNodes.ClusterNode.validate_env_allowlist()
    |> validate_format(:key_prefix, @key_prefix_regex,
      message: "must be 2-10 uppercase letters/digits, starting with a letter"
    )
    |> unique_constraint(:key_prefix)
  end
end
