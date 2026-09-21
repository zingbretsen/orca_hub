defmodule OrcaHub.MCP.Tools.CodePush do
  @moduledoc """
  Operator surface for the code RECONCILIATION loop
  (`OrcaHub.Cluster.CodePush`): publish a generation, inspect what the fleet
  is being reconciled toward, supersede a generation after a real deploy,
  and kick a reconcile by hand.

  ## Where each tool actually runs

  This matters more here than in most tool categories, because the work is
  split across two nodes on purpose.

  `publish_code_generation` has an ORIGIN — a node that owns a checkout and
  has compiled it (`MIX_ENV=prod mix compile`). In practice that is the
  local Debian systemd agent, not the hub pod, which has no checkout at
  all. The tool routes `collect_payload/1` to that node via
  `OrcaHub.Cluster.rpc/5`, then hands the resulting payload to the HUB,
  which is the only node that may store a generation or fan it out.

  That split is forced by the topology, not by taste. The cluster runs
  `-kernel connect_all false`, so an agent's `Node.list/0` contains only the
  hub — an agent physically cannot reach its peers. Publishing is therefore
  always "agent hands beams to hub; hub fans out", and a design where the
  compiling node pushed directly to the fleet could not work at all.

  The other three tools are pure hub operations and are proxied through
  `OrcaHub.HubRPC` from wherever they are called.

  ## Refusals are the point

  `publish_code_generation` refuses a dirty checkout, and refuses a change
  set `OrcaHub.Cluster.HotLoadGate` classifies as not hot-loadable. Both
  refusals are overridable (`allow_dirty`, `force`) and both overrides are
  RECORDED on the generation — `dirty: true`, and the full list of
  overridden gate reasons. Neither can be taken silently. A fleet running
  uncommitted code is a fact an operator must be able to discover later
  without reconstructing what someone typed.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC, NodePolicy}
  alias OrcaHub.MCP.Tools.NodeArg

  require Logger

  # Collecting a payload reads ~277 beams (~7.6 MiB) off disk on the origin
  # node and ships them back over distribution.
  @collect_timeout :timer.minutes(3)

  def list do
    [
      %{
        "name" => "publish_code_generation",
        "description" =>
          "Publish compiled beams as the hub's DESIRED CODE GENERATION, then reconcile " <>
            "every connected node to it. This is hot code loading as reconciliation, not " <>
            "a deploy: the generation is stored durably, so a node that connects later " <>
            "(an agent that was powered off, a pod that just restarted) is brought up to " <>
            "it automatically, and the hub applies it to itself on boot. The ORIGIN must " <>
            "be a node that owns a checkout; publishing runs `MIX_ENV=prod mix compile` " <>
            "there ITSELF rather than trusting whatever is already in " <>
            "<directory>/_build/prod/lib/orca_hub/ebin, then verifies every beam in the " <>
            "payload was produced by this node's own Erlang compiler — a stale artifact " <>
            "from a different toolchain passes every runtime-level check while being " <>
            "exactly the wrong bytes. REFUSES a dirty checkout (pass allow_dirty to override; the " <>
            "generation is then permanently marked dirty) and REFUSES a change set the " <>
            "hot-load safety gate rejects — dependency/config/migration/supervision-tree/" <>
            "defstruct changes need a real deploy (pass force to override; the " <>
            "overridden reasons are recorded on the generation). Does NOT restart " <>
            "anything and does NOT touch the slow deploy path.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "directory" => %{
              "type" => "string",
              "description" =>
                "Absolute path to the checkout on the origin node, e.g. \"/home/zach/orca_hub\"."
            },
            "node" => %{
              "type" => "string",
              "description" =>
                "Erlang node name that owns the checkout and compiled it, e.g. " <>
                  "\"orca@debian\". Defaults to your own session's node. Must be " <>
                  "currently connected."
            },
            "base" => %{
              "type" => "string",
              "description" =>
                "Git ref the change set is measured against for the safety gate. " <>
                  "Defaults to the current generation's base SHA, or — if there is no " <>
                  "generation — the hub image's SHA, i.e. whatever the fleet is actually " <>
                  "running now."
            },
            "ebin" => %{
              "type" => "string",
              "description" =>
                "Override the beam directory. Defaults to " <>
                  "<directory>/_build/prod/lib/orca_hub/ebin."
            },
            "allow_dirty" => %{
              "type" => "boolean",
              "description" =>
                "Publish from a checkout with uncommitted or untracked changes. The " <>
                  "generation records dirty: true permanently. Default false."
            },
            "force" => %{
              "type" => "boolean",
              "description" =>
                "Publish despite a hot-load safety gate refusal. The overridden reasons " <>
                  "are recorded on the generation and logged. Default false."
            },
            "force_compile" => %{
              "type" => "boolean",
              "description" =>
                "Go straight to `mix compile --force` rather than an incremental compile. " <>
                  "Rarely needed — a payload that disagrees with this node's compiler " <>
                  "triggers a forced recompile automatically. Default false."
            },
            "notes" => %{
              "type" => "string",
              "description" => "Free-text note stored on the generation."
            }
          },
          "required" => ["directory"]
        }
      },
      %{
        "name" => "code_generation_status",
        "description" =>
          "What the fleet is currently being reconciled toward: the active code " <>
            "generation (base SHA, dirty flag, module count, ERTS version, circuit-" <>
            "breaker status and apply budget), whether reconciliation is enabled on the " <>
            "hub at all, the connected nodes, and the last reconcile outcome per node.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "supersede_code_generation",
        "description" =>
          "Clear the current code generation so no node is reconciled toward it any " <>
            "more. This is the action to run AFTER a real image deploy lands and the " <>
            "fleet is genuinely newer than the stored generation. Deliberately manual: " <>
            "the hub will not infer that a deploy happened. Does not roll anything back " <>
            "— nodes keep whatever code they are already running.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "note" => %{
              "type" => "string",
              "description" => "Why it was superseded, stored on the generation."
            }
          }
        }
      },
      %{
        "name" => "purge_orphaned_modules",
        "description" =>
          "Unload modules a node still carries that the current code generation does NOT " <>
            "contain — i.e. modules deleted from source. Hot loading can never remove a " <>
            "module, so a deleted one stays resident and callable on every node that ever " <>
            "had it; a reconcile reports these as `orphaned` but will not remove them. " <>
            "This is the explicit, destructive follow-up. It never kills a process: a " <>
            "module whose old code is still running comes back as wedged, untouched. " <>
            "Refuses entirely when no generation is published, since without one there is " <>
            "nothing for a module to be orphaned relative to.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "node" => %{
              "type" => "string",
              "description" =>
                "Erlang node to purge orphaned modules on. Defaults to your own node."
            }
          }
        }
      },
      %{
        "name" => "reconcile_code",
        "description" =>
          "Reconcile connected nodes against the current code generation by hand — " <>
            "normally unnecessary, since this happens on hub boot and whenever a node " <>
            "connects. Only pushes what DIFFERS, skips nodes whose image is newer than " <>
            "the generation, and skips nodes on a different ERTS version.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "node" => %{
              "type" => "string",
              "description" => "Reconcile only this node. Omit to reconcile every connected node."
            }
          }
        }
      }
    ]
  end

  # ------------------------------------------------------------------

  def call("publish_code_generation", args, state) do
    directory = args["directory"]

    if blank?(directory) do
      error("directory is required — the absolute path to the checkout on the origin node.")
    else
      with {:ok, origin} <- NodeArg.resolve(args["node"]),
           :ok <- check_isolation(origin),
           {:ok, base} <- resolve_base(args["base"]),
           {:ok, payload} <- collect(origin, directory, base, args) do
        publish(payload, args, state)
      else
        {:error, message} -> error(message)
      end
    end
  end

  def call("code_generation_status", _args, _state) do
    case safe_hub(fn -> HubRPC.code_push_status() end) do
      {:ok, status} -> text(render_status(status))
      {:error, message} -> error(message)
    end
  end

  def call("supersede_code_generation", args, _state) do
    case safe_hub(fn -> HubRPC.supersede_code_generation(args["note"]) end) do
      {:ok, {:ok, generation}} ->
        text(
          "Superseded generation #{generation.id} (#{generation.base_sha}).\n" <>
            "No node will be reconciled toward it any more. Nothing was rolled back — " <>
            "every node keeps the code it is already running."
        )

      {:ok, {:error, :no_generation}} ->
        error("There is no current code generation to supersede.")

      {:ok, other} ->
        error("Unexpected result: #{inspect(other)}")

      {:error, message} ->
        error(message)
    end
  end

  def call("purge_orphaned_modules", args, _state) do
    with {:ok, target} <- NodeArg.resolve(args["node"]),
         :ok <- check_isolation(target),
         {:ok, result} <- safe_hub(fn -> HubRPC.purge_orphaned_modules(target) end) do
      case result do
        {:ok, report} ->
          text(render_purge(report))

        {:error, :no_generation} ->
          error("There is no current code generation to compare against.")

        {:error, {:untrusted_generation, explanation}} ->
          error(
            "REFUSED: the current code generation's publish provenance is not trusted, so it " <>
              "cannot be used to decide what is orphaned — every real module on the node " <>
              "would qualify. #{explanation}"
          )

        other ->
          error("Unexpected result: #{inspect(other)}")
      end
    else
      {:error, message} -> error(message)
    end
  end

  def call("reconcile_code", args, _state) do
    result =
      case args["node"] do
        nil ->
          safe_hub(fn -> HubRPC.reconcile_code_all() end)

        "" ->
          safe_hub(fn -> HubRPC.reconcile_code_all() end)

        name ->
          with {:ok, target} <- NodeArg.resolve(name) do
            safe_hub(fn -> HubRPC.reconcile_code_node(target) end)
          end
      end

    case result do
      {:ok, {:ok, report}} -> text(render_reconcile(report))
      {:ok, {:error, :no_generation}} -> error("There is no current code generation.")
      {:ok, %{} = node_report} -> text(render_node(node_report))
      {:ok, other} -> error("Unexpected result: #{inspect(other)}")
      {:error, message} -> error(message)
    end
  end

  # ------------------------------------------------------------------
  # Publish
  # ------------------------------------------------------------------

  defp collect(origin, directory, base, args) do
    opts =
      [dir: directory, base: base]
      |> put_unless_nil(:ebin, args["ebin"])
      |> Keyword.put(:allow_dirty, args["allow_dirty"] == true)
      |> Keyword.put(:force, args["force"] == true)
      |> Keyword.put(:force_compile, args["force_compile"] == true)

    case Cluster.rpc(origin, OrcaHub.Cluster.CodePush, :collect_payload, [opts], @collect_timeout) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, {:dirty_checkout, message}} ->
        {:error, "Refusing to publish: #{message}"}

      {:error, {:gate_refused, explanation, _reasons}} ->
        {:error,
         "Refusing to publish — the hot-load safety gate rejected this change set.\n\n" <>
           explanation <>
           "\n\nThese changes need the real deploy path. If you are certain hot loading " <>
           "is correct here, re-run with force: true; the overridden reasons will be " <>
           "recorded on the generation."}

      {:error, {:gate_unavailable, reason}} ->
        {:error, "Could not classify the change set (base=#{base || "none"}): #{inspect(reason)}"}

      {:error, {:git_failed, message}} ->
        {:error, "git failed on #{origin}: #{message}"}

      {:error, {:compile_failed, _, _} = reason} ->
        {:error,
         "Refusing to publish — the checkout did not compile on #{origin}.\n\n" <>
           OrcaHub.Cluster.CodePush.describe_provenance_error(reason)}

      {:error, {:mixed_payload, _} = reason} ->
        {:error,
         "Refusing to publish — " <>
           OrcaHub.Cluster.CodePush.describe_provenance_error(reason) <>
           ".\n\nA forced recompile was already attempted and did not resolve it. This is " <>
           "usually a toolchain mismatch on #{origin}: check that its Erlang/Elixir match " <>
           "the repo's pin before publishing."}

      {:error, reason} ->
        {:error,
         Cluster.node_unavailable_message(reason) ||
           "Payload collection failed: #{inspect(reason)}"}

      other ->
        {:error, "Payload collection failed: #{inspect(other)}"}
    end
  end

  defp publish(payload, args, state) do
    opts =
      [published_by: published_by(state)]
      |> put_unless_nil(:notes, args["notes"])

    case safe_hub(fn -> HubRPC.publish_code_generation(payload, opts) end) do
      {:ok, {:ok, report}} -> text(render_publish(report))
      {:ok, {:error, reason}} -> error("Publish failed: #{inspect(reason)}")
      {:ok, other} -> error("Unexpected publish result: #{inspect(other)}")
      {:error, message} -> error(message)
    end
  end

  # The gate needs something to diff against, and the only honest default is
  # "whatever the fleet is running": the current generation's SHA if there is
  # one, else the hub image's SHA. If neither is knowable, the base stays nil
  # and CodePush skips classification rather than inventing a ref — see its
  # gate_verdict/3.
  defp resolve_base(explicit) when is_binary(explicit) and explicit != "", do: {:ok, explicit}

  defp resolve_base(_) do
    case safe_hub(fn -> HubRPC.code_push_status() end) do
      {:ok, %{generation: %{base_sha: sha}}} when is_binary(sha) -> {:ok, sha}
      {:ok, _} -> {:ok, hub_image_sha()}
      {:error, message} -> {:error, message}
    end
  end

  defp hub_image_sha do
    case OrcaHub.BuildInfo.sha() do
      "unknown" -> nil
      sha -> sha
    end
  end

  defp published_by(%{orca_session_id: id}) when is_binary(id), do: "session:#{id}"
  defp published_by(_), do: "node:#{node()}"

  # ------------------------------------------------------------------
  # Rendering
  # ------------------------------------------------------------------

  defp render_status(%{generation: nil} = status) do
    """
    No code generation is published.

    The fleet is running pure image code — nothing is being reconciled.
    Reconciliation enabled on the hub: #{status.enabled}
    Connected nodes: #{format_nodes(status.connected_nodes)}
    """
  end

  defp render_status(%{generation: generation} = status) do
    """
    Current code generation
    #{generation_lines(generation)}#{refusal_banner(status[:generation_refusal])}
    Reconciliation enabled on the hub: #{status.enabled}
    Health window: #{status.health_window_ms}ms   Apply budget: #{generation.apply_attempts}/#{status.max_apply_attempts}
    Connected nodes: #{format_nodes(status.connected_nodes)}

    Last reconcile per node:
    #{render_last(status.last_reconcile)}
    """
  end

  defp generation_lines(g) do
    """
      id:        #{g.id}
      base SHA:  #{g.base_sha}#{if g.dirty, do: "   *** DIRTY — the fleet is running UNCOMMITTED code ***", else: ""}
      status:    #{g.status}#{healthy_suffix(g)}
      modules:   #{g.module_count} (#{g.total_bytes} bytes)
      toolchain: ERTS #{g.erts_version}, OTP #{g.otp_release}, Elixir #{g.elixir_version}, compiler #{g.compiler_version || "unrecorded"}
      published: #{g.created_at} by #{g.published_by || "unknown"} from #{g.published_from_node || "unknown"}
      provenance: #{g.provenance || "NONE"}#{provenance_suffix(g)}#{forced_lines(g)}#{notes_line(g)}
    """
  end

  # A generation nothing will ever apply must not read like a healthy one —
  # see OrcaHub.CodeGenerations.Provenance.
  defp provenance_suffix(%{provenance_trusted: false}),
    do: "   *** NOT TRUSTED — this generation will NOT be applied to any node ***"

  defp provenance_suffix(_), do: ""

  defp refusal_banner(nil), do: ""

  defp refusal_banner(explanation),
    do: "\n  !! THIS GENERATION IS REFUSED AND WILL NEVER BE APPLIED: #{explanation}\n"

  defp healthy_suffix(%{status: "healthy", proven_healthy_at: at}) when not is_nil(at),
    do: " (proven healthy at #{at})"

  defp healthy_suffix(%{status: "pending"}), do: " (not yet proven healthy)"
  defp healthy_suffix(_), do: ""

  defp forced_lines(%{forced_reasons: []}), do: ""

  defp forced_lines(%{forced_reasons: reasons}) do
    "\n  FORCED past #{length(reasons)} safety-gate refusal(s):\n" <>
      Enum.map_join(reasons, "\n", fn r ->
        "    - [#{r["category"]}] #{r["path"]}: #{r["message"]}"
      end)
  end

  defp notes_line(%{notes: nil}), do: ""
  defp notes_line(%{notes: notes}), do: "\n  notes:     #{notes}"

  defp render_last(last) when map_size(last) == 0, do: "  (none yet)"

  defp render_last(last) do
    Enum.map_join(last, "\n", fn {name, result} -> "  " <> render_node(result, name) end)
  end

  defp render_reconcile(%{generation: generation, nodes: nodes}) do
    """
    Reconciled against generation #{generation.base_sha} (#{generation.module_count} modules).

    #{if nodes == %{}, do: "  (no connected nodes)", else: Enum.map_join(nodes, "\n", fn {name, r} -> "  " <> render_node(r, name) end)}
    """
  end

  defp render_publish(%{generation: generation} = report) do
    """
    Published code generation #{generation.id}.
    #{generation_lines(generation)}
    #{if report[:nodes] in [nil, %{}], do: "No other nodes were connected to reconcile.", else: "Reconciled:\n" <> Enum.map_join(report.nodes, "\n", fn {name, r} -> "  " <> render_node(r, name) end)}

    The generation is stored durably: any node that connects later — including one
    that is currently powered off — is reconciled to it automatically, and the hub
    re-applies it to itself on boot.
    """
  end

  defp render_purge(%{purged: [], deleted_not_purged: [], wedged: [], errors: []} = r),
    do: "#{r.node}: no orphaned modules — everything resident is part of the current generation."

  defp render_purge(r) do
    """
    #{r.node} orphaned-module purge:
      fully unloaded:      #{format_nodes(r.purged)}
      deleted, not purged: #{format_nodes(r.deleted_not_purged)}#{if r.deleted_not_purged == [], do: "", else: "\n        (uncallable for new work; their old code goes away as the processes on it exit)"}
      wedged, untouched:   #{format_nodes(r.wedged)}#{if r.wedged == [], do: "", else: "\n        (processes are still running these; refused rather than killed — retry later)"}#{if r.errors == [], do: "", else: "\n  errors: " <> Enum.join(r.errors, "; ")}
    """
  end

  defp render_node(result, name \\ nil)

  defp render_node(%{status: :in_sync} = r, name),
    do: "#{prefix(name)}in sync (#{r[:identical] || 0} modules identical)#{orphan_suffix(r)}"

  defp render_node(%{status: :reconciled} = r, name),
    do:
      "#{prefix(name)}reconciled — #{r.pushed} module(s) loaded#{wedged_suffix(r)}#{orphan_suffix(r)}"

  defp render_node(%{status: :partial} = r, name),
    do:
      "#{prefix(name)}PARTIAL — #{r.pushed} loaded, errors: #{Enum.join(r.errors, "; ")}#{wedged_suffix(r)}"

  defp render_node(%{status: status, reason: reason}, name),
    do: "#{prefix(name)}#{status} — #{reason}"

  defp render_node(other, name), do: "#{prefix(name)}#{inspect(other)}"

  # Orphans are reported on every reconcile but never acted on — removing
  # them is purge_orphaned_modules, a separate and destructive step.
  defp orphan_suffix(%{orphaned: []}), do: ""

  defp orphan_suffix(%{orphaned: orphaned}),
    do:
      "; #{length(orphaned)} orphaned module(s) still resident but absent from the generation " <>
        "(deleted from source — hot loading cannot remove them; use purge_orphaned_modules): " <>
        Enum.join(Enum.take(orphaned, 10), ", ") <>
        if(length(orphaned) > 10, do: ", …", else: "")

  defp orphan_suffix(_), do: ""

  defp wedged_suffix(%{wedged: []}), do: ""

  defp wedged_suffix(%{wedged: wedged}),
    do:
      ", #{length(wedged)} wedged (processes still running old code; refused rather than forced — retried on the next reconcile): #{Enum.join(wedged, ", ")}"

  defp wedged_suffix(_), do: ""

  defp prefix(nil), do: ""
  defp prefix(name), do: "#{name}: "

  defp format_nodes([]), do: "(none)"
  defp format_nodes(nodes), do: Enum.join(nodes, ", ")

  # ------------------------------------------------------------------

  defp check_isolation(target) do
    if NodePolicy.cross_node_allowed?(target) do
      :ok
    else
      {:error,
       "This node is isolated and may not initiate cross-node calls, so it cannot collect " <>
         "a payload from #{target}."}
    end
  end

  # Every hub call here crosses :erpc when this runs on an agent, so a hub
  # that is down surfaces as a readable message rather than an exit that
  # takes the MCP connection with it.
  defp safe_hub(fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      Logger.warning("[MCP] code push hub call failed: #{kind} #{inspect(reason)}")
      {:error, "Could not reach the hub: #{kind} #{inspect(reason)}"}
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, _key, ""), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
