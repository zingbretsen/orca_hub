defmodule OrcaHub.MCP.Tools.DeploysTest do
  @moduledoc """
  Coverage for the Deploys MCP tool surface
  (`.context/deploy-jobs-design.md` §2.5/§2.6).

  **Nothing in this file may ever name a real deploy target or execute a
  real deploy script.** Every target is a fixture injected through the
  `:deploy_targets` config override, and every `command` is a throwaway
  `sh` stub written into a temp `ORCA_JOBS_DIR` under `$HOME`. The one
  test that actually launches a process launches `echo`-and-`exit 0`, the
  same way `OrcaHub.DeploysTest` does.

  `async: false` — the fixtures flip process-wide app env (`:deploy_targets`)
  and `ORCA_JOBS_DIR`, and one test launches a real detached job.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.Deploys.{Lease, Leases}
  alias OrcaHub.Jobs.Paths
  alias OrcaHub.MCP.Tools
  alias OrcaHub.MCP.Tools.Deploys, as: DeploysTool
  alias OrcaHub.{HubRPC, Jobs, Sessions, ToolPolicy}

  @moduletag timeout: 120_000

  setup do
    root = Path.join(System.user_home!(), ".orca_hub_deploy_tools_test")
    dir = Path.join(root, "t#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_jobs_dir = System.get_env("ORCA_JOBS_DIR")
    prev_targets = Application.get_env(:orca_hub, :deploy_targets)

    System.put_env("ORCA_JOBS_DIR", dir)

    {:ok, session} = Sessions.create_session(%{directory: dir})

    on_exit(fn ->
      reap_processes(dir)

      if prev_jobs_dir,
        do: System.put_env("ORCA_JOBS_DIR", prev_jobs_dir),
        else: System.delete_env("ORCA_JOBS_DIR")

      if prev_targets,
        do: Application.put_env(:orca_hub, :deploy_targets, prev_targets),
        else: Application.delete_env(:orca_hub, :deploy_targets)

      File.rm_rf(dir)
      File.rmdir(root)
    end)

    %{dir: dir, session: session, state: %{orchestrator: true, orca_session_id: session.id}}
  end

  # ── fixtures ───────────────────────────────────────────────────────

  defp reap_processes(dir) do
    for path <- Path.wildcard(Path.join(dir, "*.pid")),
        {pid, _} <- [path |> File.read!() |> String.trim() |> Integer.parse()] do
      System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  defp stub_script!(dir, body) do
    path = Path.join(dir, "deploy-stub-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp put_target!(dir, overrides \\ %{}) do
    key = "tool-target-#{System.unique_integer([:positive])}"

    config =
      Map.merge(
        %{
          name: "Fixture Target",
          command: stub_script!(dir, "exit 0"),
          directory: dir,
          allowed_flags: ["--skip-build", "--dry-run"],
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

  defp job!(attrs) do
    {:ok, job} =
      Jobs.create_job(
        Map.merge(
          %{
            directory: System.tmp_dir!(),
            runner_node: Atom.to_string(node()),
            command: "true",
            status: "running"
          },
          attrs
        )
      )

    job
  end

  defp lease!(target, attrs) do
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

  defp write_log!(job_id, body), do: File.write!(Paths.log_path(job_id), body)

  # A log in the exact shape all three real deploy scripts emit: the shared
  # banner(), a step_skipped() line, a warn-only gb10 failure, and the
  # verify script's own "  FAIL:" line. Not invented — this is the format
  # §1.1/§2.6 surveyed.
  defp deploy_log do
    """

    ==============================================================
    >>> Step 1/7 — Pushing current branch to origin
    ==============================================================
    Everything up-to-date

    ==============================================================
    >>> Step 5/7 — Installing release on mini + restarting its systemd service
    ==============================================================
    --- SKIPPED: mini install (--skip-mini) ---

    ==============================================================
    >>> Step 6/7 — Installing arm64 release on gb10 + restarting its systemd service
    ==============================================================
    WARNING: gb10 did not report sha=01a1b00 after restart — check it manually.

    ==============================================================
    >>> Step 7/7 — Installing release locally + restarting systemd service: orca-hub
    ==============================================================
      FAIL: gb10 (zach@192.168.1.77) still reports sha='4dc631d' after 120s (want 01a1b00)
    """
  end

  defp call(name, args, state \\ %{orchestrator: true}), do: DeploysTool.call(name, args, state)

  defp decode(%{"content" => [%{"text" => body}]}), do: Jason.decode!(body)

  defp ok_body(result) do
    assert %{"isError" => false} = result
    body = decode(result)
    assert body["ok"] == true, "expected ok: true, got #{inspect(body)}"
    body
  end

  defp refusal_body(result, reason) do
    # A refusal is a RESULT, not an MCP error envelope — an isError result
    # raises Tools.Error inside a code-exec snippet, which would flatten the
    # structured payload the model is supposed to act on.
    assert %{"isError" => false} = result
    body = decode(result)
    assert body["ok"] == false
    assert body["reason"] == reason
    assert is_binary(body["hint"]) and body["hint"] != ""
    body
  end

  defp await_status(job_id, statuses, tries \\ 200) do
    job = HubRPC.get_job(job_id)

    cond do
      job.status in statuses -> job
      tries <= 0 -> flunk("job #{job_id} stuck at #{job.status}")
      true -> Process.sleep(50) && await_status(job_id, statuses, tries - 1)
    end
  end

  # ── schemas ────────────────────────────────────────────────────────

  describe "list/0" do
    test "exposes exactly the three tools of §2.5" do
      assert Enum.map(DeploysTool.list(), & &1["name"]) ==
               ~w(start_deploy in_flight_deploys deploy_status)
    end

    test "every tool's inputSchema is a well-formed object schema" do
      for tool <- DeploysTool.list() do
        assert is_binary(tool["description"]) and tool["description"] != ""
        schema = tool["inputSchema"]
        assert schema["type"] == "object"
        assert is_map(schema["properties"])

        for {name, prop} <- schema["properties"] do
          assert prop["type"] in ~w(string integer boolean array),
                 "#{tool["name"]}.#{name} has type #{inspect(prop["type"])}"

          assert is_binary(prop["description"]) and prop["description"] != ""
        end
      end
    end

    test "`required` names only real properties" do
      for tool <- DeploysTool.list(), name <- Map.get(tool["inputSchema"], "required", []) do
        assert Map.has_key?(tool["inputSchema"]["properties"], name)
      end
    end

    test "required is honoured per tool" do
      by_name = Map.new(DeploysTool.list(), &{&1["name"], &1})

      assert by_name["start_deploy"]["inputSchema"]["required"] == ["target"]
      assert by_name["deploy_status"]["inputSchema"]["required"] == ["job_id"]
      # A filter-only tool: no required arguments at all.
      refute Map.has_key?(by_name["in_flight_deploys"]["inputSchema"], "required")
    end

    test "start_deploy's array argument declares its item type" do
      start = Enum.find(DeploysTool.list(), &(&1["name"] == "start_deploy"))
      flags = start["inputSchema"]["properties"]["flags"]

      assert flags["type"] == "array"
      assert flags["items"] == %{"type" => "string"}
    end
  end

  # ── orchestrator-only gating (the load-bearing test) ───────────────

  describe "visibility" do
    test "start_deploy is absent from a regular (non-orchestrator) connection" do
      names = Tools.list(%{orchestrator: false}) |> Enum.map(& &1["name"])

      refute "start_deploy" in names
      # The read-only pair is scoped the same way, deliberately.
      refute "in_flight_deploys" in names
      refute "deploy_status" in names
    end

    test "an absent role defaults to regular, so start_deploy stays hidden" do
      names = Tools.list(%{orca_session_id: "abc"}) |> Enum.map(& &1["name"])
      refute "start_deploy" in names
    end

    test "an orchestrator connection sees all three" do
      names = Tools.list(%{orchestrator: true}) |> Enum.map(& &1["name"])

      assert "start_deploy" in names
      assert "in_flight_deploys" in names
      assert "deploy_status" in names
    end

    test "a regular connection cannot allowlist start_deploy back into view" do
      names =
        Tools.list(%{orchestrator: false, tool_policy: ToolPolicy.new(["start_deploy"], nil)})
        |> Enum.map(& &1["name"])

      refute "start_deploy" in names
    end

    test "a ToolPolicy denylist hides start_deploy from an orchestrator too" do
      names =
        Tools.list(%{orchestrator: true, tool_policy: ToolPolicy.new(nil, ["start_deploy"])})
        |> Enum.map(& &1["name"])

      refute "start_deploy" in names
      assert "deploy_status" in names
    end

    test "a ToolPolicy denial REFUSES the call, and nothing is leased", %{dir: dir, state: state} do
      target = put_target!(dir)
      state = Map.put(state, :tool_policy, ToolPolicy.new(nil, ["start_deploy"]))

      result = Tools.call("start_deploy", %{"target" => target}, state)

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "start_deploy"
      assert Leases.list_for_target(target) == []
    end

    test "Tools.call routes the deploy tool names to this module" do
      result = Tools.call("in_flight_deploys", %{}, %{orchestrator: true})
      assert %{"isError" => false} = result
      assert is_list(decode(result)["known_targets"])
    end
  end

  # ── start_deploy: success ──────────────────────────────────────────

  describe "start_deploy" do
    test "launches a real (stub) deploy and returns §2.5's success shape", %{
      dir: dir,
      state: state,
      session: session
    } do
      script = stub_script!(dir, ~s|echo ">>> Step 1/1 — stub"; exit 0|)
      target = put_target!(dir, %{command: script, allowed_flags: ["--skip-build"]})

      body =
        call(
          "start_deploy",
          %{"target" => target, "flags" => ["--skip-build"], "note" => "because I said so"},
          state
        )
        |> ok_body()

      assert body["target"] == target
      assert is_binary(body["job_id"])
      assert is_binary(body["lease_id"])
      assert body["status"] == "running"
      assert body["runner_node"] == Atom.to_string(node())
      assert body["command"] == "#{script} --skip-build"
      assert body["escape_cgroup"] == false
      assert is_binary(body["acquired_at"]) and is_binary(body["expires_at"])
      assert is_binary(body["log_path"])
      assert body["hint"] =~ "deploy_status"
      assert body["note"] =~ "Launched detached"

      job = HubRPC.get_job(body["job_id"])
      assert job.session_id == session.id
      assert job.label == "deploy #{target}"

      lease = Leases.get_live(target)
      assert lease.id == body["lease_id"]
      assert lease.session_id == session.id
      assert lease.note == "because I said so"

      assert await_status(job.id, ~w(succeeded failed)).status == "succeeded"
    end

    test "the launch note warns that a verified target is not done when the script is", %{
      dir: dir,
      state: state
    } do
      target = put_target!(dir, %{verify_command: "/bin/true", verify_sha: false})

      body = call("start_deploy", %{"target" => target}, state) |> ok_body()

      assert body["verify_command"] == "/bin/true"
      assert body["note"] =~ "succeeded vs verification_failed"

      assert await_status(body["job_id"], ~w(succeeded failed verification_failed)).status ==
               "succeeded"
    end

    test "an escape_cgroup target pinned to a dead node is refused, never launched over ssh", %{
      dir: dir,
      state: state
    } do
      target = put_target!(dir, %{escape_cgroup: true, node: "ghost@nowhere.invalid"})

      body =
        call("start_deploy", %{"target" => target}, state) |> refusal_body("node_unavailable")

      assert body["hint"] =~ "never re-routes"
      assert Leases.list_for_target(target) == []
    end
  end

  # ── start_deploy: every refusal reason, each with a hint ───────────

  describe "start_deploy refusals" do
    test "unknown_target echoes the known keys", %{state: state} do
      body =
        call("start_deploy", %{"target" => "not-a-target"}, state)
        |> refusal_body("unknown_target")

      assert body["target"] == "not-a-target"
      assert is_list(body["known_targets"])
      assert body["hint"] =~ "known_targets"
    end

    test "a missing target argument is refused, not crashed", %{state: state} do
      body = call("start_deploy", %{}, state) |> refusal_body("unknown_target")
      assert is_list(body["known_targets"])
    end

    test "disallowed_flag echoes the allow-list back", %{dir: dir, state: state} do
      target = put_target!(dir, %{allowed_flags: ["--skip-build"]})

      body =
        call("start_deploy", %{"target" => target, "flags" => ["--rm-rf-prod"]}, state)
        |> refusal_body("disallowed_flag")

      assert body["flag"] == "--rm-rf-prod"
      assert body["allowed_flags"] == ["--skip-build"]
      assert body["reason"] == "disallowed_flag"
      assert body["hint"] =~ "allow-list"
      assert Leases.list_for_target(target) == []
    end

    test "invalid_positional explains the expected shape", %{dir: dir, state: state} do
      target = put_target!(dir, %{positional: :version})

      body =
        call("start_deploy", %{"target" => target, "version" => "not-a-version"}, state)
        |> refusal_body("invalid_positional")

      assert body["value"] == "not-a-version"
      # The validator's own explanation survives the refusal's own `reason`
      # field rather than being overwritten by it.
      assert body["detail"] == "expected a version like 1.2.3"
      assert Leases.list_for_target(target) == []
    end

    test "node_unavailable refuses instead of re-routing, and takes no lease", %{
      dir: dir,
      state: state
    } do
      target = put_target!(dir, %{node: "ghost@nowhere.invalid"})

      body =
        call("start_deploy", %{"target" => target}, state) |> refusal_body("node_unavailable")

      assert body["node"] == "ghost@nowhere.invalid"
      assert body["hint"] =~ "never re-routes"
      assert Leases.list_for_target(target) == []
    end

    test "script_missing is refused before the lease is taken", %{dir: dir, state: state} do
      target = put_target!(dir, %{command: Path.join(dir, "gone.sh")})

      body = call("start_deploy", %{"target" => target}, state) |> refusal_body("script_missing")

      assert body["command"] =~ "gone.sh"
      # OrcaHub.Deploys' own, more specific hint survives — the module's
      # default hint only fills in when the refusal carried none.
      assert body["hint"] =~ "No lease was taken"
      assert Leases.list_for_target(target) == []
    end

    test "held names the holder so the model can poll it instead", %{dir: dir, state: state} do
      target = put_target!(dir)
      holder = job!(%{status: "running", label: "deploy #{target}"})

      lease =
        lease!(target, %{job_id: holder.id, session_id: state.orca_session_id, note: "first"})

      body = call("start_deploy", %{"target" => target}, state) |> refusal_body("held")

      assert body["target"] == target
      held = body["held_by"]
      assert held["job_id"] == holder.id
      assert held["lease_id"] == lease.id
      assert held["session_id"] == state.orca_session_id
      assert held["job_status"] == "running"
      assert held["note"] == "first"
      assert is_binary(held["acquired_at"]) and is_binary(held["expires_at"])
      assert body["hint"] =~ "already in flight"

      # The loser must not have taken a second lease or launched anything.
      assert [^lease] = Leases.list_for_target(target)
    end

    test "lease_expired_job_running refuses to steal from a live deploy", %{
      dir: dir,
      state: state
    } do
      target = put_target!(dir)
      holder = job!(%{status: "running"})
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      lease =
        lease!(target, %{
          job_id: holder.id,
          acquired_at: DateTime.add(past, -300, :second),
          expires_at: past
        })

      body =
        call("start_deploy", %{"target" => target}, state)
        |> refusal_body("lease_expired_job_running")

      assert body["held_by"]["job_id"] == holder.id
      assert body["hint"] =~ "refuses to steal"
      assert [^lease] = Leases.list_for_target(target)
    end
  end

  # ── in_flight_deploys ──────────────────────────────────────────────

  describe "in_flight_deploys" do
    test "reports nothing for a target with no lease, and always lists the known keys", %{
      dir: dir
    } do
      target = put_target!(dir)

      body = call("in_flight_deploys", %{"target" => target}) |> ok_body()

      assert body["count"] == 0
      assert body["deploys"] == []
      assert target in body["known_targets"]
      assert body["hint"] =~ "Nothing is holding"
    end

    test "in_flight: live lease + live job, with the step it has reached", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{status: "running"})
      write_log!(job.id, deploy_log())
      lease!(target, %{job_id: job.id, note: "deploy 01a1b00"})

      body = call("in_flight_deploys", %{"target" => target}) |> ok_body()

      assert body["count"] == 1
      assert [entry] = body["deploys"]
      assert entry["target"] == target
      assert entry["state"] == "in_flight"
      assert entry["job_id"] == job.id
      assert entry["job_status"] == "running"
      assert entry["note"] == "deploy 01a1b00"
      assert entry["seconds_remaining"] > 0
      assert entry["runner_node"] == Atom.to_string(node())

      assert entry["current_step"] ==
               "Step 7/7 — Installing release locally + restarting systemd service: orca-hub"

      assert entry["hint"] =~ "do not start a second one"
      assert body["hint"] =~ "LIVE deploy job"
    end

    test "stale_lease: the lease is held but its job already finished", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{status: "succeeded"})
      lease!(target, %{job_id: job.id})

      assert [entry] =
               call("in_flight_deploys", %{"target" => target})
               |> ok_body()
               |> Map.fetch!("deploys")

      assert entry["state"] == "stale_lease"
      assert entry["job_status"] == "succeeded"
      assert entry["current_step"] == nil
      assert entry["hint"] =~ "nothing is deploying"
    end

    test "lease_expired_job_running is named as the disagreement it is", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{status: "running"})
      past = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)

      lease!(target, %{
        job_id: job.id,
        acquired_at: DateTime.add(past, -300, :second),
        expires_at: past
      })

      body = call("in_flight_deploys", %{"target" => target}) |> ok_body()

      assert [entry] = body["deploys"]
      assert entry["state"] == "lease_expired_job_running"
      assert entry["seconds_remaining"] == 0
      assert entry["hint"] =~ "STILL RUNNING"
      assert body["hint"] =~ "LIVE deploy job"
    end

    test "expired: an unreleased lease over a finished job is not in flight", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{status: "failed"})
      past = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)

      lease!(target, %{
        job_id: job.id,
        acquired_at: DateTime.add(past, -300, :second),
        expires_at: past
      })

      body = call("in_flight_deploys", %{"target" => target}) |> ok_body()

      assert [entry] = body["deploys"]
      assert entry["state"] == "expired"
      assert entry["hint"] =~ "blocks nothing"
      assert body["hint"] =~ "No live deploy job"
    end

    test "a released lease holds nothing and is not reported", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{status: "succeeded"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      lease!(target, %{job_id: job.id, released_at: now})

      assert call("in_flight_deploys", %{"target" => target}) |> ok_body() |> Map.fetch!("count") ==
               0
    end

    test "the unfiltered listing includes our fixture target's lease", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{status: "running"})
      lease!(target, %{job_id: job.id})

      body = call("in_flight_deploys", %{}) |> ok_body()

      assert Enum.any?(body["deploys"], &(&1["target"] == target))
      assert body["count"] == length(body["deploys"])
    end

    test "an unknown target filter is refused with the known keys" do
      body = call("in_flight_deploys", %{"target" => "nope"}) |> refusal_body("unknown_target")
      assert is_list(body["known_targets"])
    end
  end

  # ── deploy_status ──────────────────────────────────────────────────

  describe "deploy_status" do
    test "an unknown job id is refused, not crashed" do
      body =
        call("deploy_status", %{"job_id" => Ecto.UUID.generate()}) |> refusal_body("unknown_job")

      assert body["hint"] =~ "in_flight_deploys"
    end

    test "a missing job_id is refused" do
      call("deploy_status", %{}) |> refusal_body("missing_job_id")
    end

    test "a job that is not a deploy is refused rather than reported on" do
      job = job!(%{status: "succeeded", label: "build the thing"})

      body = call("deploy_status", %{"job_id" => job.id}) |> refusal_body("not_a_deploy")

      assert body["job_id"] == job.id
      assert body["hint"] =~ "check_job"
    end

    test "verification_failed: §2.5's full shape, warnings SEPARATE from errors", %{dir: dir} do
      target = put_target!(dir, %{verify_command: "/bin/true"})
      started = DateTime.utc_now() |> DateTime.add(-1284, :second) |> DateTime.truncate(:second)
      finished = DateTime.utc_now() |> DateTime.truncate(:second)

      job =
        job!(%{
          label: "deploy #{target}",
          status: "verification_failed",
          exit_code: 0,
          verify_exit_code: 1,
          verify_command: "/home/zach/homelab/scripts/verify-orca-deploy.sh 01a1b00",
          started_at: started,
          finished_at: finished
        })

      write_log!(job.id, deploy_log())
      lease!(target, %{job_id: job.id, released_at: finished})

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["target"] == target
      assert body["job_id"] == job.id
      assert body["status"] == "verification_failed"
      assert body["exit_code"] == 0
      assert body["verify_exit_code"] == 1
      assert body["runner_node"] == Atom.to_string(node())
      assert body["duration_seconds"] == 1284

      assert body["steps_seen"] == [
               "Step 1/7 — Pushing current branch to origin",
               "Step 5/7 — Installing release on mini + restarting its systemd service",
               "Step 6/7 — Installing arm64 release on gb10 + restarting its systemd service",
               "Step 7/7 — Installing release locally + restarting systemd service: orca-hub"
             ]

      assert body["last_step"] == List.last(body["steps_seen"])
      assert body["skipped_steps"] == ["mini install (--skip-mini)"]

      # The whole point of §2.6: a non-fatal gb10 warning must not be filed
      # under errors, and must not be invisible either.
      assert body["errors"] == [
               "  FAIL: gb10 (zach@192.168.1.77) still reports sha='4dc631d' after 120s (want 01a1b00)"
             ]

      assert body["warnings"] == [
               "WARNING: gb10 did not report sha=01a1b00 after restart — check it manually."
             ]

      assert body["log_tail"] =~ "Step 7/7"
      assert body["log_unavailable"] == false
      assert body["log_truncated_for_parsing"] == false
      assert body["lease"]["state"] == "released"
      assert is_binary(body["lease"]["released_at"])
      assert body["lease"]["seconds_remaining"] == nil
      assert body["hint"] =~ "verification FAILED"
    end

    test "exit 0 with a warn-only stage failure does NOT read as 'everything worked'", %{
      dir: dir
    } do
      target = put_target!(dir)

      job =
        job!(%{label: "deploy #{target}", status: "succeeded", exit_code: 0, verify_exit_code: 0})

      write_log!(job.id, deploy_log())

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["status"] == "succeeded"
      assert body["exit_code"] == 0
      assert body["warnings"] != []
      assert body["hint"] =~ "warning"
      assert body["hint"] =~ "non-fatal"
      assert body["field_notes"]["warnings"] =~ "exit 0"
    end

    test "a clean success says so without inventing a warning", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{label: "deploy #{target}", status: "succeeded", exit_code: 0})
      write_log!(job.id, ">>> Step 1/1 — all good\n")

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["warnings"] == []
      assert body["errors"] == []
      assert body["hint"] =~ "succeeded"
      refute body["hint"] =~ "warning"
    end

    test "last_step is labelled as the step REACHED, never as the failing step", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{label: "deploy #{target}", status: "failed", exit_code: 1})
      write_log!(job.id, deploy_log())

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["field_notes"]["last_step"] =~ "REACHED"
      assert body["field_notes"]["last_step"] =~ "not necessarily the step that failed"
      assert body["hint"] =~ "where it got to, not necessarily what broke"
    end

    test "an escape_cgroup target explains what exit_code means (§2.3's contract)", %{dir: dir} do
      target = put_target!(dir, %{escape_cgroup: true, verify_command: "/bin/true"})

      job =
        job!(%{
          label: "deploy #{target}",
          status: "succeeded",
          exit_code: 0,
          verify_command: "/bin/true"
        })

      notes =
        call("deploy_status", %{"job_id" => job.id}) |> ok_body() |> Map.fetch!("field_notes")

      assert notes["exit_code"] =~ "DEPLOY SCRIPT's own exit code"
      assert notes["exit_code"] =~ "70"
      assert notes["verify_exit_code"] =~ "run only if the deploy exited 0"
    end

    test "the reserved 70 is reported as indeterminate, not as a script status", %{dir: dir} do
      target = put_target!(dir, %{escape_cgroup: true})
      job = job!(%{label: "deploy #{target}", status: "failed", exit_code: 70})

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["exit_code"] == 70
      assert body["field_notes"]["exit_code"] =~ "genuinely unknown"
    end

    test "a target with no verify command says nothing confirmed the deploy", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{label: "deploy #{target}", status: "succeeded", exit_code: 0})

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["verify_log_tail"] == nil
      assert body["field_notes"]["verify_exit_code"] =~ "no verify command"
      assert body["hint"] =~ "nothing verified it"
    end

    test "a running deploy reports its live state and points at wake_when_done", %{dir: dir} do
      target = put_target!(dir)

      job =
        job!(%{
          label: "deploy #{target}",
          status: "running",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      lease!(target, %{job_id: job.id})
      write_log!(job.id, deploy_log())

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["status"] == "running"
      assert body["lease"]["state"] == "in_flight"
      assert body["lease"]["seconds_remaining"] > 0
      assert is_integer(body["duration_seconds"])
      assert body["hint"] =~ "wake_when_done"
    end

    test "log_tail_bytes truncates the tail but never the parsing", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{label: "deploy #{target}", status: "succeeded", exit_code: 0})
      write_log!(job.id, deploy_log())

      body = call("deploy_status", %{"job_id" => job.id, "log_tail_bytes" => 80}) |> ok_body()

      assert byte_size(body["log_tail"]) <= 80
      # Parsing still saw the whole file.
      assert length(body["steps_seen"]) == 4
    end

    test "a missing log file is reported, not silently rendered as an empty deploy", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{label: "deploy #{target}", status: "failed", exit_code: 1})

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["log_unavailable"] == true
      assert body["steps_seen"] == []
      assert body["last_step"] == nil
    end

    test "the lease is found by job id even when the label is gone", %{dir: dir} do
      target = put_target!(dir)
      job = job!(%{label: nil, status: "succeeded", exit_code: 0})
      lease!(target, %{job_id: job.id})

      body = call("deploy_status", %{"job_id" => job.id}) |> ok_body()

      assert body["target"] == target
      # Held lease over a finished job — the lease view says so plainly
      # rather than reusing classify/3's `:free`, which answers a different
      # question ("may I deploy?").
      assert body["lease"]["state"] == "stale_lease"
    end
  end

  # ── end-to-end ─────────────────────────────────────────────────────

  describe "start_deploy -> in_flight_deploys -> deploy_status" do
    test "the three tools agree about one real (stub) deploy", %{dir: dir, state: state} do
      script =
        stub_script!(dir, """
        echo ">>> Step 1/2 — doing the thing"
        echo "WARNING: gb10 did not report sha=deadbee after restart — check it manually."
        echo ">>> Step 2/2 — finishing"
        exit 0
        """)

      target = put_target!(dir, %{command: script})

      started = call("start_deploy", %{"target" => target}, state) |> ok_body()
      job_id = started["job_id"]

      in_flight = call("in_flight_deploys", %{"target" => target}) |> ok_body()
      assert [%{"job_id" => ^job_id}] = in_flight["deploys"]

      assert await_status(job_id, ~w(succeeded failed)).status == "succeeded"

      body = call("deploy_status", %{"job_id" => job_id}) |> ok_body()

      assert body["target"] == target
      assert body["status"] == "succeeded"
      assert body["exit_code"] == 0
      assert body["steps_seen"] == ["Step 1/2 — doing the thing", "Step 2/2 — finishing"]
      assert body["last_step"] == "Step 2/2 — finishing"

      assert body["warnings"] == [
               "WARNING: gb10 did not report sha=deadbee after restart — check it manually."
             ]

      assert body["hint"] =~ "warning"
    end
  end
end
