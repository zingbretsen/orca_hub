defmodule OrcaHub.Sessions do
  import Ecto.Query
  alias OrcaHub.{Repo, Sessions.Session, Sessions.Message}

  def list_sessions do
    Repo.all(from s in Session, order_by: [desc: s.inserted_at])
  end

  def get_session!(id), do: Repo.get!(Session, id)

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
end
