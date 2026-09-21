defmodule OrcaHub.Repo.Migrations.CreateCodeGenerations do
  use Ecto.Migration

  # The hub's DURABLE desired code state: one row per published generation,
  # plus one row per module in it. See OrcaHub.Cluster.CodePush for the
  # reconciliation loop these tables feed, and OrcaHub.CodeGenerations for
  # the read/write surface.
  #
  # Per-module rows rather than one blob column: the payload is ~277
  # modules / ~7.6 MiB, and reconciling a node DIFFERENTIALLY (fetch only
  # the modules whose md5 differs) is the whole point — a single blob would
  # force every reconcile to move 7.6 MiB even to fix one module.
  def change do
    create table(:code_generations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Provenance of the beams. `base_sha` is the git SHA of the checkout
      # they were compiled from; `dirty` records that the tree had
      # uncommitted changes at compile time, which the publish path refuses
      # by default and only ever allows with an explicit flag. Once dirty is
      # true, "the fleet is running uncommitted code" is a reportable fact
      # forever, not an inference.
      add :base_sha, :string, null: false
      add :dirty, :boolean, null: false, default: false
      add :published_by, :string
      add :published_from_node, :string

      # Toolchain the beams were produced by. A beam built under a different
      # ERTS must never be loaded onto a node running this one, so this is
      # stored with the generation rather than re-derived from whoever
      # happens to be reconciling.
      add :erts_version, :string, null: false
      add :otp_release, :string
      add :elixir_version, :string

      add :module_count, :integer, null: false, default: 0
      add :total_bytes, :bigint, null: false, default: 0

      # Circuit-breaker state. See OrcaHub.Cluster.CodePush's moduledoc for
      # the full argument; briefly:
      #   pending     — published, never yet PROVEN healthy
      #   healthy     — the hub applied it and stayed up past the health window
      #   quarantined — burned through its apply budget without proving healthy
      #   superseded  — explicitly cleared by an operator (e.g. a real deploy landed)
      add :status, :string, null: false, default: "pending"
      add :apply_attempts, :integer, null: false, default: 0
      add :proven_healthy_at, :utc_datetime_usec
      add :superseded_at, :utc_datetime_usec

      # HotLoadGate reasons that were OVERRIDDEN at publish time, if any.
      # Empty for an ordinary clean publish. Never dropped: a forced publish
      # has to stay auditable after the fact.
      add :forced_reasons, {:array, :map}, null: false, default: []
      add :notes, :text

      # Microsecond precision, not the codebase's usual second precision:
      # "the newest non-superseded generation" is resolved by ordering on
      # inserted_at, and two publishes landing in the same second would make
      # that ordering ambiguous.
      timestamps(type: :utc_datetime_usec)
    end

    # The reconciler always wants "the newest non-superseded generation".
    create index(:code_generations, [:status, :inserted_at])

    create table(:code_generation_modules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :code_generation_id,
          references(:code_generations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :module, :string, null: false
      # The module's COMPILE-TIME md5 (:erlang.get_module_info/2), NOT
      # :erlang.md5/1 of the file bytes — those differ, and only the former
      # is comparable against what a remote node reports about loaded code.
      add :md5, :binary, null: false
      add :beam, :binary, null: false
      add :beam_bytes, :integer, null: false, default: 0
    end

    create unique_index(:code_generation_modules, [:code_generation_id, :module])
    # Differential reconcile fetches a SUBSET of modules by name.
    create index(:code_generation_modules, [:code_generation_id, :md5])
  end
end
