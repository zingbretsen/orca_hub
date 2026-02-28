defmodule OrcaHubWeb.QueueLive do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Sessions, SessionSupervisor, SessionRunner, Feedback}
  alias OrcaHubWeb.Markdown

  @impl true
  def mount(_params, _session, socket) do
    entries = load_entries()

    feedback_requests = Feedback.list_pending_requests()

    if connected?(socket) do
      for {session, _msg} <- entries do
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
      end

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "feedback_requests")
    end

    {:ok,
     socket
     |> assign(:entries, entries)
     |> assign(:feedback_requests, feedback_requests)
     |> assign(:prompt, "")
     |> assign(:page_title, "Queue")}
  end

  @impl true
  def handle_event("archive", %{"id" => id}, socket) do
    session = Sessions.get_session!(id)
    Sessions.archive_session(session)
    {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}
  end

  def handle_event("send_message", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt)

    case {prompt, socket.assigns.entries} do
      {"", _} ->
        {:noreply, socket}

      {_, []} ->
        {:noreply, put_flash(socket, :error, "No idle sessions")}

      {prompt, [{session, _msg} | _rest]} ->
        ensure_runner(session.id)

        case SessionRunner.send_message(session.id, prompt) do
          :ok ->
            {:noreply,
             socket
             |> assign(:entries, reject_session(socket.assigns.entries, session.id))
             |> assign(:prompt, "")}

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
      ensure_runner(id)

      case SessionRunner.send_message(id, prompt) do
        :ok ->
          {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

        {:error, :busy} ->
          {:noreply, put_flash(socket, :error, "Session is busy")}
      end
    end
  end

  def handle_event("commit", %{"id" => id}, socket) do
    ensure_runner(id)

    case SessionRunner.send_message(id, "Commit all current changes. Use a descriptive commit message based on the diff.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("add_tests", %{"id" => id}, socket) do
    ensure_runner(id)

    case SessionRunner.send_message(id, "Check if there are tests for the recent changes. If there aren't any, add comprehensive tests.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("rebase", %{"id" => id}, socket) do
    ensure_runner(id)

    case SessionRunner.send_message(id, "Rebase this branch onto main. If there are conflicts, resolve them intelligently based on the intent of both changes.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("merge_to_main", %{"id" => id}, socket) do
    ensure_runner(id)

    case SessionRunner.send_message(id, "Switch to the main branch, merge this worktree's branch in, and resolve any conflicts if they arise.") do
      :ok ->
        {:noreply, assign(socket, :entries, reject_session(socket.assigns.entries, id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("respond_feedback", %{"feedback_id" => id, "response" => response}, socket) do
    response = String.trim(response)
    id = String.to_integer(id)

    if response == "" do
      {:noreply, socket}
    else
      Feedback.respond(id, response)

      {:noreply,
       assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
    end
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:status, status}, socket) do
    if status == :idle do
      # A session just went idle — reload the full list
      entries = load_entries()

      # Subscribe to any new sessions we weren't tracking
      existing_ids = MapSet.new(socket.assigns.entries, fn {s, _} -> s.id end)

      for {session, _msg} <- entries, session.id not in existing_ids do
        Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{session.id}")
      end

      {:noreply, assign(socket, :entries, entries)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_feedback_request, _request}, socket) do
    {:noreply, assign(socket, :feedback_requests, Feedback.list_pending_requests())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_entries do
    Sessions.list_idle_sessions_with_last_assistant_message()
  end

  defp reject_session(entries, id) do
    Enum.reject(entries, fn {session, _} -> session.id == id end)
  end

  defp ensure_runner(session_id) do
    unless SessionSupervisor.session_alive?(session_id) do
      SessionSupervisor.start_session(session_id)
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
