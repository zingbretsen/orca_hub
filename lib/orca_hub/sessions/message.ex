defmodule OrcaHub.Sessions.Message do
  @moduledoc "Schema for a message belonging to a session."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :data, :map

    belongs_to :session, OrcaHub.Sessions.Session

    # usec precision: see the widen_message_timestamps_to_microseconds
    # migration's moduledoc — "most recent message" queries have no
    # secondary tiebreaker beyond inserted_at.
    timestamps(type: :naive_datetime_usec)
  end

  # U+FFFD REPLACEMENT CHARACTER: the feed shows that bytes were dropped,
  # where a silent removal would not.
  @replacement "�"

  # Every message insert (runner events, tool results, system events, the
  # HubRPC path) and update goes through here, so this is where `data` is
  # made storable. `OrcaHub.ClaudeImport` bypasses it with `insert_all` and
  # calls `storable/1` itself.
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :data])
    |> validate_required([:session_id, :data])
    |> update_change(:data, &storable/1)
  end

  @doc """
  `term` with every string made storable in Postgres (ORCAHUB3-153).

  Postgres rejects U+0000 anywhere in a jsonb string or a text column, and
  Postgrex cannot encode a string that is not valid UTF-8. A Bash tool call
  that `cat`s a binary file returns both, and one such `tool_result`
  crashed a `SessionRunner` mid-turn (Postgrex 22P05). Each NUL and each
  invalid byte sequence becomes U+FFFD, in values and map keys alike, at any
  depth. Structs (the `NaiveDateTime` `"timestamp"`s) and non-string scalars
  pass through unchanged.
  """
  def storable(string) when is_binary(string) do
    string =
      if String.valid?(string), do: string, else: String.replace_invalid(string, @replacement)

    case :binary.match(string, <<0>>) do
      :nomatch -> string
      _ -> :binary.replace(string, <<0>>, @replacement, [:global])
    end
  end

  def storable(%_{} = struct), do: struct

  def storable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {storable(key), storable(value)} end)

  def storable(list) when is_list(list), do: Enum.map(list, &storable/1)
  def storable(other), do: other
end
