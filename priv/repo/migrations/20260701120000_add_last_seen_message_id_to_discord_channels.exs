defmodule OrcaHub.Repo.Migrations.AddLastSeenMessageIdToDiscordChannels do
  use Ecto.Migration

  # Mention watermark: the snowflake of the last message we replied to in this
  # channel/thread. On the next @-mention, the bridge backfills the untagged
  # messages posted AFTER this id so the session has conversational context.
  # Nullable — nil means "never replied here yet" (first-mention backfill).
  def change do
    alter table(:discord_channels) do
      add :last_seen_message_id, :string
    end
  end
end
