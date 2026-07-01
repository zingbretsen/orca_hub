defmodule OrcaHub.Discord.Bot do
  @moduledoc """
  Discord gateway consumer for the all-in-one Discord worker.

  Holds the Discord gateway connection (via `nostrum`) and reacts to
  `MESSAGE_CREATE` events. For the MVP we handle the @-mention path only:
  when the bot is @-mentioned in a channel, we strip the mention and hand the
  message to `OrcaHub.Discord.Bridge`, which drives an OrcaHub session and
  posts the reply back.

  Every message is first screened against the guild allowlist
  (`OrcaHub.Discord.guild_allowed?/1`), which fails closed. This gate runs
  before dispatch, so it also protects the bridge's auto-provisioning.

  This process is a singleton across the cluster — it only runs on the node
  that has `DISCORD_BOT=true` (the dedicated Discord agent pod). See
  `OrcaHub.Application` for how it is gated into the supervision tree, and
  `mix.exs` for how nostrum is kept inert (no auto-connect) elsewhere.
  """

  use Nostrum.Consumer

  require Logger

  alias Nostrum.Cache.Me
  alias OrcaHub.Discord.Bridge

  @impl true
  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    if handle?(msg) do
      Logger.info(
        "Discord mention accepted: channel=#{msg.channel_id} raw_len=#{String.length(msg.content || "")} attachments=#{length(msg.attachments)}"
      )

      Bridge.dispatch(%{
        channel_id: to_string(msg.channel_id),
        message_id: msg.id,
        text: clean_content(msg.content, bot_id()),
        guild_id: msg.guild_id,
        author: msg.author,
        attachments: msg.attachments
      })
    end

    :noop
  end

  # Ignore anything we shouldn't act on:
  #   - messages from a guild not in the allowlist, or DMs (guild_id nil) —
  #     checked FIRST so an untrusted guild never reaches auto-provisioning
  #   - our own messages / other bots (avoid loops)
  #   - messages that don't @-mention us
  #   - messages with neither usable text (once the mention is stripped) nor any
  #     attachment — a file-only mention still passes so the files get saved
  def handle_event(_event), do: :noop

  defp handle?(msg) do
    id = bot_id()

    OrcaHub.Discord.guild_allowed?(msg.guild_id) and
      not is_nil(id) and
      not from_bot?(msg) and
      mentions_bot?(msg, id) and
      (String.trim(clean_content(msg.content, id)) != "" or msg.attachments != [])
  end

  defp bot_id do
    case Me.get() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp from_bot?(%{author: %{bot: true}}), do: true
  defp from_bot?(_), do: false

  defp mentions_bot?(%{mentions: mentions}, bot_id) when is_list(mentions) do
    Enum.any?(mentions, fn
      %{id: ^bot_id} -> true
      _ -> false
    end)
  end

  defp mentions_bot?(_, _), do: false

  # Strip the bot mention token (`<@id>` or `<@!id>`) and collapse whitespace.
  defp clean_content(nil, _bot_id), do: ""

  defp clean_content(content, bot_id) do
    content
    |> String.replace(~r/<@!?#{bot_id}>/, " ")
    |> String.trim()
    |> String.replace(~r/[ \t]+/, " ")
  end
end
