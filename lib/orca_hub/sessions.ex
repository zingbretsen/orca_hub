defmodule OrcaHub.Sessions do
  @moduledoc """
  Context for managing Claude sessions and their messages.

  ## Per-node backend/model defaults

  `create_session/1` is the single seam every session-creation path funnels
  through (LiveView forms, the command palette, MCP `start_session`,
  `TriggerExecutor`, the Discord bridge, the Agent Runs API) — always via
  `OrcaHub.HubRPC` on non-hub nodes, since the `nodes` table is hub-local.
  Before inserting, it fills in a node's configured `default_backend` /
  `default_model` (set on the node's show page) for any attrs the caller
  left blank, so e.g. the Discord bridge's node can default every session it
  spawns to `sonnet-5` without the bridge itself knowing that.

  Precedence: explicit caller value > node default > existing behavior (the
  `Session` schema's own `backend` default of `"claude"`, `model: nil`
  meaning "let the CLI pick"). A value counts as "explicit" unless it's
  missing, `nil`, or `""` — callers arrive with both atom keys (MCP/trigger/
  Discord paths) and string keys (LiveView form params).

  The backend/model pair is applied atomically: `default_model` only fires
  when the effective backend matches the backend `default_model` was
  configured for. Concretely, if the caller explicitly requests a backend
  different from the node's `default_backend` (e.g. an explicit `"codex"`
  session on a node whose default is `"claude"`/`"sonnet-5"`), the node's
  `default_model` is skipped — a Claude model default makes no sense for a
  Codex session. A node with no `runner_node` match, or a matching node with
  both defaults `nil`, leaves attrs untouched.
  """

  import Ecto.Query
  require Logger

  alias OrcaHub.{
    AgentPresence,
    ClusterNodes,
    Repo,
    Sessions.Message,
    Sessions.Session,
    Sessions.SessionInteraction
  }

  def list_sessions(filter \\ :manual) do
    query =
      from s in Session,
        left_join: p in assoc(s, :project),
        where: is_nil(s.archived_at),
        where: is_nil(s.project_id) or is_nil(p.deleted_at),
        preload: [project: p],
        order_by: [desc: s.updated_at]

    query =
      case filter do
        :all -> query
        :manual -> from s in query, where: s.triggered == false
        :automated -> from s in query, where: s.triggered == true
        :orchestrator -> from s in query, where: s.orchestrator == true
        # :heartbeat filter is handled in-memory by the LiveView since heartbeats are ephemeral
        :heartbeat -> query
      end

    Repo.all(query)
  end

  @doc """
  Non-archived sessions stuck at `status: "running"` whose `runner_node`
  matches `node_name` — candidates for `OrcaHub.SessionResumer`'s
  boot-time orphan sweep. Scoped to a single node by design (never-reassign
  rule): a node only ever resumes its own sessions.
  """
  def list_running_sessions_for_node(node_name) do
    Repo.all(
      from s in Session,
        where: is_nil(s.archived_at),
        where: s.runner_node == ^node_name,
        where: s.status == "running"
    )
  end

  @doc """
  Every session a trigger has ever spawned, newest first — INCLUDING
  archived ones, since `archive_on_complete` triggers archive their
  sessions and excluding them would usually show an empty list on the
  trigger's show page.
  """
  def list_sessions_for_trigger(trigger_id) do
    Repo.all(
      from s in Session,
        where: s.trigger_id == ^trigger_id,
        order_by: [desc: s.inserted_at, desc: s.id],
        preload: [:project]
    )
  end

  def archive_session(%Session{} = session) do
    result =
      session
      |> Session.changeset(%{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()

    with {:ok, _} <- result do
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :archived}})
      AgentPresence.remove(session.directory, session.id)
    end

    result
  end

  def unarchive_session(%Session{} = session) do
    result =
      session
      |> Session.changeset(%{archived_at: nil})
      |> Repo.update()

    with {:ok, _} <- result do
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session.id, {:status, :unarchived}})
    end

    result
  end

  def get_session!(id), do: Repo.get!(Session, id) |> Repo.preload(:project)

  def get_session(id) do
    case Repo.get(Session, id) do
      nil -> nil
      session -> Repo.preload(session, :project)
    end
  end

  def create_session(attrs) do
    %Session{}
    |> Session.changeset(apply_node_defaults(attrs))
    |> Repo.insert()
  end

  # -------------------------------------------------------------------
  # Node default resolution (see moduledoc)
  # -------------------------------------------------------------------

  defp apply_node_defaults(attrs) do
    case attr_value(attrs, :runner_node, "runner_node") do
      nil ->
        attrs

      node_name ->
        case ClusterNodes.get_by_name(node_name) do
          nil -> attrs
          node -> merge_node_defaults(attrs, node)
        end
    end
  end

  defp merge_node_defaults(attrs, node) do
    explicit_backend = attr_value(attrs, :backend, "backend")
    configured_backend = node.default_backend || "claude"

    attrs
    |> put_default(:backend, "backend", node.default_backend)
    |> maybe_put_default_model(node.default_model, explicit_backend, configured_backend)
  end

  defp maybe_put_default_model(attrs, nil, _explicit_backend, _configured_backend), do: attrs

  defp maybe_put_default_model(attrs, default_model, explicit_backend, configured_backend) do
    if is_nil(explicit_backend) or explicit_backend == configured_backend do
      put_default(attrs, :model, "model", default_model)
    else
      attrs
    end
  end

  # `nil` means "no node default configured for this field" — never inject a
  # literal nil into attrs, since an explicit nil would cast over (and clear)
  # the Session schema's own field default.
  defp put_default(attrs, _atom_key, _string_key, nil), do: attrs

  defp put_default(attrs, atom_key, string_key, default_value) do
    case locate_attr(attrs, atom_key, string_key) do
      :missing ->
        if string_keyed?(attrs),
          do: Map.put(attrs, string_key, default_value),
          else: Map.put(attrs, atom_key, default_value)

      {:atom, v} ->
        if blank?(v), do: Map.put(attrs, atom_key, default_value), else: attrs

      {:string, v} ->
        if blank?(v), do: Map.put(attrs, string_key, default_value), else: attrs
    end
  end

  # `nil` if the key is missing or blank under either key style, else the value.
  defp attr_value(attrs, atom_key, string_key) do
    case locate_attr(attrs, atom_key, string_key) do
      :missing -> nil
      {_style, v} -> if blank?(v), do: nil, else: v
    end
  end

  defp locate_attr(attrs, atom_key, string_key) do
    cond do
      Map.has_key?(attrs, atom_key) -> {:atom, Map.get(attrs, atom_key)}
      Map.has_key?(attrs, string_key) -> {:string, Map.get(attrs, string_key)}
      true -> :missing
    end
  end

  defp string_keyed?(attrs), do: Enum.any?(Map.keys(attrs), &is_binary/1)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc """
  The most recently created non-archived session with the given
  `idempotency_key`, or `nil`. Powers `start_session`'s `idempotency_key`
  dedup — a repeat call with the same key returns the existing session
  instead of spawning a duplicate.
  """
  def get_session_by_idempotency_key(nil), do: nil
  def get_session_by_idempotency_key(""), do: nil

  def get_session_by_idempotency_key(key) do
    from(s in Session,
      where: s.idempotency_key == ^key and is_nil(s.archived_at),
      order_by: [desc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      session -> Repo.preload(session, :project)
    end
  end

  @doc """
  Like `get_session_by_idempotency_key/1`, but only matches a session created
  within the last `window_seconds` — used for AUTO-derived idempotency keys
  (see `OrcaHub.MCP.Tools.Sessions`), which are time-bounded so a
  pathological hash collision on a recycled MCP request id ages out instead
  of dedup-ing forever. Explicit caller-supplied keys stay unbounded (see
  `get_session_by_idempotency_key/1`) since retrying "until I know it
  landed" may legitimately happen well after the auto-key window.
  """
  def get_recent_session_by_idempotency_key(nil, _window_seconds), do: nil
  def get_recent_session_by_idempotency_key("", _window_seconds), do: nil

  def get_recent_session_by_idempotency_key(key, window_seconds) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-window_seconds, :second)
      |> DateTime.to_naive()

    from(s in Session,
      where: s.idempotency_key == ^key and is_nil(s.archived_at),
      where: s.inserted_at >= ^cutoff,
      order_by: [desc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      session -> Repo.preload(session, :project)
    end
  end

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  # No prior caller broadcasts anything on delete today (ORCAHUB3-26 item 4)
  # even though `SessionHeartbeat` has always had a handler for it - added
  # here to match `archive_session/1`'s pattern so that handler actually
  # fires, and so any future caller doesn't silently reintroduce the same gap.
  def delete_session(%Session{} = session) do
    result = Repo.delete(session)

    with {:ok, deleted} <- result do
      Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {deleted.id, {:status, :deleted}})
    end

    result
  end

  def list_messages(session_id) do
    Repo.all(
      from m in Message, where: m.session_id == ^session_id, order_by: [asc: m.inserted_at]
    )
  end

  # `task_*` system events (subagent progress broadcasts) are matched by
  # `tool_use_id` rather than `parent_tool_use_id` — see
  # MessageComponents.message_feed/1, which this mirrors.
  @task_event_subtypes ~w(task_started task_progress task_notification)

  @doc """
  A windowed page of a session's message feed, keyset-paginated over
  TOP-LEVEL items (oldest-first in the returned list) with every subagent
  descendant of those items pulled in alongside them — never a bare "last N
  rows" slice, which could split a parent tool_use from its
  `parent_tool_use_id` children / `task_*` progress events (see
  MessageComponents.message_feed/1's grouping, which this stays consistent
  with by construction: a descendant is included whenever ITS parent's
  tool_use id appears among the fetched top-level messages, regardless of
  how the descendant's own `inserted_at` compares to the page boundary).

  `opts`:
    - `:limit` (required) — how many TOP-LEVEL messages to return (the
      window size — descendants are extra, uncounted).
    - `:before` — a `%{inserted_at:, id:}` cursor (see `:cursor` below);
      when given, only top-level messages strictly older than it are
      considered. Omit for the first ("most recent") page.

  Returns `%{messages:, has_more:, cursor:}`:
    - `:messages` — oldest-first, ready to prepend/render as-is (each entry
      already carries the `"timestamp"` key SessionRunner's live events do).
    - `:has_more` — whether an OLDER top-level message exists beyond this
      page (drives the "load older" affordance).
    - `:cursor` — the oldest loaded top-level message's `%{inserted_at:,
      id:}`, to pass as the next call's `:before` — `nil` if this page (and
      therefore the session) has no top-level messages at all.

  Ordered by `(inserted_at, id)` rather than a raw offset: messages are
  appended continuously by a live session, so an offset would skip or
  duplicate rows as new ones land mid-scroll. `id` is the tiebreak for
  messages sharing a timestamp (usec precision still ties under load — see
  the `widen_message_timestamps_to_microseconds` migration's moduledoc).

  The merge sort below MUST use `NaiveDateTime.compare/2` (via the explicit
  comparator, not a bare `Enum.sort_by/2`) — comparing `%NaiveDateTime{}`
  structs with the default term/struct ordering compares fields in
  ALPHABETICAL key order (`microsecond` before `minute`/`month`/`second`),
  which is unrelated to chronological order and silently scrambles any two
  timestamps that share an `hour`. See the 2026-08-08 windowed-feed
  out-of-order/dropped-message incident.
  """
  def list_messages_window(session_id, opts) do
    limit = Keyword.fetch!(opts, :limit)
    cursor = Keyword.get(opts, :before)

    page = fetch_top_level_page(session_id, limit, cursor)
    {top_level, has_more} = split_page(page, limit)
    top_level_asc = Enum.reverse(top_level)

    messages =
      (top_level_asc ++ fetch_descendants(session_id, top_level_asc))
      |> Enum.sort_by(& &1, &message_order/2)
      |> Enum.map(&row_to_event/1)

    %{messages: messages, has_more: has_more, cursor: window_cursor(top_level_asc)}
  end

  defp fetch_top_level_page(session_id, limit, cursor) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: ^top_level_condition()
    )
    |> apply_cursor(cursor)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    # Fetch one extra row to learn whether an older page exists without a
    # separate count query.
    |> limit(^(limit + 1))
    |> Repo.all()
  end

  defp top_level_condition do
    dynamic(
      [m],
      fragment("? ->> 'parent_tool_use_id' IS NULL", m.data) and
        not fragment(
          "(? ->> 'type' = 'system' AND ? ->> 'subtype' = ANY(?) AND ? ->> 'tool_use_id' IS NOT NULL)",
          m.data,
          m.data,
          ^@task_event_subtypes,
          m.data
        )
    )
  end

  defp apply_cursor(query, nil), do: query

  # Standard operators (not a raw `fragment("(?, ?) < (?, ?)", ...)` tuple
  # comparison) deliberately: a bare fragment gives Ecto no type context for
  # `^id`, and Postgrex can't guess it needs `:binary_id` encoding — this OR
  # form lets `m.id`'s schema type drive that inference normally, while
  # still being the same "seek past this row" shape the composite
  # `(session_id, inserted_at, id)` index (see the migration) supports.
  defp apply_cursor(query, %{inserted_at: at, id: id}) do
    from(m in query,
      where: m.inserted_at < ^at or (m.inserted_at == ^at and m.id < ^id)
    )
  end

  defp split_page(page, limit) do
    if length(page) > limit, do: {Enum.take(page, limit), true}, else: {page, false}
  end

  defp window_cursor([]), do: nil
  defp window_cursor([oldest | _]), do: %{inserted_at: oldest.inserted_at, id: oldest.id}

  # Chronological (inserted_at, id) comparator for the top-level/descendant
  # merge above — NEVER replace this with a bare `Enum.sort_by(&{&1.inserted_at,
  # &1.id})`: comparing `%NaiveDateTime{}` structs via `<=` falls back to
  # struct/term ordering (alphabetical field order), not calendar time.
  defp message_order(a, b) do
    case NaiveDateTime.compare(a.inserted_at, b.inserted_at) do
      :lt -> true
      :gt -> false
      :eq -> a.id <= b.id
    end
  end

  defp fetch_descendants(_session_id, []), do: []

  defp fetch_descendants(session_id, top_level_asc) do
    case extract_tool_use_ids(top_level_asc) do
      [] ->
        []

      ids ->
        Repo.all(
          from m in Message,
            where: m.session_id == ^session_id,
            where:
              fragment("? ->> 'parent_tool_use_id' = ANY(?)", m.data, ^ids) or
                (fragment("? ->> 'type' = 'system'", m.data) and
                   fragment("? ->> 'subtype' = ANY(?)", m.data, ^@task_event_subtypes) and
                   fragment("? ->> 'tool_use_id' = ANY(?)", m.data, ^ids))
        )
    end
  end

  defp extract_tool_use_ids(messages) do
    messages
    |> Enum.filter(&(&1.data["type"] == "assistant"))
    |> Enum.flat_map(fn m ->
      m.data
      |> get_in(["message", "content"])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
      |> Enum.map(& &1["id"])
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp row_to_event(%Message{data: data, inserted_at: inserted_at}) do
    Map.put(data, "timestamp", inserted_at)
  end

  @doc """
  The single assistant message that contains a `tool_use` block with the
  given id, or `nil` — used by `SessionLive.Show` to pull a subagent's
  parent tool_use into an already-loaded windowed feed (see
  `list_messages_window/2`) when a LIVE event's `parent_tool_use_id` (or a
  `task_*` progress event's `tool_use_id`) references a tool_use that fell
  outside the window. Without this, `MessageComponents.message_feed/1`
  groups the descendant under a parent that's never rendered, silently
  dropping it (and everything nested under it, including a subagent's
  final reply) from the DOM.

  Returns the same shape as a `list_messages_window/2` entry (raw event
  map plus a `"timestamp"` key).
  """
  def fetch_tool_use_message(session_id, tool_use_id) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'type' = 'assistant'", m.data),
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'message'->'content', '[]'::jsonb)) AS block WHERE block->>'type' = 'tool_use' AND block->>'id' = ?)",
          m.data,
          ^tool_use_id
        ),
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      message -> row_to_event(message)
    end
  end

  # -------------------------------------------------------------------
  # Targeted derived-state queries — see SessionLive.Show's mount, which
  # needs plan mode / todos / pending questions / pending pi dialogs /
  # context percent computed from a session's FULL history even though the
  # message feed itself only loads a bounded window (see
  # list_messages_window/2 above). Each of these is a single/bounded
  # targeted query (WHERE-pushed to Postgres, LIMIT 1 or a handful of rows)
  # rather than pulling the whole history into the app just to fold over it.
  # -------------------------------------------------------------------

  @doc """
  The most recent unanswered `AskUserQuestion`, or `nil` — same "most
  recent still-pending" semantics as `OrcaHub.AskUserQuestion.pending_questions/1`,
  but as one targeted query instead of a full-history scan. Safe because a
  real (non-error) answering `tool_result` is exceptionally rare in practice
  (see that module's doc) — an `AskUserQuestion` is, for all practical
  purposes, always still open once asked, so only the LATEST one need be
  considered.

  Returns `%{tool_use_id:, questions:}` with the RAW (un-normalized)
  questions list — callers wanting the UI-ready shape should pass it through
  `OrcaHub.AskUserQuestion.normalize_questions/1`.
  """
  def pending_ask_user_question(session_id) do
    case latest_message_with_tool_use(session_id, ["AskUserQuestion"]) do
      nil -> nil
      data -> extract_pending_ask_user_question(session_id, data)
    end
  end

  defp extract_pending_ask_user_question(session_id, data) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use" && &1["name"] == "AskUserQuestion"))
    |> List.last()
    |> case do
      %{"id" => id, "input" => %{"questions" => questions}}
      when is_binary(id) and is_list(questions) ->
        if tool_use_answered?(session_id, id) do
          nil
        else
          %{tool_use_id: id, questions: questions}
        end

      _ ->
        nil
    end
  end

  @doc """
  The tool_use `"name"` (`"EnterPlanMode"` or `"ExitPlanMode"`) of the most
  recent plan-mode toggle in a session's full history, or `nil` if neither
  ever fired — mirrors `OrcaHubWeb.SessionLive.PlanMode.detect/1`'s
  "last Enter/Exit wins" reconstruction via one targeted query.
  """
  def latest_plan_mode_tool_use_name(session_id) do
    case latest_message_with_tool_use(session_id, ["EnterPlanMode", "ExitPlanMode"]) do
      nil -> nil
      data -> last_tool_use_name(data, ["EnterPlanMode", "ExitPlanMode"])
    end
  end

  defp last_tool_use_name(data, names) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use" && &1["name"] in names))
    |> List.last()
    |> case do
      %{"name" => name} -> name
      _ -> nil
    end
  end

  @doc """
  The raw `todos` input of a session's most recent `TodoWrite` tool call, or
  `nil` if none — mirrors `OrcaHubWeb.SessionLive.Todos.from_messages/1`'s
  "last TodoWrite wins" reconstruction via one targeted query. Callers
  should pass the result through `Todos.parse/1` (handles both the list and
  JSON-string-encoded shapes a `todos` arg can arrive in).
  """
  def latest_todos_input(session_id) do
    case latest_message_with_tool_use(session_id, ["TodoWrite"]) do
      nil ->
        nil

      data ->
        data
        |> get_in(["message", "content"])
        |> List.wrap()
        |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use" && &1["name"] == "TodoWrite"))
        |> List.last()
        |> case do
          nil -> nil
          tool_use -> get_in(tool_use, ["input", "todos"])
        end
    end
  end

  @doc """
  The most recent unanswered pi extension-UI dialog request event, or `nil`
  — mirrors `SessionLive.Show`'s `pending_ui_request_from_messages/1`
  reconstruction ("last pi_ui_request with no later pi_ui_response for the
  same id") via one targeted query plus one existence check.
  """
  def pending_pi_ui_request(session_id) do
    case latest_event_of_type(session_id, "pi_ui_request") do
      %{"id" => id} = data ->
        if event_id_exists?(session_id, "pi_ui_response", id), do: nil, else: data

      other ->
        other
    end
  end

  @doc """
  Returns a struct representing a pending dialog for a pi session, or `nil`.

  For pi sessions, returns the pending dialog data (id, method, title, message,
  options) if there is an unanswered `pi_ui_request` in the session's history.
  For non-pi sessions (Claude, Codex), returns `nil` since they use the
  `AskUserQuestion` tool instead.

  This is the public API for the `pending_pi_ui_request` reconstruction logic.
  It accepts either a session struct or a session ID.

  ## Examples

      iex> Sessions.pending_question(session_id)
      %{"id" => "req1", "method" => "input", "title" => "Title", "message" => "Msg", "options" => []}

      iex> Sessions.pending_question(claude_session_id)
      nil
  """
  def pending_question(%{id: session_id}), do: pending_question(session_id)
  def pending_question(session_id) do
    # For non-pi sessions, return nil immediately - they use AskUserQuestion tool
    case get_session(session_id) do
      nil -> nil
      %Session{backend: "claude"} -> nil
      %Session{backend: "codex"} -> nil
      %Session{backend: "pi"} ->
        # Extract the pi dialog fields from pending_pi_ui_request result
        case pending_pi_ui_request(session_id) do
          %{"id" => id, "method" => method, "title" => title, "message" => message, "options" => options} ->
            %{id: id, method: method, title: title, message: message, options: options}
          _ -> nil
        end
      _ -> nil
    end
  end

  @doc """
  Batched version of `pending_question/1` for efficiency.

  Takes a list of session IDs and returns a map of `%{session_id => pending_question_map}`
  for sessions that have a pending dialog. Only pi sessions are checked.

  This uses a single SQL query to fetch all pending dialogs instead of N queries.
  """
  def pending_questions_for(session_ids) when is_list(session_ids) and length(session_ids) > 0 do
    # Fetch all pi_ui_request events for these sessions in one query
    requests =
      from(m in Message,
        where: m.session_id in ^session_ids,
        where: fragment("? ->> 'type' = ?", m.data, "pi_ui_request"),
        order_by: [desc: m.inserted_at],
        select: %{session_id: m.session_id, data: m.data}
      )
      |> Repo.all()
      |> Enum.group_by(& &1.session_id)

    # For each session, check if there's a matching pi_ui_response
    Enum.reduce(session_ids, %{}, fn session_id, acc ->
      case requests[session_id] do
        [%{data: %{"id" => request_id} = data_map}] ->
          # Check if a matching response exists
          if event_id_exists?(session_id, "pi_ui_response", request_id) do
            acc
          else
            # Return the pending dialog data
            data = %{
              id: request_id,
              method: data_map["method"],
              title: data_map["title"],
              message: data_map["message"],
              options: data_map["options"]
            }
            Map.put(acc, session_id, data)
          end
        _ ->
          acc
      end
    end)
  end

  def pending_questions_for(_), do: %{}

  @doc """
  Whether the most recent `pi_plan_mode` broadcast in a session's history
  left plan mode enabled — mirrors `SessionLive.Show`'s
  `pi_plan_mode_from_messages/1` reconstruction.
  """
  def latest_pi_plan_mode_enabled?(session_id) do
    match?(%{"enabled" => true}, latest_event_of_type(session_id, "pi_plan_mode"))
  end

  # How many of the most recent `pi_session_stats` events to consider before
  # giving up — bounds the (rare) case where the newest one(s) lack a numeric
  # `context_usage.percent`, without an unbounded fallback scan.
  @context_stats_scan_limit 5

  @doc """
  The context-window percent from the most recent `pi_session_stats` event
  that actually carries a numeric `context_usage.percent`, or `nil` —
  mirrors `SessionLive.Show`'s `context_percent_from_messages/1`
  reconstruction via a small bounded query instead of a full scan.
  """
  def latest_context_percent(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'type' = 'pi_session_stats'", m.data),
      order_by: [desc: m.inserted_at],
      limit: ^@context_stats_scan_limit,
      select: m.data
    )
    |> Repo.all()
    |> Enum.find_value(fn
      %{"context_usage" => %{"percent" => p}} when is_number(p) -> p
      _ -> nil
    end)
  end

  @doc """
  The context-window TOKEN count from the most recent `pi_session_stats`
  event that actually carries a numeric `context_usage.tokens`, or `nil` —
  same scan pattern as `latest_context_percent/1`. Read by pi session
  forking (pi_fork_spec.md §3/§7) both to report `parent_context_tokens` on
  a fork spawn's result and to drive the soft KV-budget guard.
  """
  def last_context_tokens(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'type' = 'pi_session_stats'", m.data),
      order_by: [desc: m.inserted_at],
      limit: ^@context_stats_scan_limit,
      select: m.data
    )
    |> Repo.all()
    |> Enum.find_value(fn
      %{"context_usage" => %{"tokens" => t}} when is_number(t) -> t
      _ -> nil
    end)
  end

  @doc """
  Count of non-archived sessions forked from `parent_id` — the "concurrent
  fork-children" term in pi_fork_spec.md §7's soft KV-budget guard. Called
  AFTER a new fork child is created, so the count already includes that
  child (the spec's "+1").
  """
  def count_active_fork_children(parent_id) do
    from(s in Session,
      where: s.forked_from_session_id == ^parent_id,
      where: is_nil(s.archived_at)
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Merges `annotations` into a fork child's synthetic `forked_from` marker
  message (pi_fork_spec.md §8) — how `OrcaHub.ForkGate` stamps §6.1's
  cache-hit/miss outcome onto the marker at the top of the child's feed.

  Returns `{:ok, message}`, or `{:error, :not_found}` when the child has no
  marker (a fork whose marker creation itself failed — that path is already
  best-effort, so this stays non-fatal too).
  """
  def annotate_fork_marker(session_id, annotations) when is_map(annotations) do
    query =
      from(m in Message,
        where: m.session_id == ^session_id,
        where: fragment("? ->> 'subtype' = 'forked_from'", m.data),
        order_by: [desc: m.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      message ->
        message
        |> Message.changeset(%{data: Map.merge(message.data, annotations)})
        |> Repo.update()
    end
  end

  # Latest assistant message containing a tool_use block whose name is in
  # `names`, or `nil` — the shared primitive behind the plan-mode/todos/
  # AskUserQuestion targeted queries above. Returns the whole message `data`
  # (not just the matching block) since a message can carry several tool_use
  # blocks and callers need to pick the last matching one in content order
  # to match the full-history fold semantics they're mirroring.
  defp latest_message_with_tool_use(session_id, names) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'type' = 'assistant'", m.data),
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'message'->'content', '[]'::jsonb)) AS block WHERE block->>'type' = 'tool_use' AND block->>'name' = ANY(?))",
          m.data,
          ^names
        ),
      order_by: [desc: m.inserted_at],
      limit: 1,
      select: m.data
    )
    |> Repo.one()
  end

  # Is there any NON-error tool_result for `tool_use_id` anywhere in the
  # session's history? (The synthetic `is_error: true` result Claude's CLI
  # always injects for AskUserQuestion under `-p` must not count — see
  # OrcaHub.AskUserQuestion's moduledoc.)
  defp tool_use_answered?(session_id, tool_use_id) do
    Repo.exists?(
      from m in Message,
        where: m.session_id == ^session_id,
        where: fragment("? ->> 'type' = 'user'", m.data),
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'message'->'content', '[]'::jsonb)) AS block WHERE block->>'type' = 'tool_result' AND block->>'tool_use_id' = ? AND COALESCE(block->>'is_error', 'false') <> 'true')",
            m.data,
            ^tool_use_id
          )
    )
  end

  defp latest_event_of_type(session_id, type) do
    from(m in Message,
      where: m.session_id == ^session_id,
      where: fragment("? ->> 'type' = ?", m.data, ^type),
      order_by: [desc: m.inserted_at],
      limit: 1,
      select: m.data
    )
    |> Repo.one()
  end

  defp event_id_exists?(session_id, type, id) do
    Repo.exists?(
      from m in Message,
        where: m.session_id == ^session_id,
        where: fragment("? ->> 'type' = ?", m.data, ^type),
        where: fragment("? ->> 'id' = ?", m.data, ^id)
    )
  end

  # Find all pi_ui_request events that don't have a corresponding pi_ui_response
  # with the same id. Returns a list of %{"id" => id} maps.
  def all_pending_pi_dialog_ids(session_id) do
    requests =
      from(m in Message,
        where: m.session_id == ^session_id,
        where: fragment("? ->> 'type'", m.data) == "pi_ui_request",
        select: fragment("? ->> 'id'", m.data)
      )
      |> Repo.all()

    answered_ids =
      from(m in Message,
        where: m.session_id == ^session_id,
        where: fragment("? ->> 'type'", m.data) == "pi_ui_response",
        select: fragment("? ->> 'id'", m.data)
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.filter(requests, fn id -> not MapSet.member?(answered_ids, id) end)
    |> Enum.map(&%{"id" => &1})
  end

  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Records a directed session_interactions edge — e.g. a
  send_message_to_session delivery. `attrs` needs :sender_session_id and
  :recipient_session_id; :kind defaults to "message" and :inserted_at
  defaults to now (the backfill task overrides it with the original
  message timestamp).
  """
  def create_session_interaction(attrs) do
    %SessionInteraction{}
    |> SessionInteraction.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists session_interactions edges, newest first. `opts` supports
  :sender_session_id, :recipient_session_id, :kind, and :since (only edges
  with inserted_at >= since) — all optional, combinable.
  """
  def list_session_interactions(opts \\ []) do
    from(i in SessionInteraction, order_by: [desc: i.inserted_at])
    |> filter_interactions_by_sender(opts[:sender_session_id])
    |> filter_interactions_by_recipient(opts[:recipient_session_id])
    |> filter_interactions_by_kind(opts[:kind])
    |> filter_interactions_by_since(opts[:since])
    |> Repo.all()
  end

  @doc """
  Every session_interactions edge touching any session in `session_ids`,
  as either sender or recipient — the whole-subgraph query the session
  graph view needs in one round trip rather than per-node lookups.
  """
  def list_session_interactions_for_sessions(session_ids) when is_list(session_ids) do
    from(i in SessionInteraction,
      where: i.sender_session_id in ^session_ids or i.recipient_session_id in ^session_ids,
      order_by: [asc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns `{root, members}` for the whole spawn tree containing
  `session_id`: walks `parent_session_id` up to the root ancestor, then
  gathers every descendant of that root via breadth-first traversal. No
  archived/time filtering (unlike the old `/sessions/tree` page's `:recent`
  scope) — a session's own tree view is already scoped to one
  orchestration, so a completed/archived child is exactly the point of
  looking, not something to hide.
  """
  def get_session_tree(session_id) do
    session = Repo.get!(Session, session_id)
    root = find_root_session(session)
    {root, collect_tree_members([root])}
  end

  defp find_root_session(%Session{parent_session_id: nil} = session), do: session

  defp find_root_session(%Session{parent_session_id: parent_id} = session) do
    case Repo.get(Session, parent_id) do
      nil -> session
      parent -> find_root_session(parent)
    end
  end

  defp collect_tree_members(frontier, acc \\ %{})
  defp collect_tree_members([], acc), do: Map.values(acc)

  defp collect_tree_members(frontier, acc) do
    acc = Enum.reduce(frontier, acc, &Map.put(&2, &1.id, &1))
    frontier_ids = Enum.map(frontier, & &1.id)

    new_children =
      from(s in Session, where: s.parent_session_id in ^frontier_ids)
      |> Repo.all()
      |> Enum.reject(&Map.has_key?(acc, &1.id))

    collect_tree_members(new_children, acc)
  end

  @doc """
  Bulk id -> title lookup, one query regardless of list size. Powers the
  session-tree view resolving the title of an edge's far end when it
  points at a session outside the current tree — a single extra fetch for
  the whole page, never per-chip.
  """
  def list_sessions_by_ids([]), do: []

  def list_sessions_by_ids(ids) when is_list(ids) do
    from(s in Session, where: s.id in ^ids, select: %{id: s.id, title: s.title})
    |> Repo.all()
  end

  # How many recent assistant messages to scan for Agent tool_use blocks —
  # generous relative to @tail_scan_limit since list_task_invocations/1 wants
  # the FULL history of subagent spawns for a session, not just a tail.
  @task_invocation_scan_limit 2000

  @doc """
  Every harness-internal subagent invocation for a session: assistant
  messages' "Agent"-named tool_use blocks (see message_components.ex's
  `assistant_message/1`, which separates Agent tool_use blocks from regular
  ones for the same reason — harness subagents surface as a tool_use block
  named "Agent", not a literal "Task" string anywhere in this codebase).
  Powers the session-tree view's lazy, per-session "Subagents" disclosure —
  called on-demand for one session at a time, never for the whole visible
  set up front.
  """
  def list_task_invocations(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id and fragment("? ->> 'type' = 'assistant'", m.data),
      order_by: [asc: m.inserted_at],
      limit: @task_invocation_scan_limit
    )
    |> Repo.all()
    |> Enum.flat_map(&agent_tool_use_blocks/1)
  end

  defp agent_tool_use_blocks(%Message{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use" && &1["name"] == "Agent"))
    |> Enum.map(fn block ->
      %{
        id: block["id"],
        subagent_type: get_in(block, ["input", "subagent_type"]),
        description: get_in(block, ["input", "description"])
      }
    end)
  end

  @doc """
  Which of `session_ids` have at least one harness-internal subagent
  invocation — same "Agent"-named tool_use block match as
  `list_task_invocations/1`, just counted instead of extracted, and for a
  whole tree's worth of ids in one grouped query rather than one id at a
  time. Powers the tree view's upfront gate for whether a node's
  "Subagents" disclosure is worth rendering at all — the disclosure's own
  contents still fetch lazily, on first expand.

  Returns `%{session_id => count}`; a session with none is simply absent
  from the map (no zero-count entries).
  """
  def session_ids_with_subagents(session_ids)
  def session_ids_with_subagents([]), do: %{}

  def session_ids_with_subagents(session_ids) when is_list(session_ids) do
    from(m in Message,
      where: m.session_id in ^session_ids and fragment("? ->> 'type' = 'assistant'", m.data),
      inner_lateral_join:
        block in fragment(
          "jsonb_array_elements(COALESCE(?->'message'->'content', '[]'::jsonb))",
          m.data
        ),
      on: fragment("? ->> 'type' = 'tool_use' AND ? ->> 'name' = 'Agent'", block, block),
      group_by: m.session_id,
      select: {m.session_id, fragment("count(*)")}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp filter_interactions_by_sender(q, nil), do: q

  defp filter_interactions_by_sender(q, sender_id),
    do: from(i in q, where: i.sender_session_id == ^sender_id)

  defp filter_interactions_by_recipient(q, nil), do: q

  defp filter_interactions_by_recipient(q, recipient_id),
    do: from(i in q, where: i.recipient_session_id == ^recipient_id)

  defp filter_interactions_by_kind(q, nil), do: q
  defp filter_interactions_by_kind(q, kind), do: from(i in q, where: i.kind == ^kind)

  defp filter_interactions_by_since(q, nil), do: q
  defp filter_interactions_by_since(q, since), do: from(i in q, where: i.inserted_at >= ^since)

  def search(query, opts \\ []) do
    like = "%#{query}%"
    include_archived = Keyword.get(opts, :include_archived, false)

    from(s in Session,
      where: ilike(s.title, ^like) or ilike(s.directory, ^like),
      preload: [:project],
      order_by: [desc: s.updated_at],
      limit: 5
    )
    |> then(fn q ->
      if include_archived, do: q, else: where(q, [s], is_nil(s.archived_at))
    end)
    |> Repo.all()
  end

  def search_sessions_by_directory(directory, opts \\ %{}) do
    limit = opts[:limit] || 20

    from(s in Session,
      where: s.directory == ^directory,
      preload: [:project],
      order_by: [desc: s.updated_at],
      limit: ^limit
    )
    |> apply_search_filters(opts)
    |> Repo.all()
  end

  def search_all_sessions(opts \\ %{}) do
    limit = opts[:limit] || 20

    from(s in Session,
      left_join: p in assoc(s, :project),
      where: is_nil(s.project_id) or is_nil(p.deleted_at),
      preload: [project: p],
      order_by: [desc: s.updated_at],
      limit: ^limit
    )
    |> apply_search_filters(opts)
    |> Repo.all()
  end

  # Applies the archive/query/status filters shared by the session search
  # functions. `opts` is a map with optional :archived_only, :include_archived,
  # :query and :status keys.
  defp apply_search_filters(query, opts) do
    query
    |> filter_by_archive(opts)
    |> filter_by_query(opts[:query])
    |> filter_by_status(opts[:status])
    |> filter_by_session_id(opts[:session_id])
    |> filter_by_parent_session_id(opts[:parent_session_id])
  end

  defp filter_by_archive(q, opts) do
    cond do
      opts[:archived_only] -> from(s in q, where: not is_nil(s.archived_at))
      opts[:include_archived] -> q
      true -> from(s in q, where: is_nil(s.archived_at))
    end
  end

  defp filter_by_query(q, nil), do: q
  defp filter_by_query(q, query), do: from(s in q, where: ilike(s.title, ^"%#{query}%"))

  defp filter_by_status(q, nil), do: q
  defp filter_by_status(q, status), do: from(s in q, where: s.status == ^status)

  defp filter_by_session_id(q, nil), do: q
  defp filter_by_session_id(q, id), do: from(s in q, where: s.id == ^id)

  defp filter_by_parent_session_id(q, nil), do: q

  defp filter_by_parent_session_id(q, parent_id),
    do: from(s in q, where: s.parent_session_id == ^parent_id)

  @doc """
  Returns the IDs of the previous and next sessions within the same project,
  ordered by updated_at desc. Returns {prev_id, next_id} where either may be nil.
  """
  def get_adjacent_session_ids(session) do
    project_id = session.project_id

    if is_nil(project_id) do
      {nil, nil}
    else
      sessions =
        from(s in Session,
          where: s.project_id == ^project_id and is_nil(s.archived_at),
          select: s.id,
          order_by: [desc: s.updated_at]
        )
        |> Repo.all()

      case Enum.find_index(sessions, &(&1 == session.id)) do
        nil -> {nil, nil}
        0 -> {nil, Enum.at(sessions, 1)}
        idx -> {Enum.at(sessions, idx - 1), Enum.at(sessions, idx + 1)}
      end
    end
  end

  def count_idle_sessions do
    Repo.one(
      from s in Session,
        where: is_nil(s.archived_at) and s.status == "idle",
        select: count(s.id)
    )
  end

  def list_idle_sessions_with_last_assistant_message do
    reset_front_of_queue_priority()

    # LATERAL join instead of a DISTINCT ON subquery over the whole `messages`
    # table (was a full sequential scan + disk-spilled sort of 300K+ rows to
    # answer a question about ~50 idle sessions — see perf_audit_projects_queue.md
    # §2). This runs one indexed "last assistant message" lookup per
    # already-filtered idle/waiting session instead, served by the
    # `(session_id, inserted_at, id)` index added in 84c2664.
    last_message =
      from m in Message,
        where:
          m.session_id == parent_as(:session).id and
            fragment("? ->> 'type' = 'assistant'", m.data),
        order_by: [desc: m.inserted_at],
        limit: 1

    Repo.all(
      from s in Session,
        as: :session,
        left_lateral_join: m in subquery(last_message),
        on: true,
        left_join: p in assoc(s, :project),
        where:
          is_nil(s.archived_at) and s.status in ["idle", "waiting"] and
            is_nil(s.parent_session_id),
        order_by: [asc: s.priority, asc: s.updated_at],
        preload: [project: p],
        select: {s, m}
    )
  end

  # How many recent assistant messages to scan (for text or tool_use blocks) —
  # bounds query cost regardless of how long the session's history is.
  @tail_scan_limit 50

  # Assistant messages within this many seconds of the newest one are treated
  # as the same "message burst" when hunting for reply text (see below).
  @assistant_text_window_seconds 2

  @doc """
  Total message count for a session. Used by the Agent Runs API
  (`ApiRunController`) as a completion cursor for continuations: a run
  snapshots this count right before its prompt is delivered, so a poll can
  tell a session that's idle because THIS run's turn already finished apart
  from one that's idle because it hasn't started processing yet (the latter
  matters for a continuation, whose target session can already be idle from
  a previous turn the instant the prompt is delivered).
  """
  def count_messages(session_id) do
    Repo.aggregate(from(m in Message, where: m.session_id == ^session_id), :count, :id)
  end

  @doc """
  Return the text of the most recent assistant message that actually carries
  text blocks, or `nil` if there is none (or the latest burst carried no text
  blocks — e.g. only tool_use/thinking).

  Scans the newest few assistant messages rather than taking exactly the
  newest one: a turn's final thinking-only and text messages often share a
  same-second `inserted_at`, so `limit: 1` can land on the thinking one and
  report no text even though the reply exists. The scan is bounded to a small
  time window around the newest assistant message so a text-less turn can't
  resurrect a previous turn's reply.

  Used by the Discord worker to post a session's reply back to the channel.
  """
  def last_assistant_text(session_id) do
    rows =
      from(m in Message,
        where: m.session_id == ^session_id and fragment("? ->> 'type' = 'assistant'", m.data),
        order_by: [desc: m.inserted_at],
        limit: @tail_scan_limit
      )
      |> Repo.all()

    case rows do
      [] ->
        nil

      [newest | _] ->
        cutoff = NaiveDateTime.add(newest.inserted_at, -@assistant_text_window_seconds, :second)

        rows
        |> Enum.take_while(&(NaiveDateTime.compare(&1.inserted_at, cutoff) != :lt))
        |> Enum.find_value(&extract_assistant_text/1)
    end
  end

  defp extract_assistant_text(%Message{data: data}) do
    text =
      data
      |> get_in(["message", "content"])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text == "", do: nil, else: text
  end

  @doc """
  A slim, read-only "tail" for a session: its last assistant text message plus
  the last `tool_call_limit` tool calls (name + raw input, oldest to newest) —
  without touching the live SessionRunner. Powers `get_session_tail` (an
  orchestrator progress peek that doesn't interrupt the worker, unlike
  `send_message_to_session`).
  """
  def session_tail(session_id, opts \\ []) do
    limit = Keyword.get(opts, :tool_call_limit, 10)

    %{list: tool_calls, truncated?: truncated?, total: total} =
      recent_tool_calls(session_id, limit)

    result = %{
      last_assistant_text: last_assistant_text(session_id),
      recent_tool_calls: tool_calls,
      tool_calls_truncated?: truncated?
    }

    if truncated? do
      Map.put(result, :tool_calls_total, total)
    else
      result
    end
  end

  defp recent_tool_calls(session_id, limit) do
    from(m in Message,
      where: m.session_id == ^session_id and fragment("? ->> 'type' = 'assistant'", m.data),
      order_by: [desc: m.inserted_at],
      limit: @tail_scan_limit
    )
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.flat_map(&tool_use_blocks/1)
    |> case do
      all ->
        total = length(all)
        capped = Enum.take(all, -limit)
        truncated? = total > limit
        %{list: capped, truncated?: truncated?, total: total}
    end
  end

  defp tool_use_blocks(%Message{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
    |> Enum.map(&%{name: &1["name"], input: &1["input"]})
  end

  @doc """
  Bucketed activity metadata (message + tool-call counts over the last
  5/15/30 minutes, plus last_activity_at) for every id in `session_ids`, keyed
  by session_id. Computed in two grouped queries total regardless of how many
  session ids are passed — NOT one query per session — so it's safe to call
  for an entire `search_sessions` page at once.

  Every id passed in `session_ids` is present in the result, even a session
  with no messages at all (zero counts, `last_activity_at: nil`) — callers
  never need to handle a missing key.
  """
  # Bucket windows (minutes) for activity_metadata/1.
  @activity_buckets [5, 15, 30]

  def activity_metadata(session_ids)
  def activity_metadata([]), do: %{}

  def activity_metadata(session_ids) when is_list(session_ids) do
    now = NaiveDateTime.utc_now()
    [t5, t15, t30] = Enum.map(@activity_buckets, &NaiveDateTime.add(now, -&1 * 60, :second))

    message_counts =
      from(m in Message,
        where: m.session_id in ^session_ids,
        group_by: m.session_id,
        select: %{
          session_id: m.session_id,
          messages_5m: fragment("count(*) FILTER (WHERE ? >= ?)", m.inserted_at, ^t5),
          messages_15m: fragment("count(*) FILTER (WHERE ? >= ?)", m.inserted_at, ^t15),
          messages_30m: fragment("count(*) FILTER (WHERE ? >= ?)", m.inserted_at, ^t30),
          last_activity_at: max(m.inserted_at)
        }
      )
      |> Repo.all()
      |> Map.new(&{&1.session_id, &1})

    tool_call_counts =
      from(m in Message,
        where: m.session_id in ^session_ids and fragment("? ->> 'type' = 'assistant'", m.data),
        inner_lateral_join:
          block in fragment(
            "jsonb_array_elements(COALESCE(?->'message'->'content', '[]'::jsonb))",
            m.data
          ),
        on: fragment("? ->> 'type' = 'tool_use'", block),
        group_by: m.session_id,
        select: %{
          session_id: m.session_id,
          tool_calls_5m: fragment("count(?) FILTER (WHERE ? >= ?)", block, m.inserted_at, ^t5),
          tool_calls_15m: fragment("count(?) FILTER (WHERE ? >= ?)", block, m.inserted_at, ^t15),
          tool_calls_30m: fragment("count(?) FILTER (WHERE ? >= ?)", block, m.inserted_at, ^t30),
          distinct_tools_15m:
            fragment(
              "count(DISTINCT (? ->> 'name' || ':' || left((? -> 'input')::text, 120))) FILTER (WHERE ? >= ?)",
              block,
              block,
              m.inserted_at,
              ^t15
            ),
          distinct_tools_30m:
            fragment(
              "count(DISTINCT (? ->> 'name' || ':' || left((? -> 'input')::text, 120))) FILTER (WHERE ? >= ?)",
              block,
              block,
              m.inserted_at,
              ^t30
            )
        }
      )
      |> Repo.all()
      |> Map.new(&{&1.session_id, &1})

    session_ids
    |> Enum.uniq()
    |> Map.new(fn id ->
      msgs = Map.get(message_counts, id, %{})
      tools = Map.get(tool_call_counts, id, %{})

      {id,
       %{
         messages_5m: msgs[:messages_5m] || 0,
         messages_15m: msgs[:messages_15m] || 0,
         messages_30m: msgs[:messages_30m] || 0,
         tool_calls_5m: tools[:tool_calls_5m] || 0,
         tool_calls_15m: tools[:tool_calls_15m] || 0,
         tool_calls_30m: tools[:tool_calls_30m] || 0,
         distinct_tools_15m: tools[:distinct_tools_15m] || 0,
         distinct_tools_30m: tools[:distinct_tools_30m] || 0,
         last_activity_at: msgs[:last_activity_at]
       }}
    end)
  end

  @doc """
  The current git HEAD of `directory` (sha, short_sha, committed_at, subject) — a cheap "did
  it actually commit" signal for a session's working directory. Returns `nil`
  silently for a non-repo, a missing directory, or any git failure; never
  raises.
  """
  def git_head_info(directory) do
    case System.cmd("git", ["log", "-1", "--format=%H%n%h%n%cI%n%s"],
           cd: directory,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(String.trim(output), "\n", parts: 4) do
          [sha, short_sha, committed_at, subject] ->
            committed_at =
              case DateTime.from_iso8601(committed_at) do
                {:ok, dt, _} -> dt
                _ -> nil
              end

            %{sha: sha, short_sha: short_sha, committed_at: committed_at, subject: subject}

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp reset_front_of_queue_priority do
    min_priority_query =
      from s in Session,
        where: is_nil(s.archived_at) and s.status == "idle",
        select: min(s.priority)

    case Repo.one(min_priority_query) do
      nil ->
        :ok

      0 ->
        :ok

      min_priority ->
        from(s in Session,
          where: is_nil(s.archived_at) and s.status == "idle" and s.priority == ^min_priority
        )
        |> Repo.update_all(set: [priority: 0])
    end
  end

  def defer_session(%Session{} = session) do
    session
    |> Session.changeset(%{priority: (session.priority || 0) + 1})
    |> Repo.update()
  end

  @doc """
  Lists git commits associated with a session by searching for the OrcaHub-Session trailer.
  Returns a list of maps with :hash, :short_hash, :subject, :author, :date keys.
  """
  def list_session_commits(directory, session_id) do
    git_log_by_grep(directory, "OrcaHub-Session: #{session_id}")
  end

  @doc """
  Lists git commits in `directory`'s history whose message matches
  `grep_term` (passed directly to `git log --grep`). Same output shape as
  `list_session_commits/2` (which is just this with an
  `OrcaHub-Session: <id>` grep term) — reused by `OrcaHub.Issues` to find
  commits tagged with the `OrcaHub-Issue:` trailer (issues_spec.md §4.2).
  """
  def git_log_by_grep(directory, grep_term) do
    args = [
      "log",
      "--all",
      "--grep=#{grep_term}",
      "--format=%H%n%h%n%s%n%an%n%aI",
      "--max-count=50"
    ]

    case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> parse_git_log_output()

      _ ->
        []
    end
  end

  @doc """
  Returns the full commit body and diffstat for a given commit hash.
  """
  def get_commit_detail(directory, hash) do
    with {body, 0} <-
           System.cmd("git", ["log", "-1", "--format=%b", hash],
             cd: directory,
             stderr_to_stdout: true
           ),
         {stat, 0} <-
           System.cmd("git", ["diff-tree", "--stat", "--no-commit-id", "-r", hash],
             cd: directory,
             stderr_to_stdout: true
           ) do
      %{body: String.trim(body), stat: String.trim(stat)}
    else
      _ -> %{body: "", stat: ""}
    end
  end

  defp parse_git_log_output(""), do: []

  defp parse_git_log_output(output) do
    output
    |> String.split("\n")
    |> Enum.chunk_every(5)
    |> Enum.filter(&(length(&1) == 5))
    |> Enum.map(fn [hash, short_hash, subject, author, date] ->
      %{
        hash: hash,
        short_hash: short_hash,
        subject: subject,
        author: author,
        date: date
      }
    end)
  end

  # -------------------------------------------------------------------
  # Churn sample persistence (ORCAHUB3-44)
  # -------------------------------------------------------------------

  alias OrcaHub.Sessions.ChurnSample

  @doc """
  Bulk-insert churn samples.

  Accepts a list of sample maps with the same keys as the ChurnSample schema.
  Uses `insert_all` for efficient batch insertion. `inserted_at`/`updated_at`
  use `timestamps(type: :naive_datetime_usec)`, so `NaiveDateTime.utc_now()`
  (microsecond precision) is dumped as-is. `sampled_at` is `:utc_datetime`
  (second precision) — callers must pass an already-truncated
  `DateTime.utc_now() |> DateTime.truncate(:second)`, since `insert_all`
  dumps values straight through the schema's field types with no casting.
  """
  def insert_churn_samples([]), do: {0, nil}

  def insert_churn_samples(samples) when is_list(samples) do
    now = NaiveDateTime.utc_now()

    samples_with_timestamps =
      Enum.map(samples, fn attrs ->
        Map.put(attrs, :inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(ChurnSample, samples_with_timestamps)
  end

  @doc """
  Prune churn samples older than `older_than_days` (default 14).

  Used by the churn sampler to keep the table size bounded.
  """
  def prune_churn_samples(older_than_days \\ 14) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-older_than_days, :day)
      |> DateTime.truncate(:second)

    from(c in ChurnSample, where: c.sampled_at < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  List churn samples for a specific session, newest first.

  Used for querying historical churn data for a session.
  """
  def list_churn_samples(session_id) when is_binary(session_id) do
    from(c in ChurnSample,
      where: c.session_id == ^session_id,
      order_by: [desc: c.sampled_at]
    )
    |> Repo.all()
  end

  @doc """
  List all running (non-archived) sessions.

  Used by the churn sampler to determine which sessions to assess.
  """
  def list_running_sessions do
    from(s in Session,
      where: is_nil(s.archived_at),
      where: s.status == "running"
    )
    |> Repo.all()
  end

  @doc """
  Attaches a session to a parent session.

  Sets `parent_session_id` to `parent_id` and (unless `opts[:notify] == false`)
  sets `notify_parent: true`. Works whether or not the session already has a parent
  (implicit re-parent).

  Returns:
    - `{:ok, %{session: %Session{}, previous_parent_id: binary() | nil}}`
    - `{:error, :session_not_found | :parent_not_found | :self_parent | :cycle | Ecto.Changeset.t()}`

  Guards:
    - `parent_id == session_id` -> `{:error, :self_parent}`
    - If `session_id` is an ANCESTOR of `parent_id` -> `{:error, :cycle}`
    - Nonexistent ids -> `:session_not_found` / `:parent_not_found`
  """
  @spec attach_session(binary(), binary(), keyword()) ::
          {:ok, %{session: %Session{}, previous_parent_id: binary() | nil}}
          | {:error,
             :session_not_found | :parent_not_found | :self_parent | :cycle | Ecto.Changeset.t()}
  def attach_session(session_id, parent_id, opts \\ [])
      when is_binary(session_id) and is_binary(parent_id) do
    result =
      cond do
        session_id == parent_id ->
          {:error, :self_parent}

        true ->
          session = Repo.get(Session, session_id)

          if is_nil(session) do
            {:error, :session_not_found}
          else
            parent = Repo.get(Session, parent_id)

            if is_nil(parent) do
              {:error, :parent_not_found}
            else
              if ancestor_in_chain?(session_id, parent_id, 0) do
                {:error, :cycle}
              else
                previous_parent_id = session.parent_session_id

                notify_parent? = Keyword.get(opts, :notify, true)

                result =
                  session
                  |> Session.changeset(%{
                    parent_session_id: parent_id,
                    notify_parent: notify_parent?
                  })
                  |> Repo.update()

                case result do
                  {:ok, updated_session} ->
                    if previous_parent_id && previous_parent_id != parent_id do
                      record_session_interaction(session_id, previous_parent_id, "detach")
                    end

                    record_session_interaction(session_id, parent_id, "attach")

                    broadcast_parentage_change(
                      session_id,
                      previous_parent_id,
                      parent_id,
                      updated_session.archived_at
                    )

                    {:ok, %{session: updated_session, previous_parent_id: previous_parent_id}}

                  {:error, changeset} ->
                    {:error, changeset}
                end
              end
            end
          end
      end

    result
  end

  @doc """
  Detaches a session from its parent.

  Sets `parent_session_id: nil`. Leaves `notify_parent` alone — it is meaningless
  without a parent. Detaching an already-parentless session is an IDEMPOTENT SUCCESS
  returning `previous_parent_id: nil`, NOT an error.

  Returns:
    - `{:ok, %{session: %Session{}, previous_parent_id: binary() | nil}}`
    - `{:error, :session_not_found | Ecto.Changeset.t()}`
  """
  @spec detach_session(binary(), keyword()) ::
          {:ok, %{session: %Session{}, previous_parent_id: binary() | nil}}
          | {:error, :session_not_found | Ecto.Changeset.t()}
  def detach_session(session_id, _opts \\ []) when is_binary(session_id) do
    session = Repo.get(Session, session_id)

    if is_nil(session) do
      {:error, :session_not_found}
    else
      previous_parent_id = session.parent_session_id

      # Detaching an already-parentless session is an idempotent success
      if is_nil(previous_parent_id) do
        {:ok, %{session: session, previous_parent_id: nil}}
      else
        # Perform the update
        result =
          session
          |> Session.changeset(%{
            parent_session_id: nil
          })
          |> Repo.update()

        case result do
          {:ok, updated_session} ->
            # Record detach edge only if there was a previous parent
            record_session_interaction(session_id, previous_parent_id, "detach")

            # Broadcast parentage change
            broadcast_parentage_change(
              session_id,
              previous_parent_id,
              nil,
              updated_session.archived_at
            )

            {:ok, %{session: updated_session, previous_parent_id: previous_parent_id}}

          {:error, changeset} ->
            {:error, changeset}
        end
      end
    end
  end

  # Helper: checks if session_id is an ancestor of any session in the chain
  # starting from parent_id, walking up via parent_session_id.
  # Depth cap of 64 to prevent infinite loops on corrupt data.
  defp ancestor_in_chain?(_session_id, _parent_id, depth) when depth >= 64 do
    # Depth cap reached - assume no cycle to avoid hanging
    false
  end

  defp ancestor_in_chain?(session_id, parent_id, depth) do
    case Repo.get(Session, parent_id) do
      nil ->
        false

      parent ->
        if parent.id == session_id do
          true
        else
          case parent.parent_session_id do
            nil ->
              false

            next_id ->
              ancestor_in_chain?(session_id, next_id, depth + 1)
          end
        end
    end
  end

  # Helper: best-effort session interaction recording
  defp record_session_interaction(sender_id, recipient_id, kind) do
    attrs = %{sender_session_id: sender_id, recipient_session_id: recipient_id, kind: kind}

    case SessionInteraction.changeset(%SessionInteraction{}, attrs) |> Repo.insert() do
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("Failed to record session interaction: #{inspect(changeset.errors)}")

      _ ->
        :ok
    end
  end

  # Helper: broadcast parentage change event
  defp broadcast_parentage_change(session_id, previous_parent_id, new_parent_id, archived_at) do
    payload = %{
      session_id: session_id,
      previous_parent_id: previous_parent_id,
      new_parent_id: new_parent_id,
      archived_at: archived_at
    }

    # Broadcast on global "sessions" topic
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "sessions",
      {session_id, {:parentage_changed, payload}}
    )

    # Broadcast on per-session topics for child, old parent, new parent
    ids =
      [session_id, previous_parent_id, new_parent_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.each(ids, fn id ->
      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        "session:#{id}",
        {session_id, {:parentage_changed, payload}}
      )
    end)
  end
end
