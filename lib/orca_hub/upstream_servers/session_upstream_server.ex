defmodule OrcaHub.UpstreamServers.SessionUpstreamServer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_upstream_servers" do
    belongs_to :session, OrcaHub.Sessions.Session
    belongs_to :upstream_server, OrcaHub.UpstreamServers.UpstreamServer

    timestamps()
  end

  def changeset(session_upstream_server, attrs) do
    session_upstream_server
    |> cast(attrs, [:session_id, :upstream_server_id])
    |> validate_required([:session_id, :upstream_server_id])
    |> unique_constraint([:session_id, :upstream_server_id])
  end
end
