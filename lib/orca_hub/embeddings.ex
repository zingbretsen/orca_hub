defmodule OrcaHub.Embeddings do
  @moduledoc """
  Hub-only HTTP client for the local embedding endpoint (an
  OpenAI-compatible `POST /v1/embeddings`, served by the gb10 box), backing
  pgvector-based issue search.

  Structure is deliberately copied from `OrcaHub.MemoryClient`: every public
  function is a thin wrapper routing through `OrcaHub.HubRPC` (see the
  `embeddings_*` functions there) so only the hub ever needs
  `EMBEDDING_URL` configured and a call from an agent node transparently
  executes on the hub. The `_impl` functions are the actual hub-side HTTP
  calls; they are `def` (not `defp`) only because `HubRPC` reaches them via
  `apply/3`/`:erpc`, which cannot target a private function — callers should
  use the wrapper.

  Never raises to callers: every function returns `{:ok, term} | {:error,
  reason}`, with `{:error, :disabled}` when `EMBEDDING_URL` is unset. That
  matters more here than it looks: a chunk row is allowed to exist with a
  NULL `embedding` (see `OrcaHub.Issues.IssueChunk`), so "the embedder is
  down" must degrade indexing, never fail it.

  ## Endpoint facts (verified live 2026-09-14)

  - Model `qwen3-embedding-0.6b`, **1024 dims**.
  - `input` accepts a STRING or a LIST of strings; a list response carries
    an `"index"` per element, which `embed_many/1` sorts by rather than
    trusting arrival order.
  - Server `n_ctx` is **8192 tokens**, enforced PER INPUT, not per batch —
    a 40-element batch totalling ~9.7k tokens is fine. An input over the
    limit is a hard HTTP 400 (`exceed_context_size_error`), NOT a silent
    truncation, which is why `OrcaHub.Issues.Chunker` exists.
  - No auth header is required.

  ## Retry policy

  Following `MemoryClient.default_retry_opts/1`'s reasoning: an embedding
  request IS idempotent (unlike `remember`, a retry can't create a
  duplicate), so a transient retry is allowed — but capped at ONE, not
  Req's default 3. This endpoint is a single small GPU box, and repeating a
  slow request against an already-saturated server is precisely what
  amplified the 2026-09-11 memory-service OOMKill. A retry storm here would
  do the same thing to the shared LLM host every other project depends on.
  """

  require Logger

  alias OrcaHub.HubRPC

  @timeout 60_000

  # Batch cap. 40 inputs / ~9.7k total tokens was verified working, so this
  # is not a server limit — it bounds request size and blast radius so one
  # failed call re-does at most this many embeddings.
  @max_batch 32

  @default_model "qwen3-embedding-0.6b"
  @default_dims 1024

  @doc "Whether the embedding integration is configured (`EMBEDDING_URL` set)."
  def enabled?, do: HubRPC.embeddings_enabled?()

  @doc """
  The configured embedding model name — stamp this into
  `IssueChunk.embedding_model` alongside a stored vector. Read from the HUB's
  config, not the calling node's.
  """
  def model, do: HubRPC.embeddings_model()

  @doc """
  The configured embedding dimension. Must match `issue_chunks.embedding`'s
  `vector(1024)` column type; `embed/1`/`embed_many/1` reject a response
  that disagrees rather than letting the DB insert fail cryptically later.
  """
  def dims, do: HubRPC.embeddings_dims()

  @doc """
  Embeds one string. Returns `{:ok, [float]}` (length `dims/0`).

  `{:error, :disabled}` when unconfigured, `{:error, :empty_input}` for a
  blank string, `{:error, {:http_error, 400, _}}` for an input over the
  server's 8192-token context (chunk first — see
  `OrcaHub.Issues.Chunker`), `{:error, {:dimension_mismatch, got,
  expected}}` if the endpoint returns an unexpected width.
  """
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text), do: HubRPC.embeddings_embed(text)

  @doc """
  Embeds a list of strings in one (or, past #{@max_batch}, several)
  request(s). Returns `{:ok, [[float]]}` in the SAME ORDER as the input.

  `{:ok, []}` for an empty list, without touching the network. A blank
  string anywhere in the list is `{:error, :empty_input}` — the caller's
  positional mapping back onto chunks would otherwise silently skew, so
  this refuses rather than dropping an element. Any failing sub-batch fails
  the whole call; there is no partial result.
  """
  @spec embed_many([String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed_many(texts), do: HubRPC.embeddings_embed_many(texts)

  # -------------------------------------------------------------------
  # Hub-side implementation (invoked only via HubRPC.call/3's apply/:erpc —
  # see moduledoc)
  # -------------------------------------------------------------------

  def enabled_impl? do
    is_binary(base_url()) and base_url() != ""
  end

  def model_impl, do: Application.get_env(:orca_hub, :embedding_model) || @default_model

  def dims_impl, do: Application.get_env(:orca_hub, :embedding_dims) || @default_dims

  def embed_impl(text) when is_binary(text) do
    case embed_many_impl([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  def embed_impl(other), do: {:error, {:invalid_input, other}}

  def embed_many_impl([]), do: {:ok, []}

  def embed_many_impl(texts) when is_list(texts) do
    cond do
      not Enum.all?(texts, &is_binary/1) -> {:error, {:invalid_input, :not_all_strings}}
      Enum.any?(texts, &(String.trim(&1) == "")) -> {:error, :empty_input}
      not enabled_impl?() -> {:error, :disabled}
      true -> batched_embed(texts)
    end
  end

  def embed_many_impl(other), do: {:error, {:invalid_input, other}}

  defp batched_embed(texts) do
    texts
    |> Enum.chunk_every(@max_batch)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case request_embeddings(batch) do
        {:ok, vectors} -> {:cont, {:ok, acc ++ vectors}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp request_embeddings(batch) do
    body = %{"model" => model_impl(), "input" => batch}

    case do_request("/v1/embeddings", body) do
      {:ok, %{"data" => data}} when is_list(data) -> decode_data(data, length(batch))
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The response carries an "index" per element; sort by it rather than
  # trusting arrival order, since a caller maps the result positionally back
  # onto its chunks and a silent reorder would attach vectors to the wrong
  # text.
  defp decode_data(data, expected_count) do
    vectors =
      data
      |> Enum.sort_by(fn item -> item["index"] || 0 end)
      |> Enum.map(fn item -> item["embedding"] end)

    expected_dims = dims_impl()

    cond do
      length(vectors) != expected_count ->
        {:error, {:count_mismatch, length(vectors), expected_count}}

      not Enum.all?(vectors, &is_list/1) ->
        {:error, {:unexpected_response, :missing_embedding}}

      Enum.find(vectors, &(length(&1) != expected_dims)) ->
        got = vectors |> Enum.find(&(length(&1) != expected_dims)) |> length()
        {:error, {:dimension_mismatch, got, expected_dims}}

      true ->
        {:ok, vectors}
    end
  end

  defp do_request(path, body) do
    req_opts =
      [
        method: :post,
        url: base_url() <> path,
        json: body,
        receive_timeout: @timeout,
        # See the moduledoc's retry-policy note: idempotent, so retrying is
        # safe, but ONE retry only — never Req's default 3 against a single
        # shared GPU box.
        retry: :transient,
        max_retries: 1
      ]
      |> Keyword.merge(req_options())

    case Req.request(req_opts) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp base_url do
    case Application.get_env(:orca_hub, :embedding_url) do
      nil -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  defp req_options, do: Application.get_env(:orca_hub, :embedding_req_options, [])
end
