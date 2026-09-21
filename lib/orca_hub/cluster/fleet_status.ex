defmodule OrcaHub.Cluster.FleetStatus do
  @moduledoc """
  "What code is actually running out there" — one row per node, computed on
  demand for the Settings page's drift view.

  This is the reporting half of the hot-deploy feature. The reconciler
  (`OrcaHub.Cluster.CodePush`) already converges the fleet; this answers the
  question an operator asks BEFORE trusting that it did.

  ## Two shas per node, never conflated

    * **build sha** — `OrcaHub.BuildInfo.sha/0` on that node: the image it
      booted from. Never hot-pushed, so always true about the image and,
      after a hot load, no longer true about the running code.
    * **live code sha** — `OrcaHub.Cluster.CodeStamp`: the generation
      actually applied there, or nothing at all, in which case the node says
      so rather than echoing its build sha.

  A node can be "on the right build sha" and still be drifted, or be on an
  old image and perfectly in sync. Showing only one of the two is how a
  fleet gets misread in both directions.

  ## The comparison basis is named, not assumed

  Drift is measured against the hub's DESIRED state, and what that is
  depends on whether a generation has been published:

    * `:generation` — the current `OrcaHub.CodeGenerations` generation. This
      is the real desired state whenever one exists, and it is what
      `CodePush` reconciles toward.
    * `:local_ebin` — this node's own `ebin`, when no generation exists.
      The pre-generation `CodeSync.check_drift/1` behaviour, kept because a
      fleet with nothing published is exactly the fleet most likely to have
      quietly drifted.

  `basis` is on the report so the UI can say which one it used. A drift
  count whose meaning depends on invisible state is not a drift count.

  ## `missing` is three answers, not one

  `CodeSync.drift/3` calls a module "missing" when the node raises on
  `:erlang.get_module_info/2` — true for a module the node has never heard
  of AND for one that is simply not loaded yet. Reporting the union as one
  number implies a certainty that probe does not have.

  So every module the md5 pass called missing gets a second, cheap
  `:code.which/1` probe (`CodeSync.code_locations/3`) and lands in exactly
  one of:

    * `absent` — `:non_existing` there. Genuinely not on the node.
    * `not_loaded` — in its code path, not currently loaded.
    * `unknown` — the probe could not say. Counted and labelled as unknown,
      never quietly merged into either of the above.

  When the classification probe itself fails, every missing module is
  `unknown` and `missing_classified?` is `false` — the UI is expected to
  render that as uncertainty rather than as a precise zero.
  """

  require Logger

  alias OrcaHub.Cluster
  alias OrcaHub.Cluster.{BeamTransport, CodeStamp, CodeSync}
  alias OrcaHub.CodeGenerations
  alias OrcaHub.CodeGenerations.Provenance

  @type basis :: %{kind: :generation | :local_ebin, label: String.t()}

  @doc """
  The whole fleet: this node plus every connected node.

  Returns `%{basis:, generation:, checked_at:, total_checked:, nodes: [...]}`.
  Never raises — an unreachable node becomes a row carrying `:error`, since
  "we could not ask" is itself a thing the operator needs to see next to
  the nodes that answered.
  """
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    generation = current_generation()
    {basis, entries} = basis_and_entries(generation, opts)

    nodes =
      [node() | Node.list()]
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&node_report(&1, entries, generation, opts))

    %{
      basis: basis,
      generation: generation && CodeGenerations.summarize(generation),
      checked_at: DateTime.utc_now(),
      total_checked: length(entries),
      nodes: nodes
    }
  end

  defp current_generation do
    CodeGenerations.current()
  rescue
    # The Settings page only runs on the hub, so this is defence rather
    # than a supported path — but a reporting view that crashes the page
    # when the DB hiccups is worse than one that falls back to comparing
    # against the local build.
    error ->
      Logger.warning("FleetStatus: could not read the current generation — #{inspect(error)}")
      nil
  end

  defp basis_and_entries(nil, opts) do
    dir = Keyword.get(opts, :ebin) || CodeSync.default_ebin_dir()

    case CodeSync.load_beams(dir) do
      {:ok, entries} ->
        {%{kind: :local_ebin, label: "this node's build (no generation published)"},
         Enum.map(entries, &Map.take(&1, [:module, :md5]))}

      {:error, reason} ->
        {%{kind: :local_ebin, label: "unavailable — #{CodeSync.describe_error(reason)}"}, []}
    end
  end

  defp basis_and_entries(generation, _opts) do
    entries =
      generation.id
      |> CodeGenerations.manifest()
      |> Enum.map(fn {mod, md5} -> %{module: String.to_atom(mod), md5: md5} end)

    # An untrusted generation is still the comparison BASIS — the operator
    # needs to see the drift it describes — but the label has to say plainly
    # that nothing will ever be applied from it. See
    # OrcaHub.CodeGenerations.Provenance.
    untrusted =
      if Provenance.trusted?(generation.provenance),
        do: "",
        else: " — REFUSED, untrusted publish provenance (#{generation.provenance || "none"})"

    {%{
       kind: :generation,
       label:
         "generation #{short(generation.base_sha)}" <>
           "#{if generation.dirty, do: " (dirty)"}#{untrusted}"
     }, entries}
  end

  @doc """
  One node's row: its two shas, its drift counts, and whatever could not be
  determined about it.
  """
  @spec node_report(node(), [map()], term(), keyword()) :: map()
  def node_report(target, entries, generation, opts \\ []) do
    base = %{
      node: target,
      name: Cluster.node_name(target),
      self?: target == node(),
      total_checked: length(entries),
      identical: 0,
      drifted: [],
      absent: [],
      not_loaded: [],
      unknown: [],
      orphaned: [],
      missing_classified?: true,
      error: nil
    }

    base
    |> Map.merge(build_info(target))
    |> Map.merge(code_stamp(target))
    |> Map.merge(drift(target, entries, opts))
    |> Map.merge(orphans(target, generation, entries))
    |> annotate()
  end

  # ------------------------------------------------------------------
  # The two shas
  # ------------------------------------------------------------------

  defp build_info(target) do
    case BeamTransport.sha(target) do
      {:ok, sha} -> %{build_sha: sha, build_sha_error: nil}
      {:error, reason} -> %{build_sha: nil, build_sha_error: BeamTransport.describe_error(reason)}
    end
  end

  defp code_stamp(target) do
    case CodeStamp.read(target) do
      {:ok, stamp} -> %{code: stamp, code_error: nil}
      {:error, reason} -> %{code: nil, code_error: BeamTransport.describe_error(reason)}
    end
  end

  # ------------------------------------------------------------------
  # Drift
  # ------------------------------------------------------------------

  defp drift(_target, [], _opts), do: %{}

  defp drift(target, entries, opts) do
    case CodeSync.drift(entries, target, opts) do
      {:ok, report} ->
        %{drifted: report.drifted, identical: length(report.identical)}
        |> Map.merge(classify_missing(target, report.missing, opts))

      {:error, reason} ->
        %{error: CodeSync.describe_error(reason)}
    end
  end

  # See the moduledoc: the md5 pass cannot tell "absent" from "not loaded",
  # so ask :code.which/1 and keep the three answers apart.
  defp classify_missing(_target, [], _opts),
    do: %{absent: [], not_loaded: [], unknown: [], missing_classified?: true}

  defp classify_missing(target, missing, opts) do
    case CodeSync.code_locations(target, missing, opts) do
      {:ok, locations} ->
        grouped = Enum.group_by(missing, &Map.get(locations, &1, :unknown))

        %{
          absent: Enum.sort(Map.get(grouped, :absent, [])),
          not_loaded: Enum.sort(Map.get(grouped, :not_loaded, [])),
          unknown: Enum.sort(Map.get(grouped, :unknown, [])),
          missing_classified?: true
        }

      {:error, _reason} ->
        # Everything the md5 pass called missing stays missing; we just
        # cannot say WHY. Flagged so the UI can label the uncertainty
        # instead of rendering a confident "0 absent".
        %{absent: [], not_loaded: [], unknown: Enum.sort(missing), missing_classified?: false}
    end
  end

  # ------------------------------------------------------------------
  # Orphans
  # ------------------------------------------------------------------

  # Modules the node can still execute that the desired set does not
  # contain. Hot loading cannot remove a module, so these accumulate
  # silently; CodePush.purge_orphaned/1 is the explicit operator remedy.
  defp orphans(_target, _generation, []), do: %{}

  defp orphans(target, _generation, entries) do
    case BeamTransport.resident_modules(target) do
      {:ok, resident} ->
        wanted = MapSet.new(entries, & &1.module)

        orphaned =
          resident
          |> MapSet.difference(wanted)
          |> Enum.reject(&(&1 in BeamTransport.excluded_modules()))
          |> Enum.sort()

        %{orphaned: orphaned}

      {:error, _reason} ->
        %{orphaned: []}
    end
  end

  # ------------------------------------------------------------------
  # Verdict
  # ------------------------------------------------------------------

  # A single field the UI can colour on, so "this node is wrong" does not
  # have to be reconstructed from five counts at a glance.
  defp annotate(row) do
    out_of_date = length(row.drifted) + length(row.absent) + length(row.not_loaded)

    status =
      cond do
        row.error -> :unreachable
        row.total_checked == 0 -> :unknown
        out_of_date > 0 -> :out_of_date
        row.unknown != [] -> :uncertain
        row.orphaned != [] -> :orphans_only
        true -> :in_sync
      end

    Map.put(row, :status, status)
  end

  defp short(nil), do: "unknown"
  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
end
