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
    # Which agent-CLI backend runs this session (backend_abstraction_spec.md
    # §4). "codex" is a valid data-layer value ahead of its Phase 2 adapter;
    # the UI only offers backends from `OrcaHub.Backend.available/0`.
    field :backend, :string, default: "claude"
    field :archived_at, :utc_datetime
    field :triggered, :boolean, default: false
    field :priority, :integer, default: 0
    field :runner_node, :string
    field :original_node, :string
    field :orchestrator, :boolean, default: false
    # "Code execution with MCP" mode — collapses this session's MCP
    # tools/list to the run_elixir meta-tool and exposes every other
    # tool as a generated `Tools.*` function. ON by
    # default for new sessions; still opt-OUT per session, and globally
    # killable node-wide via ORCA_DISABLE_CODE_EXEC.
    field :code_exec, :boolean, default: true
    field :parent_session_id, :binary_id
    # Whether a running->idle/running->error turn-end transition should
    # notify `parent_session_id` (fire-and-forget spawns want this off).
    # Meaningless without a parent_session_id. See SessionRunner's
    # maybe_notify_parent/2.
    field :notify_parent, :boolean, default: true
    # nil = inherit global default (streaming unless ORCA_DISABLE_STREAMING set);
    # true/false force the engine for this session
    field :streaming, :boolean
    # Per-session `--tools` override (Agent Runs API "no filesystem tools"
    # mode). nil = inherit the orchestrator-derived default; "" restricts the
    # Claude CLI to zero built-in tools. See Backend.Claude.spawn_spec/2.
    field :tools, :string
    # Concise launch/exit failure detail (last stderr/output lines, or a
    # turn-level error message), truncated. Set when status becomes "error";
    # cleared when a later run succeeds. See SessionRunner.handle_cli_error/2.
    field :error_detail, :string
    # Self-reported phase (e.g. "planning", "implementing") set by the
    # report_progress MCP tool — a coarse, non-interrupting progress signal
    # distinct from `status`. Cleared at the start of every new turn (see
    # SessionRunner's resume_clears_waiting/start_running/start_streaming) so
    # a stale phase from a prior turn can't survive into a fresh run.
    field :progress_phase, :string
    field :progress_note, :string
    field :progress_updated_at, :utc_datetime
    # Caller-supplied dedup key for start_session (Agent Runs API and
    # orchestrator retries): a repeat start_session with the same key against
    # a non-archived session returns that session instead of spawning a
    # duplicate. Not unique at the DB level — archived sessions with the same
    # key are ignored by that lookup, not deleted.
    field :idempotency_key, :string

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
      :backend,
      :project_id,
      :archived_at,
      :triggered,
      :priority,
      :runner_node,
      :original_node,
      :orchestrator,
      :code_exec,
      :parent_session_id,
      :notify_parent,
      :streaming,
      :error_detail,
      :progress_phase,
      :progress_note,
      :progress_updated_at,
      :idempotency_key
    ])
    # Cast separately with empty_values: [] — cast/4's default empty_values
    # ([""]) would otherwise silently turn an explicit `tools: ""` (the "no
    # built-in tools" API run mode, see field doc above) into nil, indistinguishable
    # from "not set".
    |> cast(attrs, [:tools], empty_values: [])
    |> validate_required([:directory])
    |> validate_inclusion(:status, ~w(ready idle running waiting error compacting))
    |> validate_inclusion(:backend, ~w(claude codex pi))
  end
end
