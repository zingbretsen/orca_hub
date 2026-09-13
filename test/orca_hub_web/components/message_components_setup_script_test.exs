defmodule OrcaHubWeb.MessageComponentsSetupScriptTest do
  @moduledoc """
  Rendering checks for the `system`/`setup_script` feed event persisted by
  `OrcaHub.Triggers.SetupScript.persist_event/3` — collapsed by default like
  `memory_injected`, visually distinct when the run FAILED, and — the point
  of the last test here — escaping its output, which is arbitrary command
  output rendered into the MAIN document rather than the sandboxed artifact
  iframe.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OrcaHubWeb.MessageComponents

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "system",
        "subtype" => "setup_script",
        "trigger_id" => "trig-1",
        "trigger_name" => "nightly-summary",
        "script" => "date -u",
        "exit_code" => 0,
        "timed_out" => false,
        "duration_ms" => 42,
        "truncated_bytes" => 0,
        "failed" => false,
        "error" => nil,
        "output" => "Sat Sep 13 00:00:00 UTC 2026"
      },
      overrides
    )
  end

  defp render_feed(event) do
    render_component(&MessageComponents.message_feed/1, %{
      messages: [event],
      session_node: nil
    })
  end

  describe "a successful run" do
    test "renders quietly, collapsed, with the trigger name, exit code and duration" do
      html = render_feed(event())

      assert html =~ "<details>"
      assert html =~ "Setup script ran"
      assert html =~ "nightly-summary"
      assert html =~ "exit 0"
      assert html =~ "42ms"
      # Quiet: no error styling on the container.
      refute html =~ "Setup script failed"
      refute html =~ "text-error"
    end

    test "shows the script and its output inside the collapsed disclosure" do
      html = render_feed(event())

      assert html =~ "date -u"
      assert html =~ "Sat Sep 13 00:00:00 UTC 2026"
    end

    test "says so explicitly when the script produced no output" do
      html = render_feed(event(%{"output" => ""}))

      assert html =~ "(no output)"
    end
  end

  describe "a failed run" do
    test "is visually distinct while collapsed for a non-zero exit" do
      html = render_feed(event(%{"exit_code" => 2, "failed" => true, "output" => "boom"}))

      assert html =~ "Setup script failed"
      assert html =~ "text-error"
      assert html =~ "exit 2"
    end

    test "reports a timeout as such" do
      html =
        render_feed(
          event(%{
            "exit_code" => nil,
            "timed_out" => true,
            "failed" => true,
            "duration_ms" => 120_000
          })
        )

      assert html =~ "Setup script failed"
      assert html =~ "timed out"
    end

    test "surfaces an out-of-script error (unreachable node, missing directory)" do
      html =
        render_feed(
          event(%{
            "exit_code" => nil,
            "failed" => true,
            "error" => "setup script directory /nope does not exist on nonode@nohost",
            "output" => ""
          })
        )

      assert html =~ "Setup script failed"
      assert html =~ "could not run"
      assert html =~ "setup script directory /nope does not exist"
    end

    test "uses the precomputed \"failed\" flag rather than re-deriving it" do
      # exit_code 0 but failed: true — nothing here may second-guess the
      # persister, which owns the timeout/error/exit-code combination.
      html = render_feed(event(%{"exit_code" => 0, "failed" => true}))

      assert html =~ "Setup script failed"

      # And the inverse: failed false wins even with a non-zero exit code.
      html = render_feed(event(%{"exit_code" => 3, "failed" => false}))
      assert html =~ "Setup script ran"
      refute html =~ "Setup script failed"
    end
  end

  test "marks truncated output with the dropped byte count" do
    html = render_feed(event(%{"truncated_bytes" => 4096}))

    assert html =~ "4096 bytes dropped"
  end

  test "omits the truncation marker when nothing was dropped" do
    refute render_feed(event()) =~ "bytes dropped"
  end

  describe "untrusted output escaping" do
    test "renders a hostile payload as visible text, never as live HTML" do
      hostile =
        "<script>alert(1)</script>\n<img src=x onerror=\"alert(2)\">\n</pre><b>escaped?</b>"

      html = render_feed(event(%{"output" => hostile, "script" => "curl evil.example"}))

      # Escaped, i.e. present only in entity form...
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=&quot;alert(2)&quot;&gt;"
      assert html =~ "&lt;/pre&gt;&lt;b&gt;escaped?&lt;/b&gt;"

      # ...and never as live markup.
      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<img src=x"
      refute html =~ "<b>escaped?</b>"
    end

    test "escapes a hostile SCRIPT body too (operator-authored, but still escaped)" do
      html = render_feed(event(%{"script" => "echo '<script>alert(3)</script>'", "output" => ""}))

      assert html =~ "&lt;script&gt;alert(3)&lt;/script&gt;"
      refute html =~ "<script>alert(3)</script>"
    end

    test "escapes a hostile trigger name and error string" do
      html =
        render_feed(
          event(%{
            "trigger_name" => "<img src=x onerror=alert(4)>",
            "failed" => true,
            "error" => "<svg onload=alert(5)>"
          })
        )

      assert html =~ "&lt;img src=x onerror=alert(4)&gt;"
      assert html =~ "&lt;svg onload=alert(5)&gt;"
      refute html =~ "<img src=x"
      refute html =~ "<svg onload"
    end
  end
end
