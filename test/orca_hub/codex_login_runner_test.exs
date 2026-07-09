defmodule OrcaHub.CodexLoginRunnerTest do
  # Starts real GenServers/Ports (via the :codex_executable seam, mirroring
  # OrcaHub.Backend.Codex's own test pattern) — not async, since it mutates
  # global Application env and the singleton-per-node CodexLoginRunner.
  use ExUnit.Case, async: false

  alias OrcaHub.CodexLoginRunner

  @fake_codex Path.expand("../support/fixtures/fake_codex.sh", __DIR__)

  setup do
    original = Application.get_env(:orca_hub, :codex_executable)
    Application.put_env(:orca_hub, :codex_executable, @fake_codex)
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, "codex_login:#{node()}")

    on_exit(fn ->
      CodexLoginRunner.cancel()

      if original do
        Application.put_env(:orca_hub, :codex_executable, original)
      else
        Application.delete_env(:orca_hub, :codex_executable)
      end
    end)

    :ok
  end

  describe "strip_ansi/1, scrape_url/1, scrape_code/1" do
    test "strips CSI/OSC escapes and keeps text" do
      raw = "\e[2J\e[1;1HVisit \e[32mhttps://chatgpt.com/device\e[0m and enter WDJB-MJHT\r\n"
      cleaned = CodexLoginRunner.strip_ansi(raw)

      refute String.contains?(cleaned, "\e")
      assert String.contains?(cleaned, "https://chatgpt.com/device")
      assert String.contains?(cleaned, "WDJB-MJHT")
    end

    test "scrape_url/1 extracts the verification URL" do
      assert CodexLoginRunner.scrape_url("Visit https://chatgpt.com/device now.") ==
               "https://chatgpt.com/device"

      assert CodexLoginRunner.scrape_url("no url here") == nil
    end

    test "scrape_code/1 extracts an RFC-8628-shaped user code" do
      assert CodexLoginRunner.scrape_code("enter code WDJB-MJHT to continue") == "WDJB-MJHT"
    end

    test "scrape_code/1 falls back to a 'code: TOKEN' phrasing" do
      assert CodexLoginRunner.scrape_code("your code: ABC123") == "ABC123"
      assert CodexLoginRunner.scrape_code("nothing to see here") == nil
    end
  end

  describe "device-auth flow" do
    test "scrapes URL + code and reports success on exit 0" do
      {:ok, _pid} = CodexLoginRunner.start_device_auth()

      assert_receive {:codex_login_status, :running}, 2_000
      assert_receive {:codex_login_url, "https://chatgpt.com/device"}, 2_000
      assert_receive {:codex_login_code, "WDJB-MJHT"}, 2_000
      assert_receive {:codex_login_status, :awaiting_approval}, 2_000
      assert_receive {:codex_login_done, :success}, 2_000
    end
  end

  describe "api-key flow" do
    test "delivers the key over stdin, never broadcasts raw output, reports success" do
      out_path =
        Path.join(System.tmp_dir!(), "fake_codex_key_out_#{System.unique_integer([:positive])}")

      System.put_env("FAKE_CODEX_KEY_OUT", out_path)
      on_exit(fn -> System.delete_env("FAKE_CODEX_KEY_OUT") end)

      {:ok, _pid} = CodexLoginRunner.start_api_key("fake-openai-key-do-not-log")

      assert_receive {:codex_login_status, :running}, 2_000
      assert_receive {:codex_login_done, :success}, 2_000
      refute_received {:codex_login_output, _}

      assert File.read!(out_path) == "fake-openai-key-do-not-log"
    end

    test "reports error on non-zero exit without leaking the key in the error" do
      {:ok, _pid} = CodexLoginRunner.start_api_key("fail-me")

      assert_receive {:codex_login_done, {:error, msg}}, 2_000
      refute String.contains?(msg, "fail-me")
      refute_received {:codex_login_output, _}
    end
  end
end
