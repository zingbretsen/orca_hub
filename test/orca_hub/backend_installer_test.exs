defmodule OrcaHub.BackendInstallerTest do
  @moduledoc """
  Runs jobs through the REAL `OrcaHub.BackendInstallerSupervisor` /
  `OrcaHub.BackendInstallerRegistry` started by the application — only the
  underlying executables/shell commands are swapped for deterministic
  fixture scripts via the `:orca_hub, :claude_executable` /
  `:codex_executable` / `:pi_executable` / `:npm_executable` /
  `:backend_installer_commands` Application env seams (mirrors
  `OrcaHub.NodeConfig`'s `:node_config_home` pattern). Not async: mutates
  process-wide Application env.

  Deliberately does NOT try to force `installed?: false` for a real backend
  (same limitation as `OrcaHub.NodeConfigTest`'s `cli_installed?/2` test) —
  there's no way to make `System.find_executable/1` return `nil` for a CLI
  that's actually present on the test host's PATH without mutating PATH
  itself, so `installed?`/`action` for claude/codex/pi are asserted as
  internally consistent (`action == :update` iff `installed?`) rather than
  pinned to a specific boolean.
  """
  use ExUnit.Case, async: false

  alias OrcaHub.BackendInstaller

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "backend_installer_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    claude = fixture_script(tmp_dir, "claude", "2.1.205 (Claude Code)")
    codex = fixture_script(tmp_dir, "codex", "codex-cli 0.142.6")
    pi = fixture_script(tmp_dir, "pi", "0.80.4")
    npm = fixture_script(tmp_dir, "npm", "9.9.9")

    original = %{
      commands: Application.get_env(:orca_hub, :backend_installer_commands),
      npm_executable: Application.get_env(:orca_hub, :npm_executable),
      claude_executable: Application.get_env(:orca_hub, :claude_executable),
      codex_executable: Application.get_env(:orca_hub, :codex_executable),
      pi_executable: Application.get_env(:orca_hub, :pi_executable)
    }

    Application.put_env(:orca_hub, :claude_executable, claude)
    Application.put_env(:orca_hub, :codex_executable, codex)
    Application.put_env(:orca_hub, :pi_executable, pi)
    Application.put_env(:orca_hub, :npm_executable, npm)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
      restore_env(:backend_installer_commands, original.commands)
      restore_env(:npm_executable, original.npm_executable)
      restore_env(:claude_executable, original.claude_executable)
      restore_env(:codex_executable, original.codex_executable)
      restore_env(:pi_executable, original.pi_executable)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp restore_env(key, nil), do: Application.delete_env(:orca_hub, key)
  defp restore_env(key, value), do: Application.put_env(:orca_hub, key, value)

  defp fixture_script(tmp_dir, name, output) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/sh\necho \"#{output}\"\n")
    File.chmod!(path, 0o755)
    path
  end

  defp subscribe do
    Phoenix.PubSub.subscribe(OrcaHub.PubSub, BackendInstaller.topic(node()))
  end

  # The :installer_done broadcast happens inside the Job process just before
  # it returns {:stop, :normal, _} — Registry deregistration (driven by the
  # Registry's own monitor on that process) can land an arbitrary number of
  # messages after our own PubSub subscriber receives the broadcast, so
  # running?/1 right after :installer_done is inherently eventually-
  # consistent, not synchronous. Poll instead of asserting immediately.
  defp eventually(fun, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        do_eventually(fun, deadline)

      true ->
        flunk("condition not met within timeout")
    end
  end

  # -------------------------------------------------------------------
  # parse_version/1
  # -------------------------------------------------------------------

  describe "parse_version/1" do
    test "extracts x.y.z from claude's \"2.1.202 (Claude Code)\" format" do
      assert BackendInstaller.parse_version("2.1.202 (Claude Code)") == "2.1.202"
    end

    test "extracts x.y.z from codex's \"codex-cli 0.142.5\" format" do
      assert BackendInstaller.parse_version("codex-cli 0.142.5") == "0.142.5"
    end

    test "extracts a bare x.y.z (pi's format)" do
      assert BackendInstaller.parse_version("0.80.3\n") == "0.80.3"
    end

    test "returns nil when no version-like token is present" do
      assert BackendInstaller.parse_version("command not found") == nil
    end

    test "returns nil for nil input" do
      assert BackendInstaller.parse_version(nil) == nil
    end
  end

  # -------------------------------------------------------------------
  # command_for/2 — fixed, never-interpolated commands
  # -------------------------------------------------------------------

  describe "command_for/2" do
    test "resolves every valid {backend, action} pair" do
      for backend <- [:claude, :codex, :pi], action <- [:install, :update] do
        assert {:ok, cmd} = BackendInstaller.command_for(backend, action)
        assert is_binary(cmd)
      end
    end

    test "returns :error for an unknown action" do
      assert BackendInstaller.command_for(:claude, :bogus) == :error
    end

    test "codex install and update both run npm directly, never `codex update`" do
      assert BackendInstaller.command_for(:codex, :install) ==
               BackendInstaller.command_for(:codex, :update)

      {:ok, cmd} = BackendInstaller.command_for(:codex, :update)
      assert cmd =~ "npm install -g @openai/codex@latest"
      refute cmd =~ "codex update"
    end

    test "pi update uses pi's own self-updater, not npm" do
      assert BackendInstaller.command_for(:pi, :update) == {:ok, "pi update"}
    end

    test "claude update uses claude's own updater; install uses the official installer script" do
      assert BackendInstaller.command_for(:claude, :update) == {:ok, "claude update"}
      {:ok, install_cmd} = BackendInstaller.command_for(:claude, :install)
      assert install_cmd =~ "claude.ai/install.sh"
    end
  end

  # -------------------------------------------------------------------
  # status/0 — shaping
  # -------------------------------------------------------------------

  describe "status/0" do
    test "returns one row per backend with the fixture-derived version and a consistent action" do
      rows = BackendInstaller.status()
      assert Enum.map(rows, & &1.backend) == [:claude, :codex, :pi]

      claude_row = Enum.find(rows, &(&1.backend == :claude))
      assert claude_row.installed?
      assert claude_row.version == "2.1.205"
      # No reliable read-only "latest" check exists for claude (see moduledoc).
      assert claude_row.latest_version == nil
      assert claude_row.unavailable_reason == nil

      codex_row = Enum.find(rows, &(&1.backend == :codex))
      assert codex_row.installed?
      assert codex_row.version == "0.142.6"
      assert codex_row.npm_available?
      assert codex_row.latest_version == "9.9.9"

      pi_row = Enum.find(rows, &(&1.backend == :pi))
      assert pi_row.installed?
      assert pi_row.version == "0.80.4"
      assert pi_row.npm_available?
      assert pi_row.latest_version == "9.9.9"

      for row <- rows do
        assert row.action == if(row.installed?, do: :update, else: :install)
      end
    end

    test "gates codex/pi off with :unavailable when npm isn't in PATH, leaves claude untouched" do
      Application.put_env(
        :orca_hub,
        :npm_executable,
        "definitely-not-a-real-binary-#{System.unique_integer([:positive])}"
      )

      rows = BackendInstaller.status()
      claude_row = Enum.find(rows, &(&1.backend == :claude))
      codex_row = Enum.find(rows, &(&1.backend == :codex))
      pi_row = Enum.find(rows, &(&1.backend == :pi))

      refute claude_row.action == :unavailable

      for row <- [codex_row, pi_row] do
        refute row.npm_available?
        assert row.latest_version == nil
        assert row.action == :unavailable
        assert row.unavailable_reason =~ "npm not available"
      end
    end

    test "reports ephemeral?: true when KUBERNETES_SERVICE_HOST is set" do
      System.put_env("KUBERNETES_SERVICE_HOST", "10.0.0.1")

      try do
        rows = BackendInstaller.status()
        assert Enum.all?(rows, & &1.ephemeral?)
      after
        System.delete_env("KUBERNETES_SERVICE_HOST")
      end
    end

    test "reports ephemeral?: false off-cluster" do
      assert Enum.all?(BackendInstaller.status(), &(&1.ephemeral? == false))
    end
  end

  # -------------------------------------------------------------------
  # run/2-3 — job lifecycle
  # -------------------------------------------------------------------

  describe "run/2-3 job lifecycle" do
    test "streams output chunks then a success :done event carrying the refreshed version" do
      Application.put_env(:orca_hub, :backend_installer_commands, %{
        {:claude, :update} => "echo hello-from-job"
      })

      subscribe()
      assert BackendInstaller.run(:claude, :update) == :ok

      assert_receive {:installer_output, :claude, output}, 2000
      assert output =~ "hello-from-job"

      assert_receive {:installer_done, :claude, {:ok, "2.1.205"}}, 2000
      eventually(fn -> not BackendInstaller.running?(:claude) end)
    end

    test "broadcasts an :error done event carrying the exit code on failure" do
      Application.put_env(:orca_hub, :backend_installer_commands, %{{:codex, :update} => "false"})

      subscribe()
      assert BackendInstaller.run(:codex, :update) == :ok

      assert_receive {:installer_done, :codex, {:error, 1}}, 2000
      eventually(fn -> not BackendInstaller.running?(:codex) end)
    end

    test "rejects a second run for a backend already running with {:error, :already_running}" do
      Application.put_env(:orca_hub, :backend_installer_commands, %{
        {:pi, :update} => "sleep 1 && echo done"
      })

      subscribe()
      assert BackendInstaller.run(:pi, :update) == :ok
      assert BackendInstaller.running?(:pi)
      assert BackendInstaller.run(:pi, :update) == {:error, :already_running}

      assert_receive {:installer_done, :pi, _result}, 3000
      eventually(fn -> not BackendInstaller.running?(:pi) end)
    end

    test "kills and reports {:error, :timeout} for a job exceeding its timeout" do
      Application.put_env(:orca_hub, :backend_installer_commands, %{
        {:claude, :update} => "sleep 5"
      })

      subscribe()
      assert BackendInstaller.run(:claude, :update, timeout: 100) == :ok

      assert_receive {:installer_done, :claude, {:error, :timeout}}, 2000
      eventually(fn -> not BackendInstaller.running?(:claude) end)
    end

    test "running_backends/0 reflects in-flight jobs on this node" do
      Application.put_env(:orca_hub, :backend_installer_commands, %{
        {:codex, :update} => "sleep 1"
      })

      assert BackendInstaller.running_backends() == []

      subscribe()
      assert BackendInstaller.run(:codex, :update) == :ok
      assert BackendInstaller.running_backends() == [:codex]

      assert_receive {:installer_done, :codex, _result}, 3000
      eventually(fn -> BackendInstaller.running_backends() == [] end)
    end
  end
end
