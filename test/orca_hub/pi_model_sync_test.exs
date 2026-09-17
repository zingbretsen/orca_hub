defmodule OrcaHub.PiModelSyncTest do
  @moduledoc """
  Coverage for dynamic resolution of a pi provider's `models` list from a
  live `/v1/models` endpoint (`OrcaHub.PiModelSync`).

  Every test here injects a `:fetcher` — nothing in this file makes a real
  HTTP call, and the GenServer's own tick loop is off in `config/test.exs`.

  The rules these tests exist to pin down, each of which was an observed
  outage mode rather than a hypothetical (see the module's moduledoc):

    * never write an empty `models` list — on ANY failure the row is left
      exactly as it was;
    * `apiKey` must stay a non-empty literal string, or the provider
      silently vanishes from `pi --list-models` and the model picker;
    * a resolved spec that would poison `models.json` (pi validates the file
      as ONE document — one bad field drops every provider in it) is
      refused;
    * an unchanged resolution broadcasts NOTHING, because a real write
      evicts every idle warm pi port cluster-wide;
    * hand-tuned per-model metadata survives a refresh.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{PiConfig, PiModelSync}

  @url "http://gateway.test/v1/models"

  setup do
    for entry <- PiConfig.list_entries(), do: PiConfig.delete_entry(entry)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, PiConfig.topic())
    # Drain the deletes above so a later refute_receive isn't testing them.
    flush()
    :ok
  end

  defp flush do
    receive do
      {:pi_config_updated} -> flush()
    after
      0 -> :ok
    end
  end

  defp create_provider(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          kind: "provider",
          name: "gateway-#{System.unique_integer([:positive])}",
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "none",
            "models" => [%{"id" => "old-model"}]
          },
          models_from: %{"url" => @url}
        },
        overrides
      )

    {:ok, entry} = PiConfig.create_entry(attrs)
    flush()
    entry
  end

  # The shape the gateway returns TODAY: ids only, no `kind`.
  defp id_only_payload(ids) do
    %{"object" => "list", "data" => Enum.map(ids, &%{"id" => &1, "owned_by" => "local"})}
  end

  # The shape after ai_gateway 4919308 (committed, not yet deployed).
  defp enriched_payload(entries) do
    %{"object" => "list", "data" => entries}
  end

  defp fetcher(payload), do: fn _url, _timeout -> {:ok, payload} end
  defp failing_fetcher(reason), do: fn _url, _timeout -> {:error, reason} end

  defp reload(entry), do: PiConfig.get_entry!(entry.id)

  # ── happy path ───────────────────────────────────────────────────────

  describe "refresh_entry/2" do
    test "replaces the stored model list with the endpoint's" do
      entry = create_provider()

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry,
                 fetcher: fetcher(id_only_payload(["a-model", "b-model"]))
               )

      reloaded = reload(entry)
      assert Enum.map(reloaded.spec["models"], & &1["id"]) == ["a-model", "b-model"]
      assert reloaded.models_refreshed_at
      refute reloaded.models_refresh_error
      # A real change DOES fan out to every node's PiConfigSync.
      assert_receive {:pi_config_updated}
    end

    test "leaves a row without models_from completely alone" do
      entry = create_provider(%{models_from: nil})

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["a-model"])))

      assert reason =~ "not model-managed"
      assert reload(entry).spec["models"] == [%{"id" => "old-model"}]
    end

    test "ids are sorted deterministically so ordering alone is never a change" do
      entry = create_provider()

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry,
                 fetcher: fetcher(id_only_payload(["z", "a", "m"]))
               )

      assert Enum.map(reload(entry).spec["models"], & &1["id"]) == ["a", "m", "z"]

      # Same set, different order on the wire → no second write.
      flush()

      assert {:ok, :unchanged} =
               PiModelSync.refresh_entry(reload(entry),
                 fetcher: fetcher(id_only_payload(["m", "z", "a"]))
               )

      refute_receive {:pi_config_updated}
    end
  end

  # ── rule 5: merge, don't replace ─────────────────────────────────────

  describe "merge semantics" do
    test "hand-tuned per-model metadata survives a refresh" do
      entry =
        create_provider(%{
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "none",
            "models" => [
              %{
                "id" => "qwen3-coder-next",
                "name" => "Qwen3 Coder Next (GB10)",
                "contextWindow" => 262_144,
                "reasoning" => false
              }
            ]
          }
        })

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry,
                 fetcher: fetcher(id_only_payload(["qwen3-coder-next", "new-model"]))
               )

      models = Map.new(reload(entry).spec["models"], &{&1["id"], &1})

      # The known id keeps every hand-tuned field — NOT regressed to pi's
      # silent 128000 contextWindow default.
      assert models["qwen3-coder-next"]["contextWindow"] == 262_144
      assert models["qwen3-coder-next"]["name"] == "Qwen3 Coder Next (GB10)"
      # The new id is added, carrying nothing it wasn't told.
      assert models["new-model"] == %{"id" => "new-model"}
    end

    test "stored metadata beats a conflicting freshly-fetched value" do
      entry =
        create_provider(%{
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "none",
            "models" => [%{"id" => "m1", "contextWindow" => 262_144}]
          }
        })

      payload =
        enriched_payload([
          %{"id" => "m1", "kind" => "chat", "context_window" => 32_768},
          %{"id" => "m2", "kind" => "chat", "context_window" => 65_536}
        ])

      assert {:ok, :updated} = PiModelSync.refresh_entry(entry, fetcher: fetcher(payload))

      models = Map.new(reload(entry).spec["models"], &{&1["id"], &1})
      assert models["m1"]["contextWindow"] == 262_144
      assert models["m2"]["contextWindow"] == 65_536
    end

    test "models_from defaults fill gaps for newly discovered ids only" do
      entry =
        create_provider(%{
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "none",
            "models" => [%{"id" => "m1", "contextWindow" => 8192}]
          },
          models_from: %{
            "url" => @url,
            "defaults" => %{"contextWindow" => 131_072, "input" => ["text"]}
          }
        })

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["m1", "m2"])))

      models = Map.new(reload(entry).spec["models"], &{&1["id"], &1})
      assert models["m1"]["contextWindow"] == 8192
      assert models["m2"]["contextWindow"] == 131_072
      assert models["m2"]["input"] == ["text"]
    end

    test "a model dropped by the endpoint is removed from the stored list" do
      entry = create_provider()

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["kept"])))

      assert Enum.map(reload(entry).spec["models"], & &1["id"]) == ["kept"]
    end

    test "non-models spec fields are untouched by a refresh" do
      entry = create_provider()

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["a"])))

      reloaded = reload(entry)
      assert reloaded.spec["baseUrl"] == "http://gateway.test/v1"
      assert reloaded.spec["api"] == "openai-completions"
      assert reloaded.spec["apiKey"] == "none"
    end
  end

  # ── rule 1: never write an empty list ────────────────────────────────

  describe "never writes an empty model list" do
    test "a failed fetch leaves the row untouched and records the error" do
      entry = create_provider()

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry, fetcher: failing_fetcher("connection refused"))

      assert reason == "connection refused"

      reloaded = reload(entry)
      assert reloaded.spec["models"] == [%{"id" => "old-model"}]
      assert reloaded.models_refresh_error == "connection refused"
      refute reloaded.models_refreshed_at
      refute_receive {:pi_config_updated}
    end

    test "an empty data array leaves the row untouched" do
      entry = create_provider()

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(%{"data" => []}))

      assert reason =~ "empty model list"
      assert reload(entry).spec["models"] == [%{"id" => "old-model"}]
      refute_receive {:pi_config_updated}
    end

    test "a response with no data list leaves the row untouched" do
      entry = create_provider()

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(%{"error" => "nope"}))

      assert reason =~ ~s(no "data" list)
      assert reload(entry).spec["models"] == [%{"id" => "old-model"}]
    end

    test "an all-filtered-out result leaves the row untouched" do
      entry =
        create_provider(%{models_from: %{"url" => @url, "exclude_id_patterns" => ["^tts-"]}})

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry,
                 fetcher: fetcher(id_only_payload(["tts-a", "tts-b"]))
               )

      assert reason =~ "filtered out"
      assert reload(entry).spec["models"] == [%{"id" => "old-model"}]
      refute_receive {:pi_config_updated}
    end

    test "a successful refresh clears a previously recorded error" do
      entry = create_provider()

      {:error, _} = PiModelSync.refresh_entry(entry, fetcher: failing_fetcher("boom"))
      assert reload(entry).models_refresh_error == "boom"

      {:ok, :updated} =
        PiModelSync.refresh_entry(reload(entry), fetcher: fetcher(id_only_payload(["a"])))

      refute reload(entry).models_refresh_error
    end
  end

  # ── rule 4: no churn, no broadcast ───────────────────────────────────

  describe "unchanged resolutions" do
    test "resolving the same set writes no spec and broadcasts nothing" do
      entry = create_provider()

      {:ok, :updated} =
        PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["a", "b"])))

      assert_receive {:pi_config_updated}
      first = reload(entry)

      assert {:ok, :unchanged} =
               PiModelSync.refresh_entry(first, fetcher: fetcher(id_only_payload(["a", "b"])))

      second = reload(entry)
      assert second.spec == first.spec
      # THE guard: a broadcast here would re-sync every node, and a
      # models.json write evicts every idle warm pi port cluster-wide.
      refute_receive {:pi_config_updated}
    end

    test "an unchanged resolution still stamps models_refreshed_at" do
      entry =
        create_provider(%{
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "none",
            "models" => [%{"id" => "a"}]
          }
        })

      assert {:ok, :unchanged} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["a"])))

      assert reload(entry).models_refreshed_at
      refute_receive {:pi_config_updated}
    end
  end

  # ── non-chat filtering, under BOTH response shapes ───────────────────

  describe "non-chat model filtering" do
    test "enriched responses keep only models that POSITIVELY declare kind == chat" do
      entry = create_provider()

      payload =
        enriched_payload([
          %{"id" => "chat-a", "kind" => "chat"},
          %{"id" => "tts-chatterbox-23lang", "kind" => "tts"},
          # No `kind` in an otherwise-enriched response: dropped, never
          # assumed to be chat — defaulting is what resurrects the TTS bug.
          %{"id" => "mystery"}
        ])

      assert {:ok, :updated} = PiModelSync.refresh_entry(entry, fetcher: fetcher(payload))
      assert Enum.map(reload(entry).spec["models"], & &1["id"]) == ["chat-a"]
    end

    test "id-only responses fall back to the configured exclude filters" do
      entry =
        create_provider(%{
          models_from: %{"url" => @url, "exclude_id_patterns" => ["^tts-"]}
        })

      payload = id_only_payload(["Qwen3.8-27B", "qwen3-coder-next", "tts-chatterbox-23lang"])

      assert {:ok, :updated} = PiModelSync.refresh_entry(entry, fetcher: fetcher(payload))

      assert Enum.map(reload(entry).spec["models"], & &1["id"]) ==
               ["Qwen3.8-27B", "qwen3-coder-next"]
    end

    test "an explicit exclude_ids list also applies to an enriched response" do
      entry =
        create_provider(%{
          models_from: %{"url" => @url, "exclude_ids" => ["chat-b"]}
        })

      payload =
        enriched_payload([
          %{"id" => "chat-a", "kind" => "chat"},
          %{"id" => "chat-b", "kind" => "chat"}
        ])

      assert {:ok, :updated} = PiModelSync.refresh_entry(entry, fetcher: fetcher(payload))
      assert Enum.map(reload(entry).spec["models"], & &1["id"]) == ["chat-a"]
    end

    test "include_ids restricts to an allow-list" do
      entry =
        create_provider(%{models_from: %{"url" => @url, "include_ids" => ["b"]}})

      assert {:ok, :updated} =
               PiModelSync.refresh_entry(entry,
                 fetcher: fetcher(id_only_payload(["a", "b", "c"]))
               )

      assert Enum.map(reload(entry).spec["models"], & &1["id"]) == ["b"]
    end

    test "maps the enriched per-model fields onto pi's names" do
      entry = create_provider()

      payload =
        enriched_payload([
          %{
            "id" => "m1",
            "kind" => "chat",
            "name" => "Model One",
            "context_window" => 65_536,
            "max_output_tokens" => 4096,
            "input_modalities" => ["text", "image"],
            "reasoning" => true,
            "on_demand" => true
          }
        ])

      assert {:ok, :updated} = PiModelSync.refresh_entry(entry, fetcher: fetcher(payload))

      [model] = reload(entry).spec["models"]
      assert model["name"] == "Model One"
      assert model["contextWindow"] == 65_536
      assert model["maxTokens"] == 4096
      assert model["input"] == ["text", "image"]
      assert model["reasoning"] == true
      # Not a pi field — must not leak into models.json.
      refute Map.has_key?(model, "on_demand")
    end

    test "an omitted max_output_tokens means no claim, not zero" do
      entry = create_provider()

      payload =
        enriched_payload([%{"id" => "m1", "kind" => "chat", "context_window" => 131_072}])

      assert {:ok, :updated} = PiModelSync.refresh_entry(entry, fetcher: fetcher(payload))

      [model] = reload(entry).spec["models"]
      refute Map.has_key?(model, "maxTokens")
      assert model["contextWindow"] == 131_072
    end
  end

  # ── rules 2 and 3: the spec gate ─────────────────────────────────────

  describe "validate_spec/1" do
    defp base_spec(overrides \\ %{}) do
      Map.merge(
        %{
          "baseUrl" => "http://gateway.test/v1",
          "api" => "openai-completions",
          "apiKey" => "none",
          "models" => [%{"id" => "m1"}]
        },
        overrides
      )
    end

    test "accepts a well-formed provider" do
      assert :ok = PiModelSync.validate_spec(base_spec())
    end

    # Rule 2 regression guard: a provider whose apiKey is absent or empty is
    # omitted from `pi --list-models` entirely, so it vanishes from the
    # session model picker while models.json on disk still looks correct.
    # This is one line away from breaking at all times.
    test "rejects a missing apiKey" do
      assert {:error, reason} =
               PiModelSync.validate_spec(Map.delete(base_spec(), "apiKey"))

      assert reason =~ "apiKey"
    end

    test "rejects an empty-string apiKey" do
      assert {:error, reason} = PiModelSync.validate_spec(base_spec(%{"apiKey" => ""}))
      assert reason =~ "apiKey"
      # pi's own schema has minLength: 1 here, and models.json is validated
      # as ONE document — this would take every OTHER provider down with it.
      assert {:error, _} = PiModelSync.validate_spec(base_spec(%{"apiKey" => "   "}))
    end

    test "rejects an empty models list" do
      assert {:error, reason} = PiModelSync.validate_spec(base_spec(%{"models" => []}))
      assert reason =~ "models"
    end

    test "rejects a missing api or baseUrl" do
      assert {:error, _} = PiModelSync.validate_spec(Map.delete(base_spec(), "api"))
      assert {:error, _} = PiModelSync.validate_spec(Map.delete(base_spec(), "baseUrl"))
    end

    test "rejects a model with no id" do
      assert {:error, reason} =
               PiModelSync.validate_spec(base_spec(%{"models" => [%{"name" => "x"}]}))

      assert reason =~ "id"
    end

    test "rejects non-positive contextWindow / maxTokens" do
      assert {:error, reason} =
               PiModelSync.validate_spec(
                 base_spec(%{"models" => [%{"id" => "m1", "contextWindow" => 0}]})
               )

      assert reason =~ "contextWindow"

      assert {:error, _} =
               PiModelSync.validate_spec(
                 base_spec(%{"models" => [%{"id" => "m1", "maxTokens" => -1}]})
               )
    end

    test "rejects a non-list input modality" do
      assert {:error, reason} =
               PiModelSync.validate_spec(
                 base_spec(%{"models" => [%{"id" => "m1", "input" => "text"}]})
               )

      assert reason =~ "input"
    end
  end

  describe "the spec gate refuses a file-poisoning write" do
    test "a row whose stored apiKey is empty is never rewritten" do
      # An empty apiKey trips pi's minLength: 1 and discards EVERY provider
      # in models.json. We refuse to touch such a row rather than republish
      # it with a fresh model list.
      entry =
        create_provider(%{
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "",
            "models" => [%{"id" => "old-model"}]
          }
        })

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["a"])))

      assert reason =~ "refusing to write"
      assert reload(entry).spec["models"] == [%{"id" => "old-model"}]
      assert reload(entry).models_refresh_error =~ "apiKey"
      refute_receive {:pi_config_updated}
    end

    test "a hand-authored model with a zero contextWindow blocks the write" do
      entry =
        create_provider(%{
          spec: %{
            "baseUrl" => "http://gateway.test/v1",
            "api" => "openai-completions",
            "apiKey" => "none",
            "models" => [%{"id" => "a", "contextWindow" => 0}]
          }
        })

      assert {:error, reason} =
               PiModelSync.refresh_entry(entry, fetcher: fetcher(id_only_payload(["a", "b"])))

      assert reason =~ "contextWindow"
      assert reload(entry).spec["models"] == [%{"id" => "a", "contextWindow" => 0}]
    end
  end

  # ── url handling / batch pass ────────────────────────────────────────

  describe "models_url/1" do
    test "passes a full /v1/models URL through" do
      assert PiModelSync.models_url("http://ai.test/v1/models") == "http://ai.test/v1/models"
    end

    test "appends /models to a bare base URL and tolerates a trailing slash" do
      assert PiModelSync.models_url("http://ai.test/v1") == "http://ai.test/v1/models"
      assert PiModelSync.models_url("http://ai.test/v1/") == "http://ai.test/v1/models"
      assert PiModelSync.models_url(" http://ai.test/v1/models/ ") == "http://ai.test/v1/models"
    end
  end

  describe "refresh_all/1" do
    test "refreshes every managed row and skips unmanaged ones" do
      managed = create_provider(%{name: "managed-a"})
      _unmanaged = create_provider(%{name: "unmanaged-a", models_from: nil})

      results =
        PiModelSync.refresh_all(fetcher: fetcher(id_only_payload(["x"])))

      assert results == [{"managed-a", {:ok, :updated}}]
      assert Enum.map(reload(managed).spec["models"], & &1["id"]) == ["x"]
    end

    test "one unreachable endpoint doesn't stop the others" do
      _a = create_provider(%{name: "a-provider"})
      _b = create_provider(%{name: "b-provider"})

      fetcher = fn _url, _timeout -> {:error, "down"} end
      results = PiModelSync.refresh_all(fetcher: fetcher)

      assert length(results) == 2
      assert Enum.all?(results, fn {_name, result} -> match?({:error, "down"}, result) end)
    end

    test "includes disabled rows, so re-enabling one doesn't hand pi a stale list" do
      entry = create_provider(%{name: "disabled-a", enabled: false})
      flush()

      assert [{"disabled-a", {:ok, :updated}}] =
               PiModelSync.refresh_all(fetcher: fetcher(id_only_payload(["x"])))

      assert Enum.map(reload(entry).spec["models"], & &1["id"]) == ["x"]
    end
  end
end
