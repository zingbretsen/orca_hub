defmodule OrcaHubWeb.SessionLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Sessions, SessionSupervisor, SessionRunner}
  alias OrcaHubWeb.MessageComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    session = Sessions.get_session!(id)

    unless SessionSupervisor.session_alive?(id) do
      SessionSupervisor.start_session(id)
    end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{id}")
    end

    runner_state = SessionRunner.get_state(id)

    {:ok,
     socket
     |> assign(:session, session)
     |> assign(:status, runner_state.status)
     |> assign(:messages, runner_state.messages)
     |> assign(:prompt, "")
     |> assign(:page_title, session.title || session.directory)}
  end

  @impl true
  def handle_event("send_message", %{"prompt" => prompt}, socket) when prompt != "" do
    case SessionRunner.send_message(socket.assigns.session.id, prompt) do
      :ok ->
        {:noreply, assign(socket, :prompt, "")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("commit", _params, socket) do
    prompt = "Commit all current changes. Use a descriptive commit message based on the diff."

    case SessionRunner.send_message(socket.assigns.session.id, prompt) do
      :ok ->
        {:noreply, socket}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  @impl true
  def handle_info({:event, event}, socket) do
    {:noreply, assign(socket, :messages, socket.assigns.messages ++ [event])}
  end

  def handle_info({:status, status}, socket) do
    {:noreply, assign(socket, :status, status)}
  end

end
