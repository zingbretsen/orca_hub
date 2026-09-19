defmodule OrcaHub.Repo.Migrations.AddFileSurgeryToChurnSamples do
  @moduledoc """
  ORCAHUB3-66 — close the file-surgery observability gap in `churn_samples`.

  ## READ THIS BEFORE QUERYING `churn_samples.churn_suspected`

  **`churn_suspected` is VOID as historical ground truth for every row written
  before this migration ran.** It is uniformly `false` on those rows for a
  reason that has nothing to do with churn: `OrcaHub.ChurnSampler.run_sweep/1`
  called `Churn.assess/3` — the arity-3 form, in which `file_surgery` takes its
  `nil` default — so the sampler NEVER COMPUTED FILE SURGERY AT ALL. Only the
  alert path (`AlertEvaluator`) ever passed evidence. The qualitative half of
  `churn_suspected` was therefore structurally unable to be true in this table,
  and the volumetric half fired exactly once in seven weeks.

  The scale of the discrepancy: `churn_suspected` was true **0 times in 1,480
  samples** over the same weeks in which **229 file-surgery alerts were
  delivered** to orchestrators. Nobody may read those 1,480 falses as 1,480
  clean sessions. They are 1,480 rows on which the question was never asked.

  **The void rows are exactly those where `file_surgery_suspected IS NULL`.**
  That is why the new boolean is deliberately NULLABLE WITH NO DEFAULT rather
  than `null: false, default: false` — a default would backfill the old rows to
  `false` and make "never computed" indistinguishable from "computed, and there
  was no surgery", erasing the discontinuity into data that looks continuous.
  Any analysis spanning this migration must filter on that NULL, not on dates.

  See `churn_alert_precision.md` (repo root) §0 and its closing section.

  ## What the new columns hold

    * `file_surgery_suspected` — `NULL` = never computed (pre-migration row);
      `true`/`false` = computed by the sampler for that sample.
    * `file_surgery_kind` — `OrcaHub.Sessions.FileSurgery` evidence `:kind`
      (`write_to_tracked` / `programmatic_write` / `in_place_edit` /
      `slice_and_redirect`), `NULL` when there was no detection.
    * `file_surgery_path` — the path the evidence names, `NULL` when there was
      no detection. Text, not varchar: these are LLM-authored paths.
    * `surgery_alert_decision` — what `OrcaHub.Sessions.SurgeryAlertPolicy`
      would have decided for this detection. `NULL` = not evaluated (no
      detection to decide about); `"alert"`; or `"suppress:<reason>"` where
      reason is the atom `decide/2` returned. Prefix-queryable:
      `where surgery_alert_decision like 'suppress:%'`.

  That last column is the whole point of the migration. ORCAHUB3-66 starts
  suppressing ~31% of file-surgery alerts, and a suppressed alert would
  otherwise leave NO TRACE ANYWHERE — the alerts table records delivered
  alerts only. Persisting the decision is what makes "did U1b cost us
  anything?" answerable from data in a month instead of unanswerable forever.
  """

  use Ecto.Migration

  def change do
    alter table(:churn_samples) do
      # NULLABLE ON PURPOSE, NO DEFAULT — see the moduledoc. NULL is the
      # marker that separates the pre-migration rows (on which file surgery
      # was never computed, making churn_suspected void) from post-migration
      # rows that genuinely had no surgery.
      add :file_surgery_suspected, :boolean
      add :file_surgery_kind, :string
      add :file_surgery_path, :text
      add :surgery_alert_decision, :string
    end

    # Supports the two questions this migration exists to answer: "how often
    # does the policy suppress, and why" and "show me the suppressed ones".
    create index(:churn_samples, [:surgery_alert_decision, :sampled_at],
             name: :churn_samples_surgery_alert_decision_idx,
             where: "surgery_alert_decision is not null"
           )
  end
end
