defmodule OrcaHub.UpstreamServers do
  import Ecto.Query
  alias OrcaHub.{Repo, UpstreamServers.UpstreamServer}

  def list_upstream_servers do
    Repo.all(from s in UpstreamServer, order_by: [asc: s.name])
  end

  def list_enabled_upstream_servers do
    Repo.all(from s in UpstreamServer, where: s.enabled == true, order_by: [asc: s.name])
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

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "upstream_servers", :upstream_servers_changed)
  end
end
