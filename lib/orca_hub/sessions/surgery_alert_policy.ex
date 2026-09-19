defmodule OrcaHub.Sessions.SurgeryAlertPolicy do
  @moduledoc """
  Suppression policy for file-surgery-driven churn ALERTS (ORCAHUB3-66).

  `OrcaHub.Sessions.FileSurgery` keeps detecting exactly what it detected
  before; this module decides whether a detection is worth waking an
  orchestrator for. **The matcher's job is to be accurate about what was
  written; the policy layer decides whether that is worth alerting about.**

  That split is load-bearing, not tidiness. Suppressing noise by making the
  matcher decline to resolve a path it COULD resolve buys the right outcome
  today and arms a flood for whoever next improves the matcher — a latent
  regression with a delayed fuse. Noise gets suppressed HERE, where the
  reason is explicit and can be re-measured.

  We suppress the ALERT, not the DETECTION. Note the gap that leaves, though:
  a suppressed detection currently leaves no durable trace anywhere —
  `ChurnSampler.run_sweep/1` calls `Churn.assess/3`, which never computes
  file surgery, so `churn_samples` has never carried one, and the only record
  of an alert has always been the DELIVERED message in the orchestrator's
  feed. `decide/2` returns WHICH clause suppressed precisely so that a
  follow-up (migration + sampler change, tracked separately) can persist the
  reason without re-deriving it.

  ## The rule: U1b = D6 ∨ (D1 ∧ D2b)

  Suppress when EITHER:

    - **D6** — the alert carries no corroborating evidence at all:
      `ChurnDetail`'s `top_edited_files` AND `top_repeated_signatures` are
      both empty, so the file-surgery sentence is the whole alert; or
    - **D1 ∧ D2b** — the written path is not tracked by git AND the flagged
      command verifies its own write in the same command (reads it back, or
      executes what it just wrote — `evidence.verified_in_command`).

  This is MEASURED, not reasoned: `churn_alert_precision.md` (repo root)
  scores it against all 229 file-surgery alerts ever delivered in production
  plus a hand-labelled sample of 39. U1b suppresses 72/229 (31.4%), loses
  **0 of 3** hand-labelled true positives, kills all 12 deploy-runner
  firings, and preserves the `nohup`/`until`-loop true positive.

  **Do not "improve" this rule without re-running that measurement.** Every
  discriminator in the table loses at least one hand-labelled true positive
  when applied ALONE. In particular:

    - D1 alone suppresses 44% and loses 2/3 — including the one case
      ORCAHUB3-66 must keep, because the wedged-poll-loop worker also wrote
      outside git (a scratch harness under `tmp/voice2c/`);
    - D4 (same-path repeat count) suppresses 81% and destroys 3/3 while
      looking like a near-total cleanup in aggregate. `evidence.same_path_matches`
      is carried for mining only and is **never** a gate here;
    - D3 (require the write to be paired with a failed editor call)
      suppresses 100% — it is an off switch, not a discriminator. Pairing was
      never once true in production across 229 alerts, so it is being retired
      from `FileSurgery` rather than kept as a dead field. The pairing CONCEPT
      graduated into `OrcaHub.Sessions.EditFailure` (ORCAHUB3-63 §1) instead:
      "this worker cannot land an edit" is a signal in its own right, and in
      this corpus it is DISJOINT from "this worker writes files from the
      shell" (failed editor calls: 0 in 223 of 229 alert windows). The two
      cannot be traded off against each other.

  ## Unknown never suppresses

  `tracked_in_git: nil` means UNKNOWN — the runner node was unreachable, the
  directory is gone, git could not be run. Only an explicit `false` satisfies
  D1. Everything here fails toward ALERTING: a missing `verified_in_command`
  field, an unknown git state and a nil `ChurnDetail` all leave the alert
  standing rather than silently dropping it.
  """

  alias OrcaHub.Cluster

  @doc """
  The full decision, WITH the reason: `:alert` or `{:suppress, reason}`.

  Pure over explicit inputs — no DB, no git, no node — so the truth table is
  directly testable:

      decide(evidence, %{tracked_in_git: true | false | nil,
                         has_corroborating_detail: boolean})

  Reasons:

    - `:no_corroborating_detail` — D6;
    - `:untracked_and_verified` — D1 ∧ D2b;
    - `:no_evidence` — there was no file-surgery detection to begin with.

  Both suppressing clauses can hold at once (12/12 deploy-runner alerts in
  the measured corpus satisfy D1 ∧ D2b, and 11 of those 12 also satisfy D6).
  D6 is reported in that case, since it is the cheaper and stricter claim —
  "this alert had no content besides the shell write" — and it is the clause
  that needs no git check to justify. Callers that need both should evaluate
  the two predicates themselves rather than reading precedence into this.
  """
  def decide(evidence, context)

  def decide(nil, _context), do: {:suppress, :no_evidence}

  def decide(evidence, context) when is_map(evidence) and is_map(context) do
    cond do
      d6?(context) -> {:suppress, :no_corroborating_detail}
      d1?(context) and d2b?(evidence) -> {:suppress, :untracked_and_verified}
      true -> :alert
    end
  end

  @doc """
  The pinned predicate: `true` means "deliver this file-surgery alert".

  `decide/2` without the reason, for the call sites that only need the gate.
  """
  def alertable?(evidence, context), do: decide(evidence, context) == :alert

  # D6 — no corroborating detail at all; the surgery sentence IS the alert.
  defp d6?(context), do: Map.get(context, :has_corroborating_detail, true) == false

  # D1 — path is NOT tracked by git. `nil` (unknown) must not suppress.
  defp d1?(context), do: Map.get(context, :tracked_in_git, nil) == false

  # D2b — the flagged command reads back or executes what it just wrote.
  # Defaults to false: a detector that has not (yet) computed this field
  # leaves the alert standing.
  defp d2b?(evidence), do: Map.get(evidence, :verified_in_command, false) == true

  @doc """
  Applies `decide/2` for a live session: resolves D1 with a real git check on
  the session's OWN runner node and D6 from an already-fetched `ChurnDetail`
  map. Returns `:alert` or `{:suppress, reason}`.

  `churn_detail` is threaded in rather than fetched here so a tick pays for at
  most one `ChurnDetail.fetch/1` per session (the alert message needs the same
  map). `nil` is accepted and read as "no corroborating detail".

  The git check is skipped entirely when D6 already decides the outcome —
  `D6 ∨ (D1 ∧ D2b)` is true regardless of D1 once D6 holds, so shelling out
  would only cost a `git ls-files` for an answer that cannot change.
  """
  def decide_for_session(session, evidence, churn_detail)

  def decide_for_session(_session, nil, _churn_detail), do: {:suppress, :no_evidence}

  def decide_for_session(session, evidence, churn_detail) do
    has_detail = corroborating_detail?(churn_detail)

    tracked = if has_detail, do: git_tracked?(session, Map.get(evidence, :path)), else: nil

    decide(evidence, %{tracked_in_git: tracked, has_corroborating_detail: has_detail})
  end

  @doc """
  `decide_for_session/3` without the reason.
  """
  def alertable_for_session?(session, evidence, churn_detail),
    do: decide_for_session(session, evidence, churn_detail) == :alert

  @doc """
  D6's input: does this `ChurnDetail` map carry anything BESIDES the
  file-surgery sentence?

  Only `top_edited_files` and `top_repeated_signatures` count, exactly as
  measured — `failing_tests` is not part of D6 (§D's operational definition).
  A `nil` detail carries nothing, so it is `false`.
  """
  def corroborating_detail?(nil), do: false

  def corroborating_detail?(%{} = detail) do
    Map.get(detail, :top_edited_files, []) != [] or
      Map.get(detail, :top_repeated_signatures, []) != []
  end

  def corroborating_detail?(_), do: false

  @doc """
  Is `path` tracked by git, as seen from `session`'s working directory?

  Returns `true`, `false`, or `nil` for UNKNOWN. Unknown is a real answer, not
  an error to paper over: the runner node may be unreachable, the directory
  may be gone, git may not be runnable. Callers must treat `nil` as
  "do not suppress".

  Runs on the session's OWN runner node via `Cluster.rpc/4` and NEVER
  re-routes to another node — an unreachable node yields `nil`, not a local
  fallback (standing project invariant). A session with no `runner_node`
  assigned at all is a local session, matching how
  `AlertEvaluator.fetch_commit_info_for/1` resolves the same question.
  """
  def git_tracked?(session, path) do
    node = Cluster.runner_node_for(session) || node()

    case Cluster.rpc(node, __MODULE__, :tracked_locally?, [Map.get(session, :directory), path]) do
      result when is_boolean(result) -> result
      _ -> nil
    end
  end

  @doc """
  The node-local half of `git_tracked?/2` — public only so it can be the
  `Cluster.rpc/4` entry point on the session's own node.

  `git ls-files --error-unmatch -- <path>` in ARGV form, never a shell: the
  path originates in an LLM-written command string, so any shell
  interpolation here would be a command-injection hole.

  Exit 0 -> tracked. Any non-zero exit -> untracked, which deliberately also
  covers "absolute path outside this repo" and "not a git repository at all"
  (both are `false` in the measured D1: `untracked_in_repo` and `no_repo` both
  suppress). Failing to run git at all -> `nil`, unknown.
  """
  def tracked_locally?(directory, path) do
    with {:ok, dir} <- usable_directory(directory),
         {:ok, target} <- usable_path(path) do
      case System.cmd("git", ["ls-files", "--error-unmatch", "--", target],
             cd: dir,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> true
        {_output, _nonzero} -> false
      end
    else
      :unknown -> nil
    end
  rescue
    # System.cmd raises when git is missing or `cd` vanishes underneath us —
    # that is UNKNOWN, not "untracked".
    _ -> nil
  end

  defp usable_directory(dir) when is_binary(dir) do
    if File.dir?(dir), do: {:ok, dir}, else: :unknown
  end

  defp usable_directory(_), do: :unknown

  defp usable_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> :unknown
      "~" <> _ = tilde -> {:ok, Path.expand(tilde)}
      trimmed -> {:ok, trimmed}
    end
  end

  defp usable_path(_), do: :unknown
end
