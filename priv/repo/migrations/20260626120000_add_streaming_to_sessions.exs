defmodule OrcaHub.Repo.Migrations.AddStreamingToSessions do
  use Ecto.Migration

  # Per-session override for the long-lived streaming SessionRunner engine.
  # Nullable on purpose: NULL means "inherit the global default" (streaming
  # unless the ORCA_DISABLE_STREAMING kill switch is set); true/false force the
  # engine for one session. Lets us pin individual sessions independent of the
  # global default.
  def change do
    alter table(:sessions) do
      add :streaming, :boolean, default: nil
    end
  end
end
