defmodule OrcaHub.Discord.Bridge do
  @moduledoc """
  Maps a Discord channel to an OrcaHub session and drives it.

  When the Discord worker sees an @-mention (see `OrcaHub.Discord.Bot`), it
  calls `dispatch/1`. We look up the channel → project mapping, resolve or
  create a session for that project (mirroring `OrcaHub.TriggerExecutor`),
  send the message, then capture the assistant's reply in a supervised task
  and post it back to the channel.

  All database access goes through `OrcaHub.HubRPC` so this works from the
  Discord agent node (which has no local database).
  """

  require Logger

  alias OrcaHub.{Cluster, HubRPC}

  # Discord's hard limit on a single message's content length.
  @discord_max_len 2000

  # How long we wait for the session to go idle before giving up on the reply.
  @reply_timeout :timer.minutes(30)

  @doc """
  Handle an @-mention. `msg` is a plain map with:

    * `:channel_id` — Discord channel snowflake, as a string
    * `:message_id` — the triggering message id (for the reply reference)
    * `:text` — the message content with the bot mention stripped

  Returns `:ok` when dispatched, `:ignore` when there is no enabled mapping.
  Safe to call from the gateway consumer — never raises.
  """
  def dispatch(%{channel_id: channel_id, message_id: message_id, text: text}) do
    case HubRPC.get_discord_channel_by_channel_id(channel_id) do
      %{enabled: true, project: %{} = project} = mapping ->
        drive(mapping, project, message_id, text)
        :ok

      %{enabled: false} ->
        Logger.debug("Discord channel #{channel_id} mapping is disabled, ignoring")
        :ignore

      _ ->
        Logger.debug("No Discord channel mapping for #{channel_id}, ignoring")
        :ignore
    end
  rescue
    e ->
      Logger.error("Discord bridge dispatch failed: #{Exception.message(e)}")
      :ignore
  end

  defp drive(mapping, project, message_id, text) do
    session_id = resolve_session(mapping, project)
    runner_node = Cluster.project_node_for(project)

    HubRPC.set_discord_channel_session(mapping, session_id)

    unless Cluster.session_alive?(runner_node, session_id) do
      session = HubRPC.get_session(session_id)
      Cluster.start_session(runner_node, session_id, session)
    end

    Cluster.send_message(runner_node, session_id, text)
    capture_reply(session_id, mapping.discord_channel_id, message_id)
  end

  # Reuse the current session if it exists and is in a resumable state,
  # otherwise create a fresh one (mirrors TriggerExecutor.resolve_session).
  defp resolve_session(%{session_id: session_id}, project) when not is_nil(session_id) do
    case HubRPC.get_session(session_id) do
      %{archived_at: nil, status: status} when status in ["ready", "idle", "error"] ->
        session_id

      _ ->
        create_new_session(project)
    end
  end

  defp resolve_session(_mapping, project), do: create_new_session(project)

  defp create_new_session(project) do
    runner_node = Cluster.project_node_for(project)

    {:ok, session} =
      HubRPC.create_session(%{
        directory: project.directory,
        project_id: project.id,
        title: "Discord: ##{project.name}",
        status: "ready",
        triggered: true,
        runner_node: Atom.to_string(runner_node)
      })

    session.id
  end

  # Subscribe to the session's PubSub topic in a supervised task and post the
  # last assistant message back to Discord once the session goes idle/error.
  # Runs off the gateway consumer so a slow session never blocks event handling.
  # (Mirrors TriggerExecutor.subscribe_for_completion.)
  defp capture_reply(session_id, discord_channel_id, message_id) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session_id}")
      wait_for_reply(session_id, discord_channel_id, message_id)
    end)
  end

  defp wait_for_reply(session_id, discord_channel_id, message_id) do
    receive do
      {:status, status} when status in [:idle, :error] ->
        post_reply(session_id, discord_channel_id, message_id)

      _ ->
        wait_for_reply(session_id, discord_channel_id, message_id)
    after
      @reply_timeout ->
        Logger.warning("Discord reply capture timed out for session #{session_id}")
    end
  end

  defp post_reply(session_id, discord_channel_id, message_id) do
    channel_id = String.to_integer(discord_channel_id)

    case HubRPC.last_assistant_text(session_id) do
      nil ->
        Logger.info("Discord session #{session_id} produced no assistant text to post")

      text ->
        text
        |> chunk(@discord_max_len)
        |> post_chunks(channel_id, message_id)
    end
  rescue
    e ->
      Logger.error("Discord reply post failed for #{session_id}: #{Exception.message(e)}")
  end

  # First chunk is posted as a reply to the triggering message; the rest as
  # plain follow-up messages in the same channel.
  defp post_chunks([first | rest], channel_id, message_id) do
    Nostrum.Api.Message.create(channel_id,
      content: first,
      message_reference: %{message_id: message_id}
    )

    Enum.each(rest, fn chunk ->
      Nostrum.Api.Message.create(channel_id, content: chunk)
    end)
  end

  defp post_chunks([], _channel_id, _message_id), do: :ok

  @doc """
  Split `text` into a list of chunks no longer than `max` characters, breaking
  on line boundaries where possible so code/prose stays readable.
  """
  def chunk(text, max) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc -> pack_line(line, acc, max) end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  # A single line longer than the limit is hard-split into fixed-size pieces.
  defp pack_line(line, acc, max) when byte_size(line) > max do
    pieces = hard_split(line, max)
    Enum.reduce(pieces, acc, fn piece, inner -> [piece | inner] end)
  end

  defp pack_line(line, [current | rest], max)
       when byte_size(current) + byte_size(line) + 1 <= max do
    [current <> "\n" <> line | rest]
  end

  defp pack_line(line, acc, _max), do: [line | acc]

  defp hard_split(line, max) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(max)
    |> Enum.map(&Enum.join/1)
  end

  # TODO: phase 2 periodic-read — a separate module/cron would poll mapped
  # channels for new messages (without an @-mention) and feed them in here via
  # the same resolve/send/capture path. Hook it in by calling `dispatch/1`
  # (or a sibling function) with the polled message.
end
