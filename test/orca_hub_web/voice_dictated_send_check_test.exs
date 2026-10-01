defmodule OrcaHubWeb.VoiceDictatedSendCheckTest do
  @moduledoc """
  Runs `assets/js/voice/dictated_send.check.mjs` — the standalone node checks
  that a spoken send submits the session composer with its hidden
  `voice_dictated` button as the SUBMITTER — so the suite actually gates
  them.

  Same reasoning as `OrcaHubWeb.TtsHoldCheckTest`: the client half is
  invisible to every other test here, and losing it is SILENT — a voice send
  would simply stop telling the agent the text was dictated, with nothing
  failing. The server half (the param -> `OrcaHub.Voice.Dictation` prefix)
  is pinned in `SessionLive.ShowTest`.

  Asserts `node` is present rather than skipping, so a box without it fails
  loudly instead of reporting a green run that checked nothing.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../assets/js/voice/dictated_send.check.mjs", __DIR__)

  test "the voice dictated-send checks pass" do
    node = System.find_executable("node")

    refute is_nil(node),
           "node not found — required to run #{Path.relative_to_cwd(@script)}"

    assert File.exists?(@script), "missing check script: #{@script}"

    {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)

    assert status == 0, """
    dictated_send.check.mjs failed (exit #{status}).

    Reproduce with:

        node #{Path.relative_to_cwd(@script)}

    #{output}
    """
  end
end
