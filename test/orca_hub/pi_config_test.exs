defmodule OrcaHub.PiConfigTest do
  @moduledoc """
  Coverage for the hub-managed pi config context — CRUD, per-kind spec
  validation, and the `{:pi_config_updated}` PubSub broadcast that
  `OrcaHub.PiConfigSync` listens for. Materialization into `~/.pi/agent` is
  covered in `OrcaHub.PiConfigSyncTest`.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.PiConfig
  alias OrcaHub.PiConfig.Entry

  setup do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "pi_config")
    :ok
  end

  setup do
    # Clean up all pi config entries to avoid flaky tests from pre-existing data
    for entry <- PiConfig.list_entries() do
      PiConfig.delete_entry(entry)
    end

    :ok
  end

  defp provider_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "provider",
        name: "ollama-#{System.unique_integer([:positive])}",
        spec: %{
          "baseUrl" => "http://localhost:11434/v1",
          "api" => "openai-completions",
          "apiKey" => "ollama",
          "models" => [%{"id" => "llama3.1:8b"}]
        }
      },
      overrides
    )
  end

  describe "create_entry/1" do
    test "creates a provider entry with defaults and broadcasts" do
      assert {:ok, %Entry{} = entry} = PiConfig.create_entry(provider_attrs())

      assert entry.enabled
      assert entry.kind == "provider"
      assert entry.spec["baseUrl"] == "http://localhost:11434/v1"
      assert_receive {:pi_config_updated}
    end

    test "deep-stringifies atom-keyed spec maps and lists" do
      assert {:ok, entry} =
               PiConfig.create_entry(
                 provider_attrs(%{spec: %{baseUrl: "http://x/v1", models: [%{id: "m1"}]}})
               )

      assert entry.spec == %{"baseUrl" => "http://x/v1", "models" => [%{"id" => "m1"}]}
    end

    test "requires kind and name" do
      assert {:error, changeset} = PiConfig.create_entry(%{spec: %{"value" => 1}})
      assert "can't be blank" in errors_on(changeset).kind
      assert "can't be blank" in errors_on(changeset).name
    end

    test "rejects an unknown kind" do
      assert {:error, changeset} =
               PiConfig.create_entry(%{kind: "bogus", name: "x", spec: %{"body" => "y"}})

      assert "is invalid" in errors_on(changeset).kind
    end

    test "rejects names that could escape their surface" do
      for bad <- [".hidden", "../escape", "a/b", "a\\b", "", "-leading"] do
        assert {:error, changeset} =
                 PiConfig.create_entry(%{kind: "prompt", name: bad, spec: %{"body" => "x"}})

        assert errors_on(changeset).name != nil, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "accepts settings-key and provider-style names" do
      assert {:ok, _} =
               PiConfig.create_entry(%{
                 kind: "setting",
                 name: "defaultModel",
                 spec: %{"value" => "gpt-oss:20b"}
               })

      assert {:ok, _} = PiConfig.create_entry(provider_attrs(%{name: "my_google.v2-beta"}))
    end

    test "requires a value key on a setting" do
      assert {:error, changeset} =
               PiConfig.create_entry(%{kind: "setting", name: "theme", spec: %{"theme" => "x"}})

      assert ~s(must contain a "value" key) in errors_on(changeset).spec
    end

    test "accepts any JSON value on a setting, including false and nil" do
      assert {:ok, e1} =
               PiConfig.create_entry(%{
                 kind: "setting",
                 name: "someFlag",
                 spec: %{"value" => false}
               })

      assert e1.spec["value"] == false

      assert {:ok, e2} =
               PiConfig.create_entry(%{
                 kind: "setting",
                 name: "someNull",
                 spec: %{"value" => nil}
               })

      assert e2.spec["value"] == nil
    end

    test "requires a body string on file-backed kinds" do
      for kind <- ["extension", "prompt", "theme"] do
        assert {:error, changeset} =
                 PiConfig.create_entry(%{kind: kind, name: "x", spec: %{"body" => 42}})

        assert ~s(must contain a "body" string) in errors_on(changeset).spec
      end
    end

    test "requires a non-empty provider spec" do
      assert {:error, changeset} = PiConfig.create_entry(provider_attrs(%{spec: %{}}))
      assert errors_on(changeset).spec != nil
    end

    test "enforces unique name per kind but allows the same name across kinds" do
      assert {:ok, _} =
               PiConfig.create_entry(%{kind: "prompt", name: "shared", spec: %{"body" => "a"}})

      assert {:ok, _} =
               PiConfig.create_entry(%{kind: "theme", name: "shared", spec: %{"body" => "{}"}})

      assert {:error, changeset} =
               PiConfig.create_entry(%{kind: "prompt", name: "shared", spec: %{"body" => "b"}})

      assert "has already been taken for this kind" in errors_on(changeset).name
    end

    test "does not broadcast on a failed create" do
      assert {:error, _} = PiConfig.create_entry(%{})
      refute_receive {:pi_config_updated}
    end
  end

  describe "update_entry/2 and delete_entry/1" do
    test "updates fields and broadcasts" do
      {:ok, entry} = PiConfig.create_entry(provider_attrs())
      assert_receive {:pi_config_updated}

      assert {:ok, updated} = PiConfig.update_entry(entry, %{enabled: false})
      refute updated.enabled
      assert_receive {:pi_config_updated}
    end

    test "deletes and broadcasts" do
      {:ok, entry} = PiConfig.create_entry(provider_attrs())
      assert_receive {:pi_config_updated}

      assert {:ok, _} = PiConfig.delete_entry(entry)
      assert PiConfig.get_entry(entry.id) == nil
      assert_receive {:pi_config_updated}
    end
  end

  describe "listing" do
    test "list_enabled_entries/0 excludes disabled entries" do
      {:ok, on} = PiConfig.create_entry(provider_attrs())
      {:ok, off} = PiConfig.create_entry(provider_attrs(%{enabled: false}))

      names = PiConfig.list_enabled_entries() |> Enum.map(& &1.name)
      assert on.name in names
      refute off.name in names

      all_names = PiConfig.list_entries() |> Enum.map(& &1.name)
      assert off.name in all_names
    end

    test "per-kind listing filters by kind" do
      {:ok, provider} = PiConfig.create_entry(provider_attrs())

      {:ok, prompt} =
        PiConfig.create_entry(%{
          kind: "prompt",
          name: "review-#{System.unique_integer([:positive])}",
          spec: %{"body" => "Review it."}
        })

      provider_names = PiConfig.list_enabled_entries("provider") |> Enum.map(& &1.name)
      assert provider.name in provider_names
      refute prompt.name in provider_names

      assert prompt.name in (PiConfig.list_entries("prompt") |> Enum.map(& &1.name))
    end
  end

  describe "get_entry_by_kind_and_name/2" do
    test "fetches scoped to the kind" do
      {:ok, entry} =
        PiConfig.create_entry(%{
          kind: "theme",
          name: "midnight-#{System.unique_integer([:positive])}",
          spec: %{"body" => "{}"}
        })

      assert PiConfig.get_entry_by_kind_and_name("theme", entry.name).id == entry.id
      assert PiConfig.get_entry_by_kind_and_name("prompt", entry.name) == nil
    end
  end

  # ── models_from: opt-in dynamic model resolution (OrcaHub.PiModelSync) ──

  describe "models_from" do
    test "defaults to nil — an existing provider keeps its hand-authored models" do
      assert {:ok, entry} = PiConfig.create_entry(provider_attrs())

      assert is_nil(entry.models_from)
      assert is_nil(entry.models_refreshed_at)
      assert is_nil(entry.models_refresh_error)
    end

    test "casts and deep-stringifies an atom-keyed config" do
      assert {:ok, entry} =
               PiConfig.create_entry(
                 provider_attrs(%{
                   models_from: %{
                     url: "http://ai.test/v1/models",
                     defaults: %{contextWindow: 8192}
                   }
                 })
               )

      assert entry.models_from == %{
               "url" => "http://ai.test/v1/models",
               "defaults" => %{"contextWindow" => 8192}
             }
    end

    test "requires an http(s) url" do
      assert {:error, changeset} =
               PiConfig.create_entry(provider_attrs(%{models_from: %{"defaults" => %{}}}))

      assert %{models_from: [message]} = errors_on(changeset)
      assert message =~ "url"

      assert {:error, _} =
               PiConfig.create_entry(provider_attrs(%{models_from: %{"url" => "not-a-url"}}))

      assert {:error, _} =
               PiConfig.create_entry(
                 provider_attrs(%{models_from: %{"url" => "ftp://ai.test/v1"}})
               )
    end

    test "is rejected on any kind other than provider" do
      assert {:error, changeset} =
               PiConfig.create_entry(%{
                 kind: "setting",
                 name: "defaultModel",
                 spec: %{"value" => "x"},
                 models_from: %{"url" => "http://ai.test/v1/models"}
               })

      assert %{models_from: [message]} = errors_on(changeset)
      assert message =~ "provider"
    end

    test "rejects malformed filter lists and an uncompilable exclude pattern" do
      assert {:error, _} =
               PiConfig.create_entry(
                 provider_attrs(%{
                   models_from: %{"url" => "http://ai.test/v1/models", "exclude_ids" => "tts"}
                 })
               )

      assert {:error, _} =
               PiConfig.create_entry(
                 provider_attrs(%{
                   models_from: %{"url" => "http://ai.test/v1/models", "defaults" => "nope"}
                 })
               )

      assert {:error, changeset} =
               PiConfig.create_entry(
                 provider_attrs(%{
                   models_from: %{
                     "url" => "http://ai.test/v1/models",
                     "exclude_id_patterns" => ["^tts-["]
                   }
                 })
               )

      assert %{models_from: [message]} = errors_on(changeset)
      assert message =~ "invalid regex"
    end

    test "clearing models_from hands the row back to hand-authoring" do
      {:ok, entry} =
        PiConfig.create_entry(
          provider_attrs(%{models_from: %{"url" => "http://ai.test/v1/models"}})
        )

      assert {:ok, updated} = PiConfig.update_entry(entry, %{models_from: nil})
      assert is_nil(updated.models_from)
    end
  end

  describe "list_model_managed_entries/0" do
    test "returns only provider rows with a models_from, enabled or not" do
      {:ok, managed} =
        PiConfig.create_entry(
          provider_attrs(%{models_from: %{"url" => "http://ai.test/v1/models"}})
        )

      {:ok, disabled} =
        PiConfig.create_entry(
          provider_attrs(%{
            models_from: %{"url" => "http://ai.test/v1/models"},
            enabled: false
          })
        )

      {:ok, unmanaged} = PiConfig.create_entry(provider_attrs())

      names = PiConfig.list_model_managed_entries() |> Enum.map(& &1.name)
      assert managed.name in names
      # Disabled rows are included on purpose: re-enabling one must not hand
      # pi a months-stale list.
      assert disabled.name in names
      refute unmanaged.name in names
    end
  end

  describe "record_models_refresh/2" do
    test "stamps bookkeeping WITHOUT broadcasting {:pi_config_updated}" do
      {:ok, entry} =
        PiConfig.create_entry(
          provider_attrs(%{models_from: %{"url" => "http://ai.test/v1/models"}})
        )

      assert_receive {:pi_config_updated}

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      assert {:ok, updated} =
               PiConfig.record_models_refresh(entry, %{
                 models_refreshed_at: now,
                 models_refresh_error: nil
               })

      assert updated.models_refreshed_at == now
      # THE point of this function: a no-op refresh must not fan a sync out
      # to every node, because a models.json write evicts warm pi ports
      # cluster-wide.
      refute_receive {:pi_config_updated}
    end

    test "never touches spec, even if asked to" do
      {:ok, entry} = PiConfig.create_entry(provider_attrs())
      original = entry.spec

      assert {:ok, updated} =
               PiConfig.record_models_refresh(entry, %{
                 spec: %{"baseUrl" => "http://evil/v1"},
                 models_refresh_error: "boom"
               })

      assert updated.spec == original
      assert updated.models_refresh_error == "boom"
    end
  end
end
