defmodule OrcaHub.TTSConfig do
  @moduledoc """
  Context for hub-managed text-to-speech config — the active provider and a
  user-maintained catalog of synthesis models — read by
  `OrcaHubWeb.TTSController` on every `POST /api/tts`.

  Same table shape as `OrcaHub.PiConfig` (`kind`/`name`/`spec`/`enabled`),
  for the same reason: a typed config surface plus a catalog the user CRUDs,
  without a singleton row and without reviving the generic `settings` k/v
  table that was deliberately dropped in `5754eb3`.

  ## Resolution: DB wins, else env, else hardcoded — PER FIELD

  `resolve/0` decides four fields independently. For each one it takes the
  first non-blank of:

    1. the DB value (the `"tts_provider"` row's `spec` for provider/url/
       language; the enabled `"tts_model"` row's `name` for the model),
    2. the corresponding `TTS_*` env var (`config/runtime.exs`),
    3. the hardcoded default.

  The per-field part is load-bearing. A provider row that sets only
  `"provider"` must NOT suppress `TTS_URL`/`TTS_LANGUAGE` for the fields it
  leaves blank — a half-filled row is a partial override, not a whole-config
  takeover. Likewise an EMPTY model catalog means "use `TTS_MODEL`", not "no
  model available", which is why the migration seeds nothing: a fresh DB
  behaves exactly like the pre-migration build.

  ## No cache, deliberately

  `resolve/0` queries inside the request. `POST /api/tts` is a very low-QPS
  path, and a cache is the one thing that could stop a provider/model change
  taking effect on the very next request — which is the entire point of
  moving this config into the DB. Do not add ETS or `:persistent_term` here.

  ## Default model selection

  `enabled` on a `"tts_model"` row doubles as "this is the default".
  `set_default_model/1` enables exactly one row and disables the rest in a
  transaction. Zero enabled rows is a legitimate state (delete the default,
  or never mark one) and means the model field falls back to env.
  """

  import Ecto.Query
  require Logger

  alias OrcaHub.Repo
  alias OrcaHub.TTSConfig.Entry

  @topic "tts_config"

  @provider_kind "tts_provider"
  @model_kind "tts_model"

  # The single provider row's `name`. Uniqueness is on [:kind, :name], so
  # pinning the name is what makes "there is exactly one provider row" true.
  @provider_name "active"

  # Terminal fallbacks, byte-identical to the ones the controller carried
  # before this table existed.
  @default_provider "local"
  @default_url "https://ai.lab.ingbretsenhome.com"
  @default_model "tts-chatterbox-23lang"
  @default_language "en"

  @doc "The PubSub topic mutations broadcast on."
  def topic, do: @topic

  def provider_kind, do: @provider_kind
  def model_kind, do: @model_kind
  def provider_name, do: @provider_name

  @doc """
  The effective TTS config for this request: `%{provider:, url:, model:,
  language:}`, each field resolved DB → env → hardcoded independently.

  A DB read failure degrades to env-only rather than failing the request —
  synthesis with the env config is strictly better than a 500, and the hub
  being unable to reach its own Repo is already visible everywhere else.
  """
  def resolve do
    {provider_spec, model_name} = db_config()

    %{
      provider: pick(provider_spec["provider"], :tts_provider, @default_provider),
      url: pick(provider_spec["url"], :tts_url, @default_url),
      language: pick(provider_spec["language"], :tts_language, @default_language),
      model: pick(model_name, :tts_model, @default_model)
    }
  end

  @doc """
  The env-and-hardcoded half of `resolve/0`, with no DB read at all — what
  every field would fall back to if its DB value were blank. The Settings UI
  renders these as placeholders so a blank input visibly shows what it will
  inherit.
  """
  def env_defaults do
    %{
      provider: pick(nil, :tts_provider, @default_provider),
      url: pick(nil, :tts_url, @default_url),
      language: pick(nil, :tts_language, @default_language),
      model: pick(nil, :tts_model, @default_model)
    }
  end

  defp pick(db_value, env_key, default) do
    blank_to_nil(db_value) || blank_to_nil(Application.get_env(:orca_hub, env_key)) || default
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # Both DB reads for one resolution, so a Repo outage degrades the whole
  # resolve to env exactly once instead of half-degrading it.
  defp db_config do
    {provider_spec(), default_model_name()}
  rescue
    error ->
      Logger.warning("TTSConfig: falling back to env config, DB read failed: #{inspect(error)}")
      {%{}, nil}
  catch
    :exit, reason ->
      Logger.warning("TTSConfig: falling back to env config, DB read exited: #{inspect(reason)}")
      {%{}, nil}
  end

  # A disabled provider row is treated exactly like a missing one: every
  # field reverts to env, without the user having to delete their settings.
  defp provider_spec do
    case get_provider_entry() do
      %Entry{enabled: true, spec: spec} when is_map(spec) -> spec
      _ -> %{}
    end
  end

  defp default_model_name do
    case default_model() do
      %Entry{name: name} -> name
      nil -> nil
    end
  end

  # ── Provider row ───────────────────────────────────────────────────────

  def get_provider_entry, do: Repo.get_by(Entry, kind: @provider_kind, name: @provider_name)

  @doc """
  Upserts the single provider row. `attrs` carries `provider`/`url`/
  `language` (string or atom keys); a blank value is stored as-is and read
  back as "fall back to env for this field".
  """
  def put_provider(attrs) do
    spec =
      %{
        "provider" => fetch(attrs, :provider),
        "url" => fetch(attrs, :url),
        "language" => fetch(attrs, :language)
      }

    enabled = Map.get(attrs, :enabled, Map.get(attrs, "enabled", true))
    entry_attrs = %{kind: @provider_kind, name: @provider_name, spec: spec, enabled: enabled}

    result =
      case get_provider_entry() do
        nil -> Entry.changeset(%Entry{}, entry_attrs) |> Repo.insert()
        entry -> Entry.changeset(entry, entry_attrs) |> Repo.update()
      end

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  @doc "A changeset for the provider row, for `to_form/1` in the Settings UI."
  def change_provider(entry \\ nil, attrs \\ %{}) do
    Entry.changeset(entry || %Entry{kind: @provider_kind, name: @provider_name}, attrs)
  end

  defp fetch(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, to_string(key)))
    if is_binary(value), do: String.trim(value), else: value || ""
  end

  # ── Model catalog ──────────────────────────────────────────────────────

  def list_models do
    Repo.all(from e in Entry, where: e.kind == ^@model_kind, order_by: [asc: e.name])
  end

  @doc """
  The model marked default, or `nil` when the catalog is empty or nothing is
  marked. Ordered by name so a catalog that somehow has two enabled rows
  (concurrent writes racing) still resolves deterministically.
  """
  def default_model do
    Repo.one(
      from e in Entry,
        where: e.kind == ^@model_kind and e.enabled == true,
        order_by: [asc: e.name],
        limit: 1
    )
  end

  def get_model!(id), do: Repo.get_by!(Entry, id: id, kind: @model_kind)
  def get_model(id), do: Repo.get_by(Entry, id: id, kind: @model_kind)

  @doc """
  Adds a model to the catalog. It becomes the default only when nothing is
  currently marked — adding a second model must not silently repoint
  synthesis at it.
  """
  def create_model(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("kind", @model_kind)
      |> Map.put("enabled", is_nil(default_model()))

    result = %Entry{} |> Entry.changeset(attrs) |> Repo.insert()

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  @doc """
  Updates a catalog row's name/spec. `enabled` is deliberately NOT settable
  here — default selection goes through `set_default_model/1`, which is what
  keeps the at-most-one invariant.
  """
  def update_model(%Entry{kind: @model_kind} = entry, attrs) do
    attrs = attrs |> stringify_keys() |> Map.drop(["kind", "enabled"])

    result = entry |> Entry.changeset(attrs) |> Repo.update()

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  def delete_model(%Entry{kind: @model_kind} = entry) do
    result = Repo.delete(entry)

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  @doc """
  Marks one catalog row as the default, disabling every other in the same
  transaction so "exactly one enabled" can't be observed as two.
  """
  def set_default_model(%Entry{kind: @model_kind, id: id} = entry) do
    result =
      Repo.transaction(fn ->
        Repo.update_all(
          from(e in Entry, where: e.kind == ^@model_kind and e.id != ^id),
          set: [enabled: false]
        )

        Repo.update_all(from(e in Entry, where: e.id == ^id), set: [enabled: true])

        %{entry | enabled: true}
      end)

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  @doc """
  Clears the default selection, reverting the model field to `TTS_MODEL`
  without deleting anything from the catalog.
  """
  def clear_default_model do
    {count, _} =
      Repo.update_all(from(e in Entry, where: e.kind == ^@model_kind), set: [enabled: false])

    notify_change()
    {:ok, count}
  end

  def change_model(entry \\ %Entry{kind: @model_kind}, attrs \\ %{}) do
    Entry.changeset(entry, Map.put(stringify_keys(attrs), "kind", @model_kind))
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, @topic, {:tts_config_updated})
  end
end
