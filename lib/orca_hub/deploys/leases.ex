defmodule OrcaHub.Deploys.Leases do
  @moduledoc """
  Context for deploy leases — the mutual-exclusion primitive for project
  deploys (.context/deploy-jobs-design.md §2.1/§2.2).

  ## What this is

  A **lease with a TTL, not a lock.** The holder can die: `deploy-orca-hub.sh`
  restarts the very hub that launched it, and any deploy can be OOM-killed or
  lose its node. A lock would wedge the target forever; a lease expires.

  ## The two rules that matter

  1. **Exclusion is the partial unique index, never application code.**
     `deploy_leases_one_live_per_target` is `UNIQUE (target) WHERE released_at
     IS NULL`. `acquire/2` INSERTs and lets Postgres adjudicate; a loser sees a
     `unique_violation` and gets `{:error, :held, current_lease}`. There is no
     read-then-write anywhere in this module — a check-then-insert has a window
     between the two statements and would silently admit two deploys.
  2. **Expiry is reaping, not overwriting.** Stealing an expired lease is an
     `UPDATE ... SET released_at = ... WHERE target = $1 AND released_at IS
     NULL AND expires_at < $2` that runs in the SAME transaction as the insert,
     so there is no window where the target is unowned. The stolen row STAYS in
     the table with `released_at` set (and ` [expired]` appended to its note),
     so "who held this and how did it end" is answerable after the fact.

  ## Liveness is a conjunction, and this module only owns half of it

  A lease is *held* iff `released_at IS NULL AND expires_at > now`. That is the
  backstop signal, not the authoritative one: per §2.2 there is deliberately NO
  renewer process (it would die with the hub restart it is meant to survive),
  so the real "is a deploy still running?" answer is the linked JOB's status.
  Callers are expected to cross-check `job_id`'s status and report the
  disagreements (`stale_lease`, `lease_expired_job_running`) rather than
  trusting the TTL alone. This module never looks at the jobs table.

  ## Routing

  The table lives on the hub, so agent nodes reach these functions through
  `OrcaHub.HubRPC` (`acquire_deploy_lease/2` and friends) — which is what makes
  the lease a cluster-wide mutex for free. Because of that indirection,
  `node()` in here is the HUB's node, so callers should pass their own
  `:runner_node` rather than relying on the default.
  """

  import Ecto.Query

  alias OrcaHub.{Deploys.Lease, Repo}

  # 90 minutes — generously over the observed envelope of the longest deploy
  # (2-arch native buildx + 3x180s Flux polls + two remote restarts). Per
  # §2.2 the TTL is a backstop for "the job record is unreachable", so it is
  # sized to be embarrassingly long rather than tight.
  @default_ttl_seconds 5400

  @doc "Default lease TTL in seconds (#{@default_ttl_seconds})."
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc """
  Acquires the lease for `target`, reaping an expired one in the same
  transaction if there is one.

  `attrs` (map or keyword): `:job_id`, `:session_id`, `:runner_node`, `:note`,
  `:ttl_seconds`.

  Returns `{:ok, lease}`, `{:error, :held, current_lease}` when another live
  lease already holds the target, or `{:error, changeset}` for a malformed
  lease.

  The `{:error, :held, _}` path is driven by the unique index catching a
  concurrent INSERT — not by looking first. `current_lease` is read only
  AFTER the index has already refused us, purely so the caller can say who
  holds it.
  """
  def acquire(target, attrs \\ %{}) do
    attrs = Map.new(attrs)
    now = now()
    ttl = attrs[:ttl_seconds] || @default_ttl_seconds

    insert_attrs = %{
      target: target,
      job_id: attrs[:job_id],
      session_id: attrs[:session_id],
      runner_node: attrs[:runner_node] || Atom.to_string(node()),
      note: attrs[:note],
      acquired_at: now,
      expires_at: DateTime.add(now, ttl, :second)
    }

    result =
      Repo.transaction(fn ->
        reap_expired_query(target, now) |> Repo.update_all([])

        # `mode: :savepoint` so a unique_violation does not abort the
        # surrounding transaction — we still want to READ the winning lease
        # before rolling back, and an aborted transaction cannot run queries.
        %Lease{}
        |> Lease.changeset(insert_attrs)
        |> Repo.insert(mode: :savepoint)
        |> case do
          {:ok, lease} -> lease
          {:error, changeset} -> Repo.rollback(acquire_failure(target, changeset, now))
        end
      end)

    case result do
      {:ok, lease} -> {:ok, lease}
      {:error, {:held, current}} -> {:error, :held, current}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp acquire_failure(target, changeset, now) do
    if held_conflict?(changeset) do
      {:held, get_live(target, now) || get_unreleased(target)}
    else
      changeset
    end
  end

  defp held_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:target, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  @doc """
  Releases a lease, keyed on BOTH `id` and `job_id` so a stale caller cannot
  release a lease it no longer owns (the job it remembers finished long ago and
  somebody else now holds the target).

  A no-op returns `{:error, :not_found}` — that covers a wrong `job_id`, an
  unknown id, and an already-released lease alike.

  A lease acquired before its job existed carries a NULL `job_id` and is
  released by passing `nil`, which matches `job_id IS NULL`. Such a lease has
  no owner token by construction; if that matters to a caller, acquire with a
  `job_id` (or any opaque owner id) in the first place.
  """
  def release(lease_id, job_id) do
    with {:ok, id} <- cast_required_id(lease_id),
         {:ok, job_id} <- cast_id(job_id) do
      now = now()

      from(l in Lease, where: l.id == ^id and is_nil(l.released_at))
      |> where_job_id(job_id)
      |> select([l], l)
      |> update(set: [released_at: ^now, updated_at: ^DateTime.to_naive(now)])
      |> Repo.update_all([])
      |> case do
        {1, [lease]} -> {:ok, lease}
        {0, _} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Releases every live lease taken for `job_id` — the job-completion path
  (§2.2: release is driven by job completion, not by the deploy script).

  Returns `{:ok, released_leases}`; an empty list is a perfectly normal
  outcome (the lease was already released, or the job never took one).
  """
  def release_for_job(job_id) do
    case cast_id(job_id) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, job_id} ->
        now = now()

        {_n, leases} =
          from(l in Lease,
            where: l.job_id == ^job_id and is_nil(l.released_at),
            select: l,
            update: [set: [released_at: ^now, updated_at: ^DateTime.to_naive(now)]]
          )
          |> Repo.update_all([])

        {:ok, leases}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Extends an unreleased lease's `expires_at` to `now + ttl_seconds`.

  Offered for completeness and for the operator escape hatch in the
  `lease_expired_job_running` case; per §2.2 the OrcaHub target does NOT renew
  on a timer — there is deliberately no renewer process.

  Already-released leases are not renewable: `{:error, :not_found}`.
  """
  def renew(lease_id, ttl_seconds \\ @default_ttl_seconds) do
    with {:ok, id} <- cast_required_id(lease_id) do
      now = now()
      expires_at = DateTime.add(now, ttl_seconds, :second)

      from(l in Lease,
        where: l.id == ^id and is_nil(l.released_at),
        select: l,
        update: [set: [expires_at: ^expires_at, updated_at: ^DateTime.to_naive(now)]]
      )
      |> Repo.update_all([])
      |> case do
        {1, [lease]} -> {:ok, lease}
        {0, _} -> {:error, :not_found}
      end
    end
  end

  @doc """
  Reaps `target`'s expired-but-unreleased lease, if any, outside of an
  acquire. Returns `{:ok, reaped_leases}`.

  `acquire/2` already does this transactionally, so this is for sweeps and
  operator tooling. Note §2.2's caveat: an expired lease whose JOB is still
  non-terminal must NOT be reaped — the caller owes that cross-check, this
  function only knows about the clock.
  """
  def reap_expired(target) do
    {_n, leases} =
      target
      |> reap_expired_query(now())
      |> select([l], l)
      |> Repo.update_all([])

    {:ok, leases}
  end

  @doc "Fetches a lease by id. `nil`/garbage ids return `nil` rather than raising."
  def get_lease(id) do
    case cast_id(id) do
      {:ok, nil} -> nil
      {:ok, id} -> Repo.get(Lease, id)
      {:error, _} -> nil
    end
  end

  @doc """
  The lease currently HELD for `target` (unreleased and unexpired), or `nil`.
  """
  def get_live(target, now \\ nil) do
    now = now || now()

    Repo.one(
      from l in Lease,
        where: l.target == ^target and is_nil(l.released_at) and l.expires_at > ^now
    )
  end

  @doc """
  Every currently HELD lease — released AND expired leases are excluded.
  Most recently acquired first.
  """
  def list_live do
    now = now()

    Repo.all(
      from l in Lease,
        where: is_nil(l.released_at) and l.expires_at > ^now,
        order_by: [desc: l.acquired_at]
    )
  end

  @doc """
  Lease history for `target`, most recent first — including released and
  expired rows, which is the whole point of reaping instead of overwriting.

  `opts[:limit]` defaults to 20.
  """
  def list_for_target(target, opts \\ %{}) do
    limit = Map.new(opts)[:limit] || 20

    Repo.all(
      from l in Lease,
        where: l.target == ^target,
        order_by: [desc: l.acquired_at, desc: l.inserted_at],
        limit: ^limit
    )
  end

  @doc "Whether `lease` is held right now (unreleased and unexpired)."
  def held?(%Lease{} = lease), do: Lease.held?(lease, now())
  def held?(nil), do: false

  # ── internals ─────────────────────────────────────────────────────────

  # The reaping UPDATE. Run inside acquire/2's transaction so there is no
  # window between "the expired lease is gone" and "mine exists".
  #
  # NOTE: §2.1's snippet writes `note = note || ' [expired]'`, which in SQL
  # nulls the note out entirely whenever it was NULL. coalesce + btrim keeps
  # the marker in every case.
  defp reap_expired_query(target, now) do
    from(l in Lease,
      where: l.target == ^target and is_nil(l.released_at) and l.expires_at < ^now,
      update: [
        set: [
          released_at: ^now,
          updated_at: ^DateTime.to_naive(now),
          note: fragment("btrim(coalesce(?, '') || ' [expired]')", l.note)
        ]
      ]
    )
  end

  # Fallback for the `{:error, :held, _}` payload: if the conflicting lease is
  # unreleased but already past its TTL (it can only be so by a hair — acquire
  # just reaped anything older, in the same transaction), report it anyway
  # rather than handing the caller a bare nil.
  defp get_unreleased(target) do
    Repo.one(from l in Lease, where: l.target == ^target and is_nil(l.released_at))
  end

  defp where_job_id(query, nil), do: where(query, [l], is_nil(l.job_id))
  defp where_job_id(query, job_id), do: where(query, [l], l.job_id == ^job_id)

  # Ids arrive from MCP tool args and RPC callers, so garbage must not raise
  # an Ecto.Query.CastError (or Ecto's "comparison with nil is forbidden") out
  # of a release/renew call.
  defp cast_required_id(nil), do: {:error, :not_found}
  defp cast_required_id(id), do: cast_id(id)

  defp cast_id(nil), do: {:ok, nil}

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_), do: {:error, :not_found}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
