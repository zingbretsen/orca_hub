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

  def get_session_by_idempotency_key(key),
    do: call(OrcaHub.Sessions, :get_session_by_idempotency_key, [key])

  def get_recent_session_by_idempotency_key(key, window_seconds),
    do: call(OrcaHub.Sessions, :get_recent_session_by_idempotency_key, [key, window_seconds])

  def update_session(session, attrs),
    do: call(OrcaHub.Sessions, :update_session, [session, attrs])

  def delete_session(session), do: call(OrcaHub.Sessions, :delete_session, [session])
  def archive_session(session), do: call(OrcaHub.Sessions, :archive_session, [session])
  def unarchive_session(session), do: call(OrcaHub.Sessions, :unarchive_session, [session])
  def defer_session(session), do: call(OrcaHub.Sessions, :defer_session, [session])
  def list_sessions(filter \\ :manual), do: call(OrcaHub.Sessions, :list_sessions, [filter])

  def list_running_sessions_for_node(node_name),
    do: call(OrcaHub.Sessions, :list_running_sessions_for_node, [node_name])

  def list_messages(session_id), do: call(OrcaHub.Sessions, :list_messages, [session_id])

  def list_messages_window(session_id, opts),
    do: call(OrcaHub.Sessions, :list_messages_window, [session_id, opts])

  def fetch_tool_use_message(session_id, tool_use_id),
    do: call(OrcaHub.Sessions, :fetch_tool_use_message, [session_id, tool_use_id])

  def pending_ask_user_question(session_id),
    do: call(OrcaHub.Sessions, :pending_ask_user_question, [session_id])

  def latest_plan_mode_tool_use_name(session_id),
    do: call(OrcaHub.Sessions, :latest_plan_mode_tool_use_name, [session_id])

  def latest_todos_input(session_id),
    do: call(OrcaHub.Sessions, :latest_todos_input, [session_id])

  def pending_pi_ui_request(session_id),
    do: call(OrcaHub.Sessions, :pending_pi_ui_request, [session_id])

  def latest_pi_plan_mode_enabled?(session_id),
    do: call(OrcaHub.Sessions, :latest_pi_plan_mode_enabled?, [session_id])

  def latest_context_percent(session_id),
    do: call(OrcaHub.Sessions, :latest_context_percent, [session_id])

  def last_context_tokens(session_id),
    do: call(OrcaHub.Sessions, :last_context_tokens, [session_id])

  def count_active_fork_children(parent_id),
    do: call(OrcaHub.Sessions, :count_active_fork_children, [parent_id])

  def annotate_fork_marker(session_id, annotations),
    do: call(OrcaHub.Sessions, :annotate_fork_marker, [session_id, annotations])

  def create_message(attrs), do: call(OrcaHub.Sessions, :create_message, [attrs])
  def count_idle_sessions, do: call(OrcaHub.Sessions, :count_idle_sessions, [])

  def list_idle_sessions_with_last_assistant_message,
    do: call(OrcaHub.Sessions, :list_idle_sessions_with_last_assistant_message, [])

  def last_assistant_text(session_id),
    do: call(OrcaHub.Sessions, :last_assistant_text, [session_id])

  def count_messages(session_id), do: call(OrcaHub.Sessions, :count_messages, [session_id])

  def session_tail(session_id, opts \\ []),
    do: call(OrcaHub.Sessions, :session_tail, [session_id, opts])

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

  def activity_metadata(session_ids),
    do: call(OrcaHub.Sessions, :activity_metadata, [session_ids])

  def churn_detail(session_id, opts \\ []),
    do: call(OrcaHub.Sessions.ChurnDetail, :fetch, [session_id, opts])

  def create_session_interaction(attrs),
    do: call(OrcaHub.Sessions, :create_session_interaction, [attrs])

  def list_session_interactions(opts \\ []),
    do: call(OrcaHub.Sessions, :list_session_interactions, [opts])

  def list_session_interactions_for_sessions(session_ids),
    do: call(OrcaHub.Sessions, :list_session_interactions_for_sessions, [session_ids])

  def get_session_tree(session_id), do: call(OrcaHub.Sessions, :get_session_tree, [session_id])

  def list_sessions_by_ids(ids), do: call(OrcaHub.Sessions, :list_sessions_by_ids, [ids])

  def list_sessions_for_trigger(trigger_id),
    do: call(OrcaHub.Sessions, :list_sessions_for_trigger, [trigger_id])

  def list_task_invocations(session_id),
    do: call(OrcaHub.Sessions, :list_task_invocations, [session_id])

  def session_ids_with_subagents(session_ids),
    do: call(OrcaHub.Sessions, :session_ids_with_subagents, [session_ids])

  # -------------------------------------------------------------------
  # Projects
  # -------------------------------------------------------------------

  def list_projects, do: call(OrcaHub.Projects, :list_projects, [])
  def get_project!(id), do: call(OrcaHub.Projects, :get_project!, [id])
  def get_project(id), do: call(OrcaHub.Projects, :get_project, [id])

  def get_commit_trailer(project_id),
    do: call(OrcaHub.Projects, :get_commit_trailer, [project_id])

  def get_project_by_directory(dir), do: call(OrcaHub.Projects, :get_project_by_directory, [dir])
  def resolve_project_id(id), do: call(OrcaHub.Projects, :resolve_id, [id])
  def create_project(attrs), do: call(OrcaHub.Projects, :create_project, [attrs])

  def update_project(project, attrs),
    do: call(OrcaHub.Projects, :update_project, [project, attrs])

  def delete_project(project), do: call(OrcaHub.Projects, :delete_project, [project])
  def search_projects(query), do: call(OrcaHub.Projects, :search, [query])

  # -------------------------------------------------------------------
  # Issues (minimal — backs the file_feature_request MCP tool and the
  # read-only issues UI; see OrcaHub.Issues moduledoc)
  # -------------------------------------------------------------------

  def create_issue(attrs), do: call(OrcaHub.Issues, :create_issue, [attrs])
  def get_issue(id), do: call(OrcaHub.Issues, :get_issue, [id])
  def get_issue!(id), do: call(OrcaHub.Issues, :get_issue!, [id])
  def list_issues, do: call(OrcaHub.Issues, :list_issues, [])

  def list_open_issues_for_project(project_id),
    do: call(OrcaHub.Issues, :list_open_issues_for_project, [project_id])

  def list_issues_for_project(project_id),
    do: call(OrcaHub.Issues, :list_issues_for_project, [project_id])

  def list_issues_by_id_prefix(prefix),
    do: call(OrcaHub.Issues, :list_issues_by_id_prefix, [prefix])

  def append_issue_note(issue, note), do: call(OrcaHub.Issues, :append_note, [issue, note])
  def close_issue(issue), do: call(OrcaHub.Issues, :close_issue, [issue])
  def reopen_issue(issue), do: call(OrcaHub.Issues, :reopen_issue, [issue])

  # -------------------------------------------------------------------
  # Artifacts (see OrcaHub.Artifacts moduledoc)
  # -------------------------------------------------------------------

  def save_artifact(attrs), do: call(OrcaHub.Artifacts, :save_artifact, [attrs])

  def update_artifact_data(artifact, data),
    do: call(OrcaHub.Artifacts, :update_artifact_data, [artifact, data])

  def merge_user_state(artifact_or_id, patch),
    do: call(OrcaHub.Artifacts, :merge_user_state, [artifact_or_id, patch])

  def get_artifact(id), do: call(OrcaHub.Artifacts, :get_artifact, [id])

  def get_artifact_by_name(project_id, name),
    do: call(OrcaHub.Artifacts, :get_artifact_by_name, [project_id, name])

  def list_artifacts_for_project(project_id),
    do: call(OrcaHub.Artifacts, :list_artifacts_for_project, [project_id])

  def list_artifacts_for_session(session_id),
    do: call(OrcaHub.Artifacts, :list_artifacts_for_session, [session_id])

  def list_all_artifacts(opts \\ %{}), do: call(OrcaHub.Artifacts, :list_all_artifacts, [opts])

  def pin_artifact(artifact), do: call(OrcaHub.Artifacts, :pin_artifact, [artifact])

  def unpin_artifact(artifact), do: call(OrcaHub.Artifacts, :unpin_artifact, [artifact])

  def delete_artifact(artifact), do: call(OrcaHub.Artifacts, :delete_artifact, [artifact])

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
  # Email Inboxes (IMAP mailboxes polled for inbound email triggers; see
  # OrcaHub.EmailInboxes moduledoc — hub-only, same as the poller itself)
  # -------------------------------------------------------------------

  def list_email_inboxes, do: call(OrcaHub.EmailInboxes, :list_email_inboxes, [])
  def get_email_inbox!(id), do: call(OrcaHub.EmailInboxes, :get_email_inbox!, [id])

  def create_email_inbox(attrs),
    do: call(OrcaHub.EmailInboxes, :create_email_inbox, [attrs])

  def update_email_inbox(inbox, attrs),
    do: call(OrcaHub.EmailInboxes, :update_email_inbox, [inbox, attrs])

  def delete_email_inbox(inbox),
    do: call(OrcaHub.EmailInboxes, :delete_email_inbox, [inbox])

  def change_email_inbox(inbox, attrs \\ %{}),
    do: call(OrcaHub.EmailInboxes, :change_email_inbox, [inbox, attrs])

  def test_email_inbox_connection(attrs),
    do: call(OrcaHub.EmailInboxes, :test_connection, [attrs])

  # Starts a poller for any enabled inbox that doesn't have one running yet —
  # see OrcaHub.EmailInboxLoader moduledoc. Safe to call more than once;
  # edits/disables to an already-running poller take effect on its next poll
  # cycle without this (it re-reads the inbox row every tick).
  def sync_email_inbox_pollers, do: call(OrcaHub.EmailInboxLoader, :sync, [])

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

  def get_discord_channel_by_session_id(session_id),
    do: call(OrcaHub.DiscordChannels, :get_by_session_id, [session_id])

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

  def schedule_heartbeat(session_id, interval_seconds, message, opts \\ %{}),
    do: call(OrcaHub.SessionHeartbeat, :schedule, [session_id, interval_seconds, message, opts])

  def cancel_heartbeat(session_id),
    do: call(OrcaHub.SessionHeartbeat, :cancel, [session_id])

  def get_heartbeat(session_id),
    do: call(OrcaHub.SessionHeartbeat, :get, [session_id])

  def watch_job(session_id, job_id),
    do: call(OrcaHub.SessionHeartbeat, :watch_job, [session_id, job_id])

  # ORCAHUB3-29: backs Cluster.send_message/4's :queue delivery mode.
  def deliver_or_queue_message(session_id, message),
    do: call(OrcaHub.SessionHeartbeat, :deliver_or_queue, [session_id, message])

  # ORCAHUB3-43: public read-only accessor for queued message state.
  # Tolerates {:error, {:rpc_undef, _}} from older hubs that lack this function.
  def queued_message_state(session_id) do
    case call(OrcaHub.SessionHeartbeat, :queued_message_state, [session_id]) do
      {:error, {:rpc_undef, _}} -> nil
      {:error, _} -> nil
      result -> result
    end
  end

  # -------------------------------------------------------------------
  # Alert Subscriptions (ORCAHUB3-44 Phase 2 — condition-based worker
  # alerts; see OrcaHub.AlertSubscriptions, OrcaHub.ChurnSampler.AlertEvaluator)
  # -------------------------------------------------------------------

  def get_alert_subscription(orchestrator_session_id),
    do: call(OrcaHub.AlertSubscriptions, :get_by_orchestrator, [orchestrator_session_id])

  def upsert_alert_subscription(orchestrator_session_id, attrs),
    do: call(OrcaHub.AlertSubscriptions, :upsert, [orchestrator_session_id, attrs])

  def cancel_alert_subscription(orchestrator_session_id),
    do: call(OrcaHub.AlertSubscriptions, :cancel, [orchestrator_session_id])

  # -------------------------------------------------------------------
  # API Runs (Agent Runs API, docs/api.md)
  # -------------------------------------------------------------------

  def get_api_run(id), do: call(OrcaHub.ApiRuns, :get_run, [id])
  def create_api_run(attrs), do: call(OrcaHub.ApiRuns, :create_run, [attrs])
  def update_api_run(run, attrs), do: call(OrcaHub.ApiRuns, :update_run, [run, attrs])

  def get_run_by_session_id(session_id),
    do: call(OrcaHub.ApiRuns, :get_run_by_session_id, [session_id])

  # -------------------------------------------------------------------
  # A2A Tasks (inbound A2A server, docs/a2a.md) — reached from MCP.Server
  # (which may run on an agent node) via OrcaHub.MCP.ToolCallHolder.A2ATaskHolder.
  # Task CREATION stays direct-Repo in A2ATasks/A2AController (hub-only), so
  # only the get/update surface a client-tool-call holder needs is wrapped
  # here.
  # -------------------------------------------------------------------

  def get_a2a_task(id), do: call(OrcaHub.A2ATasks, :get_task, [id])

  def get_a2a_task_by_session_id(session_id),
    do: call(OrcaHub.A2ATasks, :get_task_by_session_id, [session_id])

  def update_a2a_task(task, attrs), do: call(OrcaHub.A2ATasks, :update_task, [task, attrs])

  # -------------------------------------------------------------------
  # Cluster Nodes (/nodes UI — currently and previously connected nodes)
  # -------------------------------------------------------------------

  def list_nodes, do: call(OrcaHub.ClusterNodes, :list_nodes, [])
  def get_node!(id), do: call(OrcaHub.ClusterNodes, :get_node!, [id])
  def get_node_by_name(name), do: call(OrcaHub.ClusterNodes, :get_by_name, [name])

  def update_node(node, attrs), do: call(OrcaHub.ClusterNodes, :update_node, [node, attrs])
  def create_node(attrs), do: call(OrcaHub.ClusterNodes, :create_node, [attrs])

  def count_sessions_for_node(name),
    do: call(OrcaHub.ClusterNodes, :count_sessions_for_node, [name])

  def count_projects_for_node(name),
    do: call(OrcaHub.ClusterNodes, :count_projects_for_node, [name])

  def session_counts_by_node, do: call(OrcaHub.ClusterNodes, :session_counts_by_node, [])
  def project_counts_by_node, do: call(OrcaHub.ClusterNodes, :project_counts_by_node, [])

  # -------------------------------------------------------------------
  # Notifications (Gotify push, see OrcaHub.Notify — hub-only creds)
  # -------------------------------------------------------------------

  def send_notification(payload), do: call(OrcaHub.Notify, :deliver, [payload])

  # -------------------------------------------------------------------
  # Skills (hub-managed global skills — see OrcaHub.Skills, OrcaHub.SkillSync)
  # -------------------------------------------------------------------

  def list_skills, do: call(OrcaHub.Skills, :list_skills, [])
  def list_enabled_skills, do: call(OrcaHub.Skills, :list_enabled_skills, [])
  def get_skill!(id), do: call(OrcaHub.Skills, :get_skill!, [id])
  def get_skill(id), do: call(OrcaHub.Skills, :get_skill, [id])
  def get_skill_by_name(name), do: call(OrcaHub.Skills, :get_skill_by_name, [name])
  def create_skill(attrs), do: call(OrcaHub.Skills, :create_skill, [attrs])
  def update_skill(skill, attrs), do: call(OrcaHub.Skills, :update_skill, [skill, attrs])
  def delete_skill(skill), do: call(OrcaHub.Skills, :delete_skill, [skill])

  # -------------------------------------------------------------------
  # pi config federation (hub-managed ~/.pi/agent config — see
  # OrcaHub.PiConfig, OrcaHub.PiConfigSync)
  # -------------------------------------------------------------------

  def list_pi_config_entries, do: call(OrcaHub.PiConfig, :list_entries, [])
  def list_pi_config_entries(kind), do: call(OrcaHub.PiConfig, :list_entries, [kind])
  def list_enabled_pi_config_entries, do: call(OrcaHub.PiConfig, :list_enabled_entries, [])

  def list_enabled_pi_config_entries(kind),
    do: call(OrcaHub.PiConfig, :list_enabled_entries, [kind])

  def get_pi_config_entry!(id), do: call(OrcaHub.PiConfig, :get_entry!, [id])
  def get_pi_config_entry(id), do: call(OrcaHub.PiConfig, :get_entry, [id])

  def get_pi_config_entry_by_kind_and_name(kind, name),
    do: call(OrcaHub.PiConfig, :get_entry_by_kind_and_name, [kind, name])

  def create_pi_config_entry(attrs), do: call(OrcaHub.PiConfig, :create_entry, [attrs])

  def update_pi_config_entry(entry, attrs),
    do: call(OrcaHub.PiConfig, :update_entry, [entry, attrs])

  def delete_pi_config_entry(entry), do: call(OrcaHub.PiConfig, :delete_entry, [entry])

  # -------------------------------------------------------------------
  # Issues — full issues_spec.md tool-surface API (Phase 2a). The minimal
  # wrappers above (create_issue/get_issue/list_issues/0/list_issues_for_project/
  # list_issues_by_id_prefix/append_issue_note/close_issue(1)/reopen_issue(1))
  # predate this section and stay as-is — see OrcaHub.Issues moduledoc for why
  # both old and new arities coexist.
  # -------------------------------------------------------------------

  def list_issues(opts), do: call(OrcaHub.Issues, :list_issues, [opts])

  def update_issue(issue, attrs, session_id),
    do: call(OrcaHub.Issues, :update_issue, [issue, attrs, session_id])

  def close_issue(issue, attrs), do: call(OrcaHub.Issues, :close_issue, [issue, attrs])

  def reopen_issue(issue, session_id),
    do: call(OrcaHub.Issues, :reopen_issue, [issue, session_id])

  def resolve_issue_id(id), do: call(OrcaHub.Issues, :resolve_id, [id])
  def render_issue_key(issue), do: call(OrcaHub.Issues, :render_key, [issue])
  def derive_issue_commits(issue), do: call(OrcaHub.Issues, :derive_commits, [issue])

  def derive_issue_attempt_summary(issue),
    do: call(OrcaHub.Issues, :derive_attempt_summary, [issue])

  def live_issue_attempts(issue), do: call(OrcaHub.Issues, :live_attempts, [issue])

  def find_similar_open_issue(project_id, kind, title),
    do: call(OrcaHub.Issues, :find_similar_open_issue, [project_id, kind, title])

  def list_open_issues_created_by(session_id),
    do: call(OrcaHub.Issues, :list_open_issues_created_by, [session_id])

  # Plain, no-side-effect field update (distinct from the session-aware
  # update_issue/3 above) — used for start_session's best-effort
  # open -> in_progress auto-transition (issues_spec.md §9).
  def update_issue(issue, attrs), do: call(OrcaHub.Issues, :update_issue, [issue, attrs])

  # -------------------------------------------------------------------
  # Jobs (ORCAHUB3-25 — durable, detached background jobs; see OrcaHub.Jobs)
  # -------------------------------------------------------------------

  def get_job(id), do: call(OrcaHub.Jobs, :get_job, [id])
  def get_job!(id), do: call(OrcaHub.Jobs, :get_job!, [id])
  def create_job(attrs), do: call(OrcaHub.Jobs, :create_job, [attrs])
  def update_job(job, attrs), do: call(OrcaHub.Jobs, :update_job, [job, attrs])

  def list_nonterminal_jobs_for_node(node_name),
    do: call(OrcaHub.Jobs, :list_nonterminal_jobs_for_node, [node_name])

  def list_jobs(opts \\ %{}), do: call(OrcaHub.Jobs, :list_jobs, [opts])

  # -------------------------------------------------------------------
  # Session Parentage (ORCAHUB3-50)
  # -------------------------------------------------------------------

  def attach_session(session_id, parent_id, opts \\ []),
    do: call(OrcaHub.Sessions, :attach_session, [session_id, parent_id, opts])

  def detach_session(session_id, opts \\ []),
    do: call(OrcaHub.Sessions, :detach_session, [session_id, opts])

  # -------------------------------------------------------------------
  # API Tokens (scoped, revocable — see OrcaHub.ApiTokens)
  # -------------------------------------------------------------------

  def list_api_tokens, do: call(OrcaHub.ApiTokens, :list_tokens, [])
  def create_api_token(attrs), do: call(OrcaHub.ApiTokens, :create_token, [attrs])
  def revoke_api_token(id), do: call(OrcaHub.ApiTokens, :revoke_token, [id])

  def change_api_token(token, attrs \\ %{}),
    do: call(OrcaHub.ApiTokens, :change_token, [token, attrs])
end
