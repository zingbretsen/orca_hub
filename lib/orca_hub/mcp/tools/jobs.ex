defmodule OrcaHub.MCP.Tools.Jobs do
  @moduledoc """
  MCP tools for the Jobs subsystem (ORCAHUB3-25) — durable, detached
  background jobs that outlive this session's own process. See
  `OrcaHub.Jobs` for the full subsystem design and the field-report
  rationale behind its two hard invariants (the job declares its own
  progress metric; OrcaHub never adjudicates "stalled").

  `check_job`/`list_jobs` are pure DB reads via `HubRPC` — they never touch
  a live watcher process, so probing a job costs nothing and interrupts
  nothing, on any node, regardless of where the job is actually running.
  `cancel_job` is the one tool here that needs to reach the job's OWN node
  (to actually signal the OS process), so it's the only one routed through
  `OrcaHub.Cluster.rpc/5`.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, HubRPC, JobSupervisor}

  @heartbeat_caveat "A heartbeat does not prevent teardown — it only wakes you up " <>
                      "afterwards. It is the POLLING mechanism, not the durability " <>
                      "mechanism. The job keeps running whether or not anything is " <>
                      "watching it; only start_job (this tool) makes it durable."

  @max_wait_seconds 120
  @log_tail_bytes 4_000

  def list do
    [
      %{
        "name" => "start_job",
        "description" =>
          "Start a DETACHED, durable background job — the OS process survives this " <>
            "session ending, idle teardown, a warm-pool eviction, an OrcaHub restart or " <>
            "deploy, or a graceful interrupt. Use this for anything that should keep " <>
            "running independent of this conversation: a large download, a long build, a " <>
            "full test suite, a deploy. Returns immediately with a job_id — this tool " <>
            "does NOT wait for the command to finish; poll with check_job or block " <>
            "briefly with wait_for_job.\n\n" <>
            "PROGRESS: you can declare EXACTLY ONE metric OrcaHub should sample on an " <>
            "interval — a file to stat (progress_path, optionally with " <>
            "progress_expect_bytes as the total) or a command to run and parse " <>
            "(progress_command — its stdout may be a bare number, \"value/total\", or " <>
            "JSON like {\"value\":, \"total\":, \"note\":}). OrcaHub NEVER infers a metric " <>
            "on its own — if the job's own strategy changes mid-flight (e.g. switching " <>
            "from one file download to several parallel ranged ones), call " <>
            "update_job_progress_metric to re-declare it; the old metric going stale is " <>
            "expected in that case, not a sign the job died.\n\n" <>
            "VERIFICATION: if verify_command is given, it only runs after the main " <>
            "command exits 0, and the job only reaches a terminal status AFTER " <>
            "verify_command itself finishes — status goes running -> verifying -> " <>
            "succeeded | verification_failed. This exists so \"done\" always means a " <>
            "VERIFIED artifact, never just a present one (e.g. verify_command for a big " <>
            "download might be a checksum check) — don't start consuming the artifact " <>
            "until check_job shows a terminal status.\n\n" <>
            "wake_when_done: pass true and you'll be woken (same queue-while-running/" <>
            "flush-at-turn-end delivery as schedule_heartbeat) the moment this job reaches " <>
            "a TERMINAL status — succeeded/failed/verification_failed/timed_out/cancelled. " <>
            "verifying does NOT wake you: a consumer woken while verify_command is still " <>
            "running would get an unverified artifact, which is the one thing this design " <>
            "exists to prevent. Works standalone, with no schedule_heartbeat call needed " <>
            "first. For watching several jobs together with any/all semantics, use " <>
            "schedule_heartbeat's watch_job_ids/wake_on instead. " <> @heartbeat_caveat,
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "Shell command (or script — multi-line is fine) to run."
            },
            "cwd" => %{
              "type" => "string",
              "description" => "Working directory. Defaults to this session's own directory."
            },
            "label" => %{
              "type" => "string",
              "description" => "Short human-readable label shown in list_jobs/check_job."
            },
            "verify_command" => %{
              "type" => "string",
              "description" =>
                "Optional command run AFTER `command` exits 0, in the same directory, " <>
                  "also fully detached. Its own exit code decides succeeded vs " <>
                  "verification_failed. Skipped entirely if `command` doesn't exit 0."
            },
            "timeout_seconds" => %{
              "type" => "integer",
              "description" =>
                "Optional wall-clock budget covering the main command AND any verify " <>
                  "phase together. Exceeding it kills the process group and marks the " <>
                  "job timed_out. No timeout if omitted."
            },
            "progress_path" => %{
              "type" => "string",
              "description" =>
                "Declare a file_bytes progress metric: this file's size is sampled on " <>
                  "an interval. Ignored if progress_command is also given."
            },
            "progress_expect_bytes" => %{
              "type" => "integer",
              "description" =>
                "Optional total for progress_path, e.g. the expected download size."
            },
            "progress_command" => %{
              "type" => "string",
              "description" =>
                "Declare a command progress metric instead of progress_path: run on an " <>
                  "interval, stdout parsed as a bare number, \"value/total\", or JSON " <>
                  "{\"value\":, \"total\":, \"note\":}. Takes precedence over progress_path " <>
                  "if both are given."
            },
            "wake_when_done" => %{
              "type" => "boolean",
              "description" =>
                "Wake this session when the job reaches a terminal status (not on entering " <>
                  "verifying). See this tool's description."
            }
          },
          "required" => ["command"]
        }
      },
      %{
        "name" => "check_job",
        "description" =>
          "Check a job's current status, declared progress metric, and a tail of its " <>
            "log — a pure DB read, costs nothing and interrupts nothing regardless of " <>
            "which node the job is actually running on. progress_updated_at_age_seconds " <>
            "is surfaced so YOU can judge whether that's healthy for the metric this job " <>
            "declared — OrcaHub itself never decides a job is \"stalled\".",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "job_id" => %{"type" => "string", "description" => "The job's id."}
          },
          "required" => ["job_id"]
        }
      },
      %{
        "name" => "list_jobs",
        "description" =>
          "List jobs, most recently updated first. Defaults to only jobs started from " <>
            "this session (mine=true) — pass mine=false to see every job across every " <>
            "session and node (useful for an orchestrator checking on a job a child " <>
            "session started).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "mine" => %{
              "type" => "boolean",
              "description" => "Restrict to jobs started from this session. Default true."
            },
            "status" => %{
              "type" => "string",
              "description" =>
                "Filter to one status: running, verifying, succeeded, failed, " <>
                  "verification_failed, timed_out, or cancelled."
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Max results, default 50, capped at 200."
            }
          }
        }
      },
      %{
        "name" => "cancel_job",
        "description" =>
          "Cancel a running/verifying job: sends the process group a TERM, then a KILL " <>
            "after a short grace period if it hasn't exited. Reaches the job's actual " <>
            "node to do this, wherever that is. No-op (reported, not an error) if the " <>
            "job already reached a terminal status.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "job_id" => %{"type" => "string", "description" => "The job's id."}
          },
          "required" => ["job_id"]
        }
      },
      %{
        "name" => "wait_for_job",
        "description" =>
          "Block THIS turn for up to max_wait_seconds (capped at #{@max_wait_seconds}), " <>
            "polling for the job to reach a terminal status, and return as soon as it " <>
            "does — or the current (still running/verifying) state if the wait budget " <>
            "runs out first, never an error either way. Exists so you stop hand-rolling " <>
            "`until ...; sleep` loops for a job you expect to finish soon; for anything " <>
            "longer, poll with check_job instead of burning turns here. " <> @heartbeat_caveat,
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "job_id" => %{"type" => "string", "description" => "The job's id."},
            "max_wait_seconds" => %{
              "type" => "integer",
              "description" => "How long to block, capped at #{@max_wait_seconds} seconds."
            }
          },
          "required" => ["job_id"]
        }
      },
      %{
        "name" => "update_job_progress_metric",
        "description" =>
          "RE-DECLARE a running job's progress metric mid-flight — for when the job's " <>
            "own strategy changed (e.g. one download became several parallel ranged " <>
            "ones) and the OLD metric would otherwise look frozen/dead even though real " <>
            "progress is happening elsewhere. Takes effect on the watcher's next poll " <>
            "tick, no restart needed. Same field rules as start_job: progress_command " <>
            "takes precedence over progress_path if both are given.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "job_id" => %{"type" => "string", "description" => "The job's id."},
            "progress_path" => %{
              "type" => "string",
              "description" => "New file_bytes metric: file to stat."
            },
            "progress_expect_bytes" => %{
              "type" => "integer",
              "description" => "Optional new total for progress_path."
            },
            "progress_command" => %{
              "type" => "string",
              "description" =>
                "New command metric — see start_job's description for the output format."
            }
          },
          "required" => ["job_id"]
        }
      }
    ]
  end

  def call("start_job", args, state), do: do_start_job(args, state)
  def call("check_job", args, _state), do: do_check_job(args["job_id"])
  def call("list_jobs", args, state), do: do_list_jobs(args, state)
  def call("cancel_job", args, _state), do: do_cancel_job(args["job_id"])

  def call("wait_for_job", args, _state),
    do: do_wait_for_job(args["job_id"], args["max_wait_seconds"])

  def call("update_job_progress_metric", args, _state),
    do: do_update_progress_metric(args["job_id"], args)

  # ── start_job ──────────────────────────────────────────────────────

  defp do_start_job(args, state) do
    command = args["command"]

    cond do
      not is_binary(command) or command == "" ->
        error("start_job requires a non-empty `command` string argument.")

      is_nil(state[:orca_session_id]) ->
        error("No OrcaHub session linked to this MCP connection.")

      true ->
        resolve_directory(args, state.orca_session_id)
    end
  end

  defp resolve_directory(%{"cwd" => cwd} = args, session_id) when is_binary(cwd) and cwd != "" do
    launch_job(cwd, session_id, args)
  end

  defp resolve_directory(args, session_id) do
    case HubRPC.get_session(session_id) do
      nil -> error("Session #{session_id} not found.")
      %{directory: dir} when is_binary(dir) and dir != "" -> launch_job(dir, session_id, args)
      _ -> error("Could not resolve a working directory — pass `cwd` explicitly.")
    end
  end

  defp launch_job(directory, session_id, args) do
    attrs =
      %{
        session_id: session_id,
        directory: directory,
        runner_node: Atom.to_string(node()),
        label: args["label"],
        command: args["command"],
        verify_command: normalize_blank(args["verify_command"]),
        timeout_seconds: args["timeout_seconds"]
      }
      |> Map.merge(progress_attrs_from_args(args))

    case HubRPC.create_job(attrs) do
      {:ok, job} -> start_and_report(job, args["wake_when_done"] == true)
      {:error, changeset} -> error("Failed to create job: #{inspect(changeset.errors)}")
    end
  end

  defp start_and_report(job, wake_when_done?) do
    case JobSupervisor.start_job(job.id) do
      {:ok, started} ->
        note =
          if wake_when_done? do
            HubRPC.watch_job(started.session_id, started.id)

            "Job launched detached — it will keep running even if this session ends. " <>
              "You'll be woken (via the same delivery path as schedule_heartbeat) once it " <>
              "reaches a terminal status — verifying does not wake you, only " <>
              "succeeded/failed/verification_failed/timed_out/cancelled do."
          else
            "Job launched detached — it will keep running even if this session ends."
          end

        text(
          Jason.encode!(%{
            job_id: started.id,
            status: started.status,
            pid: started.pid,
            log_path: started.log_path,
            note: note
          })
        )

      {:error, reason} ->
        error("Job row #{job.id} was created but failed to launch: #{inspect(reason)}")
    end
  end

  # ── check_job ──────────────────────────────────────────────────────

  defp do_check_job(job_id) when not is_binary(job_id) or job_id == "" do
    error("check_job requires a `job_id` string argument.")
  end

  defp do_check_job(job_id) do
    case HubRPC.get_job(job_id) do
      nil -> error("No job found with id #{job_id}.")
      job -> text(Jason.encode!(check_job_view(job)))
    end
  end

  defp check_job_view(job) do
    %{
      id: job.id,
      label: job.label,
      status: job.status,
      runner_node: job.runner_node,
      command: job.command,
      verify_command: job.verify_command,
      exit_code: job.exit_code,
      verify_exit_code: job.verify_exit_code,
      timeout_seconds: job.timeout_seconds,
      started_at: job.started_at,
      finished_at: job.finished_at,
      progress: %{
        kind: job.progress_kind,
        value: job.progress_value,
        total: job.progress_total,
        note: job.progress_note,
        updated_at: job.progress_updated_at,
        updated_at_age_seconds: age_seconds(job.progress_updated_at)
      },
      log_tail: tail(OrcaHub.Jobs.Paths.log_path(job.id)),
      verify_log_tail: job.verify_command && tail(OrcaHub.Jobs.Paths.verify_log_path(job.id))
    }
  end

  defp age_seconds(nil), do: nil
  defp age_seconds(%DateTime{} = ts), do: DateTime.diff(DateTime.utc_now(), ts)

  defp tail(nil), do: nil

  defp tail(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        offset = max(size - @log_tail_bytes, 0)

        case File.open(path, [:read]) do
          {:ok, io} ->
            :file.position(io, offset)
            data = IO.binread(io, :eof)
            File.close(io)
            if is_binary(data), do: data, else: nil

          {:error, _reason} ->
            nil
        end

      {:error, _reason} ->
        nil
    end
  end

  # ── list_jobs ──────────────────────────────────────────────────────

  defp do_list_jobs(args, state) do
    mine? = Map.get(args, "mine", true) == true

    opts =
      %{status: normalize_blank(args["status"]), limit: args["limit"]}
      |> Map.put(:session_id, if(mine?, do: state[:orca_session_id]))

    jobs = opts |> HubRPC.list_jobs() |> Enum.map(&list_job_summary/1)

    text(Jason.encode!(%{count: length(jobs), jobs: jobs}))
  end

  defp list_job_summary(job) do
    %{
      id: job.id,
      label: job.label,
      status: job.status,
      runner_node: job.runner_node,
      exit_code: job.exit_code,
      verify_exit_code: job.verify_exit_code,
      updated_at: job.updated_at
    }
  end

  # ── cancel_job ─────────────────────────────────────────────────────

  defp do_cancel_job(job_id) when not is_binary(job_id) or job_id == "" do
    error("cancel_job requires a `job_id` string argument.")
  end

  defp do_cancel_job(job_id) do
    case HubRPC.get_job(job_id) do
      nil ->
        error("No job found with id #{job_id}.")

      %{status: status} when status not in ["running", "verifying"] ->
        text("Job #{job_id} already reached a terminal status (#{status}) — nothing to cancel.")

      job ->
        route_cancel(job)
    end
  end

  defp route_cancel(job) do
    case node_atom(job.runner_node) do
      {:ok, node} ->
        case Cluster.rpc(node, JobSupervisor, :cancel_job, [job.id]) do
          :ok -> text("Cancelling job #{job.id} (TERM now, KILL shortly if it doesn't exit).")
          {:error, reason} -> error("Failed to cancel job #{job.id}: #{inspect(reason)}")
        end

      {:error, _reason} ->
        error(
          "Job #{job.id}'s runner_node (#{job.runner_node}) isn't currently known — it may be offline."
        )
    end
  end

  defp node_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :unknown_node}
  end

  defp node_atom(_name), do: {:error, :unknown_node}

  # ── wait_for_job ───────────────────────────────────────────────────

  defp do_wait_for_job(job_id, _max_wait) when not is_binary(job_id) or job_id == "" do
    error("wait_for_job requires a `job_id` string argument.")
  end

  defp do_wait_for_job(job_id, max_wait_seconds) do
    budget_ms = normalize_wait_seconds(max_wait_seconds) * 1000
    deadline = System.monotonic_time(:millisecond) + budget_ms
    poll_until_terminal_or_deadline(job_id, deadline)
  end

  defp normalize_wait_seconds(n) when is_integer(n) and n > 0, do: min(n, @max_wait_seconds)
  defp normalize_wait_seconds(_n), do: @max_wait_seconds

  @wait_poll_interval_ms 1_000

  defp poll_until_terminal_or_deadline(job_id, deadline) do
    case HubRPC.get_job(job_id) do
      nil ->
        error("No job found with id #{job_id}.")

      %{status: status} = job when status not in ["running", "verifying"] ->
        text(Jason.encode!(check_job_view(job)))

      job ->
        if System.monotonic_time(:millisecond) >= deadline do
          text(Jason.encode!(Map.put(check_job_view(job), :wait_timed_out, true)))
        else
          Process.sleep(
            min(@wait_poll_interval_ms, max(deadline - System.monotonic_time(:millisecond), 0))
          )

          poll_until_terminal_or_deadline(job_id, deadline)
        end
    end
  end

  # ── update_job_progress_metric ────────────────────────────────────

  defp do_update_progress_metric(job_id, _args) when not is_binary(job_id) or job_id == "" do
    error("update_job_progress_metric requires a `job_id` string argument.")
  end

  defp do_update_progress_metric(job_id, args) do
    attrs = progress_attrs_from_args(args)

    cond do
      map_size(attrs) == 0 ->
        error("Provide either `progress_path` or `progress_command` to declare a metric.")

      true ->
        case HubRPC.get_job(job_id) do
          nil -> error("No job found with id #{job_id}.")
          job -> persist_progress_update(job, attrs)
        end
    end
  end

  defp persist_progress_update(job, attrs) do
    case HubRPC.update_job(job, attrs) do
      {:ok, updated} ->
        text(
          Jason.encode!(%{
            job_id: updated.id,
            progress_kind: updated.progress_kind,
            progress_path: updated.progress_path,
            progress_command: updated.progress_command,
            note: "Metric re-declared — takes effect on the watcher's next poll tick."
          })
        )

      {:error, changeset} ->
        error("Failed to update progress metric: #{inspect(changeset.errors)}")
    end
  end

  # ── shared helpers ─────────────────────────────────────────────────

  defp progress_attrs_from_args(args) do
    cond do
      present?(args["progress_command"]) ->
        %{
          progress_kind: "command",
          progress_command: args["progress_command"],
          progress_path: nil,
          progress_expect_bytes: nil
        }

      present?(args["progress_path"]) ->
        %{
          progress_kind: "file_bytes",
          progress_path: args["progress_path"],
          progress_expect_bytes: normalize_int(args["progress_expect_bytes"]),
          progress_command: nil
        }

      true ->
        %{}
    end
  end

  defp present?(str), do: is_binary(str) and String.trim(str) != ""

  defp normalize_int(n) when is_integer(n), do: n
  defp normalize_int(_n), do: nil

  defp normalize_blank(str) when is_binary(str) do
    if String.trim(str) == "", do: nil, else: str
  end

  defp normalize_blank(_str), do: nil
end
