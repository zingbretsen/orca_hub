defmodule OrcaHub.MCP.CodeExec.ToolSearchTest do
  use ExUnit.Case, async: true

  alias OrcaHub.MCP.CodeExec.ToolSearch

  defp tool(name, description), do: %{name: name, description: description}

  defp corpus do
    [
      tool("manage_todo", "Create, update, complete, and list todo items"),
      tool("manage_project", "Create and update projects; list each project todo"),
      tool("web_search", "Search the web for current information"),
      tool("search_notes", "Search notes by content and tags"),
      tool("add_calendar_event", "Add an event to the calendar"),
      tool("generate_image", "Generate an image from a text prompt"),
      tool("get_reading_queue", "List saved articles in the reading queue"),
      tool("get_issue", "Get an issue from a github repo")
    ]
  end

  defp names(results), do: Enum.map(results, & &1.name)

  test "tokenize splits snake_case and non-alphanumerics, downcased" do
    assert ToolSearch.tokenize("Manage_Todo v2!") == ["manage", "todo", "v2"]
    assert ToolSearch.tokenize("  ") == []
  end

  test "every result contains at least one query token" do
    results = ToolSearch.search(corpus(), "todo calendar")

    for %{name: name, description: description} <- results do
      doc_tokens = ToolSearch.tokenize(name) ++ ToolSearch.tokenize(description)
      assert Enum.any?(["todo", "calendar"], &(&1 in doc_tokens))
    end

    assert length(results) > 0
  end

  test "a tool matching ALL query tokens ranks above partial matches" do
    # "todo project" — manage_project matches both tokens (no stemming, so its
    # description carries the literal "todo"), manage_todo only "todo".
    results = ToolSearch.search(corpus(), "todo project")

    assert hd(names(results)) == "manage_project"
    assert "manage_todo" in names(results)
  end

  test "snake_case tool names are searchable by their words" do
    assert "get_reading_queue" in names(ToolSearch.search(corpus(), "reading"))
    assert "add_calendar_event" in names(ToolSearch.search(corpus(), "calendar event"))
    assert "get_issue" in names(ToolSearch.search(corpus(), "issue"))
  end

  test "name matches outrank description-only matches" do
    # "search" appears in web_search/search_notes names (double-counted) and
    # nowhere else as a name token.
    results = ToolSearch.search(corpus(), "search")
    assert [first, second | _] = names(results)
    assert Enum.sort([first, second]) == ["search_notes", "web_search"]
  end

  test "no token overlap returns an empty list" do
    assert ToolSearch.search(corpus(), "zebra xylophone") == []
    assert ToolSearch.search(corpus(), "") == []
    assert ToolSearch.search(corpus(), "!!!") == []
  end

  test "relative cutoff drops weak-tail matches of a strong query" do
    # "generate image prompt" matches generate_image on three tokens; any
    # other single weak overlap should fall below 0.3 * top_score.
    results = ToolSearch.search(corpus(), "generate image prompt")
    assert names(results) == ["generate_image"]
  end

  test "results are capped at 25" do
    many = for i <- 1..40, do: tool("tool_#{i}_todo", "todo helper number #{i}")
    assert length(ToolSearch.search(many, "todo")) == 25
  end

  test "empty corpus is fine" do
    assert ToolSearch.search([], "todo") == []
  end
end
