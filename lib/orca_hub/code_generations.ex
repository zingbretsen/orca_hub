defmodule OrcaHub.CodeGenerations do
  @moduledoc """
  Read/write surface for the hub's durable DESIRED code state.

  A *generation* is a full set of compiled `:orca_hub` beams plus the
  provenance and toolchain metadata needed to decide, later and for a node
  nobody was thinking about at publish time, whether those beams may safely
  be loaded there. `OrcaHub.Cluster.CodePush` owns the loop that acts on
  them; this module owns only persistence.

  **Hub-only.** Everything here touches `OrcaHub.Repo` directly and must run
  on the hub. Agent nodes reach it through `OrcaHub.HubRPC`, never by
  calling this module on themselves — see that module's moduledoc.

  ## Reading a generation in two halves

  The manifest (`manifest/1`: module name + md5, no binaries) and the beams
  (`fetch_beams/2`: binaries for a named subset) are deliberately separate
  calls. A reconcile is overwhelmingly a *diff* operation, and the diff
  needs only md5s: for a node that is already up to date — the common case
  on a healthy fleet — the whole reconcile costs one small manifest query
  and moves no beam bytes at all. Fetching the full generation up front
  would move ~7.6 MiB per node per nodeup, most of it to discover that
  nothing needed to change.

  ## Retention

  Generations are large. `prune/1` keeps the newest few and deletes the
  rest; module rows cascade. The current generation is never pruned
  regardless of how the count falls out — a retention policy that can
  delete the thing the fleet is supposed to be running is not a retention
  policy.
  """

  import Ecto.Query

  alias OrcaHub.CodeGenerations.{CodeGeneration, CodeGenerationModule, Provenance}
  alias OrcaHub.Repo

  @default_keep 5

  # ------------------------------------------------------------------
  # Writing
  # ------------------------------------------------------------------

  @doc """
  Stores `entries` as a new generation.

  `entries` are `OrcaHub.Cluster.CodeSync` beam payload entries:
  `%{module: atom, binary: binary, md5: binary, path: charlist}`. `attrs`
  carries the provenance/toolchain fields (see
  `OrcaHub.CodeGenerations.CodeGeneration`).

  The generation row and every module row are written in ONE transaction:
  a half-written generation is indistinguishable from a complete one at
  read time, and reconciling a node toward a truncated module set would
  quietly load a partial build.

  The row is stamped with `OrcaHub.CodeGenerations.Provenance.current/0` —
  what KIND of process published it. That stamp is put on the STRUCT and
  the field is not castable, so it describes the code calling this function
  and cannot be supplied (or faked) through `attrs`. An applying node
  refuses a generation whose stamp it does not trust; see that module for
  why a shared database makes this necessary.
  """
  def publish(attrs, entries) when is_map(attrs) and is_list(entries) do
    gen_attrs =
      attrs
      |> Map.put(:module_count, length(entries))
      |> Map.put(:total_bytes, Enum.reduce(entries, 0, &(byte_size(&1.binary) + &2)))

    Repo.transaction(fn ->
      generation =
        %CodeGeneration{provenance: Provenance.current()}
        |> CodeGeneration.changeset(gen_attrs)
        |> Repo.insert!()

      rows =
        Enum.map(entries, fn entry ->
          %{
            id: Ecto.UUID.generate(),
            code_generation_id: generation.id,
            module: to_string(entry.module),
            md5: entry.md5,
            beam: entry.binary,
            beam_bytes: byte_size(entry.binary)
          }
        end)

      # insert_all in chunks: ~277 rows each carrying a beam binary is well
      # past what one statement's parameter budget tolerates.
      rows
      |> Enum.chunk_every(25)
      |> Enum.each(&Repo.insert_all(CodeGenerationModule, &1))

      generation
    end)
  end

  @doc """
  Increments a generation's apply-attempt counter and returns the updated row.

  Called BEFORE the beams are applied, never after: the counter exists to
  survive the apply killing the process that incremented it. An increment
  that only lands on success would count zero attempts in exactly the
  scenario the circuit breaker is for.
  """
  def record_apply_attempt(%CodeGeneration{} = generation) do
    {1, [updated]} =
      from(g in CodeGeneration, where: g.id == ^generation.id, select: g)
      |> Repo.update_all(inc: [apply_attempts: 1])

    updated
  end

  @doc """
  Marks a generation as having PROVEN healthy, resetting its apply budget.

  The reset matters as much as the status: a generation that has survived
  the health window earns a fresh budget, so an unrelated crash weeks later
  does not start counting from wherever the last boot left off.
  """
  def mark_healthy(%CodeGeneration{} = generation), do: mark_healthy(generation.id)

  def mark_healthy(id) when is_binary(id) do
    {count, _} =
      from(g in CodeGeneration, where: g.id == ^id and g.status == "pending")
      |> Repo.update_all(
        set: [
          status: "healthy",
          apply_attempts: 0,
          proven_healthy_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ]
      )

    if count == 1, do: {:ok, get(id)}, else: {:error, :not_pending}
  end

  @doc """
  Quarantines a generation: it exhausted its apply budget without proving
  healthy, and must never be applied again.
  """
  def quarantine(%CodeGeneration{} = generation, note), do: quarantine(generation.id, note)

  def quarantine(id, note) when is_binary(id) do
    update_status(id, "quarantined", note, [])
  end

  @doc """
  Supersedes a generation — the operator action to run after a real image
  deploy lands and the fleet is genuinely newer than the stored desired
  state.

  Distinct from `quarantine/2` on purpose. Both stop a generation being
  applied, but they mean opposite things: superseded is "this is no longer
  what we want", quarantined is "this is suspected of being harmful". A
  drift report that conflated them would tell an operator the wrong story
  about their own fleet.
  """
  def supersede(%CodeGeneration{} = generation, note), do: supersede(generation.id, note)

  def supersede(id, note) when is_binary(id) do
    update_status(id, "superseded", note, superseded_at: DateTime.utc_now())
  end

  defp update_status(id, status, note, extra) do
    set =
      [status: status, updated_at: DateTime.utc_now()] ++
        extra ++ if(note, do: [notes: note], else: [])

    case from(g in CodeGeneration, where: g.id == ^id) |> Repo.update_all(set: set) do
      {1, _} -> {:ok, get(id)}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Deletes all but the newest `keep` generations, never touching `current/0`.

  Returns the number deleted.
  """
  def prune(keep \\ @default_keep) when is_integer(keep) and keep > 0 do
    protected =
      [current(), latest()]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)

    survivors =
      from(g in CodeGeneration,
        order_by: [desc: g.inserted_at],
        limit: ^keep,
        select: g.id
      )
      |> Repo.all()

    keep_ids = Enum.uniq(protected ++ survivors)

    {deleted, _} =
      from(g in CodeGeneration, where: g.id not in ^keep_ids) |> Repo.delete_all()

    deleted
  end

  # ------------------------------------------------------------------
  # Reading
  # ------------------------------------------------------------------

  @doc """
  The generation the fleet should currently be reconciled toward: the
  newest one that is neither superseded nor quarantined. `nil` when there
  is nothing to reconcile to, which is the correct state for a fleet
  running pure image code.
  """
  def current do
    from(g in CodeGeneration,
      where: g.status in ["pending", "healthy"],
      order_by: [desc: g.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "The newest generation of ANY status, for status reporting."
  def latest do
    from(g in CodeGeneration, order_by: [desc: g.inserted_at], limit: 1) |> Repo.one()
  end

  @doc "A generation by id, or nil."
  def get(id) when is_binary(id), do: Repo.get(CodeGeneration, id)

  @doc "The newest `limit` generations, without their module rows."
  def list(limit \\ 20) do
    from(g in CodeGeneration, order_by: [desc: g.inserted_at], limit: ^limit) |> Repo.all()
  end

  @doc """
  Module names and md5s for a generation, WITHOUT the beam binaries — the
  cheap half of a reconcile. Returns `%{"Elixir.Foo" => md5}`.
  """
  def manifest(id) when is_binary(id) do
    from(m in CodeGenerationModule,
      where: m.code_generation_id == ^id,
      select: {m.module, m.md5}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Beam payload entries for `module_names` (strings) within a generation, in
  the shape `OrcaHub.Cluster.CodeSync.push/3` expects. Passing `:all`
  fetches every module.

  The `path` field is synthesised rather than stored: `:code.load_binary/3`
  uses it only as the module's recorded load path, and the originating
  machine's `_build` path is not meaningful on the node being reconciled.
  """
  def fetch_beams(id, :all) do
    from(m in CodeGenerationModule, where: m.code_generation_id == ^id)
    |> Repo.all()
    |> Enum.map(&to_entry/1)
  end

  def fetch_beams(id, module_names) when is_list(module_names) do
    names = Enum.map(module_names, &to_string/1)

    from(m in CodeGenerationModule,
      where: m.code_generation_id == ^id and m.module in ^names
    )
    |> Repo.all()
    |> Enum.map(&to_entry/1)
  end

  defp to_entry(%CodeGenerationModule{} = row) do
    %{
      module: String.to_atom(row.module),
      binary: row.beam,
      md5: row.md5,
      path: ~c"generation://" ++ to_charlist(row.module) ++ ~c".beam"
    }
  end

  @doc """
  A generation summarised for display/telemetry — everything except the
  beams. Safe to log, safe to hand to an MCP caller.
  """
  def summarize(nil), do: nil

  def summarize(%CodeGeneration{} = g) do
    %{
      id: g.id,
      base_sha: g.base_sha,
      dirty: g.dirty,
      status: g.status,
      apply_attempts: g.apply_attempts,
      proven_healthy_at: g.proven_healthy_at,
      published_by: g.published_by,
      published_from_node: g.published_from_node,
      provenance: g.provenance,
      provenance_trusted: Provenance.trusted?(g.provenance),
      erts_version: g.erts_version,
      otp_release: g.otp_release,
      elixir_version: g.elixir_version,
      compiler_version: g.compiler_version,
      module_count: g.module_count,
      total_bytes: g.total_bytes,
      forced_reasons: g.forced_reasons,
      notes: g.notes,
      created_at: g.inserted_at
    }
  end
end
