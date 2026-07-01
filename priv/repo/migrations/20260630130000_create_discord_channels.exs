defmodule OrcaHub.Repo.Migrations.CreateDiscordChannels do
  use Ecto.Migration

  # Maps a Discord channel to an OrcaHub project so the Discord worker can
  # drive a Claude session in response to @-mentions in that channel.
  #
  # - discord_channel_id: the Discord channel snowflake (stored as a string)
  # - project_id: supplies the working directory + node routing for sessions
  # - session_id: the current session driving this channel (nullable; reused
  #   while alive/ready/idle/error, otherwise a fresh one is created)
  # - enabled: gate — a disabled mapping causes mentions to be ignored
  #
  # Hub-only table; the Discord agent reads/writes via HubRPC.
  def change do
    create table(:discord_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :discord_channel_id, :string, null: false
      add :enabled, :boolean, null: false, default: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:discord_channels, [:discord_channel_id])
    create index(:discord_channels, [:project_id])
  end
end
