defmodule OrcaHubWeb.TtsRailCheckTest do
  @moduledoc """
  Runs `assets/js/tts_rail.check.mjs` — the standalone node checks for the
  phone voice view's read-aloud RAIL, HELD STRIP and TAP-TO-JUMP (ORCAHUB3-113
  phase C) — so the suite actually gates them.

  Same reasoning as `OrcaHubWeb.TtsHoldCheckTest`, whose pattern this copies:
  the behaviour is entirely client-side and invisible to every other test
  here, and the failures it guards against are SILENT ones — a rail that
  stops following the sentence counter, a tap that lands on the wrong
  sentence, an End that no longer stops the reading. Nothing else would go
  red.

  `node` is asserted present rather than silently skipped, so a box without
  it fails loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/tts_rail.check.mjs", __DIR__)

  test "the voice view's TTS rail, held strip and tap-to-jump checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    tts_rail.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
