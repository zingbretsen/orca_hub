defmodule OrcaHubWeb.ProjectLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, Projects, Triggers}
  alias OrcaHub.Projects.Project
  alias OrcaHub.Triggers.Trigger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {project_node, project} = find_project!(id)
    remote? = project_node != node()

    {editable_files, file_tree, commits, current_branch, worktrees, branches} =
      if remote? do
        {[], [], [], nil, [], []}
      else
        editable_files = Projects.list_editable_files(project)
        file_tree = Projects.build_file_tree(editable_files)
        commits = Projects.git_log(project)
        current_branch = Projects.git_branch(project)
        worktrees = Projects.git_worktree_list(project)
        branches = Projects.git_branches(project)
        {editable_files, file_tree, commits, current_branch, worktrees, branches}
      end

    triggers = HubRPC.list_triggers_for_project(project.id)

    {:ok,
     socket
     |> assign(
       show_archived_sessions: false,
       show_hidden_files: false,
       project: project,
       project_node: project_node,
       remote_project: remote?,
       page_title: project.name,
       commits: commits,
       editable_files: editable_files,
       file_tree: file_tree,
       filtered_file_tree: file_tree,
       file_tree_filter: "",
       current_branch: current_branch,
       worktrees: worktrees,
       branches: branches,
       show_worktree_form: false,
       selected_file: nil,
       file_content: nil,
       file_editing: false,
       file_blocks: [],
       editing_block: nil,
       block_edit_content: nil,
       new_file_name: nil,
       triggers: triggers,
       editing_trigger: nil,
       show_trigger_form: false,
       trigger_type: "scheduled",
       trigger_form: to_form(Triggers.change_trigger(%Trigger{project_id: project.id})),
       edit_form: nil,
       browsing: false,
       browse_path: nil,
       browse_entries: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      case socket.assigns.live_action do
        :edit ->
          project = socket.assigns.project
          changeset = Project.changeset(project, %{})
          assign(socket, edit_form: to_form(changeset), page_title: "Edit #{project.name}")

        :show ->
          assign(socket, edit_form: nil, page_title: socket.assigns.project.name)
      end

    socket =
      case params["file"] do
        nil ->
          socket

        path ->
          project = socket.assigns.project

          case Projects.load_file(project, path) do
            {:ok, content} ->
              blocks =
                if markdown_file?(path),
                  do: OrcaHubWeb.Markdown.split_blocks(content),
                  else: []

              assign(socket,
                selected_file: path,
                file_content: content,
                file_blocks: blocks,
                file_editing: false,
                editing_block: nil,
                new_file_name: nil
              )

            {:error, _} ->
              put_flash(socket, :error, "Failed to load #{path}")
          end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_project", %{"project" => params}, socket) do
    case HubRPC.update_project(socket.assigns.project, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project)
         |> push_patch(to: ~p"/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}
    end
  end

  def handle_event("validate_project", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project
      |> Project.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, edit_form: to_form(changeset))}
  end

  def handle_event("toggle_archived_sessions", _params, socket) do
    {:noreply, assign(socket, show_archived_sessions: !socket.assigns.show_archived_sessions)}
  end

  def handle_event("browse", _params, socket) do
    home = System.user_home!()
    {:noreply, browse_to(socket, home)}
  end

  def handle_event("browse_navigate", %{"path" => path}, socket) do
    {:noreply, browse_to(socket, path)}
  end

  def handle_event("browse_up", _params, socket) do
    parent = Path.dirname(socket.assigns.browse_path)
    {:noreply, browse_to(socket, parent)}
  end

  def handle_event("browse_select", _params, socket) do
    project = socket.assigns.project
    changeset = Project.changeset(project, %{"directory" => socket.assigns.browse_path})

    {:noreply,
     socket
     |> assign(browsing: false, edit_form: to_form(changeset))}
  end

  def handle_event("browse_close", _params, socket) do
    {:noreply, assign(socket, browsing: false)}
  end

  @impl true
  def handle_event("toggle_hidden_files", _params, socket) do
    show_hidden = !socket.assigns.show_hidden_files
    project = socket.assigns.project
    editable_files = Projects.list_editable_files(project, show_hidden: show_hidden)
    file_tree = Projects.build_file_tree(editable_files)
    filtered = Projects.filter_file_tree(file_tree, socket.assigns.file_tree_filter)

    {:noreply,
     assign(socket,
       show_hidden_files: show_hidden,
       editable_files: editable_files,
       file_tree: file_tree,
       filtered_file_tree: filtered
     )}
  end

  @impl true
  def handle_event("filter_file_tree", %{"value" => query}, socket) do
    filtered = Projects.filter_file_tree(socket.assigns.file_tree, query)
    {:noreply, assign(socket, file_tree_filter: query, filtered_file_tree: filtered)}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    project = socket.assigns.project

    case Projects.load_file(project, path) do
      {:ok, content} ->
        blocks =
          if markdown_file?(path),
            do: OrcaHubWeb.Markdown.split_blocks(content),
            else: []

        {:noreply,
         assign(socket,
           selected_file: path,
           file_content: content,
           file_blocks: blocks,
           file_editing: false,
           editing_block: nil,
           new_file_name: nil
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to load #{path}")}
    end
  end

  def handle_event("edit_file", _params, socket) do
    {:noreply, assign(socket, file_editing: true)}
  end

  def handle_event("cancel_edit_file", _params, socket) do
    if socket.assigns.new_file_name do
      {:noreply, assign(socket, file_editing: false, selected_file: nil, new_file_name: nil)}
    else
      {:noreply, assign(socket, file_editing: false)}
    end
  end

  def handle_event("save_file", params, socket) do
    content = params["content"]
    project = socket.assigns.project

    path =
      if socket.assigns.new_file_name != nil do
        String.trim(params["filename"] || "")
      else
        socket.assigns.selected_file
      end

    if path == "" do
      {:noreply, put_flash(socket, :error, "Please enter a filename")}
    else
      case Projects.save_file(project, path, content) do
      :ok ->
        editable_files = Projects.list_editable_files(project, show_hidden: socket.assigns.show_hidden_files)
        file_tree = Projects.build_file_tree(editable_files)

        blocks =
          if markdown_file?(path),
            do: OrcaHubWeb.Markdown.split_blocks(content),
            else: []

        {:noreply,
         assign(socket,
           file_content: content,
           file_blocks: blocks,
           file_editing: false,
           editing_block: nil,
           selected_file: path,
           new_file_name: nil,
           editable_files: editable_files,
           file_tree: file_tree,
           filtered_file_tree: Projects.filter_file_tree(file_tree, socket.assigns.file_tree_filter)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("new_file", _params, socket) do
    {:noreply,
     assign(socket,
       selected_file: nil,
       new_file_name: "",
       file_content: "",
       file_editing: true
     )}
  end

  def handle_event("deselect_file", _params, socket) do
    {:noreply,
     assign(socket,
       selected_file: nil,
       file_content: nil,
       file_editing: false,
       file_blocks: [],
       editing_block: nil,
       block_edit_content: nil,
       new_file_name: nil
     )}
  end

  def handle_event("edit_block", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {_, text} = Enum.find(socket.assigns.file_blocks, fn {i, _} -> i == index end)
    {:noreply, assign(socket, editing_block: index, block_edit_content: text)}
  end

  def handle_event("cancel_block_edit", _params, socket) do
    {:noreply, assign(socket, editing_block: nil, block_edit_content: nil)}
  end

  def handle_event("delete_block", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)

    blocks =
      socket.assigns.file_blocks
      |> Enum.reject(fn {i, _} -> i == index end)
      |> Enum.with_index()
      |> Enum.map(fn {{_, text}, new_idx} -> {new_idx, text} end)

    full_content = OrcaHubWeb.Markdown.join_blocks(blocks)
    project = socket.assigns.project
    path = socket.assigns.selected_file

    case Projects.save_file(project, path, full_content) do
      :ok ->
        {:noreply,
         assign(socket,
           file_blocks: blocks,
           file_content: full_content,
           editing_block: nil,
           block_edit_content: nil
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("save_block", %{"content" => content}, socket) do
    index = socket.assigns.editing_block

    blocks =
      Enum.map(socket.assigns.file_blocks, fn
        {^index, _} -> {index, String.trim(content)}
        other -> other
      end)

    full_content = OrcaHubWeb.Markdown.join_blocks(blocks)
    project = socket.assigns.project
    path = socket.assigns.selected_file

    case Projects.save_file(project, path, full_content) do
      :ok ->
        {:noreply,
         assign(socket,
           file_blocks: blocks,
           file_content: full_content,
           editing_block: nil,
           block_edit_content: nil
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("create_session", _params, socket) do
    project = socket.assigns.project
    runner_node = socket.assigns.project_node
    params = %{
      "project_id" => project.id,
      "directory" => project.directory,
      "runner_node" => Atom.to_string(runner_node)
    }

    case HubRPC.create_session(params) do
      {:ok, session} ->
        {:ok, _} = Cluster.start_session(runner_node, session.id)
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  # Trigger events

  def handle_event("new_trigger", _params, socket) do
    changeset = Triggers.change_trigger(%Trigger{project_id: socket.assigns.project.id})

    {:noreply,
     assign(socket,
       show_trigger_form: true,
       editing_trigger: nil,
       trigger_type: "scheduled",
       trigger_form: to_form(changeset)
     )}
  end

  def handle_event("edit_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    changeset = Triggers.change_trigger(trigger)

    {:noreply,
     assign(socket,
       show_trigger_form: true,
       editing_trigger: trigger,
       trigger_type: trigger.type,
       trigger_form: to_form(changeset)
     )}
  end

  def handle_event("set_trigger_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, trigger_type: type)}
  end

  def handle_event("cancel_trigger", _params, socket) do
    {:noreply, assign(socket, show_trigger_form: false, editing_trigger: nil)}
  end

  @schedule_presets %{
    "every_15m" => "*/15 * * * *",
    "hourly" => "0 * * * *",
    "daily_9am" => "0 9 * * *",
    "weekdays_9am" => "0 9 * * 1-5",
    "weekly_mon_9am" => "0 9 * * 1",
    "monthly_9am" => "0 9 1 * *"
  }

  def handle_event("set_schedule_preset", %{"schedule_preset" => preset}, socket) do
    case Map.get(@schedule_presets, preset) do
      nil ->
        {:noreply, socket}

      cron ->
        trigger = socket.assigns.editing_trigger || %Trigger{project_id: socket.assigns.project.id}
        current_params = socket.assigns.trigger_form.params || %{}
        updated_params = Map.put(current_params, "cron_expression", cron)
        changeset = Triggers.change_trigger(trigger, updated_params)
        {:noreply, assign(socket, trigger_form: to_form(changeset))}
    end
  end

  def handle_event("validate_trigger", %{"trigger" => params}, socket) do
    trigger = socket.assigns.editing_trigger || %Trigger{project_id: socket.assigns.project.id}
    params = Map.put(params, "type", socket.assigns.trigger_type)
    changeset = Triggers.change_trigger(trigger, params)
    {:noreply, assign(socket, trigger_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_trigger", %{"trigger" => params}, socket) do
    project = socket.assigns.project
    attrs = Map.put(params, "project_id", project.id)
    attrs = Map.put(attrs, "type", socket.assigns.trigger_type)

    result =
      case socket.assigns.editing_trigger do
        nil -> HubRPC.create_trigger(attrs)
        trigger -> HubRPC.update_trigger(trigger, attrs)
      end

    case result do
      {:ok, _} ->
        triggers = HubRPC.list_triggers_for_project(project.id)

        {:noreply,
         assign(socket, triggers: triggers, show_trigger_form: false, editing_trigger: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, trigger_form: to_form(changeset))}
    end
  end

  def handle_event("delete_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    {:ok, _} = HubRPC.delete_trigger(trigger)
    triggers = HubRPC.list_triggers_for_project(socket.assigns.project.id)
    {:noreply, assign(socket, triggers: triggers)}
  end

  def handle_event("toggle_trigger", %{"id" => id}, socket) do
    trigger = HubRPC.get_trigger!(id)
    {:ok, _} = HubRPC.update_trigger(trigger, %{enabled: !trigger.enabled})
    triggers = HubRPC.list_triggers_for_project(socket.assigns.project.id)
    {:noreply, assign(socket, triggers: triggers)}
  end

  def handle_event("fire_trigger", %{"id" => id}, socket) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      OrcaHub.TriggerExecutor.execute(id)
    end)

    {:noreply, put_flash(socket, :info, "Trigger fired")}
  end

  # Git operations

  def handle_event("git_pull", _params, socket) do
    project = socket.assigns.project

    case Projects.git_pull(project) do
      {:ok, output} ->
        commits = Projects.git_log(project)
        current_branch = Projects.git_branch(project)

        {:noreply,
         socket
         |> assign(commits: commits, current_branch: current_branch)
         |> put_flash(:info, output)}

      {:error, output} ->
        {:noreply, put_flash(socket, :error, output)}
    end
  end

  def handle_event("new_worktree", _params, socket) do
    {:noreply, assign(socket, show_worktree_form: true)}
  end

  def handle_event("cancel_worktree", _params, socket) do
    {:noreply, assign(socket, show_worktree_form: false)}
  end

  def handle_event("create_worktree", params, socket) do
    existing = params["existing_branch"] || ""
    new_name = String.trim(params["new_branch"] || "")

    {branch, opts} =
      cond do
        new_name != "" -> {new_name, [new_branch: true]}
        existing != "" -> {existing, []}
        true -> {"", []}
      end

    if branch == "" do
      {:noreply, put_flash(socket, :error, "Select a branch or enter a new branch name")}
    else
      project = socket.assigns.project

      case Projects.git_create_worktree(project, branch, opts) do
        {:ok, _worktree_path} ->
          worktrees = Projects.git_worktree_list(project)
          branches = Projects.git_branches(project)

          {:noreply,
           socket
           |> assign(worktrees: worktrees, branches: branches, show_worktree_form: false)
           |> put_flash(:info, "Worktree created for branch #{branch}")}

        {:error, output} ->
          {:noreply, put_flash(socket, :error, output)}
      end
    end
  end

  def handle_event("worktree_session", %{"path" => path}, socket) do
    project = socket.assigns.project
    runner_node = socket.assigns.project_node
    params = %{
      "project_id" => project.id,
      "directory" => path,
      "runner_node" => Atom.to_string(runner_node)
    }

    case HubRPC.create_session(params) do
      {:ok, session} ->
        {:ok, _} = Cluster.start_session(runner_node, session.id)
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("worktree_rebase", %{"path" => path}, socket) do
    project = socket.assigns.project

    case Projects.git_rebase_worktree(project, path) do
      {:ok, output} ->
        commits = Projects.git_log(project)
        {:noreply, socket |> assign(commits: commits) |> put_flash(:info, "Rebase successful: #{output}")}

      {:error, output} ->
        {:noreply, put_flash(socket, :error, "Rebase failed (auto-aborted): #{output}")}
    end
  end

  def handle_event("worktree_merge", %{"branch" => branch}, socket) do
    project = socket.assigns.project

    case Projects.git_merge_worktree(project, branch) do
      {:ok, output} ->
        commits = Projects.git_log(project)
        current_branch = Projects.git_branch(project)

        {:noreply,
         socket
         |> assign(commits: commits, current_branch: current_branch)
         |> put_flash(:info, "Merged #{branch}: #{output}")}

      {:error, output} ->
        {:noreply, put_flash(socket, :error, "Merge failed: #{output}")}
    end
  end

  def handle_event("worktree_remove", %{"path" => path, "branch" => branch}, socket) do
    project = socket.assigns.project
    dir = project.directory

    case System.cmd("git", ["worktree", "remove", path], cd: dir, stderr_to_stdout: true) do
      {_, 0} ->
        # Also delete the branch
        System.cmd("git", ["branch", "-d", branch], cd: dir, stderr_to_stdout: true)
        worktrees = Projects.git_worktree_list(project)
        {:noreply, socket |> assign(worktrees: worktrees) |> put_flash(:info, "Worktree removed")}

      {output, _} ->
        {:noreply, put_flash(socket, :error, "Remove failed: #{String.trim(output)}")}
    end
  end

  @impl true
  def handle_info({_session_id, _payload}, socket) do
    project = HubRPC.get_project!(socket.assigns.project.id)
    {:noreply, assign(socket, project: project)}
  end

  attr :node, :map, required: true
  attr :selected_file, :string, default: nil

  defp file_tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <li>
      <button
        phx-click="select_file"
        phx-value-path={@node.path}
        class={[@selected_file == @node.path && "active"]}
      >
        <span class="font-mono text-xs truncate">{@node.name}</span>
      </button>
    </li>
    """
  end

  defp file_tree_node(%{node: %{type: :dir}} = assigns) do
    ~H"""
    <li>
      <details open>
        <summary class="font-mono text-xs">
          <.icon name="hero-folder-micro" class="size-3 opacity-50" />
          {@node.name}
        </summary>
        <ul>
          <.file_tree_node
            :for={child <- @node.children}
            node={child}
            selected_file={@selected_file}
          />
        </ul>
      </details>
    </li>
    """
  end

  defp markdown_file?(path), do: String.ends_with?(path, ".md")

  defp file_disk_path(project, path) do
    Path.join(project.directory, path)
  end

  defp find_project!(id) do
    project = HubRPC.get_project!(id)
    {Cluster.project_node_for(project), project}
  end

  defp browse_to(socket, path) do
    target = socket.assigns.project_node

    entries =
      case Cluster.rpc(target, File, :ls, [path]) do
        {:ok, names} ->
          full_paths = Enum.map(names, &Path.join(path, &1))
          dirs = Cluster.rpc(target, Enum, :filter, [full_paths, &File.dir?/1])

          dirs
          |> Enum.reject(fn p -> String.starts_with?(Path.basename(p), ".") end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end
end
