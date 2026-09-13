defmodule OrcaHub.Triggers.SetupScript do
  @moduledoc """
  Runs a trigger's operator-authored pre-run setup script and turns the
  result into something the agent (and a human) can see.

  A setup script is a *gather current state before this run* hook, not
  one-time provisioning: it runs on EVERY firing of the trigger, including a
  `reuse_session: true` firing that reuses an existing session. It runs on
  the session's runner node, in the session's directory, and its combined
  stdout+stderr, exit code and duration are prepended to the trigger prompt
  in a `<setup_script>` block (`prepend/2`) and persisted to the session feed
  as a `system`/`setup_script` event (`OrcaHub.Sessions.persist_system_event/2`).

  The motivating case: a nightly trigger whose prompt began "Note the current
  wall-clock time before you do anything else (e.g. run `date -u` once)" —
  an instruction the model was free to skip. `setup_script: "date -u"` makes
  it structural.

  ## Node routing

  `run/3` routes through `OrcaHub.Cluster.rpc/5` unconditionally. The two
  `OrcaHub.TriggerExecutor` entry points are asymmetric — `execute/1` (cron)
  runs on the HUB, while `execute_payload/2` already runs its whole body on
  the runner node — and `Cluster.rpc/5` collapses to a plain local `apply/3`
  when the target node is `node()`, so one uniform call is correct for both
  without either path having to know which case it is in.

  ## Security: payload data deliberately never reaches the script

  The script is a STATIC, operator-authored trigger field. No part of a
  webhook body or an inbound email — not the body, not a header, not a
  filename — is ever interpolated into the script, its arguments, or its
  environment. A webhook payload is arbitrary third-party JSON and an email
  body is untrusted by construction; either one reaching a shell would be a
  command-injection hole. `execute/4` accordingly takes only the script text,
  the directory, a timeout and a project id, and there is deliberately no
  parameter through which a caller could pass payload-derived data.

  The script text itself is written to a temp file and executed as a file —
  never interpolated into an `sh -c` string — so even the operator's own
  quoting cannot escape into the launcher command.

  ## Bounded, and it takes its children with it

  `setup_timeout_seconds` (default 120) bounds the run. The script is
  launched under `setsid` so it becomes a session/process-group leader, and
  it writes its own pid (`$$` — the group leader's pid by construction,
  whether or not `setsid(1)` chose to fork) to a pidfile. A timeout therefore
  signals the whole process GROUP (`kill -TERM -<pgid>`, then `-KILL` after a
  short grace), so a script that backgrounds children cannot leave orphans
  behind. This mirrors `OrcaHub.Jobs.Launcher`'s process-group handling but
  deliberately does NOT reuse the Jobs subsystem, which exists for DETACHED
  long-running work — this is a synchronous, bounded, captured run whose
  output has to be in hand before the prompt is sent.

  ## Failure never aborts the firing

  A non-zero exit, a timeout, an unreachable node, or a missing directory all
  produce a `Result` that is logged at `:warning` and surfaced prominently in
  the prompt block — the firing continues. Silently skipping a scheduled run
  because a `git pull` failed is worse than running it with a loud warning.
  """

  require Logger

  alias OrcaHub.{Cluster, HubRPC}

  @default_timeout_seconds 120
  @max_output_bytes 16 * 1024
  # How long a TERMed process group gets to die before it is KILLed.
  @kill_grace_ms 2_000
  # Slack on top of the script's own timeout for the rpc/task round trip,
  # the group-kill grace, and temp-file bookkeeping.
  @overhead_ms 15_000

  defmodule Result do
    @moduledoc """
    Outcome of one setup-script run: `output` is the (possibly tail-
    truncated) combined stdout+stderr, `exit_code` is nil when the script
    never produced one (timeout, or a failure to launch at all), and `error`
    is set only for a failure OUTSIDE the script itself (node unreachable,
    missing directory, launcher crash).
    """
    defstruct output: "",
              exit_code: nil,
              duration_ms: 0,
              timed_out: false,
              truncated_bytes: 0,
              error: nil

    @type t :: %__MODULE__{
            output: String.t(),
            exit_code: integer() | nil,
            duration_ms: non_neg_integer(),
            timed_out: boolean(),
            truncated_bytes: non_neg_integer(),
            error: String.t() | nil
          }

    @doc "Whether this run should be reported to the agent as a failure."
    def failed?(%__MODULE__{} = r), do: r.timed_out or r.error != nil or r.exit_code not in [0]
  end

  @doc "Whether `trigger` has a setup script worth running (non-blank)."
  def configured?(%{setup_script: script}) when is_binary(script), do: String.trim(script) != ""
  def configured?(_trigger), do: false

  @doc """
  The effective timeout for `trigger` in seconds — the column, or
  #{@default_timeout_seconds} when it is nil/invalid (a legacy row, or a
  changeset that explicitly nulled it).
  """
  def timeout_seconds(%{setup_timeout_seconds: seconds})
      when is_integer(seconds) and seconds > 0,
      do: seconds

  def timeout_seconds(_trigger), do: @default_timeout_seconds

  @doc """
  Run `trigger`'s setup script for `session_id` on `runner_node`, persist a
  system event for it, and return the `Result` — or `nil` when the trigger
  has no setup script (the overwhelmingly common case, which costs nothing
  but a field read).

  Never raises: every failure mode becomes a `Result` with `error` set.
  """
  def run(trigger, session_id, runner_node) do
    if configured?(trigger) do
      result = do_run(trigger, session_id, runner_node)
      log(trigger, result)
      persist_event(trigger, session_id, result)
      result
    end
  rescue
    e ->
      Logger.warning(
        "[setup_script] trigger #{inspect(Map.get(trigger, :id))} setup script failed " <>
          "unexpectedly: #{Exception.message(e)}"
      )

      %Result{error: "setup script failed unexpectedly: #{Exception.message(e)}"}
  end

  defp do_run(trigger, session_id, runner_node) do
    case HubRPC.get_session(session_id) do
      %{directory: directory} = session when is_binary(directory) ->
        timeout = timeout_seconds(trigger)

        Cluster.rpc(
          runner_node,
          __MODULE__,
          :execute,
          [trigger.setup_script, directory, timeout, Map.get(session, :project_id)],
          timeout * 1_000 + @overhead_ms
        )
        |> normalize_rpc_result(runner_node)

      _ ->
        %Result{error: "session #{session_id} has no directory to run the setup script in"}
    end
  end

  defp normalize_rpc_result(%Result{} = result, _node), do: result

  defp normalize_rpc_result({:error, reason}, runner_node) do
    %Result{
      error: "could not run the setup script on #{inspect(runner_node)}: #{inspect(reason)}"
    }
  end

  defp normalize_rpc_result(other, runner_node) do
    %Result{
      error: "unexpected setup script result from #{inspect(runner_node)}: #{inspect(other)}"
    }
  end

  # ------------------------------------------------------------------
  # Remote entry point — runs ON the session's runner node.
  # ------------------------------------------------------------------

  @doc """
  Execute `script` in `directory`, bounded by `timeout_seconds`, capturing
  combined stdout+stderr. Runs on the node it is called on; `run/3` is what
  routes it. Returns a `Result` and never raises.

  `project_id` is used only to resolve the node+project env allow-list
  extension (`OrcaHub.NodePolicy.extra_env_allowlist/1`) — the script gets
  exactly the environment a session or terminal spawned on this node would.
  """
  def execute(script, directory, timeout_seconds, project_id \\ nil) do
    task =
      Task.Supervisor.async_nolink(OrcaHub.TaskSupervisor, fn ->
        run_port(script, directory, timeout_seconds, project_id)
      end)

    outer = timeout_seconds * 1_000 + @overhead_ms

    case Task.yield(task, outer) || Task.shutdown(task, :brutal_kill) do
      {:ok, %Result{} = result} ->
        result

      {:exit, reason} ->
        %Result{error: "setup script runner crashed: #{inspect(reason)}"}

      _ ->
        %Result{
          error: "setup script runner did not return within #{outer}ms",
          timed_out: true
        }
    end
  end

  defp run_port(script, directory, timeout_seconds, project_id) do
    started = System.monotonic_time(:millisecond)

    if File.dir?(directory) do
      paths = temp_paths()

      try do
        write_scripts!(paths, script)
        launch_and_collect(paths, directory, timeout_seconds, project_id, started)
      rescue
        e ->
          %Result{
            error: "setup script could not be launched: #{Exception.message(e)}",
            duration_ms: elapsed(started)
          }
      after
        Enum.each([paths.script, paths.wrapper, paths.pid], &File.rm/1)
      end
    else
      %Result{
        error: "setup script directory #{directory} does not exist on #{node()}",
        duration_ms: elapsed(started)
      }
    end
  end

  defp launch_and_collect(paths, directory, timeout_seconds, project_id, started) do
    port =
      Port.open({:spawn_executable, sh()}, [
        :binary,
        :exit_status,
        :hide,
        {:args, ["-c", launcher_command(paths)]},
        {:cd, String.to_charlist(directory)},
        {:env, setup_env(project_id)}
      ])

    deadline = started + timeout_seconds * 1_000

    case collect(port, deadline, "", 0) do
      {:done, code, output, dropped} ->
        close(port)

        %Result{
          output: render_output(output, dropped),
          exit_code: code,
          duration_ms: elapsed(started),
          truncated_bytes: dropped
        }

      {:timeout, output, dropped} ->
        {output, dropped} = kill_and_drain(port, paths, output, dropped)
        close(port)

        %Result{
          output: render_output(output, dropped),
          exit_code: nil,
          duration_ms: elapsed(started),
          timed_out: true,
          truncated_bytes: dropped
        }
    end
  end

  # The port's direct child is a plain `sh -c`, which runs `setsid` as a
  # FOREGROUND child and waits for it. Two properties fall out of that shape,
  # and both matter:
  #
  #   * the `setsid` process is not a process-group leader (it was just
  #     forked by the outer sh), so `setsid(1)` execs the wrapper IN PLACE
  #     rather than forking — the wrapper is the new session/group leader and
  #     `$$` inside it is the pgid;
  #   * the outer sh is NOT in that new group, so a group kill leaves it
  #     alive to reap the child and exit, and the port still reports an exit
  #     status instead of hanging.
  #
  # The wrapper inherits the port's stdout pipe, so output streams the whole
  # time. `setsid` missing (macOS dev boxes don't ship it) degrades to a
  # direct run — bounded and captured just the same, only without the group
  # isolation, and `kill_group/1` then falls back to killing the pid alone.
  # The leading `exec 2>&1` points the OUTER sh's own stderr at the port pipe
  # as well (the wrapper redirects its own separately). Without it, a
  # launcher-level failure — `setsid` not executable, the wrapper unreadable
  # — and the shell's "Terminated" notice on a group kill would go to the
  # BEAM's inherited stderr and land in the journal with no context, instead
  # of in the captured output where whoever reads the result can see it.
  defp launcher_command(paths) do
    run = "#{shq(sh())} #{shq(paths.wrapper)} < /dev/null"

    run =
      case setsid() do
        nil -> run
        setsid -> "#{shq(setsid)} " <> run
      end

    "exec 2>&1; " <> run
  end

  defp write_scripts!(paths, script) do
    File.mkdir_p!(Path.dirname(paths.script))
    # The operator's script goes to disk VERBATIM and is executed as a file —
    # never spliced into a shell command string.
    File.write!(paths.script, script)

    File.write!(paths.wrapper, """
    #!/bin/sh
    echo $$ > #{shq(paths.pid)}
    exec 2>&1
    exec #{shq(sh())} #{shq(paths.script)}
    """)
  end

  defp collect(port, deadline, output, dropped) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, output, dropped}
    else
      receive do
        {^port, {:data, chunk}} ->
          {output, dropped} = append(output, dropped, chunk)
          collect(port, deadline, output, dropped)

        {^port, {:exit_status, code}} ->
          {:done, code, output, dropped}
      after
        remaining -> {:timeout, output, dropped}
      end
    end
  end

  # Signal the whole process group, then keep draining: a TERMed script may
  # still emit a final line, and the outer sh's exit status arrives once its
  # child is reaped. Whatever is still alive after the grace gets KILLed.
  defp kill_and_drain(port, paths, output, dropped) do
    pid = read_pid(paths.pid) || port_os_pid(port)
    kill_group(pid, "TERM")

    {output, dropped} =
      drain(port, System.monotonic_time(:millisecond) + @kill_grace_ms, output, dropped)

    kill_group(pid, "KILL")
    drain(port, System.monotonic_time(:millisecond) + 500, output, dropped)
  end

  defp drain(port, deadline, output, dropped) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {output, dropped}
    else
      receive do
        {^port, {:data, chunk}} ->
          {output, dropped} = append(output, dropped, chunk)
          drain(port, deadline, output, dropped)

        {^port, {:exit_status, _code}} ->
          {output, dropped}
      after
        remaining -> {output, dropped}
      end
    end
  end

  # `-pid` targets the process group (the normal case: the wrapper is its own
  # group leader under setsid). The bare pid is a fallback for the no-setsid
  # degradation above; both are attempted, failures ignored — one of the two
  # is expected to be a no-op. `pid` is an integer we parsed ourselves, so
  # nothing operator- or payload-controlled reaches this shell.
  defp kill_group(nil, _signal), do: :ok

  defp kill_group(pid, signal) when is_integer(pid) and pid > 1 do
    System.cmd(sh(), [
      "-c",
      "kill -#{signal} -#{pid} 2>/dev/null; kill -#{signal} #{pid} 2>/dev/null; exit 0"
    ])

    :ok
  rescue
    _ -> :ok
  end

  defp kill_group(_pid, _signal), do: :ok

  defp read_pid(pid_path) do
    with {:ok, contents} <- File.read(pid_path),
         {pid, _rest} <- Integer.parse(String.trim(contents)) do
      pid
    else
      _ -> nil
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # Keep the TAIL: a script that floods stdout still ends with the error that
  # explains why, and that is the part worth spending the agent's context on.
  defp append(output, dropped, chunk) do
    output = output <> chunk

    if byte_size(output) > @max_output_bytes do
      excess = byte_size(output) - @max_output_bytes
      {binary_part(output, excess, @max_output_bytes), dropped + excess}
    else
      {output, dropped}
    end
  end

  defp render_output(output, 0), do: output

  defp render_output(output, dropped),
    do: "[... truncated #{dropped} bytes ...]\n" <> output

  defp temp_paths do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "orca_setup_scripts")

    %{
      script: Path.join(dir, "#{id}.sh"),
      wrapper: Path.join(dir, "#{id}.wrapper.sh"),
      pid: Path.join(dir, "#{id}.pid")
    }
  end

  # Exactly the treatment a session (OrcaHub.Backend.Claude/Codex/Pi) or a
  # terminal (OrcaHub.TerminalRunner) spawned on this node gets — a setup
  # script running on a node whose sessions are scrubbed must not be the one
  # hole that hands out the pod's secrets.
  defp setup_env(project_id) do
    if OrcaHub.NodePolicy.scrub_session_env?() do
      OrcaHub.Env.strict_env([], OrcaHub.NodePolicy.extra_env_allowlist(project_id))
    else
      OrcaHub.Env.sanitized_env()
    end
  end

  defp sh, do: System.find_executable("sh") || "/bin/sh"
  defp setsid, do: System.find_executable("setsid")

  defp shq(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  # ------------------------------------------------------------------
  # Prompt composition + visibility
  # ------------------------------------------------------------------

  @doc """
  Prepend `result`'s `<setup_script>` block to `prompt`, or return `prompt`
  unchanged for a `nil` result (no script configured).

  Prepending — rather than appending or splicing — is what keeps this correct
  for the email path: the block lands ahead of everything, well OUTSIDE the
  `<untrusted_email>` region `OrcaHub.TriggerExecutor.build_prompt/2` wraps
  third-party content in. Setup output is operator-authored; an email body is
  not, and the two must never share a trust region.
  """
  def prepend(nil, prompt), do: prompt
  def prepend(%Result{} = result, prompt), do: block(result) <> "\n" <> prompt

  @doc """
  The `<setup_script>` block for `result` — status, exit code and duration on
  their own lines so success and failure are distinguishable at a glance,
  with the captured output nested in its own tags.
  """
  def block(%Result{} = result) do
    """
    <setup_script>
    This trigger ran an operator-configured setup script on this session's node before the
    instructions below. You did not run it; its combined stdout+stderr is provided as context.
    status: #{status_line(result)}
    duration: #{format_duration(result.duration_ms)}
    <setup_output>
    #{String.trim_trailing(result.output)}
    </setup_output>
    #{failure_advice(result)}</setup_script>
    """
  end

  defp status_line(%Result{error: error}) when is_binary(error),
    do: "FAILED — #{error}"

  defp status_line(%Result{timed_out: true} = result),
    do:
      "FAILED — timed out after #{format_duration(result.duration_ms)}; the script and its " <>
        "child processes were killed"

  defp status_line(%Result{exit_code: 0}), do: "success (exit code 0)"

  defp status_line(%Result{exit_code: code}), do: "FAILED — exit code #{code}"

  defp failure_advice(%Result{} = result) do
    if Result.failed?(result) do
      "NOTE: the setup for this run did NOT complete successfully. Do not assume the state it " <>
        "was meant to prepare is in place — check first, and say so in your output.\n"
    else
      ""
    end
  end

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1_000, 2)}s"

  @doc """
  Persist a `system`/`setup_script` event into the session feed so a human
  can see what the setup script did — same mechanism `memory_injected` uses.
  Fire-and-forget: a failure to persist must never fail the firing.
  """
  def persist_event(trigger, session_id, %Result{} = result) do
    OrcaHub.Sessions.persist_system_event(session_id, %{
      "type" => "system",
      "subtype" => "setup_script",
      "trigger_id" => Map.get(trigger, :id),
      "trigger_name" => Map.get(trigger, :name),
      # Operator-authored, so safe to echo back verbatim — and the whole
      # point of the event is being able to see WHAT ran, not just its output.
      "script" => Map.get(trigger, :setup_script),
      "exit_code" => result.exit_code,
      "timed_out" => result.timed_out,
      "duration_ms" => result.duration_ms,
      "truncated_bytes" => result.truncated_bytes,
      "failed" => Result.failed?(result),
      "error" => result.error,
      "output" => result.output
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "[setup_script] failed to persist setup_script event for session #{session_id}: " <>
          Exception.message(e)
      )

      :ok
  end

  defp log(trigger, %Result{} = result) do
    if Result.failed?(result) do
      Logger.warning(
        "[setup_script] trigger #{Map.get(trigger, :name)} (#{Map.get(trigger, :id)}) setup " <>
          "script #{status_line(result)} after #{format_duration(result.duration_ms)} — the " <>
          "firing continues with the failure surfaced in the prompt"
      )
    else
      Logger.info(
        "[setup_script] trigger #{Map.get(trigger, :name)} (#{Map.get(trigger, :id)}) setup " <>
          "script succeeded in #{format_duration(result.duration_ms)}"
      )
    end
  end
end
