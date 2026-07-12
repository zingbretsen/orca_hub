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
end
