defmodule OrcaHub.OSProcess do
  @moduledoc """
  Signal OS processes and process groups without exec'ing an external `kill`.

  ORCAHUB3-150: `System.cmd("kill", ["-TERM", "-1997685"])` on gb10 (Ubuntu
  procps 2:4.0.4-4ubuntu3.3) became `kill(-1, SIGTERM)`. Its getopt reads
  `-1997685` as option `-1`, so every process the user owned got SIGTERM,
  orca-hub included. A pgid starting with 2-9 became `kill(-2..-9)` and did
  nothing. util-linux kill (mini) refused the group outright, and the k3s
  images ship no `kill` binary at all. Four hosts, four behaviours.

  So every signal here goes through the POSIX shell's BUILTIN `kill`, which
  is a direct `kill(2)` on dash and bash alike: `-s` names the signal, `--`
  ends option parsing, and the pid arrives as a positional parameter, never
  interpolated into the script. `command kill` skips any shell function of
  that name, and a builtin always wins over a `kill` on `PATH`.

  Guards, all refusals rather than best efforts:

    * pids and pgids must be integers > 1. `0` is the caller's own group,
      `1` is init (or the BEAM itself in a k3s pod), negatives are other
      groups, and `-1` is everything.
    * never the BEAM's own pid or process group.
    * signals come from `@signals` only.

  Results are `:ok | {:error, reason}` from the builtin's exit status, so a
  caller can log a kill that did not land instead of assuming it did.
  """

  @signals ~w(TERM KILL INT HUP 0)

  @type signal :: String.t()
  @type reason ::
          {:invalid_pid, term()}
          | {:invalid_signal, term()}
          | :own_process
          | {:kill_failed, non_neg_integer(), String.t()}
          | {:shell_failed, String.t()}

  @doc "The signals `signal_group/2` and `signal_pids/2` accept."
  def signals, do: @signals

  @doc """
  Sends `sig` to every process in group `pgid` (`kill -s SIG -- -<pgid>`).
  `{:error, {:kill_failed, _, _}}` covers a group that no longer exists.
  """
  @spec signal_group(term(), term()) :: :ok | {:error, reason()}
  def signal_group(pgid, sig) do
    with :ok <- check_signal(sig),
         :ok <- check_pid(pgid),
         :ok <- check_not_own(pgid, own_pgid()) do
      run(~s(command kill -s "$1" -- "-$2"), [sig, Integer.to_string(pgid)])
    end
  end

  @doc """
  Sends `sig` to each pid in `pids` in one builtin call. The whole call is
  refused if any pid fails the guards. A pid that no longer exists does not
  stop the rest from being signalled, but the result differs by shell: dash
  (debian, gb10, k3s) returns an error if ANY pid failed, bash (mini) only if
  ALL did.
  """
  @spec signal_pids([term()], term()) :: :ok | {:error, reason()}
  def signal_pids([], sig), do: check_signal(sig)

  def signal_pids(pids, sig) when is_list(pids) do
    own = System.pid() |> String.to_integer()

    with :ok <- check_signal(sig),
         :ok <- Enum.reduce_while(pids, :ok, &check_each(&1, &2, own)) do
      run(~s(sig=$1; shift; command kill -s "$sig" -- "$@"), [
        sig | Enum.map(pids, &Integer.to_string/1)
      ])
    end
  end

  def signal_pids(pids, _sig), do: {:error, {:invalid_pid, pids}}

  @doc """
  Whether `pid` is a live process. A zombie is not: it has exited and only
  waits to be reaped, which in a k3s pod (where the BEAM is PID 1 and never
  reaps orphans) can be forever.
  """
  @spec alive?(term()) :: boolean()
  def alive?(pid) when is_integer(pid) and pid > 0 do
    case stat(Integer.to_string(pid)) do
      {:ok, %{state: state}} -> state not in ["Z", "X"]
      :error -> false
    end
  end

  def alive?(_pid), do: false

  @doc "Whether any live (non-zombie) process is still in group `pgid`."
  @spec group_alive?(term()) :: boolean()
  def group_alive?(pgid) when is_integer(pgid) and pgid > 1 do
    case File.ls("/proc") do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          match?({_, ""}, Integer.parse(entry)) and
            match?({:ok, %{pgrp: ^pgid, state: state}} when state not in ["Z", "X"], stat(entry))
        end)

      {:error, _} ->
        false
    end
  end

  def group_alive?(_pgid), do: false

  # ── Internals ───────────────────────────────────────────────────────

  defp run(script, args) do
    case System.cmd(sh(), ["-c", script, "sh" | args], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:kill_failed, status, String.trim(out)}}
    end
  rescue
    e -> {:error, {:shell_failed, Exception.message(e)}}
  end

  defp check_signal(sig) when sig in @signals, do: :ok
  defp check_signal(sig), do: {:error, {:invalid_signal, sig}}

  defp check_pid(pid) when is_integer(pid) and pid > 1, do: :ok
  defp check_pid(pid), do: {:error, {:invalid_pid, pid}}

  defp check_not_own(pid, pid), do: {:error, :own_process}
  defp check_not_own(_pid, _own), do: :ok

  defp check_each(pid, :ok, own) do
    with :ok <- check_pid(pid), :ok <- check_not_own(pid, own) do
      {:cont, :ok}
    else
      error -> {:halt, error}
    end
  end

  # `pgrp` of the BEAM itself. `nil` (no procfs) disables only this guard.
  defp own_pgid do
    case stat("self") do
      {:ok, %{pgrp: pgrp}} -> pgrp
      :error -> nil
    end
  end

  # `/proc/<pid>/stat` is `pid (comm) state ppid pgrp ...`. `comm` may hold
  # spaces and parens, so split at the LAST `)`.
  defp stat(entry) do
    with {:ok, contents} <- File.read("/proc/#{entry}/stat"),
         {pos, 1} <- contents |> :binary.matches(")") |> List.last(),
         rest = binary_part(contents, pos + 1, byte_size(contents) - pos - 1),
         [state, _ppid, pgrp | _] <- String.split(rest),
         {pgrp, ""} <- Integer.parse(pgrp) do
      {:ok, %{state: state, pgrp: pgrp}}
    else
      _ -> :error
    end
  end

  defp sh do
    if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
  end
end
