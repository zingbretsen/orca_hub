defmodule OrcaHub.Jobs.Paths do
  @moduledoc """
  Durable per-node storage for a job's command script, wrapper script, log,
  exit-code sentinel, and pidfile.

  ## Why not /tmp

  The `orca-hub` systemd unit runs `PrivateTmp=yes` — a restart gives the
  process a brand-new, empty `/tmp`. Anything written there for a
  long-running detached job would look "gone" to a resumed watcher even
  though the OS process itself is still running untouched. Anything written
  under the release/build directory is just as bad for a different reason:
  `~/homelab/scripts/deploy-orca-hub.sh` extracts EVERY deploy into a new
  `<sha>/` directory and flips a symlink — that directory isn't guaranteed
  to still be there (or still be the one this job started under) by the
  time a watcher tries to read from it.

  ## Chosen path: `$HOME/.orca_hub/jobs` (override: `ORCA_JOBS_DIR`)

  This directory is independent of both of the above and, on a plain host
  (the local systemd instance, `mini`), survives systemd restarts, deploys,
  and reboots — it's just an ordinary directory under the OS user's home.

  Caveat, stated plainly rather than glossed over: on a k3s pod WITHOUT a
  persistent volume mounted at (or above) this path, a full pod recreation
  (not just an in-container process restart) still wipes it, same as it
  would wipe anything else outside a `PersistentVolumeClaim`/`hostPath`
  mount — see `~/homelab/k3s/apps/orca-hub.yaml`'s `volumeMounts` for what
  IS currently persisted. `ORCA_JOBS_DIR` exists specifically so an operator
  can point a given node's jobs directory at an already-mounted persistent
  path (e.g. the `shared-data` hostPath) if cross-pod-recreation durability
  is needed there too — that wiring is left to the node's own deployment
  manifest, not hardcoded here.
  """

  @doc "This node's jobs directory — `$HOME/.orca_hub/jobs`, or `ORCA_JOBS_DIR` if set."
  def jobs_dir do
    System.get_env("ORCA_JOBS_DIR") || Path.expand("~/.orca_hub/jobs")
  end

  @doc "Ensure the jobs directory exists, returning its path."
  def ensure_dir! do
    dir = jobs_dir()
    File.mkdir_p!(dir)
    dir
  end

  def cmd_script_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.cmd.sh")
  def wrapper_script_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.wrap.sh")
  def log_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.log")
  def sentinel_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.exit")
  def pid_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.pid")

  def verify_cmd_script_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.verify.cmd.sh")
  def verify_wrapper_script_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.verify.wrap.sh")
  def verify_log_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.verify.log")
  def verify_sentinel_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.verify.exit")
  def verify_pid_path(job_id), do: Path.join(jobs_dir(), "#{job_id}.verify.pid")

  @doc """
  The sentinel/pid path RELEVANT to a job's current status — the main phase's
  paths while `running`, the verify phase's while `verifying`. `pid`/`pgid`
  columns are reused across phases (see `OrcaHub.Jobs.Job` moduledoc), but
  the on-disk sentinel/log paths are phase-specific so the main command's
  exit code is never clobbered by the verify command reusing the same file.
  """
  def relevant_sentinel_path(%{id: id, status: "verifying"}), do: verify_sentinel_path(id)
  def relevant_sentinel_path(%{id: id}), do: sentinel_path(id)

  def relevant_log_path(%{id: id, status: "verifying"}), do: verify_log_path(id)
  def relevant_log_path(%{id: id}), do: log_path(id)

  @doc """
  Single-quote a value for safe interpolation into a `sh -c` argument (the
  only untrusted piece is `directory`, a session's working directory — job
  ids are OrcaHub-generated UUIDs and every other path lives under our own
  `jobs_dir/0`, but every value passed through here regardless).
  """
  def shq(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end
end
