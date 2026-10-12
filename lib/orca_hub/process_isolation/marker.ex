defmodule OrcaHub.ProcessIsolation.Marker do
  @moduledoc """
  The no-cgroup half of `OrcaHub.ProcessIsolation`: every agent CLI spawn
  carries `ORCA_AGENT_SPAWN_ID=<spawn id>` in its environment, every
  descendant inherits it, and teardown kills exactly the processes whose
  `/proc/<pid>/environ` holds that entry.

  Why an env marker rather than the CLI's process group or a ppid walk:
  the port's child is already its own session leader (erl_child_setup
  setsid()s it), Claude's Bash tool setsid()s every shell it starts, and a
  backgrounded build is reparented to init the moment its shell exits. A
  process group misses the first two, a ppid walk misses the last. The
  inherited environment survives all three.

  Limits, documented rather than hidden: a descendant started with a
  scrubbed environment (`env -i`, some sandboxes), one that runs as another
  user (setuid, sudo), and a pid reused within one scan are out of reach.
  The cgroup path has none of these gaps.

  Matching is on the exact spawn id, which carries random bytes, so one
  BEAM never kills another instance's agents on the same host (a `bin/test`
  run beside the live service, say).
  """

  @var "ORCA_AGENT_SPAWN_ID"

  @doc "The environment variable carrying the spawn id."
  def var, do: @var

  @doc "The `{name, value}` Port env entry for `id`."
  @spec env_entry(String.t()) :: {charlist(), charlist()}
  def env_entry(id), do: {String.to_charlist(@var), String.to_charlist(id)}

  @doc """
  Pids of every live process whose initial environment holds this spawn's
  marker. Unreadable entries (other users' processes, zombies, processes
  that exited mid-scan) are skipped.
  """
  @spec find(String.t(), String.t()) :: [pos_integer()]
  def find(id, proc_root \\ "/proc") do
    needle = <<0>> <> @var <> "=" <> id <> <<0>>

    case File.ls(proc_root) do
      {:ok, entries} ->
        for entry <- entries,
            {pid, ""} <- [Integer.parse(entry)],
            {:ok, environ} <- [File.read(Path.join([proc_root, entry, "environ"]))],
            :binary.match(<<0>> <> environ, needle) != :nomatch,
            do: pid

      {:error, _} ->
        []
    end
  end

  @doc "Sends `signal` (`\"KILL\"`, `\"TERM\"`) to every pid, in one `kill`."
  @spec signal([pos_integer()], String.t()) :: :ok
  def signal([], _signal), do: :ok

  def signal(pids, signal) do
    System.cmd("kill", ["-#{signal}" | Enum.map(pids, &Integer.to_string/1)],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end
end
