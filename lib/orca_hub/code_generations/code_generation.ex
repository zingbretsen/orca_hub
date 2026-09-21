defmodule OrcaHub.CodeGenerations.CodeGeneration do
  @moduledoc """
  One published generation of compiled `:orca_hub` beams — the hub's DESIRED
  code state, which every connected node is reconciled toward.

  The row carries three independent kinds of information, and it is worth
  keeping them apart when reading the schema:

    * **Provenance** (`base_sha`, `dirty`, `published_by`,
      `published_from_node`) — where these beams came from. `dirty: true` is
      the load-bearing one: it is the only durable record that the fleet may
      be running code that exists in no commit.
    * **Toolchain** (`erts_version`, `otp_release`, `elixir_version`) — what
      produced them, so a node on a different ERTS can be SKIPPED rather
      than handed beams it cannot load.
    * **Circuit-breaker state** (`status`, `apply_attempts`,
      `proven_healthy_at`) — whether this generation has ever demonstrated
      that it does not kill the hub. See `OrcaHub.Cluster.CodePush`.

  ## Statuses

    * `"pending"` — published, applied zero or more times, never yet proven
      healthy. A pending generation is still eligible to be applied, but
      only within its apply budget.
    * `"healthy"` — the hub applied it to ITSELF and was still alive a
      configurable number of seconds later. Only a healthy generation is
      re-applied on boot without hesitation.
    * `"quarantined"` — it exhausted its apply budget without ever proving
      healthy. Never applied again. This is the state that breaks a
      CrashLoopBackOff without anyone having to reach into a pod that will
      not stay up.
    * `"superseded"` — explicitly cleared, e.g. after a real image deploy
      landed and the fleet is now NEWER than this generation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OrcaHub.CodeGenerations.CodeGenerationModule

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending healthy quarantined superseded)

  schema "code_generations" do
    field :base_sha, :string
    field :dirty, :boolean, default: false
    field :published_by, :string
    field :published_from_node, :string

    field :erts_version, :string
    field :otp_release, :string
    field :elixir_version, :string

    field :module_count, :integer, default: 0
    field :total_bytes, :integer, default: 0

    field :status, :string, default: "pending"
    field :apply_attempts, :integer, default: 0
    field :proven_healthy_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec

    field :forced_reasons, {:array, :map}, default: []
    field :notes, :string

    has_many :modules, CodeGenerationModule, foreign_key: :code_generation_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Statuses a generation row may hold."
  def statuses, do: @statuses

  @doc "True when `status` means the generation should never be applied again."
  def terminal?(status) when status in ["quarantined", "superseded"], do: true
  def terminal?(_), do: false

  def changeset(generation, attrs) do
    generation
    |> cast(attrs, [
      :base_sha,
      :dirty,
      :published_by,
      :published_from_node,
      :erts_version,
      :otp_release,
      :elixir_version,
      :module_count,
      :total_bytes,
      :status,
      :apply_attempts,
      :proven_healthy_at,
      :superseded_at,
      :forced_reasons,
      :notes
    ])
    |> validate_required([:base_sha, :erts_version])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:apply_attempts, greater_than_or_equal_to: 0)
  end
end
