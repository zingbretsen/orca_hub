defmodule OrcaHub.Sessions do
  import Ecto.Query
  alias OrcaHub.{Repo, Sessions.Session, Sessions.Message}

  def list_sessions(filter \\ :manual) do
    query =
      from s in Session,
        where: is_nil(s.archived_at),
        preload: [:project],
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

  def get_session(id), do: Repo.get(Session, id)

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

  def count_idle_sessions do
    Repo.one(
      from s in Session,
        where: is_nil(s.archived_at) and s.status == "idle",
        select: count(s.id)
    )
  end

  def list_idle_sessions_with_last_assistant_message do
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
        order_by: [asc: s.updated_at],
        select: {s, m}
    )
  end
end
