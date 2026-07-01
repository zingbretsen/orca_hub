defmodule OrcaHub.Repo.Migrations.AddParentChannelIdToDiscordChannels do
  use Ecto.Migration

  # Observability only: for a mapping that represents a Discord THREAD, record
  # the parent channel's snowflake. Thread mappings reuse the parent channel's
  # project (shared directory) but get their own session. Nullable — top-level
  # channel mappings leave it nil.
  def change do
    alter table(:discord_channels) do
      add :parent_channel_id, :string
    end

    create index(:discord_channels, [:parent_channel_id])
  end
end
