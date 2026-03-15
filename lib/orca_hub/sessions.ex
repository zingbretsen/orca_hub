defmodule OrcaHub.Sessions do
  import Ecto.Query
  alias OrcaHub.{AgentPresence, Repo, Sessions.Session, Sessions.Message}

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
      end

    Repo.all(query)
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

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  def delete_session(%Session{} = session), do: Repo.delete(session)

  def list_messages(session_id) do
    Repo.all(from m in Message, where: m.session_id == ^session_id, order_by: [asc: m.inserted_at])
  end

  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  def search(query) do
    like = "%#{query}%"

    Repo.all(
      from s in Session,
        where: is_nil(s.archived_at) and (ilike(s.title, ^like) or ilike(s.directory, ^like)),
        preload: [:project],
        order_by: [desc: s.updated_at],
        limit: 5
    )
  end

  def search_sessions_by_directory(directory, opts \\ %{}) do
    query = opts[:query]
    status = opts[:status]
    include_archived = opts[:include_archived] || false
    archived_only = opts[:archived_only] || false
    limit = opts[:limit] || 20

    q =
      from s in Session,
        where: s.directory == ^directory,
        preload: [:project],
        order_by: [desc: s.updated_at],
        limit: ^limit

    q =
      cond do
        archived_only -> from(s in q, where: not is_nil(s.archived_at))
        include_archived -> q
        true -> from(s in q, where: is_nil(s.archived_at))
      end
    q = if query, do: from(s in q, where: ilike(s.title, ^"%#{query}%")), else: q
    q = if status, do: from(s in q, where: s.status == ^status), else: q

    Repo.all(q)
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
        where: is_nil(s.archived_at) and s.status == "idle",
        order_by: [asc: s.priority, asc: s.updated_at],
        select: {s, m}
    )
    |> Enum.map(fn {session, message} -> {Repo.preload(session, :project), message} end)
  end

  defp reset_front_of_queue_priority do
    min_priority_query =
      from s in Session,
        where: is_nil(s.archived_at) and s.status == "idle",
        select: min(s.priority)

    case Repo.one(min_priority_query) do
      nil -> :ok
      0 -> :ok
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
      "log", "--all",
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
    with {body, 0} <- System.cmd("git", ["log", "-1", "--format=%b", hash], cd: directory, stderr_to_stdout: true),
         {stat, 0} <- System.cmd("git", ["diff-tree", "--stat", "--no-commit-id", "-r", hash], cd: directory, stderr_to_stdout: true) do
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
