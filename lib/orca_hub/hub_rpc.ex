defmodule OrcaHub.HubRPC do
  @moduledoc """
  Proxies database operations to the hub node.

  In hub mode, calls are executed locally. In agent mode, calls are
  forwarded to the hub node via `:erpc`. This allows SessionRunner
  and other modules on agent nodes to persist data without a local database.
  """

  alias OrcaHub.Mode

  @timeout 10_000

  @doc """
  Call a function on the hub node. If this IS the hub, just calls locally.
  """
  def call(mod, fun, args) do
    if Mode.hub?() do
      apply(mod, fun, args)
    else
      hub = Mode.hub_node()
      :erpc.call(hub, mod, fun, args, @timeout)
    end
  end

  # -------------------------------------------------------------------
  # Sessions
  # -------------------------------------------------------------------

  def get_session!(id), do: call(OrcaHub.Sessions, :get_session!, [id])
  def get_session(id), do: call(OrcaHub.Sessions, :get_session, [id])
  def create_session(attrs), do: call(OrcaHub.Sessions, :create_session, [attrs])

  def update_session(session, attrs),
    do: call(OrcaHub.Sessions, :update_session, [session, attrs])

  def delete_session(session), do: call(OrcaHub.Sessions, :delete_session, [session])
  def archive_session(session), do: call(OrcaHub.Sessions, :archive_session, [session])
  def unarchive_session(session), do: call(OrcaHub.Sessions, :unarchive_session, [session])
  def defer_session(session), do: call(OrcaHub.Sessions, :defer_session, [session])
  def list_sessions(filter \\ :manual), do: call(OrcaHub.Sessions, :list_sessions, [filter])
  def list_messages(session_id), do: call(OrcaHub.Sessions, :list_messages, [session_id])
  def create_message(attrs), do: call(OrcaHub.Sessions, :create_message, [attrs])
  def count_idle_sessions, do: call(OrcaHub.Sessions, :count_idle_sessions, [])

  def list_idle_sessions_with_last_assistant_message,
    do: call(OrcaHub.Sessions, :list_idle_sessions_with_last_assistant_message, [])

  def last_assistant_text(session_id),
    do: call(OrcaHub.Sessions, :last_assistant_text, [session_id])

  def search(query, opts \\ []), do: call(OrcaHub.Sessions, :search, [query, opts])

  def search_sessions_by_directory(directory, opts \\ %{}),
    do: call(OrcaHub.Sessions, :search_sessions_by_directory, [directory, opts])

  def search_all_sessions(opts \\ %{}),
    do: call(OrcaHub.Sessions, :search_all_sessions, [opts])

  def get_adjacent_session_ids(session),
    do: call(OrcaHub.Sessions, :get_adjacent_session_ids, [session])

  def list_session_commits(directory, session_id),
    do: call(OrcaHub.Sessions, :list_session_commits, [directory, session_id])

  def get_commit_detail(directory, hash),
    do: call(OrcaHub.Sessions, :get_commit_detail, [directory, hash])

  # -------------------------------------------------------------------
  # Projects
  # -------------------------------------------------------------------

  def list_projects, do: call(OrcaHub.Projects, :list_projects, [])
  def get_project!(id), do: call(OrcaHub.Projects, :get_project!, [id])
  def get_project_by_directory(dir), do: call(OrcaHub.Projects, :get_project_by_directory, [dir])
  def create_project(attrs), do: call(OrcaHub.Projects, :create_project, [attrs])

  def update_project(project, attrs),
    do: call(OrcaHub.Projects, :update_project, [project, attrs])

  def delete_project(project), do: call(OrcaHub.Projects, :delete_project, [project])
  def search_projects(query), do: call(OrcaHub.Projects, :search, [query])

  # -------------------------------------------------------------------
  # Triggers
  # -------------------------------------------------------------------

  def list_triggers, do: call(OrcaHub.Triggers, :list_triggers, [])
  def get_trigger!(id), do: call(OrcaHub.Triggers, :get_trigger!, [id])
  def create_trigger(attrs), do: call(OrcaHub.Triggers, :create_trigger, [attrs])

  def update_trigger(trigger, attrs),
    do: call(OrcaHub.Triggers, :update_trigger, [trigger, attrs])

  def delete_trigger(trigger), do: call(OrcaHub.Triggers, :delete_trigger, [trigger])

  def list_triggers_for_project(project_id),
    do: call(OrcaHub.Triggers, :list_triggers_for_project, [project_id])

  # -------------------------------------------------------------------
  # Upstream Servers
  # -------------------------------------------------------------------

  def list_upstream_servers, do: call(OrcaHub.UpstreamServers, :list_upstream_servers, [])
  def get_upstream_server!(id), do: call(OrcaHub.UpstreamServers, :get_upstream_server!, [id])

  def create_upstream_server(attrs),
    do: call(OrcaHub.UpstreamServers, :create_upstream_server, [attrs])

  def update_upstream_server(server, attrs),
    do: call(OrcaHub.UpstreamServers, :update_upstream_server, [server, attrs])

  def delete_upstream_server(server),
    do: call(OrcaHub.UpstreamServers, :delete_upstream_server, [server])

  def change_upstream_server(server, attrs \\ %{}),
    do: call(OrcaHub.UpstreamServers, :change_upstream_server, [server, attrs])

  def list_servers_for_project(project_id),
    do: call(OrcaHub.UpstreamServers, :list_servers_for_project, [project_id])

  def list_enabled_servers_for_project(project_id),
    do: call(OrcaHub.UpstreamServers, :list_enabled_servers_for_project, [project_id])

  def add_server_to_project(project_id, server_id),
    do: call(OrcaHub.UpstreamServers, :add_server_to_project, [project_id, server_id])

  def remove_server_from_project(project_id, server_id),
    do: call(OrcaHub.UpstreamServers, :remove_server_from_project, [project_id, server_id])

  def server_in_project?(project_id, server_id),
    do: call(OrcaHub.UpstreamServers, :server_in_project?, [project_id, server_id])

  def list_servers_for_session(session_id),
    do: call(OrcaHub.UpstreamServers, :list_servers_for_session, [session_id])

  def list_enabled_servers_for_session(session_id),
    do: call(OrcaHub.UpstreamServers, :list_enabled_servers_for_session, [session_id])

  def add_server_to_session(session_id, server_id),
    do: call(OrcaHub.UpstreamServers, :add_server_to_session, [session_id, server_id])

  def remove_server_from_session(session_id, server_id),
    do: call(OrcaHub.UpstreamServers, :remove_server_from_session, [session_id, server_id])

  def server_in_session?(session_id, server_id),
    do: call(OrcaHub.UpstreamServers, :server_in_session?, [session_id, server_id])

  # -------------------------------------------------------------------
  # Terminals
  # -------------------------------------------------------------------

  def list_terminals, do: call(OrcaHub.Terminals, :list_terminals, [])
  def get_terminal!(id), do: call(OrcaHub.Terminals, :get_terminal!, [id])
  def get_terminal(id), do: call(OrcaHub.Terminals, :get_terminal, [id])
  def create_terminal(attrs), do: call(OrcaHub.Terminals, :create_terminal, [attrs])

  def update_terminal(terminal, attrs),
    do: call(OrcaHub.Terminals, :update_terminal, [terminal, attrs])

  def delete_terminal(terminal), do: call(OrcaHub.Terminals, :delete_terminal, [terminal])

  def list_terminals_for_project(project_id),
    do: call(OrcaHub.Terminals, :list_terminals_for_project, [project_id])

  # -------------------------------------------------------------------
  # Discord Channels (Discord channel -> project/session mappings)
  # -------------------------------------------------------------------

  def list_discord_channels, do: call(OrcaHub.DiscordChannels, :list_discord_channels, [])

  def get_discord_channel_by_channel_id(discord_channel_id),
    do: call(OrcaHub.DiscordChannels, :get_by_channel_id, [discord_channel_id])

  def create_discord_channel(attrs),
    do: call(OrcaHub.DiscordChannels, :create_discord_channel, [attrs])

  def update_discord_channel(channel, attrs),
    do: call(OrcaHub.DiscordChannels, :update_discord_channel, [channel, attrs])

  def delete_discord_channel(channel),
    do: call(OrcaHub.DiscordChannels, :delete_discord_channel, [channel])

  def set_discord_channel_session(channel, session_id),
    do: call(OrcaHub.DiscordChannels, :set_session, [channel, session_id])

  def set_discord_channel_watermark(channel, message_id),
    do: call(OrcaHub.DiscordChannels, :set_watermark, [channel, message_id])

  # -------------------------------------------------------------------
  # Node Credentials (per-node Claude OAuth tokens)
  # -------------------------------------------------------------------

  def get_node_token(node_name),
    do: call(OrcaHub.NodeCredentials, :get_token_for_node, [node_name])

  def put_node_token(node_name, token),
    do: call(OrcaHub.NodeCredentials, :put_token_for_node, [node_name, token])

  def delete_node_token(node_name),
    do: call(OrcaHub.NodeCredentials, :delete_for_node, [node_name])

  def list_logged_in_nodes, do: call(OrcaHub.NodeCredentials, :list_logged_in_nodes, [])

  # -------------------------------------------------------------------
  # Secrets (OrcaHub-managed secrets for upstream MCP injection)
  # -------------------------------------------------------------------

  def list_secret_keys, do: call(OrcaHub.Secrets, :list_keys, [])
  def put_secret(key, value), do: call(OrcaHub.Secrets, :put_secret, [key, value])
  def delete_secret(key), do: call(OrcaHub.Secrets, :delete_secret, [key])

  # -------------------------------------------------------------------
  # Session Heartbeat (hub-only GenServer)
  # -------------------------------------------------------------------

  def schedule_heartbeat(session_id, interval_seconds, message),
    do: call(OrcaHub.SessionHeartbeat, :schedule, [session_id, interval_seconds, message])

  def cancel_heartbeat(session_id),
    do: call(OrcaHub.SessionHeartbeat, :cancel, [session_id])

  def get_heartbeat(session_id),
    do: call(OrcaHub.SessionHeartbeat, :get, [session_id])
end
