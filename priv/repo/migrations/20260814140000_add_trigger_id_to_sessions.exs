defmodule OrcaHub.Repo.Migrations.AddTriggerIdToSessions do
  @moduledoc """
  Links a session back to the trigger that created it — previously
  `triggers.last_session_id` only ever pointed at the MOST RECENT session
  for a trigger, so there was no way to list every session a trigger had
  ever spawned. `TriggerExecutor.create_new_session/1` now stamps this at
  creation time; this migration backfills existing rows in two passes:

  1. Exact: for every trigger with a non-nil `last_session_id`, stamp that
     one session — this is unambiguous, `last_session_id` names an exact
     session row.
  2. Heuristic: for sessions that still have no `trigger_id`, match on
     `sessions.triggered = true AND sessions.project_id = t.project_id AND
     sessions.title = 'Trigger: ' || t.name` (the title format
     `create_new_session/1` has always used). This is restricted to
     triggers whose `(project_id, name)` pair is UNIQUE among all triggers
     — if two triggers in the same project share a name, their sessions'
     titles are indistinguishable, so guessing would risk mis-attributing
     a session to the wrong trigger. Ambiguous triggers are simply left
     for their sessions' `trigger_id` to stay NULL (matches pre-migration
     behavior: no worse than before).
  """

  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :trigger_id, references(:triggers, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:sessions, [:trigger_id])

    flush()

    # Pass 1: exact match via triggers.last_session_id.
    execute(
      """
      UPDATE sessions
      SET trigger_id = triggers.id
      FROM triggers
      WHERE triggers.last_session_id = sessions.id
        AND sessions.trigger_id IS NULL
      """,
      ""
    )

    # Pass 2: heuristic match by title, restricted to triggers whose
    # (project_id, name) pair is unique so an ambiguous name can never
    # mis-attribute a session to the wrong trigger.
    execute(
      """
      UPDATE sessions
      SET trigger_id = t.id
      FROM triggers t
      WHERE sessions.trigger_id IS NULL
        AND sessions.triggered = true
        AND sessions.project_id = t.project_id
        AND sessions.title = 'Trigger: ' || t.name
        AND (
          SELECT count(*) FROM triggers t2
          WHERE t2.project_id = t.project_id AND t2.name = t.name
        ) = 1
      """,
      ""
    )
  end
end
