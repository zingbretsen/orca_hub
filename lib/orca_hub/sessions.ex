defmodule OrcaHub.Sessions do
  import Ecto.Query
  alias OrcaHub.{Repo, Sessions.Session, Sessions.Message}

  def list_sessions do
    Repo.all(from s in Session, where: is_nil(s.archived_at), order_by: [asc: s.directory, desc: s.updated_at])
  end

  def archive_session(%Session{} = session) do
    session
    |> Session.changeset(%{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
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
