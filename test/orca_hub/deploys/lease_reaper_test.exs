defmodule OrcaHub.Deploys.LeaseReaperTest do
  @moduledoc """
  Coverage for the lease-release half of .context/deploy-jobs-design.md
  §2.2 — the broadcast-driven release, the boot sweep that exists because
  a deploy restarts the very hub the reaper lives in, and the one case the
  reaper deliberately refuses to fix.

  Each test starts its OWN reaper (unnamed, boot sweep disabled) rather
  than leaning on the application's, so a `{:job_finished, ...}` broadcast
  can be aimed at a subscription this test knows exists.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Deploys, JobWatcher, Jobs}
  alias OrcaHub.Deploys.{Lease, LeaseReaper, Leases}

  @moduletag timeout: 60_000

  setup do
    prev_targets = Application.get_env(:orca_hub, :deploy_targets)

    on_exit(fn ->
      if prev_targets,
        do: Application.put_env(:orca_hub, :deploy_targets, prev_targets),
        else: Application.delete_env(:orca_hub, :deploy_targets)
    end)

    # No name (the application already owns `LeaseReaper`) and no boot
    # sweep timer — every sweep in here is driven explicitly.
    reaper = start_supervised!({LeaseReaper, name: nil, boot_sweep_delay_ms: nil})
    %{reaper: reaper}
  end

  # Registers the target in the deploy registry as well as naming it. The
  # sweep enumerates REGISTRY keys (plus currently-live leases) rather than
  # every row in the table — see `OrcaHub.Deploys.sweepable_targets/1` — so
  # an unregistered key with an EXPIRED lease would not be visited. Every
  # lease `OrcaHub.Deploys` takes is for a registry target, so registering
  # here is the realistic shape, not a workaround.
  defp target(name) do
    key = "reaper-#{name}-#{System.unique_integer([:positive])}"

    targets =
      Application.get_env(:orca_hub, :deploy_targets, %{})
      |> Map.put(key, %{name: key, allowed_flags: [], positional: :none})

    Application.put_env(:orca_hub, :deploy_targets, targets)
    key
  end

  defp job!(status) do
    {:ok, job} =
      Jobs.create_job(%{
        directory: System.tmp_dir!(),
        runner_node: Atom.to_string(node()),
        command: "true",
        status: status
      })

    job
  end

  defp insert_lease!(target, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Lease{}
    |> Lease.changeset(
      Map.merge(
        %{
          target: target,
          runner_node: Atom.to_string(node()),
          acquired_at: now,
          expires_at: DateTime.add(now, 300, :second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp reload(lease), do: Leases.get_lease(lease.id)

  describe "broadcast-driven release" do
    test "releases the lease on {:job_finished, ...}", %{reaper: reaper} do
      target = target("finished")
      job = job!("running")
      {:ok, lease} = Leases.acquire(target, %{job_id: job.id})

      assert :ok = LeaseReaper.watch(reaper, job.id)
      assert Leases.held?(reload(lease))

      # Exactly what OrcaHub.JobWatcher.finalize/3 broadcasts.
      {:ok, _} = Jobs.update_job(job, %{status: "succeeded"})

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        JobWatcher.topic(job.id),
        {:job_finished, job.id, "succeeded"}
      )

      # Round-trip through the GenServer so the broadcast has certainly
      # been handled. Deliberately NOT a sweep — a sweep would release this
      # lease by itself and prove nothing about the broadcast path.
      sync(reaper)

      released = reload(lease)
      refute is_nil(released.released_at)
      refute Leases.held?(released)
    end

    test "a job that finished before the subscription landed is still released", %{
      reaper: reaper
    } do
      target = target("already-done")
      job = job!("running")
      {:ok, lease} = Leases.acquire(target, %{job_id: job.id})
      {:ok, _} = Jobs.update_job(job, %{status: "failed"})

      # No broadcast at all — watch/2 re-checks the status on subscribing,
      # which is the race-closing half of the design.
      assert :ok = LeaseReaper.watch(reaper, job.id)

      refute is_nil(reload(lease).released_at)
    end

    # The application's own (named) reaper is subscribed to this topic too,
    # so either instance may be the one that releases — they are the same
    # code path, and the assertion still fails if that path is broken.
    test "the launch announcement is what makes a deploy watchable", %{reaper: reaper} do
      target = target("announced")
      job = job!("succeeded")
      {:ok, lease} = Leases.acquire(target, %{job_id: job.id})

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        Deploys.topic(),
        {:deploy_lease_acquired, job.id, lease.id, target}
      )

      sync(reaper)

      refute is_nil(reload(lease).released_at)
    end
  end

  describe "boot sweep" do
    test "releases a lease whose job is already terminal", %{reaper: reaper} do
      target = target("stale")
      job = job!("succeeded")
      {:ok, lease} = Leases.acquire(target, %{job_id: job.id})

      report = LeaseReaper.sweep(reaper)

      assert {target, job.id} in report.released
      refute is_nil(reload(lease).released_at)
    end

    test "releases an EXPIRED lease whose job is terminal", %{reaper: reaper} do
      target = target("expired-done")
      job = job!("failed")
      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60, :second)
      lease = insert_lease!(target, %{job_id: job.id, expires_at: past})

      report = LeaseReaper.sweep(reaper)

      assert {target, job.id} in report.released
      refute is_nil(reload(lease).released_at)
    end

    test "FLAGS but never releases an expired lease whose job is still running", %{
      reaper: reaper
    } do
      target = target("expired-running")
      job = job!("running")
      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60, :second)
      lease = insert_lease!(target, %{job_id: job.id, expires_at: past})

      report = LeaseReaper.sweep(reaper)

      assert {target, job.id} in report.expired_job_running
      refute {target, job.id} in report.released

      # The whole point of the job cross-check: a pure-TTL reaper would
      # hand this target to a second deploy while the first is still
      # running.
      still_held = reload(lease)
      assert is_nil(still_held.released_at)
    end

    test "leaves a live lease over a live job alone, and re-subscribes to it", %{reaper: reaper} do
      target = target("in-flight")
      job = job!("running")
      {:ok, lease} = Leases.acquire(target, %{job_id: job.id})

      report = LeaseReaper.sweep(reaper)

      assert {target, job.id} in report.in_flight
      assert is_nil(reload(lease).released_at)

      # The sweep's subscription is what replaces the one the restart
      # destroyed — a completion arriving AFTER the sweep must still
      # release, with no further prompting.
      {:ok, _} = Jobs.update_job(job, %{status: "succeeded"})

      Phoenix.PubSub.broadcast(
        OrcaHub.PubSub,
        JobWatcher.topic(job.id),
        {:job_finished, job.id, "succeeded"}
      )

      sync(reaper)

      refute is_nil(reload(lease).released_at)
    end
  end

  # Synchronous round-trip: a system message is handled in mailbox order,
  # so once this returns every earlier broadcast has been processed.
  defp sync(reaper), do: :sys.get_state(reaper)
end
