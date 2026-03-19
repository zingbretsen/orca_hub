defmodule OrcaHub.UpstreamServers do
  import Ecto.Query
  alias OrcaHub.{Repo, UpstreamServers.UpstreamServer, UpstreamServers.ProjectUpstreamServer, UpstreamServers.SessionUpstreamServer}

  # ── Global server CRUD ────────────────────────────────────────────────

  def list_upstream_servers do
    Repo.all(from s in UpstreamServer, order_by: [asc: s.name])
  end

  def list_enabled_upstream_servers do
    Repo.all(from s in UpstreamServer, where: s.enabled == true and s.global == true, order_by: [asc: s.name])
  end

  def get_upstream_server!(id), do: Repo.get!(UpstreamServer, id)

  def create_upstream_server(attrs) do
    result =
      %UpstreamServer{}
      |> UpstreamServer.changeset(attrs)
      |> Repo.insert()

    with {:ok, _server} <- result do
      notify_change()
    end

    result
  end

  def update_upstream_server(%UpstreamServer{} = server, attrs) do
    result =
      server
      |> UpstreamServer.changeset(attrs)
      |> Repo.update()

    with {:ok, _server} <- result do
      notify_change()
    end

    result
  end

  def delete_upstream_server(%UpstreamServer{} = server) do
    result = Repo.delete(server)

    with {:ok, _} <- result do
      notify_change()
    end

    result
  end

  def change_upstream_server(%UpstreamServer{} = server, attrs \\ %{}) do
    UpstreamServer.changeset(server, attrs)
  end

  # ── Project associations ──────────────────────────────────────────────

  def list_servers_for_project(project_id) do
    Repo.all(
      from s in UpstreamServer,
        join: ps in ProjectUpstreamServer,
        on: ps.upstream_server_id == s.id and ps.project_id == ^project_id,
        order_by: [asc: s.name]
    )
  end

  def list_enabled_servers_for_project(project_id) do
    Repo.all(
      from s in UpstreamServer,
        join: ps in ProjectUpstreamServer,
        on: ps.upstream_server_id == s.id and ps.project_id == ^project_id,
        where: s.enabled == true,
        order_by: [asc: s.name]
    )
  end

  def add_server_to_project(project_id, server_id) do
    %ProjectUpstreamServer{}
    |> ProjectUpstreamServer.changeset(%{project_id: project_id, upstream_server_id: server_id})
    |> Repo.insert()
  end

  def remove_server_from_project(project_id, server_id) do
    Repo.delete_all(
      from ps in ProjectUpstreamServer,
        where: ps.project_id == ^project_id and ps.upstream_server_id == ^server_id
    )
  end

  def server_in_project?(project_id, server_id) do
    Repo.exists?(
      from ps in ProjectUpstreamServer,
        where: ps.project_id == ^project_id and ps.upstream_server_id == ^server_id
    )
  end

  # ── Session associations ──────────────────────────────────────────────

  def list_servers_for_session(session_id) do
    Repo.all(
      from s in UpstreamServer,
        join: ss in SessionUpstreamServer,
        on: ss.upstream_server_id == s.id and ss.session_id == ^session_id,
        order_by: [asc: s.name]
    )
  end

  def list_enabled_servers_for_session(session_id) do
    Repo.all(
      from s in UpstreamServer,
        join: ss in SessionUpstreamServer,
        on: ss.upstream_server_id == s.id and ss.session_id == ^session_id,
        where: s.enabled == true,
        order_by: [asc: s.name]
    )
  end

  def add_server_to_session(session_id, server_id) do
    %SessionUpstreamServer{}
    |> SessionUpstreamServer.changeset(%{session_id: session_id, upstream_server_id: server_id})
    |> Repo.insert()
  end

  def remove_server_from_session(session_id, server_id) do
    Repo.delete_all(
      from ss in SessionUpstreamServer,
        where: ss.session_id == ^session_id and ss.upstream_server_id == ^server_id
    )
  end

  def server_in_session?(session_id, server_id) do
    Repo.exists?(
      from ss in SessionUpstreamServer,
        where: ss.session_id == ^session_id and ss.upstream_server_id == ^server_id
    )
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "upstream_servers", :upstream_servers_changed)
  end
end
