defmodule OrcaHubWeb.SessionLive.Show do
  use OrcaHubWeb, :live_view
  require Logger

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
     |> assign(:page_title, session.title || (session.project && session.project.name) || session.directory)
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 5,
       max_file_size: 10_000_000
     )
     |> allow_upload(:file,
       accept: :any,
       max_entries: 5,
       max_file_size: 50_000_000
     )}
  end

  @convert_url Application.compile_env(:orca_hub, :document_convert_url)

  @impl true
  def handle_event("send_message", %{"prompt" => prompt}, socket) do
    Logger.info("send_message: prompt=#{inspect(String.trim(prompt))}")
    Logger.info("send_message: image entries=#{length(socket.assigns.uploads.image.entries)}, file entries=#{length(socket.assigns.uploads.file.entries)}")
    {image_paths, socket} = consume_uploaded_entries_for(socket, :image)
    {file_entries, socket} = consume_uploaded_file_entries(socket)
    Logger.info("send_message: image_paths=#{inspect(image_paths)}, file_entries=#{inspect(file_entries)}")

    image_attachments = Enum.map(image_paths, &"[Attached image: #{&1}]")

    file_attachments =
      Enum.map(file_entries, fn {path, md_path} ->
        if md_path do
          "[Attached file: #{path}]\n[Extracted text: #{md_path}]"
        else
          "[Attached file: #{path}]"
        end
      end)

    attachments = Enum.join(image_attachments ++ file_attachments, "\n\n")

    full_prompt =
      case {String.trim(prompt), attachments} do
        {"", ""} -> nil
        {text, ""} -> text
        {"", att} -> "I've attached files to the session directory. Please review them.\n\n#{att}"
        {text, att} -> "#{text}\n\n#{att}"
      end

    if full_prompt do
      case SessionRunner.send_message(socket.assigns.session.id, full_prompt) do
        :ok ->
          {:noreply, push_event(socket, "clear-prompt", %{})}

        {:error, :busy} ->
          {:noreply, put_flash(socket, :error, "Session is busy")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", _params, socket) do
    Logger.info("validate: image entries=#{length(socket.assigns.uploads.image.entries)}, file entries=#{length(socket.assigns.uploads.file.entries)}")
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("interrupt", _params, socket) do
    SessionRunner.interrupt(socket.assigns.session.id)
    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket) do
    session = socket.assigns.session
    params = %{"directory" => session.directory, "project_id" => session.project_id}

    case Sessions.create_session(params) do
      {:ok, new_session} ->
        {:ok, _} = OrcaHub.SessionSupervisor.start_session(new_session.id)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{new_session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("commit", _params, socket) do
    prompt = "Commit the changes you made in this session. Only stage files you actually modified — do not use `git add -A` or `git add .`. Use a descriptive commit message based on the diff."

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

  @impl true
  def handle_info({:status, status}, socket) do
    {:noreply,
     socket
     |> assign(:status, status)
     |> push_event("set-prompt-disabled", %{disabled: status == :running})}
  end

  @impl true
  def handle_info({:title_updated, title}, socket) do
    session = %{socket.assigns.session | title: title}
    {:noreply, socket |> assign(:session, session) |> assign(:page_title, title)}
  end

  @impl true
  def handle_info({:title_error, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Title generation failed: #{reason}")}
  end

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:not_accepted), do: "Invalid file type"
  defp upload_error_to_string(:too_many_files), do: "Too many files"
  defp upload_error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp consume_uploaded_entries_for(socket, upload_name) do
    case uploaded_entries(socket, upload_name) do
      {[_ | _], _} ->
        paths =
          consume_uploaded_entries(socket, upload_name, fn %{path: tmp_path}, entry ->
            ext = Path.extname(entry.client_name)
            filename = "upload_#{System.os_time(:millisecond)}#{ext}"
            dest = Path.join("/tmp", filename)
            Logger.info("#{upload_name} upload: #{entry.client_name} -> #{dest}")
            File.cp!(tmp_path, dest)
            {:ok, dest}
          end)

        {paths, socket}

      _ ->
        {[], socket}
    end
  end

  defp consume_uploaded_file_entries(socket) do
    case uploaded_entries(socket, :file) do
      {[_ | _], _} ->
        entries =
          consume_uploaded_entries(socket, :file, fn %{path: tmp_path}, entry ->
            ext = Path.extname(entry.client_name)
            filename = "upload_#{System.os_time(:millisecond)}#{ext}"
            dest = Path.join("/tmp", filename)
            Logger.info("file upload: #{entry.client_name} -> #{dest}")
            File.cp!(tmp_path, dest)
            md_path = convert_document(dest, entry.client_name)
            Logger.info("file upload: md_path=#{inspect(md_path)}")
            {:ok, {dest, md_path}}
          end)

        {entries, socket}

      _ ->
        {[], socket}
    end
  end

  defp convert_document(path, client_name) do
    Logger.info("convert_document: path=#{path}, client_name=#{client_name}, url=#{@convert_url}")
    content = File.read!(path)

    case Req.post(@convert_url,
           form_multipart: [file: {content, filename: client_name}],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"markdown" => markdown}}} ->
        md_path = Path.rootname(path) <> ".md"
        File.write!(md_path, markdown)
        md_path

      other ->
        Logger.warning("Document conversion failed for #{client_name}: #{inspect(other)}")
        nil
    end
  rescue
    e ->
      Logger.warning("Document conversion error for #{client_name}: #{Exception.message(e)}")
      nil
  end
end
