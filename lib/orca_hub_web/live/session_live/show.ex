defmodule OrcaHubWeb.SessionLive.Show do
  use OrcaHubWeb, :live_view
  require Logger

  alias OrcaHub.{Feedback, Projects, Sessions, SessionSupervisor, SessionRunner}
  alias OrcaHubWeb.{MessageComponents, Markdown}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    session = Sessions.get_session!(id)

    unless SessionSupervisor.session_alive?(id) do
      SessionSupervisor.start_session(id)
    end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{id}")
      Process.send_after(self(), :poll_file_changes, 2000)
    end

    runner_state = SessionRunner.get_state(id)

    {:ok,
     socket
     |> assign(:session, session)
     |> assign(:status, runner_state.status)
     |> assign(:messages, runner_state.messages)
     |> assign(:page_title, session.title || (session.project && session.project.name) || session.directory)
     |> assign(:feedback_requests, Feedback.list_pending_requests_for_session(id))
     |> assign(:tts_autoplay, false)
     |> assign(:open_files, [])
     |> assign(:active_file_tab, nil)
     |> assign(:file_editing, false)
     |> assign(:file_edit_mode, false)
     |> assign(:editing_block, nil)
     |> assign(:block_edit_content, nil)
     |> assign(:show_file_browser, false)
     |> assign(:file_tree, [])
     |> assign(:filtered_file_tree, [])
     |> assign(:file_tree_filter, "")
     |> assign(:file_mtimes, %{})
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 5,
       max_file_size: 20_000_000,
       auto_upload: true
     )
     |> allow_upload(:file,
       accept: :any,
       max_entries: 5,
       max_file_size: 50_000_000,
       auto_upload: true
     )}
  end


  @impl true
  def handle_event("send_message", %{"prompt" => prompt}, socket) do
    Logger.info("send_message: prompt=#{inspect(String.trim(prompt))}")
    Logger.info("send_message: image entries=#{length(socket.assigns.uploads.image.entries)}, file entries=#{length(socket.assigns.uploads.file.entries)}")
    {image_paths, socket} = consume_uploaded_entries_for(socket, :image)
    {file_entries, socket} = consume_uploaded_file_entries(socket)
    Logger.info("send_message: image_paths=#{inspect(image_paths)}, file_entries=#{inspect(file_entries)}")

    image_attachments = Enum.map(image_paths, &"[Attached image: #{&1} — use your Read tool to view it]")

    file_attachments = Enum.map(file_entries, &"[Attached file: #{&1}]")

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

  def handle_event("approve_feedback", %{"id" => id}, socket) do
    Feedback.respond(String.to_integer(id), "That sounds great, go for it!")
    {:noreply, assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == String.to_integer(id))))}
  end

  def handle_event("cancel_feedback", %{"id" => id}, socket) do
    id = String.to_integer(id)
    Feedback.cancel(id)
    {:noreply, assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
  end

  def handle_event("respond_feedback", %{"feedback_id" => id, "response" => response}, socket) do
    response = String.trim(response)
    id = String.to_integer(id)

    if response == "" do
      {:noreply, socket}
    else
      Feedback.respond(id, response)
      {:noreply, assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
    end
  end

  def handle_event("toggle_tts", _params, socket) do
    {:noreply, assign(socket, :tts_autoplay, !socket.assigns.tts_autoplay)}
  end

  def handle_event("archive", _params, socket) do
    session = socket.assigns.session
    SessionSupervisor.stop_session(session.id)
    {:ok, _} = Sessions.archive_session(session)
    {:noreply, push_navigate(socket, to: ~p"/sessions?undo=#{session.id}")}
  end

  def handle_event("unarchive", _params, socket) do
    session = socket.assigns.session
    {:ok, session} = Sessions.unarchive_session(session)
    {:noreply, assign(socket, :session, session)}
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

  # -- File panel events --

  def handle_event("toggle_file_browser", _params, socket) do
    socket =
      if socket.assigns.show_file_browser do
        assign(socket, :show_file_browser, false)
      else
        socket = ensure_file_tree_loaded(socket)
        assign(socket, :show_file_browser, true)
      end

    {:noreply, socket}
  end

  def handle_event("filter_file_tree", %{"value" => query}, socket) do
    filtered = Projects.filter_file_tree(socket.assigns.file_tree, query)
    {:noreply, assign(socket, file_tree_filter: query, filtered_file_tree: filtered)}
  end

  def handle_event("open_file", %{"path" => path}, socket) do
    socket = open_file_tab(socket, path)
    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"path" => path}, socket) do
    tab = Enum.find(socket.assigns.open_files, &(&1.path == path))

    if tab do
      {:noreply,
       socket
       |> assign(:active_file_tab, path)
       |> assign(:file_editing, false)
       |> assign(:file_edit_mode, false)
       |> assign(:editing_block, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_tab", %{"path" => path}, socket) do
    open_files = Enum.reject(socket.assigns.open_files, &(&1.path == path))

    active =
      cond do
        open_files == [] -> nil
        socket.assigns.active_file_tab == path -> hd(open_files).path
        true -> socket.assigns.active_file_tab
      end

    {:noreply,
     socket
     |> assign(:open_files, open_files)
     |> assign(:active_file_tab, active)
     |> assign(:file_editing, false)
     |> assign(:editing_block, nil)
     |> assign(:file_mtimes, Map.delete(socket.assigns.file_mtimes, path))}
  end

  def handle_event("close_file_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:open_files, [])
     |> assign(:active_file_tab, nil)
     |> assign(:file_editing, false)
     |> assign(:editing_block, nil)
     |> assign(:show_file_browser, false)}
  end

  def handle_event("toggle_edit_mode", _params, socket) do
    {:noreply, assign(socket, file_edit_mode: !socket.assigns.file_edit_mode, file_editing: false, editing_block: nil)}
  end

  def handle_event("edit_file", _params, socket) do
    {:noreply, assign(socket, :file_editing, true)}
  end

  def handle_event("cancel_edit_file", _params, socket) do
    {:noreply, assign(socket, file_editing: false, editing_block: nil)}
  end

  def handle_event("save_file", %{"content" => content}, socket) do
    path = socket.assigns.active_file_tab
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}

    case Projects.save_file(project, path, content) do
      :ok ->
        blocks = if markdown_file?(path), do: Markdown.split_blocks(content), else: []
        mtime = file_mtime(Path.join(dir, path))

        open_files =
          Enum.map(socket.assigns.open_files, fn tab ->
            if tab.path == path, do: %{tab | content: content, blocks: blocks}, else: tab
          end)

        {:noreply,
         socket
         |> assign(open_files: open_files, file_editing: false, editing_block: nil)
         |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, path, mtime))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("edit_block", %{"index" => index}, socket) do
    index = String.to_integer(index)
    tab = get_active_tab(socket)

    block_text =
      case Enum.find(tab.blocks, fn {idx, _} -> idx == index end) do
        {_, text} -> text
        nil -> ""
      end

    {:noreply, assign(socket, editing_block: index, block_edit_content: block_text)}
  end

  def handle_event("cancel_block_edit", _params, socket) do
    {:noreply, assign(socket, editing_block: nil, block_edit_content: nil)}
  end

  def handle_event("save_block", %{"content" => content}, socket) do
    tab = get_active_tab(socket)
    index = socket.assigns.editing_block

    updated_blocks =
      Enum.map(tab.blocks, fn {idx, text} ->
        if idx == index, do: {idx, String.trim(content)}, else: {idx, text}
      end)

    full_content = Markdown.join_blocks(updated_blocks)
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}

    case Projects.save_file(project, tab.path, full_content) do
      :ok ->
        mtime = file_mtime(Path.join(dir, tab.path))

        open_files =
          Enum.map(socket.assigns.open_files, fn t ->
            if t.path == tab.path, do: %{t | content: full_content, blocks: updated_blocks}, else: t
          end)

        {:noreply,
         socket
         |> assign(open_files: open_files, editing_block: nil, block_edit_content: nil)
         |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, tab.path, mtime))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_block", %{"index" => index}, socket) do
    tab = get_active_tab(socket)
    index = String.to_integer(index)

    updated_blocks = Enum.reject(tab.blocks, fn {idx, _} -> idx == index end)
    full_content = Markdown.join_blocks(updated_blocks)
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}

    case Projects.save_file(project, tab.path, full_content) do
      :ok ->
        mtime = file_mtime(Path.join(dir, tab.path))

        open_files =
          Enum.map(socket.assigns.open_files, fn t ->
            if t.path == tab.path, do: %{t | content: full_content, blocks: updated_blocks}, else: t
          end)

        {:noreply,
         socket
         |> assign(open_files: open_files, editing_block: nil)
         |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, tab.path, mtime))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:open_file, path}, socket) do
    {:noreply, open_file_tab(socket, path)}
  end

  @impl true
  def handle_info({:event, event}, socket) do
    {:noreply, assign(socket, :messages, socket.assigns.messages ++ [event])}
  end

  @impl true
  def handle_info({:status, status}, socket) do
    socket = assign(socket, :status, status)

    socket =
      if status == :waiting do
        assign(socket, :feedback_requests, Feedback.list_pending_requests_for_session(socket.assigns.session.id))
      else
        socket
      end

    socket =
      if status == :idle do
        socket = assign(socket, :feedback_requests, [])

        if socket.assigns.tts_autoplay do
          push_event(socket, "tts-autoplay", %{})
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
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

  @impl true
  def handle_info(:poll_file_changes, socket) do
    Process.send_after(self(), :poll_file_changes, 2000)

    if socket.assigns.open_files == [] do
      {:noreply, socket}
    else
      {:noreply, refresh_changed_files(socket)}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if session = socket.assigns[:session] do
      if Enum.empty?(Sessions.list_messages(session.id)) do
        SessionSupervisor.stop_session(session.id)
        Sessions.archive_session(session)
      end
    end
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
            {:ok, dest}
          end)

        {entries, socket}

      _ ->
        {[], socket}
    end
  end

  # -- File panel helpers --

  defp open_file_tab(socket, path) do
    dir = socket.assigns.session.directory

    # Normalize: if absolute and inside the project dir, make relative
    # If absolute and outside, keep absolute and mark read-only
    {path, read_only} =
      if String.starts_with?(path, "/") do
        relative = Path.relative_to(path, dir)

        if relative != path do
          # Successfully made relative — it's inside the project
          {relative, false}
        else
          # Outside the project — keep absolute, read-only
          {path, true}
        end
      else
        {path, false}
      end

    # If already open, just switch to it
    if Enum.any?(socket.assigns.open_files, &(&1.path == path)) do
      socket
      |> assign(:active_file_tab, path)
      |> assign(:file_editing, false)
      |> assign(:editing_block, nil)
      |> assign(:show_file_browser, false)
    else
      result =
        if read_only do
          File.read(path)
        else
          Projects.load_file(%Projects.Project{directory: dir}, path)
        end

      case result do
        {:ok, content} ->
          blocks = if markdown_file?(path), do: Markdown.split_blocks(content), else: []
          tab = %{path: path, content: content, blocks: blocks, read_only: read_only}
          full_path = if read_only, do: path, else: Path.join(dir, path)
          mtime = file_mtime(full_path)

          socket
          |> assign(:open_files, socket.assigns.open_files ++ [tab])
          |> assign(:active_file_tab, path)
          |> assign(:file_editing, false)
          |> assign(:editing_block, nil)
          |> assign(:show_file_browser, false)
          |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, path, mtime))

        {:error, reason} ->
          put_flash(socket, :error, "Could not open file: #{inspect(reason)}")
      end
    end
  end

  defp get_active_tab(socket) do
    Enum.find(socket.assigns.open_files, &(&1.path == socket.assigns.active_file_tab))
  end

  defp ensure_file_tree_loaded(socket) do
    if socket.assigns.file_tree == [] do
      dir = socket.assigns.session.directory
      project = %Projects.Project{directory: dir}
      files = Projects.list_editable_files(project)
      tree = Projects.build_file_tree(files)
      assign(socket, file_tree: tree, filtered_file_tree: tree)
    else
      socket
    end
  end

  defp refresh_changed_files(socket) do
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}

    {open_files, mtimes} =
      Enum.map_reduce(socket.assigns.open_files, socket.assigns.file_mtimes, fn tab, mtimes ->
        full_path = if tab.read_only, do: tab.path, else: Path.join(dir, tab.path)
        current_mtime = file_mtime(full_path)
        stored_mtime = Map.get(mtimes, tab.path)

        if current_mtime != stored_mtime && current_mtime != nil do
          result =
            if tab.read_only do
              File.read(tab.path)
            else
              Projects.load_file(project, tab.path)
            end

          case result do
            {:ok, content} ->
              blocks = if markdown_file?(tab.path), do: Markdown.split_blocks(content), else: []
              {%{tab | content: content, blocks: blocks}, Map.put(mtimes, tab.path, current_mtime)}

            {:error, _} ->
              {tab, mtimes}
          end
        else
          {tab, mtimes}
        end
      end)

    socket
    |> assign(:open_files, open_files)
    |> assign(:file_mtimes, mtimes)
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp markdown_file?(path), do: String.ends_with?(path, ".md")

  # -- File tree components --

  attr :node, :map, required: true

  defp file_tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <li>
      <button phx-click="open_file" phx-value-path={@node.path}>
        <span class="font-mono text-xs truncate">{@node.name}</span>
      </button>
    </li>
    """
  end

  defp file_tree_node(%{node: %{type: :dir}} = assigns) do
    ~H"""
    <li>
      <details>
        <summary class="font-mono text-xs">
          <.icon name="hero-folder-micro" class="size-3 opacity-50" />
          {@node.name}
        </summary>
        <ul>
          <.file_tree_node :for={child <- @node.children} node={child} />
        </ul>
      </details>
    </li>
    """
  end
end
