defmodule OrcaHub.Artifacts.HtmlValidator do
  @moduledoc """
  Cheap, non-fatal sanity check for `kind: "html"` artifact content on save.

  Floki's parser is deliberately lenient (HTML5-style auto-repair, the same
  behavior a browser applies) and effectively never errors on malformed
  markup — it silently closes/reparents whatever it's given. So instead of
  relying on parse failures, `validate/1` does its own simple tag-balance
  scan to catch unclosed/mismatched tags and surfaces them as warning
  strings. Always non-fatal: callers include the warnings in the save
  result for the agent to fix on a later iteration, but the save itself is
  never rejected.
  """

  @void_elements ~w(area base br col embed hr img input link meta param source track wbr)
  @tag_regex ~r/<(\/?)([a-zA-Z][a-zA-Z0-9-]*)\b[^>]*?(\/?)>/

  @doc "Returns a list of warning strings — empty if nothing looked wrong."
  def validate(content) when is_binary(content) do
    case Floki.parse_document(content) do
      {:ok, _doc} -> balance_warnings(content)
      {:error, reason} -> ["Could not parse as HTML: #{inspect(reason)}"]
    end
  end

  def validate(_content), do: []

  defp balance_warnings(content) do
    {stack, warnings} =
      content
      |> strip_noise()
      |> scan_tags()
      |> Enum.reduce({[], []}, &apply_tag/2)

    warnings = if stack == [], do: warnings, else: [unclosed_message(stack) | warnings]
    Enum.reverse(warnings)
  end

  # Strip comments and script/style bodies — their content routinely
  # contains bare `<` (JS comparisons/generics, CSS selectors) that isn't a
  # tag and would otherwise pollute the scan with false positives.
  defp strip_noise(content) do
    content
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/si, "")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/si, "")
  end

  defp scan_tags(content), do: Regex.scan(@tag_regex, content)

  defp apply_tag([_, "", name, self_close], {stack, warnings}) do
    name = String.downcase(name)

    if self_close == "/" or name in @void_elements do
      {stack, warnings}
    else
      {[name | stack], warnings}
    end
  end

  defp apply_tag([_, "/", name, _self_close], {stack, warnings}) do
    name = String.downcase(name)

    case Enum.split_while(stack, &(&1 != name)) do
      {_skipped, []} ->
        {stack, ["unexpected closing tag </#{name}> with no matching open tag" | warnings]}

      {[], [^name | rest]} ->
        {rest, warnings}

      {skipped, [^name | rest]} ->
        still_open = Enum.map_join(skipped, ", ", &"<#{&1}>")

        {rest,
         ["mismatched closing tag </#{name}> — still open before it: #{still_open}" | warnings]}
    end
  end

  defp unclosed_message(stack) do
    tags = stack |> Enum.uniq() |> Enum.map_join(", ", &"<#{&1}>")
    "unclosed tag(s): #{tags}"
  end
end
