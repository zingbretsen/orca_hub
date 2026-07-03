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

    base_children =
      if OrcaHub.Mode.hub?() do
        hub_children(topologies)
      else
        agent_children(topologies)
      end

    # The Discord worker is gated behind DISCORD_BOT + DISCORD_BOT_TOKEN, so
    # this is `[]` on every node except the dedicated Discord agent. Appending
    # to the tail keeps nostrum inert everywhere else (see OrcaHub.Discord).
    children = base_children ++ OrcaHub.Discord.children()

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
      # Duplicate-keys: one entry per LiveView currently viewing a session.
      # Consulted by the delayed abandoned-session cleanup (SessionLive.Show)
      # so a page reload doesn't archive a session someone is still looking at.
      {Registry, keys: :duplicate, name: OrcaHub.SessionViewersRegistry},
      {Task.Supervisor, name: OrcaHub.TaskSupervisor},
      OrcaHub.SessionHeartbeat,
      # Warm-process admission control — must start before SessionSupervisor so
      # streaming runners can request_slot at port-open.
      OrcaHub.Streaming.WarmPool,
      OrcaHub.SessionSupervisor,
      OrcaHub.TerminalSupervisor,
      OrcaHub.LoginSupervisor,
      {DynamicSupervisor, name: OrcaHub.MCPSupervisor, strategy: :one_for_one},
      # Serializes (re)generation of the global `Tools` surface for code-exec
      # sessions. Idle until the first run_elixir on this node.
      OrcaHub.MCP.CodeExec.Generator,
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
      # Duplicate-keys: one entry per LiveView currently viewing a session.
      # Consulted by the delayed abandoned-session cleanup (SessionLive.Show)
      # so a page reload doesn't archive a session someone is still looking at.
      {Registry, keys: :duplicate, name: OrcaHub.SessionViewersRegistry},
      {Task.Supervisor, name: OrcaHub.TaskSupervisor},
      # Warm-process admission control — must start before SessionSupervisor.
      OrcaHub.Streaming.WarmPool,
      OrcaHub.SessionSupervisor,
      OrcaHub.TerminalSupervisor,
      OrcaHub.LoginSupervisor,
      {DynamicSupervisor, name: OrcaHub.MCPSupervisor, strategy: :one_for_one},
      # Serializes (re)generation of the global `Tools` surface for code-exec
      # sessions. Idle until the first run_elixir on this node.
      OrcaHub.MCP.CodeExec.Generator,
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
