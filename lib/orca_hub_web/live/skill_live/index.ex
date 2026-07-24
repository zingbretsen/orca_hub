defmodule OrcaHubWeb.SkillLive.Index do
  @moduledoc """
  Global hub-managed skills (`OrcaHub.Skills`) — a single index page with an
  inline create/edit form (same pattern as `TriggerLive.Index`), since a
  skill has no per-node/per-project scope to browse into a separate Show
  page. Materializing a row here onto every node's disk is entirely
  `OrcaHub.SkillSync`'s job, driven by the `{:skills_updated}` broadcast this
  page's writes trigger (see `OrcaHub.Skills`) — this LiveView also
  subscribes to that same topic so a concurrent edit from another tab/user
  refreshes the list live.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.{HubRPC, Skills}
  alias OrcaHub.Skills.Skill

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(OrcaHub.PubSub, "skills")

    {:ok,
     socket
     |> assign(
       skills: HubRPC.list_skills(),
       show_form: false,
       editing_skill: nil,
       skill_form: to_form(Skills.change_skill(%Skill{}))
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Skills", show_form: false, editing_skill: nil)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Skill",
      show_form: true,
      editing_skill: nil,
      skill_form: to_form(Skills.change_skill(%Skill{}))
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    skill = HubRPC.get_skill!(id)

    assign(socket,
      page_title: "Edit Skill",
      show_form: true,
      editing_skill: skill,
      skill_form: to_form(Skills.change_skill(skill))
    )
  end

  @impl true
  def handle_event("validate", %{"skill" => params}, socket) do
    skill = socket.assigns.editing_skill || %Skill{}
    changeset = Skills.change_skill(skill, normalize_backends(params))
    {:noreply, assign(socket, skill_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"skill" => params}, socket) do
    params = normalize_backends(params)

    result =
      case socket.assigns.editing_skill do
        nil -> HubRPC.create_skill(params)
        skill -> HubRPC.update_skill(skill, params)
      end

    case result do
      {:ok, _skill} ->
        {:noreply,
         socket
         |> assign(skills: HubRPC.list_skills(), show_form: false, editing_skill: nil)
         |> put_flash(:info, "Skill saved")
         |> push_patch(to: ~p"/skills")}

      {:error, changeset} ->
        {:noreply, assign(socket, skill_form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    skill = HubRPC.get_skill!(id)
    {:ok, _} = HubRPC.delete_skill(skill)

    {:noreply,
     socket
     |> assign(skills: HubRPC.list_skills())
     |> put_flash(:info, "Skill deleted")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    skill = HubRPC.get_skill!(id)
    {:ok, _} = HubRPC.update_skill(skill, %{enabled: !skill.enabled})

    {:noreply, assign(socket, skills: HubRPC.list_skills())}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(show_form: false, editing_skill: nil)
     |> push_patch(to: ~p"/skills")}
  end

  @impl true
  def handle_info({:skills_updated}, socket) do
    {:noreply, assign(socket, skills: HubRPC.list_skills())}
  end

  def known_backends, do: Skill.known_backends()

  def truncate(nil, _len), do: ""

  def truncate(str, len) do
    if String.length(str) > len, do: String.slice(str, 0, len) <> "…", else: str
  end

  # The multi-checkbox backend picker always submits a leading "" (from the
  # hidden fallback input that guarantees the key exists when every box is
  # unchecked) — strip it before it ever reaches the changeset.
  defp normalize_backends(%{"backends" => list} = params) when is_list(list) do
    Map.put(params, "backends", Enum.reject(list, &(&1 == "")))
  end

  defp normalize_backends(params), do: params
end
