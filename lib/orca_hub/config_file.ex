defmodule OrcaHub.ConfigFile do
  @moduledoc """
  Structured editing over config-style files (currently JSON; TOML/YAML are
  future adapters slotting into the same `OrcaHub.ConfigFile.Format`
  behaviour). Used by `OrcaHubWeb.StructuredEditor` and its two hosts
  (`NodeLive.Show`'s Backend Configuration section, `ProjectLive.Show`'s
  file viewer) to render a config file as a tree of collapsible
  sections/click-to-edit rows instead of a raw textarea, and to apply
  single edits (set/delete/add) back onto the file's raw text.

  ## Adapter registry

  New formats register themselves in `@adapters` below and implement the
  `OrcaHub.ConfigFile.Format` behaviour (`parse/1`, `apply_op/2`). The UI
  picks up a new format automatically once it's registered here —
  `OrcaHubWeb.NodeLive.ConfigComponents` and `OrcaHubWeb.ProjectLive.Show`
  both gate the Structured/Raw toggle on `OrcaHub.ConfigFile.supported?/1`,
  keyed off the same `format:` atom `OrcaHub.NodeConfig`'s catalog (or the
  project file's extension) already produces — no other UI change is
  needed to light up a new format.

  ## Tree shape

  `parse/1` normalizes an adapter's native parsed structure into a format
  the UI can render generically:

      %{kind: :object, path: [...], entries: [{key, tree}, ...]}
      %{kind: :array,  path: [...], items: [tree, ...]}
      %{kind: :leaf,   path: [...], value: term(), value_type: value_type()}

  `entries` preserves source order (JSON's adapter decodes via
  `Jason.OrderedObject` for this). `value_type` is one of `:string`,
  `:integer`, `:float`, `:boolean`, `:null`, inferred from the Elixir value.

  ## Paths

  A path is a list of object keys (strings) and array indices
  (non-negative integers), e.g. `["permissions", "allow", 0]` — stable
  across a single parse, used to address a node for an op or for wire
  round-tripping (`encode_path/1` / `decode_path/1`) between
  `OrcaHubWeb.StructuredEditor` (which only ever sees encoded path
  strings on phx-value-* attributes) and its host LiveView.

  ## Ops

  `apply_op/3` takes an already-parsed op and the CURRENT raw text (not the
  tree) and returns new raw text:

      {:set, path, value}            # replace the leaf/element at path
      {:delete, path}                # remove the key/element at path
      {:add, parent_path, key, value}  # key: string to add an object member,
                                        # nil to append an array item

  A parse error from `parse/1` must never crash the caller — hosts are
  expected to fall back to raw-text-only editing (with the error message
  shown) when `parse/1` returns `{:error, _}`; `apply_op/3` on top of
  malformed text degrades the same way.
  """

  alias OrcaHub.ConfigFile.{Json, Toml, Yaml}

  @type path :: [String.t() | non_neg_integer()]
  @type value_type :: :string | :integer | :float | :boolean | :null
  @type tree ::
          %{kind: :object, path: path, entries: [{String.t(), tree}]}
          | %{kind: :array, path: path, items: [tree]}
          | %{kind: :leaf, path: path, value: term(), value_type: value_type}
  @type op ::
          {:set, path, term()}
          | {:delete, path}
          | {:add, path, String.t() | nil, term()}

  @adapters %{json: Json, toml: Toml, yaml: Yaml}

  @doc "Whether `format` has a registered structured-editing adapter."
  def supported?(format), do: Map.has_key?(@adapters, format)

  @doc "Parses `raw` (in `format`) into the normalized tree."
  @spec parse(atom(), String.t()) :: {:ok, tree} | {:error, term()}
  def parse(format, raw) do
    with {:ok, adapter} <- fetch_adapter(format) do
      adapter.parse(raw)
    end
  end

  @doc "Applies `op` to `raw` (in `format`), returning the new raw text."
  @spec apply_op(atom(), String.t(), op) :: {:ok, String.t()} | {:error, term()}
  def apply_op(format, raw, op) do
    with {:ok, adapter} <- fetch_adapter(format) do
      adapter.apply_op(raw, op)
    end
  end

  defp fetch_adapter(format) do
    case Map.fetch(@adapters, format) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, :unsupported_format}
    end
  end

  # -------------------------------------------------------------------
  # Tree navigation
  # -------------------------------------------------------------------

  @doc "Looks up the tree node at `path`, or `nil` if it doesn't exist."
  @spec get_node(tree, path) :: tree | nil
  def get_node(node, []), do: node

  def get_node(%{kind: :object, entries: entries}, [key | rest]) when is_binary(key) do
    case List.keyfind(entries, key, 0) do
      {^key, child} -> get_node(child, rest)
      nil -> nil
    end
  end

  def get_node(%{kind: :array, items: items}, [index | rest]) when is_integer(index) do
    case Enum.at(items, index) do
      nil -> nil
      child -> get_node(child, rest)
    end
  end

  def get_node(_node, _path), do: nil

  # -------------------------------------------------------------------
  # Path wire encoding — used on phx-value-path; base64-per-segment avoids
  # any delimiter collision with object keys that themselves contain "."
  # or the segment-join character.
  # -------------------------------------------------------------------

  @doc "Encodes a path for use in a `phx-value-path` attribute."
  @spec encode_path(path) :: String.t()
  def encode_path(path) do
    path
    |> Enum.map(fn
      index when is_integer(index) -> "i" <> Integer.to_string(index)
      key when is_binary(key) -> "s" <> Base.url_encode64(key, padding: false)
    end)
    |> Enum.join(".")
  end

  @doc "Decodes a path produced by `encode_path/1`."
  @spec decode_path(String.t()) :: path
  def decode_path(""), do: []

  def decode_path(encoded) do
    encoded
    |> String.split(".")
    |> Enum.map(&decode_segment/1)
  end

  defp decode_segment("i" <> digits), do: String.to_integer(digits)
  defp decode_segment("s" <> b64), do: Base.url_decode64!(b64, padding: false)

  # -------------------------------------------------------------------
  # Value coercion — text submitted through the UI's edit/add forms back
  # into a typed Elixir term suitable for a `:set`/`:add` op's `value`.
  # -------------------------------------------------------------------

  @doc """
  Coerces raw form text into a value of `value_type` for an edit/add op.
  `:null` ignores `raw` entirely (there's nothing to type). `:integer` and
  `:float` are both routed through numeric parsing (accepting whichever of
  the two the text actually is) since the UI offers a single "number"
  choice rather than asking the user to pick a numeric subtype.
  """
  @spec coerce(value_type | :number, String.t()) :: {:ok, term()} | {:error, term()}
  def coerce(:string, raw), do: {:ok, raw}
  def coerce(:null, _raw), do: {:ok, nil}
  def coerce(:boolean, raw), do: {:ok, raw in ["true", "on", "1", "yes"]}

  def coerce(type, raw) when type in [:integer, :float, :number] do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> {:ok, float}
          _ -> {:error, :invalid_number}
        end
    end
  end

  @doc """
  Parses a `value_type` submitted as a form string (e.g. from an add-key
  type select). `"number"` maps to the `:number` pseudo-type `coerce/2`
  accepts — the UI offers one "number" choice rather than asking the user
  to pick `:integer` vs `:float` up front.
  """
  @spec parse_value_type(String.t()) :: value_type | :number
  def parse_value_type("number"), do: :number
  def parse_value_type("boolean"), do: :boolean
  def parse_value_type("null"), do: :null
  def parse_value_type(_), do: :string
end
