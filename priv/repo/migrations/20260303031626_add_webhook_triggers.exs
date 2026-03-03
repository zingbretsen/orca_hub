defmodule OrcaHub.Repo.Migrations.AddWebhookTriggers do
  use Ecto.Migration

  def change do
    alter table(:triggers) do
      add :type, :string, null: false, default: "scheduled"
      add :webhook_secret, :string
      modify :cron_expression, :string, null: true, from: {:string, null: false}
    end

    create unique_index(:triggers, [:webhook_secret])
  end
end
