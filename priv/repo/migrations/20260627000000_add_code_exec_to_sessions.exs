defmodule OrcaHub.Repo.Migrations.AddCodeExecToSessions do
  use Ecto.Migration

  # Per-session opt-in for "code execution with MCP" mode. Dark by default:
  # NOT NULL with a `false` default so existing sessions and new sessions are
  # unaffected until explicitly enabled. Globally killable via the
  # ORCA_DISABLE_CODE_EXEC env switch (resolved at MCP connection time).
  def change do
    alter table(:sessions) do
      add :code_exec, :boolean, default: false, null: false
    end
  end
end
