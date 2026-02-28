defmodule OrcaHubWeb.Markdown do
  @moduledoc """
  Renders markdown strings as HTML using Earmark.
  """

  def render(nil), do: ""
  def render(""), do: ""

  def render(markdown) when is_binary(markdown) do
    markdown
    |> Earmark.as_html!(code_class_prefix: "language-")
    |> Phoenix.HTML.raw()
  end
end
