defmodule OrcaHub.Discord.Bridge do
  @moduledoc """
  Maps a Discord channel to an OrcaHub session and drives it.

  When the Discord worker sees an @-mention (see `OrcaHub.Discord.Bot`), it
  calls `dispatch/1`. We look up the channel → project mapping (auto-provisioning
  one if the channel is unmapped), resolve or create a session for that project
  (mirroring `OrcaHub.TriggerExecutor`), send the message, then capture the
  assistant's reply in a supervised task and post it back to the channel.

  ## Auto-provisioning

  The guild allowlist is enforced upstream in `OrcaHub.Discord.Bot`, so any
  message reaching here is from a trusted guild. An @-mention in an UNMAPPED
  channel provisions it lazily:

    * **Top-level channel** → create a directory under `/home/orca/discord`
      named `<slug>-<channel_id>`, a Project tagged to THIS Discord node, and an
      enabled mapping.
    * **Thread** → ensure the PARENT channel is provisioned first, then create a
      mapping for the thread that REUSES the parent's project (shared directory)
      but gets its own session — a separate conversation in the same project.

  A channel that is explicitly mapped with `enabled: false` stays ignored and is
  NOT re-provisioned.

  All database access goes through `OrcaHub.HubRPC` so this works from the
  Discord agent node (which has no local database). Directory creation happens
  locally, since the bridge runs on the node that owns the shared mount.
  """

  require Logger

  alias OrcaHub.{Cluster, HubRPC}

  # Root of the isolated shared subtree for Discord-provisioned projects. Must
  # match the container mountPath in the orca-agent-discord k3s manifest.
  @discord_root "/home/orca/discord"

  # Discord channel `type` values that denote a thread (news/public/private).
  @thread_types [10, 11, 12]

  # Discord's hard limit on a single message's content length.
  @discord_max_len 2000

  # How long we wait for the session to go idle before giving up on the reply.
  @reply_timeout :timer.minutes(30)

  @doc """
  Handle an @-mention. `msg` is a plain map with:

    * `:channel_id` — Discord channel snowflake, as a string
    * `:message_id` — the triggering message id (for the reply reference)
    * `:text` — the message content with the bot mention stripped
    * `:guild_id` — the guild snowflake (integer), for provisioning metadata

  Returns `:ok` when dispatched, `:ignore` when the mapping is disabled or
  provisioning fails. Safe to call from the gateway consumer — never raises.
  """
  def dispatch(%{channel_id: channel_id} = msg) do
    case HubRPC.get_discord_channel_by_channel_id(channel_id) do
      %{enabled: true, project: %{}} = mapping ->
        drive(mapping, msg)
        :ok

      %{enabled: false} ->
        Logger.debug("Discord channel #{channel_id} mapping is disabled, ignoring")
        :ignore

      nil ->
        drive(provision(msg), msg)
        :ok
    end
  rescue
    e ->
      Logger.error("Discord bridge dispatch failed: #{Exception.message(e)}")
      :ignore
  end

  defp drive(%{project: %{} = project} = mapping, %{message_id: message_id, text: text}) do
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

  # ------------------------------------------------------------------
  # Auto-provisioning
  # ------------------------------------------------------------------

  # Provision an unmapped channel and return its mapping (with :project set).
  # Threads reuse the parent channel's project; top-level channels get their own.
  defp provision(%{channel_id: channel_id, guild_id: guild_id}) do
    info = channel_info(channel_id)

    if info.thread? and not is_nil(info.parent_id) do
      provision_thread(channel_id, info, guild_id)
    else
      provision_channel(channel_id, info, guild_id)
    end
  end

  defp provision_channel(channel_id, info, guild_id) do
    dir = channel_dir(info.name, channel_id)
    File.mkdir_p!(dir)

    {:ok, project} =
      HubRPC.create_project(%{
        name: project_name(info, guild_id),
        directory: dir,
        node: Atom.to_string(node())
      })

    case HubRPC.create_discord_channel(%{
           discord_channel_id: channel_id,
           project_id: project.id,
           enabled: true
         }) do
      {:ok, mapping} ->
        %{mapping | project: project}

      {:error, %Ecto.Changeset{} = cs} ->
        # Lost a create race: a concurrent mention provisioned this channel
        # first. Roll back our now-orphaned project and use the winner's mapping.
        if unique_conflict?(cs, :discord_channel_id) do
          HubRPC.delete_project(project)
          HubRPC.get_discord_channel_by_channel_id(channel_id)
        else
          raise "discord_channels insert failed: #{inspect(cs.errors)}"
        end
    end
  end

  defp provision_thread(channel_id, info, guild_id) do
    parent_id = to_string(info.parent_id)

    parent_mapping =
      case HubRPC.get_discord_channel_by_channel_id(parent_id) do
        %{} = mapping -> mapping
        nil -> provision_channel(parent_id, channel_info(parent_id), guild_id)
      end

    case HubRPC.create_discord_channel(%{
           discord_channel_id: channel_id,
           project_id: parent_mapping.project_id,
           parent_channel_id: parent_id,
           enabled: true
         }) do
      {:ok, mapping} ->
        %{mapping | project: parent_mapping.project}

      {:error, %Ecto.Changeset{} = cs} ->
        if unique_conflict?(cs, :discord_channel_id) do
          HubRPC.get_discord_channel_by_channel_id(channel_id)
        else
          raise "discord_channels (thread) insert failed: #{inspect(cs.errors)}"
        end
    end
  end

  # Fetch channel type/parent/name from Discord. Falls back to a safe top-level
  # shape if the lookup fails so provisioning can still proceed.
  defp channel_info(channel_id) do
    case Nostrum.Api.Channel.get(String.to_integer(channel_id)) do
      {:ok, %{type: type, parent_id: parent_id, name: name}} ->
        %{name: name, thread?: type in @thread_types, parent_id: parent_id}

      _ ->
        %{name: nil, thread?: false, parent_id: nil}
    end
  end

  # Stable per-channel directory: <slug>-<channel_id>. The channel_id suffix
  # guarantees uniqueness and survives channel renames.
  defp channel_dir(name, channel_id) do
    Path.join(@discord_root, "#{slug(name)}-#{channel_id}")
  end

  defp project_name(%{name: name}, guild_id) do
    channel = if name in [nil, ""], do: "#discord", else: "##{name}"

    case guild_name(guild_id) do
      nil -> channel
      gname -> "#{gname} / #{channel}"
    end
  end

  defp guild_name(nil), do: nil

  defp guild_name(guild_id) do
    Nostrum.Cache.GuildCache.get!(guild_id).name
  rescue
    _ -> nil
  end

  defp slug(nil), do: "channel"

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "channel"
      s -> s
    end
  end

  defp unique_conflict?(%Ecto.Changeset{errors: errors}, field) do
    case errors[field] do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
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
