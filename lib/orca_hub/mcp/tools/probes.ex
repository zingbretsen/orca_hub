defmodule OrcaHub.MCP.Tools.Probes do
  @moduledoc """
  Node-routed, read-only verification tools (ORCAHUB3-28): `git_probe`,
  `stat_paths`, `disk_free`. The point of this category is NODE ROUTING —
  an orchestrator's own `Read`/`Glob`/`Grep`/`Bash` only ever see its own
  node, so a child session running on a different node writes files the
  orchestrator cannot observe by any means short of interrupting the child
  with a message. These three tools route via `OrcaHub.Cluster.rpc/5` to an
  explicit target node (default: the caller's own node), execute a fixed,
  typed, read-only operation there (`OrcaHub.Probes`), and return
  structured data — never a shell command string, see `OrcaHub.Probes`'
  moduledoc for the injection-safety argument.

  ## Path scoping (decision)

  A probe here runs with the CALLING SESSION's privileges but reaches an
  ARBITRARY other node — that combination is new: nothing else in this
  codebase lets a session ask a *different* node to read filesystem state
  at a caller-supplied path. The existing cross-node precedent
  (`get_session_tail`'s `last_commit`) is narrower than that: it always
  derives the directory from an existing session record, so the probed
  path is never attacker-chosen text, only ever "some session's own
  directory". `git_probe`/`stat_paths`/`disk_free` take a raw path/directory
  argument directly, so that constraint doesn't come for free here.

  Decision: **restrict every path/directory argument to a registered
  project's directory (any project, any node — see below) or the calling
  session's own directory, in either case allowing sub-paths (worktrees
  under `.worktrees/`, nested build output, etc.)** — see
  `within_allowed_root?/2`. Unrestricted access was considered and
  rejected: without this, a probe becomes a generic "read filesystem
  metadata/git history anywhere on any connected machine" oracle, which is
  a materially larger blast radius than anything currently reachable
  through the MCP tool surface, for a marginal gain (probing paths OrcaHub
  has no other reason to know about isn't a real verification need — every
  legitimate "check on a child's work" question is about a project or
  session directory OrcaHub already tracks). Both `git_probe` and
  `stat_paths`/`disk_free` share the identical scoping rule rather than
  each tool inventing its own carve-out, even though their stakes differ
  (next paragraph) — one rule is easier to reason about and audit than
  several similar-but-not-identical ones, and `disk_free`'s free-space
  numbers are only reached by walking through the same scoped `path` check
  anyway.

  Note the stakes are NOT uniform across these three tools: `stat_paths`
  and `disk_free` return metadata only (existence, size, mtime, a bounded
  recursive count, free/used bytes) and NEVER file content — a much lower
  ceiling than `git_probe`, which can surface commit subjects, author
  names, and diffed file paths, i.e. actual repository content. Scoping
  still applies uniformly (previous paragraph), but this asymmetry is why
  `git_probe` is the one worth the most scrutiny in review, and why a
  future "loosen scoping" change, if ever proposed, should not loosen it
  for `git_probe` and `stat_paths`/`disk_free` in the same step.

  A project's directory is trusted regardless of which node happens to
  currently own that project, and regardless of which node is actually
  being probed — the allow-list is "directories OrcaHub already tracks",
  not an attempt to enforce a strict directory-to-node pairing on top of
  that; a caller crossing that pairing (probing node A with a directory
  string that's actually node B's project) just gets a normal
  file-not-found/not-a-repo result from node A, nothing unsafe.

  ## NodePolicy direction (decision)

  `OrcaHub.NodePolicy.isolated` blocks a node from INITIATING cross-node
  calls; inbound traffic to an isolated node is unaffected (see
  `NodePolicy`'s moduledoc). A probe tool call's `MCP.Server`/this dispatch
  code runs colocated with the CALLING session — i.e. on the caller's own
  node — and every probe here reaches out via `Cluster.rpc/5` to a target
  node (which may be the same node, a no-op cross-node-wise). That is
  squarely "initiating a cross-node call", the exact shape `isolated`
  exists to block — identical to `send_message_to_session`,
  `archive_session`, and `get_session_tail` in `OrcaHub.MCP.Tools.Sessions`,
  which already gate on `NodePolicy.cross_node_allowed?/1` before reaching
  across. This module applies the same check, the same way, for the same
  reason: a session on an isolated node (e.g. the Discord agent node)
  should not be able to probe git/filesystem state on any OTHER node,
  exactly as it already cannot message or search sessions there.

  ## Node argument safety

  The `node` argument arrives as caller-supplied text — resolved via
  `OrcaHub.MCP.Tools.NodeArg.resolve/1`, shared with `start_session`'s
  `node` targeting param, see that module's moduledoc for the atom-table
  safety argument.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC, NodePolicy, Probes}
  alias OrcaHub.MCP.Tools.NodeArg

  @max_paths 25
  @git_actions ~w(status head log touches diff_stat)

  def list do
    [
      %{
        "name" => "git_probe",
        "description" =>
          "Read-only git verification, routed to a specific node (default: your own) — " <>
            "the trust-but-verify workhorse for checking a child session's work on " <>
            "ANOTHER node without interrupting it. Actions: \"status\" (git status " <>
            "--porcelain — is the tree clean?), \"head\" (current HEAD sha/subject), " <>
            "\"log\" (recent commits, optionally scoped to a path), \"touches\" (does a " <>
            "specific commit touch a specific path — requires commit + path), " <>
            "\"diff_stat\" (structured per-file added/deleted line counts between two " <>
            "shas — requires from_sha + to_sha). Commit/from_sha/to_sha must be hex shas " <>
            "(full or abbreviated) — branch names and relative refs like HEAD~2 are not " <>
            "accepted. directory must be a registered project's directory (or a " <>
            "sub-path, e.g. a worktree) or your own session's directory — see the " <>
            "module's path-scoping notes if this rejects a path you expected to work.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "directory" => %{
              "type" => "string",
              "description" => "Absolute path to the git repository to probe."
            },
            "node" => %{
              "type" => "string",
              "description" =>
                "Erlang node name to run this probe on, e.g. \"orca@dell\". Defaults to " <>
                  "your own session's node. Must be a currently-connected node."
            },
            "action" => %{
              "type" => "string",
              "enum" => @git_actions,
              "description" => "Which git question to ask. See the tool description."
            },
            "path" => %{
              "type" => "string",
              "description" =>
                "Repo-relative pathspec. For \"log\": optionally scope the log to this " <>
                  "path. For \"touches\": required — the path to check."
            },
            "commit" => %{
              "type" => "string",
              "description" => "Required for \"touches\": a hex sha (full or abbreviated)."
            },
            "from_sha" => %{
              "type" => "string",
              "description" => "Required for \"diff_stat\": the earlier hex sha."
            },
            "to_sha" => %{
              "type" => "string",
              "description" => "Required for \"diff_stat\": the later hex sha."
            },
            "limit" => %{
              "type" => "integer",
              "description" => "For \"log\": max commits to return. Default 20, max 200."
            }
          },
          "required" => ["directory", "action"]
        }
      },
      %{
        "name" => "stat_paths",
        "description" =>
          "Batch, metadata-only stat for up to #{@max_paths} paths at once, routed to a " <>
            "specific node (default: your own). Returns existence/type/size/mtime per " <>
            "path — for a directory, also a bounded recursive entry count and total size " <>
            "(never file contents). Built for repeated polling of a fixed set of paths " <>
            "(\"these five paths, every 30 seconds\") in ONE call rather than N. Each " <>
            "path must be a registered project's directory/sub-path or your own " <>
            "session's directory — a path outside that scope comes back as " <>
            "{denied: true} rather than failing the whole batch.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "paths" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Absolute paths to stat. 1-#{@max_paths} per call."
            },
            "node" => %{
              "type" => "string",
              "description" =>
                "Erlang node name to run this probe on, e.g. \"orca@dell\". Defaults to " <>
                  "your own session's node. Must be a currently-connected node."
            },
            "max_entries" => %{
              "type" => "integer",
              "description" =>
                "Cap on recursive files counted/summed for a directory path. Default " <>
                  "5000, hard max 50000. A directory hitting the cap comes back with " <>
                  "truncated: true and a partial count/size."
            }
          },
          "required" => ["paths"]
        }
      },
      %{
        "name" => "disk_free",
        "description" =>
          "Free/used/total bytes for the filesystem containing `path`, routed to a " <>
            "specific node (default: your own). Cheap corroborating signal for a claim " <>
            "about disk usage — e.g. confirming a worker's \"added 46GB, deleted nothing\" " <>
            "claim independently of anything the worker itself reported. path must be a " <>
            "registered project's directory/sub-path or your own session's directory.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Any path on the filesystem you want free-space info for."
            },
            "node" => %{
              "type" => "string",
              "description" =>
                "Erlang node name to run this probe on, e.g. \"orca@dell\". Defaults to " <>
                  "your own session's node. Must be a currently-connected node."
            }
          },
          "required" => ["path"]
        }
      }
    ]
  end

  def call("git_probe", args, state) do
    directory = args["directory"]
    action = args["action"]

    cond do
      is_nil(directory) or directory == "" ->
        error("directory is required.")

      action not in @git_actions ->
        error("action must be one of: #{Enum.join(@git_actions, ", ")}.")

      action == "touches" and blank?(args["commit"]) ->
        error("action \"touches\" requires commit.")

      action == "touches" and blank?(args["path"]) ->
        error("action \"touches\" requires path.")

      action == "diff_stat" and (blank?(args["from_sha"]) or blank?(args["to_sha"])) ->
        error("action \"diff_stat\" requires both from_sha and to_sha.")

      true ->
        with {:ok, target_node} <- NodeArg.resolve(args["node"]),
             :ok <- check_isolation(target_node),
             :ok <- check_scope(directory, state) do
          run_git_probe(target_node, directory, action, args)
        else
          {:error, msg} -> error(msg)
        end
    end
  end

  def call("stat_paths", args, state) do
    paths = args["paths"] || []
    max_entries = args["max_entries"]

    cond do
      paths == [] or not is_list(paths) ->
        error("paths must be a non-empty list of strings.")

      length(paths) > @max_paths ->
        error("Too many paths (#{length(paths)}); max #{@max_paths} per call.")

      true ->
        with {:ok, target_node} <- NodeArg.resolve(args["node"]),
             :ok <- check_isolation(target_node) do
          run_stat_paths(target_node, paths, max_entries, state)
        else
          {:error, msg} -> error(msg)
        end
    end
  end

  def call("disk_free", args, state) do
    path = args["path"]

    cond do
      blank?(path) ->
        error("path is required.")

      true ->
        with {:ok, target_node} <- NodeArg.resolve(args["node"]),
             :ok <- check_isolation(target_node),
             :ok <- check_scope(path, state) do
          rpc_probe_result(Cluster.rpc(target_node, Probes, :disk_free, [path]))
        else
          {:error, msg} -> error(msg)
        end
    end
  end

  # -----------------------------------------------------------------------
  # git_probe dispatch
  # -----------------------------------------------------------------------

  defp run_git_probe(node, directory, "status", _args),
    do: rpc_probe_result(Cluster.rpc(node, Probes, :git_status, [directory]))

  defp run_git_probe(node, directory, "head", _args),
    do: rpc_probe_result(Cluster.rpc(node, Probes, :git_head, [directory]))

  defp run_git_probe(node, directory, "log", args),
    do:
      rpc_probe_result(
        Cluster.rpc(node, Probes, :git_log, [directory, args["path"], args["limit"]])
      )

  defp run_git_probe(node, directory, "touches", args) do
    rpc_probe_result(
      Cluster.rpc(node, Probes, :git_commit_touches_path?, [
        directory,
        args["commit"],
        args["path"]
      ])
    )
  end

  defp run_git_probe(node, directory, "diff_stat", args) do
    rpc_probe_result(
      Cluster.rpc(node, Probes, :git_diff_stat, [directory, args["from_sha"], args["to_sha"]])
    )
  end

  # -----------------------------------------------------------------------
  # stat_paths dispatch (single batched RPC for every in-scope path)
  # -----------------------------------------------------------------------

  defp run_stat_paths(target_node, paths, max_entries, state) do
    roots = allowed_roots(state)
    {allowed, denied} = Enum.split_with(paths, &within_allowed_root?(&1, roots))

    denied_results =
      Map.new(denied, &{&1, %{path: &1, denied: true, reason: scope_denial_reason()}})

    case allowed do
      [] ->
        text(Jason.encode!(Enum.map(paths, &Map.fetch!(denied_results, &1))))

      _ ->
        case Cluster.rpc(target_node, Probes, :stat_paths, [allowed, max_entries]) do
          results when is_list(results) ->
            allowed_results = Map.new(results, &{&1.path, &1})
            combined = Map.merge(denied_results, allowed_results)
            text(Jason.encode!(Enum.map(paths, &Map.fetch!(combined, &1))))

          {:error, reason} ->
            error("Probe failed: #{Cluster.node_unavailable_message(reason) || inspect(reason)}")
        end
    end
  end

  # -----------------------------------------------------------------------
  # Shared: RPC result normalization, node resolution, isolation, scoping
  # -----------------------------------------------------------------------

  # OrcaHub.Probes functions always return {:ok, result} | {:error, string}
  # for their own failures — a STRING reason distinguishes a probe-level
  # failure from Cluster.rpc/5's own transport-error tuples ({:error,
  # :node_unassigned}, {:error, {:node_unavailable, n}}, etc., all atoms/
  # tuples, never bare strings — see Cluster.rpc/5's doc).
  defp rpc_probe_result({:ok, result}), do: text(Jason.encode!(result))
  defp rpc_probe_result({:error, reason}) when is_binary(reason), do: error(reason)

  defp rpc_probe_result({:error, reason}) do
    error("Probe failed: #{Cluster.node_unavailable_message(reason) || inspect(reason)}")
  end

  defp check_isolation(target_node) do
    if NodePolicy.cross_node_allowed?(target_node) do
      :ok
    else
      {:error, NodePolicy.denial_message(target_node)}
    end
  end

  defp check_scope(path, state) do
    if within_allowed_root?(path, allowed_roots(state)) do
      :ok
    else
      {:error, "#{path} #{scope_denial_reason()}"}
    end
  end

  defp scope_denial_reason,
    do:
      "is outside this session's scoped directories — must be a registered project's " <>
        "directory (or a sub-path of one, e.g. a worktree) or this session's own directory."

  defp allowed_roots(state) do
    project_dirs = HubRPC.list_projects() |> Enum.map(& &1.directory)

    own_dir =
      case state.orca_session_id && HubRPC.get_session(state.orca_session_id) do
        %{directory: dir} -> [dir]
        _ -> []
      end

    Enum.uniq(project_dirs ++ own_dir)
  end

  defp within_allowed_root?(path, roots) when is_binary(path) do
    expanded = Path.expand(path)

    Enum.any?(roots, fn root ->
      root = Path.expand(root)
      expanded == root or String.starts_with?(expanded, root <> "/")
    end)
  end

  defp within_allowed_root?(_path, _roots), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
