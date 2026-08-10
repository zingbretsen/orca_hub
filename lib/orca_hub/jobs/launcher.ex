defmodule OrcaHub.Jobs.Launcher do
  @moduledoc """
  Spawns a job's (or its verify phase's) OS process fully DETACHED from the
  BEAM — empirically verified, not just reasoned about (see the ORCAHUB3-25
  commit history/report for the manual proof), to survive both the
  launching Erlang port closing and this whole node restarting:

    1. The actual command is written to a durable script file
       (`OrcaHub.Jobs.Paths.cmd_script_path/1`) — never interpolated
       in-line into another shell string.
    2. A small wrapper script runs that script with stdout+stderr
       redirected to a durable log file, then writes its exit code to a
       durable sentinel file via a write-to-`.tmp`-then-`rename` (atomic —
       a watcher never observes a partially-written sentinel).
    3. The Erlang port launches `setsid sh <wrapper> & echo $! > <pidfile>`
       — `setsid` (no `--fork`) execs the wrapper IN PLACE as a new session
       AND process group leader, so the pid captured via `$!` is the same
       pid as the wrapper itself, and `pid == pgid == sid`. The outer `sh
       -c` that the port owns exits immediately after writing the pidfile
       (near-instant — this is a handshake, not the job), so the port only
       ever observes a launch handshake, never the job's actual lifetime.

  Cancellation/timeout note (also empirically confirmed): sending a signal
  to the negative pgid kills the wrapper itself along with the job, so the
  wrapper's own sentinel-writing step never runs in that case — a killed
  job's sentinel is NOT expected to appear. `OrcaHub.JobWatcher` accounts
  for this: cancel/timeout finalize by confirming the process is gone, not
  by waiting for a sentinel that a group-kill prevents from ever being
  written.
  """

  require Logger
  alias OrcaHub.Jobs.Paths

  @handshake_timeout_ms 5_000

  @doc "Launch the main command for `job` (an `OrcaHub.Jobs.Job`). Returns `{:ok, pid}` or `{:error, reason}` — `pid == pgid` by construction."
  def launch_main(job) do
    launch(
      job.directory,
      job.command,
      Paths.cmd_script_path(job.id),
      Paths.wrapper_script_path(job.id),
      Paths.log_path(job.id),
      Paths.sentinel_path(job.id),
      Paths.pid_path(job.id)
    )
  end

  @doc "Launch the verify command for `job`. Same contract as `launch_main/1`."
  def launch_verify(job) do
    launch(
      job.directory,
      job.verify_command,
      Paths.verify_cmd_script_path(job.id),
      Paths.verify_wrapper_script_path(job.id),
      Paths.verify_log_path(job.id),
      Paths.verify_sentinel_path(job.id),
      Paths.verify_pid_path(job.id)
    )
  end

  defp launch(directory, command, script_path, wrapper_path, log_path, sentinel_path, pid_path) do
    with {:ok, sh} <- find_executable("sh"),
         {:ok, setsid} <- find_executable("setsid") do
      Paths.ensure_dir!()
      File.rm(pid_path)
      File.rm(sentinel_path)
      File.write!(script_path, command)
      File.write!(wrapper_path, wrapper_script(sh, script_path, log_path, sentinel_path))

      launcher_cmd =
        "cd #{Paths.shq(directory)} && " <>
          "#{Paths.shq(setsid)} #{Paths.shq(sh)} #{Paths.shq(wrapper_path)} " <>
          "< /dev/null > /dev/null 2>&1 & " <>
          "echo $! > #{Paths.shq(pid_path)}"

      port =
        Port.open({:spawn_executable, sh}, [
          :binary,
          :exit_status,
          {:args, ["-c", launcher_cmd]},
          {:cd, String.to_charlist(directory)},
          {:env, job_env()}
        ])

      await_handshake(port, pid_path)
    end
  end

  defp wrapper_script(sh, script_path, log_path, sentinel_path) do
    tmp_sentinel = sentinel_path <> ".tmp"

    """
    #!/bin/sh
    #{Paths.shq(sh)} #{Paths.shq(script_path)} > #{Paths.shq(log_path)} 2>&1
    rc=$?
    printf '%s' "$rc" > #{Paths.shq(tmp_sentinel)}
    mv #{Paths.shq(tmp_sentinel)} #{Paths.shq(sentinel_path)}
    """
  end

  defp await_handshake(port, pid_path) do
    receive do
      {^port, {:exit_status, 0}} ->
        read_pid(pid_path)

      {^port, {:exit_status, code}} ->
        {:error, {:launcher_exit, code}}
    after
      @handshake_timeout_ms ->
        Port.close(port)
        {:error, :launcher_handshake_timeout}
    end
  end

  defp read_pid(pid_path) do
    case File.read(pid_path) do
      {:ok, content} ->
        case content |> String.trim() |> Integer.parse() do
          {pid, _} -> {:ok, pid}
          :error -> {:error, {:bad_pidfile, content}}
        end

      {:error, reason} ->
        {:error, {:pidfile_missing, reason}}
    end
  end

  defp find_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:executable_not_found, name}}
      path -> {:ok, path}
    end
  end

  # Same per-node scrub policy as agent-CLI sessions/terminals (Stage 2 env
  # allow-list extension) — a job launched on an untrusted-triggered node
  # shouldn't get pod/host secrets any more than a session's Bash tool does.
  # Jobs have no `project_id` of their own to extend the allow-list with
  # (unlike sessions/terminals) — only the node's own `env_allowlist`
  # applies.
  defp job_env do
    if OrcaHub.NodePolicy.scrub_session_env?() do
      OrcaHub.Env.strict_env([], OrcaHub.NodePolicy.extra_env_allowlist())
    else
      OrcaHub.Env.sanitized_env()
    end
  end
end
