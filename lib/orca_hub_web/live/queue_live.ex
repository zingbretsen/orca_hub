defmodule OrcaHubWeb.QueueLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{HubRPC, Cluster}
  alias OrcaHubWeb.Markdown

  @impl true
  def mount(_params, _session, socket) do
    {entries, node_map} = load_entries_with_nodes()

    tagged_feedback = Cluster.list_pending_feedback()
    feedback_requests = Enum.map(tagged_feedback, fn {_n, req} -> req end)
    feedback_node_map = Cluster.build_node_map(tagged_feedback)

    if connected?(socket) do
      for {session, _msg} <- entries do
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
      end

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "feedback_requests")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {:ok,
     socket
     |> assign(:entries, entries)
     |> assign(:node_map, node_map)
     |> assign(:feedback_requests, feedback_requests)
     |> assign(:feedback_node_map, feedback_node_map)
     |> assign(:clustered, length(Node.list()) > 0)
     |> assign(:prompt, "")
     |> assign(:form_key, 0)
     |> assign(:show_all, false)
     |> assign(:tts_autoplay, false)
     |> assign(:tts_autoplay_pending, false)
     |> assign(:page_title, "Queue")
     |> assign(:undo_archive_session, nil)
     |> assign(:undo_archive_timer, nil)}
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

      {entries, node_map} = load_entries_with_nodes()

      {:noreply,
       socket
       |> cancel_undo_timer()
       |> assign(undo_archive_session: nil)
       |> assign(:entries, entries)
       |> assign(:node_map, node_map)}
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

        case Cluster.send_message(node, session.id, prompt) do
          :ok ->
            {:noreply,
             socket
             |> assign(:entries, reject_session(socket.assigns.entries, session.id))
             |> assign(:prompt, "")
             |> update(:form_key, &(&1 + 1))}

          {:error, :busy} ->
            {:noreply, put_flash(socket, :error, "Session is busy")}
        end
    end
  end

  def handle_event("send_to", %{"id" => id, "prompt" => prompt}, socket) do
    prompt = String.trim(prompt)
    if prompt == "" do
      {:noreply, socket}
    else
      node = Map.get(socket.assigns.node_map, id, node())
      ensure_runner(node, id)

      case Cluster.send_message(node, id, prompt) do
        :ok ->
          {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

        {:error, :busy} ->
          {:noreply, put_flash(socket, :error, "Session is busy")}
      end
    end
  end

  def handle_event("defer", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    session = Cluster.get_session!(node, id)
    Cluster.defer_session(node, session)

    {entries, node_map} = load_entries_with_nodes()
    {:noreply, socket |> assign(:entries, entries) |> assign(:node_map, node_map)}
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
        Cluster.start_session(node, new_session.id)

        # Tell the original session to delegate work to the new session
        ensure_runner(node, id)

        delegate_prompt =
          "A new session has been created for you to delegate work to. " <>
            "Its session ID is #{new_session.id}. " <>
            "Use the send_message_to_session tool to tell it what to work on. " <>
            "Give it enough context to work independently." <>
            if(prompt != "", do: "\n\nThe user says: #{prompt}", else: "")

        case Cluster.send_message(node, id, delegate_prompt) do
          :ok ->
            {:noreply,
             socket
             |> assign(:entries, reject_session(socket.assigns.entries, id))
             |> assign(:prompt, "")
             |> update(:form_key, &(&1 + 1))}

          {:error, :busy} ->
            {:noreply, put_flash(socket, :error, "Session is busy")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create delegate session")}
    end
  end

  def handle_event("commit", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    case Cluster.send_message(node, id, "Commit all current changes. Use a descriptive commit message based on the diff.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("add_tests", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    case Cluster.send_message(node, id, "Check if there are tests for the recent changes. If there aren't any, add comprehensive tests.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("rebase", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    case Cluster.send_message(node, id, "Rebase this branch onto main. If there are conflicts, resolve them intelligently based on the intent of both changes.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("merge_to_main", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    case Cluster.send_message(node, id, "Switch to the main branch, merge this worktree's branch in, and resolve any conflicts if they arise.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("approve_session", %{"id" => id}, socket) do
    node = Map.get(socket.assigns.node_map, id, node())
    ensure_runner(node, id)

    case Cluster.send_message(node, id, "That sounds great, go for it!") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("approve_feedback", %{"id" => id}, socket) do
    id = String.to_integer(id)
    HubRPC.respond_feedback(id, "That sounds great, go for it!")

    {:noreply,
     assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
  end

  def handle_event("cancel_feedback", %{"id" => id}, socket) do
    id = String.to_integer(id)
    HubRPC.cancel_feedback(id)

    {:noreply,
     assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
  end

  def handle_event("respond_feedback", %{"feedback_id" => id, "response" => response}, socket) do
    response = String.trim(response)
    id = String.to_integer(id)

    if response == "" do
      {:noreply, socket}
    else
      HubRPC.respond_feedback(id, response)

      {:noreply,
       assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
    end
  end

  def handle_event("toggle_tts", _params, socket) do
    {:noreply, assign(socket, :tts_autoplay, !socket.assigns.tts_autoplay)}
  end

  def handle_event("show_all", _params, socket) do
    {:noreply, assign(socket, :show_all, !socket.assigns.show_all)}
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

  def handle_info({:new_feedback_request, _request}, socket) do
    tagged_feedback = Cluster.list_pending_feedback()
    feedback_requests = Enum.map(tagged_feedback, fn {_n, req} -> req end)
    feedback_node_map = Cluster.build_node_map(tagged_feedback)

    {:noreply,
     socket
     |> assign(:feedback_requests, feedback_requests)
     |> assign(:feedback_node_map, feedback_node_map)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_status_change(:idle, socket) do
    {entries, node_map} = load_entries_with_nodes()

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
      |> assign(:tts_autoplay_pending, was_empty && now_has_entries && socket.assigns.tts_autoplay)

    {:noreply, socket}
  end

  defp handle_status_change(_status, socket), do: {:noreply, socket}

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

  defp load_entries_with_nodes do
    tagged = Cluster.list_idle_sessions_with_last_assistant_message()
    # tagged is [{node, {session, msg}}, ...]
    node_map = Map.new(tagged, fn {n, {session, _msg}} -> {session.id, n} end)
    entries = Enum.map(tagged, fn {_n, entry} -> entry end)
    {entries, node_map}
  end

  defp reject_session(entries, id) do
    Enum.reject(entries, fn {session, _} -> session.id == id end)
  end

  defp ensure_runner(target_node, session_id) do
    unless Cluster.session_alive?(target_node, session_id) do
      Cluster.start_session(target_node, session_id)
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
    datetime = if is_struct(datetime, NaiveDateTime), do: DateTime.from_naive!(datetime, "Etc/UTC"), else: datetime
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  def worktree?(directory) do
    gitfile = Path.join(directory, ".git")
    File.regular?(gitfile)
  end
end
