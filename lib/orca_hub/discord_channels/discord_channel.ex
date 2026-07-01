defmodule OrcaHub.DiscordChannels.DiscordChannel do
  @moduledoc "Schema mapping a Discord channel to an OrcaHub project + session."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_channels" do
    field :discord_channel_id, :string
    field :enabled, :boolean, default: true

    belongs_to :project, OrcaHub.Projects.Project
    belongs_to :session, OrcaHub.Sessions.Session

    timestamps()
  end

  def changeset(discord_channel, attrs) do
    discord_channel
    |> cast(attrs, [:discord_channel_id, :enabled, :project_id, :session_id])
    |> validate_required([:discord_channel_id, :project_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint(:discord_channel_id)
  end
end
