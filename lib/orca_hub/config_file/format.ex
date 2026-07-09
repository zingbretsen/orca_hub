defmodule OrcaHub.ConfigFile.Format do
  @moduledoc """
  Behaviour every `OrcaHub.ConfigFile` adapter (JSON now; TOML/YAML later)
  must implement. See `OrcaHub.ConfigFile`'s moduledoc for the tree/path/op
  shapes and for how an adapter registers itself.

  `apply_op/2` deliberately takes and returns RAW TEXT rather than the
  parsed tree — a naive "parse, mutate the parsed structure, re-serialize
  the whole thing" approach loses comments/formatting for formats like TOML
  and YAML that a full re-dump can't faithfully preserve. JSON's adapter
  happens to implement this via ordered decode/re-encode (round-trips key
  order exactly since there's no comment/whitespace to lose), but a future
  TOML/YAML adapter is expected to do a surgical text edit instead.
  """

  alias OrcaHub.ConfigFile

  @doc "Parses `raw` into a normalized tree (see `OrcaHub.ConfigFile`'s moduledoc for its shape), or a parse error."
  @callback parse(raw :: String.t()) :: {:ok, ConfigFile.tree()} | {:error, term()}

  @doc "Applies a single op directly to `raw` text, returning the new raw text."
  @callback apply_op(raw :: String.t(), op :: ConfigFile.op()) ::
              {:ok, String.t()} | {:error, term()}
end
