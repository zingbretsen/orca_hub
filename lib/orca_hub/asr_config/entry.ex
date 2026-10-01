defmodule OrcaHub.ASRConfig.Entry do
  @moduledoc """
  Schema for the hub-managed speech-recognition config read through
  `OrcaHub.ASRConfig.resolve/0`.

  Same `kind`/`name`/`spec`/`enabled` shape as `OrcaHub.TTSConfig.Entry`, in
  its own table for the same reason the two contexts are separate modules:
  the ASR sync lane has no model catalog and no provider choice, so the only
  thing the two schemas would actually share is four column names. There is
  exactly ONE kind here:

    * `"asr_provider"` — the active transcription settings. Exactly one row,
      named `"active"` (`OrcaHub.ASRConfig.provider_name/0`), whose `spec`
      holds `%{"url" => ..., "path" => ..., "language" => ...,
      "timeout_ms" => ..., "warmup_timeout_ms" => ..., "threshold" => ...,
      "echo_cancellation" => ..., "noise_suppression" => ...,
      "auto_gain_control" => ..., "release_mic_during_playback" => ...,
      "vocabulary" => ..., "draft_context" => ..., "cleanup_enabled" => ...,
      "cleanup_url" => ..., "cleanup_models" => ...,
      "cleanup_timeout_ms" => ..., "cleanup_glossary" => ...}`.
      Any key may be blank or absent, in which
      case that ONE field falls back to its `ASR_*` env var — see
      `OrcaHub.ASRConfig.resolve/0`. `enabled: false` disables the whole row,
      reverting every field to env without having to delete it.

  There is deliberately no `"asr_model"` kind. The sync lane
  (`POST /v1/transcribe/sync` on GB10) is pinned to `large-v3-turbo` and
  offers no model selection at all — see the voice mode spec, section 6.

  ## Numbers live in `spec` as strings

  `spec` is jsonb and is edited through a plain HTML form, so
  `timeout_ms`/`warmup_timeout_ms`/`threshold` are stored as the strings the
  form produced, exactly like every other field. Typed values appear only at
  the far end, in `resolve/0`. The changeset validates that those strings
  PARSE and are in range, so a bad value is rejected at save time rather
  than silently falling back to env forever.

  `vocabulary` is capped at `OrcaHub.Voice.Prompt.max_vocabulary_chars/0`
  so the Whisper prompt always keeps room for the draft tail after it.
  `cleanup_glossary` is capped at `max_cleanup_glossary_chars/0` and
  `cleanup_models` (a comma-separated id list) must name at least one id.

  ## The booleans are TRI-STATE, not checkboxes

  `echo_cancellation`/`noise_suppression`/`auto_gain_control` (the
  `getUserMedia` constraints the browser mic is opened with),
  `release_mic_during_playback` (ORCAHUB3-105), `draft_context` (the
  Whisper prompt's draft tail) and `cleanup_enabled` (ORCAHUB3-120) all
  need three states, not
  two: `"true"`, `"false"`, and BLANK meaning "inherit this one from its env
  var". A checkbox cannot express the third, so the Settings UI renders them
  as selects and they are stored as the strings `"true"`/`"false"`/`""` like
  every other field here — never as a jsonb boolean by way of the form.

  `spec` is deep-stringified on cast so a struct built from atom-keyed attrs
  reads identically to one loaded back from jsonb.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @kinds ~w(asr_provider)

  # The glossary rides every cleanup call's system prompt; the default is
  # ~330 characters.
  @max_cleanup_glossary_chars 1_000

  schema "asr_config_entries" do
    field :kind, :string
    field :name, :string
    field :spec, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps()
  end

  @doc "The config surfaces an entry can target, as strings."
  def kinds, do: @kinds

  @doc "The cap on `cleanup_glossary`, in characters."
  def max_cleanup_glossary_chars, do: @max_cleanup_glossary_chars

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:kind, :name, :spec, :enabled])
    |> update_change(:spec, &stringify/1)
    |> validate_required([:kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_spec()
    |> unique_constraint(:name,
      name: :asr_config_entries_kind_name_index,
      message: "has already been taken for this kind"
    )
  end

  # A blank field is legitimate everywhere here — it means "fall back to env
  # for this one field" — so each check runs only on a populated value.
  defp validate_spec(changeset) do
    spec = get_field(changeset, :spec)

    if is_map(spec) do
      changeset
      |> validate_url(spec["url"])
      |> validate_positive_integer(spec["timeout_ms"], "timeout_ms")
      |> validate_positive_integer(spec["warmup_timeout_ms"], "warmup_timeout_ms")
      |> validate_threshold(spec["threshold"])
      |> validate_boolean(spec["echo_cancellation"], "echo_cancellation")
      |> validate_boolean(spec["noise_suppression"], "noise_suppression")
      |> validate_boolean(spec["auto_gain_control"], "auto_gain_control")
      |> validate_boolean(spec["release_mic_during_playback"], "release_mic_during_playback")
      |> validate_boolean(spec["draft_context"], "draft_context")
      |> validate_vocabulary(spec["vocabulary"])
      |> validate_boolean(spec["cleanup_enabled"], "cleanup_enabled")
      |> validate_url(spec["cleanup_url"], "cleanup_url")
      |> validate_positive_integer(spec["cleanup_timeout_ms"], "cleanup_timeout_ms")
      |> validate_models(spec["cleanup_models"])
      |> validate_cleanup_glossary(spec["cleanup_glossary"])
    else
      add_error(changeset, :spec, "must be a map")
    end
  end

  defp validate_url(changeset, value, field \\ "url") do
    cond do
      blank?(value) -> changeset
      not is_binary(value) -> add_error(changeset, :spec, "#{field} must be a string")
      String.starts_with?(String.trim(value), ["http://", "https://"]) -> changeset
      true -> add_error(changeset, :spec, "#{field} must start with http:// or https://")
    end
  end

  defp validate_models(changeset, value) do
    cond do
      blank?(value) ->
        changeset

      is_binary(value) and OrcaHub.Voice.Cleanup.parse_models(value) != [] ->
        changeset

      true ->
        add_error(changeset, :spec, "cleanup_models must be a comma-separated list of model ids")
    end
  end

  defp validate_cleanup_glossary(changeset, value) do
    cond do
      blank?(value) ->
        changeset

      not is_binary(value) ->
        add_error(changeset, :spec, "cleanup_glossary must be a string")

      String.length(String.trim(value)) <= @max_cleanup_glossary_chars ->
        changeset

      true ->
        add_error(
          changeset,
          :spec,
          "cleanup_glossary must be at most #{@max_cleanup_glossary_chars} characters"
        )
    end
  end

  defp validate_positive_integer(changeset, value, field) do
    cond do
      blank?(value) ->
        changeset

      match?({:ok, ms} when ms > 0, parse_integer(value)) ->
        changeset

      true ->
        add_error(changeset, :spec, "#{field} must be a positive whole number of milliseconds")
    end
  end

  defp validate_threshold(changeset, value) do
    cond do
      blank?(value) ->
        changeset

      match?({:ok, t} when t >= 0.0 and t <= 1.0, parse_float(value)) ->
        changeset

      true ->
        add_error(changeset, :spec, "threshold must be a number between 0.0 and 1.0")
    end
  end

  defp validate_boolean(changeset, value, field) do
    cond do
      blank?(value) ->
        changeset

      match?({:ok, _}, parse_boolean(value)) ->
        changeset

      true ->
        add_error(changeset, :spec, ~s(#{field} must be "true" or "false"))
    end
  end

  defp validate_vocabulary(changeset, value) do
    max = OrcaHub.Voice.Prompt.max_vocabulary_chars()

    cond do
      blank?(value) -> changeset
      not is_binary(value) -> add_error(changeset, :spec, "vocabulary must be a string")
      String.length(String.trim(value)) <= max -> changeset
      true -> add_error(changeset, :spec, "vocabulary must be at most #{max} characters")
    end
  end

  @doc """
  Parses a stored `spec` integer. Shared with `OrcaHub.ASRConfig` so the
  changeset and the resolver can never disagree about what "valid" means.
  """
  def parse_integer(value) when is_integer(value), do: {:ok, value}

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  def parse_integer(_), do: :error

  @doc "Parses a stored `spec` float. See `parse_integer/1`."
  def parse_float(value) when is_float(value), do: {:ok, value}
  def parse_float(value) when is_integer(value), do: {:ok, value * 1.0}

  def parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, float}
      _ -> :error
    end
  end

  def parse_float(_), do: :error

  @doc """
  Parses a stored `spec` boolean. See `parse_integer/1`.

  Deliberately STRICT: only `"true"`/`"false"` (any case, trimmed) and real
  booleans. `"1"`/`"yes"`/`"on"` are rejected rather than guessed at, because
  the failure mode of guessing wrong here is a microphone opened with a
  constraint nobody asked for — the exact confusion ORCAHUB3-105 exists to
  remove.
  """
  def parse_boolean(value) when is_boolean(value), do: {:ok, value}

  def parse_boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  def parse_boolean(_), do: :error

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
