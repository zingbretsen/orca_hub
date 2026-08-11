defmodule OrcaHubWeb.QueueLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{AskUserQuestion, Cluster, HubRPC}
  alias OrcaHubWeb.{Markdown, NodeFilter}

  import OrcaHubWeb.AskUserQuestionComponent

  @impl true
  def mount(_params, _session, socket) do
    node_filter = socket.assigns.node_filter
    queue_filter = :all
    {entries, node_map, aq_questions} = load_entries_with_nodes(node_filter, queue_filter)

    if connected?(socket) do
      for {session, _msg} <- entries do
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
      end

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {:ok,
     socket
     |> assign(:entries, entries)
     |> assign(:node_map, node_map)
     |> assign(:aq_questions, aq_questions)
     |> assign(:aq_state, %{})
     |> assign(:clustered, Node.list() != [])
     |> assign(:prompt, "")
     |> assign(:form_key, 0)
     |> assign(:show_all, false)
     |> assign(:tts_autoplay, false)
     |> assign(:page_title, "Queue")
     |> assign(:undo_archive_session, nil)
     |> assign(:undo_archive_timer, nil)
     |> assign(:queue_filter, queue_filter)
     |> maybe_push_tts_config()}
  end

  # ORCAHUB3-29: every send_message-style event below uses :queue delivery
  # (this page only lists idle-ish sessions — the human reviewing the queue
  # already has a dedicated Stop/Interrupt action on the session page if a
  # send genuinely needs to cancel in-flight work). `{:queued, status}` is
  # exactly as much a success as `:ok` from here — the message still
  # arrives, just deferred to the target's turn end — so both route to
  # `on_success`, keeping the 9 near-identical call sites below from each
  # growing an extra clause.
  defp handle_delivery_result(:ok, _socket, on_success), do: on_success.()
  defp handle_delivery_result({:queued, _status}, _socket, on_success), do: on_success.()

  defp handle_delivery_result({:error, :busy}, socket, _on_success) do
    {:noreply, put_flash(socket, :error, "Session is busy")}
  end

  defp handle_delivery_result({:error, reason}, socket, _on_success) do
    message =
      Cluster.node_unavailable_message(reason) || "Failed to send message: #{inspect(reason)}"

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_event("archive", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    session = Cluster.get_session!(node, id)
    Cluster.archive_session(node, session)

    socket =
      socket
      |> assign(:entries, reject_session(socket.assigns.entries, id))
      |> schedule_undo_archive(id)

    {:noreply, socket}
  end

  def handle_event("undo_archive", _params, socket) do
    if session_id = socket.assigns.undo_archive_session do
      node = Map.get(socket.assigns.node_map, session_id, node())
      session = Cluster.get_session!(node, session_id)
      Cluster.unarchive_session(node, session)

      {entries, node_map, aq_questions} =
        load_entries_with_nodes(socket.assigns.node_filter, socket.assigns.queue_filter)

      {:noreply,
       socket
       |> cancel_undo_timer()
       |> assign(undo_archive_session: nil)
       |> assign(:entries, entries)
       |> assign(:node_map, node_map)
       |> assign(:aq_questions, aq_questions)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_message", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    case {prompt, socket.assigns.entries} do
      {"", _} ->
        {:noreply, socket}

      {_, []} ->
        {:noreply, put_flash(socket, :error, "No idle sessions")}

      {prompt, [{session, _msg} | _rest]} ->
        node = Map.get(socket.assigns.node_map, session.id, node())
        ensure_runner(node, session.id)

        Cluster.send_message(node, session.id, prompt, :queue)
        |> handle_delivery_result(socket, fn ->
          {:noreply,
           socket
           |> assign(:entries, reject_session(socket.assigns.entries, session.id))
           |> assign(:prompt, "")
           |> update(:form_key, &(&1 + 1))}
        end)
    end
  end

  def handle_event("send_to", %{"id" => id, "prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:noreply, socket}
    else
      node = Map.get(socket.assigns.node_map, id, node())
      ensure_runner(node, id)

      Cluster.send_message(node, id, prompt, :queue)
      |> handle_delivery_result(socket, fn ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
      end)
    end
  end

  def handle_event("defer", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    session = Cluster.get_session!(node, id)
    Cluster.defer_session(node, session)

    {entries, node_map, aq_questions} =
      load_entries_with_nodes(socket.assigns.node_filter, socket.assigns.queue_filter)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:node_map, node_map)
     |> assign(:aq_questions, aq_questions)}
  end

  def handle_event("delegate", %{"id" => id, "prompt" => prompt}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    session = Cluster.get_session!(node, id)
    prompt = String.trim(prompt)

    # Create the delegate session on the same node as the original
    case HubRPC.create_session(%{
           directory: session.directory,
           project_id: session.project_id,
           runner_node: Atom.to_string(node)
         }) do
      {:ok, new_session} ->
        Cluster.start_session(node, new_session.id, new_session)

        # Tell the original session to delegate work to the new session
        ensure_runner(node, id)

        delegate_prompt =
          "A new session has been created for you to delegate work to. " <>
            "Its session ID is #{new_session.id}. " <>
            "Use the send_message_to_session tool to tell it what to work on. " <>
            "Give it enough context to work independently." <>
            if(prompt != "", do: "\n\nThe user says: #{prompt}", else: "")

        Cluster.send_message(node, id, delegate_prompt, :queue)
        |> handle_delivery_result(socket, fn ->
          {:noreply,
           socket
           |> assign(:entries, reject_session(socket.assigns.entries, id))
           |> assign(:prompt, "")
           |> update(:form_key, &(&1 + 1))}
        end)

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create delegate session")}
    end
  end

  def handle_event("commit", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    Cluster.send_message(
      node,
      id,
      "Commit all current changes. Use a descriptive commit message based on the diff.",
      :queue
    )
    |> handle_delivery_result(socket, fn ->
      {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
    end)
  end

  def handle_event("add_tests", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    Cluster.send_message(
      node,
      id,
      "Check if there are tests for the recent changes. If there aren't any, add comprehensive tests.",
      :queue
    )
    |> handle_delivery_result(socket, fn ->
      {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
    end)
  end

  def handle_event("rebase", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    Cluster.send_message(
      node,
      id,
      "Rebase this branch onto main. If there are conflicts, resolve them intelligently based on the intent of both changes.",
      :queue
    )
    |> handle_delivery_result(socket, fn ->
      {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
    end)
  end

  def handle_event("merge_to_main", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    Cluster.send_message(
      node,
      id,
      "Switch to the main branch, merge this worktree's branch in, and resolve any conflicts if they arise.",
      :queue
    )
    |> handle_delivery_result(socket, fn ->
      {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
    end)
  end

  def handle_event("approve_session", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    Cluster.send_message(node, id, "That sounds great, go for it!", :queue)
    |> handle_delivery_result(socket, fn ->
      {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
    end)
  end

  # AskUserQuestion wizard events (per-session state keyed by id)

  def handle_event("aq_select", %{"id" => id, "q" => q, "label" => label} = params, socket) do
    page = String.to_integer(q)
    multi = params["multi"] == "true"
    state = aq_state_for(socket, id)
    selections = AskUserQuestion.toggle_selection(state.selections, page, label, multi)
    {:noreply, put_aq_state(socket, id, %{state | selections: selections})}
  end

  def handle_event("aq_prev", %{"id" => id}, socket) do
    state = aq_state_for(socket, id)
    {:noreply, put_aq_state(socket, id, %{state | page: max(state.page - 1, 0)})}
  end

  def handle_event("aq_next", %{"id" => id}, socket) do
    state = aq_state_for(socket, id)
    max_page = length(Map.get(socket.assigns.aq_questions, id, [])) - 1
    {:noreply, put_aq_state(socket, id, %{state | page: min(state.page + 1, max_page)})}
  end

  def handle_event("aq_submit", %{"id" => id}, socket) do
    questions = Map.get(socket.assigns.aq_questions, id, [])
    state = aq_state_for(socket, id)
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    prompt = AskUserQuestion.format_answers(questions, state.selections)

    Cluster.send_message(node, id, prompt, :queue)
    |> handle_delivery_result(socket, fn ->
      {:noreply,
       socket
       |> assign(:entries, reject_session(socket.assigns.entries, id))
       |> assign(:aq_state, Map.delete(socket.assigns.aq_state, id))}
    end)
  end

  def handle_event("toggle_tts", _params, socket) do
    enabled = !socket.assigns.tts_autoplay

    {:noreply,
     socket
     |> assign(:tts_autoplay, enabled)
     |> push_event("tts_autoplay_persisted", %{enabled: enabled})}
  end

  # Hydrates :tts_autoplay from the client's localStorage on connect — see
  # SessionLive.Show's identical clause and app.js's ttsMountShared (shared
  # storage key, so toggling autoplay on either page reflects on both).
  def handle_event("tts_autoplay_init", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :tts_autoplay, enabled)}
  end

  def handle_event("show_all", _params, socket) do
    {:noreply, assign(socket, :show_all, !socket.assigns.show_all)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)

    {entries, node_map, aq_questions} =
      load_entries_with_nodes(socket.assigns.node_filter, filter)

    {:noreply,
     socket
     |> assign(:queue_filter, filter)
     |> assign(:entries, entries)
     |> assign(:node_map, node_map)
     |> assign(:aq_questions, aq_questions)}
  end

  def handle_event("validate", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :prompt, prompt)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_undo_archive, socket) do
    {:noreply, assign(socket, undo_archive_session: nil, undo_archive_timer: nil)}
  end

  def handle_info({:status, status}, socket) do
    handle_status_change(status, socket)
  end

  def handle_info({_session_id, {:status, status}}, socket) do
    handle_status_change(status, socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def reload_for_node_filter(socket) do
    {entries, node_map, aq_questions} =
      load_entries_with_nodes(socket.assigns.node_filter, socket.assigns.queue_filter)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:node_map, node_map)
     |> assign(:aq_questions, aq_questions)}
  end

  # Both idle and waiting sessions belong in the queue; reload on either.
  defp handle_status_change(status, socket) when status in [:idle, :waiting] do
    {entries, node_map, aq_questions} =
      load_entries_with_nodes(socket.assigns.node_filter, socket.assigns.queue_filter)

    # Subscribe to any new sessions we weren't tracking
    existing_ids = MapSet.new(socket.assigns.entries, fn {s, _} -> s.id end)

    for {session, _msg} <- entries, session.id not in existing_ids do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
    end

    was_empty = Enum.empty?(socket.assigns.entries)
    now_has_entries = entries != []

    socket =
      socket
      |> assign(:entries, entries)
      |> assign(:node_map, node_map)
      |> assign(:aq_questions, aq_questions)

    socket =
      if was_empty && now_has_entries && socket.assigns.tts_autoplay do
        push_autoplay_target(socket, hd(entries))
      else
        socket
      end

    {:noreply, socket}
  end

  defp handle_status_change(_status, socket), do: {:noreply, socket}

  # Explicit id from the server (the new entry's session id — see
  # extract_assistant_text/1's nil branch for why we skip messages with
  # nothing to read), mirroring SessionLive.Show's push_autoplay_target/1.
  # Replaces the old `data-tts-autoplay` attribute + per-card self-start,
  # which only worked because every card had its own TTSPlayer hook.
  defp push_autoplay_target(socket, {session, message}) do
    if extract_assistant_text(message) do
      push_event(socket, "tts-autoplay", %{message_id: session.id})
    else
      socket
    end
  end

  defp schedule_undo_archive(socket, session_id) do
    socket = cancel_undo_timer(socket)
    timer = Process.send_after(self(), :clear_undo_archive, 5000)
    assign(socket, undo_archive_session: session_id, undo_archive_timer: timer)
  end

  defp cancel_undo_timer(socket) do
    if ref = socket.assigns.undo_archive_timer do
      Process.cancel_timer(ref)
    end

    assign(socket, undo_archive_timer: nil)
  end

  defp load_entries_with_nodes(node_filter, queue_filter) do
    tagged =
      Cluster.list_idle_sessions_with_last_assistant_message()
      |> NodeFilter.filter_tagged(node_filter)

    # tagged is [{node, {session, msg}}, ...]

    # Apply queue filter
    tagged =
      case queue_filter do
        :orchestrator -> Enum.filter(tagged, fn {_n, {session, _msg}} -> session.orchestrator end)
        :all -> tagged
      end

    node_map = Map.new(tagged, fn {n, {session, _msg}} -> {session.id, n} end)
    entries = Enum.map(tagged, fn {_n, entry} -> entry end)
    {entries, node_map, load_aq_questions(entries)}
  end

  # For each waiting session, derive its pending AskUserQuestion from full
  # history (the last assistant message in `entries` is the model's follow-up
  # text, not the tool_use). Only waiting sessions are queried.
  defp load_aq_questions(entries) do
    entries
    |> Enum.filter(fn {session, _msg} -> session.status == "waiting" end)
    |> Enum.reduce(%{}, fn {session, _msg}, acc ->
      messages =
        session.id
        |> HubRPC.list_messages()
        |> Enum.map(& &1.data)

      case AskUserQuestion.pending_questions(messages) do
        %{questions: questions} -> Map.put(acc, session.id, questions)
        nil -> acc
      end
    end)
  end

  defp reject_session(entries, id) do
    Enum.reject(entries, fn {session, _} -> session.id == id end)
  end

  # Delivered once over the connected socket (never rendered into static
  # HTML) so the bearer credential for POST /api/tts (now behind
  # :api_authed, see router.ex) never appears in a disconnected page
  # response. Mirrors SessionLive.Show's identical helper.
  defp maybe_push_tts_config(socket) do
    if connected?(socket) do
      push_event(socket, "tts-config", %{api_token: Application.get_env(:orca_hub, :api_token)})
    else
      socket
    end
  end

  defp aq_state_for(socket, id) do
    Map.get(socket.assigns.aq_state, id, %{page: 0, selections: %{}})
  end

  defp put_aq_state(socket, id, state) do
    assign(socket, :aq_state, Map.put(socket.assigns.aq_state, id, state))
  end

  defp ensure_runner(target_node, session_id) do
    unless Cluster.session_alive?(target_node, session_id) do
      session = HubRPC.get_session(session_id)
      Cluster.start_session(target_node, session_id, session)
    end
  end

  def extract_assistant_text(nil), do: nil

  def extract_assistant_text(message) do
    content_blocks = get_in(message.data, ["message", "content"]) || []

    text =
      content_blocks
      |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text == "", do: nil, else: text
  end

  def time_ago(datetime) do
    now = DateTime.utc_now()

    datetime =
      if is_struct(datetime, NaiveDateTime),
        do: DateTime.from_naive!(datetime, "Etc/UTC"),
        else: datetime

    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  def worktree?(directory) do
    gitfile = Path.join(directory, ".git")
    File.regular?(gitfile)
  end
end
