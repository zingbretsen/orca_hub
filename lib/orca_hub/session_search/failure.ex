defmodule OrcaHub.SessionSearch.Failure do
  @moduledoc """
  A message memory-service rejected (per-doc `errors` entry of an otherwise
  200 response). The sweep cursor moves past it; the indexer retries these
  rows separately, with backoff, until `attempts` reaches its cap — after
  which the row stays as an inspectable dead letter.
  """

  use Ecto.Schema

  @primary_key {:message_id, :binary_id, autogenerate: false}
  schema "session_search_failures" do
    field :session_id, :binary_id
    field :reason, :string
    field :attempts, :integer, default: 1
    timestamps(type: :naive_datetime_usec)
  end
end
