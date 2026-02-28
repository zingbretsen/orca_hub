defmodule OrcaHub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OrcaHubWeb.Telemetry,
      OrcaHub.Repo,
      {DNSCluster, query: Application.get_env(:orca_hub, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OrcaHub.PubSub},
      {Registry, keys: :unique, name: OrcaHub.SessionRegistry},
      OrcaHub.SessionSupervisor,
      OrcaHubWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OrcaHub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OrcaHubWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
