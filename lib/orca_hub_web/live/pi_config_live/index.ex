defmodule OrcaHubWeb.PiConfigLive.Index do
  @moduledoc """
  Hub-managed pi config (`OrcaHub.PiConfig`) — a single index page with an
  inline create/edit form, since a pi config entry has no per-node/per-project
  scope to browse into a separate Show page. Materializing a row here onto
  every node's disk is entirely `OrcaHub.PiConfigSync`'s job, driven by the
  `{:pi_config_updated}` broadcast this page's writes trigger (see
  `OrcaHub.PiConfig`) — this LiveView also subscribes to that same topic so a
  concurrent edit from another tab/user refreshes the list live.

  ## Model-managed providers

  A `provider` row with a `models_from` config has its `models` array
  resolved hourly from a live `/v1/models` endpoint by `OrcaHub.PiModelSync`.
  Editing such a row through the free-text `spec` textarea would save a
  human's (inevitably stale) copy of the machine-written array back over it,
  silently reverting discovery until the next tick.

  So for a model-managed provider the editor **strips `models` out of the
  editable JSON and re-merges the stored array back in on save** — chosen
  over a read-only render because it makes the race structurally impossible
  rather than merely discouraged. The resolved list is shown read-only
  beneath the textarea, alongside the source URL, the last-refresh time,
  and any `models_refresh_error` (the never-write-an-empty-list rule means
  a gateway that's been down for a week is invisible on disk — this badge
  is the only place it surfaces).
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
       spec_error: nil,
       models_from_text: "",
       models_from_error: nil
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
      spec_error: nil,
      models_from_text: "",
      models_from_error: nil
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
      spec_error: nil,
      models_from_text: models_from_as_string(entry),
      models_from_error: nil
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

    models_from_text = Map.get(params, "models_from", socket.assigns.models_from_text || "")

    # Normalize params for changeset (parse spec_text for provider/setting)
    params = normalize_spec_for_kind_with_text(params, spec_text, kind)
    # Ensure name is included in params to prevent it from being lost on validate
    params = Map.put_new(params, "name", name)

    {params, models_from_error} =
      apply_models_from(params, models_from_text, kind, socket.assigns.editing_entry)

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
       spec_error: spec_error,
       models_from_text: models_from_text,
       models_from_error: models_from_error
     )}
  end

  def handle_event("save", %{"pi_config_entry" => params}, socket) do
    # Extract spec from pi_config_entry params (textarea is now a form field)
    spec_text = Map.get(params, "spec", socket.assigns.spec_text || "")
    # Get kind from params (it may have been changed by the user)
    kind = Map.get(params, "kind", socket.assigns.current_kind)
    # Get name from params, falling back to assign to preserve user input on spec change
    name = Map.get(params, "name", socket.assigns.entry_form.params["name"] || "")

    models_from_text = Map.get(params, "models_from", socket.assigns.models_from_text || "")

    # Normalize params for save (parse spec_text for provider/setting)
    params = normalize_spec_for_kind_with_text(params, spec_text, kind)
    # Ensure name is included in params to prevent it from being lost
    params = Map.put_new(params, "name", name)

    {params, models_from_error} =
      apply_models_from(params, models_from_text, kind, socket.assigns.editing_entry)

    result =
      cond do
        models_from_error ->
          {:error, :models_from}

        is_nil(socket.assigns.editing_entry) ->
          HubRPC.create_pi_config_entry(params)

        true ->
          HubRPC.update_pi_config_entry(socket.assigns.editing_entry, params)
      end

    case result do
      {:ok, entry} ->
        {flash_kind, flash} = post_save_refresh(entry)

        {:noreply,
         socket
         |> assign(
           entries: HubRPC.list_pi_config_entries(),
           show_form: false,
           editing_entry: nil,
           spec_text: "",
           spec_error: nil,
           models_from_text: "",
           models_from_error: nil
         )
         |> put_flash(flash_kind, flash)
         |> push_patch(to: ~p"/settings/pi-config")}

      {:error, :models_from} ->
        {:noreply,
         assign(socket,
           spec_text: spec_text,
           models_from_text: models_from_text,
           models_from_error: models_from_error
         )}

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
           spec_error: spec_error,
           models_from_text: models_from_text,
           models_from_error: models_from_error
         )}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    entry = HubRPC.get_pi_config_entry!(id)
    {:ok, _} = HubRPC.delete_pi_config_entry(entry)

    {:noreply,
     socket
     |> assign(entries: HubRPC.list_pi_config_entries())
     |> put_flash(:info, "Pi config entry deleted")
     |> push_patch(to: ~p"/settings/pi-config")}
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
     |> push_patch(to: ~p"/settings/pi-config")}
  end

  def handle_event("refresh_models", %{"id" => id}, socket) do
    entry = HubRPC.get_pi_config_entry!(id)
    {kind, message} = refresh_flash(entry)

    {:noreply,
     socket
     |> assign(entries: HubRPC.list_pi_config_entries())
     |> put_flash(kind, message)}
  end

  def handle_event("kind_select", %{"kind" => kind}, socket) do
    entry = socket.assigns.editing_entry || %Entry{}
    # Reset spec_text when changing kind
    {:noreply,
     assign(socket,
       current_kind: kind,
       spec_text: "",
       spec_error: nil,
       models_from_text: "",
       models_from_error: nil,
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

  # ── model-managed providers (OrcaHub.PiModelSync) ────────────────────

  @doc "Whether this row's `models` array is resolved from a live endpoint."
  def model_managed?(%{kind: "provider", models_from: config}) when is_map(config), do: true
  def model_managed?(_), do: false

  @doc "The `/v1/models` URL a managed row actually fetches."
  def models_source_url(%{models_from: %{"url" => url}}) when is_binary(url),
    do: OrcaHub.PiModelSync.models_url(url)

  def models_source_url(_), do: nil

  @doc "Model ids currently stored on a row, sorted — rendered read-only for managed rows."
  def model_ids(%{spec: spec}) when is_map(spec) do
    spec
    |> Map.get("models", [])
    |> List.wrap()
    |> Enum.map(&(is_map(&1) && &1["id"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  def model_ids(_), do: []

  def models_from_as_string(%{models_from: config}) when is_map(config),
    do: Jason.encode!(config)

  def models_from_as_string(_), do: ""

  # Parses the models_from textarea. `""` means "not managed" (nil), which
  # is what every row that predates PiModelSync has.
  defp parse_models_from(text) do
    case String.trim(text || "") do
      "" ->
        {:ok, nil}

      json ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _} -> {:error, "must be a JSON object"}
          {:error, _} -> {:error, "is not valid JSON"}
        end
    end
  end

  # Folds the models_from textarea into the changeset params, and — for a
  # provider whose `models` array was STRIPPED out of the spec textarea (see
  # the moduledoc) — folds the stored array back in, so saving an unrelated
  # field can't blow the resolved list away. A `models` key typed into the
  # textarea by hand still wins, which is the escape hatch for fixing a bad
  # entry without waiting for a refresh.
  defp apply_models_from(params, text, "provider", editing_entry) do
    case parse_models_from(text) do
      {:ok, config} ->
        params = Map.put(params, "models_from", config)

        params =
          if model_managed?(editing_entry) and is_map(params["spec"]) do
            stored = List.wrap(editing_entry.spec["models"])
            Map.put(params, "spec", Map.put_new(params["spec"], "models", stored))
          else
            params
          end

        {params, nil}

      {:error, message} ->
        {params, message}
    end
  end

  # Non-provider kinds never carry a models_from — clear any leftover from a
  # kind switch rather than letting it ride along and fail validation.
  defp apply_models_from(params, _text, _kind, _editing_entry),
    do: {Map.put(params, "models_from", nil), nil}

  # A managed provider saved with an empty `models` array would be written to
  # every node's models.json as a provider pi treats as a hard failure, so we
  # resolve it once, inline, instead of leaving that hole open until the
  # hourly tick. An already-populated row is left for the tick.
  defp post_save_refresh(entry) do
    if model_managed?(entry) and model_ids(entry) == [] do
      refresh_flash(entry)
    else
      {:info, "Pi config entry saved"}
    end
  end

  # Gated on the same flag as the periodic loop: an instance with model
  # resolution turned off (notably `mix test`, which boots the full app
  # against the shared dev DB) must never make a live call to the gateway
  # just because a page was rendered or a form was saved.
  defp refresh_flash(entry) do
    if OrcaHub.PiModelSync.enabled?() do
      do_refresh_flash(entry)
    else
      {:error, "#{entry.name}: model resolution is disabled on this instance"}
    end
  end

  defp do_refresh_flash(entry) do
    case HubRPC.refresh_pi_config_entry_models(entry) do
      {:ok, :updated} ->
        {:info, "#{entry.name}: model list refreshed from #{models_source_url(entry)}"}

      {:ok, :unchanged} ->
        {:info, "#{entry.name}: model list already up to date"}

      {:error, reason} when is_binary(reason) ->
        {:error, "#{entry.name}: #{reason} — the stored model list was left untouched"}

      other ->
        {:error, "#{entry.name}: refresh failed (#{inspect(other)})"}
    end
  end

  # Get the current spec value as a string for the form field.
  #
  # A model-managed provider's `models` array is STRIPPED here and re-merged
  # in apply_models_from/4 on save — see the moduledoc. Editing the array by
  # hand in this textarea would otherwise silently revert whatever
  # PiModelSync last resolved.
  def spec_as_string(%{kind: "provider", spec: spec, models_from: config})
      when is_map(config) and is_map(spec),
      do: Jason.encode!(Map.delete(spec, "models"))

  def spec_as_string(%{kind: "provider", spec: spec}), do: Jason.encode!(spec)
  def spec_as_string(%{kind: "setting", spec: spec}), do: Jason.encode!(spec)
  def spec_as_string(%{kind: "extension", spec: spec}), do: spec["body"] || ""
  def spec_as_string(%{kind: "prompt", spec: spec}), do: spec["body"] || ""
  def spec_as_string(%{kind: "theme", spec: spec}), do: spec["body"] || ""
  def spec_as_string(_), do: ""
end
