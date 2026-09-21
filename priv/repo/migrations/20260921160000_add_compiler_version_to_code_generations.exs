defmodule OrcaHub.Repo.Migrations.AddCompilerVersionToCodeGenerations do
  use Ecto.Migration

  # The Erlang compiler version (`:compiler` app vsn, e.g. "8.5.5") that
  # produced this generation's beams — read back out of each beam's own
  # `compile_info` chunk, not merely asserted by the publisher.
  #
  # ERTS version alone does not pin an artifact's provenance: a `.beam` file
  # sitting in _build carries no ERTS stamp, and the live-runtime comparison
  # `CodeSync.compatible?/1` performs cannot see how the FILE was produced.
  # This column is the durable half of the answer to "what actually built
  # these bytes" — see OrcaHub.Cluster.CodePush's payload-provenance section.
  def change do
    alter table(:code_generations) do
      add :compiler_version, :string
    end
  end
end
