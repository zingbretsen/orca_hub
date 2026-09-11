defmodule OrcaHub.MemoryReview do
  @moduledoc """
  Automated memory REVIEW passes — a nightly consolidation pass and a
  weekly verification pass — each a hub-scheduled `Trigger` that spawns a
  session driven by a prompt in this module, using the ordinary memory
  tools (`OrcaHub.MCP.Tools.Memory`).

  Zach's invariant: passes PROPOSE, humans DECIDE. A pass may only:

    (a) merge clear near-duplicates via `merge_memories` with
        `created_by: "consolidation"` — reversible: the source memories
        become superseded with lineage, and the merged memory itself
        re-enters the review queue as pending, since it was created with
        that attribution;
    (b) flag a memory back into the review queue with `flag_memory` and a
        reason;
    (c) batch-verify memories it independently confirmed are still true,
        via `verify_memories`.

  A pass must NEVER retire, hard-delete, or rewrite the text of an
  existing memory (`retire_memory` and `update_memory`/`remember` on an
  existing memory's own id are off-limits — both prompts say so
  explicitly). Every run ends by saving a review artifact
  (`OrcaHub.MCP.Tools.Artifacts.save_artifact`) so a human has something
  concrete to act on. Both spawned sessions are created with
  `memory_extract: false` (via each trigger's own `Trigger.memory_extract`
  override) — an automated review pass must never itself be
  memory-extracted, the same reasoning `OrcaHub.MemoryExtraction`'s own
  extraction children apply to themselves.

  `consolidate_prompt/1` and `verify_prompt/1` are pure functions of `opts`
  (project scope + action caps) — no DB/HTTP access — so the prompt text
  itself is directly testable and versioned in git independent of the
  trigger-scheduling machinery below.

  ## Backend/model

  `OrcaHub.Triggers.Trigger` carries no `backend`/`model` fields (unlike
  `OrcaHub.Sessions.Session`) — a trigger-spawned session always falls back
  to the owning project's/node's configured default backend/model
  (`OrcaHub.NodePolicy`, applied in `Sessions.create_session/1`). There is
  currently no way to pin these two triggers to `claude`/`claude-sonnet-5`
  specifically short of setting that as the orca_hub project's or node's
  own default — `ensure_triggers!/0` does not attempt to change either.

  ## Boot wiring

  `ensure_triggers!/0` is release-safe (no Mix dependency) and idempotent
  — upserts by trigger `name`, updating prompt/cron if either drifted from
  what this module currently generates, and never duplicating. It's called
  from `OrcaHub.TriggerLoader` right before `OrcaHub.Scheduler.sync_triggers/0`
  so a fresh/updated trigger is scheduled the same boot it's created —
  hub-only, like `TriggerLoader` itself (agent nodes have no DB to write
  a trigger row into).
  """

  require Logger

  alias OrcaHub.HubRPC

  @project_directory "/home/zach/orca_hub"

  @consolidate_name "memory-consolidate-nightly"
  @consolidate_cron "0 3 * * *"
  @consolidate_default_cap 40

  @verify_name "memory-verify-weekly"
  @verify_cron "0 4 * * 0"
  @verify_default_cap 60

  @doc """
  Idempotently creates or updates the two scheduled review-pass triggers
  (upsert by `name`) in the orca_hub project itself
  (directory #{@project_directory}). A no-op (logged once) if that project
  isn't registered on this hub yet, rather than raising and blocking boot.

  `opts[:directory]` overrides which project's directory to target —
  test-only seam, production callers always use the zero-arg form.
  """
  def ensure_triggers!(opts \\ []) do
    directory = Keyword.get(opts, :directory, @project_directory)

    case HubRPC.get_project_by_directory(directory) do
      nil ->
        Logger.warning(
          "MemoryReview.ensure_triggers!: no project registered for #{directory}, skipping"
        )

        :ok

      project ->
        upsert_trigger(project, @consolidate_name, @consolidate_cron, consolidate_prompt())
        upsert_trigger(project, @verify_name, @verify_cron, verify_prompt())
        :ok
    end
  end

  defp upsert_trigger(project, name, cron, prompt) do
    attrs = %{
      name: name,
      prompt: prompt,
      type: "scheduled",
      cron_expression: cron,
      project_id: project.id,
      reuse_session: false,
      archive_on_complete: true,
      # An automated review pass must never itself be memory-extracted.
      memory_extract: false,
      enabled: true
    }

    case find_trigger(project.id, name) do
      nil ->
        case HubRPC.create_trigger(attrs) do
          {:ok, _trigger} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "MemoryReview.ensure_triggers!: failed to create #{name}: " <>
                inspect(changeset.errors)
            )
        end

      trigger ->
        case HubRPC.update_trigger(trigger, attrs) do
          {:ok, _trigger} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "MemoryReview.ensure_triggers!: failed to update #{name}: " <>
                inspect(changeset.errors)
            )
        end
    end
  end

  defp find_trigger(project_id, name) do
    project_id
    |> HubRPC.list_triggers_for_project()
    |> Enum.find(&(&1.name == name))
  end

  # -------------------------------------------------------------------
  # Prompts (pure — no DB/HTTP access, testable in isolation)
  # -------------------------------------------------------------------

  @doc """
  The nightly consolidation pass's prompt. `opts[:cap]` bounds the total
  number of merge_memories/flag_memory/verify_memories calls in one run
  (default #{@consolidate_default_cap}); `opts[:app]` names the app whose
  memories are in scope (default `"orcahub"`).
  """
  def consolidate_prompt(opts \\ %{}) do
    cap = Map.get(opts, :cap, @consolidate_default_cap)
    app = Map.get(opts, :app, "orcahub")

    """
    # Nightly Memory Consolidation Pass (automated)

    You are an automated memory-consolidation pass for the "#{app}" app's memory \
    store. You PROPOSE changes; a human DECIDES. Follow every rule below exactly \
    — do not improvise around them, and do not use the question/AskUserQuestion \
    tool at any point — no user is watching this session; decide yourself using \
    the rules below and record your reasoning in the review artifact instead of \
    asking. You must end this turn when you are done (archive_on_complete relies \
    on your turn actually ending) — do not leave work outstanding.

    ## The only writes you may make

    - `Tools.merge_memories(...)` with `"created_by" => "consolidation"`, to \
      combine two memories that are genuinely the same claim. Sources become \
      superseded with lineage; the merged memory itself re-enters the review \
      queue as pending (that's what created_by: "consolidation" does).
    - `Tools.flag_memory(...)`, to flag one existing memory back into the human \
      review queue with a reason. Never retires, never rewrites its text.
    - `Tools.verify_memories(...)`, to batch-confirm memories you independently \
      confirmed are still true (only after actually checking — never by \
      assumption alone).

    You may NEVER call `retire_memory`. You may NEVER call `update_memory` or \
    `remember` targeting an EXISTING memory's own id — i.e. never rewrite an \
    existing memory's text, ever, for any reason. If a memory needs a text \
    correction, flag it instead and let a human make the edit.

    ## Scope and budget

    Hard budget: at most #{cap} total actions this run (each merge_memories, \
    flag_memory, or verify_memories CALL counts once, regardless of how many ids \
    it covers). Stop proposing new actions once you hit the cap and say so in the \
    artifact — do not silently keep going past it, and do not pad out to the cap \
    if there is nothing left worth doing.

    Build your candidate pool by calling `Tools.list_memories(%{"all_projects" => \
    true, "sort" => "updated_at"})` and taking memories updated in the last 7 \
    days, plus each candidate's nearest neighbours: for every candidate, call \
    `Tools.recall(%{"query" => <candidate's hook or text>, "include_other_projects" \
    => true, "limit" => 5})`. If the memory service exposes a dedicated \
    duplicates endpoint, prefer it — check with `Tools.search("duplicate")` \
    first. You are not expected to review every memory that exists, only this \
    window.

    ## Decision rules

    1. Merge ONLY when two memories state the SAME claim — same subject, no \
       conflicting detail. When you merge: keep the MORE SPECIFIC of the two \
       texts (don't average them into something vaguer), take the UNION of their \
       `tags` and `source` references, and pass `"created_by" => "consolidation"`.
    2. When two memories CONTRADICT each other, do NOT merge them — flag BOTH \
       with `flag_memory`, each note naming the OTHER memory's id and describing \
       the conflict in one sentence.
    3. Flag importance inflation: a memory with `importance: 5` that is not a \
       standing rule Zach himself explicitly stated (a preference/decision/fact \
       he actually asserted — not something the assistant merely inferred or \
       asserted on its own) should be flagged with a note proposing a lower \
       value and why.
    4. Never touch a PINNED memory except to flag it — never merge a pinned \
       memory into anything, not even as a source.
    5. When genuinely unsure whether two memories are the same claim, do NOT \
       merge — list the pair in the artifact's "skipped but suspicious" section \
       with your reasoning instead, for a human to decide later.

    ## When you're done

    Save an artifact (`Tools.save_artifact`, `"kind" => "markdown"`) named \
    `memory-review-consolidate-<today's date, YYYY-MM-DD>` listing, in this \
    order:

    1. **Merges** — for each: the source ids merged in, the resulting memory \
       id, and a one-line reason.
    2. **Flags** — for each: the memory id, and the note you attached.
    3. **Skipped but suspicious** — pairs you considered but chose not to act \
       on, and why.

    Then end your final message with a 3-line summary: how many candidates you \
    reviewed, how many merges/flags/verifies you made, and whether the action \
    cap was reached.
    """
    |> String.trim()
  end

  @doc """
  The weekly verification pass's prompt. `opts[:cap]` bounds how many
  memories are pulled into the working set in one run (default
  #{@verify_default_cap}); `opts[:project_slug]` scopes it to a specific
  project's own memories, defaulting to the orca_hub project (this pass
  only checks orca_hub's own project-scoped memories plus global/shared
  ones, never another project's — see moduledoc).
  """
  def verify_prompt(opts \\ %{}) do
    cap = Map.get(opts, :cap, @verify_default_cap)
    directory = Map.get(opts, :directory, @project_directory)

    """
    # Weekly Memory Verification Pass (automated)

    You are an automated memory-verification pass. You PROPOSE changes; a human \
    DECIDES. Follow every rule below exactly — do not improvise around them, and \
    do not use the question/AskUserQuestion tool at any point — no user is \
    watching this session; decide yourself using the rules below and record your \
    reasoning in the review artifact instead of asking. You must end this turn \
    when you are done (archive_on_complete relies on your turn actually ending) \
    — do not leave work outstanding.

    This pass only checks memories scoped to THIS project (orca_hub) plus \
    global/shared ones — you are running from #{directory} and cannot verify a \
    claim about a different project's own codebase from here, so leave other \
    projects' project-scoped memories alone entirely (do not call list_memories \
    with all_projects: true for this pass).

    ## The only writes you may make

    - `Tools.verify_memories(...)`, to batch-confirm memories you actually \
      checked and found still accurate — never by assumption.
    - `Tools.flag_memory(...)`, to flag a memory that's stale or contradicted, \
      with a specific note (what changed, and the evidence).

    You may NEVER call `retire_memory`, and you may NEVER call `update_memory` \
    or `remember` targeting an EXISTING memory's own id — never rewrite an \
    existing memory's text, ever, for any reason, even when you're sure what the \
    correct text should be. Flag it instead and let a human make the edit.

    ## Building the working set

    Call `Tools.list_memories(%{"status" => "active", "sort" => \
    "last_verified_at", "per_page" => #{cap}})` — oldest/never-verified first. \
    (If the service doesn't support sorting by last_verified_at yet, it falls \
    back to updated_at ordering; if the returned list doesn't actually look \
    sorted or filtered by verification age, sort it yourself client-side using \
    each memory's own `last_verified_at`, treating a missing/null value as the \
    oldest.) Then drop any memory where `created_by == "extraction"` AND \
    `review_status == "pending"` — those are still awaiting their first human \
    review and aren't this pass's job. Cap the working set at #{cap} memories.

    ## Checking each memory

    For each memory in the working set, check its CONCRETE claims against \
    reality using whatever tool fits the claim:

    - A file path, module, function name, or flag it references — `grep` for it \
      under #{directory}.
    - A commit it cites — `git cat-file -e <sha>` in #{directory} (exit 0 means \
      the commit exists).
    - A URL it cites — `curl -sI <url>` where that's safe to do (never for a URL \
      that looks internal/credentialed).

    Classify each memory:

    - **Confirmed** — the claim still checks out. Collect its id; call \
      `Tools.verify_memories(...)` ONCE at the end with every confirmed id \
      together (not one call per memory).
    - **Stale or contradicted** — something concrete has changed. Call \
      `Tools.flag_memory(...)` with a specific note: what changed, and the \
      evidence (the grep hit, the missing commit, the failed request).
    - **Unverifiable from here** — the claim isn't something a grep/git/curl \
      check can settle (e.g. a subjective preference, or something outside this \
      project's own directory). Leave it untouched and list it separately in \
      the artifact — do not verify or flag a claim you didn't actually check.

    Never rewrite a memory's text under any classification.

    ## When you're done

    Save an artifact (`Tools.save_artifact`, `"kind" => "markdown"`) named \
    `memory-review-verify-<today's date, YYYY-MM-DD>` listing, in this order:

    1. **Confirmed** — memory ids batch-verified.
    2. **Flagged** — for each: memory id, and the note you attached.
    3. **Unverifiable from here** — memory ids left untouched, and why.

    Then end your final message with a 3-line summary: how many memories you \
    reviewed, how many were confirmed/flagged/left unverifiable, and whether the \
    working-set cap was reached.
    """
    |> String.trim()
  end
end
