defmodule OrcaHub.MemoryGit.Server do
  @moduledoc """
  Per-node singleton GenServer that serializes every `OrcaHub.MemoryGit` /
  `OrcaHub.MemorySync` operation.

  Many sessions on one node can go idle around the same time; concurrent
  git operations against the same working tree aren't safe (index/HEAD
  races), so every request funnels through this one process's mailbox —
  cheap to do since `MemoryGit.snapshot/3` is commit-if-dirty (a redundant
  run just costs one `git status`).

  `snapshot_session_async/1` is the entry point `OrcaHub.SessionRunner`
  calls on every clean idle transition. It is fire-and-forget by design: the
  real work runs inside an unsupervised `Task.Supervisor` child that then
  makes a (serializing) call into this GenServer, so a slow or failing git
  pass can never block or crash the idle transition that triggered it.
  No-ops entirely — no Task even started — when `MemoryGit.enabled?/0` is
  `false` (`config/test.exs` sets this, so `mix test`, which boots the full
  application against the shared dev DB, never touches a real node's
  `~/.claude`/`~/.codex`).
  """

  use GenServer
  require Logger

  alias OrcaHub.{MemoryGit, MemorySync}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fire-and-forget snapshot+sync pass tagged with `session`'s id/title.
  Always returns `:ok` immediately.

  `:task_supervisor` (default `OrcaHub.TaskSupervisor`) is injectable so
  tests can assert against an isolated supervisor instead of the shared
  global one (see `OrcaHub.MemoryGit.ServerTest`).
  """
  def snapshot_session_async(session, opts \\ []) do
    if MemoryGit.enabled?() do
      label = commit_label(session)
      supervisor = Keyword.get(opts, :task_supervisor, OrcaHub.TaskSupervisor)

      Task.Supervisor.start_child(supervisor, fn ->
        GenServer.call(__MODULE__, {:run_pass, label, []}, 120_000)
      end)
    end

    :ok
  end

  defp commit_label(%{id: id, title: title}) do
    if title in [nil, ""], do: "session #{id}", else: "session #{id} — #{title}"
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:run_pass, label, opts}, _from, state) do
    do_run_pass(label, opts)
    {:reply, :ok, state}
  rescue
    e ->
      Logger.warning(
        "MemoryGit.Server: snapshot/sync pass raised: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:reply, :ok, state}
  end

  @doc """
  The actual (deterministic, opts-injectable) snapshot+sync pass — exposed
  as a plain function so tests can exercise it directly without going
  through the GenServer or the `enabled?/0` gate.
  """
  def run_pass(label, opts \\ []) do
    do_run_pass(label, opts)
  end

  defp do_run_pass(label, opts) do
    claude_dir = MemoryGit.claude_projects_dir(opts)
    codex_dir = MemoryGit.codex_memories_dir(opts)

    MemoryGit.ensure_repo(
      claude_dir,
      Keyword.merge(opts, whitelist_memory?: true, repo_name: MemoryGit.repo_name(:claude, opts))
    )

    MemoryGit.ensure_repo(
      codex_dir,
      Keyword.merge(opts, repo_name: MemoryGit.repo_name(:codex, opts))
    )

    MemoryGit.snapshot(claude_dir, "snapshot: #{label}", opts)
    MemoryGit.snapshot(codex_dir, "snapshot: #{label}", opts)

    %{codex_changed: codex_changed?} = MemorySync.sync(opts)

    if codex_changed? do
      MemoryGit.snapshot(codex_dir, "sync: mechanical cross-backend mirror", opts)
    end

    :ok
  end
end
