defmodule OrcaHub.SessionSearch.Cursor do
  @moduledoc """
  Durable keyset position of an `OrcaHub.SessionSearch.Indexer` sweep over
  `messages ORDER BY inserted_at, id`. One row per sweep `name`; a missing row
  or NULL position means "from the beginning".
  """

  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}
  schema "session_search_cursors" do
    field :last_inserted_at, :naive_datetime_usec
    field :last_message_id, :binary_id
    field :indexed_total, :integer, default: 0
    timestamps(type: :naive_datetime_usec)
  end
end
