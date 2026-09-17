defmodule OrcaHub.PiModelSync do
  @moduledoc """
  Resolves the `models` list of opted-in pi provider entries
  (`OrcaHub.PiConfig.Entry` rows with a non-nil `models_from`) from a live
  OpenAI-compatible `GET /v1/models` endpoint — today the homelab
  ai_gateway — so adding a model to the gateway shows up in pi, including in
  the session model picker, without an OrcaHub edit.

  ## Where this runs, and why

  HUB-ONLY (registered in `Application.hub_children/1`, sibling to
  `ChurnSampler`/`Issues.IndexSweep`). It fetches, resolves, and writes the
  provider row through `PiConfig.update_entry/2`; the existing
  `{:pi_config_updated}` broadcast then fans the new spec out to every
  node's `OrcaHub.PiConfigSync`, which needs no changes at all.

  Resolution deliberately does NOT happen per-node at sync time:

    * only the hub owns the DB — `PiConfigSync` is pure disk + `HubRPC`;
    * agent pods can't even reach the gateway (`orca-agent-dell`'s egress
      NetworkPolicy excepts `10.0.0.0/8`, which covers the ClusterIP);
    * N independent writers each publishing whatever an endpoint handed
      them is how you get a half-empty model list on one node only.

  An hourly tick is plenty: the gateway's model set changes via a git+Flux
  edit of its `UPSTREAMS` env, not at runtime.

  ## The five rules this module exists to enforce

  Each was established empirically; violating one is a real outage.

  1. **Never write an empty `models` list.** A provider with >= 1 model
     passes arbitrary ids through to the endpoint with a warning; a
     provider with ZERO models is a hard client-side failure (`Error: Model
     "x/y" not found`) AND is invisible to `pi --list-models`. On a fetch
     failure, a non-200, an empty `data`, or an all-filtered-out result we
     log, record the error in `models_refresh_error`, and return WITHOUT
     touching the row. A stale list beats an empty one every time.

  2. **`apiKey` must stay a non-empty literal string** (`"none"` is fine).
     A provider whose `apiKey` field is absent — or is an unresolvable
     `$VAR` — is omitted from `pi --list-models` entirely, so it vanishes
     from the session model picker while `models.json` on disk still looks
     perfectly correct. The VALUE is irrelevant to a keyless endpoint; its
     PRESENCE is what makes the provider visible.

  3. **Validate the resolved spec before writing.** pi validates
     `models.json` as a SINGLE document: one schema-invalid field anywhere
     discards EVERY provider in the file, on every node at once.
     `PiConfigSync` writes specs verbatim and has no notion of pi's schema,
     so `validate_spec/1` here is the only gate.

  4. **Skip the write when the resolved spec equals the stored one**
     (ids sorted before comparing). Every real write broadcasts
     `{:pi_models_changed, node}` and evicts every idle warm pi port
     cluster-wide; a churning list would kill warm ports everywhere, hourly.
     An unchanged resolution still stamps `models_refreshed_at`, but through
     `PiConfig.record_models_refresh/2`, which does NOT broadcast.

  5. **Merge, don't replace.** Per-model metadata already stored for a known
     id is preserved, so resolution only ADDS and REMOVES ids and can never
     regress a hand-tuned `contextWindow` to pi's silent 128000 default.
     (pi's omitted-field defaults, `provider-composer.js`: `name = id`,
     `reasoning = false`, `input = ["text"]`, `cost` all zeros,
     `contextWindow = 128000`, `maxTokens = 16384`.)

  A sixth, implicit in all of the above: we resolve id SETS, never
  residency. A model that is merely not currently loaded must not drop out
  of the list.

  ## Response shapes

  Both are handled. The gateway currently returns ids only:

      {"data": [{"id": "Qwen3.8-27B", "object": "model", "owned_by": "local"}, ...]}

  A committed-but-undeployed gateway change enriches each entry with
  `kind` (`"chat"`/`"tts"`), `name`, `context_window`, `input_modalities`,
  `reasoning`, `on_demand`, and `max_output_tokens` (per-listener, and
  OMITTED ENTIRELY when the listener applies no cap — absent means "the
  gateway makes no claim", not `null` and not `0`).

  Mode is detected per RESPONSE: if any entry carries a `kind`, the response
  is treated as enriched and every model must POSITIVELY declare
  `kind == "chat"` — a missing `kind` is NOT defaulted to chat, which is
  what would resurrect the `tts-chatterbox-23lang`-as-a-chat-model bug. If
  no entry carries a `kind` at all (the gateway hasn't been deployed yet, or
  was rolled back), we fall back to the explicit `include_ids` /
  `exclude_ids` / `exclude_id_patterns` filters from `models_from`, so a
  rollback can't poison the picker.

  Those explicit filters apply in BOTH modes — an operator exclusion always
  wins over whatever the gateway claims.

  ## Field precedence

  `stored > fetched > models_from["defaults"] > (omitted, and pi supplies
  its own default)`, applied per model field. Rule 5 is the reason stored
  wins: a hand-tuned value must survive a refresh. The practical consequence
  is that correcting a model's metadata after it has been discovered means
  editing the row (or deleting that model's entry from `spec["models"]` so
  the next refresh re-derives it), not just fixing the gateway.

  ## Testing

  The GenServer loop is gated behind `config :orca_hub,
  :pi_model_sync_enabled` (`false` in `config/test.exs`) so `mix test`'s
  full-application boot never makes a live HTTP call to the gateway. Tests
  call `refresh_entry/2` with an injected `:fetcher`, or the pure
  `resolve_spec/3` / `validate_spec/1` directly.
  """

  use GenServer
  require Logger

  alias OrcaHub.{PiConfig, PiConfig.Entry}

  @interval_ms :timer.hours(1)
  @boot_delay_ms :timer.seconds(30)
  @default_timeout_ms 15_000

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the GenServer runs its boot-time / periodic refresh loop."
  def enabled? do
    Application.get_env(:orca_hub, :pi_model_sync_enabled, true)
  end

  @doc """
  Refreshes every model-managed provider row. Returns
  `[{entry_name, result}]` where each result is what `refresh_entry/2`
  returned. Never raises — one unreachable endpoint must not stop the
  others from refreshing.
  """
  def refresh_all(opts \\ []) do
    entries =
      Keyword.get_lazy(opts, :entries, fn -> PiConfig.list_model_managed_entries() end)

    Enum.map(entries, fn entry -> {entry.name, refresh_entry(entry, opts)} end)
  end

  @doc """
  Refreshes ONE provider row's `models` list.

  Returns `{:ok, :updated}` (the spec changed and was written, broadcasting
  `{:pi_config_updated}`), `{:ok, :unchanged}` (resolved to the same set —
  bookkeeping stamped, NOTHING broadcast), or `{:error, reason}` (the row's
  `spec` is untouched and `models_refresh_error` records why).

  Options:

    * `:fetcher` — 2-arity fun `(url, timeout_ms)` returning
      `{:ok, decoded_body} | {:error, reason}`; defaults to a real `Req` GET.
    * `:now` — `NaiveDateTime` to stamp (default `utc_now/0`).
  """
  def refresh_entry(%Entry{} = entry, opts \\ []) do
    with {:ok, config} <- managed_config(entry),
         {:ok, payload} <- fetch(config, opts),
         {:ok, new_spec} <- resolve_spec(entry.spec, config, payload) do
      write(entry, new_spec, opts)
    else
      {:error, reason} ->
        Logger.warning(
          "PiModelSync: provider #{entry.name} not refreshed (spec left untouched): #{reason}"
        )

        record(entry, %{models_refresh_error: reason})
        {:error, reason}
    end
  end

  @doc """
  Resolves a provider `spec` against one decoded `/v1/models` payload.

  Pure: no DB, no HTTP. Returns `{:ok, spec_with_new_models}` or
  `{:error, human_readable_reason}` — and per rule 1 it errors rather than
  ever returning a spec whose `models` list is empty.
  """
  def resolve_spec(spec, config, payload) when is_map(spec) and is_map(config) do
    with {:ok, data} <- extract_data(payload),
         {:ok, candidates} <- filter_models(data, config) do
      models = Enum.map(candidates, &merge_model(&1, spec, config))
      new_spec = Map.put(spec, "models", Enum.sort_by(models, & &1["id"]))

      case validate_spec(new_spec) do
        :ok -> {:ok, new_spec}
        {:error, why} -> {:error, "resolved spec is invalid, refusing to write: #{why}"}
      end
    end
  end

  @doc """
  Checks a provider spec against the subset of pi's `models.json` schema we
  can be sure of. `:ok` or `{:error, reason}`.

  This is the ONLY thing standing between a bad resolution and a
  `models.json` that pi rejects WHOLESALE — one invalid field takes every
  provider in the file down with it, on every node.
  """
  def validate_spec(spec) when is_map(spec) do
    models = spec["models"]

    cond do
      # Rule 2. A provider without a non-empty apiKey silently disappears
      # from `pi --list-models`, and hence from the model picker, while
      # models.json on disk still looks fine.
      not non_empty_binary?(spec["apiKey"]) ->
        {:error,
         ~s|provider "apiKey" must be a non-empty string (use "none" for a keyless endpoint)|}

      not non_empty_binary?(spec["api"]) ->
        {:error, ~s(provider "api" must be a non-empty string)}

      not non_empty_binary?(spec["baseUrl"]) ->
        {:error, ~s(provider "baseUrl" must be a non-empty string)}

      # Rule 1.
      not (is_list(models) and models != []) ->
        {:error, ~s(provider "models" must be a non-empty list)}

      true ->
        models
        |> Enum.find_value(&model_error/1)
        |> case do
          nil -> :ok
          why -> {:error, why}
        end
    end
  end

  def validate_spec(_), do: {:error, "provider spec must be a map"}

  # -------------------------------------------------------------------
  # Resolution internals
  # -------------------------------------------------------------------

  defp managed_config(%Entry{models_from: config}) when is_map(config), do: {:ok, config}
  defp managed_config(_), do: {:error, "entry is not model-managed (models_from is nil)"}

  defp extract_data(%{"data" => data}) when is_list(data) and data != [] do
    {:ok, Enum.filter(data, &(is_map(&1) and non_empty_binary?(&1["id"])))}
  end

  defp extract_data(%{"data" => []}), do: {:error, "endpoint returned an empty model list"}

  defp extract_data(_),
    do: {:error, ~s(endpoint response has no "data" list)}

  # Enriched vs legacy is a per-RESPONSE decision: if ANY entry carries a
  # "kind", every entry must positively declare kind == "chat". A missing
  # kind in an otherwise-enriched response is dropped, never assumed chat.
  defp filter_models(data, config) do
    enriched? = Enum.any?(data, &Map.has_key?(&1, "kind"))

    kept =
      data
      |> then(fn models ->
        if enriched?, do: Enum.filter(models, &(&1["kind"] == "chat")), else: models
      end)
      |> Enum.filter(&allowed_id?(&1["id"], config))

    case kept do
      [] ->
        {:error,
         "every model returned by the endpoint was filtered out " <>
           "(#{length(data)} returned, #{if enriched?, do: "enriched", else: "id-only"} response)"}

      kept ->
        {:ok, kept}
    end
  end

  defp allowed_id?(id, config) do
    include = config["include_ids"]

    included? = not is_list(include) or id in include
    excluded? = id in List.wrap(config["exclude_ids"]) or matches_pattern?(id, config)

    included? and not excluded?
  end

  defp matches_pattern?(id, config) do
    config
    |> Map.get("exclude_id_patterns", [])
    |> List.wrap()
    |> Enum.any?(fn pattern ->
      case Regex.compile(pattern) do
        {:ok, regex} -> Regex.match?(regex, id)
        {:error, _} -> false
      end
    end)
  end

  # Rule 5: stored > fetched > configured defaults. A known id keeps every
  # field it already has; a newly discovered id gets whatever the gateway
  # claims, then the configured defaults, then pi's own defaults for the
  # rest.
  defp merge_model(fetched, spec, config) do
    id = fetched["id"]
    stored = stored_model(spec, id)
    defaults = if is_map(config["defaults"]), do: config["defaults"], else: %{}

    defaults
    |> Map.merge(from_gateway(fetched))
    |> Map.merge(stored)
    |> Map.put("id", id)
  end

  defp stored_model(spec, id) do
    spec
    |> Map.get("models", [])
    |> List.wrap()
    |> Enum.find(%{}, &(is_map(&1) and &1["id"] == id))
  end

  # The enriched gateway fields, mapped onto pi's per-model field names.
  # An ABSENT field is omitted rather than nil'd — `max_output_tokens` in
  # particular is omitted when the listener applies no cap, which means
  # "no claim", not "zero".
  defp from_gateway(fetched) do
    %{}
    |> put_if(fetched, "name", "name", &non_empty_binary?/1)
    |> put_if(fetched, "context_window", "contextWindow", &positive_integer?/1)
    |> put_if(fetched, "max_output_tokens", "maxTokens", &positive_integer?/1)
    |> put_if(fetched, "input_modalities", "input", &modality_list?/1)
    |> put_if(fetched, "reasoning", "reasoning", &is_boolean/1)
  end

  defp put_if(acc, fetched, source_key, target_key, valid?) do
    case Map.fetch(fetched, source_key) do
      {:ok, value} -> if valid?.(value), do: Map.put(acc, target_key, value), else: acc
      :error -> acc
    end
  end

  # -------------------------------------------------------------------
  # Validation helpers
  # -------------------------------------------------------------------

  defp model_error(model) when is_map(model) do
    cond do
      not non_empty_binary?(model["id"]) ->
        ~s(a model has no non-empty "id")

      Map.has_key?(model, "contextWindow") and not positive_integer?(model["contextWindow"]) ->
        ~s(model "#{model["id"]}" has a non-positive "contextWindow")

      Map.has_key?(model, "maxTokens") and not positive_integer?(model["maxTokens"]) ->
        ~s(model "#{model["id"]}" has a non-positive "maxTokens")

      Map.has_key?(model, "input") and not modality_list?(model["input"]) ->
        ~s(model "#{model["id"]}" has a non-list/empty "input")

      Map.has_key?(model, "reasoning") and not is_boolean(model["reasoning"]) ->
        ~s(model "#{model["id"]}" has a non-boolean "reasoning")

      Map.has_key?(model, "name") and not non_empty_binary?(model["name"]) ->
        ~s(model "#{model["id"]}" has an empty "name")

      true ->
        nil
    end
  end

  defp model_error(_), do: "a model entry is not a map"

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp modality_list?(value),
    do: is_list(value) and value != [] and Enum.all?(value, &non_empty_binary?/1)

  # -------------------------------------------------------------------
  # Fetch
  # -------------------------------------------------------------------

  defp fetch(config, opts) do
    url = models_url(config["url"])

    timeout =
      if positive_integer?(config["timeout_ms"]),
        do: config["timeout_ms"],
        else: @default_timeout_ms

    fetcher = Keyword.get(opts, :fetcher, &http_get_json/2)

    case fetcher.(url, timeout) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, other} -> {:error, "#{url} returned #{inspect(other)} instead of a JSON object"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "#{url}: #{inspect(reason)}"}
    end
  end

  @doc """
  The URL actually fetched for a configured `models_from["url"]`.

  Forgiving on purpose — the natural thing to paste is the provider's own
  `baseUrl` (`http://host/v1`), so a URL that doesn't already end in
  `/models` gets it appended.
  """
  def models_url(url) when is_binary(url) do
    trimmed = String.trim_trailing(String.trim(url), "/")
    if String.ends_with?(trimmed, "/models"), do: trimmed, else: trimmed <> "/models"
  end

  defp http_get_json(url, timeout) do
    req_opts =
      [
        url: url,
        method: :get,
        receive_timeout: timeout,
        # Idempotent, but ONE retry only — this runs hourly against a single
        # shared box; three retries per tick buys nothing.
        retry: :transient,
        max_retries: 1
      ]
      |> Keyword.merge(Application.get_env(:orca_hub, :pi_model_sync_req_options, []))

    case Req.request(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "#{url} returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "#{url} unreachable: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "#{url} raised: #{Exception.message(e)}"}
  end

  # -------------------------------------------------------------------
  # Persistence
  # -------------------------------------------------------------------

  defp write(entry, new_spec, opts) do
    if comparable(new_spec) == comparable(entry.spec) do
      # Rule 4: no broadcast — this must not fan a no-op sync out to every
      # node, because a models.json write evicts warm pi ports cluster-wide.
      record(entry, %{models_refresh_error: nil, models_refreshed_at: now(opts)})
      {:ok, :unchanged}
    else
      attrs = %{
        spec: new_spec,
        models_refresh_error: nil,
        models_refreshed_at: now(opts)
      }

      case PiConfig.update_entry(entry, attrs) do
        {:ok, updated} ->
          Logger.info(
            "PiModelSync: provider #{entry.name} models -> " <>
              Enum.map_join(updated.spec["models"], ", ", & &1["id"])
          )

          {:ok, :updated}

        {:error, changeset} ->
          reason = "write rejected: #{inspect(changeset.errors)}"
          record(entry, %{models_refresh_error: reason})
          {:error, reason}
      end
    end
  end

  # Ids sorted on both sides so a stored list in a different order is not
  # mistaken for a change (rule 4).
  defp comparable(spec) do
    case spec["models"] do
      models when is_list(models) ->
        Map.put(spec, "models", Enum.sort_by(models, &to_string(is_map(&1) && &1["id"])))

      _ ->
        spec
    end
  end

  defp record(entry, attrs) do
    attrs = Map.put_new(attrs, :models_refreshed_at, entry.models_refreshed_at)
    PiConfig.record_models_refresh(entry, attrs)
  rescue
    # The row may have been deleted between the fetch and the write — never
    # let bookkeeping take down a refresh pass.
    e -> Logger.warning("PiModelSync: could not record refresh state: #{Exception.message(e)}")
  end

  defp now(opts) do
    Keyword.get_lazy(opts, :now, fn ->
      NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    end)
  end

  # -------------------------------------------------------------------
  # GenServer plumbing
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    if enabled?() do
      Process.send_after(self(), :tick, @boot_delay_ms)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval_ms)
    run_pass()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:refresh_all, _from, state), do: {:reply, run_pass(), state}

  defp run_pass do
    refresh_all()
  rescue
    e ->
      Logger.warning("PiModelSync: refresh pass failed: " <> Exception.message(e))
      []
  catch
    kind, reason ->
      Logger.warning("PiModelSync: refresh pass crashed: #{inspect({kind, reason})}")
      []
  end
end
