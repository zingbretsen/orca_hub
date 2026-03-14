defmodule OrcaHub.Cluster do
  @moduledoc """
  Distributed query and action routing across connected OrcaHub nodes.

  Each node keeps its own database, registry, and supervisors. This module
  fans out queries to all nodes via `:erpc` and merges results, and routes
  actions to the node that owns a given session/resource.
  """

  alias OrcaHub.{Sessions, Projects, Issues, Triggers, Feedback}
  alias OrcaHub.{SessionRunner, SessionSupervisor}

  @timeout 10_000

  # -------------------------------------------------------------------
  # Node helpers
  # -------------------------------------------------------------------

  @doc "All nodes in the cluster, including this one."
  def nodes, do: [node() | Node.list()]

  @doc "Human-readable node name (the part before @)."
  def node_name(n) when is_atom(n) do
    n |> Atom.to_string() |> String.split("@") |> hd()
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
  # Session queries (fan-out)
  # -------------------------------------------------------------------

  def list_sessions(filter \\ %{}) do
    fan_out(Sessions, :list_sessions, [filter])
    |> Enum.sort_by(fn {_n, s} -> s.updated_at end, {:desc, NaiveDateTime})
  end

  def list_idle_sessions_with_last_assistant_message do
    fan_out(Sessions, :list_idle_sessions_with_last_assistant_message)
    |> Enum.sort_by(fn {_n, s} -> s.updated_at end, {:desc, NaiveDateTime})
  end

  def count_idle_sessions do
    fan_out(Sessions, :count_idle_sessions)
    |> Enum.map(fn {_n, count} -> count end)
    |> Enum.sum()
  end

  def search(query) do
    fan_out(Sessions, :search, [query])
  end

  @doc """
  Find which node owns a session. Returns `{node, session}` or `nil`.
  """
  def find_session(session_id) do
    fan_out(Sessions, :get_session, [session_id])
    |> Enum.find(fn {_n, result} -> result != nil end)
  end

  # -------------------------------------------------------------------
  # Session actions (routed to owning node)
  # -------------------------------------------------------------------

  def get_session!(n, session_id), do: rpc(n, Sessions, :get_session!, [session_id])
  def list_messages(n, session_id), do: rpc(n, Sessions, :list_messages, [session_id])
  def archive_session(n, session), do: rpc(n, Sessions, :archive_session, [session])
  def unarchive_session(n, session), do: rpc(n, Sessions, :unarchive_session, [session])
  def update_session(n, session, attrs), do: rpc(n, Sessions, :update_session, [session, attrs])
  def delete_session(n, session), do: rpc(n, Sessions, :delete_session, [session])
  def defer_session(n, session), do: rpc(n, Sessions, :defer_session, [session])

  def start_session(n, session_id), do: rpc(n, SessionSupervisor, :start_session, [session_id])
  def stop_session(n, session_id), do: rpc(n, SessionSupervisor, :stop_session, [session_id])
  def session_alive?(n, session_id), do: rpc(n, SessionSupervisor, :session_alive?, [session_id])

  def send_message(n, session_id, prompt), do: rpc(n, SessionRunner, :send_message, [session_id, prompt])
  def interrupt(n, session_id), do: rpc(n, SessionRunner, :interrupt, [session_id])
  def get_state(n, session_id), do: rpc(n, SessionRunner, :get_state, [session_id])

  # -------------------------------------------------------------------
  # Project queries (fan-out)
  # -------------------------------------------------------------------

  def list_projects do
    fan_out(Projects, :list_projects)
  end

  def get_project!(n, project_id), do: rpc(n, Projects, :get_project!, [project_id])

  # -------------------------------------------------------------------
  # Issue queries (fan-out)
  # -------------------------------------------------------------------

  def list_issues(opts \\ []) do
    fan_out(Issues, :list_issues, [opts])
  end

  def get_issue!(n, issue_id), do: rpc(n, Issues, :get_issue!, [issue_id])

  # -------------------------------------------------------------------
  # Trigger queries (fan-out)
  # -------------------------------------------------------------------

  def list_triggers do
    fan_out(Triggers, :list_triggers)
  end

  def get_trigger!(n, trigger_id), do: rpc(n, Triggers, :get_trigger!, [trigger_id])

  # -------------------------------------------------------------------
  # Feedback queries (fan-out)
  # -------------------------------------------------------------------

  def list_pending_feedback do
    fan_out(Feedback, :list_pending_requests)
  end

  # -------------------------------------------------------------------
  # Utility: build a node lookup map from fan-out results
  # -------------------------------------------------------------------

  @doc """
  Given fan-out results `[{node, item}, ...]`, build a map of
  `%{item_id => node}` for quick lookups when routing actions.
  """
  def build_node_map(tagged_results, id_fn \\ & &1.id) do
    Map.new(tagged_results, fn {n, item} -> {id_fn.(item), n} end)
  end
end
