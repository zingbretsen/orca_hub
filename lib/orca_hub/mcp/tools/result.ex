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

  @doc """
  Append `new_value` to an existing string field on `issue`, storing the
  result under `field` in `attrs`. A nil `new_value` leaves `attrs` unchanged.
  """
  def maybe_append_field(attrs, _issue, _field, nil), do: attrs

  def maybe_append_field(attrs, issue, field, new_value) do
    existing = Map.get(issue, field) || ""

    appended =
      if existing == "" do
        new_value
      else
        existing <> "\n\n" <> new_value
      end

    Map.put(attrs, field, appended)
  end

  @doc "Put `val` under `key` in `attrs`, unless `val` is nil."
  def maybe_put_field(attrs, _key, nil), do: attrs
  def maybe_put_field(attrs, key, val), do: Map.put(attrs, key, val)
end
