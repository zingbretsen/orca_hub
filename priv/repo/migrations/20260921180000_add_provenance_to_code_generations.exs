defmodule OrcaHub.Repo.Migrations.AddProvenanceToCodeGenerations do
  use Ecto.Migration

  # What KIND of process published this generation — see
  # OrcaHub.CodeGenerations.Provenance. Format "<version>:<runtime>:<env>",
  # e.g. "1:release:prod" or "1:mix:test", stamped from a COMPILE-TIME
  # attribute of the publishing code so no caller can set it.
  #
  # NULLABLE on purpose, and left null for every pre-existing row. A null
  # marker is a REFUSAL at apply time, not a grandfathered pass: the local
  # systemd production instance and `bin/test` share this database, so a row
  # with no provenance is indistinguishable from one a test run left behind,
  # and hot-loading synthetic in-test modules onto a live node is the exact
  # outcome the column exists to prevent. Backfilling a value here would
  # hand that trust to rows that never earned it.
  def change do
    alter table(:code_generations) do
      add :provenance, :string
    end
  end
end
