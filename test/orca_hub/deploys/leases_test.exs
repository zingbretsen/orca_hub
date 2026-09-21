defmodule OrcaHub.Deploys.LeasesTest do
  @moduledoc """
  Coverage for the deploy mutual-exclusion primitive
  (.context/deploy-jobs-design.md §2.1). `async: false` because the
  concurrency test spawns `Task`s that need the test's own DB connection —
  see `OrcaHub.DataCase`'s `shared: not tags[:async]` sandbox setup, and
  `OrcaHub.IssuesKeyAllocationTest` for the same pattern.

  Every test uses a unique `target`, since the suite runs against the shared
  dev DB and `deploy_leases` is not guaranteed empty.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Deploys.{Lease, Leases}

  defp target(name), do: "#{name}-#{System.unique_integer([:positive])}"

  defp insert_lease!(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Lease{}
    |> Lease.changeset(
      Map.merge(
        %{
          runner_node: "n1@test",
          acquired_at: now,
          expires_at: DateTime.add(now, 300, :second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "acquire/2" do
    test "succeeds on a free target" do
      target = target("free")
      job_id = Ecto.UUID.generate()

      assert {:ok, lease} =
               Leases.acquire(target, job_id: job_id, runner_node: "n1@test", note: "deploy abc")

      assert lease.target == target
      assert lease.job_id == job_id
      assert lease.runner_node == "n1@test"
      assert lease.note == "deploy abc"
      assert is_nil(lease.released_at)
      assert Leases.held?(lease)
      assert DateTime.compare(lease.expires_at, lease.acquired_at) == :gt
    end

    test "defaults expires_at to acquired_at + the default TTL" do
      target = target("ttl")
      assert {:ok, lease} = Leases.acquire(target)

      assert DateTime.diff(lease.expires_at, lease.acquired_at, :second) ==
               Leases.default_ttl_seconds()

      assert {:ok, short} = Leases.acquire(target("ttl-short"), ttl_seconds: 60)
      assert DateTime.diff(short.expires_at, short.acquired_at, :second) == 60
    end

    test "a second acquire on a held target returns {:error, :held, current_lease}" do
      target = target("held")
      assert {:ok, first} = Leases.acquire(target, note: "first")

      assert {:error, :held, current} = Leases.acquire(target, note: "second")
      assert current.id == first.id
      assert current.note == "first"

      # The loser inserted nothing: still exactly one row for this target.
      assert [only] = Leases.list_for_target(target)
      assert only.id == first.id
    end

    test "N concurrent acquires against the same target produce EXACTLY ONE winner" do
      target = target("race")
      n = 8

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(OrcaHub.Repo, self(), self())
            Leases.acquire(target, note: "racer #{i}")
          end)
        end

      results = Task.await_many(tasks, 15_000)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, :held, _}, &1))

      assert length(winners) == 1, "expected exactly one winner, got #{length(winners)}"
      assert length(losers) == n - 1
      assert length(winners) + length(losers) == n

      [{:ok, winner}] = winners

      # Every loser was told who actually holds it, and nobody else's row landed.
      for {:error, :held, current} <- losers, do: assert(current.id == winner.id)
      assert Leases.list_for_target(target) |> length() == 1
      assert Leases.get_live(target).id == winner.id
    end
  end

  describe "expiry" do
    test "an expired lease is stolen, and the old row is RETAINED with released_at set" do
      target = target("expired")
      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-600, :second)

      stale =
        insert_lease!(%{
          target: target,
          job_id: Ecto.UUID.generate(),
          acquired_at: DateTime.add(past, -60, :second),
          expires_at: past,
          note: "abandoned deploy"
        })

      refute Leases.held?(stale)

      assert {:ok, fresh} = Leases.acquire(target, note: "takeover")
      assert fresh.id != stale.id
      assert Leases.held?(fresh)

      # Reaping, not overwriting: the old row is still there, marked.
      reaped = Repo.get!(Lease, stale.id)
      refute is_nil(reaped.released_at)
      assert reaped.note == "abandoned deploy [expired]"

      # Both rows survive; only the new one is live.
      assert Leases.list_for_target(target) |> length() == 2
      assert Leases.get_live(target).id == fresh.id
    end

    test "reaping marks a note-less lease too (coalesce, not SQL's NULL-swallowing ||)" do
      target = target("expired-nonote")
      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60, :second)

      stale = insert_lease!(%{target: target, expires_at: past, note: nil})

      assert {:ok, _fresh} = Leases.acquire(target)
      assert Repo.get!(Lease, stale.id).note == "[expired]"
    end

    test "reap_expired/1 reaps outside of an acquire and leaves unexpired leases alone" do
      expired_target = target("reap-expired")
      live_target = target("reap-live")
      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60, :second)

      stale = insert_lease!(%{target: expired_target, expires_at: past})
      {:ok, live} = Leases.acquire(live_target)

      assert {:ok, [reaped]} = Leases.reap_expired(expired_target)
      assert reaped.id == stale.id
      refute is_nil(Repo.get!(Lease, stale.id).released_at)

      assert {:ok, []} = Leases.reap_expired(live_target)
      assert is_nil(Repo.get!(Lease, live.id).released_at)
    end
  end

  describe "release/2" do
    test "is a no-op for a non-matching job_id" do
      target = target("release-mismatch")
      job_id = Ecto.UUID.generate()
      {:ok, lease} = Leases.acquire(target, job_id: job_id)

      assert {:error, :not_found} = Leases.release(lease.id, Ecto.UUID.generate())
      assert {:error, :not_found} = Leases.release(lease.id, nil)
      assert {:error, :not_found} = Leases.release(Ecto.UUID.generate(), job_id)
      assert {:error, :not_found} = Leases.release("not-a-uuid", job_id)
      assert {:error, :not_found} = Leases.release(nil, job_id)

      # Still held by its owner throughout.
      assert Leases.get_live(target).id == lease.id

      assert {:ok, released} = Leases.release(lease.id, job_id)
      assert released.id == lease.id
      refute is_nil(released.released_at)
      refute Leases.held?(released)
      assert is_nil(Leases.get_live(target))
    end

    test "releasing frees the target for a new acquire" do
      target = target("release-frees")
      job_id = Ecto.UUID.generate()
      {:ok, first} = Leases.acquire(target, job_id: job_id)
      assert {:ok, _} = Leases.release(first.id, job_id)

      assert {:ok, second} = Leases.acquire(target)
      assert second.id != first.id
      assert Leases.list_for_target(target) |> length() == 2
    end

    test "a lease taken before its job existed is released with a nil job_id" do
      target = target("release-no-job")
      {:ok, lease} = Leases.acquire(target)
      assert is_nil(lease.job_id)

      assert {:error, :not_found} = Leases.release(lease.id, Ecto.UUID.generate())
      assert {:ok, released} = Leases.release(lease.id, nil)
      assert released.id == lease.id
      refute is_nil(released.released_at)
    end

    test "a second release of the same lease is a no-op" do
      target = target("release-twice")
      job_id = Ecto.UUID.generate()
      {:ok, lease} = Leases.acquire(target, job_id: job_id)

      assert {:ok, _} = Leases.release(lease.id, job_id)
      assert {:error, :not_found} = Leases.release(lease.id, job_id)
    end

    test "release_for_job/1 releases the lease a finished job was holding" do
      target = target("release-by-job")
      job_id = Ecto.UUID.generate()
      {:ok, lease} = Leases.acquire(target, job_id: job_id)

      assert {:ok, [released]} = Leases.release_for_job(job_id)
      assert released.id == lease.id
      assert is_nil(Leases.get_live(target))

      assert {:ok, []} = Leases.release_for_job(job_id)
      assert {:ok, []} = Leases.release_for_job(Ecto.UUID.generate())
      assert {:ok, []} = Leases.release_for_job(nil)
    end
  end

  describe "renew/2" do
    test "bumps expires_at on an unreleased lease and refuses a released one" do
      target = target("renew")
      job_id = Ecto.UUID.generate()
      {:ok, lease} = Leases.acquire(target, job_id: job_id, ttl_seconds: 60)

      assert {:ok, renewed} = Leases.renew(lease.id, 3_600)
      assert DateTime.compare(renewed.expires_at, lease.expires_at) == :gt
      assert Leases.held?(renewed)

      {:ok, _} = Leases.release(lease.id, job_id)
      assert {:error, :not_found} = Leases.renew(lease.id, 3_600)
      assert {:error, :not_found} = Leases.renew("not-a-uuid", 3_600)
    end
  end

  describe "list_live/0" do
    test "excludes released and expired leases" do
      held_target = target("live-held")
      released_target = target("live-released")
      expired_target = target("live-expired")

      {:ok, held} = Leases.acquire(held_target)

      job_id = Ecto.UUID.generate()
      {:ok, releasable} = Leases.acquire(released_target, job_id: job_id)
      {:ok, _} = Leases.release(releasable.id, job_id)

      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60, :second)
      expired = insert_lease!(%{target: expired_target, expires_at: past})

      live_ids = Leases.list_live() |> Enum.map(& &1.id)

      assert held.id in live_ids
      refute releasable.id in live_ids
      refute expired.id in live_ids
    end
  end
end
