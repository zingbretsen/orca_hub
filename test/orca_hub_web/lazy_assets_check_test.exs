defmodule OrcaHubWeb.LazyAssetsCheckTest do
  @moduledoc """
  Runs `assets/js/lazy_assets.check.mjs` — the standalone node checks for the
  lazily loaded bundles (`lazy_assets.js`) and the Terminal hook that loads
  xterm through them: one fetch per bundle per page, retry after a failed
  load, the stylesheet awaited before a terminal opens, and a hook destroyed
  mid-load never opening one.

  Same `node`-prerequisite pattern as `OrcaHubWeb.PanelLayoutCheckTest`:
  assert the tool is present rather than silently skipping.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/lazy_assets.check.mjs", __DIR__)

  test "the lazy bundle loader checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    lazy_assets.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
