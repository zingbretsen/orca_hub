defmodule OrcaHub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    File.mkdir_p!("log")

    :logger.add_handler(:file_log, :logger_std_h, %{
      config: %{file: ~c"log/dev.log"},
      formatter:
        Logger.Formatter.new(
          format: "$date $time [$level] $message\n",
          colors: [enabled: false]
        )
    })

    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      if OrcaHub.Mode.hub?() do
        hub_children(topologies)
      else
        agent_children(topologies)
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OrcaHub.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Clean up stale .agents/ presence files from previous runs
    if OrcaHub.Mode.hub?() do
      Task.start(fn -> OrcaHub.AgentPresence.cleanup_all_stale() end)
    end

    result
  end

  defp hub_children(topologies) do
    [
      OrcaHubWeb.Telemetry,
      OrcaHub.Repo,
      {DNSCluster, query: Application.get_env(:orca_hub, :dns_cluster_query) || :ignore},
      {Cluster.Supervisor, [topologies, [name: OrcaHub.ClusterSupervisor]]},
      {Phoenix.PubSub, name: OrcaHub.PubSub},
      {Registry, keys: :unique, name: OrcaHub.SessionRegistry},
      {Registry, keys: :unique, name: OrcaHub.MCPRegistry},
      {Registry, keys: :unique, name: OrcaHub.TerminalRegistry},
      {Task.Supervisor, name: OrcaHub.TaskSupervisor},
      OrcaHub.SessionHeartbeat,
      OrcaHub.SessionSupervisor,
      OrcaHub.TerminalSupervisor,
      {DynamicSupervisor, name: OrcaHub.MCPSupervisor, strategy: :one_for_one},
      OrcaHub.MCP.UpstreamClient,
      OrcaHub.Scheduler,
      OrcaHub.TriggerLoader,
      OrcaHubWeb.Endpoint
    ]
  end

  defp agent_children(topologies) do
    [
      {DNSCluster, query: Application.get_env(:orca_hub, :dns_cluster_query) || :ignore},
      {Cluster.Supervisor, [topologies, [name: OrcaHub.ClusterSupervisor]]},
      {Phoenix.PubSub, name: OrcaHub.PubSub},
      {Registry, keys: :unique, name: OrcaHub.SessionRegistry},
      {Registry, keys: :unique, name: OrcaHub.MCPRegistry},
      {Registry, keys: :unique, name: OrcaHub.TerminalRegistry},
      {Task.Supervisor, name: OrcaHub.TaskSupervisor},
      OrcaHub.SessionSupervisor,
      OrcaHub.TerminalSupervisor,
      {DynamicSupervisor, name: OrcaHub.MCPSupervisor, strategy: :one_for_one},
      # Agent needs a local HTTP endpoint for MCP (Claude CLI connects to it)
      OrcaHubWeb.Endpoint
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OrcaHubWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
