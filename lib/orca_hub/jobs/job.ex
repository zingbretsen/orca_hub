defmodule OrcaHub.Jobs.Job do
  @moduledoc """
  Schema for a durable, detached background job (ORCAHUB3-25) — see
  `OrcaHub.Jobs` moduledoc for the full subsystem design.

  Status ladder: `running -> verifying -> succeeded | failed |
  verification_failed | timed_out | cancelled`. `verifying` is only ever
  entered when the main command exits 0 AND `verify_command` is present;
  `pid`/`pgid` are reused across phases — they always refer to whichever OS
  process is CURRENTLY being watched (the main command's, then the verify
  command's), while `exit_code`/`verify_exit_code` are separate columns so
  neither phase's result overwrites the other's.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running verifying succeeded failed verification_failed timed_out cancelled)
  @nonterminal_statuses ~w(running verifying)
  @progress_kinds ~w(file_bytes command)

  schema "jobs" do
    field :session_id, :binary_id
    field :directory, :string
    field :runner_node, :string
    field :label, :string
    field :command, :string
    field :verify_command, :string

    field :status, :string, default: "running"
    field :pid, :integer
    field :pgid, :integer
    field :exit_code, :integer
    field :verify_exit_code, :integer

    field :log_path, :string
    field :sentinel_path, :string

    field :progress_kind, :string
    field :progress_path, :string
    field :progress_expect_bytes, :integer
    field :progress_command, :string
    field :progress_value, :float
    field :progress_total, :float
    field :progress_note, :string
    field :progress_updated_at, :utc_datetime

    field :timeout_seconds, :integer
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps()
  end

  @doc "Non-terminal statuses — a job in one of these is still being watched."
  def nonterminal_statuses, do: @nonterminal_statuses

  @doc "Every valid status."
  def statuses, do: @statuses

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :session_id,
      :directory,
      :runner_node,
      :label,
      :command,
      :verify_command,
      :status,
      :pid,
      :pgid,
      :exit_code,
      :verify_exit_code,
      :log_path,
      :sentinel_path,
      :progress_kind,
      :progress_path,
      :progress_expect_bytes,
      :progress_command,
      :progress_value,
      :progress_total,
      :progress_note,
      :progress_updated_at,
      :timeout_seconds,
      :started_at,
      :finished_at
    ])
    |> validate_required([:directory, :runner_node, :command])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:progress_kind, @progress_kinds, message: "is invalid")
    |> validate_number(:timeout_seconds, greater_than: 0)
  end
end
