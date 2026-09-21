defmodule OrcaHubWeb.TtsHoldCheckTest do
  @moduledoc """
  Runs `assets/js/tts_hold.check.mjs` — the standalone node checks for the
  read-aloud AUTOPLAY HOLD and the voice bar's transport (ORCAHUB3-113 items
  6 and 7) — so the suite actually gates them.

  The repo has no JS test runner; the `*.check.mjs` scripts are plain node
  scripts (see `tts_stream.check.mjs` for the convention). Most are run by
  hand; this one is not, for the same reason
  `OrcaHubWeb.AssistantStreamCheckTest` is not: the behaviour it pins is
  entirely client-side and therefore invisible to every other test here, and
  the regression it guards against is a SILENT one — an autoplay path added
  later that forgets to ask whether the user is still typing would simply
  take the microphone back, with nothing failing.

  The `node`-prerequisite pattern is lifted from that sibling test: assert the
  tool is present rather than silently skipping, so a box without it fails
  loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/tts_hold.check.mjs", __DIR__)

  test "the TTS autoplay-hold checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    tts_hold.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
