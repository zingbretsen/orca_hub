defmodule OrcaHubWeb.EnvAllowlistInput do
  @moduledoc """
  Shared text <-> list conversion for the `env_allowlist` form inputs on the
  Node show page and the Project edit form (`OrcaHub.ClusterNodes.ClusterNode`/
  `OrcaHub.Projects.Project`'s `env_allowlist` field, `{:array, :string}`).
  HTML forms submit this as free text (comma/space/newline separated
  tokens) — `parse/1` turns that into the list a changeset expects, `to_text/1`
  is the inverse for rendering the current value back into the input.
  """

  @doc "Parses free text (comma/space/newline separated) into trimmed, non-blank entries."
  def parse(nil), do: []

  def parse(text) when is_binary(text) do
    text
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Renders a list of entries back into the input's text form."
  def to_text(entries) when is_list(entries), do: Enum.join(entries, ", ")
  def to_text(_), do: ""

  @doc "Human-readable summary of a changeset's `:env_allowlist` errors, for a flash message."
  def error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.get(:env_allowlist, ["invalid entry"])
    |> Enum.join("; ")
  end
end
