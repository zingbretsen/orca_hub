defmodule OrcaHub.TTSConfigTest do
  @moduledoc """
  The resolution rules are the whole point of this table, so they get tested
  directly rather than only through the controller.

  `async: false` deliberately: every test here mutates the global `:tts_*`
  application env, which `OrcaHubWeb.TTSControllerTest` (async) also touches.
  Sync tests run after all async ones, so the two files can never interleave
  over the same keys.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.TTSConfig
  alias OrcaHub.TTSConfig.Entry

  @env_keys [:tts_provider, :tts_url, :tts_model, :tts_language]

  setup do
    # Snapshot and restore rather than delete-on-exit: config/runtime.exs
    # sets all four for real, and leaving them deleted would silently change
    # what every later test resolves.
    saved = Map.new(@env_keys, fn key -> {key, Application.fetch_env(:orca_hub, key)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:orca_hub, key, value)
        {key, :error} -> Application.delete_env(:orca_hub, key)
      end)
    end)

    Application.put_env(:orca_hub, :tts_provider, "local")
    Application.put_env(:orca_hub, :tts_url, "https://env.example")
    Application.put_env(:orca_hub, :tts_model, "env-model")
    Application.put_env(:orca_hub, :tts_language, "env-lang")

    :ok
  end

  defp put_provider!(spec, opts \\ []) do
    {:ok, entry} =
      TTSConfig.put_provider(Map.merge(spec, %{enabled: Keyword.get(opts, :enabled, true)}))

    entry
  end

  defp add_model!(name) do
    {:ok, entry} = TTSConfig.create_model(%{name: name})
    entry
  end

  describe "resolve/0 with an empty table" do
    test "every field comes from env — a fresh DB behaves exactly like the pre-migration build" do
      assert TTSConfig.resolve() == %{
               provider: "local",
               url: "https://env.example",
               model: "env-model",
               language: "env-lang"
             }
    end

    test "falls through env to the hardcoded defaults when the env vars are unset too" do
      Enum.each(@env_keys, &Application.delete_env(:orca_hub, &1))

      assert TTSConfig.resolve() == %{
               provider: "local",
               url: "https://ai.lab.ingbretsenhome.com",
               model: "tts-chatterbox-23lang",
               language: "en"
             }
    end

    test "treats a blank env var as unset rather than resolving to an empty string" do
      Application.put_env(:orca_hub, :tts_model, "")
      Application.put_env(:orca_hub, :tts_url, "   ")

      resolved = TTSConfig.resolve()

      assert resolved.model == "tts-chatterbox-23lang"
      assert resolved.url == "https://ai.lab.ingbretsenhome.com"
    end
  end

  describe "resolve/0 per-field fallback (the rule most likely to be got wrong)" do
    test "a row that sets ONLY provider leaves url and language on their env values" do
      put_provider!(%{provider: "elevenlabs", url: "", language: ""})

      assert TTSConfig.resolve() == %{
               provider: "elevenlabs",
               url: "https://env.example",
               model: "env-model",
               language: "env-lang"
             }
    end

    test "a row that sets ONLY url leaves provider and language on their env values" do
      put_provider!(%{provider: "", url: "https://db.example", language: ""})

      assert TTSConfig.resolve() == %{
               provider: "local",
               url: "https://db.example",
               model: "env-model",
               language: "env-lang"
             }
    end

    test "each populated field independently overrides its env value" do
      put_provider!(%{provider: "elevenlabs", url: "https://db.example", language: "fr"})
      add_model!("db-model")

      assert TTSConfig.resolve() == %{
               provider: "elevenlabs",
               url: "https://db.example",
               model: "db-model",
               language: "fr"
             }
    end

    test "a whitespace-only DB field falls back to env like a blank one" do
      put_provider!(%{provider: "  ", url: "   ", language: "\t"})

      assert TTSConfig.resolve() == %{
               provider: "local",
               url: "https://env.example",
               model: "env-model",
               language: "env-lang"
             }
    end

    test "a DB field wins even when it happens to equal the hardcoded default" do
      Application.put_env(:orca_hub, :tts_url, "https://env.example")
      put_provider!(%{provider: "", url: "https://ai.lab.ingbretsenhome.com", language: ""})

      assert TTSConfig.resolve().url == "https://ai.lab.ingbretsenhome.com"
    end

    test "a disabled provider row reverts every field to env without being deleted" do
      put_provider!(%{provider: "elevenlabs", url: "https://db.example", language: "fr"},
        enabled: false
      )

      assert TTSConfig.resolve() == %{
               provider: "local",
               url: "https://env.example",
               model: "env-model",
               language: "env-lang"
             }
    end
  end

  describe "resolve/0 model catalog" do
    test "an EMPTY catalog means TTS_MODEL, not 'no model available'" do
      assert TTSConfig.list_models() == []
      assert TTSConfig.resolve().model == "env-model"
    end

    test "a catalog with no row marked default falls back to env" do
      add_model!("first")
      {:ok, _} = TTSConfig.clear_default_model()

      assert length(TTSConfig.list_models()) == 1
      assert TTSConfig.resolve().model == "env-model"
    end

    test "the enabled row supplies the model" do
      add_model!("first")
      assert TTSConfig.resolve().model == "first"
    end

    test "the model field falls back to env independently of a fully-populated provider row" do
      put_provider!(%{provider: "local", url: "https://db.example", language: "de"})

      assert TTSConfig.resolve() == %{
               provider: "local",
               url: "https://db.example",
               model: "env-model",
               language: "de"
             }
    end
  end

  describe "default model selection" do
    test "the first model added becomes the default, later ones do not silently steal it" do
      first = add_model!("first")
      second = add_model!("second")

      assert TTSConfig.get_model!(first.id).enabled
      refute TTSConfig.get_model!(second.id).enabled
      assert TTSConfig.resolve().model == "first"
    end

    test "set_default_model/1 leaves exactly one row enabled" do
      first = add_model!("first")
      second = add_model!("second")
      third = add_model!("third")

      {:ok, _} = TTSConfig.set_default_model(second)

      enabled = TTSConfig.list_models() |> Enum.filter(& &1.enabled) |> Enum.map(& &1.name)
      assert enabled == ["second"]
      refute TTSConfig.get_model!(first.id).enabled
      refute TTSConfig.get_model!(third.id).enabled
      assert TTSConfig.resolve().model == "second"
    end

    test "update_model/2 cannot change the default flag — only set_default_model/1 can" do
      first = add_model!("first")
      second = add_model!("second")

      {:ok, updated} = TTSConfig.update_model(second, %{enabled: true, spec: %{label: "fast"}})

      refute updated.enabled
      assert updated.spec["label"] == "fast"
      assert TTSConfig.get_model!(first.id).enabled
    end

    test "deleting the default leaves the catalog with none, and the model reverts to env" do
      first = add_model!("first")
      add_model!("second")

      {:ok, _} = TTSConfig.delete_model(first)

      assert TTSConfig.resolve().model == "env-model"
    end
  end

  describe "changesets" do
    test "rejects a provider the controller cannot dispatch on" do
      assert {:error, changeset} =
               TTSConfig.put_provider(%{provider: "wat", url: "", language: ""})

      assert "provider must be one of: local, elevenlabs" in errors_on(changeset).spec
    end

    test "accepts a blank provider, since blank means 'inherit from env'" do
      assert {:ok, _} = TTSConfig.put_provider(%{provider: "", url: "", language: ""})
    end

    test "put_provider/1 upserts rather than accumulating rows" do
      put_provider!(%{provider: "local", url: "https://one.example", language: ""})
      put_provider!(%{provider: "elevenlabs", url: "https://two.example", language: ""})

      assert Repo.aggregate(
               from(e in Entry, where: e.kind == ^TTSConfig.provider_kind()),
               :count
             ) == 1

      assert TTSConfig.resolve().url == "https://two.example"
    end

    test "rejects a duplicate model name" do
      add_model!("dupe")
      assert {:error, changeset} = TTSConfig.create_model(%{name: "dupe"})
      assert "has already been taken for this kind" in errors_on(changeset).name
    end

    test "rejects a model name that would confuse the gateway" do
      assert {:error, changeset} = TTSConfig.create_model(%{name: "bad name with spaces"})
      assert changeset.errors[:name]
    end

    test "a model and the provider row may share a name — uniqueness is per kind" do
      put_provider!(%{provider: "local", url: "", language: ""})
      assert {:ok, _} = TTSConfig.create_model(%{name: TTSConfig.provider_name()})
    end
  end

  describe "env_defaults/0" do
    test "reports what each field would inherit, with no DB read" do
      put_provider!(%{provider: "elevenlabs", url: "https://db.example", language: "fr"})
      add_model!("db-model")

      assert TTSConfig.env_defaults() == %{
               provider: "local",
               url: "https://env.example",
               model: "env-model",
               language: "env-lang"
             }
    end
  end
end
