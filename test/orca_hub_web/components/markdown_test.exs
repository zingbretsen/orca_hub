defmodule OrcaHubWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias OrcaHubWeb.Markdown

  describe "split_frontmatter/1" do
    test "splits a leading YAML frontmatter block off the body" do
      content = """
      ---
      name: foo
      description: "A feedback note"
      metadata:
        type: feedback
      ---

      Body for foo.
      """

      assert {frontmatter, body} = Markdown.split_frontmatter(content)

      assert frontmatter == """
             ---
             name: foo
             description: "A feedback note"
             metadata:
               type: feedback
             ---\
             """

      assert body == "Body for foo.\n"
    end

    test "returns nil frontmatter for content with no frontmatter" do
      assert Markdown.split_frontmatter("Just a paragraph.\n") ==
               {nil, "Just a paragraph.\n"}
    end

    test "returns nil frontmatter for an unterminated leading '---' block" do
      content = "---\nname: foo\nno closing delimiter\n"
      assert Markdown.split_frontmatter(content) == {nil, content}
    end
  end

  describe "join_frontmatter/2" do
    test "reassembles frontmatter and body with a blank line between them" do
      assert Markdown.join_frontmatter("---\nname: foo\n---", "Body text.") ==
               "---\nname: foo\n---\n\nBody text."
    end

    test "returns just the frontmatter when the body is empty" do
      assert Markdown.join_frontmatter("---\nname: foo\n---", "") == "---\nname: foo\n---"
    end

    test "returns just the body when there is no frontmatter" do
      assert Markdown.join_frontmatter(nil, "Body text.") == "Body text."
    end
  end

  describe "split_frontmatter/1 + join_frontmatter/2 round-trip" do
    test "a frontmatter'd memory survives editing a body block byte-identically elsewhere in the file" do
      original = """
      ---
      name: multi
      description: "Two paragraphs"
      metadata:
        type: project
      ---

      First paragraph.

      Second paragraph.
      """

      {frontmatter, body} = Markdown.split_frontmatter(original)
      blocks = Markdown.split_blocks(body)

      assert blocks == [{0, "First paragraph."}, {1, "Second paragraph."}]

      edited_blocks =
        Enum.map(blocks, fn
          {1, _} -> {1, "Updated second paragraph."}
          other -> other
        end)

      rebuilt = Markdown.join_frontmatter(frontmatter, Markdown.join_blocks(edited_blocks))

      assert rebuilt == """
             ---
             name: multi
             description: "Two paragraphs"
             metadata:
               type: project
             ---

             First paragraph.

             Updated second paragraph.\
             """

      # Frontmatter bytes are untouched by the body edit.
      {rebuilt_frontmatter, _rebuilt_body} = Markdown.split_frontmatter(rebuilt)
      assert rebuilt_frontmatter == frontmatter
    end
  end
end
