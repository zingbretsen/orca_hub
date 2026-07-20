defmodule OrcaHub.MCP.Tools.TriggersTest do
  @moduledoc """
  Coverage for the cross-node isolation gate on trigger creation: a trigger
  fires on ITS project's node (see `OrcaHub.TriggerExecutor`), not
  necessarily the caller's, so pointing a trigger at a project on another
  node is a cross-node action an isolated node must not be able to
  initiate — same rationale as `start_session`'s directory-based routing
  in `OrcaHub.MCP.Tools.Sessions`.
  """

  use OrcaHub.DataCase, async: true

  alias OrcaHub.ClusterNodes
  alias OrcaHub.MCP.Tools.Triggers, as: TriggersTool
  alias OrcaHub.Triggers.Trigger
  alias OrcaHub.{Projects, Repo}

  defp isolate_local_node! do
    node_row =
      ClusterNodes.get_by_name(Atom.to_string(node())) ||
        (
          {:ok, row} = ClusterNodes.upsert_seen(Atom.to_string(node()), Atom.to_string(node()))
          row
        )

    {:ok, isolated_row} = ClusterNodes.update_node(node_row, %{isolated: true})
    isolated_row
  end

  describe "create_scheduled_trigger — cross-node isolation" do
    test "denies targeting a project on another node when the local node is isolated" do
      isolate_local_node!()

      {:ok, remote_project} =
        Projects.create_project(%{
          name: "remote-project-for-trigger",
          directory: "/tmp/remote-project-for-trigger",
          node: "debian@totally-offline-host"
        })

      count_before = Repo.aggregate(Trigger, :count)

      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{"name" => "t1", "prompt" => "hi", "project_id" => remote_project.id},
          %{}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
      assert Repo.aggregate(Trigger, :count) == count_before
    end

    test "allows targeting a project on this node even when isolated" do
      isolate_local_node!()

      {:ok, local_project} =
        Projects.create_project(%{
          name: "local-project-for-trigger",
          directory: "/tmp/local-project-for-trigger",
          node: Atom.to_string(node())
        })

      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{"name" => "t2", "prompt" => "hi", "project_id" => local_project.id},
          %{}
        )

      assert %{"isError" => false} = result
    end

    test "unrestricted when not isolated" do
      {:ok, remote_project} =
        Projects.create_project(%{
          name: "remote-project-unisolated",
          directory: "/tmp/remote-project-unisolated",
          node: "debian@totally-offline-host"
        })

      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{"name" => "t3", "prompt" => "hi", "project_id" => remote_project.id},
          %{}
        )

      assert %{"isError" => false} = result
    end
  end

  describe "create_webhook_trigger — cross-node isolation" do
    test "denies targeting a project on another node when the local node is isolated" do
      isolate_local_node!()

      {:ok, remote_project} =
        Projects.create_project(%{
          name: "remote-project-for-webhook",
          directory: "/tmp/remote-project-for-webhook",
          node: "debian@totally-offline-host"
        })

      result =
        TriggersTool.call(
          "create_webhook_trigger",
          %{"name" => "t4", "prompt" => "hi", "project_id" => remote_project.id},
          %{}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "isolated"
    end
  end

  describe "create_scheduled_trigger — directory-based project resolution" do
    test "resolves a directory to its project_id" do
      {:ok, project} =
        Projects.create_project(%{
          name: "directory-trigger-project",
          directory: "/tmp/directory-trigger-project-#{System.unique_integer([:positive])}",
          node: Atom.to_string(node())
        })

      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{"name" => "t-dir", "prompt" => "hi", "directory" => project.directory},
          %{}
        )

      assert %{"isError" => false} = result
      trigger = Repo.get_by!(Trigger, name: "t-dir")
      assert trigger.project_id == project.id
    end

    test "project_id wins when both project_id and directory are given" do
      {:ok, project} =
        Projects.create_project(%{
          name: "directory-trigger-project-winner",
          directory: "/tmp/directory-trigger-project-winner-#{System.unique_integer([:positive])}",
          node: Atom.to_string(node())
        })

      {:ok, other_project} =
        Projects.create_project(%{
          name: "directory-trigger-project-loser",
          directory: "/tmp/directory-trigger-project-loser-#{System.unique_integer([:positive])}",
          node: Atom.to_string(node())
        })

      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{
            "name" => "t-both",
            "prompt" => "hi",
            "project_id" => project.id,
            "directory" => other_project.directory
          },
          %{}
        )

      assert %{"isError" => false} = result
      trigger = Repo.get_by!(Trigger, name: "t-both")
      assert trigger.project_id == project.id
    end

    test "a directory matching no project returns a clear error mentioning list_projects" do
      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{"name" => "t-unknown-dir", "prompt" => "hi", "directory" => "/tmp/does-not-exist"},
          %{}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "list_projects"
      assert text =~ "/tmp/does-not-exist"
    end

    test "neither project_id nor directory returns a clear error" do
      result =
        TriggersTool.call(
          "create_scheduled_trigger",
          %{"name" => "t-neither", "prompt" => "hi"},
          %{}
        )

      assert %{"isError" => true, "content" => [%{"text" => text}]} = result
      assert text =~ "project_id or directory"
    end
  end

  describe "create_webhook_trigger — directory-based project resolution" do
    test "resolves a directory to its project_id" do
      {:ok, project} =
        Projects.create_project(%{
          name: "directory-webhook-project",
          directory: "/tmp/directory-webhook-project-#{System.unique_integer([:positive])}",
          node: Atom.to_string(node())
        })

      result =
        TriggersTool.call(
          "create_webhook_trigger",
          %{"name" => "wh-dir", "prompt" => "hi", "directory" => project.directory},
          %{}
        )

      assert %{"isError" => false} = result
      trigger = Repo.get_by!(Trigger, name: "wh-dir")
      assert trigger.project_id == project.id
    end
  end
end
