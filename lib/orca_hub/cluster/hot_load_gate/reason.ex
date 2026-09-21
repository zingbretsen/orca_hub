defmodule OrcaHub.Cluster.HotLoadGate.Reason do
  @moduledoc """
  One reason a diff was refused for hot code loading.

  A refusal is a list of these, never a single collapsed message: a change
  that trips three categories should show an operator all three, because
  overriding is a judgement call and the second reason may be the one that
  actually matters.

  Fields:

    * `:category` — the rule that matched, one of
      `OrcaHub.Cluster.HotLoadGate.categories/0`. Match on this, not on the
      message text.
    * `:path` — the repo-relative path that tripped it.
    * `:status` — `:added | :modified | :deleted | :unknown`, as supplied by
      the caller; `:unknown` when the caller passed a bare path.
    * `:message` — operator-facing prose: what the change is, and what
      actually goes wrong if it is hot-loaded anyway.
    * `:evidence` — up to three trimmed diff lines that triggered a
      content-based rule (`:defstruct_change`, `:supervision_tree`); empty
      for rules that matched on the path alone.
  """

  @type t :: %__MODULE__{
          category: atom,
          path: String.t(),
          status: :added | :modified | :deleted | :unknown,
          message: String.t(),
          evidence: [String.t()]
        }

  @enforce_keys [:category, :path, :message]
  defstruct [:category, :path, :message, status: :unknown, evidence: []]
end
