defmodule OrcaHub.MCP.Tools.Result do
  @moduledoc """
  Shared helpers for MCP tool implementations: building success/error
  result maps and conditionally populating attribute maps.
  """

  @doc "Wrap `content` in a successful MCP tool result."
  def text(content) do
    %{
      "content" => [%{"type" => "text", "text" => content}],
      "isError" => false
    }
  end

  @doc "Wrap `message` in an error MCP tool result."
  def error(message) do
    %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    }
  end

  @doc "Put `val` under `key` in `attrs`, unless `val` is nil."
  def maybe_put_field(attrs, _key, nil), do: attrs
  def maybe_put_field(attrs, key, val), do: Map.put(attrs, key, val)
end
