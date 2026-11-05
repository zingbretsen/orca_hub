defmodule OrcaHubWeb.QueueLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{AskUserQuestion, Cluster, HubRPC}
  alias OrcaHubWeb.{Markdown, NodeFilter}

  import OrcaHubWeb.AskUserQuestionComponent

  # A status change arrives twice (the session's own topic and "sessions"),
  # and turn ends cluster; one reload covers the whole burst.
  @reload_debounce_ms 200

  @impl true
  def mount(_params, _session, socket) do
    queue_filter = :all

    socket =
      socket
      |> assign(:queue_filter, queue_filter)
      |> assign(:aq_cache, %{})
      |> assign(:reload_timer, nil)
      |> load_queue()

    if connected?(socket) do
      for {session, _msg} <- socket.assigns.entries do
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
      end

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {:ok,
     socket
     |> assign(:aq_state, %{})
     |> assign(:clustered, Node.list() != [])
     |> assign(:prompt, "")
     |> assign(:form_key, 0)
     |> assign(:show_all, false)
     |> assign(:tts_autoplay, false)
     |> assign(:page_title, "Queue")
     |> assign(:undo_archive_session, nil)
     |> assign(:undo_archive_timer, nil)
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

      {:noreply,
       socket
       |> cancel_undo_timer()
       |> assign(undo_archive_session: nil)
       |> load_queue()}
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

    {:noreply, load_queue(socket)}
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

  # `ttsMountShared` pushes this next to "tts_autoplay_init" above, from the
  # SHARED TTSMethods — so every host of that mixin gets it, not just the
  # session page that owns the "Speak while streaming" toggle
  # (voice_mode_spec.md §7.3 / C3). Accepted and ignored here: /queue renders
  # no such toggle and receives no assistant deltas, so there is no server
  # state to hydrate. Without the clause this raised FunctionClauseError and
  # killed the LiveView on EVERY connect, which silently threw away the
  # `tts_autoplay_init` that had just been applied one push earlier.
  def handle_event("tts_stream_init", %{"enabled" => _enabled}, socket) do
    {:noreply, socket}
  end

  def handle_event("show_all", _params, socket) do
    {:noreply, assign(socket, :show_all, !socket.assigns.show_all)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)

    {:noreply, socket |> assign(:queue_filter, filter) |> load_queue()}
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

  # From the session's own topic: no id, and always paired with the
  # "sessions" broadcast below, which carries it.
  def handle_info({:status, status}, socket) do
    {:noreply, handle_status_change(socket, nil, status)}
  end

  def handle_info({session_id, {:status, status}}, socket) do
    {:noreply, handle_status_change(socket, session_id, status)}
  end

  def handle_info(:reload_queue, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> reload_after_status_change()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def reload_for_node_filter(socket), do: {:noreply, load_queue(socket)}

  # Any status change makes that session's cached AskUserQuestion stale.
  # Both idle and waiting sessions belong in the queue; reload on either.
  defp handle_status_change(socket, session_id, status) do
    socket =
      if session_id, do: update(socket, :aq_cache, &Map.delete(&1, session_id)), else: socket

    if status in [:idle, :waiting], do: schedule_reload(socket), else: socket
  end

  defp schedule_reload(%{assigns: %{reload_timer: nil}} = socket) do
    assign(socket, :reload_timer, Process.send_after(self(), :reload_queue, @reload_debounce_ms))
  end

  defp schedule_reload(socket), do: socket

  defp reload_after_status_change(socket) do
    was_empty = Enum.empty?(socket.assigns.entries)
    existing_ids = MapSet.new(socket.assigns.entries, fn {s, _} -> s.id end)
    socket = load_queue(socket)
    entries = socket.assigns.entries

    # Subscribe to any new sessions we weren't tracking
    for {session, _msg} <- entries, session.id not in existing_ids do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
    end

    if was_empty && entries != [] && socket.assigns.tts_autoplay do
      push_autoplay_target(socket, hd(entries))
    else
      socket
    end
  end

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

  # Loads the queue into :entries, :node_map and :aq_questions.
  #
  # The priority reset normalizes the queue front in the DB, so it runs on
  # the connected mount and every later reload, never on the dead render: a
  # plain GET must not write. It leaves the relative order of entries as it
  # was, so the dead render shows the same queue.
  defp load_queue(socket) do
    if connected?(socket), do: HubRPC.reset_front_of_queue_priority()

    tagged =
      Cluster.list_idle_sessions_with_last_assistant_message()
      |> NodeFilter.filter_tagged(socket.assigns.node_filter)

    # tagged is [{node, {session, msg}}, ...]

    # Apply queue filter
    tagged =
      case socket.assigns.queue_filter do
        :orchestrator -> Enum.filter(tagged, fn {_n, {session, _msg}} -> session.orchestrator end)
        :all -> tagged
      end

    node_map = Map.new(tagged, fn {n, {session, _msg}} -> {session.id, n} end)
    entries = Enum.map(tagged, fn {_n, entry} -> entry end)
    aq_cache = load_aq_questions(entries, socket.assigns.aq_cache)

    assign(socket,
      entries: entries,
      node_map: node_map,
      aq_cache: aq_cache,
      aq_questions:
        for({id, questions} <- aq_cache, questions != nil, into: %{}, do: {id, questions})
    )
  end

  # Each waiting session's pending AskUserQuestion (the last assistant
  # message in `entries` is the model's follow-up text, not the tool_use),
  # as `%{session_id => normalized questions | nil}`. One targeted lookup per
  # waiting session, reused from `cache` until that session's status changes
  # (see handle_status_change/3). This used to load and scan every waiting
  # session's full message history on every reload.
  defp load_aq_questions(entries, cache) do
    for {session, _msg} <- entries, session.status == "waiting", into: %{} do
      case Map.fetch(cache, session.id) do
        {:ok, questions} -> {session.id, questions}
        :error -> {session.id, pending_questions(session.id)}
      end
    end
  end

  defp pending_questions(session_id) do
    case HubRPC.pending_ask_user_question(session_id) do
      %{questions: questions} -> AskUserQuestion.normalize_questions(questions)
      nil -> nil
    end
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
