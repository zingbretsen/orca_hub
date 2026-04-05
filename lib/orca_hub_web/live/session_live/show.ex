defmodule OrcaHubWeb.SessionLive.Show do
  use OrcaHubWeb, :live_view
  require Logger

  alias OrcaHub.{Cluster, HubRPC, Projects, Sessions, SessionRunner, UpstreamServers}
  alias OrcaHubWeb.{MessageComponents, Markdown}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {session_node, session} = find_session!(id)

    runner_alive? = Cluster.session_alive?(session_node, id)

    if !runner_alive? do
      case Cluster.start_session(session_node, id, session) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("Failed to start session runner for #{id}: #{inspect(reason)}")
      end
    end

    # Check if session is remote based on original runner_node (not the fallback)
    remote? = session.runner_node != nil && session.runner_node != Atom.to_string(node())

    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{id}")

      unless remote? do
        Process.send_after(self(), :poll_file_changes, 2000)
      end
    end

    runner_state =
      if Cluster.session_alive?(session_node, id) do
        Cluster.get_state(session_node, id)
      else
        saved_messages =
          HubRPC.list_messages(id)
          |> Enum.map(fn msg -> Map.put(msg.data, "timestamp", msg.inserted_at) end)

        %{status: session.status || "error", messages: saved_messages}
      end

    {prev_session_id, next_session_id} = HubRPC.get_adjacent_session_ids(session)

    # Display the original node name even if disconnected
    session_node_name = Cluster.node_name(session.runner_node || node())

    {:ok,
     socket
     |> assign(:session, session)
     |> assign(:session_node, session_node)
     |> assign(:session_node_name, session_node_name)
     |> assign(:remote_session, remote?)
     |> assign(:status, runner_state.status)
     |> assign(:messages, runner_state.messages)
     |> assign(:page_title, session.title || (session.project && session.project.name) || session.directory)
     |> assign(:prev_session_id, prev_session_id)
     |> assign(:next_session_id, next_session_id)
     |> assign(:feedback_requests, HubRPC.list_pending_feedback_for_session(id))
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
     |> assign(:scroll_to_line, nil)
     |> assign(:scroll_to_block, nil)
     |> assign(:editing_title, false)
     |> assign(:plan_mode, detect_plan_mode(runner_state.messages))
     |> assign(:pending_plan_file, nil)
     |> assign(:plan_file_path, nil)
     |> assign(:plan_file_original_mtime, nil)
     |> assign(:todos, [])
     |> assign(:show_todos, false)
     |> assign(:show_commits, false)
     |> assign(:commits, [])
     |> assign(:expanded_commit, nil)
     |> assign(:commit_detail, nil)
     |> assign(:show_terminal, false)
     |> assign(:open_terminals, [])
     |> assign(:active_terminal_id, nil)
     |> assign(:show_mcp_modal, false)
     |> assign(:session_mcp_servers, UpstreamServers.list_servers_for_session(id))
     |> assign(:all_upstream_servers, UpstreamServers.list_upstream_servers())
     |> assign(:show_mcp_server_picker, false)
     |> assign(:show_heartbeat_modal, false)
     |> assign(:heartbeat_info, HubRPC.get_heartbeat(id))
     |> load_session_todos()
     |> load_session_commits()
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

    # For remote sessions, transfer uploaded files to the remote node
    {image_paths, file_entries} =
      if remote_session?(socket) do
        session_node = socket.assigns.session_node
        {transfer_uploads(image_paths, session_node), transfer_uploads(file_entries, session_node)}
      else
        {image_paths, file_entries}
      end

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
      case Cluster.send_message(socket.assigns.session_node, socket.assigns.session.id, full_prompt) do
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
    Cluster.interrupt(socket.assigns.session_node, socket.assigns.session.id)
    {:noreply, socket}
  end

  def handle_event("new_session", _params, socket) do
    session = socket.assigns.session
    target_node = socket.assigns.session_node
    params = %{
      "directory" => session.directory,
      "project_id" => session.project_id,
      "runner_node" => Atom.to_string(target_node)
    }

    case HubRPC.create_session(params) do
      {:ok, new_session} ->
        Cluster.start_session(target_node, new_session.id, new_session)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{new_session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("approve_feedback", %{"id" => id}, socket) do
    HubRPC.respond_feedback(String.to_integer(id), "That sounds great, go for it!")
    {:noreply, assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == String.to_integer(id))))}
  end

  def handle_event("cancel_feedback", %{"id" => id}, socket) do
    id = String.to_integer(id)
    HubRPC.cancel_feedback(id)
    {:noreply, assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
  end

  def handle_event("respond_feedback", %{"feedback_id" => id, "response" => response}, socket) do
    response = String.trim(response)
    id = String.to_integer(id)

    if response == "" do
      {:noreply, socket}
    else
      HubRPC.respond_feedback(id, response)
      {:noreply, assign(socket, :feedback_requests, Enum.reject(socket.assigns.feedback_requests, &(&1.id == id)))}
    end
  end

  def handle_event("toggle_tts", _params, socket) do
    {:noreply, assign(socket, :tts_autoplay, !socket.assigns.tts_autoplay)}
  end

  def handle_event("toggle_todos", _params, socket) do
    {:noreply, assign(socket, :show_todos, !socket.assigns.show_todos)}
  end

  def handle_event("toggle_commits", _params, socket) do
    {:noreply, assign(socket, :show_commits, !socket.assigns.show_commits)}
  end

  def handle_event("edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, true)}
  end

  def handle_event("cancel_title_edit", _params, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    title = String.trim(title)
    session = socket.assigns.session

    case HubRPC.update_session(session, %{title: title}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:session, %{session | title: updated.title})
         |> assign(:page_title, updated.title || session.directory)
         |> assign(:editing_title, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update title")}
    end
  end

  def handle_event("regenerate_title", _params, socket) do
    Cluster.rpc(socket.assigns.session_node, SessionRunner, :regenerate_title, [socket.assigns.session.id])
    {:noreply, socket}
  end

  def handle_event("toggle_commit_detail", %{"hash" => hash}, socket) do
    if socket.assigns[:expanded_commit] == hash do
      {:noreply, assign(socket, expanded_commit: nil, commit_detail: nil)}
    else
      detail = Cluster.rpc(socket.assigns.session_node, Sessions, :get_commit_detail, [socket.assigns.session.directory, hash])
      {:noreply, assign(socket, expanded_commit: hash, commit_detail: detail)}
    end
  end

  def handle_event("set_model", %{"model" => model}, socket) do
    session = socket.assigns.session
    model = if model == "", do: nil, else: model

    case Sessions.update_session(session, %{model: model}) do
      {:ok, updated_session} ->
        Cluster.update_model(socket.assigns.session_node, session.id, model)
        {:noreply, assign(socket, :session, updated_session)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update model")}
    end
  end

  def handle_event("toggle_orchestrator", _params, socket) do
    session = socket.assigns.session
    new_value = !session.orchestrator

    case Sessions.update_session(session, %{orchestrator: new_value}) do
      {:ok, updated_session} ->
        Cluster.update_orchestrator(socket.assigns.session_node, session.id, new_value)
        flash_msg = if new_value, do: "Orchestrator mode enabled (takes effect on next message)", else: "Orchestrator mode disabled (takes effect on next message)"
        {:noreply, socket |> assign(:session, updated_session) |> put_flash(:info, flash_msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update orchestrator mode")}
    end
  end

  def handle_event("stop_session", _params, socket) do
    Cluster.stop_session(socket.assigns.session_node, socket.assigns.session.id)
    {:noreply, socket}
  end

  # MCP server events

  def handle_event("toggle_mcp_modal", _params, socket) do
    {:noreply, assign(socket, show_mcp_modal: !socket.assigns.show_mcp_modal, show_mcp_server_picker: false)}
  end

  def handle_event("toggle_mcp_server_picker", _params, socket) do
    {:noreply, assign(socket, show_mcp_server_picker: !socket.assigns.show_mcp_server_picker)}
  end

  def handle_event("add_mcp_server", %{"id" => server_id}, socket) do
    session_id = socket.assigns.session.id
    UpstreamServers.add_server_to_session(session_id, server_id)

    {:noreply,
     socket
     |> assign(
       session_mcp_servers: UpstreamServers.list_servers_for_session(session_id),
       show_mcp_server_picker: false
     )
     |> put_flash(:info, "MCP server added — takes effect on next run")}
  end

  def handle_event("remove_mcp_server", %{"id" => server_id}, socket) do
    session_id = socket.assigns.session.id
    UpstreamServers.remove_server_from_session(session_id, server_id)

    {:noreply,
     socket
     |> assign(session_mcp_servers: UpstreamServers.list_servers_for_session(session_id))
     |> put_flash(:info, "MCP server removed")}
  end

  # Heartbeat events

  def handle_event("toggle_heartbeat_modal", _params, socket) do
    {:noreply, assign(socket, show_heartbeat_modal: !socket.assigns.show_heartbeat_modal)}
  end

  def handle_event("schedule_heartbeat", %{"interval" => interval_str, "message" => message}, socket) do
    session_id = socket.assigns.session.id

    with {interval, ""} <- Integer.parse(interval_str),
         :ok <- HubRPC.schedule_heartbeat(session_id, interval, "[Heartbeat]\n\n#{message}") do
      {:noreply,
       socket
       |> assign(heartbeat_info: HubRPC.get_heartbeat(session_id))
       |> assign(show_heartbeat_modal: false)
       |> put_flash(:info, "Heartbeat scheduled: every #{format_interval(interval)}")}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid interval")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to schedule heartbeat: #{reason}")}
    end
  end

  def handle_event("cancel_heartbeat", _params, socket) do
    session_id = socket.assigns.session.id
    HubRPC.cancel_heartbeat(session_id)

    {:noreply,
     socket
     |> assign(heartbeat_info: nil)
     |> put_flash(:info, "Heartbeat cancelled")}
  end

  def handle_event("archive", _params, socket) do
    session = socket.assigns.session
    Cluster.stop_session(socket.assigns.session_node, session.id)
    {:ok, _} = Cluster.archive_session(socket.assigns.session_node, session)
    {:noreply, push_navigate(socket, to: ~p"/sessions?undo=#{session.id}")}
  end

  def handle_event("unarchive", _params, socket) do
    session = socket.assigns.session
    {:ok, session} = Cluster.unarchive_session(socket.assigns.session_node, session)
    {:noreply, assign(socket, :session, session)}
  end

  def handle_event("approve_plan", _params, socket) do
    plan_edited? = plan_file_was_edited?(socket)

    prompt =
      if plan_edited? do
        "The plan has been edited by the user. Please re-read the plan file and review the changes before proceeding with implementation."
      else
        "The plan looks good. Please exit plan mode and proceed with implementation."
      end

    case Cluster.send_message(socket.assigns.session_node, socket.assigns.session.id, prompt) do
      :ok ->
        {:noreply, assign(socket, plan_mode: false, plan_file_path: nil, plan_file_original_mtime: nil)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("reject_plan", _params, socket) do
    # Clear plan review — user can type their feedback in the prompt
    {:noreply, assign(socket, plan_mode: false, plan_file_path: nil, plan_file_original_mtime: nil)}
  end

  def handle_event("commit", _params, socket) do
    session_id = socket.assigns.session.id
    prompt = "Commit the changes you made in this session. Only stage files you actually modified — do not use `git add -A` or `git add .`. Use a descriptive commit message based on the diff. Remember to include the trailer: OrcaHub-Session: #{session_id}"

    case Cluster.send_message(socket.assigns.session_node, session_id, prompt) do
      :ok ->
        {:noreply, socket}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}
    end
  end

  def handle_event("open_terminal", _params, socket) do
    if socket.assigns.show_terminal do
      {:noreply, assign(socket, show_terminal: false)}
    else
      session = socket.assigns.session
      session_node = socket.assigns.session_node

      if socket.assigns.open_terminals != [] do
        # Panel was just hidden, show it again
        {:noreply, assign(socket, show_terminal: true)}
      else
        # Find or create a terminal
        {:noreply, open_or_create_terminal(socket, session, session_node)}
      end
    end
  end

  def handle_event("new_terminal", _params, socket) do
    session = socket.assigns.session
    session_node = socket.assigns.session_node
    count = length(socket.assigns.open_terminals) + 1

    name =
      if session.project do
        "#{session.project.name} shell #{count}"
      else
        "shell #{count}"
      end

    terminal_attrs = build_terminal_attrs(name, session, session_node)

    case Cluster.create_terminal(session_node, terminal_attrs) do
      {:ok, terminal} ->
        Cluster.start_terminal(session_node, terminal.id)
        terminal = Cluster.get_terminal!(session_node, terminal.id)

        {:noreply,
         socket
         |> assign(:open_terminals, socket.assigns.open_terminals ++ [terminal])
         |> assign(:active_terminal_id, terminal.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create terminal")}
    end
  end

  def handle_event("switch_terminal", %{"id" => id}, socket) do
    {:noreply, assign(socket, :active_terminal_id, id)}
  end

  def handle_event("close_terminal_tab", %{"id" => id}, socket) do
    open = Enum.reject(socket.assigns.open_terminals, &(&1.id == id))

    active =
      cond do
        open == [] -> nil
        socket.assigns.active_terminal_id == id -> hd(open).id
        true -> socket.assigns.active_terminal_id
      end

    socket = assign(socket, open_terminals: open, active_terminal_id: active)
    socket = if open == [], do: assign(socket, show_terminal: false), else: socket
    {:noreply, socket}
  end

  def handle_event("close_terminal_panel", _params, socket) do
    {:noreply, assign(socket, show_terminal: false)}
  end

  def handle_event("pop_out_terminal", _params, socket) do
    active_id = socket.assigns.active_terminal_id

    if active_id do
      {:noreply, push_navigate(socket, to: ~p"/terminals/#{active_id}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume_in_terminal", _params, socket) do
    session = socket.assigns.session

    unless session.claude_session_id do
      {:noreply, put_flash(socket, :error, "No Claude session to resume")}
    else
      session_node = socket.assigns.session_node
      cmd = "claude --resume #{session.claude_session_id}\n"

      # Create a dedicated terminal for this Claude session
      name =
        if session.title do
          "claude: #{session.title}"
        else
          "claude resume"
        end

      case Cluster.create_terminal(session_node, build_terminal_attrs(name, session, session_node)) do
        {:ok, terminal} ->
          Cluster.start_terminal(session_node, terminal.id)
          terminal = Cluster.get_terminal!(session_node, terminal.id)

          # Send the resume command after a brief delay for the shell to initialize
          Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
            Process.sleep(500)
            Cluster.rpc(session_node, OrcaHub.TerminalRunner, :write, [terminal.id, cmd])
          end)

          {:noreply,
           socket
           |> assign(:show_terminal, true)
           |> assign(:open_terminals, socket.assigns.open_terminals ++ [terminal])
           |> assign(:active_terminal_id, terminal.id)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create terminal")}
      end
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
       |> assign(:editing_block, nil)
       |> assign(:scroll_to_line, nil)
       |> assign(:scroll_to_block, nil)}
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
    session_node = socket.assigns[:session_node] || node()

    case Cluster.rpc(session_node, Projects, :save_file, [project, path, content]) do
      :ok ->
        blocks = if markdown_file?(path), do: Markdown.split_blocks(content), else: []
        mtime = remote_file_mtime(session_node, Path.join(dir, path))

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
    session_node = socket.assigns[:session_node] || node()

    case Cluster.rpc(session_node, Projects, :save_file, [project, tab.path, full_content]) do
      :ok ->
        mtime = remote_file_mtime(session_node, Path.join(dir, tab.path))

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
    session_node = socket.assigns[:session_node] || node()

    case Cluster.rpc(session_node, Projects, :save_file, [project, tab.path, full_content]) do
      :ok ->
        mtime = remote_file_mtime(session_node, Path.join(dir, tab.path))

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

  defp build_terminal_attrs(name, session, session_node) do
    %{name: name, directory: session.directory, project_id: session.project_id, runner_node: Atom.to_string(session_node)}
  end

  defp open_or_create_terminal(socket, session, session_node) do
    tagged = Cluster.list_terminals_for_project(session.project_id)
    terminals = Enum.map(tagged, fn {_n, t} -> t end)

    terminal =
      Enum.find(terminals, fn t ->
        t.directory == session.directory && t.status == "running"
      end)

    case terminal do
      nil ->
        name =
          if session.project do
            "#{session.project.name} shell"
          else
            "shell"
          end

        case Cluster.create_terminal(session_node, build_terminal_attrs(name, session, session_node)) do
          {:ok, terminal} ->
            Cluster.start_terminal(session_node, terminal.id)
            terminal = Cluster.get_terminal!(session_node, terminal.id)

            socket
            |> assign(:show_terminal, true)
            |> assign(:open_terminals, [terminal])
            |> assign(:active_terminal_id, terminal.id)

          {:error, _} ->
            put_flash(socket, :error, "Failed to create terminal")
        end

      terminal ->
        unless Cluster.terminal_alive?(session_node, terminal.id) do
          Cluster.start_terminal(session_node, terminal.id)
        end

        socket
        |> assign(:show_terminal, true)
        |> assign(:open_terminals, [terminal])
        |> assign(:active_terminal_id, terminal.id)
    end
  end

  @impl true
  def handle_info({:open_file, path, line}, socket) do
    {:noreply, open_file_tab(socket, path, line)}
  end

  def handle_info({:open_file, path}, socket) do
    {:noreply, open_file_tab(socket, path)}
  end

  @impl true
  def handle_info({:event, event}, socket) do
    socket = assign(socket, :messages, socket.assigns.messages ++ [event])
    socket = handle_plan_events(socket, event)
    socket = handle_todo_events(socket, event)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:status, status}, socket) do
    socket = assign(socket, :status, status)

    socket =
      if status == :waiting do
        assign(socket, :feedback_requests, HubRPC.list_pending_feedback_for_session(socket.assigns.session.id))
      else
        socket
      end

    socket =
      if status == :idle do
        socket = assign(socket, :feedback_requests, [])
        socket = load_session_commits(socket)

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
    if socket.assigns.remote_session do
      {:noreply, socket}
    else
      Process.send_after(self(), :poll_file_changes, 2000)

      if socket.assigns.open_files == [] do
        {:noreply, socket}
      else
        {:noreply, refresh_changed_files(socket)}
      end
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if session = socket.assigns[:session] do
      session_node = socket.assigns[:session_node] || node()

      if Enum.empty?(Cluster.list_messages(session_node, session.id)) do
        Cluster.stop_session(session_node, session.id)
        Cluster.archive_session(session_node, session)
      end
    end
  end

  defp transfer_uploads(paths, target_node) do
    Enum.flat_map(paths, fn local_path ->
      content = File.read!(local_path)
      filename = Path.basename(local_path)
      remote_path = "/tmp/#{filename}"

      case Cluster.rpc(target_node, File, :write, [remote_path, content]) do
        :ok ->
          File.rm(local_path)
          [remote_path]

        error ->
          Logger.warning("Failed to transfer upload #{filename} to #{target_node}: #{inspect(error)}")
          File.rm(local_path)
          []
      end
    end)
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
            filename = "upload_#{System.unique_integer([:positive, :monotonic])}#{ext}"
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
            filename = "upload_#{System.unique_integer([:positive, :monotonic])}#{ext}"
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

  defp open_file_tab(socket, path, line \\ nil) do
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

    # If already open, just switch to it (and update scroll target)
    if Enum.any?(socket.assigns.open_files, &(&1.path == path)) do
      tab = Enum.find(socket.assigns.open_files, &(&1.path == path))

      block_idx =
        if line && markdown_file?(path) && tab,
          do: line_to_block_index(tab.content, line),
          else: nil

      socket
      |> assign(:active_file_tab, path)
      |> assign(:file_editing, false)
      |> assign(:editing_block, nil)
      |> assign(:show_file_browser, false)
      |> assign(:scroll_to_line, line)
      |> assign(:scroll_to_block, block_idx)
    else
      session_node = socket.assigns[:session_node] || node()

      result =
        if read_only do
          Cluster.rpc(session_node, File, :read, [path])
        else
          Cluster.rpc(session_node, Projects, :load_file, [%Projects.Project{directory: dir}, path])
        end

      case result do
        {:ok, content} ->
          blocks = if markdown_file?(path), do: Markdown.split_blocks(content), else: []
          tab = %{path: path, content: content, blocks: blocks, read_only: read_only}
          full_path = if read_only, do: path, else: Path.join(dir, path)
          mtime = remote_file_mtime(session_node, full_path)

          block_idx =
            if line && markdown_file?(path),
              do: line_to_block_index(content, line),
              else: nil

          socket
          |> assign(:open_files, socket.assigns.open_files ++ [tab])
          |> assign(:active_file_tab, path)
          |> assign(:file_editing, false)
          |> assign(:editing_block, nil)
          |> assign(:show_file_browser, false)
          |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, path, mtime))
          |> assign(:scroll_to_line, line)
          |> assign(:scroll_to_block, block_idx)

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
      session_node = socket.assigns[:session_node] || node()
      files = Cluster.rpc(session_node, Projects, :list_editable_files, [project])
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

  defp remote_file_mtime(target_node, path) do
    case Cluster.rpc(target_node, File, :stat, [path]) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp markdown_file?(path), do: String.ends_with?(path, ".md")

  defp line_to_block_index(content, line) when is_integer(line) and line > 0 do
    # Find which block contains the target line by tracking line offsets
    lines = String.split(content, "\n")
    # Build a prefix of the content up to the target line
    target_text = lines |> Enum.take(line) |> Enum.join("\n")
    blocks = Markdown.split_blocks(content)

    # Find the block whose text appears in the content at or before the target line
    # by checking cumulative character positions
    Enum.reduce_while(blocks, {0, nil}, fn {idx, block_text}, {search_from, _} ->
      case :binary.match(content, String.trim(block_text), [{:scope, {search_from, byte_size(content) - search_from}}]) do
        {pos, len} ->
          block_end = pos + len
          if byte_size(target_text) <= block_end do
            {:halt, {0, idx}}
          else
            {:cont, {pos + len, idx}}
          end

        :nomatch ->
          {:cont, {search_from, idx}}
      end
    end)
    |> elem(1)
  end

  defp line_to_block_index(_, _), do: nil

  # -- Heartbeat helpers --

  defp format_interval(seconds) when seconds >= 3600 do
    hours = div(seconds, 3600)
    remaining = rem(seconds, 3600)
    mins = div(remaining, 60)

    cond do
      mins == 0 -> "#{hours}h"
      true -> "#{hours}h #{mins}m"
    end
  end

  defp format_interval(seconds) when seconds >= 60 do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)

    cond do
      secs == 0 -> "#{mins}m"
      true -> "#{mins}m #{secs}s"
    end
  end

  defp format_interval(seconds), do: "#{seconds}s"

  # -- Commit helpers --

  defp format_commit_date(iso_date) do
    case DateTime.from_iso8601(iso_date) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %d, %H:%M")

      _ ->
        iso_date
    end
  end

  defp load_session_commits(socket) do
    session_node = socket.assigns[:session_node] || node()

    commits =
      Cluster.rpc(session_node, Sessions, :list_session_commits, [
        socket.assigns.session.directory,
        socket.assigns.session.id
      ])

    assign(socket, :commits, commits)
  end

  # -- Todo helpers --

  defp load_session_todos(socket) do
    todos =
      socket.assigns.messages
      |> Enum.reverse()
      |> Enum.find_value([], fn msg ->
        with %{"type" => "assistant", "message" => %{"content" => content}} when is_list(content) <- msg do
          content
          |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use" && &1["name"] == "TodoWrite"))
          |> List.last()
          |> case do
            nil -> nil
            tool_use -> parse_todos(get_in(tool_use, ["input", "todos"]))
          end
        else
          _ -> nil
        end
      end)

    assign(socket, :todos, todos)
  end

  # -- Plan mode helpers --

  @plans_dir Path.join(System.user_home!(), ".claude/plans")

  defp handle_plan_events(socket, %{"type" => "assistant", "message" => %{"content" => content}}) when is_list(content) do
    tool_uses = Enum.filter(content, &(is_map(&1) && &1["type"] == "tool_use"))

    Enum.reduce(tool_uses, socket, fn tool_use, acc ->
      case tool_use["name"] do
        "EnterPlanMode" ->
          assign(acc, :plan_mode, :planning)

        "ExitPlanMode" ->
          assign(acc, :plan_mode, :review)

        "Write" when acc.assigns.plan_mode == :planning ->
          file_path = get_in(tool_use, ["input", "file_path"]) || ""
          if String.starts_with?(file_path, @plans_dir) do
            assign(acc, :pending_plan_file, file_path)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp handle_plan_events(socket, %{"type" => "result"}) do
    case socket.assigns.pending_plan_file do
      nil ->
        socket

      path ->
        session_node = socket.assigns[:session_node] || node()

        socket
        |> assign(:pending_plan_file, nil)
        |> assign(:plan_file_path, path)
        |> assign(:plan_file_original_mtime, remote_file_mtime(session_node, path))
        |> open_file_tab(path)
        |> assign(:file_edit_mode, true)
    end
  end

  defp handle_plan_events(socket, _event), do: socket

  # Extract todos from TodoWrite tool calls in the message stream
  defp handle_todo_events(socket, %{"type" => "assistant", "message" => %{"content" => content}}) when is_list(content) do
    tool_uses = Enum.filter(content, &(is_map(&1) && &1["type"] == "tool_use"))

    Enum.reduce(tool_uses, socket, fn tool_use, acc ->
      case tool_use["name"] do
        "TodoWrite" ->
          todos = parse_todos(get_in(tool_use, ["input", "todos"]))
          assign(acc, :todos, todos)

        _ ->
          acc
      end
    end)
  end

  defp handle_todo_events(socket, _event), do: socket

  defp parse_todos(todos) when is_list(todos), do: todos
  defp parse_todos(todos) when is_binary(todos) do
    case Jason.decode(todos) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
  defp parse_todos(_), do: []

  defp plan_file_was_edited?(socket) do
    case {socket.assigns.plan_file_path, socket.assigns.plan_file_original_mtime} do
      {nil, _} -> false
      {_, nil} -> false
      {path, original_mtime} ->
        session_node = socket.assigns[:session_node] || node()
        remote_file_mtime(session_node, path) != original_mtime
    end
  end

  defp detect_plan_mode(messages) do
    # Only reconstruct :planning from history — :review is transient
    # and should only appear live when ExitPlanMode fires
    Enum.reduce(messages, false, fn msg, state ->
      case msg do
        %{"type" => "assistant", "message" => %{"content" => content}} when is_list(content) ->
          Enum.reduce(content, state, fn
            %{"type" => "tool_use", "name" => "EnterPlanMode"}, _ -> :planning
            %{"type" => "tool_use", "name" => "ExitPlanMode"}, _ -> false
            _, acc -> acc
          end)

        _ ->
          state
      end
    end)
  end

  # -- Cluster helpers --

  defp find_session!(id) do
    case HubRPC.get_session(id) do
      nil -> raise Ecto.NoResultsError, queryable: OrcaHub.Sessions.Session
      session -> {Cluster.runner_node_for(session), session}
    end
  end

  defp remote_session?(socket), do: socket.assigns.remote_session

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
