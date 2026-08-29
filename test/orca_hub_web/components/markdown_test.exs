defmodule OrcaHubWeb.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.HTML, only: [safe_to_string: 1]

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

  describe "render/2 copy-code buttons" do
    test "wraps fenced code blocks in a copy-code wrapper with a copy button" do
      html = Markdown.render("```elixir\nIO.puts(:hi)\n```") |> safe_to_string()

      assert html =~ ~s(class="code-copy-wrapper relative")
      assert html =~ ~s(data-copy-code="true")
      assert html =~ ~s(data-copy-icon="true")
      assert html =~ "hero-clipboard-document-micro"
      # The <pre> must be a SIBLING of the button inside the non-scrolling
      # wrapper, never a descendant of it, or the button scrolls away.
      assert html =~ ~r|<div class="code-copy-wrapper relative">\s*<pre>|
    end

    test "copy_code: false omits the button (JS-less artifact HTML export)" do
      html = Markdown.render("```\nx\n```", copy_code: false) |> safe_to_string()

      assert html =~ "<pre>"
      refute html =~ "code-copy-wrapper"
      refute html =~ "data-copy-code"
    end

    test "inline code is left alone" do
      html = Markdown.render("some `inline` code") |> safe_to_string()

      refute html =~ "code-copy-wrapper"
      assert html =~ "<code"
    end

    test "links still open in a new tab" do
      html = Markdown.render("[x](http://example.com)") |> safe_to_string()

      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
    end

    test "prose containing an Elixir tuple renders instead of raising" do
      # Earmark reads `{:ok, nodes}` as an illegal IAL and emits a WARNING,
      # which flips the parse status to :error. `Earmark.as_ast!/2` raises on
      # that; the `as_html!/2` this module used to call did not. Rendering must
      # keep the never-raise contract — one such message used to 500 the whole
      # session page.
      md = """
      Checking the result

      returns {:ok, nodes} and {:error_event, ok,} plus {"fail_fast", ok,}
      """

      html = Markdown.render(md) |> safe_to_string()

      assert html =~ "Checking the result"
      assert html =~ "nodes"
    end
  end
end
