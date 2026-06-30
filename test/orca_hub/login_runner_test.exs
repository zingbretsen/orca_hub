defmodule OrcaHub.LoginRunnerTest do
  use ExUnit.Case, async: true

  alias OrcaHub.LoginRunner

  # A representative slice of real `claude setup-token` PTY output: an ink TUI
  # full of CSI cursor-positioning escapes, save/restore, and DEC private mode
  # toggles. Captured from `script -qc "stty cols 400; claude setup-token"`.
  @sample "\e7\e[r\e8\e[?25h\e[?25l\e[?2004h\e[?1004hWelcome\e[9Gto\e[12GClaude\e[19GCode\e[24Gv2.1.195\r\r\n" <>
            "\e[>0q\e[cBrowser didn't open?\e[23GUse the url\e[35Gbelow\e[41Gto\e[44Gsign\e[49Gin\e[52G(c\e[55Gto\e[58Gcopy)\r\r\n" <>
            "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=sOfvyPPNLmcKyKfR78Wb75LLYBbg78-6u2FA0QGZDcw&code_challenge_method=S256&state=C-B3_578JB_AVruFVtSWzIgInaHie-rsWm973DjMPQc\r\r\n" <>
            "\r\r\n\e[2GPaste\e[8Gcode\e[13Ghere\e[18Gif\e[21Gprompted\e[30G>\r\r\n"

  describe "strip_ansi/1" do
    test "removes CSI, save/restore, and DEC private mode sequences" do
      cleaned = LoginRunner.strip_ansi(@sample)

      refute String.contains?(cleaned, "\e")
      refute String.contains?(cleaned, "\r")
      refute String.contains?(cleaned, "[?25h")
      refute String.contains?(cleaned, "[9G")
      assert String.contains?(cleaned, "Welcome")
      assert String.contains?(cleaned, "https://claude.com")
    end
  end

  describe "scrape_url/1" do
    test "extracts the full authorize URL from cleaned output" do
      url = @sample |> LoginRunner.strip_ansi() |> LoginRunner.scrape_url()

      assert url ==
               "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=sOfvyPPNLmcKyKfR78Wb75LLYBbg78-6u2FA0QGZDcw&code_challenge_method=S256&state=C-B3_578JB_AVruFVtSWzIgInaHie-rsWm973DjMPQc"
    end

    test "returns nil before any URL is printed" do
      assert LoginRunner.scrape_url("Welcome to Claude Code v2.1.195") == nil
    end
  end

  describe "scrape_token/1" do
    test "extracts an sk-ant-oat token from success output" do
      out =
        LoginRunner.strip_ansi(
          "\e[32mLogin successful!\e[0m\r\nsk-ant-oat01-AbC123_def-456XYZ\r\n"
        )

      assert LoginRunner.scrape_token(out) == "sk-ant-oat01-AbC123_def-456XYZ"
    end

    test "does not false-positive on the authorize URL (no token yet)" do
      out = LoginRunner.strip_ansi(@sample)
      assert LoginRunner.scrape_token(out) == nil
    end
  end
end
