defmodule OrcaHub.Projects.MoveSideEffects do
  @moduledoc """
  Extension point for the OUT-OF-DATABASE consequences of moving a project's
  directory (`OrcaHub.Projects.DirectoryMove`).

  Everything OrcaHub owns in Postgres — the `directory` column on `projects`,
  `sessions`, `terminals` and `jobs` — is rewritten by `DirectoryMove` itself,
  inside one transaction. This module is for the state that lives OUTSIDE that
  transaction and outside OrcaHub entirely, keyed by the project's path:

    * **Claude's per-directory history/memory dir** — `~/.claude/projects/<slug>`,
      where `<slug>` is the working directory with `/` (and friends) replaced,
      see `OrcaHub.AgentMemory.memory_dir/2` and `OrcaHub.ClaudeImport`. After a
      move the old slug directory is orphaned and the new path starts with no
      history; it needs renaming on the project's own node.
    * **The memory service's `project_slug`** — memories are namespaced by a
      slug derived from the project directory (`OrcaHub.MemoryClient`), so a
      moved project stops recalling its own memories until they are migrated.

  **This is a deliberate NO-OP today**: it returns `{:ok, []}` without touching
  anything. A follow-up worker fills in the two migrations above. The contract
  is fixed so that `DirectoryMove` can already call it:

    * `node` — the node the filesystem move ran on (`Project.node`, resolved via
      `OrcaHub.Cluster.project_node_for/1`). Any filesystem work belongs THERE,
      via `OrcaHub.Cluster.rpc/5` — never on whichever node happens to be
      running this code.
    * `from` / `to` — the normalized absolute source and destination.
    * `opts` — the same keyword list `DirectoryMove.move/3` was called with
      (notably `force: true`).

  Returns `{:ok, notes}` where `notes` is a list of human-readable strings
  describing what was done; they are merged into the move result's
  `:side_effects`. `DirectoryMove` calls this BEST-EFFORT after an otherwise
  successful move: an `{:error, _}`, a raise, or an exit here is captured into
  the result's `:warnings` and never fails the move — the directory has already
  moved and the DB has already been rewritten by that point, so there is
  nothing left to roll back.
  """

  @spec apply(node(), String.t(), String.t(), keyword()) :: {:ok, [String.t()]}
  def apply(_node, _from, _to, _opts \\ []) do
    {:ok, []}
  end
end
