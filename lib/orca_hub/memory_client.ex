defmodule OrcaHub.MemoryClient do
  @moduledoc """
  Hub-only HTTP client for the external `memory-service` (agent-memory
  centralization). Zach doesn't want to distribute a memory-service token to
  every agent node, so — exactly like `OrcaHub.Notify`'s Gotify creds —
  only the hub needs `MEMORY_SERVICE_URL`/`MEMORY_SERVICE_TOKEN` configured.

  Every public function here is a thin wrapper that routes through
  `OrcaHub.HubRPC` (see `memory_*` there) so a call made from an agent
  node's MCP tool or backend adapter transparently executes on the hub —
  the same pattern as the cross-node file store (`OrcaHub.Files`,
  `OrcaHub.MCP.Tools.Files`). The `_impl` functions below are the actual
  hub-side HTTP calls; they are `def` (not `defp`) only because `HubRPC`
  reaches them via `apply/3`/`:erpc`, which cannot target a private
  function — callers should use the wrapper, not the `_impl` directly.

  Never raises to callers: every function returns `{:ok, term} | {:error,
  reason}`, and `{:error, :disabled}` when `MEMORY_SERVICE_URL`/
  `MEMORY_SERVICE_TOKEN` aren't both configured. `context_block/3` is the
  one exception — it sits on the session-spawn path, so a memory-service
  outage must never block a spawn: it always returns `{:ok, block_or_nil}`,
  collapsing disabled/timeout/5xx/decode-error alike into `{:ok, nil}`.
  """

  require Logger

  alias OrcaHub.HubRPC

  @timeout 10_000

  @doc "Whether the memory-service integration is configured (URL + token both set)."
  def enabled?, do: HubRPC.memory_enabled?()

  @doc "POST /v1/memories. `attrs` is the memory document (string or atom keys)."
  def remember(attrs), do: HubRPC.memory_remember(attrs)

  @doc "POST /v1/memories/search."
  def search(params), do: HubRPC.memory_search(params)

  @doc "GET /v1/memories/:id."
  def get(id), do: HubRPC.memory_get(id)

  @doc "PATCH /v1/memories/:id."
  def update(id, attrs), do: HubRPC.memory_update(id, attrs)

  @doc "POST /v1/memories/:id/retire. `opts` may include `:superseded_by`."
  def retire(id, reason, opts \\ []), do: HubRPC.memory_retire(id, reason, opts)

  @doc "POST /v1/memories/:id/verify."
  def verify(id), do: HubRPC.memory_verify(id)

  @doc "POST /v1/memories/verify (batch). `ids` is a non-empty list of memory ids."
  def verify_batch(ids), do: HubRPC.memory_verify_batch(ids)

  @doc """
  Re-queues a memory for human review without touching its text. Tries
  `PATCH /v1/memories/:id` with `review_status: "pending"` + `review_note:
  reason` first; if the service doesn't support that yet (HTTP 422), falls
  back to reading the memory's current `tags` and PATCHing them with
  `"needs-review"` appended, logging once. Either way the returned map
  carries `"mechanism"` — `"review_status"` or `"tags_fallback"` — saying
  which path was taken.
  """
  def flag(id, reason), do: HubRPC.memory_flag(id, reason)

  @doc "POST /v1/memories/merge. `attrs` carries `text`/`kind`/etc. for the merged memory."
  def merge(source_ids, attrs), do: HubRPC.memory_merge(source_ids, attrs)

  @doc """
  GET /v1/memories/duplicates — the service's own similarity-scored
  duplicate grouping, `params` typically carrying `project_slug`/
  `threshold`/`limit`. Returns `{:ok, %{"groups" => [%{"memories" => [...],
  "max_score" => float}]}}` on success; an ordinary `{:error, reason}` like
  every other function here (including a 404, if a given service build
  doesn't have this endpoint yet) — never raises.
  """
  def duplicates(params \\ %{}), do: HubRPC.memory_duplicates(params)

  @doc "GET /v1/memories (listing/maintenance query)."
  def list(params \\ %{}), do: HubRPC.memory_list(params)

  @doc """
  GET /v1/tags. `params` typically carries `"project_slug"`. Returns
  `{:ok, [%{"tag" => ..., "count" => ...}]}` on success. The memory service
  may not implement this endpoint yet — any error (404 included) comes back
  as an ordinary `{:error, reason}` like every other function here, never
  raises; callers that want a tag list to be optional (`OrcaHub.MemoryExtraction`)
  degrade that to omitting it rather than failing.
  """
  def tags(params \\ %{}), do: HubRPC.memory_tags(params)

  @doc """
  POST /v1/memories/context, returning the FULL response — `"block"` plus
  `"memory_ids"`/`"pinned_count"`/`"recalled_count"` — or `{:ok, nil}`.
  Same never-raise / always-`{:ok, _}` contract as `context_block/3` (which
  is now a thin wrapper around this) — this sits on the session-spawn path
  and a memory-service outage must never block a spawn. `opts` may include
  `:budget_tokens` (default 3000), `:include_global` (default true),
  `:include_shared` (default true).
  """
  @spec context(String.t(), String.t() | nil, keyword()) :: {:ok, map() | nil}
  def context(project_slug, prompt, opts \\ []),
    do: HubRPC.memory_context(project_slug, prompt, opts)

  @doc """
  Merges two `GET /v1/memories` queries into the memories THIS session
  created — directly (`session_id == session_id`) and via extraction
  (`source.session_id == session_id`, filtered client-side the same way
  `OrcaHub.MemoryExtraction.extracted_memories/1` already does — extraction's
  own `session_id` field is the extraction CHILD session, not the session
  under review, so the direct query alone misses these). Deduped by `id`,
  capped at 50 with `truncated: true` when more existed. Never raises;
  `{:error, reason}` from EITHER leg fails the whole call rather than
  silently returning a partial list.
  """
  @spec list_created_by_session(String.t(), String.t()) ::
          {:ok, %{memories: [map()], truncated: boolean()}} | {:error, term()}
  def list_created_by_session(session_id, project_slug),
    do: HubRPC.memory_list_created_by_session(session_id, project_slug)

  @doc """
  POST /v1/memories/context, returning just the block text. Always returns
  `{:ok, block_or_nil}` — never `{:error, _}` — same reasoning as
  `context/3`, which does the actual work here.
  """
  @spec context_block(String.t(), String.t() | nil, keyword()) :: {:ok, String.t() | nil}
  def context_block(project_slug, prompt, opts \\ []) do
    case context(project_slug, prompt, opts) do
      {:ok, %{"block" => block}} -> {:ok, block}
      {:ok, _nil_or_other} -> {:ok, nil}
    end
  end

  # -------------------------------------------------------------------
  # Hub-side implementation (invoked only via HubRPC.call/3's apply/:erpc —
  # see moduledoc)
  # -------------------------------------------------------------------

  def enabled_impl? do
    is_binary(base_url()) and base_url() != "" and is_binary(token()) and token() != ""
  end

  def remember_impl(attrs) do
    with_enabled(fn -> do_request(:post, "/v1/memories", json: attrs) end)
  end

  def search_impl(params) do
    with_enabled(fn -> do_request(:post, "/v1/memories/search", json: params) end)
  end

  def get_impl(id) do
    with_enabled(fn -> do_request(:get, "/v1/memories/#{id}") end)
  end

  def update_impl(id, attrs) do
    with_enabled(fn -> do_request(:patch, "/v1/memories/#{id}", json: attrs) end)
  end

  def retire_impl(id, reason, opts) do
    body =
      %{"reason" => reason}
      |> maybe_put("superseded_by", Keyword.get(opts, :superseded_by))

    with_enabled(fn -> do_request(:post, "/v1/memories/#{id}/retire", json: body) end)
  end

  def verify_impl(id) do
    with_enabled(fn -> do_request(:post, "/v1/memories/#{id}/verify", json: %{}) end)
  end

  def verify_batch_impl(ids) do
    with_enabled(fn -> do_request(:post, "/v1/memories/verify", json: %{"ids" => ids}) end)
  end

  # The service caps review_note at 500 chars and rejects a longer one —
  # truncate here so a verbose flag reason never itself triggers the
  # tags_fallback path below for a reason unrelated to service support.
  @review_note_max_chars 500

  def flag_impl(id, reason) do
    with_enabled(fn ->
      case do_request(:patch, "/v1/memories/#{id}",
             json: %{
               "review_status" => "pending",
               "review_note" => String.slice(reason, 0, @review_note_max_chars)
             }
           ) do
        {:ok, body} ->
          {:ok, tag_mechanism(body, "review_status")}

        {:error, {:http_error, 422, _body}} ->
          flag_via_tags(id, reason)

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp flag_via_tags(id, reason) do
    Logger.warning(
      "MemoryClient.flag: service rejected review_status/review_note (422) for memory " <>
        "#{id}, falling back to a \"needs-review\" tag. Reason: #{reason}"
    )

    with {:ok, memory} <- do_request(:get, "/v1/memories/#{id}") do
      tags = ((get_field(memory, "tags") || []) ++ ["needs-review"]) |> Enum.uniq()

      case do_request(:patch, "/v1/memories/#{id}", json: %{"tags" => tags}) do
        {:ok, body} -> {:ok, tag_mechanism(body, "tags_fallback")}
        {:error, _reason} = error -> error
      end
    end
  end

  defp tag_mechanism(body, mechanism) when is_map(body), do: Map.put(body, "mechanism", mechanism)
  defp tag_mechanism(body, mechanism), do: %{"result" => body, "mechanism" => mechanism}

  defp get_field(map, key) when is_map(map), do: map[key]
  defp get_field(_map, _key), do: nil

  def merge_impl(source_ids, attrs) do
    body = Map.put(attrs, "source_ids", source_ids)
    with_enabled(fn -> do_request(:post, "/v1/memories/merge", json: body) end)
  end

  # /v1/memories/duplicates does a full pairwise-cosine scan server-side
  # (see K3S3-1) and can legitimately run well past the default @timeout
  # against a large store — this is the ONE call that gets a bigger budget,
  # rather than raising @timeout for every request this client makes.
  @duplicates_timeout 120_000

  def duplicates_impl(params) do
    with_enabled(fn ->
      do_request(:get, "/v1/memories/duplicates",
        params: params,
        receive_timeout: @duplicates_timeout,
        # Req's default :safe_transient policy retries a GET on 5xx/429 too,
        # not just a timeout — exactly the window (an OOM restart, a
        # rollout) where another ~19-29s scan does the most damage. This
        # endpoint is meant to be called at most once per pass; let a
        # failure surface immediately instead of amplifying it.
        retry: false
      )
    end)
  end

  def list_impl(params) do
    with_enabled(fn -> do_request(:get, "/v1/memories", params: params) end)
  end

  @created_by_session_per_page 100
  @created_by_session_cap 50

  def list_created_by_session_impl(session_id, project_slug) do
    with {:ok, direct} <-
           list_impl(%{"session_id" => session_id, "per_page" => @created_by_session_per_page}),
         {:ok, project_memories} <-
           list_impl(%{
             "project_slug" => project_slug,
             "per_page" => @created_by_session_per_page
           }) do
      via_extraction =
        project_memories
        |> extract_memories_list()
        |> Enum.filter(fn m ->
          m["created_by"] == "extraction" and get_in(m, ["source", "session_id"]) == session_id
        end)

      merged =
        (extract_memories_list(direct) ++ via_extraction)
        |> Enum.uniq_by(& &1["id"])

      {:ok,
       %{
         memories: Enum.take(merged, @created_by_session_cap),
         truncated: length(merged) > @created_by_session_cap
       }}
    end
  end

  defp extract_memories_list(%{"memories" => memories}) when is_list(memories), do: memories
  defp extract_memories_list(memories) when is_list(memories), do: memories
  defp extract_memories_list(_), do: []

  def tags_impl(params) do
    with_enabled(fn -> do_request(:get, "/v1/tags", params: params) end)
  end

  def context_impl(project_slug, prompt, opts) do
    if enabled_impl?() do
      body =
        %{
          "project_slug" => project_slug,
          "prompt" => prompt,
          "budget_tokens" => Keyword.get(opts, :budget_tokens, 3000),
          "include_global" => Keyword.get(opts, :include_global, true),
          "include_shared" => Keyword.get(opts, :include_shared, true)
        }

      case do_request(:post, "/v1/memories/context", json: body) do
        {:ok, %{"block" => block} = resp} when is_binary(block) and block != "" ->
          {:ok,
           %{
             "block" => block,
             "memory_ids" => resp["memory_ids"] || [],
             "memories" => resp["memories"],
             "pinned_count" => resp["pinned_count"],
             "recalled_count" => resp["recalled_count"]
           }}

        {:ok, _other} ->
          {:ok, nil}

        {:error, reason} ->
          log_context_failure(reason)
      end
    else
      {:ok, nil}
    end
  end

  def context_block_impl(project_slug, prompt, opts) do
    case context_impl(project_slug, prompt, opts) do
      {:ok, %{"block" => block}} -> {:ok, block}
      {:ok, nil} -> {:ok, nil}
    end
  end

  defp log_context_failure(reason) do
    Logger.warning("MemoryClient.context_block: #{inspect(reason)} — proceeding without memory")
    {:ok, nil}
  end

  # -------------------------------------------------------------------
  # HTTP plumbing
  # -------------------------------------------------------------------

  defp with_enabled(fun) do
    if enabled_impl?(), do: fun.(), else: {:error, :disabled}
  end

  defp do_request(method, path, opts \\ []) do
    url = base_url() <> path
    headers = [{"authorization", "Bearer #{token()}"}]

    # Merged, not `++`-spliced, so a per-call `receive_timeout`/`retry` override
    # in `opts` replaces the default instead of sitting after it as a duplicate
    # keyword key. Precedence is defaults < per-call opts < app config.
    req_opts =
      [headers: headers, receive_timeout: @timeout]
      |> Keyword.merge(opts)
      |> Keyword.merge(req_options())

    case Req.request([method: method, url: url] ++ req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp base_url do
    case Application.get_env(:orca_hub, :memory_service_url) do
      nil -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  defp token, do: Application.get_env(:orca_hub, :memory_service_token)

  defp req_options, do: Application.get_env(:orca_hub, :memory_service_req_options, [])
end
