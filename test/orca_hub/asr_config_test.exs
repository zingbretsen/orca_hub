defmodule OrcaHub.ASRConfigTest do
  @moduledoc """
  The per-field resolution rules are the whole point of this table, so they
  get tested directly.

  `async: false` deliberately, mirroring `OrcaHub.TTSConfigTest`: every test
  here mutates the global `:asr_*` application env, and sync tests run after
  all async ones, so nothing can interleave over the same keys.
  """
  use OrcaHub.DataCase, async: false

  import ExUnit.CaptureLog

  alias OrcaHub.ASRConfig
  alias OrcaHub.ASRConfig.Entry

  @env_keys [
    :asr_url,
    :asr_path,
    :asr_language,
    :asr_timeout_ms,
    :asr_warmup_timeout_ms,
    :asr_intent_threshold,
    :asr_echo_cancellation,
    :asr_noise_suppression,
    :asr_auto_gain_control,
    :asr_release_mic_during_playback
  ]

  @hardcoded %{
    url: "http://192.168.1.77:8000",
    path: "/v1/transcribe/sync",
    language: "en",
    timeout_ms: 10_000,
    warmup_timeout_ms: 40_000,
    threshold: 0.85,
    echo_cancellation: true,
    noise_suppression: true,
    auto_gain_control: true,
    release_mic_during_playback: false
  }

  # The four booleans deliberately do NOT all match their defaults here: a
  # boolean is exactly the value a `||` fallback chain silently eats, so the
  # three default-TRUE constraints are exercised with env "false", and
  # `release_mic_during_playback` — which defaults FALSE — is exercised with
  # env "true", covering the trap from both sides.
  @from_env %{
    url: "http://env.example:9000",
    path: "/env/transcribe",
    language: "env-lang",
    timeout_ms: 1111,
    warmup_timeout_ms: 2222,
    threshold: 0.5,
    echo_cancellation: false,
    noise_suppression: true,
    auto_gain_control: false,
    release_mic_during_playback: true
  }

  setup do
    # Snapshot and restore rather than delete-on-exit: config/runtime.exs
    # sets all ten for real, and leaving them deleted would silently change
    # what every later test resolves.
    saved = Map.new(@env_keys, fn key -> {key, Application.fetch_env(:orca_hub, key)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:orca_hub, key, value)
        {key, :error} -> Application.delete_env(:orca_hub, key)
      end)
    end)

    Application.put_env(:orca_hub, :asr_url, "http://env.example:9000")
    Application.put_env(:orca_hub, :asr_path, "/env/transcribe")
    Application.put_env(:orca_hub, :asr_language, "env-lang")
    Application.put_env(:orca_hub, :asr_timeout_ms, "1111")
    Application.put_env(:orca_hub, :asr_warmup_timeout_ms, "2222")
    Application.put_env(:orca_hub, :asr_intent_threshold, "0.5")
    Application.put_env(:orca_hub, :asr_echo_cancellation, "false")
    Application.put_env(:orca_hub, :asr_noise_suppression, "true")
    Application.put_env(:orca_hub, :asr_auto_gain_control, "false")
    Application.put_env(:orca_hub, :asr_release_mic_during_playback, "true")

    :ok
  end

  # The JS module constant this config replaced (ORCAHUB3-105). Read out of
  # the real file rather than copied, so the two cannot drift apart silently —
  # the whole claim of this change is "the defaults are byte-for-byte what we
  # already ship".
  defp js_constant(name) do
    source = File.read!(Path.join(File.cwd!(), "assets/js/voice/capture.js"))

    [_, body] = Regex.run(~r/export const #{name} = \{(.*?)\n\}/s, source)

    ~r/(\w+):\s*(true|false|\d+)/
    |> Regex.scan(body)
    |> Map.new(fn
      [_, key, "true"] -> {key, true}
      [_, key, "false"] -> {key, false}
      [_, key, int] -> {key, String.to_integer(int)}
    end)
  end

  defp put_provider!(spec, opts \\ []) do
    {:ok, entry} =
      ASRConfig.put_provider(Map.merge(spec, %{enabled: Keyword.get(opts, :enabled, true)}))

    entry
  end

  describe "resolve/0 with an empty table" do
    test "every field comes from env — a fresh DB behaves like the pre-migration build" do
      assert ASRConfig.resolve() == @from_env
    end

    test "falls through env to the hardcoded defaults when the env vars are unset too" do
      Enum.each(@env_keys, &Application.delete_env(:orca_hub, &1))

      assert ASRConfig.resolve() == @hardcoded
    end

    test "treats a blank env var as unset rather than resolving to an empty string" do
      Application.put_env(:orca_hub, :asr_url, "   ")
      Application.put_env(:orca_hub, :asr_language, "")
      Application.put_env(:orca_hub, :asr_timeout_ms, "  ")

      resolved = ASRConfig.resolve()

      assert resolved.url == @hardcoded.url
      assert resolved.language == @hardcoded.language
      assert resolved.timeout_ms == @hardcoded.timeout_ms
    end

    test "accepts already-typed env values as well as the strings runtime.exs sets" do
      Application.put_env(:orca_hub, :asr_timeout_ms, 4242)
      Application.put_env(:orca_hub, :asr_intent_threshold, 0.25)

      resolved = ASRConfig.resolve()

      assert resolved.timeout_ms == 4242
      assert resolved.threshold == 0.25
    end
  end

  describe "resolve/0 per-field fallback (the rule most likely to be got wrong)" do
    test "a row that sets ONLY url leaves every other field on its env value" do
      put_provider!(%{url: "http://db.example:8000"})

      assert ASRConfig.resolve() == %{@from_env | url: "http://db.example:8000"}
    end

    test "a row that sets ONLY the intent threshold leaves the timeouts on env" do
      put_provider!(%{threshold: "0.95"})

      assert ASRConfig.resolve() == %{@from_env | threshold: 0.95}
    end

    test "each populated field independently overrides its env value" do
      put_provider!(%{
        url: "http://db.example:8000",
        path: "/db/transcribe",
        language: "fr",
        timeout_ms: "7000",
        warmup_timeout_ms: "50000",
        threshold: "0.7",
        echo_cancellation: "true",
        noise_suppression: "false",
        auto_gain_control: "true",
        release_mic_during_playback: "false"
      })

      assert ASRConfig.resolve() == %{
               url: "http://db.example:8000",
               path: "/db/transcribe",
               language: "fr",
               timeout_ms: 7000,
               warmup_timeout_ms: 50_000,
               threshold: 0.7,
               echo_cancellation: true,
               noise_suppression: false,
               auto_gain_control: true,
               release_mic_during_playback: false
             }
    end

    test "a whitespace-only DB field falls back to env like a blank one" do
      put_provider!(%{url: "   ", language: "\t", timeout_ms: "  ", threshold: " "})

      assert ASRConfig.resolve() == @from_env
    end

    test "a DB field wins even when it happens to equal the hardcoded default" do
      put_provider!(%{url: @hardcoded.url, timeout_ms: "10000"})

      resolved = ASRConfig.resolve()
      assert resolved.url == @hardcoded.url
      assert resolved.timeout_ms == 10_000
    end

    test "a disabled row reverts every field to env without being deleted" do
      put_provider!(
        %{
          url: "http://db.example:8000",
          path: "/db/transcribe",
          language: "fr",
          timeout_ms: "7000",
          warmup_timeout_ms: "50000",
          threshold: "0.7"
        },
        enabled: false
      )

      assert ASRConfig.resolve() == @from_env
      assert ASRConfig.get_provider_entry().spec["url"] == "http://db.example:8000"
    end

    test "put_provider/1 upserts rather than accumulating rows" do
      put_provider!(%{url: "http://one.example:8000"})
      put_provider!(%{url: "http://two.example:8000"})

      assert ASRConfig.count_entries() == 1
      assert ASRConfig.resolve().url == "http://two.example:8000"
    end

    test "a re-save with a blank field reverts that field alone to env" do
      put_provider!(%{url: "http://db.example:8000", language: "fr"})
      put_provider!(%{url: "http://db.example:8000", language: ""})

      assert ASRConfig.resolve().url == "http://db.example:8000"
      assert ASRConfig.resolve().language == "env-lang"
    end
  end

  describe "numeric parsing falls through instead of crashing" do
    test "a malformed DB number is ignored (with a warning) and env is used" do
      # Written straight into the row, bypassing the changeset — exactly the
      # hand-edited/legacy case this fallback exists for.
      {:ok, entry} = ASRConfig.put_provider(%{url: ""})

      {:ok, _} =
        entry
        |> Ecto.Changeset.change(spec: %{"timeout_ms" => "ten thousand", "threshold" => "high"})
        |> Repo.update()

      log = capture_log(fn -> assert ASRConfig.resolve() == @from_env end)

      assert log =~ "ignoring invalid asr_timeout_ms"
      assert log =~ "ignoring invalid asr_intent_threshold"
    end

    test "a malformed ENV number falls through to the hardcoded default" do
      Application.put_env(:orca_hub, :asr_timeout_ms, "not-a-number")
      Application.put_env(:orca_hub, :asr_warmup_timeout_ms, "40000ms")

      log =
        capture_log(fn ->
          resolved = ASRConfig.resolve()
          assert resolved.timeout_ms == @hardcoded.timeout_ms
          assert resolved.warmup_timeout_ms == @hardcoded.warmup_timeout_ms
        end)

      assert log =~ "ignoring invalid asr_timeout_ms"
    end

    test "a non-positive timeout is treated as invalid, not as 'no timeout'" do
      Application.put_env(:orca_hub, :asr_timeout_ms, "0")

      capture_log(fn -> assert ASRConfig.resolve().timeout_ms == @hardcoded.timeout_ms end)
    end

    test "an out-of-range threshold falls through rather than being clamped" do
      Application.put_env(:orca_hub, :asr_intent_threshold, "1.5")

      capture_log(fn -> assert ASRConfig.resolve().threshold == @hardcoded.threshold end)
    end

    test "an integer-looking threshold resolves as a float" do
      put_provider!(%{threshold: "1"})

      assert ASRConfig.resolve().threshold === 1.0
    end
  end

  describe "the capture constraints (ORCAHUB3-105)" do
    test "the defaults ARE the JS constant they replaced — shipping this changes nothing" do
      Enum.each(@env_keys, &Application.delete_env(:orca_hub, &1))

      tunable =
        ASRConfig.capture_constraints()
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      assert tunable == js_constant("DEFAULT_TUNABLE_CONSTRAINTS")

      # ...and the full object the browser hands getUserMedia is the old
      # `AUDIO_CONSTRAINTS` literal, character for character.
      assert Map.merge(tunable, js_constant("FIXED_CONSTRAINTS")) == %{
               "echoCancellation" => true,
               "noiseSuppression" => true,
               "autoGainControl" => true,
               "channelCount" => 1,
               "voiceIsolation" => false
             }
    end

    test "capture_constraints/1 reshapes an already-resolved config, camelCased for the API" do
      config = %{echo_cancellation: false, noise_suppression: true, auto_gain_control: false}

      assert ASRConfig.capture_constraints(config) == %{
               echoCancellation: false,
               noiseSuppression: true,
               autoGainControl: false
             }
    end

    test "a DB `false` survives resolution rather than falling through to the default" do
      Enum.each(@env_keys, &Application.delete_env(:orca_hub, &1))
      put_provider!(%{echo_cancellation: "false"})

      resolved = ASRConfig.resolve()

      assert resolved.echo_cancellation == false
      assert resolved.noise_suppression == true
      assert resolved.auto_gain_control == true
    end

    test "an env `false` survives it too, and only for the field it names" do
      assert ASRConfig.resolve().echo_cancellation == false
      assert ASRConfig.resolve().noise_suppression == true
      assert ASRConfig.resolve().auto_gain_control == false
    end

    test "a DB value wins over env, per field" do
      put_provider!(%{echo_cancellation: "true"})

      assert ASRConfig.resolve().echo_cancellation == true
      assert ASRConfig.resolve().auto_gain_control == false
    end

    test "a real boolean in the row reads back the same as the string the form writes" do
      put_provider!(%{echo_cancellation: true, noise_suppression: false})

      assert ASRConfig.resolve().echo_cancellation == true
      assert ASRConfig.resolve().noise_suppression == false
    end

    test "a malformed DB value is ignored (with a warning) and env is used" do
      {:ok, entry} = ASRConfig.put_provider(%{url: ""})

      {:ok, _} =
        entry
        |> Ecto.Changeset.change(spec: %{"echo_cancellation" => "on"})
        |> Repo.update()

      log = capture_log(fn -> assert ASRConfig.resolve().echo_cancellation == false end)

      assert log =~ "ignoring invalid asr_echo_cancellation"
    end

    test "a malformed ENV value falls through to the hardcoded default" do
      Application.put_env(:orca_hub, :asr_echo_cancellation, "yes")

      log = capture_log(fn -> assert ASRConfig.resolve().echo_cancellation == true end)

      assert log =~ "ignoring invalid asr_echo_cancellation"
    end

    test "a disabled row reverts the constraints to env like every other field" do
      put_provider!(%{echo_cancellation: "true", auto_gain_control: "true"}, enabled: false)

      assert ASRConfig.resolve().echo_cancellation == false
      assert ASRConfig.resolve().auto_gain_control == false
    end

    test "env_defaults/0 reports them without a DB read" do
      put_provider!(%{echo_cancellation: "true"})

      assert ASRConfig.env_defaults().echo_cancellation == false
      assert ASRConfig.resolve().echo_cancellation == true
    end
  end

  describe "release_mic_during_playback (ORCAHUB3-105)" do
    test "defaults to FALSE with nothing configured — the knob ships inert" do
      Enum.each(@env_keys, &Application.delete_env(:orca_hub, &1))

      assert ASRConfig.resolve().release_mic_during_playback == false
      assert ASRConfig.env_defaults().release_mic_during_playback == false
    end

    test "env `true` turns it on — the default-false field's version of the `||` trap" do
      # `@from_env` sets the env var to "true"; the hardcoded default is
      # false, so a chain that fell through would read false here.
      assert ASRConfig.resolve().release_mic_during_playback == true
    end

    test "a DB value wins over env, in both directions" do
      put_provider!(%{release_mic_during_playback: "false"})
      assert ASRConfig.resolve().release_mic_during_playback == false

      put_provider!(%{release_mic_during_playback: "true"})
      assert ASRConfig.resolve().release_mic_during_playback == true
    end

    test "it is independent of the three capture constraints" do
      put_provider!(%{release_mic_during_playback: "true", echo_cancellation: "true"})

      resolved = ASRConfig.resolve()

      assert resolved.release_mic_during_playback == true
      assert resolved.echo_cancellation == true
      # ...and it is NOT one of the getUserMedia constraints: the browser
      # spreads that map straight into getUserMedia, where an unknown key is
      # at best ignored and at worst an OverconstrainedError.
      refute Map.has_key?(ASRConfig.capture_constraints(resolved), :releaseMicDuringPlayback)

      assert ASRConfig.capture_constraints(resolved) |> Map.keys() |> Enum.sort() ==
               [:autoGainControl, :echoCancellation, :noiseSuppression]
    end

    test "a blank DB value inherits from env, like every other field" do
      put_provider!(%{echo_cancellation: "false"})

      assert ASRConfig.get_provider_entry().spec["release_mic_during_playback"] == ""
      assert ASRConfig.resolve().release_mic_during_playback == true
    end

    test "a malformed value is ignored with a warning rather than read as truthy" do
      Application.put_env(:orca_hub, :asr_release_mic_during_playback, "yes")

      log =
        capture_log(fn ->
          assert ASRConfig.resolve().release_mic_during_playback == false
        end)

      assert log =~ "ignoring invalid asr_release_mic_during_playback"
    end

    test "rejects a non-boolean at save time" do
      assert {:error, changeset} =
               ASRConfig.put_provider(%{release_mic_during_playback: "sometimes"})

      assert ~s(release_mic_during_playback must be "true" or "false") in errors_on(changeset).spec
    end

    test "a disabled row reverts it to env like every other field" do
      put_provider!(%{release_mic_during_playback: "false"}, enabled: false)

      assert ASRConfig.resolve().release_mic_during_playback == true
    end
  end

  describe "changesets" do
    test "rejects a url without an http(s) scheme" do
      assert {:error, changeset} = ASRConfig.put_provider(%{url: "192.168.1.77:8000"})
      assert "url must start with http:// or https://" in errors_on(changeset).spec
    end

    test "accepts a blank url, since blank means 'inherit from env'" do
      assert {:ok, _} = ASRConfig.put_provider(%{url: ""})
    end

    test "rejects a non-numeric timeout at save time" do
      assert {:error, changeset} = ASRConfig.put_provider(%{timeout_ms: "soon"})

      assert "timeout_ms must be a positive whole number of milliseconds" in errors_on(changeset).spec
    end

    test "rejects a non-positive timeout at save time" do
      assert {:error, changeset} = ASRConfig.put_provider(%{warmup_timeout_ms: "-1"})

      assert "warmup_timeout_ms must be a positive whole number of milliseconds" in errors_on(
               changeset
             ).spec
    end

    test "rejects a threshold outside 0.0..1.0" do
      assert {:error, changeset} = ASRConfig.put_provider(%{threshold: "1.5"})
      assert "threshold must be a number between 0.0 and 1.0" in errors_on(changeset).spec

      assert {:error, changeset} = ASRConfig.put_provider(%{threshold: "-0.1"})
      assert "threshold must be a number between 0.0 and 1.0" in errors_on(changeset).spec
    end

    test "accepts the range endpoints" do
      assert {:ok, _} = ASRConfig.put_provider(%{threshold: "0"})
      assert {:ok, _} = ASRConfig.put_provider(%{threshold: "1.0"})
    end

    test "rejects a capture constraint that is not true/false" do
      assert {:error, changeset} = ASRConfig.put_provider(%{echo_cancellation: "maybe"})
      assert ~s(echo_cancellation must be "true" or "false") in errors_on(changeset).spec

      assert {:error, changeset} = ASRConfig.put_provider(%{noise_suppression: "1"})
      assert ~s(noise_suppression must be "true" or "false") in errors_on(changeset).spec
    end

    test "accepts blank capture constraints, since blank means 'inherit from env'" do
      assert {:ok, _} = ASRConfig.put_provider(%{echo_cancellation: "", auto_gain_control: ""})
    end

    test "accepts true/false in any case" do
      assert {:ok, _} = ASRConfig.put_provider(%{echo_cancellation: "TRUE"})
      assert ASRConfig.resolve().echo_cancellation == true
    end

    test "rejects an unknown kind — there is no model kind on this lane" do
      changeset = Entry.changeset(%Entry{}, %{kind: "asr_model", name: "large-v3-turbo"})
      refute changeset.valid?
      assert changeset.errors[:kind]
    end
  end

  describe "mutation notifications" do
    test "put_provider/1 broadcasts on the asr_config topic" do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, ASRConfig.topic())

      put_provider!(%{url: "http://db.example:8000"})

      assert_receive {:asr_config_updated}
    end

    test "delete_provider/0 broadcasts and reverts to env" do
      put_provider!(%{url: "http://db.example:8000"})
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, ASRConfig.topic())

      {:ok, _} = ASRConfig.delete_provider()

      assert_receive {:asr_config_updated}
      assert ASRConfig.resolve() == @from_env
    end
  end

  describe "env_defaults/0" do
    test "reports what each field would inherit, with no DB read" do
      put_provider!(%{
        url: "http://db.example:8000",
        path: "/db/transcribe",
        language: "fr",
        timeout_ms: "7000",
        warmup_timeout_ms: "50000",
        threshold: "0.7",
        echo_cancellation: "true",
        noise_suppression: "false",
        auto_gain_control: "true",
        release_mic_during_playback: "false"
      })

      assert ASRConfig.env_defaults() == @from_env
    end

    test "falls through to the hardcoded defaults when the env is unset" do
      Enum.each(@env_keys, &Application.delete_env(:orca_hub, &1))

      assert ASRConfig.env_defaults() == @hardcoded
    end
  end
end
