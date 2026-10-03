defmodule OrcaHubWeb.PanelLayoutCheckTest do
  @moduledoc """
  Runs `assets/js/panel_layout.check.mjs` — the standalone node checks for the
  session page's file-panel layout signal (ORCAHUB3-130): the `panel_layout`
  connect param, the `PanelLayout` hook's breakpoint-crossing pushes, and the
  media query's mirror of the shells' CSS `lg:` breakpoint — so the suite
  actually gates them.

  Same reasoning as `OrcaHubWeb.VoiceViewCheckTest`: the repo has no JS test
  runner, and the regressions here are SILENT. A query that drifts from the
  CSS breakpoint renders the artifact into the hidden shell, leaving a blank
  panel on screen, with nothing failing anywhere else.

  The `node`-prerequisite pattern is lifted from that sibling test: assert the
  tool is present rather than silently skipping, so a box without it fails
  loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/panel_layout.check.mjs", __DIR__)

  test "the panel layout signal checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    panel_layout.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
