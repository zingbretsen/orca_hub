defmodule OrcaHub.Repo.Migrations.AddThinkingLevelToSessions do
  use Ecto.Migration

  # ORCAHUB3-67: per-session thinking level, stored as the RAW preset value
  # of the session's backend (Claude `--effort high`, Codex `effort: "xhigh"`,
  # pi `--thinking low`), not a normalized scale. nil = the backend's own
  # default. Each adapter drops a value that is not one of its presets at
  # spawn time, so a stale value after a backend/model switch is harmless.
  def change do
    alter table(:sessions) do
      add :thinking_level, :string
    end
  end
end
