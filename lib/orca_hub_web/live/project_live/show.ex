defmodule OrcaHubWeb.ProjectLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Projects, Triggers}
  alias OrcaHub.Projects.Project
  alias OrcaHub.Triggers.Trigger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)
    md_files = Projects.list_markdown_files(project)
    commits = Projects.git_log(project)
    triggers = Triggers.list_triggers_for_project(project.id)

    {:ok,
     socket
     |> assign(
       project: project,
       page_title: project.name,
       commits: commits,
       md_files: md_files,
       selected_file: nil,
       file_content: nil,
       file_editing: false,
       new_file_name: nil,
       triggers: triggers,
       editing_trigger: nil,
       show_trigger_form: false,
       trigger_form: to_form(Triggers.change_trigger(%Trigger{project_id: project.id})),
       edit_form: nil,
       browsing: false,
       browse_path: nil,
       browse_entries: []
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    case socket.assigns.live_action do
      :edit ->
        project = socket.assigns.project
        changeset = Project.changeset(project, %{})
        {:noreply, assign(socket, edit_form: to_form(changeset), page_title: "Edit #{project.name}")}

      :show ->
        {:noreply, assign(socket, edit_form: nil, page_title: socket.assigns.project.name)}
    end
  end

  @impl true
  def handle_event("save_project", %{"project" => params}, socket) do
    case Projects.update_project(socket.assigns.project, params) do
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
  def handle_event("select_file", %{"path" => path}, socket) do
    project = socket.assigns.project

    case Projects.load_markdown_file(project, path) do
      {:ok, content} ->
        {:noreply,
         assign(socket,
           selected_file: path,
           file_content: content,
           file_editing: false,
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
        filename = params["filename"] || ""
        if String.ends_with?(filename, ".md"), do: filename, else: filename <> ".md"
      else
        socket.assigns.selected_file
      end

    if path == "" or path == ".md" do
      {:noreply, put_flash(socket, :error, "Please enter a filename")}
    else
      case Projects.save_markdown_file(project, path, content) do
      :ok ->
        md_files = Projects.list_markdown_files(project)

        {:noreply,
         assign(socket,
           file_content: content,
           file_editing: false,
           selected_file: path,
           new_file_name: nil,
           md_files: md_files
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
     assign(socket, selected_file: nil, file_content: nil, file_editing: false, new_file_name: nil)}
  end

  def handle_event("create_session", _params, socket) do
    project = socket.assigns.project
    params = %{"project_id" => project.id, "directory" => project.directory}

    case OrcaHub.Sessions.create_session(params) do
      {:ok, session} ->
        {:ok, _} = OrcaHub.SessionSupervisor.start_session(session.id)
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  # Trigger events

  def handle_event("new_trigger", _params, socket) do
    changeset = Triggers.change_trigger(%Trigger{project_id: socket.assigns.project.id})

    {:noreply,
     assign(socket, show_trigger_form: true, editing_trigger: nil, trigger_form: to_form(changeset))}
  end

  def handle_event("edit_trigger", %{"id" => id}, socket) do
    trigger = Triggers.get_trigger!(id)
    changeset = Triggers.change_trigger(trigger)

    {:noreply,
     assign(socket, show_trigger_form: true, editing_trigger: trigger, trigger_form: to_form(changeset))}
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
    changeset = Triggers.change_trigger(trigger, params)
    {:noreply, assign(socket, trigger_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_trigger", %{"trigger" => params}, socket) do
    project = socket.assigns.project
    attrs = Map.put(params, "project_id", project.id)

    result =
      case socket.assigns.editing_trigger do
        nil -> Triggers.create_trigger(attrs)
        trigger -> Triggers.update_trigger(trigger, attrs)
      end

    case result do
      {:ok, _} ->
        triggers = Triggers.list_triggers_for_project(project.id)

        {:noreply,
         assign(socket, triggers: triggers, show_trigger_form: false, editing_trigger: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, trigger_form: to_form(changeset))}
    end
  end

  def handle_event("delete_trigger", %{"id" => id}, socket) do
    trigger = Triggers.get_trigger!(id)
    {:ok, _} = Triggers.delete_trigger(trigger)
    triggers = Triggers.list_triggers_for_project(socket.assigns.project.id)
    {:noreply, assign(socket, triggers: triggers)}
  end

  def handle_event("toggle_trigger", %{"id" => id}, socket) do
    trigger = Triggers.get_trigger!(id)
    {:ok, _} = Triggers.update_trigger(trigger, %{enabled: !trigger.enabled})
    triggers = Triggers.list_triggers_for_project(socket.assigns.project.id)
    {:noreply, assign(socket, triggers: triggers)}
  end

  def handle_event("fire_trigger", %{"id" => id}, socket) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      OrcaHub.TriggerExecutor.execute(id)
    end)

    {:noreply, put_flash(socket, :info, "Trigger fired")}
  end

  defp browse_to(socket, path) do
    entries =
      case File.ls(path) do
        {:ok, names} ->
          names
          |> Enum.map(&Path.join(path, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.reject(fn p -> String.starts_with?(Path.basename(p), ".") end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    assign(socket, browsing: true, browse_path: path, browse_entries: entries)
  end
end
