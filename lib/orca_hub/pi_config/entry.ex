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
    |> cast(attrs, [:kind, :name, :spec, :enabled])
    |> update_change(:spec, &stringify/1)
    |> validate_required([:kind, :name])
    |> validate_inclusion(:kind, @kinds)
    # No leading dot (pi's dot-prefixed files are off-limits), no path
    # separators — a `name` becomes a filename for three of the five kinds.
    |> validate_format(:name, ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/,
      message:
        "must start with a letter or digit and contain only letters, digits, dots, hyphens, underscores"
    )
    |> validate_spec()
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

  # Deep string-ification of map keys, so a jsonb round-trip is a no-op.
  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
