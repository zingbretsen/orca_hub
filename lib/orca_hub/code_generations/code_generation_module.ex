defmodule OrcaHub.CodeGenerations.CodeGenerationModule do
  @moduledoc """
  One compiled module inside a generation: its name, its compile-time md5,
  and the `.beam` binary itself.

  `md5` is the module's COMPILE-TIME md5 — the value
  `:erlang.get_module_info(mod, :md5)` returns on a node that has the module
  loaded — and NOT `:erlang.md5/1` of the file's bytes. The two are
  different values, and only the former can be compared against a remote
  node's loaded code, which is the entire basis of differential reconcile.
  Storing the wrong one would make every node look permanently drifted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias OrcaHub.CodeGenerations.CodeGeneration

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "code_generation_modules" do
    field :module, :string
    field :md5, :binary
    field :beam, :binary
    field :beam_bytes, :integer, default: 0

    belongs_to :generation, CodeGeneration, foreign_key: :code_generation_id
  end

  def changeset(mod, attrs) do
    mod
    |> cast(attrs, [:code_generation_id, :module, :md5, :beam, :beam_bytes])
    |> validate_required([:code_generation_id, :module, :md5, :beam])
  end
end
