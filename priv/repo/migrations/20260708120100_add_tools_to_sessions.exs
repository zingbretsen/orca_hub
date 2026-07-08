defmodule OrcaHub.Repo.Migrations.AddToolsToSessions do
  use Ecto.Migration

  # Per-session `--tools` override (Agent Runs API "no filesystem tools"
  # mode, docs/api.md). nil = inherit the orchestrator-flag-derived default;
  # "" restricts the Claude CLI to zero built-in tools. Takes precedence over
  # the orchestrator toolset when set — see Backend.Claude.spawn_spec/2.
  def change do
    alter table(:sessions) do
      add :tools, :string
    end
  end
end
