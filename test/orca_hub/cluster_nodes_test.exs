defmodule OrcaHub.ClusterNodesTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.ClusterNodes
  alias OrcaHub.Projects
  alias OrcaHub.Sessions

  describe "upsert_seen/2" do
    test "inserts a new row with first and last connected timestamps set" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")

      assert node.name == "orca@a"
      assert node.display_name == "a"
      assert node.first_connected_at
      assert node.last_connected_at
    end

    test "preserves first_connected_at across repeated calls, bumps last_connected_at" do
      {:ok, first} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, second} = ClusterNodes.upsert_seen("orca@a", "a (renamed)")

      assert second.first_connected_at == first.first_connected_at
      assert second.display_name == "a (renamed)"
      assert DateTime.compare(second.last_connected_at, first.last_connected_at) in [:eq, :gt]

      assert ClusterNodes.list_nodes() |> Enum.count(&(&1.name == "orca@a")) == 1
    end
  end

  describe "touch_last_connected/1" do
    test "bumps last_connected_at without touching display_name" do
      {:ok, _} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, touched} = ClusterNodes.touch_last_connected("orca@a")

      assert touched.display_name == "a"
      assert touched.last_connected_at
    end

    test "creates a row if none exists yet" do
      {:ok, node} = ClusterNodes.touch_last_connected("orca@ghost")
      assert node.name == "orca@ghost"
    end
  end

  describe "backfill_node/2" do
    test "inserts a row without connected timestamps" do
      {:ok, node} = ClusterNodes.backfill_node("orca@inferred", "inferred")

      assert node.name == "orca@inferred"
      assert node.first_connected_at == nil
      assert node.last_connected_at == nil
    end

    test "does not overwrite an existing row" do
      {:ok, _} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.backfill_node("orca@a", "should not apply")

      assert ClusterNodes.get_by_name("orca@a").display_name == "a"
    end
  end

  describe "update_node/2" do
    test "updates arbitrary attrs, e.g. isolated" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      refute node.isolated

      {:ok, updated} = ClusterNodes.update_node(node, %{isolated: true})
      assert updated.isolated

      {:ok, toggled_back} = ClusterNodes.update_node(updated, %{isolated: false})
      refute toggled_back.isolated
    end

    test "updates arbitrary attrs, e.g. scrub_session_env" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      refute node.scrub_session_env

      {:ok, updated} = ClusterNodes.update_node(node, %{scrub_session_env: true})
      assert updated.scrub_session_env

      {:ok, toggled_back} = ClusterNodes.update_node(updated, %{scrub_session_env: false})
      refute toggled_back.scrub_session_env
    end

    test "updates env_allowlist" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      assert node.env_allowlist == []

      {:ok, updated} = ClusterNodes.update_node(node, %{env_allowlist: ["AWS_*", "MY_TOKEN"]})
      assert updated.env_allowlist == ["AWS_*", "MY_TOKEN"]

      {:ok, cleared} = ClusterNodes.update_node(updated, %{env_allowlist: []})
      assert cleared.env_allowlist == []
    end

    test "rejects an invalid env_allowlist entry" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")

      assert {:error, changeset} = ClusterNodes.update_node(node, %{env_allowlist: ["bad entry"]})
      assert errors_on(changeset).env_allowlist != []
    end

    test "updates default_backend and default_model" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      assert node.default_backend == nil
      assert node.default_model == nil

      {:ok, updated} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      assert updated.default_backend == "claude"
      assert updated.default_model == "sonnet-5"

      {:ok, cleared} =
        ClusterNodes.update_node(updated, %{default_backend: nil, default_model: nil})

      assert cleared.default_backend == nil
      assert cleared.default_model == nil
    end

    test "updates dial" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      refute node.dial

      {:ok, updated} = ClusterNodes.update_node(node, %{dial: true})
      assert updated.dial

      {:ok, toggled_back} = ClusterNodes.update_node(updated, %{dial: false})
      refute toggled_back.dial
    end
  end

  describe "create_node/1" do
    test "manually creates a row with dial enabled, for a node that has never connected" do
      assert {:ok, node} =
               ClusterNodes.create_node(%{
                 name: "orca@future-gb10",
                 display_name: "GB10",
                 dial: true
               })

      assert node.name == "orca@future-gb10"
      assert node.display_name == "GB10"
      assert node.dial
      assert node.first_connected_at == nil
      assert node.last_connected_at == nil
    end

    test "rejects a duplicate name with a friendly error" do
      {:ok, _} = ClusterNodes.create_node(%{name: "orca@dup", dial: true})

      assert {:error, changeset} = ClusterNodes.create_node(%{name: "orca@dup", dial: true})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "rejects a name that doesn't look like basename@host" do
      assert {:error, changeset} = ClusterNodes.create_node(%{name: "not-a-node-name"})
      assert errors_on(changeset).name != []
    end
  end

  describe "list_dial_targets/0" do
    test "returns only the names of dial-enabled rows" do
      {:ok, _} = ClusterNodes.create_node(%{name: "orca@dial-me", dial: true})
      {:ok, _} = ClusterNodes.create_node(%{name: "orca@dont-dial-me", dial: false})
      {:ok, _} = ClusterNodes.upsert_seen("orca@never-touched", "never-touched")

      assert ClusterNodes.list_dial_targets() == ["orca@dial-me"]
    end

    test "returns [] when no rows are dial-enabled" do
      {:ok, _} = ClusterNodes.upsert_seen("orca@a", "a")

      assert ClusterNodes.list_dial_targets() == []
    end
  end

  describe "isolated flag survives conflict-update paths" do
    test "upsert_seen does not reset an isolated node back to false" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, isolated_node} = ClusterNodes.update_node(node, %{isolated: true})
      assert isolated_node.isolated

      {:ok, reseen} = ClusterNodes.upsert_seen("orca@a", "a (reconnected)")

      assert reseen.isolated
      assert ClusterNodes.get_by_name("orca@a").isolated
    end

    test "touch_last_connected does not reset an isolated node back to false" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{isolated: true})

      {:ok, touched} = ClusterNodes.touch_last_connected("orca@a")

      assert touched.isolated
    end

    test "backfill_node never overwrites an existing isolated row" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{isolated: true})

      {:ok, _} = ClusterNodes.backfill_node("orca@a", "should not apply")

      assert ClusterNodes.get_by_name("orca@a").isolated
    end
  end

  describe "scrub_session_env flag survives conflict-update paths" do
    test "upsert_seen does not reset a scrub_session_env node back to false" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, scrubbed_node} = ClusterNodes.update_node(node, %{scrub_session_env: true})
      assert scrubbed_node.scrub_session_env

      {:ok, reseen} = ClusterNodes.upsert_seen("orca@a", "a (reconnected)")

      assert reseen.scrub_session_env
      assert ClusterNodes.get_by_name("orca@a").scrub_session_env
    end

    test "touch_last_connected does not reset a scrub_session_env node back to false" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{scrub_session_env: true})

      {:ok, touched} = ClusterNodes.touch_last_connected("orca@a")

      assert touched.scrub_session_env
    end

    test "backfill_node never overwrites an existing scrub_session_env row" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{scrub_session_env: true})

      {:ok, _} = ClusterNodes.backfill_node("orca@a", "should not apply")

      assert ClusterNodes.get_by_name("orca@a").scrub_session_env
    end
  end

  describe "env_allowlist survives conflict-update paths" do
    test "upsert_seen does not reset a node's env_allowlist back to []" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, extended} = ClusterNodes.update_node(node, %{env_allowlist: ["AWS_*"]})
      assert extended.env_allowlist == ["AWS_*"]

      {:ok, reseen} = ClusterNodes.upsert_seen("orca@a", "a (reconnected)")

      assert reseen.env_allowlist == ["AWS_*"]
      assert ClusterNodes.get_by_name("orca@a").env_allowlist == ["AWS_*"]
    end

    test "touch_last_connected does not reset a node's env_allowlist back to []" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{env_allowlist: ["AWS_*"]})

      {:ok, touched} = ClusterNodes.touch_last_connected("orca@a")

      assert touched.env_allowlist == ["AWS_*"]
    end

    test "backfill_node never overwrites an existing row's env_allowlist" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{env_allowlist: ["AWS_*"]})

      {:ok, _} = ClusterNodes.backfill_node("orca@a", "should not apply")

      assert ClusterNodes.get_by_name("orca@a").env_allowlist == ["AWS_*"]
    end
  end

  describe "default_backend/default_model survive conflict-update paths" do
    test "upsert_seen does not reset node defaults" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")

      {:ok, defaulted} =
        ClusterNodes.update_node(node, %{default_backend: "claude", default_model: "sonnet-5"})

      assert defaulted.default_backend == "claude"

      {:ok, reseen} = ClusterNodes.upsert_seen("orca@a", "a (reconnected)")

      assert reseen.default_backend == "claude"
      assert reseen.default_model == "sonnet-5"
      assert ClusterNodes.get_by_name("orca@a").default_backend == "claude"
    end

    test "touch_last_connected does not reset node defaults" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{default_backend: "codex"})

      {:ok, touched} = ClusterNodes.touch_last_connected("orca@a")

      assert touched.default_backend == "codex"
    end

    test "backfill_node never overwrites an existing row's defaults" do
      {:ok, node} = ClusterNodes.upsert_seen("orca@a", "a")
      {:ok, _} = ClusterNodes.update_node(node, %{default_backend: "codex"})

      {:ok, _} = ClusterNodes.backfill_node("orca@a", "should not apply")

      assert ClusterNodes.get_by_name("orca@a").default_backend == "codex"
    end
  end

  describe "distinct_session_and_project_node_names/0" do
    test "collects distinct node names from sessions and projects, ignoring blanks" do
      {:ok, _} =
        Projects.create_project(%{name: "p1", directory: "/tmp/p1", node: "orca@proj-node"})

      {:ok, _} =
        Sessions.create_session(%{directory: "/tmp/s1", runner_node: "orca@session-node"})

      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s2", runner_node: nil})

      names = ClusterNodes.distinct_session_and_project_node_names()

      assert "orca@proj-node" in names
      assert "orca@session-node" in names
      refute nil in names
      refute "" in names
    end
  end

  describe "count_sessions_for_node/1 and count_projects_for_node/1" do
    test "counts only rows assigned to the given node" do
      {:ok, _} =
        Projects.create_project(%{name: "p1", directory: "/tmp/p1", node: "orca@a"})

      {:ok, _} =
        Projects.create_project(%{name: "p2", directory: "/tmp/p2", node: "orca@b"})

      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s1", runner_node: "orca@a"})
      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s2", runner_node: "orca@a"})
      {:ok, _} = Sessions.create_session(%{directory: "/tmp/s3", runner_node: "orca@b"})

      assert ClusterNodes.count_projects_for_node("orca@a") == 1
      assert ClusterNodes.count_sessions_for_node("orca@a") == 2
      assert ClusterNodes.count_sessions_for_node("orca@b") == 1
      assert ClusterNodes.count_sessions_for_node("orca@nonexistent") == 0
    end
  end
end
