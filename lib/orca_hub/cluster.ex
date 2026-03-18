defmodule OrcaHub.Cluster do
  @moduledoc """
  Distributed query and action routing across connected OrcaHub nodes.

  Supports two topologies:
  - **Legacy (multi-hub)**: Each node has its own database; queries fan out to all nodes.
  - **Hub + agent**: One hub node owns the database; agent nodes run sessions only.

  The topology is auto-detected: if any connected node is in agent mode,
  we use hub+agent routing. Otherwise, we use legacy fan-out.
  """

  alias OrcaHub.{HubRPC, SessionRunner, SessionSupervisor}

  @timeout 10_000

  # -------------------------------------------------------------------
  # Node helpers
  # -------------------------------------------------------------------

  @doc "All nodes in the cluster, including this one."
  def nodes, do: [node() | Node.list()]

  @doc "Human-readable node name. Uses NODE_DISPLAY_NAME for local node, falls back to hostname."
  def node_name(n) when is_atom(n) do
    if n == node() do
      display_name()
    else
      try do
        :erpc.call(n, __MODULE__, :display_name, [], 5_000)
      catch
        _, _ ->
          n |> Atom.to_string() |> String.split("@") |> List.last()
      end
    end
  end

  @doc "This node's display name, from NODE_DISPLAY_NAME env var or hostname."
  def display_name do
    case System.get_env("NODE_DISPLAY_NAME") do
      nil -> node() |> Atom.to_string() |> String.split("@") |> List.last()
      "" -> node() |> Atom.to_string() |> String.split("@") |> List.last()
      name -> name
    end
  end

  @doc "Info about each connected node."
  def node_info do
    Enum.map(nodes(), fn n ->
      %{node: n, name: node_name(n)}
    end)
  end

  # -------------------------------------------------------------------
  # Fan-out infrastructure
  # -------------------------------------------------------------------

  @doc """
  Call `mod.fun(args)` on every node, merge list results, tag each item
  with its origin node. Returns `[{node, item}, ...]`.

  Unreachable nodes are silently skipped.
  """
  def fan_out(mod, fun, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    nodes()
    |> Task.async_stream(
      fn n -> {n, :erpc.call(n, mod, fun, args, timeout)} end,
      timeout: timeout + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {n, results}} when is_list(results) ->
        Enum.map(results, &{n, &1})

      {:ok, {n, result}} ->
        [{n, result}]

      {:exit, _reason} ->
        []
    end)
  end

  @doc """
  Call `mod.fun(args)` on a specific node. Passthrough if it's the local node.
  """
  def rpc(n, mod, fun, args, timeout \\ @timeout)
  def rpc(n, mod, fun, args, _timeout) when n == node(), do: apply(mod, fun, args)
  def rpc(n, mod, fun, args, timeout), do: :erpc.call(n, mod, fun, args, timeout)

  # -------------------------------------------------------------------
  # Session queries
  # -------------------------------------------------------------------

  @doc """
  List sessions. Uses HubRPC (single DB query) and tags each session
  with its runner_node (or the hub node as fallback).
  """
  def list_sessions(filter \\ %{}) do
    sessions = HubRPC.list_sessions(filter)

    Enum.map(sessions, fn s ->
      {runner_node_for(s), s}
    end)
    |> Enum.sort_by(fn {_n, s} -> s.updated_at end, {:desc, NaiveDateTime})
  end

  def list_idle_sessions_with_last_assistant_message do
    results = HubRPC.list_idle_sessions_with_last_assistant_message()

    Enum.map(results, fn {s, msg} ->
      {runner_node_for(s), {s, msg}}
    end)
    |> Enum.sort_by(fn {_n, {s, _msg}} -> {s.priority || 0, s.updated_at} end)
  end

  def count_idle_sessions, do: HubRPC.count_idle_sessions()

  def search(query, opts \\ []) do
    results = HubRPC.search(query, opts)
    Enum.map(results, fn s -> {runner_node_for(s), s} end)
  end

  @doc """
  Find which node owns a session. Returns `{node, session}` or `nil`.
  """
  def find_session(session_id) do
    case HubRPC.get_session(session_id) do
      nil -> nil
      session -> {runner_node_for(session), session}
    end
  end

  # -------------------------------------------------------------------
  # Session actions (routed to runner node or hub for DB ops)
  # -------------------------------------------------------------------

  def get_session!(_n, session_id), do: HubRPC.get_session!(session_id)
  def list_messages(_n, session_id), do: HubRPC.list_messages(session_id)
  def archive_session(_n, session), do: HubRPC.archive_session(session)
  def unarchive_session(_n, session), do: HubRPC.unarchive_session(session)
  def update_session(_n, session, attrs), do: HubRPC.update_session(session, attrs)
  def delete_session(_n, session), do: HubRPC.delete_session(session)
  def defer_session(_n, session), do: HubRPC.defer_session(session)

  def start_session(n, session_id), do: rpc(n, SessionSupervisor, :start_session, [session_id])
  def stop_session(n, session_id), do: rpc(n, SessionSupervisor, :stop_session, [session_id])
  def session_alive?(n, session_id), do: rpc(n, SessionSupervisor, :session_alive?, [session_id])

  def send_message(n, session_id, prompt), do: rpc(n, SessionRunner, :send_message, [session_id, prompt])
  def interrupt(n, session_id), do: rpc(n, SessionRunner, :interrupt, [session_id])
  def get_state(n, session_id), do: rpc(n, SessionRunner, :get_state, [session_id])

  # -------------------------------------------------------------------
  # Project queries
  # -------------------------------------------------------------------

  def list_projects do
    projects = HubRPC.list_projects()
    Enum.map(projects, fn p -> {project_node_for(p), p} end)
  end

  def get_project!(_n, project_id), do: HubRPC.get_project!(project_id)

  # -------------------------------------------------------------------
  # Issue queries
  # -------------------------------------------------------------------

  def list_issues(opts \\ []) do
    issues = HubRPC.list_issues(opts)
    Enum.map(issues, fn i ->
      n = if i.project, do: project_node_for(i.project), else: node()
      {n, i}
    end)
  end

  def get_issue!(_n, issue_id), do: HubRPC.get_issue!(issue_id)

  # -------------------------------------------------------------------
  # Trigger queries
  # -------------------------------------------------------------------

  def list_triggers do
    triggers = HubRPC.list_triggers()
    Enum.map(triggers, fn t ->
      n = if t.project, do: project_node_for(t.project), else: node()
      {n, t}
    end)
  end

  def get_trigger!(_n, trigger_id), do: HubRPC.get_trigger!(trigger_id)

  # -------------------------------------------------------------------
  # Feedback queries
  # -------------------------------------------------------------------

  def list_pending_feedback do
    requests = HubRPC.list_pending_feedback()
    Enum.map(requests, fn r -> {node(), r} end)
  end

  # -------------------------------------------------------------------
  # Utility
  # -------------------------------------------------------------------

  @doc """
  Given fan-out results `[{node, item}, ...]`, build a map of
  `%{item_id => node}` for quick lookups when routing actions.
  """
  def build_node_map(tagged_results, id_fn \\ & &1.id) do
    Map.new(tagged_results, fn {n, item} -> {id_fn.(item), n} end)
  end

  @doc """
  Determine which node should run a session, based on its runner_node field.
  Falls back to this node if not set.
  """
  def runner_node_for(%{runner_node: runner_node}) when is_binary(runner_node) and runner_node != "" do
    node_atom = String.to_atom(runner_node)
    if node_atom in nodes(), do: node_atom, else: node()
  end

  def runner_node_for(_), do: node()

  @doc """
  Determine which node a project's directory lives on, based on its node field.
  Falls back to this node if not set.
  """
  def project_node_for(%{node: project_node}) when is_binary(project_node) and project_node != "" do
    node_atom = String.to_atom(project_node)
    if node_atom in nodes(), do: node_atom, else: node()
  end

  def project_node_for(_), do: node()
end
