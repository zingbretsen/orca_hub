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

  @doc "POST /v1/memories/merge. `attrs` carries `text`/`kind`/etc. for the merged memory."
  def merge(source_ids, attrs), do: HubRPC.memory_merge(source_ids, attrs)

  @doc "GET /v1/memories (listing/maintenance query)."
  def list(params \\ %{}), do: HubRPC.memory_list(params)

  @doc """
  POST /v1/memories/context. Always returns `{:ok, block_or_nil}` — never
  `{:error, _}` — because this sits on the session-spawn path and a
  memory-service outage must never block a spawn. `opts` may include
  `:budget_tokens` (default 3000), `:include_global` (default true),
  `:include_shared` (default true).
  """
  @spec context_block(String.t(), String.t() | nil, keyword()) :: {:ok, String.t() | nil}
  def context_block(project_slug, prompt, opts \\ []),
    do: HubRPC.memory_context_block(project_slug, prompt, opts)

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

  def merge_impl(source_ids, attrs) do
    body = Map.put(attrs, "source_ids", source_ids)
    with_enabled(fn -> do_request(:post, "/v1/memories/merge", json: body) end)
  end

  def list_impl(params) do
    with_enabled(fn -> do_request(:get, "/v1/memories", params: params) end)
  end

  def context_block_impl(project_slug, prompt, opts) do
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
        {:ok, %{"block" => block}} -> {:ok, block}
        {:ok, _other} -> {:ok, nil}
        {:error, reason} -> log_context_failure(reason)
      end
    else
      {:ok, nil}
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

    req_opts =
      [headers: headers, receive_timeout: @timeout] ++ opts ++ req_options()

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
