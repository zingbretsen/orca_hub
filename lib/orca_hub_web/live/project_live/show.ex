defmodule OrcaHubWeb.ProjectLive.Show do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Projects, Triggers}
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
       trigger_form: to_form(Triggers.change_trigger(%Trigger{project_id: project.id}))
     )}
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
end
