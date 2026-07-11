defmodule OrcaHub.Repo.Migrations.AddIdempotencyKeyToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :idempotency_key, :string
    end

    create index(:sessions, [:idempotency_key])
  end
end
