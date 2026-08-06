defmodule OrcaHub.Issues.Issue do
  @moduledoc """
  Schema for an issue — a durable, agent-usable work item (issues_spec.md).

  Originally removed in `3ebb3fe`, then minimally reintroduced to back the
  `file_feature_request` MCP tool. This schema now carries the full field
  set from the spec: per-project short keys (`key_number`, rendered
  alongside the owning project's `key_prefix`), `kind` (replacing the old
  `[agent-fr] ` title-prefix hack), `plan`/`premise`/`resolution` narrative
  fields, `commits`/`attempts` (frozen at close only — see
  `OrcaHub.Issues.derive_commits/1` and `derive_attempt_summary/1`),
  session-identity provenance (`created_by_session_id`/
  `closed_by_session_id`), `closed_at`, and `superseded_by_issue_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "issues" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "open"
    field :approaches_tried, :string
    field :notes, :string

    # "task" (work against the filer's own project) or "feature_request"
    # (platform friction filed against OrcaHub itself) — see §3.1.
    field :kind, :string, default: "task"
    # Per-project sequence number; combined with the owning project's
    # key_prefix to render a short key like "ORCA-142" (§3.2). Assigned
    # once at creation via OrcaHub.Issues.create_issue/1's atomic
    # allocation — never recomputed, stays stable even if the issue's
    # project_id is later changed.
    field :key_number, :integer

    # Mutable, orchestrator-owned — the one field designed to be
    # rewritten in place as understanding develops (§10 resume hook).
    field :plan, :string
    # Written once at close_issue time; amendable afterward, but the
    # prior value is always preserved first, never silently overwritten
    # (§6.4). Narrative of what actually happened.
    field :resolution, :string
    # The assumption that makes this issue worth doing — deliberately
    # separate from `resolution` so a memory audit can query it
    # independently (§3.1.1). Also amendable post-close under the same
    # preserve-then-append rule as `resolution`.
    field :premise, :string

    # Frozen at close only (OrcaHub.Issues.derive_commits/1, §4.2) —
    # [%{hash, short_hash, subject, author, date}]. Empty ([]) while
    # open; derived live instead. Cleared back to [] on reopen (§3.5.1).
    field :commits, {:array, :map}, default: []
    # Frozen at close only (OrcaHub.Issues.derive_attempt_summary/1,
    # §4.3) — [%{session_id, status, outcome}]. Empty while open; the
    # rich live projection (OrcaHub.Issues.live_attempts/1) is used
    # instead. Cleared back to [] on reopen.
    field :attempts, {:array, :map}, default: []

    # Set once, at creation — the orchestrator-facing identity link
    # (§3.4). An orchestrator routinely touches many issues in one
    # session and has no single "the issue I'm attempting", so this is
    # provenance ("who filed this"), not an attempt link.
    field :created_by_session_id, :binary_id
    # Set at close_issue time; cleared on reopen (prior value preserved
    # in the auto-appended note first — §3.5.1).
    field :closed_by_session_id, :binary_id
    # Dedicated close marker, distinct from `updated_at` (which a
    # post-close amendment would otherwise also bump) — set only by
    # close_issue, cleared only by reopen.
    field :closed_at, :utc_datetime
    # "Replaced by ORCA-201" — structured and queryable rather than
    # buried in resolution prose (§3.1.2). Settable regardless of this
    # issue's own status; NOT cleared by reopen (§3.5.1 step 2).
    field :superseded_by_issue_id, :binary_id

    belongs_to :project, OrcaHub.Projects.Project, type: :binary_id

    timestamps()
  end

  @statuses ~w(open in_progress closed abandoned)
  @kinds ~w(task feature_request)

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :project_id,
      :approaches_tried,
      :notes,
      :kind,
      :key_number,
      :plan,
      :resolution,
      :premise,
      :commits,
      :attempts,
      :created_by_session_id,
      :closed_by_session_id,
      :closed_at,
      :superseded_by_issue_id
    ])
    |> validate_required([:title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_self_reference()
    |> unique_constraint([:project_id, :key_number])
    |> foreign_key_constraint(:created_by_session_id)
    |> foreign_key_constraint(:closed_by_session_id)
    |> foreign_key_constraint(:superseded_by_issue_id)
  end

  # An issue can't supersede itself (issues_spec.md §14 risk 10) — a
  # genuine A -> B -> A cycle across two different issues is an accepted
  # gap, not guarded against here; see the spec section for why.
  defp validate_self_reference(changeset) do
    validate_change(changeset, :superseded_by_issue_id, fn :superseded_by_issue_id, value ->
      if value != nil and value == changeset.data.id do
        [superseded_by_issue_id: "an issue cannot supersede itself"]
      else
        []
      end
    end)
  end
end
