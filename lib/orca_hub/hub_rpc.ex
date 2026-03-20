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
  def update_session(session, attrs), do: call(OrcaHub.Sessions, :update_session, [session, attrs])
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

  def search(query, opts \\ []), do: call(OrcaHub.Sessions, :search, [query, opts])

  def search_sessions_by_directory(directory, opts \\ %{}),
    do: call(OrcaHub.Sessions, :search_sessions_by_directory, [directory, opts])

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
  def update_project(project, attrs), do: call(OrcaHub.Projects, :update_project, [project, attrs])
  def delete_project(project), do: call(OrcaHub.Projects, :delete_project, [project])

  # -------------------------------------------------------------------
  # Issues
  # -------------------------------------------------------------------

  def list_issues(opts \\ []), do: call(OrcaHub.Issues, :list_issues, [opts])
  def get_issue!(id), do: call(OrcaHub.Issues, :get_issue!, [id])
  def update_issue(issue, attrs), do: call(OrcaHub.Issues, :update_issue, [issue, attrs])

  # -------------------------------------------------------------------
  # Feedback
  # -------------------------------------------------------------------

  def create_feedback_request(attrs), do: call(OrcaHub.Feedback, :create_request, [attrs])
  def respond_feedback(id, response), do: call(OrcaHub.Feedback, :respond, [id, response])
  def cancel_feedback(id), do: call(OrcaHub.Feedback, :cancel, [id])
  def list_pending_feedback, do: call(OrcaHub.Feedback, :list_pending_requests, [])

  def list_pending_feedback_for_session(session_id),
    do: call(OrcaHub.Feedback, :list_pending_requests_for_session, [session_id])

  # -------------------------------------------------------------------
  # Triggers
  # -------------------------------------------------------------------

  def list_triggers, do: call(OrcaHub.Triggers, :list_triggers, [])
  def get_trigger!(id), do: call(OrcaHub.Triggers, :get_trigger!, [id])
  def create_trigger(attrs), do: call(OrcaHub.Triggers, :create_trigger, [attrs])
  def update_trigger(trigger, attrs), do: call(OrcaHub.Triggers, :update_trigger, [trigger, attrs])
  def delete_trigger(trigger), do: call(OrcaHub.Triggers, :delete_trigger, [trigger])

  def list_triggers_for_project(project_id),
    do: call(OrcaHub.Triggers, :list_triggers_for_project, [project_id])

  # -------------------------------------------------------------------
  # Terminals
  # -------------------------------------------------------------------

  def list_terminals, do: call(OrcaHub.Terminals, :list_terminals, [])
  def get_terminal!(id), do: call(OrcaHub.Terminals, :get_terminal!, [id])
  def get_terminal(id), do: call(OrcaHub.Terminals, :get_terminal, [id])
  def create_terminal(attrs), do: call(OrcaHub.Terminals, :create_terminal, [attrs])
  def update_terminal(terminal, attrs), do: call(OrcaHub.Terminals, :update_terminal, [terminal, attrs])
  def delete_terminal(terminal), do: call(OrcaHub.Terminals, :delete_terminal, [terminal])

  def list_terminals_for_project(project_id),
    do: call(OrcaHub.Terminals, :list_terminals_for_project, [project_id])
end
