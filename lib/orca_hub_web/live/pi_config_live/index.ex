defmodule OrcaHubWeb.PiConfigLive.Index do
  @moduledoc """
  Hub-managed pi config (`OrcaHub.PiConfig`) — a single index page with an
  inline create/edit form, since a pi config entry has no per-node/per-project
  scope to browse into a separate Show page. Materializing a row here onto
  every node's disk is entirely `OrcaHub.PiConfigSync`'s job, driven by the
  `{:pi_config_updated}` broadcast this page's writes trigger (see
  `OrcaHub.PiConfig`) — this LiveView also subscribes to that same topic so a
  concurrent edit from another tab/user refreshes the list live.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.{HubRPC, PiConfig}
  alias OrcaHub.PiConfig.Entry

  # For HTML template - kind labels are available via kind_label/1
  def kinds_for_template, do: ["provider", "setting", "extension", "prompt", "theme"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(OrcaHub.PubSub, PiConfig.topic())

    {:ok,
     socket
     |> assign(
       entries: HubRPC.list_pi_config_entries(),
       show_form: false,
       editing_entry: nil,
       entry_form: to_form(PiConfig.change_entry(%Entry{})),
       current_kind: "provider"
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Pi Config", show_form: false, editing_entry: nil)
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New Pi Config Entry",
      show_form: true,
      editing_entry: nil,
      entry_form: to_form(PiConfig.change_entry(%Entry{})),
      current_kind: "provider"
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    entry = HubRPC.get_pi_config_entry!(id)

    assign(socket,
      page_title: "Edit Pi Config Entry",
      show_form: true,
      editing_entry: entry,
      entry_form: to_form(PiConfig.change_entry(entry)),
      current_kind: entry.kind
    )
  end

  @impl true
  def handle_event("validate", %{"pi_config_entry" => params}, socket) do
    entry = socket.assigns.editing_entry || %Entry{}
    # Normalize spec based on current kind before passing to changeset
    params = normalize_spec_for_kind(params)
    changeset = PiConfig.change_entry(entry, params)
    {:noreply, assign(socket, entry_form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"pi_config_entry" => params}, socket) do
    params = normalize_spec_for_kind(params)

    result =
      case socket.assigns.editing_entry do
        nil -> HubRPC.create_pi_config_entry(params)
        entry -> HubRPC.update_pi_config_entry(entry, params)
      end

    case result do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(entries: HubRPC.list_pi_config_entries(), show_form: false, editing_entry: nil)
         |> put_flash(:info, "Pi config entry saved")
         |> push_patch(to: ~p"/pi-config")}

      {:error, changeset} ->
        {:noreply, assign(socket, entry_form: to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    entry = HubRPC.get_pi_config_entry!(id)
    {:ok, _} = HubRPC.delete_pi_config_entry(entry)

    {:noreply,
     socket
     |> assign(entries: HubRPC.list_pi_config_entries())
     |> put_flash(:info, "Pi config entry deleted")}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    entry = HubRPC.get_pi_config_entry!(id)
    {:ok, _} = HubRPC.update_pi_config_entry(entry, %{enabled: !entry.enabled})

    {:noreply, assign(socket, entries: HubRPC.list_pi_config_entries())}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(show_form: false, editing_entry: nil)
     |> push_patch(to: ~p"/pi-config")}
  end

  def handle_event("kind_select", %{"kind" => kind}, socket) do
    entry = socket.assigns.editing_entry || %Entry{}
    # Clear spec when changing kind
    params = %{"kind" => kind}

    form =
      PiConfig.change_entry(entry, params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, current_kind: kind, entry_form: form)}
  end

  @impl true
  def handle_info({:pi_config_updated}, socket) do
    {:noreply, assign(socket, entries: HubRPC.list_pi_config_entries())}
  end

  # Normalize spec based on kind before DB storage
  defp normalize_spec_for_kind(%{"kind" => kind, "spec" => spec} = params)
       when kind in ["provider", "setting"] do
    # For provider and setting, spec should be a JSON string that we parse
    spec_value =
      case spec do
        "" ->
          %{}

        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, v} -> v
            {:error, _} -> %{}
          end

        s ->
          s
      end

    Map.put(params, "spec", spec_value)
  end

  defp normalize_spec_for_kind(%{"kind" => kind, "spec" => spec} = params)
       when kind in ["extension", "prompt", "theme"] do
    # For file kinds, body is stored directly
    spec_value = %{"body" => spec || ""}
    Map.put(params, "spec", spec_value)
  end

  defp normalize_spec_for_kind(params), do: params

  # Check if spec contains a literal API key (not a reference)
  def literal_api_key_warning(%{kind: "provider", spec: spec}) when is_map(spec) do
    case Map.get(spec, "apiKey") do
      key when is_binary(key) ->
        not starts_with_reference?(key)

      _ ->
        false
    end
  end

  def literal_api_key_warning(_), do: false

  # Check if a string starts with $ or ! (reference pattern)
  defp starts_with_reference?(str),
    do: String.starts_with?(str, "$") or String.starts_with?(str, "!")

  # Group entries by kind for display
  def entries_by_kind(entries) do
    Enum.reduce(entries, Map.new(), fn entry, acc ->
      kind = entry.kind
      Map.update(acc, kind, [entry], &[entry | &1])
    end)
    |> Map.new(fn {kind, list} -> {kind, Enum.sort_by(list, & &1.name)} end)
  end

  def kind_label("provider"), do: "Provider (models.json)"
  def kind_label("setting"), do: "Setting (settings.json)"
  def kind_label("extension"), do: "Extension (.ts)"
  def kind_label("prompt"), do: "Prompt (.md)"
  def kind_label("theme"), do: "Theme (.json)"

  def kind_help("provider"), do: "Provider key for models.json (e.g. \"ollama\", \"openai\")"
  def kind_help("setting"), do: "Top-level settings.json key (e.g. \"defaultModel\")"
  def kind_help("extension"), do: "File stem written into extensions/ (e.g. \"my-extension\")"
  def kind_help("prompt"), do: "File stem written into prompts/ (e.g. \"my-prompt\")"
  def kind_help("theme"), do: "File stem written into themes/ (e.g. \"my-theme\")"

  def truncate(nil, _len), do: ""

  def truncate(str, len) when is_binary(str) do
    if String.length(str) > len, do: String.slice(str, 0, len) <> "…", else: str
  end

  # Get the current spec value as a string for the form field
  def spec_as_string(%{kind: "provider", spec: spec}), do: Jason.encode!(spec)
  def spec_as_string(%{kind: "setting", spec: spec}), do: Jason.encode!(spec)
  def spec_as_string(%{kind: "extension", spec: spec}), do: spec["body"] || ""
  def spec_as_string(%{kind: "prompt", spec: spec}), do: spec["body"] || ""
  def spec_as_string(%{kind: "theme", spec: spec}), do: spec["body"] || ""
  def spec_as_string(_), do: ""
end
