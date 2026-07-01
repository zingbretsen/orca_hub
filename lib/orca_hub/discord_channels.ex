defmodule OrcaHub.DiscordChannels do
  @moduledoc """
  Context for Discord channel → project/session mappings.

  An admin maps a Discord channel to a project; the project supplies the
  working directory and node routing for the sessions that the Discord worker
  drives (see `OrcaHub.Discord.Bridge`).

  This module talks to the database directly and therefore only runs on the
  hub. Callers on any node (including the Discord agent) must go through
  `OrcaHub.HubRPC`.
  """

  import Ecto.Query

  alias OrcaHub.DiscordChannels.DiscordChannel
  alias OrcaHub.Repo

  @doc "List all channel mappings, newest first, with project preloaded."
  def list_discord_channels do
    Repo.all(from c in DiscordChannel, order_by: [desc: c.inserted_at], preload: [:project])
  end

  def get_discord_channel!(id), do: Repo.get!(DiscordChannel, id) |> Repo.preload(:project)

  @doc """
  Look up a mapping by its Discord channel snowflake. Returns the mapping with
  its project preloaded, or `nil` if there is none.
  """
  def get_by_channel_id(discord_channel_id) when is_binary(discord_channel_id) do
    case Repo.get_by(DiscordChannel, discord_channel_id: discord_channel_id) do
      nil -> nil
      channel -> Repo.preload(channel, :project)
    end
  end

  def create_discord_channel(attrs) do
    %DiscordChannel{}
    |> DiscordChannel.changeset(attrs)
    |> Repo.insert()
  end

  def update_discord_channel(%DiscordChannel{} = channel, attrs) do
    channel
    |> DiscordChannel.changeset(attrs)
    |> Repo.update()
  end

  def delete_discord_channel(%DiscordChannel{} = channel), do: Repo.delete(channel)

  def change_discord_channel(%DiscordChannel{} = channel, attrs \\ %{}),
    do: DiscordChannel.changeset(channel, attrs)

  @doc "Set the current session for a channel mapping (used by the bridge)."
  def set_session(%DiscordChannel{} = channel, session_id) do
    channel
    |> DiscordChannel.changeset(%{session_id: session_id})
    |> Repo.update()
  end
end
