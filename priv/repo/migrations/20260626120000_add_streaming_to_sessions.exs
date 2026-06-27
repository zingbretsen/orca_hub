defmodule OrcaHub.Repo.Migrations.AddStreamingToSessions do
  use Ecto.Migration

  # Per-session override for the long-lived streaming SessionRunner engine.
  # Nullable on purpose: NULL means "inherit the global :streaming_runner
  # default" (ORCA_STREAMING_RUNNER); true/false force the engine for one
  # session. Lets us canary streaming on a single session in prod without
  # flipping the global flag.
  def change do
    alter table(:sessions) do
      add :streaming, :boolean, default: nil
    end
  end
end
