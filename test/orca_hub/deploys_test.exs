defmodule OrcaHub.DeploysTest do
  @moduledoc """
  Coverage for deploy orchestration (.context/deploy-jobs-design.md §2.3 and
  §2.7).

  The `escape_cgroup` tests drive **real detached processes over a real
  `ssh localhost`** — no mocks, no fake launcher. That is deliberate: the
  first draft of §2.3 was wrong precisely because it was reasoned on paper
  ("the sentinel will record the ssh client's exit status"), and only a
  real-process experiment caught it. A mocked version of these tests would
  reproduce the paper reasoning, not the kernel's behaviour.

  `ORCA_JOBS_DIR` is pointed at a temp dir under `$HOME` — never `/tmp`,
  which `PrivateTmp=yes` makes invisible across the ssh boundary while
  `$HOME` is shared. A `/tmp` jobs dir produces a convincing false
  negative here.

  Stand-in shell scripts only. Nothing in this file may ever invoke a real
  deploy script.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Deploys, HubRPC, Jobs}
  alias OrcaHub.Deploys.{Lease, Leases}
  alias OrcaHub.Jobs.Paths

  @moduletag timeout: 180_000

  setup do
    root = Path.join(System.user_home!(), ".orca_hub_deploys_test")
    dir = Path.join(root, "t#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_jobs_dir = System.get_env("ORCA_JOBS_DIR")
    prev_targets = Application.get_env(:orca_hub, :deploy_targets)
    prev_pid_timeout = Application.get_env(:orca_hub, :deploy_remote_pid_timeout_ms)

    System.put_env("ORCA_JOBS_DIR", dir)
    Application.put_env(:orca_hub, :deploy_remote_pid_timeout_ms, 8_000)

    on_exit(fn ->
      reap_processes(dir)

      if prev_jobs_dir,
        do: System.put_env("ORCA_JOBS_DIR", prev_jobs_dir),
        else: System.delete_env("ORCA_JOBS_DIR")

      if prev_targets,
        do: Application.put_env(:orca_hub, :deploy_targets, prev_targets),
        else: Application.delete_env(:orca_hub, :deploy_targets)

      if prev_pid_timeout,
        do: Application.put_env(:orca_hub, :deploy_remote_pid_timeout_ms, prev_pid_timeout),
        else: Application.delete_env(:orca_hub, :deploy_remote_pid_timeout_ms)

      File.rm_rf(dir)
      # Leaves nothing behind at all when this was the last test to run.
      File.rmdir(root)
    end)

    %{dir: dir}
  end

  # Every pid this test's jobs ever recorded — local wrapper AND remote —
  # gets a group KILL, so a stand-in that outlives its assertions cannot
  # leak past the test.
  defp reap_processes(dir) do
    for path <- Path.wildcard(Path.join(dir, "*.pid")),
        {pid, _} <- [path |> File.read!() |> String.trim() |> Integer.parse()] do
      System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  # ── fixtures ───────────────────────────────────────────────────────

  defp stub_script!(dir, body) do
    path = Path.join(dir, "deploy-stub-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp put_target!(overrides) do
    key = "test-target-#{System.unique_integer([:positive])}"

    config =
      Map.merge(
        %{
          name: "Test Target",
          allowed_flags: [],
          positional: :none,
          escape_cgroup: false,
          ttl_seconds: 300,
          timeout_seconds: 120,
          verify_command: nil
        },
        Map.new(overrides)
      )

    Application.put_env(:orca_hub, :deploy_targets, %{key => config})
    key
  end

  defp leases_for(target), do: Leases.list_for_target(target, %{limit: 20})

  defp unreleased(target), do: Enum.filter(leases_for(target), &is_nil(&1.released_at))

  defp running_job!(dir) do
    {:ok, job} =
      Jobs.create_job(%{
        directory: dir,
        runner_node: Atom.to_string(node()),
        command: "sleep 0",
        status: "running"
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

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end

  defp wait_for_terminal(job_id, tries \\ 600) do
    job = HubRPC.get_job(job_id)

    cond do
      job.status not in ["running", "verifying"] ->
        job

      tries <= 0 ->
        flunk("job #{job_id} never finished (stuck at #{job.status})")

      true ->
        Process.sleep(100)
        wait_for_terminal(job_id, tries - 1)
    end
  end

  defp alive?(pid), do: File.exists?("/proc/#{pid}")

  defp read_pid!(path) do
    wait_until(fn -> File.exists?(path) and File.read!(path) != "" end)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  # ── command composition ────────────────────────────────────────────

  describe "command composition" do
    test "escape_cgroup: false hands the plain script invocation to the job", %{dir: dir} do
      script = stub_script!(dir, "exit 0")
      target = put_target!(%{command: script, directory: dir, allowed_flags: ["--dry-run"]})

      assert {:ok, result} = Deploys.start_deploy(target, flags: ["--dry-run"])

      assert result.job.command == "'#{script}' '--dry-run'"
      assert HubRPC.get_job(result.job.id).command == "'#{script}' '--dry-run'"
      refute result.job.command =~ "ssh"

      wait_for_terminal(result.job.id)
    end

    test "escape_cgroup: true composes the ssh-localhost remote half, byte for byte" do
      jobs = Paths.jobs_dir()

      command =
        Deploys.escape_cgroup_command("JOBID", "'/opt/deploy.sh' '--skip-arm64'",
          directory: "/srv/app"
        )

      expected =
        ~S"""
        # OrcaHub deploy job JOBID — escape_cgroup (.context/deploy-jobs-design.md §2.3).
        # The REMOTE half (user.slice, via ssh) owns the log and the exit sentinel;
        # this local half only blocks on them so the job does not finish instantly,
        # and is expected to be SIGTERMed by the deploy's own `systemctl restart`.
        ORCA_REMOTE_SH='__JOBS__/JOBID.remote.sh'
        ORCA_PIDFILE='__JOBS__/JOBID.remote.pid'
        ORCA_SENTINEL='__JOBS__/JOBID.exit'

        rm -f "$ORCA_REMOTE_SH" "$ORCA_PIDFILE" "$ORCA_SENTINEL"

        cat > "$ORCA_REMOTE_SH" <<'ORCA_REMOTE_EOF'
        echo $$ > '__JOBS__/JOBID.remote.pid'
        cd '/srv/app' || exit 70
        '/opt/deploy.sh' '--skip-arm64'
        rc=$?
        printf '%s' "$rc" > '__JOBS__/JOBID.exit.tmp'
        mv '__JOBS__/JOBID.exit.tmp' '__JOBS__/JOBID.exit'
        ORCA_REMOTE_EOF

        ssh -o BatchMode=yes localhost 'setsid sh '\''__JOBS__/JOBID.remote.sh'\'' < /dev/null > '\''__JOBS__/JOBID.log'\'' 2>&1 & sleep 0.5' < /dev/null

        # Bounded wait for the remote to report its pid (20s; the BEAM-side
        # rebind gives up sooner and cancels, this is the standalone backstop).
        ORCA_REMOTE=
        ORCA_TRIES=0
        while [ -z "$ORCA_REMOTE" ] && [ "$ORCA_TRIES" -lt 100 ]; do
          if [ -s "$ORCA_PIDFILE" ]; then
            ORCA_REMOTE=$(cat "$ORCA_PIDFILE")
          else
            sleep 0.2
          fi
          ORCA_TRIES=$((ORCA_TRIES + 1))
        done

        # 1s, not a leisurely poll: once the remote dies WITHOUT a sentinel this
        # loop's exit is racing JobWatcher's own tick, which sees the (rebound)
        # remote pid gone and would finalize_crashed instead of reporting 70.
        while [ ! -f "$ORCA_SENTINEL" ] && [ -n "$ORCA_REMOTE" ] && [ -d "/proc/$ORCA_REMOTE" ]; do
          sleep 1
        done

        if [ -f "$ORCA_SENTINEL" ]; then
          ORCA_RC=$(cat "$ORCA_SENTINEL")
        else
          ORCA_RC=70
        fi
        case "$ORCA_RC" in
          '' | *[!0-9]*) ORCA_RC=70 ;;
        esac
        exit "$ORCA_RC"
        """
        |> String.replace("__JOBS__", jobs)

      assert command == expected
    end

    test "verify_command is pinned to the deployed sha", %{dir: dir} do
      script = stub_script!(dir, "exit 0")
      verify = stub_script!(dir, "exit 0")

      target =
        put_target!(%{command: script, directory: File.cwd!(), verify_command: verify})

      assert {:ok, result} = Deploys.start_deploy(target, [])
      {sha, 0} = System.cmd("git", ["-C", File.cwd!(), "rev-parse", "--short", "HEAD"])
      sha = String.trim(sha)

      assert result.sha == sha
      assert result.job.verify_command == "#{verify} '#{sha}'"

      wait_for_terminal(result.job.id)
    end
  end

  # ── refusals ───────────────────────────────────────────────────────

  describe "refusals (no lease may be taken)" do
    test "an unknown target is refused" do
      assert {:error, :unknown_target, details} = Deploys.start_deploy("nope-not-a-target", [])
      assert "orca_hub" in details.known_targets
    end

    test "a disallowed flag is refused", %{dir: dir} do
      script = stub_script!(dir, "exit 0")
      target = put_target!(%{command: script, directory: dir, allowed_flags: ["--dry-run"]})

      assert {:error, :disallowed_flag, details} =
               Deploys.start_deploy(target, flags: ["--rm-rf"])

      assert details.flag == "--rm-rf"
      assert leases_for(target) == []
    end

    test "an unavailable node is REFUSED and takes no lease", %{dir: dir} do
      script = stub_script!(dir, "exit 0")

      target =
        put_target!(%{command: script, directory: dir, node: "ghost@nowhere.invalid"})

      assert {:error, :node_unavailable, details} = Deploys.start_deploy(target, [])
      assert details.node == "ghost@nowhere.invalid"
      assert details.hint =~ "never re-routes"

      # The whole point: refusing must not cost the target its mutex for 90
      # minutes, and it must never silently fall back to this node.
      assert leases_for(target) == []
      assert Leases.get_live(target) == nil
    end

    test "a missing script is refused before the lease is taken", %{dir: dir} do
      target = put_target!(%{command: Path.join(dir, "does-not-exist.sh"), directory: dir})

      assert {:error, :script_missing, details} = Deploys.start_deploy(target, [])
      assert details.command =~ "does-not-exist.sh"
      assert leases_for(target) == []
    end

    test "a non-executable script is refused before the lease is taken", %{dir: dir} do
      path = Path.join(dir, "not-executable.sh")
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o644)
      target = put_target!(%{command: path, directory: dir})

      assert {:error, :script_not_executable, _} = Deploys.start_deploy(target, [])
      assert leases_for(target) == []
    end

    test "a live lease over a live job refuses with who holds it", %{dir: dir} do
      script = stub_script!(dir, "exit 0")
      target = put_target!(%{command: script, directory: dir})
      job = running_job!(dir)
      {:ok, held} = Leases.acquire(target, %{job_id: job.id, note: "first deploy"})

      assert {:error, :held, details} = Deploys.start_deploy(target, [])
      assert details.held_by.job_id == job.id
      assert details.held_by.job_status == "running"
      assert details.held_by.lease_id == held.id

      # ...and the refusal did not disturb the incumbent.
      assert [still_held] = unreleased(target)
      assert still_held.id == held.id
    end

    test "an EXPIRED lease whose job is still running is refused, not stolen", %{dir: dir} do
      script = stub_script!(dir, "exit 0")
      target = put_target!(%{command: script, directory: dir})
      job = running_job!(dir)
      past = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60, :second)
      lease = insert_lease!(target, %{job_id: job.id, expires_at: past})

      assert {:error, :lease_expired_job_running, details} = Deploys.start_deploy(target, [])
      assert details.held_by.job_id == job.id
      assert details.hint =~ "refuses to steal"

      # The one case a pure-TTL design gets wrong: the lease stays HELD.
      assert [still_held] = unreleased(target)
      assert still_held.id == lease.id
      assert is_nil(still_held.released_at)
    end

    test "a stale lease (job already terminal) is released and the deploy proceeds", %{dir: dir} do
      script = stub_script!(dir, "exit 0")
      target = put_target!(%{command: script, directory: dir})
      job = running_job!(dir)
      {:ok, stale} = Leases.acquire(target, %{job_id: job.id})
      {:ok, _} = Jobs.update_job(job, %{status: "succeeded"})

      assert {:ok, result} = Deploys.start_deploy(target, [])
      assert result.lease.id != stale.id
      assert Leases.get_lease(stale.id).released_at != nil

      wait_for_terminal(result.job.id)
    end
  end

  # ── classify/3 (§2.2's disagreement table) ─────────────────────────

  describe "classify/3" do
    test "reports the conjunction of lease liveness and job liveness" do
      now = DateTime.utc_now()
      live = %Lease{expires_at: DateTime.add(now, 60, :second)}
      expired = %Lease{expires_at: DateTime.add(now, -60, :second)}
      released = %Lease{expires_at: DateTime.add(now, 60, :second), released_at: now}

      assert Deploys.classify(nil, nil, now) == :free
      assert Deploys.classify(live, %{status: "running"}, now) == :in_flight
      assert Deploys.classify(live, %{status: "verifying"}, now) == :in_flight
      assert Deploys.classify(live, %{status: "succeeded"}, now) == :stale_lease
      assert Deploys.classify(expired, %{status: "running"}, now) == :lease_expired_job_running
      assert Deploys.classify(expired, %{status: "failed"}, now) == :expired
      # A released lease holds nothing — it must not read as "expired".
      assert Deploys.classify(released, %{status: "running"}, now) == :free
    end
  end

  # ── real processes across the ssh boundary ─────────────────────────

  describe "escape_cgroup real-process behaviour" do
    test "the pid rebind lands in the job row, pointing at the REMOTE process", %{dir: dir} do
      script = stub_script!(dir, "echo DEPLOY_START; sleep 8; exit 0")
      target = put_target!(%{command: script, directory: dir, escape_cgroup: true})

      assert {:ok, result} = Deploys.start_deploy(target, [])
      job = result.job

      remote = read_pid!(Deploys.remote_pid_path(job.id))
      local = read_pid!(Paths.pid_path(job.id))

      assert job.pid == remote
      assert job.pgid == remote
      assert HubRPC.get_job(job.id).pid == remote
      refute remote == local

      # The rebind is only meaningful because the remote really is outside
      # this unit's cgroup — that is the whole escape.
      assert File.read!("/proc/#{remote}/cgroup") =~ "user.slice"
      assert File.read!("/proc/#{local}/cgroup") =~ "system.slice"

      IO.puts("\n[rebind] local wrapper pid=#{local} remote pid=#{remote} job.pid=#{job.pid}")

      System.cmd("kill", ["-KILL", "-#{remote}"], stderr_to_stdout: true)
      wait_for_terminal(job.id)
    end

    test "SIGTERM to the local wrapper's group leaves the remote alive, the job non-terminal, and the remote's own exit code 7 still lands in exit_code",
         %{dir: dir} do
      script = stub_script!(dir, "echo DEPLOY_START; sleep 12; echo DEPLOY_DONE; exit 7")
      target = put_target!(%{command: script, directory: dir, escape_cgroup: true})

      assert {:ok, result} = Deploys.start_deploy(target, [])
      job = result.job
      remote = read_pid!(Deploys.remote_pid_path(job.id))
      local = read_pid!(Paths.pid_path(job.id))

      assert alive?(local)
      assert alive?(remote)

      # This is the `systemctl restart orca-hub` simulation: KillMode=
      # control-group SIGTERMs everything in the unit's cgroup, which is
      # the local wrapper and its ssh client — NEVER the real service.
      System.cmd("kill", ["-TERM", "-#{local}"], stderr_to_stdout: true)
      wait_until(fn -> not alive?(local) end)

      refute alive?(local)
      assert alive?(remote), "the remote half must survive the local group kill"
      refute File.exists?(Paths.sentinel_path(job.id))

      # A few watcher ticks (100ms in test config) with the local wrapper
      # gone: without the rebind this is exactly where finalize_crashed
      # would fire.
      Process.sleep(600)
      mid = HubRPC.get_job(job.id)
      assert mid.status == "running"
      refute (mid.progress_note || "") =~ "disappeared without writing"

      IO.puts(
        "\n[restart-sim] local=#{local} alive=no | remote=#{remote} alive=yes | " <>
          "sentinel=NO | job.status=#{mid.status}"
      )

      finished = wait_for_terminal(job.id)

      IO.puts(
        "[restart-sim] after remote completes: sentinel=#{File.read!(Paths.sentinel_path(job.id))} " <>
          "job.status=#{finished.status} exit_code=#{finished.exit_code} " <>
          "log=#{finished.id |> Paths.log_path() |> File.read!() |> String.replace("\n", "|")}"
      )

      assert finished.exit_code == 7
      assert finished.status == "failed"
      assert File.read!(Paths.log_path(job.id)) =~ "DEPLOY_DONE"
    end

    test "the missing-sentinel path yields the reserved exit code 70", %{dir: dir} do
      # The remote dies without ever writing a sentinel (`kill -KILL 0`
      # signals its own setsid process group), so the local poller's
      # `[ -d /proc/$REMOTE ]` guard releases it and it reports 70.
      #
      # The watcher's poll interval is widened from the test default of
      # 100ms to 5s — prod's real value — precisely because this path is a
      # race (see OrcaHub.Deploys' moduledoc): with a 100ms tick the
      # watcher always sees the rebound remote pid gone before the local
      # half's 1s poll can write 70, and finalize_crashed wins instead.
      prev_poll = Application.get_env(:orca_hub, :job_poll_interval_ms)
      Application.put_env(:orca_hub, :job_poll_interval_ms, 5_000)
      on_exit(fn -> Application.put_env(:orca_hub, :job_poll_interval_ms, prev_poll) end)

      script = stub_script!(dir, "echo DEPLOY_START; sleep 1; kill -KILL 0")
      target = put_target!(%{command: script, directory: dir, escape_cgroup: true})

      assert {:ok, result} = Deploys.start_deploy(target, [])
      job = result.job
      remote = read_pid!(Deploys.remote_pid_path(job.id))

      wait_until(fn -> not alive?(remote) end)
      finished = wait_for_terminal(job.id)

      IO.puts(
        "\n[no-sentinel] remote=#{remote} died without a sentinel -> " <>
          "sentinel now='#{File.read!(Paths.sentinel_path(job.id))}' " <>
          "job.status=#{finished.status} exit_code=#{finished.exit_code}"
      )

      assert finished.exit_code == Deploys.indeterminate_exit_code()
      assert finished.exit_code == 70
      assert finished.status == "failed"
    end

    test "a remote pid that never appears cancels the job AND releases the lease", %{dir: dir} do
      script = stub_script!(dir, "exit 0")

      target =
        put_target!(%{
          command: script,
          directory: dir,
          escape_cgroup: true,
          # Unroutable ssh host: the remote half never starts, so
          # <id>.remote.pid is never written.
          ssh_host: "orca-deploy-test.invalid"
        })

      assert {:error, :remote_pid_missing, details} = Deploys.start_deploy(target, [])
      assert details.hint =~ "wrongly marked failed"

      # An un-rebound escape_cgroup job would be wrongly finalize_crashed at
      # step 7, and a lease left behind would wedge the target for its full
      # TTL. Neither is allowed to happen.
      assert unreleased(target) == []
      assert Leases.get_live(target) == nil

      job = wait_for_terminal(details.job_id)

      IO.puts(
        "\n[no-remote-pid] job=#{job.id} status=#{job.status} " <>
          "lease_released=#{unreleased(target) == []}"
      )

      assert job.status in ["cancelled", "failed"]
    end
  end
end
