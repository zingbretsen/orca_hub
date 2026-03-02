defmodule OrcaHubWeb.TriggerLive.Index do
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Projects, Triggers}
  alias OrcaHub.Triggers.Trigger

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_projects()

    {:ok,
     socket
     |> assign(
       projects: projects,
       triggers: Triggers.list_triggers(),
       show_trigger_form: false,
       editing_trigger: nil,
       trigger_form: to_form(Triggers.change_trigger(%Trigger{}))
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Triggers", show_trigger_form: false, editing_trigger: nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Triggers.change_trigger(%Trigger{})

    socket
    |> assign(
      page_title: "New Trigger",
      show_trigger_form: true,
      editing_trigger: nil,
      trigger_form: to_form(changeset)
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    trigger = Triggers.get_trigger!(id)
    changeset = Triggers.change_trigger(trigger)

    socket
    |> assign(
      page_title: "Edit Trigger",
      show_trigger_form: true,
      editing_trigger: trigger,
      trigger_form: to_form(changeset)
    )
  end

  @impl true
  def handle_event("validate_trigger", %{"trigger" => params}, socket) do
    trigger = socket.assigns.editing_trigger || %Trigger{}
    changeset = Triggers.change_trigger(trigger, params)
    {:noreply, assign(socket, trigger_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save_trigger", %{"trigger" => params}, socket) do
    result =
      case socket.assigns.editing_trigger do
        nil -> Triggers.create_trigger(params)
        trigger -> Triggers.update_trigger(trigger, params)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(triggers: Triggers.list_triggers(), show_trigger_form: false, editing_trigger: nil)
         |> push_patch(to: ~p"/triggers")}

      {:error, changeset} ->
        {:noreply, assign(socket, trigger_form: to_form(changeset))}
    end
  end

  def handle_event("delete_trigger", %{"id" => id}, socket) do
    trigger = Triggers.get_trigger!(id)
    {:ok, _} = Triggers.delete_trigger(trigger)
    {:noreply, assign(socket, triggers: Triggers.list_triggers())}
  end

  def handle_event("toggle_trigger", %{"id" => id}, socket) do
    trigger = Triggers.get_trigger!(id)
    {:ok, _} = Triggers.update_trigger(trigger, %{enabled: !trigger.enabled})
    {:noreply, assign(socket, triggers: Triggers.list_triggers())}
  end

  def handle_event("fire_trigger", %{"id" => id}, socket) do
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      OrcaHub.TriggerExecutor.execute(id)
    end)

    {:noreply, put_flash(socket, :info, "Trigger fired")}
  end

  def handle_event("cancel_trigger", _params, socket) do
    {:noreply,
     socket
     |> assign(show_trigger_form: false, editing_trigger: nil)
     |> push_patch(to: ~p"/triggers")}
  end
end
