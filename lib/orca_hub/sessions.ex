defmodule OrcaHub.Sessions do
  @moduledoc """
  Context for managing Claude sessions and their messages.
  """

  import Ecto.Query

  alias OrcaHub.{
    AgentPresence,
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
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

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

  def delete_session(%Session{} = session), do: Repo.delete(session)

  def list_messages(session_id) do
    Repo.all(
      from m in Message, where: m.session_id == ^session_id, order_by: [asc: m.inserted_at]
    )
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
  :sender_session_id, :recipient_session_id, and :since (only edges with
  inserted_at >= since) — all optional, combinable.
  """
  def list_session_interactions(opts \\ []) do
    from(i in SessionInteraction, order_by: [desc: i.inserted_at])
    |> filter_interactions_by_sender(opts[:sender_session_id])
    |> filter_interactions_by_recipient(opts[:recipient_session_id])
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
  Sessions for the `/sessions/tree` spawn-forest page. `:recent` (default)
  returns non-archived sessions plus sessions archived/updated within the
  last 24h; `:all` is the "full history" toggle — every session, no
  archived/time bound. Unlike `list_sessions/1`, there's no :manual/
  :automated/:orchestrator split here — the tree page shows everything so
  parent/child chains aren't broken by an unrelated filter hiding a link
  in the chain.
  """
  def list_sessions_for_tree(scope \\ :recent)

  def list_sessions_for_tree(:all) do
    from(s in Session,
      left_join: p in assoc(s, :project),
      where: is_nil(s.project_id) or is_nil(p.deleted_at),
      preload: [project: p],
      order_by: [desc: s.updated_at]
    )
    |> Repo.all()
  end

  def list_sessions_for_tree(:recent) do
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-24 * 3600, :second)

    from(s in Session,
      left_join: p in assoc(s, :project),
      where: is_nil(s.project_id) or is_nil(p.deleted_at),
      where: is_nil(s.archived_at) or s.updated_at >= ^cutoff,
      preload: [project: p],
      order_by: [desc: s.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Bulk id -> title lookup, one query regardless of list size. Powers the
  `/sessions/tree` message-edge overlay resolving the title of the far end
  of an edge whose session got filtered out of the visible set — a single
  extra fetch for the whole page, never per-chip.
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
  Powers the `/sessions/tree` page's lazy, per-session "Subagents"
  disclosure — called on-demand for one session at a time, never for the
  whole visible set up front.
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

  defp filter_interactions_by_sender(q, nil), do: q

  defp filter_interactions_by_sender(q, sender_id),
    do: from(i in q, where: i.sender_session_id == ^sender_id)

  defp filter_interactions_by_recipient(q, nil), do: q

  defp filter_interactions_by_recipient(q, recipient_id),
    do: from(i in q, where: i.recipient_session_id == ^recipient_id)

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

    last_messages =
      from m in Message,
        where: fragment("? ->> 'type' = 'assistant'", m.data),
        distinct: m.session_id,
        order_by: [asc: m.session_id, desc: m.inserted_at]

    Repo.all(
      from s in Session,
        left_join: m in subquery(last_messages),
        on: m.session_id == s.id,
        left_join: p in assoc(s, :project),
        where:
          is_nil(s.archived_at) and s.status in ["idle", "waiting"] and
            is_nil(s.parent_session_id),
        order_by: [asc: s.priority, asc: s.updated_at],
        preload: [project: p],
        select: {s, m}
    )
  end

  @doc """
  Return the text of the most recent assistant message for a session, or `nil`
  if there is none (or it carried no text blocks — e.g. only tool_use).

  Used by the Discord worker to post a session's reply back to the channel.
  """
  def last_assistant_text(session_id) do
    from(m in Message,
      where: m.session_id == ^session_id and fragment("? ->> 'type' = 'assistant'", m.data),
      order_by: [desc: m.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> extract_assistant_text()
  end

  defp extract_assistant_text(nil), do: nil

  defp extract_assistant_text(%Message{data: data}) do
    text =
      data
      |> get_in(["message", "content"])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) && &1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    if text == "", do: nil, else: text
  end

  # How many recent assistant messages to scan for tool_use blocks — bounds
  # query cost regardless of how long the session's history is.
  @tail_scan_limit 50

  @doc """
  A slim, read-only "tail" for a session: its last assistant text message plus
  the last `tool_call_limit` tool calls (name + raw input, oldest to newest) —
  without touching the live SessionRunner. Powers `get_session_tail` (an
  orchestrator progress peek that doesn't interrupt the worker, unlike
  `send_message_to_session`).
  """
  def session_tail(session_id, opts \\ []) do
    limit = Keyword.get(opts, :tool_call_limit, 10)

    %{
      last_assistant_text: last_assistant_text(session_id),
      recent_tool_calls: recent_tool_calls(session_id, limit)
    }
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
    |> Enum.take(-limit)
  end

  defp tool_use_blocks(%Message{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
    |> Enum.map(&%{name: &1["name"], input: &1["input"]})
  end

  # Bucket windows (minutes) for activity_metadata/1.
  @activity_buckets [5, 15, 30]

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
          tool_calls_30m: fragment("count(?) FILTER (WHERE ? >= ?)", block, m.inserted_at, ^t30)
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
         last_activity_at: msgs[:last_activity_at]
       }}
    end)
  end

  @doc """
  The current git HEAD of `directory` (sha, short_sha, subject) — a cheap "did
  it actually commit" signal for a session's working directory. Returns `nil`
  silently for a non-repo, a missing directory, or any git failure; never
  raises.
  """
  def git_head_info(directory) do
    case System.cmd("git", ["log", "-1", "--format=%H%n%h%n%s"],
           cd: directory,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(String.trim(output), "\n", parts: 3) do
          [sha, short_sha, subject] -> %{sha: sha, short_sha: short_sha, subject: subject}
          _ -> nil
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
    args = [
      "log",
      "--all",
      "--grep=OrcaHub-Session: #{session_id}",
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
end
