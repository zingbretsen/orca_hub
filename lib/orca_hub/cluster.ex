defmodule OrcaHub.Cluster do
  @moduledoc """
  Distributed query and action routing across connected OrcaHub nodes.

  Supports two topologies:
  - **Legacy (multi-hub)**: Each node has its own database; queries fan out to all nodes.
  - **Hub + agent**: One hub node owns the database; agent nodes run sessions only.

  The topology is auto-detected: if any connected node is in agent mode,
  we use hub+agent routing. Otherwise, we use legacy fan-out.
  """

  alias OrcaHub.{HubRPC, SessionRunner, SessionSupervisor, TerminalSupervisor}

  @timeout 10_000

  # -------------------------------------------------------------------
  # Node helpers
  # -------------------------------------------------------------------

  @doc "All nodes in the cluster, including this one."
  def nodes, do: [node() | Node.list()]

  @doc """
  Human-readable node name

  - For atoms: Uses NODE_DISPLAY_NAME for local node, calls remote for display_name, falls back to hostname.
  - For strings: Preserves disconnected node identity by extracting hostname from node string.
  """
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

  def node_name(n) when is_binary(n) do
    # Try to convert to atom and get display name from connected node
    try do
      node_atom = String.to_existing_atom(n)

      if node_atom in nodes() do
        node_name(node_atom)
      else
        # Disconnected node - extract hostname from node string
        n |> String.split("@") |> List.last()
      end
    rescue
      # Atom doesn't exist - extract hostname from string
      ArgumentError ->
        n |> String.split("@") |> List.last()
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

  Never silently substitutes a different node for the one requested: refuses
  with `{:error, :node_unassigned}` when `n` is `nil` (entity has no assigned
  node) and `{:error, {:node_unavailable, n}}` when `n` is a node that isn't
  currently connected, instead of letting `:erpc` raise/return a noconnection
  error for an action we should never have attempted in the first place.

  Also returns `{:error, {:rpc_undef, {mod, fun, arity}}}` instead of raising
  when the target node IS connected but doesn't export `mod.fun/arity` — the
  hub+agent topology deploys nodes independently, so a connected node running
  an older release is an expected, recoverable state (same treatment as an
  unavailable node), not a crash.
  """
  def rpc(n, mod, fun, args, timeout \\ @timeout)
  def rpc(nil, _mod, _fun, _args, _timeout), do: {:error, :node_unassigned}
  def rpc(n, mod, fun, args, _timeout) when n == node(), do: apply(mod, fun, args)

  def rpc(n, mod, fun, args, timeout) do
    if node_available?(n) do
      try do
        :erpc.call(n, mod, fun, args, timeout)
      rescue
        e in ErlangError ->
          case e.original do
            {:exception, :undef, _stacktrace} ->
              {:error, {:rpc_undef, {mod, fun, length(args)}}}

            _ ->
              reraise e, __STACKTRACE__
          end
      end
    else
      {:error, {:node_unavailable, n}}
    end
  end

  @doc """
  Shared user-facing text for the node-unassigned/node-unavailable errors
  produced by `rpc/5` (and by `session_alive?/2`/`terminal_alive?/2`
  observing the same conditions), so every LiveView/controller/tool surfaces
  the same wording instead of each inventing its own.
  """
  def node_unavailable_message(:node_unassigned),
    do: "This session has no assigned node."

  def node_unavailable_message({:node_unavailable, n}),
    do: "This session's node (#{node_name(n)}) is not currently connected."

  def node_unavailable_message({:error, reason}), do: node_unavailable_message(reason)
  def node_unavailable_message(_), do: nil

  @doc "Is `result` one of rpc/5's node-unassigned/node-unavailable errors?"
  def node_unavailable_error?({:error, :node_unassigned}), do: true
  def node_unavailable_error?({:error, {:node_unavailable, _}}), do: true
  def node_unavailable_error?(_), do: false

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

  def start_session(n, session_id, session_data \\ nil) do
    # Pass the calling node as db_node so the runner can route DB calls back
    db_node = if n != node(), do: node(), else: nil
    rpc(n, SessionSupervisor, :start_session, [session_id, session_data, db_node])
  end

  def stop_session(n, session_id), do: rpc(n, SessionSupervisor, :stop_session, [session_id])

  # Normalizes rpc/5's {:error, :node_unassigned | {:node_unavailable, _}} to
  # `false` so `unless`/`if Cluster.session_alive?(...)` keeps working as a
  # plain boolean check — "can't confirm it's alive" reads as "not alive"
  # here, which is what callers want (e.g. don't skip start_session because
  # of a stale truthy error tuple; let start_session's own rpc/5 gate refuse
  # the unavailable node cleanly instead).
  def session_alive?(n, session_id) do
    case rpc(n, SessionSupervisor, :session_alive?, [session_id]) do
      {:error, _} -> false
      alive? -> alive?
    end
  end

  # The runner may have been stopped between page load and send — e.g. the
  # abandoned-session cleanup in SessionLive.Show.terminate/2 racing a page
  # reload — so restart it instead of letting the GenStatem call crash the
  # caller with :noproc.
  def send_message(n, session_id, prompt) do
    ensure_started =
      if session_alive?(n, session_id) do
        :ok
      else
        case start_session(n, session_id) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          # Node-unavailable/unassigned refusals pass through as-is (not
          # wrapped in :not_started) — this isn't "we tried to start it and
          # it failed", it's "we correctly refused to start it anywhere".
          {:error, reason} = error ->
            if node_unavailable_error?(error), do: error, else: {:error, {:not_started, reason}}
        end
      end

    with :ok <- ensure_started do
      rpc(n, SessionRunner, :send_message, [session_id, prompt])
    end
  end

  def interrupt(n, session_id), do: rpc(n, SessionRunner, :interrupt, [session_id])
  def get_state(n, session_id), do: rpc(n, SessionRunner, :get_state, [session_id])

  def update_model(n, session_id, model),
    do: rpc(n, SessionRunner, :update_model, [session_id, model])

  def update_orchestrator(n, session_id, orchestrator),
    do: rpc(n, SessionRunner, :update_orchestrator, [session_id, orchestrator])

  def update_backend(n, session_id, backend),
    do: rpc(n, SessionRunner, :update_backend, [session_id, backend])

  # Answers a backend-native mid-turn UI dialog (pi's extension-UI reply
  # loop — "pi backend groundwork" slice). Mirrors update_backend/3's plain
  # RPC-through pattern (no ensure-started dance like send_message/3: a
  # dialog can only be pending on an ALREADY-running turn, so a dead/restarted
  # runner has nothing to answer — SessionRunner.answer_ui_request/3 returns
  # {:error, :not_running} in every non-:running state, including via a
  # freshly-started runner that never saw the dialog).
  def answer_ui_request(n, session_id, request_id, payload),
    do: rpc(n, SessionRunner, :answer_ui_request, [session_id, request_id, payload])

  # Toggles a backend-native plan mode (pi's `/plan`, spec §12.4). Plain
  # RPC-through, same posture as answer_ui_request/4 above — no ensure-started
  # dance: SessionRunner.toggle_plan_mode/1 already returns
  # {:error, :not_running} for a cold/never-started runner, and a freshly
  # (re)started one has nothing warm to toggle.
  def toggle_plan_mode(n, session_id),
    do: rpc(n, SessionRunner, :toggle_plan_mode, [session_id])

  # Manually triggers context compaction (pi's `compact` RPC command, spec
  # §12.8). Same plain RPC-through posture as toggle_plan_mode/2 — no
  # ensure-started dance: SessionRunner.compact_session/1 already returns
  # {:error, :not_running} for a cold/never-started runner.
  def compact_session(n, session_id),
    do: rpc(n, SessionRunner, :compact_session, [session_id])

  # -------------------------------------------------------------------
  # Project queries
  # -------------------------------------------------------------------

  def list_projects do
    projects = HubRPC.list_projects()
    Enum.map(projects, fn p -> {project_node_for(p), p} end)
  end

  def get_project!(_n, project_id), do: HubRPC.get_project!(project_id)

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
  # Utility
  # -------------------------------------------------------------------

  @doc """
  Given fan-out results `[{node, item}, ...]`, build a map of
  `%{item_id => node}` for quick lookups when routing actions.
  """
  def build_node_map(tagged_results, id_fn \\ & &1.id) do
    Map.new(tagged_results, fn {n, item} -> {id_fn.(item), n} end)
  end

  @doc "Is node `n` currently connected to this cluster (or is it this node)?"
  def node_available?(nil), do: false
  def node_available?(n) when is_atom(n), do: n in nodes()

  # Node name strings in the DB are always written by our own code (via
  # `node()`/`Atom.to_string/1` at assignment time), so converting back with
  # to_atom/1 is safe — and required: to_existing_atom/1 raises for a node
  # this process has never locally seen, which is exactly the "assigned but
  # currently offline" case callers need represented as a value, not a crash.
  defp node_atom_for(node_string), do: String.to_atom(node_string)

  @doc """
  Determine which node should run a session, based on its runner_node field.

  Returns the ASSIGNED node even when it is currently unreachable — this
  helper never re-assigns a session to another node just because its own
  node is offline. Callers about to act on a session must check
  `node_available?/1` (or go through `rpc/5`, which already refuses
  unavailable/unassigned nodes) rather than treating the return value as
  "safe to act on locally".

  Sessions have no legacy nil fallback: every creation path stamps
  `runner_node`, and a 2026-07 production audit found only long-archived
  (pre-stamping) rows with a nil/empty value. A nil/empty `runner_node`
  is therefore treated as "unassigned" (returns `nil`) rather than
  silently local.

  For non-session entities (e.g. terminals), a nil runner_node instead
  falls back to this node — unlike sessions, that's a legitimate "not
  started anywhere yet" state (see `OrcaHub.TerminalRunner`), not legacy
  data.
  """
  def runner_node_for(%OrcaHub.Sessions.Session{runner_node: runner_node})
      when is_binary(runner_node) and runner_node != "" do
    node_atom_for(runner_node)
  end

  def runner_node_for(%OrcaHub.Sessions.Session{}), do: nil

  def runner_node_for(%{runner_node: runner_node})
      when is_binary(runner_node) and runner_node != "" do
    node_atom_for(runner_node)
  end

  def runner_node_for(_), do: node()

  @doc """
  Determine which node a project's directory lives on, based on its node field.
  Falls back to this node if not set — nil means "no clustering configured"
  (single-node/dev default), which is real semantics, not a compatibility shim.
  """
  def project_node_for(%{node: project_node})
      when is_binary(project_node) and project_node != "" do
    node_atom_for(project_node)
  end

  def project_node_for(_), do: node()

  # -------------------------------------------------------------------
  # Terminal queries and actions
  # -------------------------------------------------------------------

  def list_terminals do
    fan_out(HubRPC, :list_terminals, [])
    |> dedup_tagged()
  end

  def list_terminals_for_project(project_id) do
    fan_out(HubRPC, :list_terminals_for_project, [project_id])
    |> dedup_tagged()
  end

  defp dedup_tagged(tagged_results) do
    tagged_results
    |> Enum.uniq_by(fn {_n, item} -> item.id end)
    |> Enum.map(fn {_n, item} -> {runner_node_for(item), item} end)
  end

  # Unlike get_session!/2 (which always queries the single shared hub DB
  # directly via HubRPC, ignoring n), this stays routed through rpc/5:
  # terminals still support the legacy multi-hub topology (see moduledoc)
  # where each node owns its own DB, so a terminal genuinely may only be
  # visible from its own node. Refuses cleanly ({:error, ...}) rather than
  # raising when that node is offline — callers must handle a non-Terminal
  # result (see terminal_live/show.ex's get_terminal_safe/2).
  def get_terminal!(n, terminal_id), do: rpc(n, HubRPC, :get_terminal!, [terminal_id])

  def create_terminal(n, attrs) do
    # Only remap project_id when the target is a different hub (separate DB).
    # Agents share the hub's DB, so the original project_id is valid.
    attrs =
      if n != node() && rpc(n, OrcaHub.Mode, :hub?, []) do
        dir = attrs[:directory] || attrs["directory"]
        remote_project = if dir, do: rpc(n, HubRPC, :get_project_by_directory, [dir])
        project_id = if remote_project, do: remote_project.id

        attrs
        |> Map.delete(:project_id)
        |> Map.delete("project_id")
        |> then(fn a -> if project_id, do: Map.put(a, :project_id, project_id), else: a end)
      else
        attrs
      end

    rpc(n, HubRPC, :create_terminal, [attrs])
  end

  def update_terminal(n, terminal, attrs), do: rpc(n, HubRPC, :update_terminal, [terminal, attrs])
  def delete_terminal(n, terminal), do: rpc(n, HubRPC, :delete_terminal, [terminal])

  def start_terminal(n, terminal_id),
    do: rpc(n, TerminalSupervisor, :start_terminal, [terminal_id])

  def stop_terminal(n, terminal_id), do: rpc(n, TerminalSupervisor, :stop_terminal, [terminal_id])

  # See session_alive?/2 — same normalization, same reason.
  def terminal_alive?(n, terminal_id) do
    case rpc(n, TerminalSupervisor, :terminal_alive?, [terminal_id]) do
      {:error, _} -> false
      alive? -> alive?
    end
  end

  # -------------------------------------------------------------------
  # Node login (Claude Code OAuth, per-node)
  # -------------------------------------------------------------------

  @doc "Start the `claude setup-token` login flow on node `n`."
  def login_node(n), do: rpc(n, OrcaHub.LoginRunner, :start_login, [])

  @doc "Submit a pasted OAuth code to the in-progress login flow on node `n`."
  def submit_login_code(n, code), do: rpc(n, OrcaHub.LoginRunner, :submit_code, [code])

  @doc "Cancel the in-progress login flow on node `n`."
  def cancel_login(n), do: rpc(n, OrcaHub.LoginRunner, :cancel, [])

  # -------------------------------------------------------------------
  # Node login (codex device-auth / API key, per-node) + pi provider keys
  # -------------------------------------------------------------------

  @doc "Start the `codex login --device-auth` flow on node `n`."
  def login_node_codex_device(n), do: rpc(n, OrcaHub.CodexLoginRunner, :start_device_auth, [])

  @doc "Start the `codex login --with-api-key` flow on node `n`, piping `key`."
  def login_node_codex_api_key(n, key),
    do: rpc(n, OrcaHub.CodexLoginRunner, :start_api_key, [key])

  @doc "Cancel the in-progress codex login flow on node `n`."
  def cancel_codex_login(n), do: rpc(n, OrcaHub.CodexLoginRunner, :cancel, [])

  @doc "Codex login-status badge for node `n` (see `OrcaHub.BackendAuth.codex_status/1`)."
  def codex_status(n), do: rpc(n, OrcaHub.BackendAuth, :codex_status, [])

  @doc "Whether node `n` has an `OPENAI_API_KEY` env var that would shadow a codex login."
  def codex_env_conflict?(n), do: rpc(n, OrcaHub.BackendAuth, :codex_env_conflict?, [])

  @doc "List configured pi providers (names/types only) on node `n`."
  def list_pi_providers(n), do: rpc(n, OrcaHub.BackendAuth, :list_pi_providers, [])

  @doc "Set pi's stored API key for `provider` on node `n`."
  def set_pi_key(n, provider, key), do: rpc(n, OrcaHub.BackendAuth, :set_pi_key, [provider, key])

  @doc "Remove pi's stored API key for `provider` on node `n`."
  def delete_pi_key(n, provider), do: rpc(n, OrcaHub.BackendAuth, :delete_pi_key, [provider])
end
