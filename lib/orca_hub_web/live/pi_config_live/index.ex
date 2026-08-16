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
       entry_form: to_form(PiConfig.change_entry(%Entry{}), as: "pi_config_entry"),
       current_kind: "provider",
       spec_text: "",
       spec_error: nil
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
      entry_form: to_form(PiConfig.change_entry(%Entry{}), as: "pi_config_entry"),
      current_kind: "provider",
      spec_text: "",
      spec_error: nil
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    entry = HubRPC.get_pi_config_entry!(id)

    assign(socket,
      page_title: "Edit Pi Config Entry",
      show_form: true,
      editing_entry: entry,
      entry_form: to_form(PiConfig.change_entry(entry), as: "pi_config_entry"),
      current_kind: entry.kind,
      spec_text: spec_as_string(entry),
      spec_error: nil
    )
  end

  @impl true
  def handle_event("validate", %{"pi_config_entry" => params}, socket) do
    entry = socket.assigns.editing_entry || %Entry{}
    # Extract spec from pi_config_entry params (textarea is now a form field)
    spec_text = Map.get(params, "spec", socket.assigns.spec_text || "")
    # Get kind from params (it may have been changed by the user)
    kind = Map.get(params, "kind", socket.assigns.current_kind)
    # Get name from params, falling back to assign to preserve user input on spec change
    name = Map.get(params, "name", socket.assigns.entry_form.params["name"] || "")

    # Normalize params for changeset (parse spec_text for provider/setting)
    params = normalize_spec_for_kind_with_text(params, spec_text, kind)
    # Ensure name is included in params to prevent it from being lost on validate
    params = Map.put_new(params, "name", name)

    changeset = PiConfig.change_entry(entry, params)

    # Extract any spec error for display
    spec_error =
      case Enum.find(changeset.errors, fn {field, _} -> field == :spec end) do
        {:spec, {msg, _}} -> msg
        _ -> nil
      end

    {:noreply,
     assign(socket,
       entry_form: to_form(changeset, action: :validate, as: "pi_config_entry"),
       spec_text: spec_text,
       spec_error: spec_error
     )}
  end

  def handle_event("save", %{"pi_config_entry" => params}, socket) do
    # Extract spec from pi_config_entry params (textarea is now a form field)
    spec_text = Map.get(params, "spec", socket.assigns.spec_text || "")
    # Get kind from params (it may have been changed by the user)
    kind = Map.get(params, "kind", socket.assigns.current_kind)
    # Get name from params, falling back to assign to preserve user input on spec change
    name = Map.get(params, "name", socket.assigns.entry_form.params["name"] || "")

    # Normalize params for save (parse spec_text for provider/setting)
    params = normalize_spec_for_kind_with_text(params, spec_text, kind)
    # Ensure name is included in params to prevent it from being lost
    params = Map.put_new(params, "name", name)

    result =
      case socket.assigns.editing_entry do
        nil -> HubRPC.create_pi_config_entry(params)
        entry -> HubRPC.update_pi_config_entry(entry, params)
      end

    case result do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(
           entries: HubRPC.list_pi_config_entries(),
           show_form: false,
           editing_entry: nil,
           spec_text: "",
           spec_error: nil
         )
         |> put_flash(:info, "Pi config entry saved")
         |> push_patch(to: ~p"/pi-config")}

      {:error, changeset} ->
        # Extract spec error for display
        spec_error =
          case Enum.find(changeset.errors, fn {field, _} -> field == :spec end) do
            {:spec, {msg, _}} -> msg
            _ -> nil
          end

        {:noreply,
         assign(socket,
           entry_form: to_form(changeset, action: :validate, as: "pi_config_entry"),
           spec_text: spec_text,
           spec_error: spec_error
         )}
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
     |> assign(show_form: false, editing_entry: nil, spec_text: "", spec_error: nil)
     |> push_patch(to: ~p"/pi-config")}
  end

  def handle_event("kind_select", %{"kind" => kind}, socket) do
    entry = socket.assigns.editing_entry || %Entry{}
    # Reset spec_text when changing kind
    {:noreply,
     assign(socket,
       current_kind: kind,
       spec_text: "",
       spec_error: nil,
       entry_form:
         PiConfig.change_entry(entry, %{kind: kind})
         |> to_form(action: :validate, as: "pi_config_entry")
     )}
  end

  @impl true
  def handle_info({:pi_config_updated}, socket) do
    {:noreply, assign(socket, entries: HubRPC.list_pi_config_entries())}
  end

  # Normalize spec based on kind before DB storage, using spec_text assign
  defp normalize_spec_for_kind_with_text(params, spec_text, kind)
       when kind in ["provider", "setting"] do
    # For provider and setting, spec_text should be JSON that we parse
    spec_value =
      case String.trim(spec_text || "") do
        "" ->
          %{}

        s ->
          case Jason.decode(s) do
            {:ok, v} ->
              v

            {:error, _} ->
              # On parse error, use empty map - validation will catch it
              %{}
          end
      end

    Map.put(params, "spec", spec_value)
  end

  defp normalize_spec_for_kind_with_text(params, spec_text, kind)
       when kind in ["extension", "prompt", "theme"] do
    # For file kinds, body is stored directly from spec_text
    spec_value = %{"body" => spec_text || ""}
    Map.put(params, "spec", spec_value)
  end

  defp normalize_spec_for_kind_with_text(params, _spec_text, _kind), do: params

  # Check if spec contains a literal API key (not a reference)
  # This checks the spec_text (raw JSON) since we're not round-tripping through the changeset
  def literal_api_key_warning(%{kind: "provider", spec: spec}) when is_map(spec) do
    case Map.get(spec, "apiKey") do
      key when is_binary(key) ->
        not starts_with_reference?(key)

      _ ->
        false
    end
  end

  def literal_api_key_warning(%{kind: "provider", spec_text: spec_text})
      when is_binary(spec_text) do
    # Check the raw spec_text for an apiKey field
    case Jason.decode(spec_text) do
      {:ok, %{"apiKey" => key}} when is_binary(key) ->
        not starts_with_reference?(key)

      _ ->
        false
    end
  rescue
    _ -> false
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
