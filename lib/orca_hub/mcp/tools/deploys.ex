defmodule OrcaHub.MCP.Tools.Deploys do
  @moduledoc """
  MCP tools for running a project deploy as a durable, mutually-exclusive
  job — the surface over `OrcaHub.Deploys` (see
  `.context/deploy-jobs-design.md` §2.5/§2.6).

  Three tools: `start_deploy` (fire it), `in_flight_deploys` (is one already
  running?), `deploy_status` (what actually happened?). There is deliberately
  no cancel tool — `cancel_job` already reaches the job's own node, and
  `OrcaHub.Deploys.LeaseReaper` releases the lease on the resulting
  `cancelled` broadcast.

  This module composes nothing and decides nothing. Target lookup, flag
  validation, node routing, leasing, the cgroup escape and the pid rebind
  all live in `OrcaHub.Deploys` and `OrcaHub.Deploys.Registry`; here we only
  translate tool arguments into that API and its results into JSON a model
  can act on.

  ## Orchestrator-only — all three, not just `start_deploy`

  None of these names appear in `OrcaHub.MCP.Tools`' `@regular_session_tools`,
  so a regular worker session never sees or lists them. `start_deploy` is the
  load-bearing case: it is a PRODUCTION-DEPLOY trigger reachable by an LLM,
  and a worker must not be able to fire one. The two read-only tools are
  scoped the same way on purpose — a session that cannot start a deploy has
  little use for deploy-shaped framing of it, and `check_job`/`wait_for_job`
  are already visible to every session for the job-level view if an
  orchestrator hands a worker the job id. Keeping the whole category
  orchestrator-only makes the rule "the Deploys tools are orchestrator-only",
  with no per-tool exception to remember.

  Per-session and per-trigger `OrcaHub.ToolPolicy` (the
  `sessions.tool_allowlist` / `tool_denylist` columns) then narrows on top of
  that for free, at BOTH `Tools.list/1` and `Tools.call/3`.

  ## Refusals are results, not MCP errors

  Every call here returns `"isError" => false` with a JSON body carrying an
  `"ok"` boolean. A refusal is `{"ok": false, "reason": ..., "hint": ...}`
  plus whatever context makes it actionable (who holds the lease, the
  allow-list that was violated, the node that is down).

  That is a deliberate choice against `Result.error/1`: in code-exec mode
  (`OrcaHub.MCP.CodeExec.Dispatcher.unwrap!/2`) an `isError` envelope RAISES
  `Tools.Error` inside the model's snippet, which unwinds the pipeline and
  flattens the payload into an exception message. A structured refusal the
  model can pattern-match on is the entire point of §2.5's shape — "a deploy
  is already in flight, here is who holds it, poll this job id" is
  information, not a failure to report.
  """

  import OrcaHub.MCP.Tools.Result

  require Logger

  alias OrcaHub.Cluster
  alias OrcaHub.Deploys
  alias OrcaHub.Deploys.{LogParser, Registry}
  alias OrcaHub.HubRPC
  alias OrcaHub.Jobs.Paths

  @default_log_tail_bytes 4_000
  @max_log_tail_bytes 200_000

  # The whole log is parsed (§2.6), but not unboundedly: a runaway log is
  # read from its END, and the result says so rather than quietly reporting
  # a truncated `steps_seen`. No real deploy log comes close to this.
  @max_parse_bytes 2_000_000

  # How far back through a target's lease history to look for a job's lease.
  # Only ever scanned for `deploy_status`, and only until the job id matches.
  @lease_scan_limit 50

  @label_prefix "deploy "

  def list do
    [
      %{
        "name" => "start_deploy",
        "description" =>
          "Run a project's REAL deploy script as a durable, detached OrcaHub job, under " <>
            "a lease that guarantees at most one deploy per target at a time. This ships " <>
            "code to PRODUCTION — it is not a dry run and it is not reversible by " <>
            "cancelling the job halfway. Only call it when the human asked for a deploy, " <>
            "or a task you were given explicitly includes deploying.\n\n" <>
            "Arguments are validated against the target's registry entry before anything " <>
            "launches: `flags` is an EXACT-MATCH allow-list (not a parser — an unknown " <>
            "flag is refused, and the refusal echoes the flags you could have passed), " <>
            "and `version` is the single optional positional, shape-checked per target. " <>
            "Every piece is shell-quoted; you cannot pass arbitrary argv.\n\n" <>
            "The job is pinned to the target's own node and is NEVER re-routed: if that " <>
            "node is down you get a node_unavailable refusal, not a deploy somewhere " <>
            "else. Nothing that can fail cheaply happens after the lease is taken, so a " <>
            "refusal never leaves a target wedged.\n\n" <>
            "NEVER returns an MCP error. Read `ok`: on true you get job_id/lease_id and " <>
            "the deploy is running; on false you get `reason` (held, unknown_target, " <>
            "disallowed_flag, invalid_positional, node_unavailable, script_missing, " <>
            "lease_expired_job_running, …) and a `hint` saying what to do instead. " <>
            "`held` names the job that holds the target — poll THAT job with " <>
            "deploy_status rather than retrying.\n\n" <>
            "Returns as soon as the deploy is launched; it does not wait. Poll with " <>
            "deploy_status (not check_job — deploy_status parses the log into steps, " <>
            "errors and warnings), or pass wake_when_done. Cancel with cancel_job.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "target" => %{
              "type" => "string",
              "description" =>
                "Registry key of the project to deploy, e.g. \"orca_hub\". " <>
                  "in_flight_deploys lists the known keys; an unknown key is refused " <>
                  "with the full list."
            },
            "flags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Exact flags from this target's allowed_flags, e.g. [\"--skip-arm64\"]. " <>
                  "Anything else is refused before launch."
            },
            "version" => %{
              "type" => "string",
              "description" =>
                "The target's single optional positional — a version like 1.2.3 or a git " <>
                  "ref, depending on the target. Omit unless the target takes one; a " <>
                  "target with positional :none refuses any value."
            },
            "wake_when_done" => %{
              "type" => "boolean",
              "description" =>
                "Wake this session when the deploy job reaches a terminal status " <>
                  "(succeeded/failed/verification_failed/timed_out/cancelled). Entering " <>
                  "the verifying phase does not wake you."
            },
            "note" => %{
              "type" => "string",
              "description" =>
                "Short free text recorded on the lease — shown to whoever is refused " <>
                  "while this deploy holds the target. Say why you are deploying."
            }
          },
          "required" => ["target"]
        }
      },
      %{
        "name" => "in_flight_deploys",
        "description" =>
          "Is a deploy already running for a project? Answers from the CONJUNCTION of " <>
            "the lease table and the job table, and names it when they disagree, so a " <>
            "stuck lease can never masquerade as a live deploy.\n\n" <>
            "Per-entry `state`: in_flight (live lease + live job — a real deploy is " <>
            "running, do not start another); stale_lease (live lease, job already " <>
            "finished — start_deploy will release it and proceed); " <>
            "lease_expired_job_running (lease expired but the job is demonstrably ALIVE " <>
            "— OrcaHub refuses to steal it; cancel the job or renew the lease); expired " <>
            "(expired lease over a finished/unknown job — harmless audit residue).\n\n" <>
            "Call this before start_deploy if you are unsure, and to discover the known " <>
            "target keys (`known_targets`, always returned).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "target" => %{
              "type" => "string",
              "description" => "Optional registry key to filter to. Omit for every target."
            }
          }
        }
      },
      %{
        "name" => "deploy_status",
        "description" =>
          "Structured status for a deploy job: the steps it reached, the steps it " <>
            "skipped, errors, WARNINGS, a log tail, the verify phase's own exit code, " <>
            "and the lease's state.\n\n" <>
            "Read `warnings` as carefully as `errors`. Several stages of a deploy are " <>
            "non-fatal by design (the mini and gb10 installs, the k3s version polls), so " <>
            "a deploy can exit 0 with a stage that completely failed. exit_code 0 does " <>
            "NOT mean everything worked — it means nothing aborted.\n\n" <>
            "`last_step` is the step the deploy REACHED, not necessarily the step that " <>
            "failed. `field_notes` in the result explains what exit_code and " <>
            "verify_exit_code mean for this specific target. Use this rather than " <>
            "check_job for a deploy job: check_job returns the raw job row with no log " <>
            "parsing.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "job_id" => %{
              "type" => "string",
              "description" => "The deploy job's id, as returned by start_deploy."
            },
            "log_tail_bytes" => %{
              "type" => "integer",
              "description" =>
                "Bytes of log tail to return, default #{@default_log_tail_bytes}, capped " <>
                  "at #{@max_log_tail_bytes}. Parsing always covers the whole log; only " <>
                  "this tail is truncated."
            }
          },
          "required" => ["job_id"]
        }
      }
    ]
  end

  def call("start_deploy", args, state), do: do_start_deploy(args, state)
  def call("in_flight_deploys", args, _state), do: do_in_flight(args["target"])

  def call("deploy_status", args, _state),
    do: do_deploy_status(args["job_id"], args["log_tail_bytes"])

  # ── start_deploy ───────────────────────────────────────────────────

  defp do_start_deploy(args, state) do
    target = args["target"]

    opts = [
      flags: Map.get(args, "flags") || [],
      positional: presence(args["version"]),
      session_id: state[:orca_session_id],
      note: presence(args["note"]),
      wake_when_done: args["wake_when_done"] == true
    ]

    case Deploys.start_deploy(target, opts) do
      {:ok, result} ->
        Logger.info("[Deploys] start_deploy #{result.target} launched job #{result.job.id}")
        json(started_view(result))

      {:error, reason, details} ->
        Logger.warning("[Deploys] start_deploy refused (#{reason}): #{inspect(details)}")
        json(refusal(reason, target, details))
    end
  end

  defp started_view(%{job: job, lease: lease, config: config} = result) do
    %{
      "ok" => true,
      "target" => result.target,
      "job_id" => job.id,
      "lease_id" => lease.id,
      "status" => job.status,
      "runner_node" => job.runner_node,
      "command" => Enum.join(result.argv, " "),
      "acquired_at" => lease.acquired_at,
      "expires_at" => lease.expires_at,
      "log_path" => job.log_path,
      "verify_command" => job.verify_command,
      "deployed_sha" => result.sha,
      "timeout_seconds" => job.timeout_seconds,
      "escape_cgroup" => config[:escape_cgroup] == true,
      "note" => launch_note(config, job),
      "hint" =>
        "Deploy launched. Poll deploy_status with this job_id; do not start a second " <>
          "deploy for #{result.target} while this one holds the lease. cancel_job stops it."
    }
  end

  # §2.5's example note says the exit code "is not authoritative" for an
  # escape_cgroup target. §2.3's resolution superseded that: the REMOTE
  # half writes the sentinel, so `exit_code` is the deploy script's own —
  # with 70 reserved for "the remote died without writing one". Saying
  # otherwise here would teach a model to ignore a trustworthy field.
  defp launch_note(config, job) do
    base =
      "Launched detached — it keeps running if this session ends, and (for a target that " <>
        "restarts this host) across that restart too."

    escape =
      if config[:escape_cgroup] == true do
        " This target restarts its own host partway through, so the job is launched " <>
          "outside the systemd cgroup; exit_code is still the deploy script's own, " <>
          "except #{Deploys.indeterminate_exit_code()}, which means the remote died " <>
          "without reporting one."
      else
        ""
      end

    verify =
      if job.verify_command do
        " A verify command runs after the deploy exits 0 and decides succeeded vs " <>
          "verification_failed, so the job is not done when the script is."
      else
        ""
      end

    base <> escape <> verify
  end

  # ── refusals (§2.5) ────────────────────────────────────────────────

  defp refusal(reason, target, details) do
    details
    |> stringify()
    # `OrcaHub.Deploys` details carry their own `:reason` for the two
    # validation refusals ("expected a version like 1.2.3"). Merging the
    # tool-level reason over it would throw that explanation away, which is
    # the single most actionable field in an invalid_positional refusal.
    |> rename("reason", "detail")
    |> Map.merge(%{
      "ok" => false,
      "reason" => to_string(reason),
      "target" => target_for_refusal(target, details)
    })
    |> Map.put_new("hint", default_hint(reason, target))
  end

  defp rename(map, from, to) do
    case Map.pop(map, from) do
      {nil, map} -> map
      {value, rest} -> Map.put_new(rest, to, value)
    end
  end

  defp target_for_refusal(target, _details) when is_binary(target), do: target
  defp target_for_refusal(_target, details), do: Map.get(details, :target)

  defp default_hint(:unknown_target, _target),
    do:
      "No such deploy target. Pick one of known_targets (in_flight_deploys also lists them) " <>
        "— a target is a registry key, not a directory or a repo name."

  defp default_hint(:disallowed_flag, _target),
    do:
      "That flag is not on this target's allow-list, which is exact-match by design. " <>
        "Pass only flags from allowed_flags, or none. No lease was taken."

  defp default_hint(:invalid_positional, _target),
    do:
      "The positional argument does not match this target's expected shape. " <>
        "Fix or omit `version`. No lease was taken."

  defp default_hint(:script_missing, _target),
    do:
      "The target's deploy script is not present on its node. Nothing was launched and " <>
        "no lease was taken — this is a host problem, not an argument problem."

  defp default_hint(:script_not_executable, target), do: default_hint(:script_missing, target)

  defp default_hint(:job_create_failed, _target),
    do: "Could not create the job row, so nothing launched and no lease was taken."

  defp default_hint(:lease_error, _target),
    do: "Could not record the deploy lease; nothing is running. Retry, and report if it persists."

  defp default_hint(:launch_failed, _target),
    do:
      "The job row was created but the process never started; its lease has been released. " <>
        "Safe to retry once you know why."

  defp default_hint(:remote_pid_missing, _target),
    do:
      "The deploy was cancelled and its lease released because the detached half never " <>
        "reported a pid — an un-rebound deploy job is wrongly reported as failed the " <>
        "moment it restarts the host. Check ssh access to the target host, then retry."

  defp default_hint(_reason, _target),
    do: "The deploy was refused. Read `reason` and the fields alongside it before retrying."

  # ── in_flight_deploys ──────────────────────────────────────────────

  defp do_in_flight(target) when not is_nil(target) and not is_binary(target) do
    json(%{
      "ok" => false,
      "reason" => "unknown_target",
      "target" => inspect(target),
      "known_targets" => Registry.keys(),
      "hint" => default_hint(:unknown_target, target)
    })
  end

  defp do_in_flight(target) do
    target = presence(target)
    entries = Deploys.in_flight(target)

    if is_binary(target) and entries == [] and target not in Registry.keys() do
      json(%{
        "ok" => false,
        "reason" => "unknown_target",
        "target" => target,
        "known_targets" => Registry.keys(),
        "hint" => default_hint(:unknown_target, target)
      })
    else
      deploys = Enum.map(entries, &in_flight_view/1)

      json(%{
        "ok" => true,
        "count" => length(deploys),
        "deploys" => deploys,
        "known_targets" => Registry.keys(),
        "hint" => in_flight_hint(deploys)
      })
    end
  end

  defp in_flight_view(%{lease: lease, job: job, state: state} = entry) do
    %{
      "target" => entry.target,
      "state" => to_string(state),
      "job_id" => lease.job_id,
      "lease_id" => lease.id,
      "session_id" => lease.session_id,
      "runner_node" => lease.runner_node,
      "acquired_at" => lease.acquired_at,
      "expires_at" => lease.expires_at,
      "seconds_remaining" => entry.seconds_remaining,
      "job_status" => job && job.status,
      "note" => lease.note,
      "current_step" => current_step(job, state),
      "hint" => state_hint(state, entry.target, lease.job_id)
    }
  end

  # Only worth a log read for a deploy that might still be producing one.
  defp current_step(%{status: status} = job, :in_flight) when status in ~w(running verifying) do
    case read_log(job) do
      {:ok, log, _truncated?} -> LogParser.parse(log, log_tail_bytes: 0).last_step
      _ -> nil
    end
  end

  defp current_step(_job, _state), do: nil

  defp state_hint(:in_flight, target, job_id),
    do:
      "A deploy is already in flight for #{target}. Poll deploy_status with job_id " <>
        "#{job_id}; do not start a second one."

  defp state_hint(:stale_lease, target, _job_id),
    do:
      "The lease for #{target} is still held but its job already finished — nothing is " <>
        "deploying. start_deploy releases this lease and proceeds."

  defp state_hint(:lease_expired_job_running, target, job_id),
    do:
      "#{target}'s lease expired but job #{job_id} is STILL RUNNING. OrcaHub refuses to " <>
        "steal a lease from a live deploy — cancel_job it, or renew the lease, before " <>
        "deploying again."

  defp state_hint(:expired, target, _job_id),
    do:
      "An expired, unreleased lease for #{target} over a job that is no longer running. " <>
        "Not a deploy in flight — audit residue; it blocks nothing."

  defp state_hint(_state, _target, _job_id), do: nil

  defp in_flight_hint([]), do: "Nothing is holding a deploy lease right now."

  defp in_flight_hint(deploys) do
    live = Enum.count(deploys, &(&1["state"] in ["in_flight", "lease_expired_job_running"]))

    if live > 0 do
      "#{live} of these #{if live == 1, do: "is", else: "are"} a LIVE deploy job — read " <>
        "each entry's state and hint before starting anything."
    else
      "No live deploy job; every entry here is a lease whose job already finished."
    end
  end

  # ── deploy_status ──────────────────────────────────────────────────

  defp do_deploy_status(job_id, _tail) when not is_binary(job_id) or job_id == "" do
    json(%{
      "ok" => false,
      "reason" => "missing_job_id",
      "hint" => "deploy_status needs the `job_id` start_deploy returned."
    })
  end

  defp do_deploy_status(job_id, tail_bytes) do
    case HubRPC.get_job(job_id) do
      nil ->
        json(%{
          "ok" => false,
          "reason" => "unknown_job",
          "job_id" => job_id,
          "hint" =>
            "No job with that id. Check in_flight_deploys for a live deploy, or list_jobs " <>
              "for the id you meant."
        })

      job ->
        lease = find_lease(job)
        target = (lease && lease.target) || target_from_label(job.label)
        status_view(job, lease, target, tail_bytes)
    end
  end

  defp status_view(job, lease, nil, _tail_bytes) do
    json(%{
      "ok" => false,
      "reason" => "not_a_deploy",
      "job_id" => job.id,
      "label" => job.label,
      "lease_id" => lease && lease.id,
      "hint" =>
        "Job #{job.id} was not started by start_deploy (no deploy lease, and its label " <>
          "does not name a target), so there is no deploy to report on. Use check_job."
    })
  end

  defp status_view(job, lease, target, tail_bytes) do
    config = target_config(target)
    bytes = normalize_tail_bytes(tail_bytes)

    {log, truncated?} =
      case read_log(job) do
        {:ok, data, truncated?} -> {data, truncated?}
        _ -> {nil, false}
      end

    parsed = LogParser.parse(log, log_tail_bytes: bytes)

    json(%{
      "ok" => true,
      "target" => target,
      "job_id" => job.id,
      "label" => job.label,
      "status" => job.status,
      "exit_code" => job.exit_code,
      "verify_exit_code" => job.verify_exit_code,
      "runner_node" => job.runner_node,
      "command" => job.command,
      "verify_command" => job.verify_command,
      "started_at" => job.started_at,
      "finished_at" => job.finished_at,
      "duration_seconds" => duration_seconds(job),
      "steps_seen" => parsed.steps_seen,
      "last_step" => parsed.last_step,
      "skipped_steps" => parsed.skipped_steps,
      "errors" => parsed.errors,
      "warnings" => parsed.warnings,
      "log_tail" => parsed.log_tail,
      "log_unavailable" => is_nil(log),
      "log_truncated_for_parsing" => truncated?,
      "verify_log_tail" => verify_log_tail(job, bytes),
      "lease" => lease_view(lease, job),
      "field_notes" => field_notes(job, config),
      "hint" => status_hint(job, parsed)
    })
  end

  # The truthfulness contract of §2.3/§2.6, restated per result so a model
  # reading ONE call has it — not buried in a tool description it may have
  # seen thousands of tokens ago.
  defp field_notes(job, config) do
    %{
      "last_step" =>
        "The step this deploy REACHED, not necessarily the step that failed. They usually " <>
          "coincide under `set -e`; a warn-only failure inside a completed step does not.",
      "warnings" =>
        "Non-fatal stages (on the OrcaHub target: the mini and gb10 installs, the k3s " <>
          "version polls, the prunes) warn and let the deploy continue. A deploy can exit " <>
          "0 with one of them completely failed — read warnings[] before calling it good.",
      "exit_code" => exit_code_note(job, config),
      "verify_exit_code" => verify_exit_code_note(job)
    }
  end

  defp exit_code_note(job, config) do
    reserved = Deploys.indeterminate_exit_code()

    base =
      if config[:escape_cgroup] == true do
        "This target restarts its own host partway through, so the deploy runs outside " <>
          "this service's process tree. exit_code is nonetheless the DEPLOY SCRIPT's own " <>
          "exit code, written by the detached half — not ssh's and not the wrapper's. " <>
          "The single exception is #{reserved}, reserved to mean \"indeterminate: the " <>
          "detached half died without reporting an exit code\"; it is never a script's " <>
          "own status."
      else
        "The deploy script's own exit code."
      end

    if job.exit_code == reserved do
      base <>
        " THIS JOB exited #{reserved}: its outcome is genuinely unknown from the exit code " <>
        "alone — read log_tail and errors, and verify the deploy by hand."
    else
      base
    end
  end

  defp verify_exit_code_note(%{verify_command: nil}),
    do: "This target has no verify command, so nothing independently confirmed the deploy."

  defp verify_exit_code_note(_job),
    do:
      "The verify command's own exit code, run only if the deploy exited 0. 0 means every " <>
        "instance it checks reported the new SHA; non-zero means at least one did not, " <>
        "which is what status verification_failed reports."

  defp status_hint(%{status: "running"}, _parsed),
    do:
      "Still running. Poll deploy_status again, or pass wake_when_done to start_deploy " <>
        "next time rather than polling in a loop."

  defp status_hint(%{status: "verifying"}, _parsed),
    do:
      "The deploy script exited 0 and the verify command is running now — not done yet. " <>
        "The final status will be succeeded or verification_failed."

  defp status_hint(%{status: "succeeded"} = job, parsed) do
    if parsed.warnings == [] do
      "Deploy succeeded" <>
        if(job.verify_command, do: " and verification passed.", else: " (nothing verified it).")
    else
      "Deploy succeeded, BUT it emitted #{length(parsed.warnings)} warning(s). Those stages " <>
        "are non-fatal, so the 0 exit code did not cover them — read warnings[] and decide " <>
        "whether that stage actually needs attention."
    end
  end

  defp status_hint(%{status: "verification_failed"}, _parsed),
    do:
      "The deploy itself exited 0 but verification FAILED: one or more instances are not " <>
        "on the new SHA. Read errors[] and verify_log_tail; a slow instance may settle, in " <>
        "which case re-run the verify script by hand rather than re-deploying."

  defp status_hint(%{status: "failed"}, parsed),
    do:
      "The deploy FAILED. Read errors[] first, then log_tail. last_step (#{inspect(parsed.last_step)}) " <>
        "is where it got to, not necessarily what broke. Do not blindly retry — these " <>
        "scripts are designed to be re-run with --skip-* flags for the stages that already " <>
        "succeeded."

  defp status_hint(%{status: "timed_out"}, _parsed),
    do:
      "The deploy exceeded its time budget and its process group was killed. It may have " <>
        "left a partially-deployed state — read log_tail and check the instances before retrying."

  defp status_hint(%{status: "cancelled"}, _parsed),
    do:
      "The deploy was cancelled. It may have been partway through — read log_tail and " <>
        "steps_seen to see what had already landed."

  defp status_hint(_job, _parsed), do: nil

  defp duration_seconds(%{started_at: %DateTime{} = started, finished_at: %DateTime{} = finished}),
    do: DateTime.diff(finished, started)

  defp duration_seconds(%{started_at: %DateTime{} = started}),
    do: DateTime.diff(DateTime.utc_now(), started)

  defp duration_seconds(_job), do: nil

  # A released lease is DONE, not free — `Deploys.classify/3` folds both into
  # :free, which is the right answer for "may I deploy?" and the wrong one
  # for "what happened to this lease?".
  defp lease_view(nil, _job), do: nil

  defp lease_view(lease, job) do
    now = DateTime.utc_now()

    state =
      if lease.released_at, do: "released", else: to_string(Deploys.classify(lease, job, now))

    %{
      "lease_id" => lease.id,
      "state" => state,
      "acquired_at" => lease.acquired_at,
      "expires_at" => lease.expires_at,
      "released_at" => lease.released_at,
      "seconds_remaining" =>
        if(lease.released_at, do: nil, else: max(DateTime.diff(lease.expires_at, now), 0)),
      "note" => lease.note
    }
  end

  # ── lease / target resolution ──────────────────────────────────────

  # The lease is authoritative for "which target is this job's deploy"; the
  # job label ("deploy <target>", set by OrcaHub.Deploys) is the fallback for
  # a job whose lease row has aged out of the scan window.
  defp find_lease(job) do
    job
    |> candidate_targets()
    |> Enum.find_value(fn target ->
      target
      |> HubRPC.list_deploy_leases_for_target(%{limit: @lease_scan_limit})
      |> Enum.find(&(&1.job_id == job.id))
    end)
  end

  defp candidate_targets(job) do
    labelled = target_from_label(job.label)

    ([labelled] ++ Registry.keys() ++ Enum.map(HubRPC.list_live_deploy_leases(), & &1.target))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp target_from_label(@label_prefix <> target) when target != "", do: target
  defp target_from_label(_label), do: nil

  defp target_config(target) do
    case Registry.fetch(target) do
      {:ok, config} -> config
      _ -> %{}
    end
  end

  # ── log reading (routed to the job's own node) ─────────────────────

  # Deploy targets are node-PINNED, so the log routinely lives on another
  # node — reading it locally (as check_job does) would silently report an
  # empty deploy. Routed through Cluster.rpc/5, which passes through for the
  # local node and refuses rather than falling back for an unavailable one.
  defp read_log(job), do: read_at(job, job.log_path || Paths.log_path(job.id), @max_parse_bytes)

  defp verify_log_tail(%{verify_command: nil}, _bytes), do: nil

  defp verify_log_tail(job, bytes) do
    case read_at(job, Paths.verify_log_path(job.id), max(bytes, 1)) do
      {:ok, data, _truncated?} -> LogParser.tail(data, bytes)
      _ -> nil
    end
  end

  defp read_at(job, path, max_bytes) do
    Cluster.rpc(Cluster.runner_node_for(job), __MODULE__, :read_tail_bytes, [path, max_bytes])
  end

  @doc """
  Read at most the LAST `max_bytes` of `path`. Runs on the job's own node
  via `OrcaHub.Cluster.rpc/5`, so it must stay public.

  Returns `{:ok, data, truncated?}`, where `truncated?` says the head of the
  file was dropped — which `deploy_status` reports rather than silently
  serving a partial `steps_seen`.
  """
  def read_tail_bytes(path, max_bytes) when is_binary(path) and is_integer(max_bytes) do
    with {:ok, %{size: size}} <- File.stat(path),
         offset = max(size - max_bytes, 0),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      :file.position(io, offset)
      data = IO.binread(io, :eof)
      File.close(io)

      if is_binary(data), do: {:ok, data, offset > 0}, else: {:error, :unreadable}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unreadable}
    end
  end

  def read_tail_bytes(_path, _max_bytes), do: {:error, :badarg}

  # ── shared helpers ─────────────────────────────────────────────────

  defp json(body), do: text(Jason.encode!(body))

  defp normalize_tail_bytes(n) when is_integer(n) and n > 0, do: min(n, @max_log_tail_bytes)
  defp normalize_tail_bytes(_n), do: @default_log_tail_bytes

  defp presence(str) when is_binary(str) do
    if String.trim(str) == "", do: nil, else: str
  end

  defp presence(_str), do: nil

  # Refusal details come from OrcaHub.Deploys as an atom-keyed map with
  # nested maps (`held_by`) — JSON-encodable either way, but stringified so
  # the merge below can't produce a map with both :target and "target".
  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(value), do: value
end
