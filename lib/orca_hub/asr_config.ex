defmodule OrcaHub.ASRConfig do
  @moduledoc """
  Context for the hub-managed speech-recognition config — where voice mode
  sends utterances, and the knobs the transcription path needs — read on
  every ASR call.

  Sibling of `OrcaHub.TTSConfig`; READ THAT MODULEDOC FIRST, because every
  structural decision here is the same one, for the same reasons: the
  `kind`/`name`/`spec`/`enabled` table shape, the PER-FIELD resolution, and
  the deliberate absence of a cache.

  It is SIMPLER than its sibling in exactly one way: there is no model
  catalog and no provider choice. The sync lane
  (`POST /v1/transcribe/sync` on GB10) is pinned to `large-v3-turbo` and
  offers no model selection at all (voice mode spec, section 6), so there is
  one provider-style row and nothing else.

  ## Resolution: DB wins, else env, else hardcoded — PER FIELD

  `resolve/0` decides nine fields independently. For each one it takes the
  first usable of:

    1. the DB value (the `"asr_provider"` row's `spec`),
    2. the corresponding `ASR_*` env var (`config/runtime.exs`),
    3. the hardcoded default.

  The per-field part is load-bearing. A row that sets only `"url"` must NOT
  suppress `ASR_LANGUAGE`/`ASR_TIMEOUT_MS` for the fields it leaves blank —
  a half-filled row is a partial override, not a whole-config takeover. The
  migration therefore seeds nothing: a fresh DB behaves exactly like the
  pre-migration build.

  ## Numeric fields

  `timeout_ms`, `warmup_timeout_ms` and `threshold` are stored as strings in
  `spec` (it is jsonb fed by an HTML form) and parsed here. A value that
  does not parse — or parses out of range — is treated as ABSENT for that
  one layer: it logs a warning and falls through to the next layer rather
  than crashing the caller. `Entry`'s changeset rejects such values at save
  time, so in practice this only fires for a hand-edited row or a malformed
  env var.

  The two timeouts are deliberately different numbers, not one knob:

    * `timeout_ms` (10_000) is the STEADY-STATE per-call HTTP timeout. Warm
      p50 is 570-1350ms and the server itself gives up at 30s, so 10s is a
      generous cap that still fails fast when the lane is wedged.
    * `warmup_timeout_ms` (40_000) is used ONLY for the warm-up ping fired
      when voice mode arms, where a cold start takes up to 35s (the GPU
      arbiter's own restore budget).

  `threshold` (0.85) is the phonetic tail-matcher threshold for
  `OrcaHub.Voice.Intent` — spec 5.1.1 rule 4 requires it to be a config
  knob rather than a module attribute, so that a user who keeps getting
  false "send" triggers can turn it up without a redeploy.

  ## The three capture constraints (ORCAHUB3-105)

  `echo_cancellation`, `noise_suppression` and `auto_gain_control` are
  booleans, all defaulting to TRUE, and they are not used on this side at
  all: the voice channel hands them to the browser in its join reply and
  `assets/js/voice/capture.js` passes them straight to `getUserMedia`. They
  live here because they need to be A/B-testable in seconds on a real phone,
  and as a module constant in JS every hypothesis cost a full
  gate-and-deploy cycle.

  The defaults reproduce that constant EXACTLY; changing one is a deliberate
  act. WHEN a change takes effect also differs from every other field here:
  the constraints are read once, when the microphone is OPENED, so a change
  applies on the NEXT ARM (voice off, then on) — not on the next utterance,
  and never mid-session.

  Why they are tunable at all: requesting `echoCancellation` puts the browser
  into communications audio mode, which on Android forces Bluetooth from A2DP
  (media) to HFP/SCO (call) — the suspected cause of ORCAHUB3-105, where
  arming the mic silences ALL audio output on the device, unrelated apps
  included. This is the knob for TESTING that, not a decision to turn AEC
  off; `voice_mode_spec.md` §4 still says AEC-on and the defaults still obey
  it.

  ## No cache, deliberately

  `resolve/0` queries inside the call. Voice traffic is very low QPS, and a
  cache is the one thing that could stop a config change taking effect on
  the very next utterance — which is the entire point of moving this into
  the DB. Do not add ETS or `:persistent_term` here.
  """

  import Ecto.Query
  require Logger

  alias OrcaHub.ASRConfig.Entry
  alias OrcaHub.Repo

  @topic "asr_config"

  @provider_kind "asr_provider"

  # The single provider row's `name`. Uniqueness is on [:kind, :name], so
  # pinning the name is what makes "there is exactly one provider row" true.
  @provider_name "active"

  # Terminal fallbacks — the measured contract from the voice mode spec.
  @default_url "http://192.168.1.77:8000"
  @default_path "/v1/transcribe/sync"
  @default_language "en"
  @default_timeout_ms 10_000
  @default_warmup_timeout_ms 40_000
  @default_threshold 0.85

  # ORCAHUB3-105. These three ARE the old `AUDIO_CONSTRAINTS` module constant
  # in assets/js/voice/capture.js — do not change them without changing spec
  # §4, and note that `asr_config_test.exs` asserts they still match the JS
  # file byte-for-byte in meaning.
  @default_echo_cancellation true
  @default_noise_suppression true
  @default_auto_gain_control true

  @doc "The PubSub topic mutations broadcast on."
  def topic, do: @topic

  def provider_kind, do: @provider_kind
  def provider_name, do: @provider_name

  @doc """
  The effective ASR config: `%{url:, path:, language:, timeout_ms:,
  warmup_timeout_ms:, threshold:, echo_cancellation:, noise_suppression:,
  auto_gain_control:}`, each field resolved DB → env → hardcoded
  independently, with the numeric and boolean fields returned TYPED.

  A DB read failure degrades to env-only rather than failing the call —
  transcribing against the env config is strictly better than dropping the
  user's utterance, and the hub being unable to reach its own Repo is
  already visible everywhere else.
  """
  def resolve do
    spec = provider_spec()

    %{
      url: pick(spec["url"], :asr_url, @default_url),
      path: pick(spec["path"], :asr_path, @default_path),
      language: pick(spec["language"], :asr_language, @default_language),
      timeout_ms: pick_integer(spec["timeout_ms"], :asr_timeout_ms, @default_timeout_ms),
      warmup_timeout_ms:
        pick_integer(
          spec["warmup_timeout_ms"],
          :asr_warmup_timeout_ms,
          @default_warmup_timeout_ms
        ),
      threshold: pick_threshold(spec["threshold"], :asr_intent_threshold, @default_threshold),
      echo_cancellation:
        pick_boolean(
          spec["echo_cancellation"],
          :asr_echo_cancellation,
          @default_echo_cancellation
        ),
      noise_suppression:
        pick_boolean(
          spec["noise_suppression"],
          :asr_noise_suppression,
          @default_noise_suppression
        ),
      auto_gain_control:
        pick_boolean(
          spec["auto_gain_control"],
          :asr_auto_gain_control,
          @default_auto_gain_control
        )
    }
  end

  @doc """
  Just the three `getUserMedia` capture constraints from `resolve/0`, keyed
  the way the Web Audio API spells them — what `OrcaHubWeb.VoiceChannel`
  puts in its join reply and `assets/js/voice/capture.js` spreads into
  `getUserMedia({audio: ...})`.

  `channelCount: 1` and `voiceIsolation: false` are NOT here: they stay
  pinned in the JS, because nothing about ORCAHUB3-105 makes them worth
  varying and spec §4 pins `voiceIsolation` explicitly.
  """
  def capture_constraints(config \\ nil) do
    config = config || resolve()

    %{
      echoCancellation: config.echo_cancellation,
      noiseSuppression: config.noise_suppression,
      autoGainControl: config.auto_gain_control
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
      url: pick(nil, :asr_url, @default_url),
      path: pick(nil, :asr_path, @default_path),
      language: pick(nil, :asr_language, @default_language),
      timeout_ms: pick_integer(nil, :asr_timeout_ms, @default_timeout_ms),
      warmup_timeout_ms: pick_integer(nil, :asr_warmup_timeout_ms, @default_warmup_timeout_ms),
      threshold: pick_threshold(nil, :asr_intent_threshold, @default_threshold),
      echo_cancellation: pick_boolean(nil, :asr_echo_cancellation, @default_echo_cancellation),
      noise_suppression: pick_boolean(nil, :asr_noise_suppression, @default_noise_suppression),
      auto_gain_control: pick_boolean(nil, :asr_auto_gain_control, @default_auto_gain_control)
    }
  end

  defp pick(db_value, env_key, default) do
    blank_to_nil(db_value) || blank_to_nil(Application.get_env(:orca_hub, env_key)) || default
  end

  defp pick_integer(db_value, env_key, default),
    do: pick_parsed(db_value, env_key, default, &positive_integer/1)

  defp pick_threshold(db_value, env_key, default),
    do: pick_parsed(db_value, env_key, default, &unit_float/1)

  defp pick_boolean(db_value, env_key, default),
    do: pick_parsed(db_value, env_key, default, &Entry.parse_boolean/1)

  # `with nil <-` rather than `||`: a resolved `false` is a REAL value here
  # (that is the whole point of the capture constraints), and `||` would
  # treat it as "not set" and fall through to the default `true`.
  defp pick_parsed(db_value, env_key, default, parser) do
    with nil <- parsed(db_value, "the DB row", env_key, parser),
         nil <-
           parsed(
             Application.get_env(:orca_hub, env_key),
             "the environment",
             env_key,
             parser
           ) do
      default
    end
  end

  # One layer of a parsed field: blank is "not set here" and falls through
  # silently; a populated-but-unusable value falls through LOUDLY, since it
  # is a config mistake the user will otherwise never see.
  defp parsed(raw, source, env_key, parser) do
    if blank_layer?(raw) do
      nil
    else
      case parser.(raw) do
        {:ok, value} ->
          value

        :error ->
          Logger.warning(
            "ASRConfig: ignoring invalid #{env_key} value from #{source}: #{inspect(raw)}"
          )

          nil
      end
    end
  end

  defp positive_integer(raw) do
    case Entry.parse_integer(raw) do
      {:ok, int} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp unit_float(raw) do
    case Entry.parse_float(raw) do
      {:ok, float} when float >= 0.0 and float <= 1.0 -> {:ok, float}
      _ -> :error
    end
  end

  defp blank_layer?(nil), do: true
  defp blank_layer?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_layer?(_), do: false

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # A disabled provider row is treated exactly like a missing one: every
  # field reverts to env, without the user having to delete their settings.
  defp provider_spec do
    case get_provider_entry() do
      %Entry{enabled: true, spec: spec} when is_map(spec) -> spec
      _ -> %{}
    end
  rescue
    error ->
      Logger.warning("ASRConfig: falling back to env config, DB read failed: #{inspect(error)}")
      %{}
  catch
    :exit, reason ->
      Logger.warning("ASRConfig: falling back to env config, DB read exited: #{inspect(reason)}")
      %{}
  end

  def get_provider_entry, do: Repo.get_by(Entry, kind: @provider_kind, name: @provider_name)

  @doc """
  Upserts the single provider row. `attrs` carries `url`/`path`/`language`/
  `timeout_ms`/`warmup_timeout_ms`/`threshold`/`echo_cancellation`/
  `noise_suppression`/`auto_gain_control` (string or atom keys); a blank
  value is stored as-is and read back as "fall back to env for this field".
  """
  def put_provider(attrs) do
    spec =
      Map.new(
        ~w(url path language timeout_ms warmup_timeout_ms threshold
           echo_cancellation noise_suppression auto_gain_control)a,
        fn key -> {to_string(key), fetch(attrs, key)} end
      )

    enabled = Map.get(attrs, :enabled, Map.get(attrs, "enabled", true))

    entry_attrs = %{
      kind: @provider_kind,
      name: @provider_name,
      spec: spec,
      enabled: normalize_enabled(enabled)
    }

    result =
      case get_provider_entry() do
        nil -> %Entry{} |> Entry.changeset(entry_attrs) |> Repo.insert()
        entry -> entry |> Entry.changeset(entry_attrs) |> Repo.update()
      end

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  @doc "A changeset for the provider row, for `to_form/1` in the Settings UI."
  def change_provider(entry \\ nil, attrs \\ %{}) do
    Entry.changeset(entry || %Entry{kind: @provider_kind, name: @provider_name}, attrs)
  end

  @doc """
  Deletes the provider row outright, reverting every field to env. Nothing
  in the UI calls this today; it exists so a wedged row can be cleared
  without a manual SQL delete.
  """
  def delete_provider do
    case get_provider_entry() do
      nil ->
        {:ok, nil}

      entry ->
        result = Repo.delete(entry)
        with {:ok, _} <- result, do: notify_change()
        result
    end
  end

  @doc false
  def count_entries do
    Repo.aggregate(from(e in Entry, where: e.kind == ^@provider_kind), :count)
  end

  defp fetch(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, to_string(key)))

    cond do
      is_binary(value) -> String.trim(value)
      is_nil(value) -> ""
      true -> to_string(value)
    end
  end

  # An HTML checkbox arrives as "true"/"false", not a boolean.
  defp normalize_enabled("false"), do: false
  defp normalize_enabled("true"), do: true
  defp normalize_enabled(nil), do: true
  defp normalize_enabled(value), do: !!value

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, @topic, {:asr_config_updated})
  end
end
