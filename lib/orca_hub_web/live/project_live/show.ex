defmodule OrcaHubWeb.ProjectLive.Show do
  use OrcaHubWeb, :live_view
  require Logger

  alias OrcaHub.{AgentMemory, Cluster, ConfigFile, HubRPC, Projects, Triggers}
  alias OrcaHub.Projects.Project
  alias OrcaHub.Triggers.Trigger
  alias OrcaHubWeb.{BlockEditor, Markdown, StructuredEditor}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
    end

    {project_node, project} = find_project!(id)

    commits = list_result(rpc(project_node, Projects, :git_log, [project]))
    current_branch = string_result(rpc(project_node, Projects, :git_branch, [project]))
    worktrees = list_result(rpc(project_node, Projects, :git_worktree_list, [project]))
    branches = list_result(rpc(project_node, Projects, :git_branches, [project]))

    node_unavailable = node_unavailable_reason(project_node)

    triggers = HubRPC.list_triggers_for_project(project.id)

    agent_memory = load_agent_memory(project_node, project)

    {:ok,
     socket
     |> assign(
       show_archived_sessions: false,
       project: project,
       project_node: project_node,
       node_unavailable: node_unavailable,
       node_unavailable_message:
         node_unavailable && Cluster.node_unavailable_message(node_unavailable),
       page_title: project.name,
       commits: commits,
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
       file_view_mode: :structured,
       structured_editing: nil,
       structured_edit_value: "",
       new_file_name: nil,
       triggers: triggers,
       editing_trigger: nil,
       show_trigger_form: false,
       trigger_type: "scheduled",
       trigger_form: to_form(Triggers.change_trigger(%Trigger{project_id: project.id})),
       project_mcp_servers: HubRPC.list_servers_for_project(project.id),
       all_upstream_servers: HubRPC.list_upstream_servers(),
       show_mcp_server_picker: false,
       edit_form: nil,
       browsing: false,
       browse_path: nil,
       browse_entries: [],
       agent_memory: agent_memory,
       claude_expanded: MapSet.new(),
       claude_editing_filename: nil,
       claude_edit_content: "",
       claude_index_expanded: false,
       claude_editing_index: false,
       claude_index_edit_content: "",
       agents_editing_index: nil,
       agents_edit_text: "",
       codex_expanded: MapSet.new(),
       codex_editing_filename: nil,
       codex_edit_content: ""
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

          case rpc(socket.assigns.project_node, Projects, :load_file, [project, path]) do
            {:ok, content} ->
              blocks = project_file_blocks(path, content)

              assign(socket,
                selected_file: path,
                file_content: content,
                file_blocks: blocks,
                file_editing: false,
                editing_block: nil,
                file_view_mode: :structured,
                structured_editing: nil,
                structured_edit_value: "",
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
      case rpc(socket.assigns.project_node, Projects, :save_file, [project, path, content]) do
        :ok ->
          send_update(OrcaHubWeb.FileTreeComponent, id: "project-file-tree", reload: true)

          blocks = project_file_blocks(path, content)

          {:noreply,
           assign(socket,
             file_content: content,
             file_blocks: blocks,
             file_editing: false,
             editing_block: nil,
             selected_file: path,
             new_file_name: nil
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
       file_view_mode: :structured,
       structured_editing: nil,
       structured_edit_value: "",
       new_file_name: nil
     )}
  end

  # Generic markdown block editing — shared by the project file viewer and
  # all Agent Memory viewers (Claude memories, the Claude MEMORY.md index,
  # Codex native memories). See `content_for/3` / `save_scoped_content/4`
  # for how `scope` routes to each store, and `split_body_blocks/2` for how
  # a Claude memory's frontmatter is kept out of the editable blocks.

  def handle_event("edit_block", %{"scope" => scope, "key" => key, "index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {_frontmatter, blocks} = split_body_blocks(scope, content_for(socket, scope, key))

    case Enum.find(blocks, fn {i, _} -> i == index end) do
      {_, text} ->
        {:noreply,
         assign(socket,
           editing_block: %{scope: scope, key: key, index: index},
           block_edit_content: text
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_block_edit", _params, socket) do
    {:noreply, assign(socket, editing_block: nil, block_edit_content: nil)}
  end

  def handle_event(
        "delete_block",
        %{"scope" => scope, "key" => key, "index" => index_str},
        socket
      ) do
    index = String.to_integer(index_str)
    {frontmatter, blocks} = split_body_blocks(scope, content_for(socket, scope, key))

    new_blocks =
      blocks
      |> Enum.reject(fn {i, _} -> i == index end)
      |> Enum.with_index()
      |> Enum.map(fn {{_, text}, new_idx} -> {new_idx, text} end)

    apply_block_change(socket, scope, key, frontmatter, new_blocks)
  end

  def handle_event("save_block", %{"content" => content}, socket) do
    %{scope: scope, key: key, index: index} = socket.assigns.editing_block
    {frontmatter, blocks} = split_body_blocks(scope, content_for(socket, scope, key))

    new_blocks =
      Enum.map(blocks, fn
        {^index, _} -> {index, String.trim(content)}
        other -> other
      end)

    apply_block_change(socket, scope, key, frontmatter, new_blocks)
  end

  # -------------------------------------------------------------------
  # Structured editing — the project file viewer's only host so far (scope
  # "project_file", single global editing session, same as the markdown
  # block editing above). See `OrcaHubWeb.NodeLive.Show` for the sibling
  # integration; both apply an op via `OrcaHub.ConfigFile.apply_op/3` and
  # persist through their own existing save path.
  # -------------------------------------------------------------------

  def handle_event("toggle_view_mode", %{"scope" => "project_file", "mode" => mode}, socket) do
    mode_atom = if mode == "raw", do: :raw, else: :structured
    {:noreply, assign(socket, file_view_mode: mode_atom)}
  end

  def handle_event("edit_value", %{"scope" => "project_file", "path" => encoded_path}, socket) do
    path = ConfigFile.decode_path(encoded_path)
    format = structured_format(socket.assigns.selected_file)

    with {:ok, tree} <- ConfigFile.parse(format, socket.assigns.file_content),
         %{} = node <- ConfigFile.get_node(tree, path) do
      {:noreply,
       assign(socket,
         structured_editing: %{scope: "project_file", key: "", path: path},
         structured_edit_value: leaf_edit_value(node)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "save_value",
        %{
          "scope" => "project_file",
          "path" => encoded_path,
          "value_type" => value_type,
          "value" => raw_value
        },
        socket
      ) do
    path = ConfigFile.decode_path(encoded_path)
    format = structured_format(socket.assigns.selected_file)

    with {:ok, value} <- ConfigFile.coerce(String.to_existing_atom(value_type), raw_value),
         {:ok, new_content} <-
           ConfigFile.apply_op(format, socket.assigns.file_content, {:set, path, value}) do
      apply_structured_file_change(socket, new_content)
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_key", %{"scope" => "project_file", "path" => encoded_path}, socket) do
    path = ConfigFile.decode_path(encoded_path)
    format = structured_format(socket.assigns.selected_file)

    case ConfigFile.apply_op(format, socket.assigns.file_content, {:delete, path}) do
      {:ok, new_content} ->
        apply_structured_file_change(socket, new_content)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "add_key",
        %{"scope" => "project_file", "path" => encoded_path, "value_type" => value_type} = params,
        socket
      ) do
    path = ConfigFile.decode_path(encoded_path)
    format = structured_format(socket.assigns.selected_file)
    add_key = blank_to_nil(params["name"])

    with {:ok, value} <-
           ConfigFile.coerce(ConfigFile.parse_value_type(value_type), params["value"] || ""),
         {:ok, new_content} <-
           ConfigFile.apply_op(format, socket.assigns.file_content, {:add, path, add_key, value}) do
      apply_structured_file_change(socket, new_content)
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to add: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel", %{"scope" => "project_file"}, socket) do
    {:noreply, assign(socket, structured_editing: nil, structured_edit_value: "")}
  end

  def handle_event("create_session", _params, socket) do
    create_session_with_opts(socket, orchestrator: false)
  end

  def handle_event("create_orchestrator", _params, socket) do
    create_session_with_opts(socket, orchestrator: true)
  end

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
        trigger =
          socket.assigns.editing_trigger || %Trigger{project_id: socket.assigns.project.id}

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

  # MCP server events

  def handle_event("toggle_mcp_server_picker", _params, socket) do
    {:noreply, assign(socket, show_mcp_server_picker: !socket.assigns.show_mcp_server_picker)}
  end

  def handle_event("add_mcp_server", %{"id" => server_id}, socket) do
    project_id = socket.assigns.project.id
    HubRPC.add_server_to_project(project_id, server_id)

    {:noreply,
     socket
     |> assign(
       project_mcp_servers: HubRPC.list_servers_for_project(project_id),
       show_mcp_server_picker: false
     )
     |> put_flash(:info, "MCP server added to project")}
  end

  def handle_event("remove_mcp_server", %{"id" => server_id}, socket) do
    project_id = socket.assigns.project.id
    HubRPC.remove_server_from_project(project_id, server_id)

    {:noreply,
     socket
     |> assign(project_mcp_servers: HubRPC.list_servers_for_project(project_id))
     |> put_flash(:info, "MCP server removed from project")}
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
    target = socket.assigns.project_node

    case rpc(target, Projects, :git_pull, [project]) do
      {:ok, output} ->
        commits = list_result(rpc(target, Projects, :git_log, [project]))
        current_branch = string_result(rpc(target, Projects, :git_branch, [project]))

        {:noreply,
         socket
         |> assign(commits: commits, current_branch: current_branch)
         |> put_flash(:info, output)}

      {:error, output} ->
        message = Cluster.node_unavailable_message({:error, output}) || output
        {:noreply, put_flash(socket, :error, message)}
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

      target = socket.assigns.project_node

      case rpc(target, Projects, :git_create_worktree, [project, branch, opts]) do
        {:ok, _worktree_path} ->
          worktrees = list_result(rpc(target, Projects, :git_worktree_list, [project]))
          branches = list_result(rpc(target, Projects, :git_branches, [project]))

          {:noreply,
           socket
           |> assign(worktrees: worktrees, branches: branches, show_worktree_form: false)
           |> put_flash(:info, "Worktree created for branch #{branch}")}

        {:error, output} ->
          message = Cluster.node_unavailable_message({:error, output}) || output
          {:noreply, put_flash(socket, :error, message)}
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
        case Cluster.start_session(runner_node, session.id, session) do
          {:ok, _} ->
            {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

          {:error, reason} ->
            Logger.error("Failed to start session runner: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Session created but failed to start runner")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("worktree_rebase", %{"path" => path}, socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, Projects, :git_rebase_worktree, [project, path]) do
      {:ok, output} ->
        commits = list_result(rpc(target, Projects, :git_log, [project]))

        {:noreply,
         socket |> assign(commits: commits) |> put_flash(:info, "Rebase successful: #{output}")}

      {:error, output} ->
        message =
          Cluster.node_unavailable_message({:error, output}) ||
            "Rebase failed (auto-aborted): #{output}"

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("worktree_merge", %{"branch" => branch}, socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, Projects, :git_merge_worktree, [project, branch]) do
      {:ok, output} ->
        commits = list_result(rpc(target, Projects, :git_log, [project]))
        current_branch = string_result(rpc(target, Projects, :git_branch, [project]))

        {:noreply,
         socket
         |> assign(commits: commits, current_branch: current_branch)
         |> put_flash(:info, "Merged #{branch}: #{output}")}

      {:error, output} ->
        message = Cluster.node_unavailable_message({:error, output}) || "Merge failed: #{output}"
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("worktree_remove", %{"path" => path, "branch" => branch}, socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node
    dir = project.directory

    case Cluster.rpc(target, System, :cmd, [
           "git",
           ["worktree", "remove", path],
           [cd: dir, stderr_to_stdout: true]
         ]) do
      {_, 0} ->
        # Also delete the branch
        Cluster.rpc(target, System, :cmd, [
          "git",
          ["branch", "-d", branch],
          [cd: dir, stderr_to_stdout: true]
        ])

        worktrees = list_result(rpc(target, Projects, :git_worktree_list, [project]))
        {:noreply, socket |> assign(worktrees: worktrees) |> put_flash(:info, "Worktree removed")}

      # rpc/5's node-unavailable/unassigned refusal — structurally a 2-tuple
      # like System.cmd's {output, exit_code}, so it must be matched before
      # the generic {output, _} clause below (which would otherwise try
      # String.trim/1 on the bare :error atom and crash).
      {:error, reason} when reason in [:node_unassigned] ->
        {:noreply, put_flash(socket, :error, Cluster.node_unavailable_message(reason))}

      {:error, {:node_unavailable, _} = reason} ->
        {:noreply, put_flash(socket, :error, Cluster.node_unavailable_message(reason))}

      {output, _} ->
        {:noreply, put_flash(socket, :error, "Remove failed: #{String.trim(output)}")}
    end
  end

  # Agent Memory — Claude Code

  def handle_event("toggle_claude_memory", %{"filename" => filename}, socket) do
    expanded = socket.assigns.claude_expanded

    expanded =
      if MapSet.member?(expanded, filename),
        do: MapSet.delete(expanded, filename),
        else: MapSet.put(expanded, filename)

    {:noreply, assign(socket, claude_expanded: expanded)}
  end

  def handle_event("edit_claude_memory", %{"filename" => filename}, socket) do
    memory = find_claude_memory(socket, filename)

    {:noreply,
     assign(socket,
       claude_editing_filename: filename,
       claude_edit_content: (memory && memory.content) || ""
     )}
  end

  def handle_event("cancel_edit_claude_memory", _params, socket) do
    {:noreply, assign(socket, claude_editing_filename: nil, claude_edit_content: "")}
  end

  def handle_event("save_claude_memory", %{"filename" => filename, "content" => content}, socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :save_claude_memory, [project.directory, filename, content]) do
      :ok ->
        {:noreply,
         socket
         |> assign(claude_editing_filename: nil, claude_edit_content: "")
         |> refresh_claude_memories()
         |> put_flash(:info, "Saved #{filename}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save #{filename}: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_claude_memory", %{"filename" => filename}, socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :delete_claude_memory, [project.directory, filename]) do
      :ok ->
        {:noreply,
         socket
         |> refresh_claude_memories()
         |> put_flash(:info, "Deleted #{filename}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{filename}: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_claude_index", _params, socket) do
    {:noreply, assign(socket, claude_index_expanded: !socket.assigns.claude_index_expanded)}
  end

  def handle_event("edit_claude_index", _params, socket) do
    content =
      case socket.assigns.agent_memory.claude do
        {:ok, %{index: index}} -> index
        _ -> ""
      end

    {:noreply, assign(socket, claude_editing_index: true, claude_index_edit_content: content)}
  end

  def handle_event("cancel_edit_claude_index", _params, socket) do
    {:noreply, assign(socket, claude_editing_index: false, claude_index_edit_content: "")}
  end

  def handle_event("save_claude_index", %{"content" => content}, socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :save_claude_index, [project.directory, content]) do
      :ok ->
        {:noreply,
         socket
         |> assign(claude_editing_index: false, claude_index_edit_content: "")
         |> refresh_claude_memories()
         |> put_flash(:info, "Saved MEMORY.md")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save MEMORY.md: #{inspect(reason)}")}
    end
  end

  # Agent Memory — AGENTS.md "Project memory" (shared by Codex & pi)

  def handle_event("edit_agents_memory", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    text = find_agents_bullet_text(socket, index)
    {:noreply, assign(socket, agents_editing_index: index, agents_edit_text: text || "")}
  end

  def handle_event("cancel_edit_agents_memory", _params, socket) do
    {:noreply, assign(socket, agents_editing_index: nil, agents_edit_text: "")}
  end

  def handle_event("save_agents_memory", %{"index" => index_str, "text" => text}, socket) do
    index = String.to_integer(index_str)
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :update_agents_md_memory, [project.directory, index, text]) do
      :ok ->
        {:noreply,
         socket
         |> assign(agents_editing_index: nil, agents_edit_text: "")
         |> refresh_agents_md()
         |> put_flash(:info, "Updated AGENTS.md")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update AGENTS.md: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_agents_memory", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :delete_agents_md_memory, [project.directory, index]) do
      :ok ->
        {:noreply,
         socket
         |> refresh_agents_md()
         |> put_flash(:info, "Removed from AGENTS.md")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update AGENTS.md: #{inspect(reason)}")}
    end
  end

  # Agent Memory — Codex (native)

  def handle_event("toggle_codex_memory", %{"filename" => filename}, socket) do
    expanded = socket.assigns.codex_expanded

    expanded =
      if MapSet.member?(expanded, filename),
        do: MapSet.delete(expanded, filename),
        else: MapSet.put(expanded, filename)

    {:noreply, assign(socket, codex_expanded: expanded)}
  end

  def handle_event("edit_codex_memory", %{"filename" => filename}, socket) do
    content = find_codex_memory_content(socket, filename)

    {:noreply,
     assign(socket, codex_editing_filename: filename, codex_edit_content: content || "")}
  end

  def handle_event("cancel_edit_codex_memory", _params, socket) do
    {:noreply, assign(socket, codex_editing_filename: nil, codex_edit_content: "")}
  end

  def handle_event("save_codex_memory", %{"filename" => filename, "content" => content}, socket) do
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :save_codex_memory, [filename, content]) do
      :ok ->
        {:noreply,
         socket
         |> assign(codex_editing_filename: nil, codex_edit_content: "")
         |> refresh_codex()
         |> put_flash(:info, "Saved #{filename}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save #{filename}: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_codex_memory", %{"filename" => filename}, socket) do
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :delete_codex_memory, [filename]) do
      :ok ->
        {:noreply, socket |> refresh_codex() |> put_flash(:info, "Deleted #{filename}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{filename}: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:file_selected, path}, socket) do
    project = socket.assigns.project

    case rpc(socket.assigns.project_node, Projects, :load_file, [project, path]) do
      {:ok, content} ->
        blocks = project_file_blocks(path, content)

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

  def handle_info({_session_id, _payload}, socket) do
    project = HubRPC.get_project!(socket.assigns.project.id)
    {:noreply, assign(socket, project: project)}
  end

  defp file_disk_path(project, path) do
    Path.join(project.directory, path)
  end

  defp find_project!(id) do
    project = HubRPC.get_project!(id)
    {Cluster.project_node_for(project), project}
  end

  defp rpc(target, mod, fun, args), do: Cluster.rpc(target, mod, fun, args)

  defp node_unavailable_reason(n) do
    unless Cluster.node_available?(n), do: {:node_unavailable, n}
  end

  # rpc/5 returns {:error, :node_unassigned | {:node_unavailable, _}} instead
  # of a list when the project's node is offline — fall back to an empty list
  # rather than propagating the error tuple into a template :for.
  defp list_result(result) do
    case result do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp string_result(result) do
    case result do
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Generic markdown block editing (project file viewer + Agent Memory)
  # -------------------------------------------------------------------

  defp project_file_blocks(path, content) do
    if Projects.markdown_file?(path), do: Markdown.split_blocks(content), else: []
  end

  # -------------------------------------------------------------------
  # Structured editing (project file viewer only, scope "project_file")
  # -------------------------------------------------------------------

  # The format a structured editor should use for `path`, or `nil` when
  # there's no adapter for it yet — `nil` falls through to the plain raw
  # `<pre>` view.
  defp structured_format(path) when is_binary(path) do
    cond do
      String.ends_with?(path, ".json") -> :json
      String.ends_with?(path, ".toml") -> :toml
      String.ends_with?(path, ".yml") or String.ends_with?(path, ".yaml") -> :yaml
      true -> nil
    end
  end

  defp structured_format(_path), do: nil

  defp apply_structured_file_change(socket, new_content) do
    project = socket.assigns.project
    path = socket.assigns.selected_file

    case rpc(socket.assigns.project_node, Projects, :save_file, [project, path, new_content]) do
      :ok ->
        send_update(OrcaHubWeb.FileTreeComponent, id: "project-file-tree", reload: true)

        {:noreply,
         assign(socket,
           file_content: new_content,
           structured_editing: nil,
           structured_edit_value: ""
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  defp leaf_edit_value(%{value_type: :null}), do: ""
  defp leaf_edit_value(%{value: value}), do: to_string(value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(str) do
    case String.trim(str) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Resolves the current content for a block-editing `scope`/`key` pair
  # from live socket assigns — used both to look a block up by index and to
  # rebuild the full document around an edited/deleted block.
  defp content_for(socket, "project_file", _key), do: socket.assigns.file_content

  defp content_for(socket, "claude_index", _key) do
    case socket.assigns.agent_memory.claude do
      {:ok, %{index: index}} -> index
      _ -> ""
    end
  end

  defp content_for(socket, "claude_memory", key) do
    case find_claude_memory(socket, key) do
      %{content: content} -> content
      _ -> ""
    end
  end

  defp content_for(socket, "codex_memory", key), do: find_codex_memory_content(socket, key) || ""

  # Splits `content` into editable blocks for `scope`. Claude memory files
  # start with `---`-delimited YAML frontmatter — split_blocks/1 would treat
  # it as an ordinary block (editable/deletable like any paragraph), so it's
  # separated out first and kept out of the editable block list entirely;
  # `apply_block_change/5` re-prepends it verbatim via `Markdown.join_frontmatter/2`.
  defp split_body_blocks("claude_memory", content) do
    {frontmatter, body} = Markdown.split_frontmatter(content)
    {frontmatter, Markdown.split_blocks(body)}
  end

  defp split_body_blocks(_scope, content), do: {nil, Markdown.split_blocks(content)}

  defp apply_block_change(socket, scope, key, frontmatter, blocks) do
    full_content = Markdown.join_frontmatter(frontmatter, Markdown.join_blocks(blocks))

    case save_scoped_content(socket, scope, key, full_content) do
      {:ok, socket} ->
        {:noreply, assign(socket, editing_block: nil, block_edit_content: nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  defp save_scoped_content(socket, "project_file", _key, content) do
    project = socket.assigns.project
    path = socket.assigns.selected_file

    case rpc(socket.assigns.project_node, Projects, :save_file, [project, path, content]) do
      :ok ->
        send_update(OrcaHubWeb.FileTreeComponent, id: "project-file-tree", reload: true)

        {:ok,
         assign(socket, file_content: content, file_blocks: project_file_blocks(path, content))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_scoped_content(socket, "claude_index", _key, content) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :save_claude_index, [project.directory, content]) do
      :ok -> {:ok, refresh_claude_memories(socket)}
      error -> error
    end
  end

  defp save_scoped_content(socket, "claude_memory", key, content) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :save_claude_memory, [project.directory, key, content]) do
      :ok -> {:ok, refresh_claude_memories(socket)}
      error -> error
    end
  end

  defp save_scoped_content(socket, "codex_memory", key, content) do
    target = socket.assigns.project_node

    case rpc(target, AgentMemory, :save_codex_memory, [key, content]) do
      :ok -> {:ok, refresh_codex(socket)}
      error -> error
    end
  end

  # -------------------------------------------------------------------
  # Agent Memory
  # -------------------------------------------------------------------

  defp load_agent_memory(project_node, project) do
    %{
      claude:
        agent_memory_result(
          rpc(project_node, AgentMemory, :list_claude_memories, [project.directory])
        ),
      agents_md:
        agent_memory_result(
          rpc(project_node, AgentMemory, :list_agents_md_memories, [project.directory])
        ),
      codex: agent_memory_result(rpc(project_node, AgentMemory, :list_codex_memories, [])),
      codex_enabled: bool_result(rpc(project_node, AgentMemory, :codex_memories_enabled?, []))
    }
  end

  # Normalizes rpc/5's {:error, ...} tuples (node offline/unassigned) down to
  # `false` — the section is hidden entirely via @node_unavailable in that
  # case anyway, so this only ever matters when the rpc actually succeeded.
  defp bool_result(true), do: true
  defp bool_result(_), do: false

  # rpc/5's node-unassigned/node-unavailable error tuples get normalized to
  # a single {:error, :node_unavailable} shape here, distinct from the
  # AgentMemory module's own {:error, :no_memory_dir | :not_enabled} /
  # :no_file / :no_section results — the template branches on these to
  # decide between "disabled, node offline" vs. "this store legitimately
  # doesn't exist here" messaging.
  defp agent_memory_result({:error, :node_unassigned}), do: {:error, :node_unavailable}
  defp agent_memory_result({:error, {:node_unavailable, _}}), do: {:error, :node_unavailable}
  defp agent_memory_result(other), do: other

  defp find_claude_memory(socket, filename) do
    case socket.assigns.agent_memory.claude do
      {:ok, %{memories: memories}} -> Enum.find(memories, &(&1.filename == filename))
      _ -> nil
    end
  end

  defp find_agents_bullet_text(socket, index) do
    case socket.assigns.agent_memory.agents_md do
      {:ok, bullets} -> Enum.find_value(bullets, fn b -> if b.index == index, do: b.text end)
      _ -> nil
    end
  end

  defp find_codex_memory_content(socket, filename) do
    case socket.assigns.agent_memory.codex do
      {:ok, files} -> Enum.find_value(files, fn f -> if f.filename == filename, do: f.content end)
      _ -> nil
    end
  end

  defp refresh_claude_memories(socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    claude =
      agent_memory_result(rpc(target, AgentMemory, :list_claude_memories, [project.directory]))

    update(socket, :agent_memory, &Map.put(&1, :claude, claude))
  end

  defp refresh_agents_md(socket) do
    project = socket.assigns.project
    target = socket.assigns.project_node

    agents_md =
      agent_memory_result(rpc(target, AgentMemory, :list_agents_md_memories, [project.directory]))

    update(socket, :agent_memory, &Map.put(&1, :agents_md, agents_md))
  end

  defp refresh_codex(socket) do
    target = socket.assigns.project_node
    codex = agent_memory_result(rpc(target, AgentMemory, :list_codex_memories, []))
    update(socket, :agent_memory, &Map.put(&1, :codex, codex))
  end

  # Human label for a Codex memory file's subdir group (nil for top-level
  # canonical/flat files, which render with no badge at all).
  defp codex_group_label(nil), do: nil
  defp codex_group_label("rollout_summaries"), do: "rollout summary"
  defp codex_group_label("skills"), do: "skill"
  defp codex_group_label("extensions"), do: "extension"

  # Codex memory filenames may include a subdir segment (e.g.
  # "rollout_summaries/2026-07-08.md") — "/" is valid in an HTML id but
  # unconventional, so DOM ids swap it for "--" while phx-value-filename
  # (and the form's hidden input) keep the real relative path.
  defp dom_id(str), do: String.replace(str, "/", "--")

  defp browse_to(socket, path) do
    target = socket.assigns.project_node

    entries =
      case rpc(target, File, :ls, [path]) do
        {:ok, names} ->
          full_paths = Enum.map(names, &Path.join(path, &1))
          dirs = rpc(target, Enum, :filter, [full_paths, &File.dir?/1])

          dirs
          |> Enum.reject(fn p -> String.starts_with?(Path.basename(p), ".") end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end

  defp create_session_with_opts(socket, opts) do
    project = socket.assigns.project
    runner_node = socket.assigns.project_node

    params = %{
      "project_id" => project.id,
      "directory" => project.directory,
      "runner_node" => Atom.to_string(runner_node),
      "orchestrator" => Keyword.get(opts, :orchestrator, false)
    }

    case HubRPC.create_session(params) do
      {:ok, session} ->
        case Cluster.start_session(runner_node, session.id, session) do
          {:ok, _} ->
            {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

          {:error, reason} ->
            Logger.error("Failed to start session runner: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Session created but failed to start runner")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end
end
