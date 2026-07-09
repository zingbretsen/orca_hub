defmodule OrcaHubWeb.NodeLive.BackendInstallerTest do
  @moduledoc """
  LiveView coverage for NodeLive.Show's "Backends" card (install/update
  status, gating, and the live job output/result stream).

  Not async: mounting NodeLive.Show for a connected node also loads
  `OrcaHub.NodeConfig` (see `ConfigTest`'s moduledoc) AND
  `OrcaHub.BackendInstaller.status/0` — both use process-wide Application
  env overrides to stay off the real `~/.claude`/`~/.codex`/`~/.pi` and the
  real claude/codex/pi/npm binaries.
  """
  use OrcaHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrcaHub.ClusterNodes

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "backend_installer_live_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    original_home = Application.get_env(:orca_hub, :node_config_home)
    Application.put_env(:orca_hub, :node_config_home, tmp_dir)

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

      if original_home,
        do: Application.put_env(:orca_hub, :node_config_home, original_home),
        else: Application.delete_env(:orca_hub, :node_config_home)

      restore_env(:backend_installer_commands, original.commands)
      restore_env(:npm_executable, original.npm_executable)
      restore_env(:claude_executable, original.claude_executable)
      restore_env(:codex_executable, original.codex_executable)
      restore_env(:pi_executable, original.pi_executable)
    end)

    {:ok, n} = ClusterNodes.upsert_seen(Atom.to_string(node()), "installer-test-node")

    {:ok, node: n}
  end

  defp restore_env(key, nil), do: Application.delete_env(:orca_hub, key)
  defp restore_env(key, value), do: Application.put_env(:orca_hub, key, value)

  defp fixture_script(tmp_dir, name, output) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/sh\necho \"#{output}\"\n")
    File.chmod!(path, 0o755)
    path
  end

  defp open(conn, n) do
    {:ok, view, _html} = live(conn, ~p"/nodes/#{n.id}")
    view
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met within timeout")

  defp wait_until(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      result ->
        result
    end
  end

  test "renders per-backend status with the fixture-derived version and an Update button", %{
    conn: conn,
    node: n
  } do
    html = open(conn, n) |> render()

    assert html =~ "backend-installer-claude"
    assert html =~ "backend-installer-codex"
    assert html =~ "backend-installer-pi"
    assert html =~ "2.1.205"
    assert html =~ "0.142.6"
    assert html =~ "0.80.4"
    assert html =~ "Update"
    refute html =~ "not installed"
  end

  test "shows a node-unavailable state for an offline node, no Backends rows", %{conn: conn} do
    {:ok, n} = ClusterNodes.upsert_seen("orca@long-gone-installer", "long-gone-installer-node")

    {:ok, _view, html} = live(conn, ~p"/nodes/#{n.id}")

    assert html =~ "backend-installer-node-unavailable"
    refute html =~ "backend-installer-claude"
  end

  test "gates codex/pi off with an unavailable badge + reason when npm isn't in PATH", %{
    conn: conn,
    node: n
  } do
    Application.put_env(
      :orca_hub,
      :npm_executable,
      "definitely-not-a-real-binary-#{System.unique_integer([:positive])}"
    )

    html = open(conn, n) |> render()

    assert html =~ "unavailable"
    assert html =~ "npm not available on this node"
  end

  test "shows the ephemeral-pod warning when KUBERNETES_SERVICE_HOST is set", %{
    conn: conn,
    node: n
  } do
    System.put_env("KUBERNETES_SERVICE_HOST", "10.0.0.1")

    html =
      try do
        open(conn, n) |> render()
      after
        System.delete_env("KUBERNETES_SERVICE_HOST")
      end

    assert html =~ "ephemeral (pod)"
    assert html =~ "durable updates require an image rebuild"
  end

  test "clicking Update starts a job: spinner appears, output streams, result shows the new version",
       %{conn: conn, node: n} do
    Application.put_env(:orca_hub, :backend_installer_commands, %{
      {:claude, :update} => "echo hi-from-ui"
    })

    view = open(conn, n)

    html = render_click(view, "run_backend_job", %{"backend" => "claude", "action" => "update"})
    assert html =~ "loading-spinner"

    wait_until(fn -> render(view) =~ "hi-from-ui" end)
    wait_until(fn -> render(view) =~ "Done — now at 2.1.205" end)

    final_html = render(view)
    refute final_html =~ "loading-spinner"
  end

  test "a second click while a job is running surfaces an already-running flash", %{
    conn: conn,
    node: n
  } do
    Application.put_env(:orca_hub, :backend_installer_commands, %{
      {:pi, :update} => "sleep 1 && echo done"
    })

    view = open(conn, n)

    render_click(view, "run_backend_job", %{"backend" => "pi", "action" => "update"})

    html = render_click(view, "run_backend_job", %{"backend" => "pi", "action" => "update"})
    assert html =~ "already running"

    wait_until(fn -> render(view) =~ "Done — now at" end)
  end
end
