defmodule OrcaHubWeb.MermaidBlocksCheckTest do
  @moduledoc """
  Runs `assets/js/mermaid_blocks.check.mjs` — the standalone node checks for
  the ```mermaid block renderer (`mermaid_blocks.js`): a page with no mermaid
  block never loads the renderer, an ordinary patch costs no document-wide
  query, blocks from the dead render, patches and in-place morphs are all
  rendered, and a failed load is retried. Source checks pin the root layout
  (no CDN script) and the exact mermaid version.

  Same `node`-prerequisite pattern as `OrcaHubWeb.PanelLayoutCheckTest`:
  assert the tool is present rather than silently skipping.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/mermaid_blocks.check.mjs", __DIR__)

  test "the mermaid block renderer checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    mermaid_blocks.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
