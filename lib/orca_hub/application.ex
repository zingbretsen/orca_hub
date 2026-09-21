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
      # One entry per watched job (OrcaHub.JobWatcher) — see OrcaHub.Jobs.
      {Registry, keys: :unique, name: OrcaHub.JobRegistry},
      # TTL cache for node-dependent backend facts (installed CLIs, pi's live
      # model catalog) — see OrcaHub.Backend.Cache.
      OrcaHub.Backend.Cache,
      {Task.Supervisor, name: OrcaHub.TaskSupervisor},
      OrcaHub.SessionHeartbeat,
      # Periodic churn sampling for ORCAHUB3-44 — hub-only, emits telemetry for Grafana.
      OrcaHub.ChurnSampler,
      # Reconciles the pgvector issue index for writes whose inline reindex
      # never completed. Hub-only for ChurnSampler's reason — two nodes
      # sweeping one table would duplicate the work and race each other's
      # upserts. Bounded per tick; see OrcaHub.Issues.IndexSweep moduledoc.
      OrcaHub.Issues.IndexSweep,
      # Bounded Task.Supervisor for the write-hook reindexes (max_children):
      # a batch of issue writes must not become one request per write to the
      # shared embedding box. Overflow is dropped and reconciled by the sweep
      # above — see OrcaHub.Issues.Indexer.reindex_async/1.
      OrcaHub.Issues.Indexer.task_supervisor_spec(),
      # Hourly resolution of opted-in pi providers' model lists from the
      # local LLM gateway's /v1/models. Hub-only for ChurnSampler's reason
      # plus two of its own: only the hub owns the DB, and agent pods can't
      # reach the gateway at all. The resulting PiConfig write fans out to
      # every node through the existing {:pi_config_updated} broadcast.
      # See OrcaHub.PiModelSync moduledoc.
      OrcaHub.PiModelSync,
      # Warm-process admission control — must start before SessionSupervisor so
      # streaming runners can request_slot at port-open.
      OrcaHub.Streaming.WarmPool,
      OrcaHub.SessionSupervisor,
      # Auto-resumes this node's own sessions orphaned in `status: "running"`
      # by a node restart (deploy). See OrcaHub.SessionResumer moduledoc.
      OrcaHub.SessionResumer,
      # Hub-only, cluster-wide cleanup of memory-extraction children orphaned
      # by a restart landing before SessionRunner's self-archive hook ran.
      # See OrcaHub.MemoryExtractionSweep moduledoc.
      OrcaHub.MemoryExtractionSweep,
      # Serializes forked pi children's first turns (pi_fork_spec.md §6).
      # Runs on hub + agent — a fork child runs wherever its parent does.
      OrcaHub.ForkGate,
      OrcaHub.TerminalSupervisor,
      # Per-node DynamicSupervisor for OrcaHub.JobWatcher processes — the
      # detached OS processes themselves are NOT children of this
      # supervisor (see OrcaHub.Jobs.Launcher); it only supervises the
      # disposable watchers that observe them.
      OrcaHub.JobSupervisor,
      # Re-attaches job watchers orphaned by this restart — the job-subsystem
      # analog of OrcaHub.SessionResumer above. See OrcaHub.JobResumer moduledoc.
      OrcaHub.JobResumer,
      OrcaHub.LoginSupervisor,
      {Registry, keys: :unique, name: OrcaHub.BackendInstallerRegistry},
      OrcaHub.BackendInstallerSupervisor,
      {DynamicSupervisor, name: OrcaHub.MCPSupervisor, strategy: :one_for_one},
      # Serializes (re)generation of the global `Tools` surface for code-exec
      # sessions. Idle until the first run_elixir on this node.
      OrcaHub.MCP.CodeExec.Generator,
      # Per-session run_elixir variable bindings (REPL persistence). Must run
      # on both hub and agent nodes — code-exec sessions run on either.
      OrcaHub.MCP.CodeExec.BindingStore,
      # Materializes hub-managed global skills onto this node's disk for
      # every installed backend CLI. Runs on hub + agent — see
      # OrcaHub.SkillSync moduledoc.
      OrcaHub.SkillSync,
      # Materializes hub-managed pi config (providers/settings/extensions/
      # prompts/themes) into this node's ~/.pi/agent. Runs on hub + agent —
      # see OrcaHub.PiConfigSync moduledoc.
      OrcaHub.PiConfigSync,
      # Serializes per-node agent-memory git snapshot+sync passes, triggered
      # by SessionRunner idle transitions. Runs on hub + agent — see
      # OrcaHub.MemoryGit.Server moduledoc.
      OrcaHub.MemoryGit.Server,
      OrcaHub.MCP.UpstreamClient,
      OrcaHub.Scheduler,
      OrcaHub.TriggerLoader,
      # Inbound email ingestion (OrcaHub.EmailInbox.*). Hub-only, like the
      # scheduler above: agent nodes must never poll a mailbox — an inbox's
      # credentials and its watermark are hub state, and two nodes polling
      # the same mailbox would race to fire the same trigger twice.
      {Registry, keys: :unique, name: OrcaHub.EmailInboxRegistry},
      OrcaHub.EmailInboxSupervisor,
      OrcaHub.EmailInboxLoader,
      OrcaHub.ClusterNodeTracker,
      # Dials out to every `nodes` row flagged `dial: true` — see
      # OrcaHub.NodeDialer moduledoc. Hub-only: agents never dial out on
      # their own.
      OrcaHub.NodeDialer,
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
      # One entry per watched job (OrcaHub.JobWatcher) — see OrcaHub.Jobs.
      {Registry, keys: :unique, name: OrcaHub.JobRegistry},
      # TTL cache for node-dependent backend facts (installed CLIs, pi's live
      # model catalog) — see OrcaHub.Backend.Cache.
      OrcaHub.Backend.Cache,
      {Task.Supervisor, name: OrcaHub.TaskSupervisor},
      # Warm-process admission control — must start before SessionSupervisor.
      OrcaHub.Streaming.WarmPool,
      OrcaHub.SessionSupervisor,
      # Auto-resumes this node's own sessions orphaned in `status: "running"`
      # by a node restart (deploy). See OrcaHub.SessionResumer moduledoc.
      OrcaHub.SessionResumer,
      # Serializes forked pi children's first turns (pi_fork_spec.md §6) —
      # see the matching hub_children/1 comment above.
      OrcaHub.ForkGate,
      OrcaHub.TerminalSupervisor,
      # Per-node DynamicSupervisor for OrcaHub.JobWatcher processes — see
      # the matching hub_children/1 comment above.
      OrcaHub.JobSupervisor,
      # Re-attaches job watchers orphaned by this restart. See
      # OrcaHub.JobResumer moduledoc.
      OrcaHub.JobResumer,
      OrcaHub.LoginSupervisor,
      {Registry, keys: :unique, name: OrcaHub.BackendInstallerRegistry},
      OrcaHub.BackendInstallerSupervisor,
      {DynamicSupervisor, name: OrcaHub.MCPSupervisor, strategy: :one_for_one},
      # Serializes (re)generation of the global `Tools` surface for code-exec
      # sessions. Idle until the first run_elixir on this node.
      OrcaHub.MCP.CodeExec.Generator,
      # Per-session run_elixir variable bindings (REPL persistence). Must run
      # on both hub and agent nodes — code-exec sessions run on either.
      OrcaHub.MCP.CodeExec.BindingStore,
      # Materializes hub-managed global skills onto this node's disk for
      # every installed backend CLI. Runs on hub + agent — see
      # OrcaHub.SkillSync moduledoc.
      OrcaHub.SkillSync,
      # Materializes hub-managed pi config (providers/settings/extensions/
      # prompts/themes) into this node's ~/.pi/agent. Runs on hub + agent —
      # see OrcaHub.PiConfigSync moduledoc.
      OrcaHub.PiConfigSync,
      # Serializes per-node agent-memory git snapshot+sync passes, triggered
      # by SessionRunner idle transitions. Runs on hub + agent — see
      # OrcaHub.MemoryGit.Server moduledoc.
      OrcaHub.MemoryGit.Server,
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
