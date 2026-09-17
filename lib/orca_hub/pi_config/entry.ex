defmodule OrcaHub.PiConfig.Entry do
  @moduledoc """
  Schema for one hub-managed piece of pi global config — see
  `OrcaHub.PiConfigSync` for how a row here becomes a file (or a key inside
  a file) under a node's `~/.pi/agent/`.

  `kind` picks the surface, `name` is that surface's key, and `spec` holds
  the payload:

    * `"provider"` — `name` is the `models.json` provider key (e.g.
      `"ollama"`); `spec` is the full provider config map
      (`%{"baseUrl" => ..., "api" => ..., "apiKey" => ..., "models" => [...]}`).
    * `"setting"` — `name` is a TOP-LEVEL `settings.json` key (e.g.
      `"defaultModel"`); `spec` is `%{"value" => <any json>}`.
    * `"extension"` / `"prompt"` / `"theme"` — `name` is the file stem
      written into `extensions/`, `prompts/`, or `themes/` (the extension is
      fixed per kind: `.ts`, `.md`, `.json`); `spec` is `%{"body" => text}`.

  `spec` is deep-stringified on cast, so a struct built from atom-keyed
  attrs reads the same as one loaded back from jsonb — `PiConfigSync` can
  rely on string keys everywhere without re-normalizing.

  ## `models_from` — dynamic model-list resolution (providers only)

  A `provider` row may opt into having its `spec["models"]` list resolved
  from a live OpenAI-compatible `/v1/models` endpoint instead of being
  hand-authored — see `OrcaHub.PiModelSync`. `models_from` is nil by
  default, and a nil means "not managed": the row keeps today's fully
  hand-authored behaviour and nothing ever rewrites it.

  It's a COLUMN rather than a `spec` key on purpose — `spec` is written
  verbatim into `models.json`, where a marker would be dead weight pi never
  reads. Accepted shape:

      %{"url" => "http://ai.lab.ingbretsenhome.com/v1/models",   # required
        "defaults" => %{"contextWindow" => 131072, ...},          # per-model fallbacks for NEW ids
        "include_ids" => ["a", "b"],                              # allow-list, if present
        "exclude_ids" => ["tts-chatterbox-23lang"],               # deny-list
        "exclude_id_patterns" => ["^tts-"],                       # deny-list, regexes
        "timeout_ms" => 10_000}

  `models_refreshed_at` is the last SUCCESSFUL resolution and
  `models_refresh_error` the last failure (cleared on the next success);
  both are written by `PiModelSync`, not by a human editing the form.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @kinds ~w(provider extension setting prompt theme)

  # Kinds materialized as one file per entry, and the extension pi expects
  # for each (docs: extensions.md, prompt-templates.md, themes.md).
  @file_kinds %{"extension" => ".ts", "prompt" => ".md", "theme" => ".json"}

  schema "pi_config_entries" do
    field :kind, :string
    field :name, :string
    field :spec, :map, default: %{}
    field :enabled, :boolean, default: true

    # Dynamic model-list resolution (providers only) — see the moduledoc
    # and OrcaHub.PiModelSync. Naive UTC, matching this table's timestamps().
    field :models_from, :map
    field :models_refreshed_at, :naive_datetime
    field :models_refresh_error, :string

    timestamps()
  end

  @doc "The five config surfaces an entry can target, as strings."
  def kinds, do: @kinds

  @doc "Kind -> file extension, for the three file-per-entry kinds."
  def file_kinds, do: @file_kinds

  @doc "File extension for a file-per-entry kind (`nil` for provider/setting)."
  def extension_for(kind), do: Map.get(@file_kinds, kind)

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :kind,
      :name,
      :spec,
      :enabled,
      :models_from,
      :models_refreshed_at,
      :models_refresh_error
    ])
    |> update_change(:spec, &stringify/1)
    |> update_change(:models_from, &stringify/1)
    |> validate_required([:kind, :name])
    |> validate_inclusion(:kind, @kinds)
    # No leading dot (pi's dot-prefixed files are off-limits), no path
    # separators — a `name` becomes a filename for three of the five kinds.
    |> validate_format(:name, ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/,
      message:
        "must start with a letter or digit and contain only letters, digits, dots, hyphens, underscores"
    )
    |> validate_spec()
    |> validate_models_from()
    # Error reported on :name (not the composite's first field, :kind) — the
    # name is what a caller can actually change to resolve the collision.
    |> unique_constraint(:name,
      name: :pi_config_entries_kind_name_index,
      message: "has already been taken for this kind"
    )
  end

  defp validate_spec(changeset) do
    kind = get_field(changeset, :kind)
    spec = get_field(changeset, :spec)

    cond do
      not is_map(spec) ->
        add_error(changeset, :spec, "must be a map")

      kind == "provider" and map_size(spec) == 0 ->
        add_error(
          changeset,
          :spec,
          "must contain the provider config (baseUrl, api, models, ...)"
        )

      kind == "setting" and not Map.has_key?(spec, "value") ->
        add_error(changeset, :spec, ~s(must contain a "value" key))

      Map.has_key?(@file_kinds, kind) and not is_binary(spec["body"]) ->
        add_error(changeset, :spec, ~s(must contain a "body" string))

      true ->
        changeset
    end
  end

  # `models_from` is opt-in and providers-only. Validated eagerly here
  # rather than in PiModelSync so a typo'd URL is a form error at save time
  # instead of an hourly log line nobody reads.
  defp validate_models_from(changeset) do
    case get_field(changeset, :models_from) do
      nil ->
        changeset

      config when is_map(config) ->
        kind = get_field(changeset, :kind)

        cond do
          kind != "provider" ->
            add_error(changeset, :models_from, ~s(is only supported for kind "provider"))

          not valid_url?(config["url"]) ->
            add_error(changeset, :models_from, ~s|must contain a "url" (http:// or https://)|)

          not is_nil(config["defaults"]) and not is_map(config["defaults"]) ->
            add_error(changeset, :models_from, ~s("defaults" must be a map))

          bad_id_list = first_bad_id_list(config) ->
            add_error(changeset, :models_from, ~s("#{bad_id_list}" must be a list of strings))

          bad_pattern = first_bad_pattern(config) ->
            add_error(
              changeset,
              :models_from,
              ~s("exclude_id_patterns" contains an invalid regex: #{bad_pattern})
            )

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :models_from, "must be a map")
    end
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  defp first_bad_id_list(config) do
    Enum.find(["include_ids", "exclude_ids", "exclude_id_patterns"], fn key ->
      case config[key] do
        nil -> false
        list when is_list(list) -> not Enum.all?(list, &is_binary/1)
        _ -> true
      end
    end)
  end

  defp first_bad_pattern(config) do
    config
    |> Map.get("exclude_id_patterns", [])
    |> List.wrap()
    |> Enum.find(fn pattern ->
      is_binary(pattern) and match?({:error, _}, Regex.compile(pattern))
    end)
  end

  # Deep string-ification of map keys, so a jsonb round-trip is a no-op.
  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
