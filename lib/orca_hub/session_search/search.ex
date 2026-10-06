defmodule OrcaHub.SessionSearch.Search do
  @moduledoc """
  Full-text + semantic search over session conversation text, one result per
  session (ORCAHUB3-137, read half).

  The text lives in Elasticsearch behind memory-service; this module calls
  `OrcaHub.MemoryClient.search_session_messages/1` (hub-routed), then joins the
  returned `group_id`s (= session ids) to `sessions` rows in ONE Postgres query.

  Filters the index knows about (`:project_id`, `:directory`, `:backend`,
  `:node`, `:role`, `:since`, `:until`) are pushed down to the service. Filters
  only Postgres knows (`:status`, archived state, `:kind`) are applied after the
  join, so the service is asked for more groups than `:limit` (oversampling) so
  a page still fills. Ids with no `sessions` row (deleted sessions not yet
  purged from the index) are dropped.

  Returns `{:ok, %{results: [result], degraded: nil | String.t()}}` or
  `{:error, reason}` — never raises. `{:error, :disabled}` means memory-service
  isn't configured. `degraded: "bm25_only"` means the query embedding failed and
  results are keyword-only.

  Each result is `%{session: %Session{}, score: float, legs: [String.t()],
  snippets: [%{message_id, role, inserted_at, text}]}`. `snippet.text` is PLAIN
  TEXT whose matches are wrapped in STX (U+0002) / ETX (U+0003); renderers must
  HTML-escape the whole string first, then call `highlight_html/1` or
  `highlight_plain/2` here. Never feed it to `raw/1` directly.
  """

  import Ecto.Query

  alias OrcaHub.{Repo, Sessions.Session}

  @stx <<2>>
  @etx <<3>>
  @default_limit 10
  @max_service_limit 100
  @oversample 3

  @doc """
  Options: `:limit` (default #{@default_limit}), `:snippets` (default 3),
  `:project_id`, `:directory`, `:backend`, `:node`, `:role`, `:since`,
  `:until` (DateTime or ISO-8601 string), and the Postgres-side `:status`,
  `:include_archived`, `:archived_only`, `:include_background`, `:session_ids`
  (restrict to these sessions; also pushed down as `group_ids`).
  """
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) do
    opts = Map.new(opts)
    limit = opts[:limit] || @default_limit

    if String.trim(query) == "" do
      {:ok, %{results: [], degraded: nil}}
    else
      params = %{
        "query" => query,
        "limit" => service_limit(limit, opts),
        "snippets" => opts[:snippets] || 3,
        "filters" => filters(opts)
      }

      case safe_call(params) do
        {:ok, %{"results" => results} = body} when is_list(results) ->
          {:ok, %{results: to_results(results, opts, limit), degraded: body["degraded"]}}

        {:ok, other} ->
          {:error, {:unexpected_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def search(_query, _opts), do: {:error, :invalid_query}

  @doc "Human-readable text for an `{:error, reason}` from `search/2`."
  def error_message(:disabled), do: "Session search is not configured (memory-service disabled)."
  def error_message(:invalid_query), do: "Search query must be a string."

  def error_message(reason),
    do: "Session search is unavailable right now: #{inspect(reason, limit: 5)}"

  @doc """
  Whole-string HTML escape FIRST, then STX/ETX -> `<mark>`/`</mark>`. Returns
  safe iodata-free binary suitable for `Phoenix.HTML.raw/1`; this is the only
  sanctioned way to render a highlight.
  """
  def highlight_html(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(@stx, "<mark>")
    |> String.replace(@etx, "</mark>")
  end

  def highlight_html(_), do: ""

  @doc "Replaces markers with `open`/`close` strings (plain text output, e.g. `**`)."
  def highlight_plain(text, {open, close} \\ {"**", "**"}) when is_binary(text) do
    text
    |> String.replace(@stx, open)
    |> String.replace(@etx, close)
  end

  # ── internals ────────────────────────────────────────────────────────

  defp client, do: Application.get_env(:orca_hub, :session_search_client, OrcaHub.MemoryClient)

  defp safe_call(params) do
    case client().search_session_messages(params) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp post_filtered?(opts) do
    opts[:status] != nil or opts[:archived_only] == true or opts[:include_archived] != true or
      opts[:include_background] != true
  end

  # Archived and background sessions are hidden by default, so a post-filter is
  # nearly always active; oversample whenever one is.
  defp service_limit(limit, opts) do
    wanted = if post_filtered?(opts), do: limit * @oversample, else: limit
    wanted |> max(limit) |> min(@max_service_limit)
  end

  defp filters(opts) do
    %{
      "role" => opts[:role],
      "backend" => opts[:backend],
      "node" => opts[:node],
      "project_id" => opts[:project_id],
      "directory" => opts[:directory],
      "group_ids" => opts[:session_ids],
      "since" => iso(opts[:since]),
      "until" => iso(opts[:until])
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp iso(s) when is_binary(s), do: s

  defp to_results(results, opts, limit) do
    ids =
      results
      |> Enum.map(& &1["group_id"])
      |> Enum.flat_map(fn id ->
        case is_binary(id) && Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          _ -> []
        end
      end)

    sessions =
      from(s in Session, where: s.id in ^ids, preload: [:project])
      |> post_filter(opts)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    results
    |> Enum.flat_map(fn r ->
      with id when is_binary(id) <- r["group_id"],
           {:ok, uuid} <- Ecto.UUID.cast(id),
           %Session{} = session <- sessions[uuid] do
        [
          %{
            session: session,
            score: r["score"],
            legs: r["legs"] || [],
            snippets: snippets(r["hits"] || [])
          }
        ]
      else
        _ -> []
      end
    end)
    |> Enum.take(limit)
  end

  defp post_filter(q, opts) do
    q
    |> then(fn q ->
      cond do
        opts[:archived_only] -> where(q, [s], not is_nil(s.archived_at))
        opts[:include_archived] -> q
        true -> where(q, [s], is_nil(s.archived_at))
      end
    end)
    |> then(fn q ->
      if opts[:include_background], do: q, else: where(q, [s], s.kind == "session")
    end)
    |> then(fn q ->
      case opts[:status] do
        nil -> q
        status -> where(q, [s], s.status == ^status)
      end
    end)
  end

  defp snippets(hits) do
    Enum.map(hits, fn hit ->
      text =
        case hit["highlights"] do
          [first | _] when is_binary(first) -> first
          _ -> hit["text"] || ""
        end

      %{
        message_id: hit["id"],
        role: get_in(hit, ["fields", "role"]),
        inserted_at: get_in(hit, ["fields", "inserted_at"]),
        text: text
      }
    end)
  end
end
