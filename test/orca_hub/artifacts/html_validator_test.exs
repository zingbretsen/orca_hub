defmodule OrcaHub.Artifacts.HtmlValidatorTest do
  @moduledoc """
  Coverage for the cheap, non-fatal HTML sanity check used by
  `save_artifact` — never rejects, only returns warning strings.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.Artifacts.HtmlValidator

  test "returns no warnings for well-formed HTML" do
    html = "<html><body><div><p>hi <strong>there</strong></p></div></body></html>"
    assert HtmlValidator.validate(html) == []
  end

  test "flags an unclosed tag" do
    warnings = HtmlValidator.validate("<div><p>oops")
    assert Enum.any?(warnings, &(&1 =~ "unclosed"))
  end

  test "flags a mismatched closing tag" do
    warnings = HtmlValidator.validate("<div><span>oops</div>")
    assert Enum.any?(warnings, &(&1 =~ "mismatched"))
  end

  test "ignores void elements without requiring a closing tag" do
    html = "<div><img src=\"x.png\"><br><hr></div>"
    assert HtmlValidator.validate(html) == []
  end

  test "ignores self-closing tags" do
    assert HtmlValidator.validate("<svg><circle r=\"5\" /></svg>") == []
  end

  test "does not flag bare < inside script/style content" do
    html = """
    <html><body>
    <script>if (a < b) { console.log("x"); }</script>
    <style>.a { color: red; } /* a < b */</style>
    </body></html>
    """

    assert HtmlValidator.validate(html) == []
  end

  test "ignores comments" do
    html = "<div><!-- <span> unclosed inside a comment --></div>"
    assert HtmlValidator.validate(html) == []
  end

  test "returns an empty list for a non-binary" do
    assert HtmlValidator.validate(nil) == []
  end
end
