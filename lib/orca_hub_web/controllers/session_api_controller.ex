defmodule OrcaHubWeb.SessionApiController do
  @moduledoc """
  Read-only session listing/lookup/tail for external HTTP clients
  (docs/api.md) — the consumers are the unified Android app (phone + Wear +
  Android Auto) and its Wear OS predecessor. Sits behind the same
  `:api_authed` pipeline as the Agent Runs API (`sessions:read` scope on a
  scoped token, or the legacy static bearer); no new auth mechanism.

  Deliberately thin: all querying is done by `OrcaHub.Sessions` via
  `OrcaHub.HubRPC` (`list_sessions/1`, `activity_metadata/1`,
  `session_tail/2`) — this module only filters, orders and projects the
  result down to the compact fields a battery/bandwidth-constrained client
  needs (see `render_session/3`), it never reimplements the queries itself.

  ## `last_activity_at` is message-derived, never `updated_at`

  Every projection here takes `last_activity_at` from
  `Sessions.activity_metadata/1` (`max(messages.inserted_at)` per session,
  two grouped queries for a whole page, every requested id present). The
  session row's `updated_at` is NOT that signal — it moves on any write at
  all: a progress-phase update, an archive flag, a node reassignment. A
  client sorting "what just finished" by row mtime gets sessions that no
  agent has said anything in for hours. `nil` (a session with no messages
  yet) is a legitimate value and sorts LAST.
  """

  use OrcaHubWeb, :controller

  alias OrcaHub.HubRPC

  # Pure helpers only (excerpt normalization/truncation) — every DB read goes
  # through HubRPC, since an agent node has no local Repo.
  alias OrcaHub.Sessions

  # /recent is the small-surface feed (watch tile, Auto list) — a short
  # default and a hard ceiling. /sessions is the older full-list endpoint,
  # which was unbounded until pagination was added, so its default is high
  # enough that existing callers see no change at today's row counts.
  @recent_default_limit 20
  @recent_max_limit 100
  @index_default_limit 100
  @index_max_limit 500

  # `include_tail`'s excerpt budget. ~400 chars is a notification body / a
  # watch screen, not a transcript — the full text is one /tail away. The
  # CUT ITSELF is `Sessions.truncate_excerpt/2`, shared with the Gotify push
  # payload (`OrcaHub.Notify`): a notification and the list row it opens must
  # not disagree about where the text stops.
  @tail_excerpt_chars 400

  @default_tool_call_limit 10
  @max_tool_call_limit 50

  # ---------------------------------------------------------------------
  # GET /api/v1/sessions
  # ---------------------------------------------------------------------

  # list_sessions/1's `:all` filter is the base query (non-archived, a
  # nil-or-non-deleted project, and `kind == "session"` so background kinds
  # like memory_extraction stay out) — status/project_id are applied here
  # rather than added as new filter atoms on that shared context function,
  # since they're specific to this compact projection, not a general
  # session-list concern.
  def index(conn, params) do
    with {:ok, limit} <- parse_limit(params, @index_default_limit, @index_max_limit),
         {:ok, offset} <- parse_offset(params) do
      {page, total} =
        conn
        |> base_page()
        |> paginate(limit, offset)

      json(conn, %{
        sessions: Enum.map(page, fn {s, activity} -> render_session(s, activity, false) end),
        total: total,
        limit: limit,
        offset: offset,
        has_more: offset + length(page) < total
      })
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  # ---------------------------------------------------------------------
  # GET /api/v1/sessions/recent
  # ---------------------------------------------------------------------

  def recent(conn, params) do
    with {:ok, limit} <- parse_limit(params, @recent_default_limit, @recent_max_limit),
         {:ok, offset} <- parse_offset(params),
         {:ok, since} <- parse_since(params) do
      {page, total} =
        conn
        |> base_page()
        |> filter_by_since(since)
        |> paginate(limit, offset)

      include_tail? = truthy?(params["include_tail"])

      json(conn, %{
        sessions:
          Enum.map(page, fn {s, activity} -> render_session(s, activity, include_tail?) end),
        fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        total: total,
        limit: limit,
        offset: offset,
        has_more: offset + length(page) < total
      })
    else
      {:error, message} -> bad_request(conn, message)
    end
  end

  # The shared body of /sessions and /sessions/recent: the same filtered,
  # activity-annotated, deterministically ordered list. Both endpoints hand a
  # client the SAME item shape (/recent just adds the tail fields) so the app
  # carries one model, not two.
  defp base_page(conn) do
    HubRPC.list_sessions(:all)
    |> filter_by_statuses(status_filters(conn))
    |> filter_by_project_id(conn.params["project_id"])
    |> annotate_activity()
    |> Enum.sort(&activity_order/2)
  end

  defp annotate_activity([]), do: []

  defp annotate_activity(sessions) do
    activity = sessions |> Enum.map(& &1.id) |> HubRPC.activity_metadata()
    Enum.map(sessions, &{&1, get_in(activity, [&1.id, :last_activity_at])})
  end

  # Ordering guarantee: last_activity_at DESC, nulls LAST, ties broken on id
  # ASC. The tiebreak is what makes limit/offset paging stable — without it
  # two sessions sharing a timestamp (or the whole no-messages tail, which is
  # every id at once) could swap places between two pages of one scan.
  defp activity_order({session_a, a}, {session_b, b}) do
    case {a, b} do
      {nil, nil} -> session_a.id <= session_b.id
      {nil, _} -> false
      {_, nil} -> true
      {a, b} -> compare_activity(a, b, session_a, session_b)
    end
  end

  defp compare_activity(a, b, session_a, session_b) do
    case NaiveDateTime.compare(a, b) do
      :gt -> true
      :lt -> false
      :eq -> session_a.id <= session_b.id
    end
  end

  defp paginate(pairs, limit, offset) do
    {Enum.slice(pairs, offset, limit), length(pairs)}
  end

  # ---------------------------------------------------------------------
  # Filters
  # ---------------------------------------------------------------------

  defp filter_by_statuses(sessions, []), do: sessions

  defp filter_by_statuses(sessions, statuses),
    do: Enum.filter(sessions, &(&1.status in statuses))

  defp filter_by_project_id(sessions, nil), do: sessions
  defp filter_by_project_id(sessions, ""), do: sessions

  defp filter_by_project_id(sessions, project_id),
    do: Enum.filter(sessions, &(&1.project_id == project_id))

  # `since` means MESSAGE activity strictly after the instant, so a session
  # with no messages at all (nil) is never "recently active".
  defp filter_by_since(pairs, nil), do: pairs

  defp filter_by_since(pairs, since) do
    Enum.filter(pairs, fn
      {_session, nil} -> false
      {_session, activity} -> NaiveDateTime.compare(activity, since) == :gt
    end)
  end

  # `?status=idle&status=error` — Plug's query decoder keeps only the LAST
  # value for a repeated bare key, so the repeats are read straight off the
  # raw query string. `status[]=…` (which does decode to a list) and a
  # comma-separated `status=idle,error` are accepted too; all three forms are
  # unioned, so a single `?status=running` behaves exactly as it always has.
  defp status_filters(conn) do
    (query_values(conn, "status") ++ List.wrap(conn.params["status"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp query_values(%{query_string: query}, key) when is_binary(query) do
    query
    |> URI.query_decoder()
    |> Enum.filter(fn {k, _v} -> k == key or k == key <> "[]" end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp query_values(_conn, _key), do: []

  # ---------------------------------------------------------------------
  # GET /api/v1/sessions/:id
  # ---------------------------------------------------------------------

  # Same posture as ApiRunController.show/2: a malformed id and a
  # well-formed-but-nonexistent id both just mean "no such session" — never
  # let a bad UUID reach Ecto and surface as a raw CastError (see CLAUDE.md's
  # "Common issues" — this failure mode has bitten the codebase before).
  def show(conn, %{"id" => id}) do
    case lookup_session(id) do
      nil ->
        not_found(conn)

      session ->
        activity = get_in(HubRPC.activity_metadata([session.id]), [session.id, :last_activity_at])
        json(conn, render_session(session, activity, false))
    end
  end

  # ---------------------------------------------------------------------
  # GET /api/v1/sessions/:id/tail
  # ---------------------------------------------------------------------

  def tail(conn, %{"id" => id} = params) do
    with session when not is_nil(session) <- lookup_session(id),
         {:ok, limit} <- parse_tool_call_limit(params) do
      tail = HubRPC.session_tail(session.id, tool_call_limit: limit)

      json(conn, %{
        session_id: session.id,
        last_assistant_text: tail.last_assistant_text,
        recent_tool_calls: tail.recent_tool_calls,
        # `tool_calls_truncated?` in Elixir; the trailing `?` is dropped for
        # the wire so clients get an ordinary JSON identifier.
        tool_calls_truncated: tail.tool_calls_truncated?,
        tool_calls_total: Map.get(tail, :tool_calls_total, length(tail.recent_tool_calls))
      })
    else
      {:error, message} -> bad_request(conn, message)
      _ -> not_found(conn)
    end
  end

  # A session is looked up by id even when it's archived or of a background
  # kind — a client holding an id from a push notification must still be able
  # to resolve it after the session is archived. Only a genuinely absent (or
  # unparseable) id is a 404. Shared by show/2 and tail/2 so the two can't
  # drift.
  defp lookup_session(id) do
    case Ecto.UUID.cast(id) do
      :error -> nil
      {:ok, _} -> HubRPC.get_session(id)
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "session not found"})
  defp bad_request(conn, message), do: conn |> put_status(400) |> json(%{error: message})

  # ---------------------------------------------------------------------
  # Param parsing
  # ---------------------------------------------------------------------

  # Over-max is CLAMPED rather than rejected (a client asking for more than
  # the ceiling still gets a useful page); only a non-integer or a
  # non-positive limit is an error, since those signal a broken caller.
  defp parse_limit(params, default, max) do
    case params["limit"] do
      nil -> {:ok, default}
      "" -> {:ok, default}
      value -> parse_positive_int(value, max, "invalid limit")
    end
  end

  defp parse_offset(params) do
    case params["offset"] do
      nil ->
        {:ok, 0}

      "" ->
        {:ok, 0}

      value ->
        case parse_int(value) do
          {:ok, n} when n >= 0 -> {:ok, n}
          _ -> {:error, "invalid offset"}
        end
    end
  end

  defp parse_tool_call_limit(params) do
    case params["tool_call_limit"] do
      nil -> {:ok, @default_tool_call_limit}
      "" -> {:ok, @default_tool_call_limit}
      value -> parse_positive_int(value, @max_tool_call_limit, "invalid tool_call_limit")
    end
  end

  defp parse_positive_int(value, max, error) do
    case parse_int(value) do
      {:ok, n} when n > 0 -> {:ok, min(n, max)}
      _ -> {:error, error}
    end
  end

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_value), do: :error

  # Accepts a full ISO 8601 instant (`2026-09-19T12:00:00Z`, any offset) or a
  # naive one, and normalizes to naive UTC — the frame `messages.inserted_at`
  # is stored in, which is what `last_activity_at` is compared against.
  defp parse_since(params) do
    case params["since"] do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> cast_since(value)
      _ -> {:error, "invalid since"}
    end
  end

  defp cast_since(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, naive}
          _ -> {:error, "invalid since"}
        end
    end
  end

  defp truthy?(value) when is_binary(value), do: String.downcase(value) in ~w(true 1 yes)
  defp truthy?(true), do: true
  defp truthy?(_value), do: false

  # ---------------------------------------------------------------------
  # Response shaping — compact projection, not the full session struct
  # ---------------------------------------------------------------------

  defp render_session(session, last_activity_at, include_tail?) do
    base = %{
      id: session.id,
      status: session.status,
      title: session.title,
      progress_phase: session.progress_phase,
      progress_note: session.progress_note,
      last_activity_at: iso8601(last_activity_at),
      directory: session.directory,
      project_id: session.project_id,
      project_name: session.project && session.project.name
    }

    if include_tail?, do: Map.merge(base, tail_excerpt(session.id)), else: base
  end

  # Only the excerpt is wanted here, so the tool-call half of session_tail/2
  # is asked for at limit 1 and discarded — /sessions/:id/tail is the
  # endpoint for tool calls.
  defp tail_excerpt(session_id) do
    %{last_assistant_text: text} = HubRPC.session_tail(session_id, tool_call_limit: 1)

    %{
      last_assistant_text: Sessions.truncate_excerpt(text, @tail_excerpt_chars),
      last_assistant_text_truncated: truncated?(text, @tail_excerpt_chars)
    }
  end

  # Measured on the NORMALIZED text, not the raw one: collapsing a run of
  # newlines is not a truncation, so a reply that only shrank because of
  # whitespace must not claim it was cut.
  defp truncated?(nil, _max), do: false

  defp truncated?(text, max), do: String.length(Sessions.normalize_excerpt(text)) > max

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = naive),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
