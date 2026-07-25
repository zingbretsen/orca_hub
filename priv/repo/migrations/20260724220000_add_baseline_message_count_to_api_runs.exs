defmodule OrcaHub.Repo.Migrations.AddBaselineMessageCountToApiRuns do
  use Ecto.Migration

  # Snapshot of the session's message count taken right before a run's
  # prompt is delivered (see ApiRunController.create_continuation_run/5).
  # Lets GET /api/v1/runs/:id tell "session is idle because THIS run's turn
  # already finished" apart from "session is idle because it hasn't started
  # processing this run's turn yet" — the latter matters for continuations,
  # whose target session can already be idle (from a PREVIOUS turn) the
  # instant the prompt is delivered.
  def change do
    alter table(:api_runs) do
      add :baseline_message_count, :integer, null: false, default: 0
    end
  end
end
