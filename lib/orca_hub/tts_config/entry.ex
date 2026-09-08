defmodule OrcaHub.TTSConfig.Entry do
  @moduledoc """
  Schema for one hub-managed piece of TTS config, consumed by
  `OrcaHubWeb.TTSController` through `OrcaHub.TTSConfig.resolve/0`.

  Same `kind`/`name`/`spec`/`enabled` shape as `OrcaHub.PiConfig.Entry`:

    * `"tts_provider"` — the ACTIVE provider settings. There is exactly one
      such row, named `"active"` (`OrcaHub.TTSConfig.provider_name/0`), and
      `spec` holds `%{"provider" => "local" | "elevenlabs", "url" => ...,
      "language" => ...}`. Any of those keys may be blank or absent, in which
      case that ONE field falls back to its env var — see
      `OrcaHub.TTSConfig.resolve/0`. `enabled: false` disables the whole
      row, reverting every field to env without having to delete it.

    * `"tts_model"` — one row per synthesis model the user wants to keep in
      their catalog; `name` is the model id sent as `"model"` to the
      gateway. `enabled` doubles as the default-selection flag, and
      `OrcaHub.TTSConfig.set_default_model/1` keeps at most one enabled.
      `spec` is free-form annotation (`%{"label" => ..., "notes" => ...}`) —
      nothing in the request path reads it.

  `spec` is deep-stringified on cast so a struct built from atom-keyed attrs
  reads identically to one loaded back from jsonb.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @kinds ~w(tts_provider tts_model)
  @providers ~w(local elevenlabs)

  schema "tts_config_entries" do
    field :kind, :string
    field :name, :string
    field :spec, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps()
  end

  @doc "The two config surfaces an entry can target, as strings."
  def kinds, do: @kinds

  @doc "The provider values `POST /api/tts` knows how to dispatch on."
  def providers, do: @providers

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :name, :spec, :enabled])
    |> update_change(:spec, &stringify/1)
    |> validate_required([:kind, :name])
    |> validate_inclusion(:kind, @kinds)
    # A model `name` is sent verbatim to the gateway as its "model" field, so
    # keep it to the shape model ids actually take rather than accepting
    # whitespace/newlines that would produce a confusing upstream 400.
    |> validate_format(:name, ~r/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/,
      message:
        "must start with a letter or digit and contain only letters, digits, dots, hyphens, underscores, slashes"
    )
    |> validate_spec()
    |> unique_constraint(:name,
      name: :tts_config_entries_kind_name_index,
      message: "has already been taken for this kind"
    )
  end

  # Only the provider row constrains its spec — a blank field there is
  # legitimate (it means "fall back to env for this one field"), so the only
  # thing worth rejecting is a provider string the controller can't dispatch.
  defp validate_spec(changeset) do
    spec = get_field(changeset, :spec)

    cond do
      not is_map(spec) ->
        add_error(changeset, :spec, "must be a map")

      get_field(changeset, :kind) == "tts_provider" and
          not (blank?(spec["provider"]) or spec["provider"] in @providers) ->
        add_error(changeset, :spec, "provider must be one of: #{Enum.join(@providers, ", ")}")

      true ->
        changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
