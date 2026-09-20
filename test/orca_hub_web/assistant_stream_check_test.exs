defmodule OrcaHubWeb.AssistantStreamCheckTest do
  @moduledoc """
  Runs `assets/js/assistant_stream.check.mjs` — the standalone node checks for
  the live assistant bubble's lifetime rules (voice_mode_spec.md §7.2 / C2 and
  ORCAHUB3-114) — so the suite actually gates them.

  The repo has no JS test runner; the `*.check.mjs` scripts are plain node
  scripts (see `tts_stream.check.mjs` for the convention). Those are run by
  hand; this one is not, because the behaviour it pins is a REGRESSION guard:
  the orphaned live bubble in ORCAHUB3-114 was invisible to every Elixir test
  (the bug is entirely client-side) and would have been invisible to a check
  script nobody remembered to run.

  The `python3`-prerequisite pattern is lifted from
  `OrcaHub.Backend.PiStubIntegrationTest`: assert the tool is present rather
  than silently skipping, so a box without it fails loudly instead of
  reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/assistant_stream.check.mjs", __DIR__)

  test "the assistant-stream bubble lifetime checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    assistant_stream.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
