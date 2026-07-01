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
    * `:author` — the mention author's `Nostrum.Struct.User` (for the backfill
      prompt); optional
    * `:attachments` — the message's attachments (list of
      `%Nostrum.Struct.Message.Attachment{}`); may be empty

  Attachments are ALWAYS copied into the project's `inbox/` directory. The
  session is only invoked when there is non-empty text after the mention is
  stripped — a file-only mention just saves the files (and provisions the
  project if needed) without starting a conversation.

  Returns `:ok` when dispatched, `:ignore` when the mapping is disabled or
  provisioning fails. Safe to call from the gateway consumer — never raises.
  """
  def dispatch(%{channel_id: channel_id} = msg) do
    case HubRPC.get_discord_channel_by_channel_id(channel_id) do
      %{enabled: true, project: %{}} = mapping ->
        # Cascade-block: a thread is silenced when its parent channel mapping is
        # disabled. Uses the stored parent_channel_id (no Discord REST call).
        if parent_disabled?(mapping.parent_channel_id) do
          Logger.debug("Discord thread #{channel_id} parent is disabled, ignoring")
          :ignore
        else
          drive(mapping, msg)
          :ok
        end

      %{enabled: false} ->
        Logger.debug("Discord channel #{channel_id} mapping is disabled, ignoring")
        :ignore

      nil ->
        case provision(msg) do
          :ignore ->
            :ignore

          mapping ->
            drive(mapping, msg)
            :ok
        end
    end
  rescue
    e ->
      Logger.error("Discord bridge dispatch failed: #{Exception.message(e)}")
      :ignore
  end

  # True only when the parent channel HAS a mapping and it is disabled. A nil
  # parent_channel_id (top-level channel) or an unmapped parent is NOT blocked.
  defp parent_disabled?(nil), do: false

  defp parent_disabled?(parent_channel_id) do
    case HubRPC.get_discord_channel_by_channel_id(parent_channel_id) do
      %{enabled: false} -> true
      _ -> false
    end
  end

  defp drive(%{project: %{} = project} = mapping, %{message_id: message_id} = msg) do
    # Always save attachments first so a file-only mention still lands the files.
    saved = save_attachments(project, msg, message_id)

    text_len = String.length(String.trim(msg[:text] || ""))
    branch = if text_len == 0, do: "file_only", else: "converse"

    Logger.info(
      "Discord dispatch: channel=#{mapping.discord_channel_id} saved=#{length(saved)} text_len=#{text_len} branch=#{branch}"
    )

    if String.trim(msg[:text] || "") == "" do
      # File-only mention: no conversation. Do NOT advance the watermark, so the
      # backfill window stays open for the next text mention.
      :ok
    else
      session_id = resolve_session(mapping, project)
      runner_node = Cluster.project_node_for(project)

      HubRPC.set_discord_channel_session(mapping, session_id)

      unless Cluster.session_alive?(runner_node, session_id) do
        session = HubRPC.get_session(session_id)
        Cluster.start_session(runner_node, session_id, session)
      end

      Cluster.send_message(runner_node, session_id, build_prompt(mapping, msg, saved))
      capture_reply(session_id, mapping.discord_channel_id, message_id)
      # Advance the watermark only after a successful dispatch, so a failed send
      # (which raises out of here) leaves the backfill window open for a retry.
      update_watermark(mapping, message_id)
    end
  end

  # ------------------------------------------------------------------
  # Raw backfill on mention
  # ------------------------------------------------------------------
  #
  # Give the session the untagged channel messages posted since we last replied,
  # so it can answer questions that reference earlier context ("Call me Ishmael"
  # said untagged, then "@bot what should you call me?"). Bounded and defensive:
  # any Discord API failure falls back to sending just the mention text.

  defp build_prompt(mapping, %{text: text} = msg, saved) do
    base =
      case fetch_history(mapping, msg) do
        [] -> text
        history -> format_prompt(history, msg)
      end

    append_saved_files(base, saved)
  rescue
    e ->
      Logger.warning("Discord history backfill failed: #{Exception.message(e)}")
      append_saved_files(msg.text, saved)
  end

  # Tack the saved inbox paths onto the prompt so Claude knows the files landed.
  defp append_saved_files(prompt, []), do: prompt

  defp append_saved_files(prompt, saved) do
    """
    #{prompt}

    [Files saved to inbox/]
    #{Enum.join(saved, "\n")}
    """
    |> String.trim_trailing()
  end

  # Fetch the intervening messages via nostrum. We always page BACKWARDS from the
  # current mention (`{:before, message_id}`) so we get the messages closest to
  # it — the most recent `limit` when the gap is larger than the cap — then keep
  # only those newer than the watermark. Returns [] on any API error.
  #
  #   * watermark set  → cap 50, keep messages with id > watermark
  #   * watermark nil  → cap 20 (first mention: last 20 before this one)
  defp fetch_history(mapping, %{message_id: message_id}) do
    channel_id = String.to_integer(mapping.discord_channel_id)

    {limit, watermark} =
      case mapping.last_seen_message_id do
        nil -> {20, nil}
        wm -> {50, String.to_integer(wm)}
      end

    case Nostrum.Api.Channel.messages(channel_id, limit, {:before, message_id}) do
      {:ok, messages} ->
        messages
        |> filter_history(message_id, watermark)
        |> Enum.sort_by(& &1.id)

      {:error, reason} ->
        Logger.warning(
          "Discord history fetch failed for channel #{channel_id}: #{inspect(reason)}"
        )

        []
    end
  end

  # Drop our own bot's messages, the current mention itself, anything at/below
  # the watermark, and content-less messages (attachments/embeds) that would add
  # blank transcript lines.
  defp filter_history(messages, current_message_id, watermark) do
    bot_id = bot_id()

    Enum.filter(messages, fn m ->
      m.id != current_message_id and
        m.author.id != bot_id and
        (is_nil(watermark) or m.id > watermark) and
        String.trim(m.content || "") != ""
    end)
  end

  defp format_prompt(history, %{text: text} = msg) do
    transcript =
      history
      |> Enum.map_join("\n", fn m -> "#{display_name(m.author)}: #{m.content}" end)

    """
    [Channel messages since your last reply]
    #{transcript}

    [#{display_name(msg[:author])} mentioned you]: #{text}
    """
    |> String.trim_trailing()
  end

  # Prefer the Discord display name, fall back to username, then a neutral label.
  defp display_name(%{global_name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{username: name}) when is_binary(name) and name != "", do: name
  defp display_name(_), do: "someone"

  defp bot_id do
    case Nostrum.Cache.Me.get() do
      %{id: id} -> id
      _ -> nil
    end
  end

  # Never let a watermark write break dispatch — the reply is already on its way.
  defp update_watermark(mapping, message_id) do
    HubRPC.set_discord_channel_watermark(mapping, to_string(message_id))
  rescue
    e -> Logger.warning("Discord watermark update failed: #{Exception.message(e)}")
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
  # Attachments → inbox/
  # ------------------------------------------------------------------
  #
  # Copy every attachment on the mention into `<project.directory>/inbox/` so a
  # session can read them later. Runs on the Discord agent node, which owns the
  # shared mount, so local File writes + Req downloads work here. Each download
  # is isolated: a failure logs and is skipped, never crashing dispatch. On any
  # successful save we react ✅ to the triggering message as feedback.
  #
  # Returns the list of saved relative paths (e.g. "inbox/report.pdf").

  defp save_attachments(project, msg, message_id) do
    attachments = msg[:attachments] || []

    case attachments do
      [] ->
        []

      list ->
        inbox = Path.join(project.directory, "inbox")
        File.mkdir_p!(inbox)

        saved =
          Enum.reduce(list, [], fn attachment, acc ->
            case save_one(inbox, attachment, acc) do
              {:ok, rel} -> [rel | acc]
              :error -> acc
            end
          end)
          |> Enum.reverse()

        if saved != [], do: ack_reaction(msg, message_id)
        saved
    end
  end

  # Download a single attachment into `inbox`, avoiding collisions with anything
  # already saved this dispatch (`taken`, a list of "inbox/<name>" rel paths).
  # Returns {:ok, rel_path} or :error (logged) — never raises.
  defp save_one(inbox, attachment, taken) do
    name = unique_name(inbox, sanitize_filename(attachment.filename), attachment.id, taken)
    path = Path.join(inbox, name)

    %{body: body} = Req.get!(attachment.url)
    File.write!(path, body)
    {:ok, Path.join("inbox", name)}
  rescue
    e ->
      Logger.warning(
        "Discord attachment save failed (#{inspect(attachment.filename)}): " <>
          Exception.message(e)
      )

      :error
  end

  # Pick a name that collides with neither an existing file on disk nor one we
  # just wrote this dispatch. First tries the sanitized name, then appends the
  # Discord attachment id, then a numeric counter as a last resort.
  defp unique_name(inbox, base, attachment_id, taken) do
    candidates =
      [base, disambiguate(base, to_string(attachment_id))] ++
        Enum.map(1..50, fn n -> disambiguate(base, Integer.to_string(n)) end)

    Enum.find(candidates, fn name ->
      not File.exists?(Path.join(inbox, name)) and Path.join("inbox", name) not in taken
    end) || disambiguate(base, "#{attachment_id}-#{System.unique_integer([:positive])}")
  end

  # Insert `suffix` before the extension: "report.pdf" + "12" -> "report-12.pdf".
  defp disambiguate(base, suffix) do
    ext = Path.extname(base)
    stem = Path.basename(base, ext)
    "#{stem}-#{suffix}#{ext}"
  end

  @doc """
  Sanitize a Discord attachment filename into a safe `inbox/` basename.

  Takes the basename only (drops any path), whitelists alphanumerics plus
  `-`, `_`, and `.`, collapses every other run of characters to a single `-`,
  and strips leading/trailing separators. Falls back to `"file"` when the
  result is empty. The output can never be absolute or escape `inbox/`.
  """
  def sanitize_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]+/u, "-")
    |> String.trim("-")
    |> String.trim(".")
    |> case do
      "" -> "file"
      sanitized -> sanitized
    end
  end

  def sanitize_filename(_), do: "file"

  # React ✅ to acknowledge saved files. Fire-and-forget in a supervised task:
  # `save_attachments/3` runs on the critical path in `drive/2` BEFORE the session
  # is dispatched, and `Nostrum.Api.Message.react/3` is a synchronous call that can
  # BLOCK the caller when the reaction bucket's ratelimiter stalls (e.g. a Discord
  # server error → nostrum "holds off request queue pipelining"). Offloading it
  # keeps a slow/erroring reaction API from delaying or preventing the text+file
  # dispatch. Defensive inside the task too: a failed reaction (missing permission,
  # deleted message) must never crash anything.
  defp ack_reaction(msg, message_id) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      try do
        channel_id = String.to_integer(msg.channel_id)
        Nostrum.Api.Message.react(channel_id, message_id, "✅")
      rescue
        e -> Logger.warning("Discord ack reaction failed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  # ------------------------------------------------------------------
  # Auto-provisioning
  # ------------------------------------------------------------------

  # Provision an unmapped channel and return its mapping (with :project set), or
  # `:ignore` if a thread's parent channel is mapped-but-disabled (cascade-block).
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

  # Returns the thread mapping, or `:ignore` when the parent channel is mapped
  # but disabled (cascade-block — a disabled parent silences its threads). An
  # unmapped parent is provisioned (enabled) first, then the thread.
  defp provision_thread(channel_id, info, guild_id) do
    parent_id = to_string(info.parent_id)

    case HubRPC.get_discord_channel_by_channel_id(parent_id) do
      %{enabled: false} ->
        :ignore

      %{} = parent_mapping ->
        create_thread_mapping(channel_id, parent_id, parent_mapping)

      nil ->
        parent_mapping = provision_channel(parent_id, channel_info(parent_id), guild_id)
        create_thread_mapping(channel_id, parent_id, parent_mapping)
    end
  end

  defp create_thread_mapping(channel_id, parent_id, parent_mapping) do
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

  # Raw backfill on mention now exists (see build_prompt/2): each @-mention
  # includes the untagged messages posted since our last reply here.
  #
  # TODO: phase 2 periodic-read — the REMAINING phase-2 work is an agent-local
  # ROLLING SUMMARY: a separate module/cron would poll mapped channels for new
  # messages (without an @-mention) and maintain a running summary/context,
  # rather than only backfilling raw messages at mention time.
end
